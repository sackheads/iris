import Foundation

/// The git config format, read only to decide which keys a change touched (#623). Strict: a file
/// it cannot read in full is `nil`, and a change to one is put back.
enum GitConfigFile {
    struct Entry: Hashable {
        /// `section.name` or `section.subsection.name`; section and name lowercased, as git does.
        var key: String
        /// nil for a bare key, which git reads as true.
        var value: String?
    }

    static func parse(_ data: Data) -> [Entry]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let s = Array(text.unicodeScalars)
        var i = 0
        var section: String?
        var entries: [Entry] = []
        func skipLine() { while i < s.count, s[i] != "\n" { i += 1 } }
        func isAlnum(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.alphanumerics.contains(c)) }
        while i < s.count {
            let c = s[i]
            if c == " " || c == "\t" || c == "\r" || c == "\n" { i += 1; continue }
            if c == "#" || c == ";" { skipLine(); continue }
            if c == "[" {
                i += 1
                var name = ""
                while i < s.count, isAlnum(s[i]) || s[i] == "-" || s[i] == "." { name.unicodeScalars.append(s[i]); i += 1 }
                guard !name.isEmpty, i < s.count else { return nil }
                var header = name.lowercased()
                if s[i] == " " || s[i] == "\t" {
                    while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
                    guard i < s.count, s[i] == "\"", !name.contains(".") else { return nil }
                    i += 1
                    var sub = ""
                    while true {
                        guard i < s.count, s[i] != "\n" else { return nil }
                        if s[i] == "\"" { i += 1; break }
                        if s[i] == "\\" { i += 1; guard i < s.count, s[i] != "\n" else { return nil } }
                        sub.unicodeScalars.append(s[i]); i += 1
                    }
                    header += "." + sub
                }
                guard i < s.count, s[i] == "]" else { return nil }
                i += 1
                section = header
                continue
            }
            guard c.isASCII, CharacterSet.letters.contains(c), let section else { return nil }
            var name = ""
            while i < s.count, isAlnum(s[i]) || s[i] == "-" { name.unicodeScalars.append(s[i]); i += 1 }
            while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
            let key = section + "." + name.lowercased()
            if i >= s.count || s[i] == "\n" || s[i] == "\r" || s[i] == "#" || s[i] == ";" {
                entries.append(Entry(key: key, value: nil))
                skipLine()
                continue
            }
            guard s[i] == "=" else { return nil }
            i += 1
            while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
            var value = ""
            var pendingSpace = ""
            var quoted = false
            valueLoop: while i < s.count {
                let v = s[i]
                switch v {
                case "\n":
                    if quoted { return nil }
                    break valueLoop
                case "\\":
                    i += 1
                    guard i < s.count else { return nil }
                    switch s[i] {
                    case "\n": i += 1; continue valueLoop
                    case "\r" where i + 1 < s.count && s[i + 1] == "\n": i += 2; continue valueLoop
                    case "n": value += pendingSpace + "\n"
                    case "t": value += pendingSpace + "\t"
                    case "b": value += pendingSpace + "\u{8}"
                    case "\"": value += pendingSpace + "\""
                    case "\\": value += pendingSpace + "\\"
                    default: return nil
                    }
                    pendingSpace = ""
                case "\"":
                    quoted.toggle()
                case "#" where !quoted, ";" where !quoted:
                    skipLine()
                    break valueLoop
                case " " where !quoted, "\t" where !quoted:
                    pendingSpace.unicodeScalars.append(v)
                case "\r" where !quoted:
                    break
                default:
                    value += pendingSpace
                    pendingSpace = ""
                    value.unicodeScalars.append(v)
                }
                i += 1
            }
            if quoted { return nil }
            entries.append(Entry(key: key, value: value))
        }
        return entries
    }

    static func isAllowed(key: String, values: [String]) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let section = parts.first, let name = parts.last else { return false }
        let hasSubsection = parts.count >= 3
        switch (section, hasSubsection, name) {
        case ("user", false, _):
            return values.allSatisfy(isPlain)
        case ("branch", true, "merge"), ("remote", true, "fetch"):
            return values.allSatisfy(isPlain)
        case ("branch", true, "remote"), ("remote", true, "url"), ("remote", true, "pushurl"):
            return values.allSatisfy(isSafeURL)
        default:
            return false
        }
    }

    private static func isPlain(_ value: String) -> Bool {
        value != "\u{0}" && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// A URL or path git fetches with its own transports. `<helper>::<address>` runs
    /// `git-remote-<helper>`, and `ext::` a command line of the repository's choosing.
    static func isSafeURL(_ value: String) -> Bool {
        isPlain(value) && !value.isEmpty && !value.hasPrefix("-") && !value.contains("::")
    }
}

