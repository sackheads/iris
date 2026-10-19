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

    /// The keys a change from `old` to `new` touched that it may not: everything but a remote's
    /// URLs and fetch refspecs, a branch's upstream, and `user.*`, which in-VM `git remote`,
    /// `git push -u` and `git config user.email` write and which run nothing. A URL that names a
    /// transport helper (`ext::`, any `<helper>::`) or reads as an option is not allowed either.
    static func disallowedKeys(from old: [Entry], to new: [Entry]) -> [String] {
        func grouped(_ entries: [Entry]) -> [String: [String]] {
            var map: [String: [String]] = [:]
            for e in entries { map[e.key, default: []].append(e.value ?? "\u{0}") }
            return map
        }
        let before = grouped(old), after = grouped(new)
        var bad: [String] = []
        for key in Set(before.keys).union(after.keys).sorted() where before[key] != after[key] {
            if !isAllowed(key: key, values: after[key] ?? []) { bad.append(key) }
        }
        return bad
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

/// Keeps a sandboxed workspace's git config to what it was, except for the changes
/// `GitConfigFile.disallowedKeys` allows (#623). Each container that mounts a repository
/// read-write is watched from before it is created to after it is removed: its files are recorded
/// then, compared before and after every command in it and before every host command, and put
/// back byte for byte when a change could make host git run a program. Process-wide, behind a
/// lock, because session, one-off and host commands all reach it.
///
/// Best effort, and the host overrides (`WorkspaceGit.hostEnvironment`) are the cover for what it
/// misses: a background process left in the VM can write after a check, and that write stays until
/// the next command or the container ends, so git run outside Iris (the person's own terminal) can
/// read it meanwhile. A folder watch to close that window is #633.
final class GitConfigGuard: @unchecked Sendable {
    static let shared = GitConfigGuard(store: IrisPaths.default.configDir.appendingPathComponent("sandbox-workspaces.json"))

    /// One folder a sandbox has mounted read-write, kept across restarts so host git there keeps
    /// its overrides, and a repository the VM made stays untrusted, before any sandboxed command.
    struct MountedWorkspace: Codable, Equatable {
        var path: String
        /// The hooks folder of the repository that was there before any VM could write it.
        var hooks: String?
        /// Why host commands there were refused when Iris last ran, kept so a restart cannot
        /// take the bad state as a fresh baseline.
        var blocked: Block?

        init(path: String, hooks: String?, blocked: Block? = nil) { self.path = path; self.hooks = hooks; self.blocked = blocked }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            hooks = try c.decodeIfPresent(String.self, forKey: .hooks)
            blocked = try c.decodeIfPresent(Block.self, forKey: .blocked)
        }
    }

    /// Why a folder's host commands are refused: what failed, and where, so that after a restart
    /// (when no baseline survives) exactly that condition can be re-tested.
    struct Block: Codable, Equatable {
        enum Kind: String, Codable {
            /// A file could not be put back, or a folder on its way was swapped: clears when the
            /// file is a plain file again (or gone) and inside the mount.
            case restore
            /// A submodule's `.git` or module repository could not be moved aside: clears when
            /// it is gone.
            case quarantine
            /// The index could not be read: clears when it reads.
            case index
            /// A repository the VM made sets a key that runs a program: clears when it does not.
            case risky
            /// A file Iris could not read changed: clears when it is as it was (`detail`).
            case unreadable
        }
        var kind: Kind
        var path: String
        var detail: String?
        var message: String

        init(_ kind: Kind, _ path: String, _ message: String, detail: String? = nil) {
            self.kind = kind; self.path = path; self.message = message; self.detail = detail
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            path = try c.decode(String.self, forKey: .path)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            message = try c.decode(String.self, forKey: .message)
        }

        /// Whether the condition that set this block is gone.
        func isCleared(source: String) -> Bool {
            var info = stat()
            switch kind {
            case .restore:
                guard WorkspaceGit.relative(path, inside: source) != nil else { return false }
                if lstat(path, &info) != 0 { return errno == ENOENT }
                return info.st_mode & S_IFMT == S_IFREG
            case .quarantine:
                return lstat(path, &info) != 0 && errno == ENOENT
            case .index:
                return WorkspaceGit.gitlinks(index: path, sha256: false) != nil
                    || WorkspaceGit.gitlinks(index: path, sha256: true) != nil
            case .risky:
                return GitConfigGuard.untrustedRisk(path, kind: .config) == nil
            case .unreadable:
                if case .other(let now) = GitConfigGuard.read(path) { return now == detail }
                return false
            }
        }
    }

    /// What a watched file was. Only `absent` and `bytes` can be put back; anything else (too
    /// large, not a plain file, unreadable) is compared by its metadata and never written over.
    enum Snapshot: Equatable {
        case absent
        case bytes(Data)
        case other(String)
    }

    private struct Record {
        var kind: WorkspaceGit.FileKind
        var snapshot: Snapshot
        /// The real path of the folder it sits in, so a restore never writes through a folder the
        /// VM swapped for a link.
        var folder: String
        /// The mount's real path when watched, and the file's path inside it: a restore walks
        /// these components one by one, refusing a link at each.
        var root: String
        var relative: String
        var source: String
        /// In a repository that was not there when Iris first saw the folder: the VM made it, so
        /// what it holds is never a baseline. It is judged as it stands, and never written.
        var untrusted: Bool
        /// A change to a file that cannot be put back has been said; it is said again only after
        /// the file is back as it was.
        var noted = false
    }

    /// A trusted repository's submodules when the watch began (#623 2b): each gitlink in the index
    /// with what its `.git` was, and the module repositories under `.git/modules`.
    private struct Submodules {
        var links: [String: String]
        var modules: Set<String>
        var indexFailed = false
    }

    /// One record per folder, whichever containers mount it: recorded when the first watch of it
    /// begins and kept until the last ends, so a second watch never takes what a background writer
    /// left as its baseline, and one container's clean check is the folder's clean check.
    private struct SourceState {
        var files: [String: Record] = [:]
        var submodules: Submodules?
        var owners: Set<String> = []
        /// Blocked when Iris last ran, so no baseline: only the block's own condition is checked,
        /// and a baseline is taken once it clears.
        var awaitingClear = false
    }

    private let lock = NSLock()
    private var states: [String: SourceState] = [:]
    /// The folders each owner (a container) mounts.
    private var watches: [String: [String]] = [:]
    /// Each source ever watched in this process, with the hooks folder Iris saw before any VM
    /// could write it, or nil when there was no repository then.
    private var trustedHooks: [String: String?] = [:]
    /// Folders whose git reads a watched repository's config: each source, and each linked
    /// worktree of a repository at a source's root, with the hooks folder their git should run.
    private var covered: [String: String?] = [:]
    /// What a check made at removal found, by owner, said with that conversation's next result.
    private var pending: [String: [String]] = [:]

    /// Folders whose repository holds a change Iris could not put back, or that the VM made with
    /// settings that run programs, with why. A host command there is refused until a clean check.
    private var blocked: [String: Block] = [:]
    private let store: URL?

    /// `store` keeps the mounted folders across restarts; nil keeps them in memory only (tests).
    init(store: URL? = nil) {
        self.store = store
        guard let store, let data = try? Data(contentsOf: store),
              let saved = try? JSONDecoder().decode([MountedWorkspace].self, from: data) else { return }
        for item in saved {
            remember(item.path, hooks: item.hooks)
            if let block = item.blocked {
                blocked[item.path] = block
                states[item.path] = SourceState(awaitingClear: true)
            }
        }
    }

    private func remember(_ source: String, hooks: String?) {
        trustedHooks[source] = .some(hooks)
        covered[source] = .some(hooks)
        if let hooks {
            let common = (hooks as NSString).deletingLastPathComponent
            for worktree in WorkspaceGit.linkedWorktrees(commonDir: common) where covered[worktree] == nil {
                covered[worktree] = .some(hooks)
            }
        }
    }

    private func save() {
        guard let store else { return }
        let items = trustedHooks.keys.sorted().map { MountedWorkspace(path: $0, hooks: trustedHooks[$0] ?? nil, blocked: blocked[$0]) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }

    /// Starts watching `sources` for `owner` (a container name). A folder no other watch holds is
    /// recorded now; one already watched keeps the record it has.
    func watch(owner: String, sources: [String]) {
        lock.lock(); defer { lock.unlock() }
        for source in sources {
            if !(watches[owner] ?? []).contains(source) { watches[owner, default: []].append(source) }
            if states[source] != nil { states[source]!.owners.insert(owner); continue }
            if trustedHooks[source] == nil {
                if case .layout(let layout) = WorkspaceGit.entry(at: source) { remember(source, hooks: layout.hooks) }
                else { remember(source, hooks: nil) }
                save()
            }
            var state = SourceState(owners: [owner])
            baseline(source, &state)
            states[source] = state
        }
    }

    /// Records what `source` holds now as what later checks compare against.
    private func baseline(_ source: String, _ state: inout SourceState) {
        let untrusted = trustedHooks[source] == .some(nil)
        if !untrusted, case .layout(let layout) = WorkspaceGit.entry(at: source) {
            let links = WorkspaceGit.gitlinks(index: (layout.gitDir as NSString).appendingPathComponent("index"),
                                              sha256: Self.isSHA256(layout)) ?? []
            state.submodules = Submodules(
                links: Dictionary(links.filter(WorkspaceGit.isPlainRelative).map { ($0, WorkspaceGit.pointerSignature(source: source, link: $0)) },
                                  uniquingKeysWith: { a, _ in a }),
                modules: Set(WorkspaceGit.modules(commonDir: layout.commonDir)))
        }
        addFiles(source, &state, untrusted: untrusted)
    }

    /// Records the repository files of `source` not yet recorded. For a trusted repository that
    /// happens once, when the watch begins; for one the VM made, again at every check, so a
    /// repository made mid-session is judged too.
    private func addFiles(_ source: String, _ state: inout SourceState, untrusted: Bool) {
        for (path, kind) in WorkspaceGit.watchedFiles(for: source) where state.files[path] == nil {
            guard let relative = WorkspaceGit.relative(path, inside: source) else { continue }
            state.files[path] = Record(kind: kind, snapshot: untrusted ? .other("untrusted") : Self.read(path),
                                       folder: Self.folder(of: path), root: IrisPaths.realPath(source),
                                       relative: relative, source: source, untrusted: untrusted)
        }
    }

    /// Compares the files of `owner`'s folders with their record and puts back each change it may
    /// not keep, answering what the person should be told, if anything.
    func check(owner: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let notes = (pending.removeValue(forKey: owner) ?? []) + checkLocked(watches[owner] ?? [])
        return Self.notice(notes)
    }

    /// Every watched folder at once, for a host command: host git may read any of them. `owner`
    /// is the command's conversation's container, whose pending notices it also says.
    func checkAll(owner: String? = nil) -> String? {
        lock.lock(); defer { lock.unlock() }
        let notes = (owner.flatMap { pending.removeValue(forKey: $0) } ?? []) + checkLocked(states.keys.sorted())
        return Self.notice(notes)
    }

    /// `owner`'s container is gone. A folder no other container mounts gets a last check, since
    /// nothing can write it now, and its record ends; what that found is said with the owner's
    /// next result. A folder another container still mounts stays watched.
    func end(owner: String) {
        lock.lock(); defer { lock.unlock() }
        let notes = endLocked(owner)
        if !notes.isEmpty { pending[owner, default: []] += notes }
    }

    /// `end`, for a one-off container that is gone once its command returns: what the last check
    /// found is this command's to say.
    func finish(owner: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return Self.notice(endLocked(owner))
    }

    private func endLocked(_ owner: String) -> [String] {
        guard let sources = watches.removeValue(forKey: owner) else { return [] }
        var last: [String] = []
        for source in sources {
            states[source]?.owners.remove(owner)
            if states[source]?.owners.isEmpty == true { last.append(source) }
        }
        // `checkLocked` ends the record of each that is clean; a blocked one stays.
        return checkLocked(last)
    }

    /// The overrides for a host command: when `owner` (its conversation's container) is watched,
    /// when its working directory lies in a folder whose git reads a repository some VM in this
    /// process could write, or when the command spells one (best effort); nil otherwise, so
    /// ordinary git is untouched. The hooks folder to run, or nil for none.
    func hostOverrides(cwd: String?, command: String = "", owner: String? = nil) -> String?? {
        lock.lock(); defer { lock.unlock() }
        let real = cwd.map(IrisPaths.realPath)
        let inside = covered.keys.filter { root in
            guard let real else { return false }
            let r = IrisPaths.realPath(root)
            return real == r || real.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        if let covering = inside.max(by: { $0.count < $1.count }) { return .some(covered[covering] ?? nil) }
        var named = covered.keys.filter { WorkspaceGit.commandNames(command, $0) || WorkspaceGit.commandNames(command, IrisPaths.realPath($0)) }
        if named.isEmpty, let owner, let mine = watches[owner] { named = mine }
        guard !named.isEmpty else { return nil }
        // A command naming more than one repository: run no hooks rather than guess whose.
        return .some(named.count == 1 ? (covered[named[0]] ?? nil) : nil)
    }

    /// Every source ever watched, for deciding whether the person's global config is in reach.
    func watchedSources() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(trustedHooks.keys)
    }

    /// `result` with what a check before the command found ahead of it and what one after found
    /// behind it.
    static func withNotices(_ result: String, before: String?, after: String?) -> String {
        [before, result, after].compactMap { $0 }.joined(separator: "\n")
    }

    private func checkLocked(_ sources: [String]) -> [String] {
        var notes: [String] = []
        for source in sources {
            guard var state = states[source] else { continue }
            var failure: Block?
            notes += checkSource(source, &state, failure: &failure)
            states[source] = state
            // A folder is cleared only by a check that found nothing it could not fix.
            if blocked[source] != failure {
                blocked[source] = failure
                save()
            }
            // A blocked folder keeps its record after its last container ends, so every host
            // command's check keeps looking at it, and a later watch joins it rather than taking
            // the bad state as a baseline. Clean and unwatched, it ends.
            if failure == nil, state.owners.isEmpty { states[source] = nil }
        }
        return notes
    }

    private func checkSource(_ source: String, _ state: inout SourceState, failure: inout Block?) -> [String] {
        var notes: [String] = []
        if state.awaitingClear {
            // After a restart: never an empty baseline here, which would move the person's own
            // submodules aside; only the block's condition, until it is gone.
            if let block = blocked[source], !block.isCleared(source: source) { failure = block; return [] }
            state.awaitingClear = false
            baseline(source, &state)
            return []
        }
        if trustedHooks[source] == .some(nil) {
            addFiles(source, &state, untrusted: true)
            // A repository the VM made has no baseline: every submodule in it is the VM's, so the
            // scan runs against an empty one and moves aside whatever it finds (Brian's "b").
            if state.submodules == nil, case .layout = WorkspaceGit.entry(at: source) {
                state.submodules = Submodules(links: [:], modules: [])
            }
        }
        for path in state.files.keys.sorted() {
            guard var record = state.files[path] else { continue }
            defer { state.files[path] = record }
            if record.untrusted {
                if let note = judgeUntrusted(path, &record) { failure = Block(.risky, path, note); notes.append(note) }
                else if let still = Self.untrustedRisk(path, kind: record.kind) { failure = Block(.risky, path, still) }
                continue
            }
            let now = Self.read(path)
            if now == record.snapshot { record.noted = false; continue }
            // Re-judged now: a folder on the way (`.git/worktrees/<x>`) swapped for a link would
            // put the path, and a restore through it, outside the mount.
            if WorkspaceGit.relative(path, inside: source) == nil || Self.folder(of: path) != record.folder {
                let note = "The folder holding \(path) was replaced; Iris did not write through it. Check the repository before running git on your Mac."
                failure = Block(.restore, path, note)
                notes.append(note)
                continue
            }
            let restorable: Data??
            switch record.snapshot {
            case .absent: restorable = .some(nil)
            case .bytes(let data): restorable = .some(data)
            case .other: restorable = nil
            }
            guard let restorable else {
                // Never written over: what was there could not be read, so it cannot be put back.
                // Refused until it is back as it was, and said once.
                let note = "\(path) changed, and Iris cannot check it (it is too large or not a plain file). Check it before running git on your Mac."
                if case .other(let was) = record.snapshot { failure = Block(.unreadable, path, note, detail: was) }
                if !record.noted { notes.append(note); record.noted = true }
                continue
            }
            var keys: [String] = []
            if record.kind == .config, case .bytes(let new) = now, let newEntries = GitConfigFile.parse(new),
               let oldEntries = restorable == nil ? [] : GitConfigFile.parse(restorable!) {
                keys = GitConfigFile.disallowedKeys(from: oldEntries, to: newEntries)
                if keys.isEmpty {
                    record.snapshot = now
                    continue
                }
            }
            let restored = Self.restore(root: record.root, relative: record.relative, to: restorable)
            let note = Self.describe(path: path, kind: record.kind, keys: keys, restored: restored)
            if !restored { failure = Block(.restore, path, note) }
            notes.append(note)
        }
        if state.submodules != nil {
            if let note = checkSubmodules(source, &state.submodules!, failure: &failure) { notes.append(note) }
        }
        return notes
    }

    /// Moves aside each submodule the VM added or repointed since the watch began: a gitlink in the
    /// index that was not there, or whose `.git` changed, has that `.git` renamed (never deleted),
    /// and a module repository new under `.git/modules` likewise. The index is not edited: a
    /// gitlink with nothing behind it runs nothing. An index that cannot be read fails closed.
    private func checkSubmodules(_ source: String, _ base: inout Submodules, failure: inout Block?) -> String? {
        guard case .layout(let layout) = WorkspaceGit.entry(at: source) else { return nil }
        let root = IrisPaths.realPath(source)
        let index = (layout.gitDir as NSString).appendingPathComponent("index")
        guard let links = WorkspaceGit.gitlinks(index: index, sha256: Self.isSHA256(layout)) else {
            let why = "The index of \(source) is too large or malformed, so Iris cannot tell which submodules the sandbox added."
            failure = Block(.index, index, why)
            defer { base.indexFailed = true }
            return base.indexFailed ? nil : why
        }
        base.indexFailed = false
        var notes: [String] = []
        for link in links where WorkspaceGit.isPlainRelative(link) {
            let now = WorkspaceGit.pointerSignature(source: source, link: link)
            guard now != "absent", base.links[link] != now else { continue }
            let path = (source as NSString).appendingPathComponent(link + "/.git")
            if let moved = Self.quarantine(root: root, relative: link + "/.git") {
                notes.append("\(path) belongs to a submodule the sandbox added or repointed; Iris moved it aside to \(moved) rather than delete it, so git on your Mac does not use it. If you trust it, rename it back to .git once the sandbox session has ended.")
            } else {
                let why = "\(path) belongs to a submodule the sandbox added or repointed, and Iris could not move it aside."
                failure = Block(.quarantine, path, why)
                notes.append(why)
            }
        }
        for module in WorkspaceGit.modules(commonDir: layout.commonDir) where !base.modules.contains(module) {
            guard let relative = WorkspaceGit.relative(module, inside: source) else { continue }
            if let moved = Self.quarantine(root: root, relative: relative) {
                notes.append("\(module), a submodule repository the sandbox made, was moved aside to \(moved), so a later `git submodule update` does not reattach to it.")
            } else {
                let why = "\(module), a submodule repository the sandbox made, could not be moved aside."
                failure = Block(.quarantine, module, why)
                notes.append(why)
            }
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// Whether the repository names objects with SHA-256, which changes the index's entry size.
    private static func isSHA256(_ layout: WorkspaceGit.Layout) -> Bool {
        guard let data = WorkspaceGit.readSmall((layout.commonDir as NSString).appendingPathComponent("config")),
              let entries = GitConfigFile.parse(data) else { return false }
        return entries.contains { $0.key == "extensions.objectformat" && $0.value?.lowercased() == "sha256" }
    }

    /// Renames `relative` under `root` to the first free `<name>.iris-quarantine[-N]` beside it,
    /// opening each folder on the way with O_NOFOLLOW. The new name, or nil.
    static func quarantine(root: String, relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        var dir = open(root, O_RDONLY | O_DIRECTORY)
        guard dir >= 0 else { return nil }
        for part in parts.dropLast() {
            let next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(dir)
            guard next >= 0 else { return nil }
            dir = next
        }
        defer { close(dir) }
        var info = stat()
        for n in 1...100 {
            let candidate = name + WorkspaceGit.quarantineSuffix + (n == 1 ? "" : "-\(n)")
            guard fstatat(dir, candidate, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { continue }
            guard renameat(dir, name, dir, candidate) == 0 else { return nil }
            return ((root as NSString).appendingPathComponent(relative) as NSString).deletingLastPathComponent + "/" + candidate
        }
        return nil
    }

    /// The `core.*` keys `git init` writes, which a repository the VM made may hold.
    static let initDefaults: Set<String> = ["core.repositoryformatversion", "core.filemode", "core.bare",
                                            "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode",
                                            "core.symlinks"]

    /// What makes a file of a repository the VM made unsafe for host git, or nil: a config key
    /// outside the allow-list and `git init`'s own, or a config Iris cannot read.
    static func untrustedRisk(_ path: String, kind: WorkspaceGit.FileKind) -> String? {
        guard kind == .config else { return nil }
        switch read(path) {
        case .absent: return nil
        case .other: return "\(path), in a repository the sandbox made, cannot be checked."
        case .bytes(let data):
            guard let entries = GitConfigFile.parse(data) else { return "\(path), in a repository the sandbox made, cannot be read." }
            var values: [String: [String]] = [:]
            for e in entries { values[e.key, default: []].append(e.value ?? "\u{0}") }
            let bad = values.keys.sorted().filter { !initDefaults.contains($0) && !GitConfigFile.isAllowed(key: $0, values: values[$0]!) }
            return bad.isEmpty ? nil : "\(path), in a repository the sandbox made, sets \(bad.joined(separator: ", "))."
        }
    }

    /// A repository the VM made is never adopted: its config is judged as it stands, said once
    /// per change, and left as it is, since nothing of the person's is there to put back.
    private func judgeUntrusted(_ path: String, _ record: inout Record) -> String? {
        let now = Self.read(path)
        guard now != record.snapshot else { return nil }
        record.snapshot = now
        return Self.untrustedRisk(path, kind: record.kind)
    }

    /// Why a host command must not run, or nil: its working directory is in, or it names, a
    /// folder whose repository is left unsafe (`blocked`).
    func hostRefusal(cwd: String?, command: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let real = cwd.map(IrisPaths.realPath)
        for source in blocked.keys.sorted() {
            guard let why = blocked[source]?.message else { continue }
            let roots = [source] + covered.keys.filter { covered[$0] == trustedHooks[source] && trustedHooks[source] != .some(nil) }
            let hit = roots.contains { root in
                let r = IrisPaths.realPath(root)
                if let real, real == r || real.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return true }
                return WorkspaceGit.commandNames(command, root) || WorkspaceGit.commandNames(command, r)
            }
            if hit {
                return "Not run: git on your Mac would read a repository the sandbox left unsafe. \(why) Fix or remove it; the next check that finds it clean lets commands run here again."
            }
        }
        return nil
    }

    private static func describe(path: String, kind: WorkspaceGit.FileKind, keys: [String], restored: Bool) -> String {
        let what = switch kind {
        case .pointer: "which tells git where the repository is"
        case .config where keys.isEmpty: "in a way Iris could not read"
        case .config: "(" + keys.joined(separator: ", ") + ")"
        }
        return restored ? "\(path) was changed \(what); Iris put back the copy it had before."
                        : "\(path) was changed \(what), and Iris could not put it back. Check it before running git on your Mac."
    }

    private static func notice(_ notes: [String]) -> String? {
        guard !notes.isEmpty else { return nil }
        return "[sandbox] A command in the sandbox changed git settings that can run programs when git runs on your Mac. "
            + notes.joined(separator: " ")
            + " Changes to remotes, upstream branches and user.* are kept. If you made this change yourself, make it again once the sandbox session has ended."
    }

    /// Large enough for any real config; a file over it is compared by metadata only.
    static let readLimit = 16 << 20

    static func read(_ path: String) -> Snapshot {
        var info = stat()
        if lstat(path, &info) != 0 { return errno == ENOENT ? .absent : .other("unreadable") }
        if info.st_mode & S_IFMT == S_IFREG, let data = WorkspaceGit.readSmall(path, limit: readLimit) { return .bytes(data) }
        return .other("\(info.st_mode)-\(info.st_size)-\(info.st_ino)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)")
    }

    private static func folder(of path: String) -> String {
        IrisPaths.realPath((path as NSString).deletingLastPathComponent)
    }

    /// Writes `bytes` back over the file by rename, which replaces a link or file put in its place
    /// without following it; nil removes what is there. The folders on the way are opened one at a
    /// time from the mount's root, each refused if it is a link, and the write and rename are made
    /// relative to the last, so a folder swapped for a link is never written through.
    static func restore(root: String, relative: String, to bytes: Data?) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        var dir = open(root, O_RDONLY | O_DIRECTORY)
        guard dir >= 0 else { return false }
        for part in parts.dropLast() {
            let next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(dir)
            guard next >= 0 else { return false }
            dir = next
        }
        defer { close(dir) }
        guard let bytes else {
            var info = stat()
            if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
            // Only what was not there before: a file or link the VM made. Never a folder.
            guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK else { return false }
            return unlinkat(dir, name, 0) == 0
        }
        let temp = ".iris-restore-\(UUID().uuidString)"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: bytes) } catch { unlinkat(dir, temp, 0); return false }
        guard renameat(dir, temp, dir, name) == 0 else { unlinkat(dir, temp, 0); return false }
        return true
    }
}
