import CoreServices
import Foundation

/// The git config format, read to judge whether an untrusted repository's config is safe (#623, #658).
/// Strict: a file it cannot read in full is `nil`, and host commands there are refused.
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
        /// True when an earlier version recorded this folder as `blocked` or `adopted`, so it is
        /// judged as untrusted even if a `sandbox-git` copy exists for it.
        var untrusted: Bool = false
        /// True while a sandbox session is actively mounting this folder read-write; cleared at a
        /// clean session end so a crash or quit mid-session rescans and quarantines on next launch.
        var live: Bool = false

        init(path: String, untrusted: Bool = false, live: Bool = false) {
            self.path = path
            self.untrusted = untrusted
            self.live = live
        }

        enum CodingKeys: CodingKey {
            case path, untrusted, live, blocked, adopted
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            let explicit = try c.decodeIfPresent(Bool.self, forKey: .untrusted) ?? false
            let hasBlocked = (try? c.decodeNil(forKey: .blocked)) == false
            let hasAdopted = (try? c.decodeNil(forKey: .adopted)) == false
            untrusted = explicit || hasBlocked || hasAdopted
            live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            if untrusted {
                try c.encode(true, forKey: .untrusted)
            }
            if live {
                try c.encode(true, forKey: .live)
            }
        }
    }

    /// Weak reference box passed to `FSEventStreamContext` so streams do not create a retain cycle
    /// with `GitConfigGuard`.
    private final class WeakGuardBox: @unchecked Sendable {
        weak var owner: GitConfigGuard?
        let mount: String
        let paths: IrisPaths
        init(_ owner: GitConfigGuard, mount: String, paths: IrisPaths) {
            self.owner = owner
            self.mount = mount
            self.paths = paths
        }
    }

    private static let fsEventCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<WeakGuardBox>.fromOpaque(info).takeUnretainedValue()
        guard let owner = box.owner else { return }
        let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
        var flags: [FSEventStreamEventFlags] = []
        flags.reserveCapacity(numEvents)
        for i in 0..<numEvents {
            flags.append(eventFlags[i])
        }
        owner.handleFSEvents(mountReal: box.mount, eventPaths: paths, flags: flags, paths: box.paths)
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

    private static let fsQueueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private let flushLock = NSLock()
    private let fsQueue: DispatchQueue = {
        let q = DispatchQueue(label: "com.iris.gitguard.fsevents")
        q.setSpecific(key: GitConfigGuard.fsQueueKey, value: true)
        return q
    }()
    private let store: URL?
    private var mountedPaths: Set<String> = []
    private var untrustedPaths: Set<String> = []
    private var livePaths: Set<String> = []
    private var baselineRepos: Set<String> = []
    private var baselineEntryCount: [String: Int] = [:]
    private var quarantinedUnderMount: [String: [String: String]] = [:]
    private var unverifiedMounts: [String: String] = [:]
    private var pendingNotices: [String] = []
    private var streams: [String: FSEventStreamRef] = [:]
    private var unknownFolders = false
    private var corruptCopies: [String] = []
    private var loadNote: String?
    private var saveDisabled = false
    private var seenUntrustedRepos: Set<String> = []

    var isUnknownFolders: Bool { lock.lock(); defer { lock.unlock() }; return unknownFolders }
    var mountedWorkspaces: [String] { lock.lock(); defer { lock.unlock() }; return mountedPaths.sorted() }

    init(store: URL? = nil, paths: IrisPaths = .default) {
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
        var liveCleaned = false
        for item in saved {
            if item.live {
                var st = stat()
                if lstat(item.path, &st) != 0 && errno == ENOENT {
                    // A live mount from a crashed session that no longer exists on disk is dropped silently.
                    liveCleaned = true
                    continue
                }
            }
            let real = IrisPaths.realPath(item.path)
            mountedPaths.insert(real)
            if item.untrusted {
                untrustedPaths.insert(real)
            }
            if item.live {
                // Only the mount root itself (if a repository) was baseline; any nested repository
                // planted before the crash is scanned and quarantined now before any host spawn.
                if WorkspaceGit.entry(at: real) != .none || WritingScripts.isBareRepository(real) {
                    baselineRepos.insert(real)
                }
                _ = scanAndQuarantineMountLocked(real, paths: paths)
                liveCleaned = true
            } else {
                recordBaselineLocked(real)
            }
        }
        if liveCleaned {
            save()
        }
    }

    deinit {
        for stream in streams.values {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static let unknownFoldersNote = " While the unreadable list is kept, git that Iris runs on your Mac checks every repository it reaches, runs no hooks in any without a sandbox copy, and ignores your global git config."

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
        let items = mountedPaths.sorted().map {
            MountedWorkspace(path: $0, untrusted: untrustedPaths.contains($0), live: livePaths.contains($0))
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }

    private func recordBaselineLocked(_ mountReal: String) {
        var st = stat()
        guard lstat(mountReal, &st) == 0 else { return }
        let survey = WritingScripts.survey(mountReal)
        baselineEntryCount[mountReal] = survey.entries
        for repo in survey.repositories {
            baselineRepos.insert(IrisPaths.realPath(repo))
            if let found = Self.findNearestGit(from: repo) {
                baselineRepos.insert(IrisPaths.realPath(found.worktree))
                baselineRepos.insert(IrisPaths.realPath(found.commonDir))
            }
        }
    }

    private func startWatchingLocked(_ mountReal: String, paths: IrisPaths) {
        guard streams[mountReal] == nil else { return }
        var st = stat()
        guard lstat(mountReal, &st) == 0 else { return }
        let box = WeakGuardBox(self, mount: mountReal, paths: paths)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<WeakGuardBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.fsEventCallback,
            &context,
            [mountReal] as CFArray,
            FSEventsGetCurrentEventId(),
            0.05,
            flags
        ) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, fsQueue)
        if FSEventStreamStart(stream) {
            streams[mountReal] = stream
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func flushStreams() {
        guard DispatchQueue.getSpecific(key: Self.fsQueueKey) == nil else { return }
        flushLock.lock(); defer { flushLock.unlock() }
        let active: [FSEventStreamRef] = {
            lock.lock(); defer { lock.unlock() }
            return Array(streams.values)
        }()
        for stream in active {
            FSEventStreamFlushSync(stream)
        }
    }

    private func stopWatching(sources: [String]) {
        guard DispatchQueue.getSpecific(key: Self.fsQueueKey) == nil else { return }
        flushLock.lock(); defer { flushLock.unlock() }
        var toStop: [FSEventStreamRef] = []
        lock.lock()
        for source in sources {
            let real = IrisPaths.realPath(source)
            if let stream = streams.removeValue(forKey: real) {
                toStop.append(stream)
            }
        }
        lock.unlock()
        for stream in toStop {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func handleFSEvents(mountReal: String, eventPaths: [String], flags: [FSEventStreamEventFlags], paths: IrisPaths) {
        lock.lock(); defer { lock.unlock() }
        let mustRescan = flags.contains {
            ($0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)) != 0
        }
        if mustRescan || (baselineEntryCount[mountReal] ?? 0) <= 2_000 {
            _ = scanAndQuarantineMountLocked(mountReal, paths: paths)
            return
        }
        var checked = Set<String>()
        for rawPath in eventPaths {
            let evReal = IrisPaths.realPath(rawPath)
            guard evReal == mountReal || WorkspaceGit.relative(evReal, inside: mountReal) != nil else { continue }
            var current = evReal
            while true {
                if checked.insert(current).inserted {
                    if WorkspaceGit.entry(at: current) != .none || WritingScripts.isBareRepository(current) || GitRead.isGitDirectory(current) {
                        _ = inspectAndQuarantineRepoLocked(repoPath: current, mountReal: mountReal, paths: paths)
                    }
                }
                if current == mountReal || current == "/" { break }
                let parent = (current as NSString).deletingLastPathComponent
                if parent == current { break }
                current = parent
            }
            if evReal != mountReal {
                var st = stat()
                if lstat(evReal, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                   (evReal as NSString).lastPathComponent != ".git",
                   !(evReal as NSString).lastPathComponent.contains(WorkspaceGit.quarantineSuffix) {
                    let subSurvey = WritingScripts.survey(evReal)
                    if !subSurvey.isComplete {
                        unverifiedMounts[mountReal] = subSurvey.incomplete ?? "over \(WritingScripts.entryCap) entries or \(Int(WritingScripts.secondsCap)) seconds to walk"
                    } else {
                        for repo in subSurvey.repositories {
                            _ = inspectAndQuarantineRepoLocked(repoPath: repo, mountReal: mountReal, paths: paths)
                        }
                    }
                }
            }
        }
    }

    func recordMounted(sources: [String], paths: IrisPaths = .default) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for source in sources {
            let real = IrisPaths.realPath(source)
            if mountedPaths.insert(real).inserted {
                recordBaselineLocked(real)
                changed = true
            }
            if livePaths.insert(real).inserted {
                changed = true
            }
            startWatchingLocked(real, paths: paths)
        }
        if changed { save() }
    }

    /// Synchronously scans `sources` (or all mounted folders) and quarantines any unsafe VM-made
    /// repositories on disk, returning any quarantine notices generated.
    @discardableResult
    func scanAndQuarantine(sources: [String]? = nil, paths: IrisPaths = .default,
                           entryCap: Int = WritingScripts.entryCap,
                           secondsCap: Double = WritingScripts.secondsCap) -> [String] {
        flushStreams()
        lock.lock(); defer { lock.unlock() }
        let targets = (sources?.map(IrisPaths.realPath)) ?? mountedPaths.sorted()
        var notes: [String] = []
        for real in targets {
            notes += scanAndQuarantineMountLocked(real, paths: paths, entryCap: entryCap, secondsCap: secondsCap)
        }
        if !pendingNotices.isEmpty {
            let drained = pendingNotices
            pendingNotices.removeAll()
            for note in drained where !notes.contains(note) {
                notes.insert(note, at: 0)
            }
        }
        return notes
    }

    /// Ends the live session on `sources`: flushes FSEvents, runs a final capped scan and
    /// quarantine, stops the FSEvents stream, clears the durable `live` mark, and saves.
    @discardableResult
    func endMounted(sources: [String], paths: IrisPaths = .default) -> [String] {
        let notes = scanAndQuarantine(sources: sources, paths: paths)
        stopWatching(sources: sources)
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for source in sources {
            let real = IrisPaths.realPath(source)
            if livePaths.remove(real) != nil {
                changed = true
            }
        }
        if changed { save() }
        return notes
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

    static func isTrusted(worktree: String = "", commonDir: String, mountedPaths: Set<String> = [],
                          untrustedPaths: Set<String> = [], paths: IrisPaths = .default) -> Bool {
        let canonicalCommon = IrisPaths.realPath(commonDir)
        let key = SandboxGit.key(canonicalCommon)
        let markerPath = ((SandboxGit.directory(paths: paths) as NSString).appendingPathComponent(key) as NSString)
            .appendingPathComponent(SandboxGit.seedMarker)
        guard let data = WorkspaceGit.readSmall(markerPath),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first,
              String(firstLine) == canonicalCommon else {
            return false
        }
        guard !worktree.isEmpty else { return true }
        let canonicalWorktree = IrisPaths.realPath(worktree)
        for untrusted in untrustedPaths {
            let u = IrisPaths.realPath(untrusted)
            if canonicalWorktree == u || WorkspaceGit.relative(canonicalWorktree, inside: u) != nil
                || canonicalCommon == u || WorkspaceGit.relative(canonicalCommon, inside: u) != nil {
                return false
            }
        }
        // A sandbox copy protects only a repository at the root of a mount (`mount == worktree`).
        // Any mount strictly containing the worktree, or containing its commonDir when not equal to
        // the worktree, exposed `.git` read-write without the root overlay (#773 H1).
        for mount in mountedPaths {
            let m = IrisPaths.realPath(mount)
            if m != canonicalWorktree {
                if WorkspaceGit.relative(canonicalWorktree, inside: m) != nil { return false }
                if canonicalCommon == m || WorkspaceGit.relative(canonicalCommon, inside: m) != nil { return false }
            }
        }
        return true
    }

    static func findNearestGit(from dir: String) -> (worktree: String, commonDir: String)? {
        var current = IrisPaths.realPath(dir)
        var visited = Set<String>()
        while true {
            visited.insert(current)
            if (current as NSString).lastPathComponent == ".git" {
                let parent = (current as NSString).deletingLastPathComponent
                if parent != current {
                    switch WorkspaceGit.entry(at: parent) {
                    case .layout(let layout):
                        return (worktree: parent, commonDir: IrisPaths.realPath(layout.commonDir))
                    case .unsupported:
                        return (worktree: parent, commonDir: current)
                    case .none:
                        break
                    }
                }
            }
            switch WorkspaceGit.entry(at: current) {
            case .layout(let layout):
                return (worktree: current, commonDir: IrisPaths.realPath(layout.commonDir))
            case .unsupported:
                return (worktree: current, commonDir: IrisPaths.realPath((current as NSString).appendingPathComponent(".git")))
            case .none:
                break
            }
            if GitRead.isGitDirectory(current) {
                var commonDir = current
                if let named = WorkspaceGit.readSmall((current as NSString).appendingPathComponent("commondir"))
                    .flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
                    commonDir = WorkspaceGit.resolve(named, against: current)
                }
                return (worktree: current, commonDir: IrisPaths.realPath(commonDir))
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || visited.contains(parent) || current == "/" {
                break
            }
            current = parent
        }
        return nil
    }

    static func extractGitCPaths(command: String, cwd: String?, mountedPaths: Set<String> = []) -> [String] {
        var raw: [String] = []
        let patterns = [
            #"(?:^|[\s;&|(`'"])(?:-C|--git-dir|--work-tree|cd|pushd)\s+(?:'([^']+)'|"([^"]+)"|([^\s;&|)`"']+))"#,
            #"(?:^|[\s;&|(`'"])(?:--git-dir|--work-tree|GIT_DIR|GIT_WORK_TREE)=(?:'([^']+)'|"([^"]+)"|([^\s;&|)`"']+))"#
        ]
        let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: command, range: fullRange) {
                for group in 1...3 {
                    if let r = Range(match.range(at: group), in: command) {
                        raw.append(String(command[r]))
                        break
                    }
                }
            }
        }

        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"`;&|()<>$" ))
        for mount in mountedPaths.sorted() {
            for spelling in Set([mount, IrisPaths.realPath(mount)]) where !spelling.isEmpty {
                if WorkspaceGit.commandNames(command, spelling) {
                    raw.append(spelling)
                }
                var search = command[...]
                while let range = search.range(of: spelling) {
                    let tail = search[range.lowerBound...]
                    let end = tail.firstIndex { c in
                        c.unicodeScalars.contains { delimiters.contains($0) }
                    } ?? tail.endIndex
                    let candidate = String(tail[..<end])
                    if candidate == spelling || candidate.hasPrefix(spelling.hasSuffix("/") ? spelling : spelling + "/") {
                        raw.append(candidate)
                    }
                    search = search[range.upperBound...]
                }
            }
        }

        var resolved: [String] = []
        var bases: [String] = []
        if let cwd { bases.append(cwd) }
        for item in raw {
            if item.hasPrefix("/") {
                resolved.append(item)
                bases.append(item)
            } else {
                var nextBases: [String] = []
                for base in bases {
                    let joined = (base as NSString).appendingPathComponent(item)
                    resolved.append(joined)
                    nextBases.append(joined)
                }
                bases.append(contentsOf: nextBases)
                for mount in mountedPaths.sorted() {
                    resolved.append((mount as NSString).appendingPathComponent(item))
                }
                if bases.isEmpty && mountedPaths.isEmpty {
                    resolved.append(item)
                }
            }
        }
        return resolved
    }

    static func judgeConfigFile(path: String, allowInitDefaults: Bool = true) -> String? {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(path) cannot be read."
        }
        guard info.st_mode & S_IFMT == S_IFREG, let data = WorkspaceGit.readSmall(path),
              let entries = GitConfigFile.parse(data) else {
            return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(path) cannot be read."
        }
        var values: [String: [String]] = [:]
        for e in entries {
            values[e.key, default: []].append(e.value ?? "\u{0}")
        }
        var badKeys: [String] = []
        for key in values.keys.sorted() {
            let vals = values[key]!
            if allowInitDefaults && initDefaults.contains(key) { continue }
            if GitConfigFile.isAllowed(key: key, values: vals) { continue }
            if let lfsExpected = WorkspaceGit.lfsValues[key], vals.allSatisfy({ $0 == lfsExpected }) { continue }
            badKeys.append(key)
        }
        if !badKeys.isEmpty {
            return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(path) sets \(badKeys.joined(separator: ", "))."
        }
        return nil
    }

    static func judgeUntrustedRepo(worktree: String, commonDir: String) -> String? {
        var configPaths: [String] = []
        let common = commonDir as NSString
        configPaths.append(common.appendingPathComponent("config"))
        configPaths.append(common.appendingPathComponent("config.worktree"))
        var gitDir = commonDir
        if case .layout(let layout) = WorkspaceGit.entry(at: worktree) {
            gitDir = layout.gitDir
            if layout.dotGitIsFile {
                configPaths.append((layout.gitDir as NSString).appendingPathComponent("config.worktree"))
            }
        }
        let indexPath = (gitDir as NSString).appendingPathComponent("index")
        if WorkspaceGit.gitlinks(index: indexPath, sha256: false) == nil,
           WorkspaceGit.gitlinks(index: indexPath, sha256: true) == nil {
            return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(indexPath) cannot be read."
        }
        for module in WorkspaceGit.modules(commonDir: commonDir) {
            configPaths.append((module as NSString).appendingPathComponent("config"))
        }
        let worktreesDir = common.appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktreesDir)) ?? [] {
            configPaths.append(((worktreesDir as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("config.worktree"))
        }

        for path in configPaths {
            if let refusal = judgeConfigFile(path: path, allowInitDefaults: true) {
                return refusal
            }
        }
        return nil
    }

    /// Checks `<commonDir>/hooks`, `<gitDir>/hooks`, `<module>/hooks`, and `<worktrees>/*/hooks`
    /// for any executable file other than `*.sample` (or any symbolic link).
    static func judgeExecutableHooks(worktree: String, commonDir: String) -> String? {
        var hookDirs: [String] = [(commonDir as NSString).appendingPathComponent("hooks")]
        if case .layout(let layout) = WorkspaceGit.entry(at: worktree) {
            let gitHooks = (layout.gitDir as NSString).appendingPathComponent("hooks")
            if !hookDirs.contains(gitHooks) {
                hookDirs.append(gitHooks)
            }
        }
        for module in WorkspaceGit.modules(commonDir: commonDir) {
            hookDirs.append((module as NSString).appendingPathComponent("hooks"))
        }
        let worktreesDir = (commonDir as NSString).appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktreesDir)) ?? [] {
            hookDirs.append((((worktreesDir as NSString).appendingPathComponent(name)) as NSString).appendingPathComponent("hooks"))
        }
        for dir in hookDirs {
            var dirInfo = stat()
            if lstat(dir, &dirInfo) != 0 {
                if errno == ENOENT { continue }
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(dir) cannot be read."
            }
            if (dirInfo.st_mode & S_IFMT) == S_IFLNK {
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(dir) is a symbolic link."
            }
            guard (dirInfo.st_mode & S_IFMT) == S_IFDIR,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(dir) cannot be read."
            }
            for name in names.sorted() {
                if name.hasSuffix(".sample") || name.contains(WorkspaceGit.quarantineSuffix) { continue }
                let hookPath = (dir as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(hookPath, &info) == 0 else {
                    return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(hookPath) cannot be read."
                }
                let fmt = info.st_mode & S_IFMT
                if fmt == S_IFLNK || (fmt == S_IFREG && (info.st_mode & 0o111) != 0) {
                    return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(hookPath) is an executable hook."
                }
            }
        }
        return nil
    }

    private func inspectAndQuarantineRepoLocked(repoPath: String, mountReal: String, paths: IrisPaths) -> String? {
        let wtReal = IrisPaths.realPath(repoPath)
        let commonDir: String
        var pointerFailure: String?
        switch WorkspaceGit.entry(at: repoPath) {
        case .layout(let layout):
            commonDir = IrisPaths.realPath(layout.commonDir)
            if layout.dotGitIsFile {
                let gitDirReal = IrisPaths.realPath(layout.gitDir)
                let inWorktree = WorkspaceGit.relative(gitDirReal, inside: wtReal) != nil
                    && WorkspaceGit.relative(commonDir, inside: wtReal) != nil
                let inMountModules = (WorkspaceGit.relative(gitDirReal, inside: mountReal) != nil
                    && WorkspaceGit.relative(commonDir, inside: mountReal) != nil
                    && gitDirReal.contains("/.git/modules/"))
                if !inWorktree && !inMountModules {
                    pointerFailure = "Not run: git on your Mac would read a repository the sandbox left unsafe. \(repoPath)/.git points outside its repository."
                }
            }
        case .unsupported:
            commonDir = IrisPaths.realPath((repoPath as NSString).appendingPathComponent(".git"))
            pointerFailure = "Not run: git on your Mac would read a repository the sandbox left unsafe. \(repoPath)/.git is not a supported git folder."
        case .none:
            guard WritingScripts.isBareRepository(repoPath) || GitRead.isGitDirectory(repoPath) else {
                return nil
            }
            var resolvedCommon = repoPath
            if let named = WorkspaceGit.readSmall((repoPath as NSString).appendingPathComponent("commondir"))
                .flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
                resolvedCommon = WorkspaceGit.resolve(named, against: repoPath)
                let resolvedReal = IrisPaths.realPath(resolvedCommon)
                if resolvedReal != wtReal && WorkspaceGit.relative(resolvedReal, inside: wtReal) == nil {
                    pointerFailure = "Not run: git on your Mac would read a repository the sandbox left unsafe. \(repoPath)/commondir points outside its repository."
                }
            }
            commonDir = IrisPaths.realPath(resolvedCommon)
        }

        if baselineRepos.contains(wtReal) || baselineRepos.contains(commonDir) {
            return nil
        }
        if Self.isTrusted(worktree: repoPath, commonDir: commonDir,
                          mountedPaths: mountedPaths, untrustedPaths: untrustedPaths, paths: paths) {
            return nil
        }
        if case .layout(let rootLayout) = WorkspaceGit.entry(at: mountReal),
           Self.isTrusted(worktree: mountReal, commonDir: rootLayout.commonDir,
                          mountedPaths: mountedPaths, untrustedPaths: untrustedPaths, paths: paths) {
            let rootModules = (IrisPaths.realPath(rootLayout.commonDir) as NSString).appendingPathComponent("modules")
            if WorkspaceGit.relative(commonDir, inside: rootModules) != nil, pointerFailure == nil {
                return nil
            }
        }

        var failureReason = pointerFailure
        if failureReason == nil {
            let problems = SandboxGit.pointerProblems(source: repoPath, commonDir: commonDir)
            if !problems.isEmpty {
                failureReason = "Not run: git on your Mac would read a repository the sandbox left unsafe. \(repoPath) holds a .git pointer outside its repository."
            }
        }
        if failureReason == nil {
            failureReason = Self.judgeUntrustedRepo(worktree: repoPath, commonDir: commonDir)
        }
        if failureReason == nil {
            failureReason = Self.judgeExecutableHooks(worktree: repoPath, commonDir: commonDir)
        }
        guard let reason = failureReason else {
            return nil
        }
        if let moved = SandboxGit.quarantineRepository(worktree: repoPath, commonDir: commonDir, mountRoot: mountReal) {
            quarantinedUnderMount[mountReal, default: [:]][moved] = reason
            let note = "[sandbox] Quarantined unsafe git repository at \(repoPath) (moved to \(moved)): \(reason)"
            if !pendingNotices.contains(note) {
                pendingNotices.append(note)
            }
            return note
        } else {
            unverifiedMounts[mountReal] = reason
            return nil
        }
    }

    private func scanAndQuarantineMountLocked(_ mountReal: String, paths: IrisPaths = .default,
                                              entryCap: Int = WritingScripts.entryCap,
                                              secondsCap: Double = WritingScripts.secondsCap) -> [String] {
        var st = stat()
        guard lstat(mountReal, &st) == 0 else { return [] }
        let survey = WritingScripts.survey(mountReal, entryCap: entryCap, secondsCap: secondsCap)
        if !survey.isComplete {
            unverifiedMounts[mountReal] = survey.incomplete ?? "over \(entryCap) entries or \(Int(secondsCap)) seconds to walk"
            return []
        }
        unverifiedMounts.removeValue(forKey: mountReal)
        var notes: [String] = []
        for repo in survey.repositories {
            if let note = inspectAndQuarantineRepoLocked(repoPath: repo, mountReal: mountReal, paths: paths) {
                notes.append(note)
            }
        }
        return notes
    }

    /// Whether the person's global git config is in a folder a sandbox could have written (or the
    /// list of mounted folders is unreadable), so host commands should not read it.
    func globalConfigInReach(base: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return globalConfigInReachLocked(base: base)
    }

    private func globalConfigInReachLocked(base: [String: String]) -> Bool {
        if unknownFolders { return true }
        return WorkspaceGit.globalConfigFiles(base: base).contains { isInsideMountedLocked($0) }
    }

    /// Whether the system git config is in a folder a sandbox could have written (or the list of
    /// mounted folders is unreadable), so host commands should set `GIT_CONFIG_NOSYSTEM=1`.
    func systemConfigInReach(base: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return systemConfigInReachLocked(base: base)
    }

    private func systemConfigInReachLocked(base: [String: String]) -> Bool {
        if unknownFolders { return true }
        return WorkspaceGit.systemConfigFiles(base: base).contains { isInsideMountedLocked($0) }
    }

    /// Applies the `GIT_CONFIG_*` overrides for `decision` and any reachable global/system config to `env`.
    func applyEnvironment(decision: HostDecision, base: [String: String] = ProcessInfo.processInfo.environment,
                          to env: inout [String: String], preserveExistingCount: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if case .noHooks = decision, !preserveExistingCount {
            for key in env.keys where key.hasPrefix("GIT_CONFIG_") { env[key] = nil }
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "core.hooksPath"
            env["GIT_CONFIG_VALUE_0"] = "/dev/null"
        }
        if globalConfigInReachLocked(base: base) {
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        }
        if systemConfigInReachLocked(base: base) {
            env["GIT_CONFIG_NOSYSTEM"] = "1"
        }
    }

    private func isInsideMountedLocked(_ path: String) -> Bool {
        let real = IrisPaths.realPath(path)
        return mountedPaths.contains { mount in
            let mountReal = IrisPaths.realPath(mount)
            return real == mountReal || WorkspaceGit.relative(path, inside: mountReal) != nil
        }
    }

    /// Child directories up to depth 2 under `root` for discovering nested repositories when `root`
    /// itself is not inside a repository.
    private static func childDirectories(under root: String, limit: Int = 32) -> [String] {
        var result: [String] = []
        func walk(_ dir: String, depth: Int) {
            guard depth < 2, result.count < limit,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                guard result.count < limit else { break }
                let full = (dir as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                result.append(full)
                walk(full, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return result
    }

    func judgeHostCommand(cwd: String?, command: String, paths: IrisPaths = .default,
                          base: [String: String] = ProcessInfo.processInfo.environment) -> HostDecision {
        flushStreams()
        lock.lock(); defer { lock.unlock() }

        for mount in mountedPaths.sorted() {
            if streams[mount] == nil || (baselineEntryCount[mount] ?? 0) <= 2_000 {
                _ = scanAndQuarantineMountLocked(mount, paths: paths)
            }
        }

        var notices: [String] = []
        if !pendingNotices.isEmpty {
            notices.append(contentsOf: pendingNotices)
            pendingNotices.removeAll()
        }

        var targetDirs: [String] = []
        if let cwd { targetDirs.append(cwd) }
        let resolveBase = cwd ?? FileManager.default.currentDirectoryPath
        if let gitDir = base["GIT_DIR"], !gitDir.isEmpty {
            targetDirs.append(WorkspaceGit.resolve(gitDir, against: resolveBase))
        }
        if let workTree = base["GIT_WORK_TREE"], !workTree.isEmpty {
            targetDirs.append(WorkspaceGit.resolve(workTree, against: resolveBase))
        }
        targetDirs.append(contentsOf: Self.extractGitCPaths(command: command, cwd: cwd, mountedPaths: mountedPaths))

        let cwdReal = cwd.map(IrisPaths.realPath)
        var hasUntrusted = false

        for mount in mountedPaths.sorted() {
            let mountReal = IrisPaths.realPath(mount)
            let cwdInMount = cwdReal.map { $0 == mountReal || WorkspaceGit.relative($0, inside: mountReal) != nil } ?? true
            let cwdIsImmediateParent = cwdReal.map {
                (mountReal as NSString).deletingLastPathComponent == $0 && $0 != "/"
            } ?? false
            let targetReachesMount = targetDirs.contains { dir in
                let dReal = IrisPaths.realPath(dir)
                return dReal == mountReal || WorkspaceGit.relative(dReal, inside: mountReal) != nil
            }
            let activeQuarantined = (quarantinedUnderMount[mountReal] ?? [:]).keys.contains { qPath in
                var st = stat()
                return lstat(qPath, &st) == 0
            }
            let mountIsRootRepo = Self.findNearestGit(from: mountReal).map { IrisPaths.realPath($0.worktree) == mountReal } ?? false

            if cwdInMount || targetReachesMount || (cwdIsImmediateParent && (mountIsRootRepo || unverifiedMounts[mountReal] != nil || activeQuarantined)) {
                if let unverified = unverifiedMounts[mountReal] {
                    let msg = unverified.hasPrefix("Not run:")
                        ? unverified
                        : "Not run: \(mountReal) cannot be checked for unsafe git repositories (\(unverified))."
                    return .refuse(msg, notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
                }
                if activeQuarantined {
                    hasUntrusted = true
                }
                targetDirs.append(mountReal)
            }
        }

        var reposToCheck: [(worktree: String, commonDir: String)] = []
        var seenWorktrees = Set<String>()
        func addRepo(_ repo: (worktree: String, commonDir: String)) {
            if seenWorktrees.insert(IrisPaths.realPath(repo.worktree)).inserted {
                reposToCheck.append(repo)
            }
        }
        for dir in targetDirs {
            if let repo = Self.findNearestGit(from: dir) {
                addRepo(repo)
            } else if isInsideMountedLocked(dir) || mountedPaths.contains(where: { WorkspaceGit.relative($0, inside: dir) != nil }) {
                for child in Self.childDirectories(under: dir) {
                    if let repo = Self.findNearestGit(from: child) {
                        addRepo(repo)
                    }
                }
            }
        }

        for repo in reposToCheck {
            let insideMount = isInsideMountedLocked(repo.worktree) || isInsideMountedLocked(repo.commonDir)
            let inScope = unknownFolders || insideMount
            guard inScope else { continue }
            if Self.isTrusted(worktree: repo.worktree, commonDir: repo.commonDir,
                              mountedPaths: mountedPaths, untrustedPaths: untrustedPaths, paths: paths) {
                continue
            }

            // Untrusted repository!
            hasUntrusted = true
            if insideMount {
                let pointerNotes = SandboxGit.quarantinePointers(source: repo.worktree, commonDir: repo.commonDir)
                if !pointerNotes.isEmpty {
                    notices.append("[sandbox] " + pointerNotes.joined(separator: " "))
                }
            }
            if !SandboxGit.pointerProblems(source: repo.worktree, commonDir: repo.commonDir).isEmpty {
                return .refuse("Not run: git on your Mac would read a repository the sandbox left unsafe. \(repo.worktree) holds a .git pointer outside its repository that Iris could not move aside.",
                               notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
            }
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