/// Tracks folders mounted read-write by sandboxes and judges untrusted repositories (#658).
final class GitConfigGuard: @unchecked Sendable {
    static let shared = GitConfigGuard(store: IrisPaths.default.configDir.appendingPathComponent("sandbox-workspaces.json"))

    /// One folder a sandbox has mounted read-write, kept across restarts so host git knows
    /// which repositories the VM could have created or modified.
    struct MountedWorkspace: Codable, Equatable {
        var path: String

        init(path: String) { self.path = path }

        enum CodingKeys: CodingKey {
            case path
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
        }
    }

    /// An entry that fails to decode is counted and skipped, not fatal to the others.
    private struct LossyWorkspace: Decodable {
        var item: MountedWorkspace?
        init(from decoder: Decoder) throws { item = try? MountedWorkspace(from: decoder) }
    }

    /// The `core.*` keys `git init` writes, which a repository the VM made may hold.
    static let initDefaults: Set<String> = [
        "core.repositoryformatversion", "core.filemode", "core.bare",
        "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode",
        "core.symlinks"
    ]

    enum HostDecision: Equatable {
        case refuse(String, notice: String? = nil)
        case noHooks(notice: String?)
        case ordinary(notice: String?)

        var notice: String? {
            switch self {
            case .refuse(_, let notice): return notice
            case .noHooks(let notice), .ordinary(let notice): return notice
            }
        }
    }

    private let lock = NSLock()
    private let store: URL?
    private var mountedPaths: Set<String> = []
    private var unknownFolders = false
    private var corruptCopies: [String] = []
    private var loadNote: String?
    private var saveDisabled = false
    private var seenUntrustedRepos: Set<String> = []

    var isUnknownFolders: Bool { lock.lock(); defer { lock.unlock() }; return unknownFolders }
    var mountedWorkspaces: [String] { lock.lock(); defer { lock.unlock() }; return mountedPaths.sorted() }

    init(store: URL? = nil) {
        self.store = store
        guard let store else { return }
        var saved: [MountedWorkspace] = []
        var lost: String?
        var info = stat()
        if lstat(store.path, &info) == 0 || errno != ENOENT {
            if let data = try? Data(contentsOf: store),
               let entries = try? JSONDecoder().decode([LossyWorkspace].self, from: data) {
                saved = entries.compactMap(\.item)
                if saved.count < entries.count {
                    let aside = Self.setAside(store, move: false)
                    saveDisabled = aside == nil
                    lost = "Iris could not read \(entries.count - saved.count) of the \(entries.count) folders in its list of those sandboxes have mounted"
                        + (aside.map { "; the list as it was is kept at \($0)." } ?? " (\(store.path)), and left it as it is.")
                }
            } else {
                let aside = Self.setAside(store, move: true)
                saveDisabled = aside == nil
                lost = "Iris could not read its list of the folders sandboxes have mounted"
                    + (aside.map { ", and moved it to \($0)." } ?? " (\(store.path)), and left it as it is.")
            }
        }
        corruptCopies = Self.corruptCopies(of: store)
        unknownFolders = lost != nil || !corruptCopies.isEmpty
        if unknownFolders {
            loadNote = "[sandbox] " + (lost ?? "Iris could not read its list of the folders sandboxes have mounted on an earlier launch.")
                + Self.unknownFoldersNote
                + (corruptCopies.isEmpty ? "" : " Delete \(corruptCopies.joined(separator: " and ")) to end this.")
        }
        for item in saved {
            mountedPaths.insert(item.path)
        }
    }

