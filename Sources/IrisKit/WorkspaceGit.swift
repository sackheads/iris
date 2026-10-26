import Foundation

/// Git repository layout, submodule discovery, and path helpers for sandboxed mounts (#623, #658).
/// A repository at the root of a read-write sandbox mount gets a VM-only git dir (`SandboxGit`)
/// and its host `.git` is mounted read-only; repositories without a sandbox copy are judged by
/// `GitConfigGuard` before host commands run.
enum WorkspaceGit {
    /// Where the repository at `source` keeps what git reads. `dotGit` is `<source>/.git`, a
    /// directory, or for a worktree a file naming its `gitDir`; `commonDir` holds the shared
    /// config and hooks (the same as `gitDir` outside a worktree).
    struct Layout: Equatable {
        var dotGitIsFile: Bool
        var gitDir: String
        var commonDir: String
        var hooks: String { (commonDir as NSString).appendingPathComponent("hooks") }
    }

    enum Entry: Equatable {
        case none
        case layout(Layout)
        /// `.git` is a symbolic link or something else Iris will not follow.
        case unsupported
    }

    static func entry(at source: String) -> Entry {
        let dotGit = (source as NSString).appendingPathComponent(".git")
        var info = stat()
        guard lstat(dotGit, &info) == 0 else { return .none }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return .layout(Layout(dotGitIsFile: false, gitDir: dotGit, commonDir: dotGit))
        case S_IFREG:
            guard let text = readSmall(dotGit).flatMap({ String(data: $0, encoding: .utf8) }),
                  let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return .unsupported }
            let gitDir = resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), against: source)
            var commonDir = gitDir
            if let named = readSmall((gitDir as NSString).appendingPathComponent("commondir"))
                .flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
                commonDir = resolve(named, against: gitDir)
            }
            return .layout(Layout(dotGitIsFile: true, gitDir: gitDir, commonDir: commonDir))
        default:
            return .unsupported
        }
    }

    /// The git dirs of the submodules under `commonDir/modules` that exist now: each folder there
    /// holding a `HEAD`, searched to a bounded depth (a module's path may have several parts, and
    /// a submodule its own `modules/`).
    static func modules(commonDir: String) -> [String] {
        var found: [String] = []
        func walk(_ dir: String, depth: Int) {
            guard depth < 8, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() {
                let path = (dir as NSString).appendingPathComponent(name)
                var info = stat()
                guard !name.contains(quarantineSuffix), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("HEAD")) {
                    found.append(path)
                    walk((path as NSString).appendingPathComponent("modules"), depth: depth + 1)
                } else {
                    walk(path, depth: depth + 1)
                }
            }
        }
        walk((commonDir as NSString).appendingPathComponent("modules"), depth: 0)
        return found
    }

    /// The folders of the worktrees linked to `commonDir`, read from each `worktrees/<n>/gitdir`.
    /// Their git reads the common config too, wherever they are.
    static func linkedWorktrees(commonDir: String) -> [String] {
        let worktrees = (commonDir as NSString).appendingPathComponent("worktrees")
        return ((try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? []).compactMap { name in
            guard let text = readSmall((worktrees as NSString).appendingPathComponent(name + "/gitdir"))
                .flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix("/") else { return nil }
            return (text as NSString).deletingLastPathComponent
        }
    }

    // MARK: Submodules

    /// What a submodule moved aside is renamed with (#623 2b): never deleted, so a person who
    /// trusts it can rename it back.
    static let quarantineSuffix = ".iris-quarantine"

    /// The index is read only up to this; a larger one fails the check closed.
    static let indexLimit = 128 << 20

    /// The submodule paths (gitlinks) in the index at `path`, read without running git: versions
    /// 2 to 4, SHA-1 or SHA-256 object names. `[]` when there is no index; nil when it is too
    /// large or does not parse, which the caller treats as a failed check.
    static func gitlinks(index path: String, sha256: Bool, followLink: Bool = true) -> [String]? {
        var info = stat()
        if lstat(path, &info) != 0 { return errno == ENOENT ? [] : nil }
        guard let data = readSmall(path, limit: indexLimit) else { return nil }
        let b = [UInt8](data)
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= b.count else { return nil }
            return UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
        }
        guard b.count >= 12, b[0] == 0x44, b[1] == 0x49, b[2] == 0x52, b[3] == 0x43,
              let version = u32(4), (2...4).contains(version), let count = u32(8) else { return nil }
        let oid = sha256 ? 32 : 20
        var at = 12
        var previous: [UInt8] = []
        var links: [String] = []
        for _ in 0..<count {
            guard let mode = u32(at + 24), at + 40 + oid + 2 <= b.count else { return nil }
            let flags = Int(b[at + 40 + oid]) << 8 | Int(b[at + 40 + oid + 1])
            var fixed = 40 + oid + 2
            if flags & 0x4000 != 0 { guard version >= 3 else { return nil }; fixed += 2 }
            var p = at + fixed
            var name: [UInt8]
            if version == 4 {
                // Prefix-compressed: how many bytes of the previous name to drop, then the rest.
                guard p < b.count else { return nil }
                var c = b[p]; p += 1
                var strip = Int(c & 0x7f)
                while c & 0x80 != 0 {
                    guard p < b.count, strip < 1 << 24 else { return nil }
                    c = b[p]; p += 1
                    strip = ((strip + 1) << 7) | Int(c & 0x7f)
                }
                guard strip <= previous.count, let end = b[p...].firstIndex(of: 0) else { return nil }
                name = Array(previous.dropLast(strip)) + b[p..<end]
                at = end + 1
            } else {
                guard p <= b.count, let end = b[p...].firstIndex(of: 0) else { return nil }
                name = Array(b[p..<end])
                // Padded with 1 to 8 NULs to a multiple of 8.
                at += (fixed + name.count + 8) & ~7
                guard at <= b.count else { return nil }
            }
            previous = name
            if mode & 0o170000 == 0o160000 {
                guard let text = String(bytes: name, encoding: .utf8) else { return nil }
                links.append(text)
            }
        }
        // Extensions, up to the trailing checksum. A split index (`link`) keeps most entries in
        // `sharedindex.<oid>` beside it, so its gitlinks are read too; one that cannot be is a
        // failed read (#632 review: a split index hid a planted submodule).
        while at + 8 <= b.count - oid {
            guard let size = u32(at + 4), at + 8 + Int(size) <= b.count - oid else { return nil }
            if b[at] == 0x6c, b[at + 1] == 0x69, b[at + 2] == 0x6e, b[at + 3] == 0x6b {   // "link"
                guard followLink, size >= oid else { return nil }
                let hex = b[(at + 8)..<(at + 8 + oid)].map { String(format: "%02x", $0) }.joined()
                let shared = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("sharedindex." + hex)
                var info = stat()
                guard lstat(shared, &info) == 0, let more = gitlinks(index: shared, sha256: sha256, followLink: false) else { return nil }
                links += more.filter { !links.contains($0) }
            }
            at += 8 + Int(size)
        }
        return links
    }


    /// Whether `command` names `path` as a whole path: followed by its end, `/`, or a character
    /// that cannot continue a file name in a shell word, so `/x/iris` is not `/x/iris-overseer`.
    static func commandNames(_ command: String, _ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var rest = command[...]
        while let range = rest.range(of: path) {
            let next = rest[range.upperBound...].first
            if next.map({ !($0.isLetter || $0.isNumber || "-_.~+@".contains($0)) }) ?? true { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }

    /// A repository-relative path that stays inside it: no `..`, no empty part, no `.git`.
    static func isPlainRelative(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !parts.isEmpty
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }
    }

    /// Where git reads the person's global config from, including any files those configs include
    /// via `include.path` or `includeIf.<condition>.path`.
    static func globalConfigFiles(base: [String: String]) -> [String] {
        let home = base["HOME"] ?? NSHomeDirectory()
        let xdg = base["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".config")
        var roots = [(home as NSString).appendingPathComponent(".gitconfig"), (xdg as NSString).appendingPathComponent("git/config")]
        if let envGlobal = base["GIT_CONFIG_GLOBAL"], !envGlobal.isEmpty, envGlobal != "/dev/null" {
            roots.append(envGlobal)
        }
        return expandConfigIncludes(roots, home: home)
    }

    /// Where git reads system-wide configuration from, including any files those configs include.
    static func systemConfigFiles(base: [String: String]) -> [String] {
        let home = base["HOME"] ?? NSHomeDirectory()
        var roots = [
            "/etc/gitconfig",
            "/private/etc/gitconfig",
            "/opt/homebrew/etc/gitconfig",
            "/usr/local/etc/gitconfig",
            "/Library/Developer/CommandLineTools/usr/etc/gitconfig"
        ]
        if let envSystem = base["GIT_CONFIG_SYSTEM"], !envSystem.isEmpty, envSystem != "/dev/null" {
            roots.append(envSystem)
        }
        for entry in (base["PATH"] ?? "").split(separator: ":").map(String.init) where entry.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: entry).deletingLastPathComponent().appendingPathComponent("etc/gitconfig").standardized.path
            if !roots.contains(candidate) {
                roots.append(candidate)
            }
        }
        return expandConfigIncludes(roots, home: home)
    }

    /// Follows `include.path` and `includeIf.<cond>.path` entries in existing config files.
    private static func expandConfigIncludes(_ roots: [String], home: String) -> [String] {
        var result: [String] = []
        var queue = roots
        var seen: Set<String> = []
        while !queue.isEmpty, result.count < 32 {
            let file = queue.removeFirst()
            guard seen.insert(file).inserted else { continue }
            result.append(file)
            guard let data = readSmall(file), let entries = GitConfigFile.parse(data) else { continue }
            let dir = (file as NSString).deletingLastPathComponent
            for entry in entries {
                guard entry.key == "include.path" || (entry.key.hasPrefix("includeif.") && entry.key.hasSuffix(".path")),
                      let raw = entry.value, !raw.isEmpty else { continue }
                let resolved: String
                if raw.hasPrefix("~/") {
                    resolved = resolve(String(raw.dropFirst(2)), against: home)
                } else {
                    resolved = resolve(raw, against: dir)
                }
                if !seen.contains(resolved) {
                    queue.append(resolved)
                }
            }
        }
        return result
    }

    /// git-lfs's own values, kept so LFS works in a repository whose drivers are checked. Matched
    /// on the exact value: `filter.lfs.clean = <anything else>` is judged like any other key.
    static let lfsValues: [String: String] = ["filter.lfs.clean": "git-lfs clean -- %f",
                                              "filter.lfs.smudge": "git-lfs smudge -- %f",
                                              "filter.lfs.process": "git-lfs filter-process",
                                              "filter.lfs.required": "true"]

    // MARK: Paths

    static func resolve(_ path: String, against base: String) -> String {
        let joined = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        // `URL.standardized`, not `standardizingPath`, which also drops a leading `/private`.
        return URL(fileURLWithPath: joined).standardized.path
    }

    /// `path` relative to `root` when it lies strictly inside it, comparing real paths, so a
    /// spelling through `/tmp` or `..` cannot step out.
    static func relative(_ path: String, inside root: String) -> String? {
        let realRoot = IrisPaths.realPath(root)
        let realPath = realParent(path)
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard realPath.hasPrefix(prefix) else { return nil }
        return String(realPath.dropFirst(prefix.count))
    }

    /// The real path of `path`'s parent joined to its last component: the file itself may be
    /// missing or a link, and is judged as itself.
    private static func realParent(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardized.path
        let parent = (standard as NSString).deletingLastPathComponent
        return (IrisPaths.realPath(parent) as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
    }

    static func readSmall(_ path: String, limit: Int = 1 << 20) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        return try? handle.readToEnd() ?? Data()
    }
}