    private static let unknownFoldersNote = " Until a sandbox mounts a folder again, git that Iris runs on your Mac runs no hooks and checks every repository found."

    private static func corruptCopies(of store: URL) -> [String] {
        let dir = store.deletingLastPathComponent().path
        let prefix = store.lastPathComponent + ".corrupt"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0 == prefix || $0.hasPrefix(prefix + "-") }.sorted()
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    private static func setAside(_ store: URL, move: Bool) -> String? {
        for n in 1...100 {
            let aside = store.path + ".corrupt" + (n == 1 ? "" : "-\(n)")
            do {
                if move { try FileManager.default.moveItem(atPath: store.path, toPath: aside) }
                else { try FileManager.default.copyItem(atPath: store.path, toPath: aside) }
                return aside
            } catch {
                var info = stat()
                if lstat(aside, &info) != 0 { return nil }
            }
        }
        return nil
    }

    func takeLoadNote() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { loadNote = nil }
        return loadNote
    }

    private func save() {
        guard let store, !saveDisabled else { return }
        let items = mountedPaths.sorted().map { MountedWorkspace(path: $0) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }

    func recordMounted(sources: [String]) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for source in sources {
            let real = IrisPaths.realPath(source)
            if mountedPaths.insert(real).inserted {
                changed = true
            }
        }
        if changed { save() }
    }

    func noticeForRepo(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return noticeForRepoLocked(path)
    }

    private func noticeForRepoLocked(_ path: String) -> String? {
        let real = IrisPaths.realPath(path)
        guard seenUntrustedRepos.insert(real).inserted else { return nil }
        return "[sandbox] A repository at \(real) was created or modified in a sandbox. Git that Iris runs on your Mac there runs no hooks. Git run from your own terminal there is not protected."
    }

    static func withNotices(_ result: String, before: String?, after: String?) -> String {
        var parts: [String] = []
        if let before, !before.isEmpty { parts.append(before) }
        parts.append(result)
        if let after, !after.isEmpty { parts.append(after) }
        return parts.joined(separator: "\n")
    }

    static func isTrusted(commonDir: String, paths: IrisPaths = .default) -> Bool {
        let canonicalCommon = IrisPaths.realPath(commonDir)
        let key = SandboxGit.key(canonicalCommon)
        let markerPath = ((SandboxGit.directory(paths: paths) as NSString).appendingPathComponent(key) as NSString)
            .appendingPathComponent(SandboxGit.seedMarker)
        guard let data = WorkspaceGit.readSmall(markerPath),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return false
        }
        return String(firstLine) == canonicalCommon
    }

    static func findNearestGit(from dir: String) -> (worktree: String, commonDir: String)? {
        var current = IrisPaths.realPath(dir)
        var visited = Set<String>()
        while true {
            visited.insert(current)
            switch WorkspaceGit.entry(at: current) {
            case .layout(let layout):
                return (worktree: current, commonDir: IrisPaths.realPath(layout.commonDir))
            case .unsupported:
                return (worktree: current, commonDir: IrisPaths.realPath((current as NSString).appendingPathComponent(".git")))
            case .none:
                break
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || visited.contains(parent) || current == "/" {
                break
            }
            current = parent
        }
        return nil
    }

    static func extractGitCPaths(command: String, cwd: String?) -> [String] {
        var paths: [String] = []
        let pattern = #"(?:^|[;&|\s])git\s+(?:-[^\s]+\s+)*-C\s+(?:'([^']+)'|"([^"]+)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        let matches = regex.matches(in: command, range: range)
        for match in matches {
            let extracted: String
            if let r1 = Range(match.range(at: 1), in: command) {
                extracted = String(command[r1])
            } else if let r2 = Range(match.range(at: 2), in: command) {
                extracted = String(command[r2])
            } else if let r3 = Range(match.range(at: 3), in: command) {
                extracted = String(command[r3])
            } else {
                continue
            }
            let resolved: String
            if extracted.hasPrefix("/") {
                resolved = extracted
            } else if let cwd {
                resolved = (cwd as NSString).appendingPathComponent(extracted)
            } else {
                resolved = extracted
            }
            paths.append(resolved)
        }
        return paths
    }

    static func judgeUntrustedRepo(worktree: String, commonDir: String) -> String? {
        var configPaths: [String] = []
        let common = commonDir as NSString
        configPaths.append(common.appendingPathComponent("config"))
        configPaths.append(common.appendingPathComponent("config.worktree"))
        if case .layout(let layout) = WorkspaceGit.entry(at: worktree), layout.dotGitIsFile {
            configPaths.append((layout.gitDir as NSString).appendingPathComponent("config.worktree"))
        }
        for module in WorkspaceGit.modules(commonDir: commonDir) {
            configPaths.append((module as NSString).appendingPathComponent("config"))
        }
        let worktreesDir = common.appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktreesDir)) ?? [] {
            configPaths.append(((worktreesDir as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("config.worktree"))
        }

        for path in configPaths {
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno == ENOENT { continue }
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(path), in a repository the sandbox made, cannot be read."
            }
            guard info.st_mode & S_IFMT == S_IFREG, let data = WorkspaceGit.readSmall(path) else {
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(path), in a repository the sandbox made, cannot be read."
            }
            guard let entries = GitConfigFile.parse(data) else {
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(path), in a repository the sandbox made, cannot be read."
            }
            var values: [String: [String]] = [:]
            for e in entries {
                values[e.key, default: []].append(e.value ?? "\u{0}")
            }
            var badKeys: [String] = []
            for key in values.keys.sorted() {
                let vals = values[key]!
                if initDefaults.contains(key) { continue }
                if GitConfigFile.isAllowed(key: key, values: vals) { continue }
                if let lfsExpected = WorkspaceGit.lfsValues[key], vals.allSatisfy({ $0 == lfsExpected }) { continue }
                badKeys.append(key)
            }
            if !badKeys.isEmpty {
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(path), in a repository the sandbox made, sets \(badKeys.joined(separator: ", "))."
            }
        }
        return nil
    }

    func judgeHostCommand(cwd: String?, command: String, paths: IrisPaths = .default) -> HostDecision {
        lock.lock(); defer { lock.unlock() }
        var targetDirs: [String] = []
        if let cwd { targetDirs.append(cwd) }
        targetDirs.append(contentsOf: Self.extractGitCPaths(command: command, cwd: cwd))

        var reposToCheck: [(worktree: String, commonDir: String)] = []
        var seenWorktrees = Set<String>()
        for dir in targetDirs {
            if let repo = Self.findNearestGit(from: dir) {
                if seenWorktrees.insert(IrisPaths.realPath(repo.worktree)).inserted {
                    reposToCheck.append(repo)
                }
            }
        }

        func isInsideMounted(_ path: String) -> Bool {
            let real = IrisPaths.realPath(path)
            return mountedPaths.contains { mount in
                let mountReal = IrisPaths.realPath(mount)
                return real == mountReal || real.hasPrefix(mountReal.hasSuffix("/") ? mountReal : mountReal + "/")
            }
        }

        var notices: [String] = []
        var hasUntrusted = false

        for repo in reposToCheck {
            let inScope = unknownFolders || isInsideMounted(repo.worktree)
            guard inScope else { continue }
            if Self.isTrusted(commonDir: repo.commonDir, paths: paths) { continue }

            // Untrusted repository!
            hasUntrusted = true
            if let refusal = Self.judgeUntrustedRepo(worktree: repo.worktree, commonDir: repo.commonDir) {
                return .refuse(refusal, notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
            }
            if let note = noticeForRepoLocked(repo.worktree) {
                notices.append(note)
            }
        }

        let combinedNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        if hasUntrusted {
            return .noHooks(notice: combinedNotice)
        } else {
            return .ordinary(notice: combinedNotice)
        }
    }
}
