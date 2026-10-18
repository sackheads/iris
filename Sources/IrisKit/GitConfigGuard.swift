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
/// misses: a background process left in the VM can write after a check, and git run outside Iris
/// (the person's own terminal) can read the file before the next one.
final class GitConfigGuard: @unchecked Sendable {
    static let shared = GitConfigGuard()

    private struct Watch {
        var sources: [String]
        /// The bytes each watched file had, or nil for one that was not there.
        var files: [String: (kind: WorkspaceGit.FileKind, bytes: Data?)]
    }

    private let lock = NSLock()
    private var watches: [String: Watch] = [:]
    /// Each source ever watched in this process, with the hooks folder Iris saw before any VM
    /// could write it, or nil when there was no repository then.
    private var trustedHooks: [String: String?] = [:]
    /// What a check made at removal found, said with the next command's result.
    private var pending: [String] = []

    init() {}

    /// Starts watching `sources` for `owner` (a container name), recording each file now. A
    /// source already watched for it keeps the record it has.
    func watch(owner: String, sources: [String]) {
        lock.lock(); defer { lock.unlock() }
        var w = watches[owner] ?? Watch(sources: [], files: [:])
        for source in sources where !w.sources.contains(source) {
            w.sources.append(source)
            if trustedHooks[source] == nil {
                if case .layout(let layout) = WorkspaceGit.entry(at: source) { trustedHooks[source] = .some(layout.hooks) }
                else { trustedHooks[source] = .some(nil) }
            }
            for (path, kind) in WorkspaceGit.watchedFiles(for: source) where w.files[path] == nil {
                w.files[path] = (kind, Self.read(path))
            }
        }
        watches[owner] = w
    }

    /// Compares `owner`'s files with their record and puts back each change it may not keep,
    /// answering what the person should be told, if anything.
    func check(owner: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var notes = takePending()
        if var w = watches[owner] {
            notes += checkLocked(&w)
            watches[owner] = w
        }
        return Self.notice(notes)
    }

    /// Every watch at once, for a host command: host git may read any of these repositories.
    func checkAll() -> String? {
        lock.lock(); defer { lock.unlock() }
        var notes = takePending()
        for owner in watches.keys.sorted() {
            var w = watches[owner]!
            notes += checkLocked(&w)
            watches[owner] = w
        }
        return Self.notice(notes)
    }

    /// A last check once `owner`'s container is gone, so nothing in it can write again, then the
    /// watch ends. What it found is said with the next command's result.
    func end(owner: String) {
        lock.lock(); defer { lock.unlock() }
        guard var w = watches.removeValue(forKey: owner) else { return }
        pending += checkLocked(&w)
    }

    /// The overrides for a host command whose working directory is `cwd`, when it lies in a
    /// folder some VM in this process could write; nil otherwise, so ordinary git is untouched.
    func hostOverrides(cwd: String?) -> String?? {
        guard let cwd else { return nil }
        lock.lock(); defer { lock.unlock() }
        let real = IrisPaths.realPath(cwd)
        let covering = trustedHooks.keys.filter {
            let root = IrisPaths.realPath($0)
            return real == root || real.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }.max { $0.count < $1.count }
        guard let covering else { return nil }
        return .some(trustedHooks[covering] ?? nil)
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

    private func takePending() -> [String] {
        defer { pending = [] }
        return pending
    }

    private func checkLocked(_ w: inout Watch) -> [String] {
        var notes: [String] = []
        for path in w.files.keys.sorted() {
            guard let (kind, recorded) = w.files[path] else { continue }
            let now = Self.read(path)
            if now == recorded, now != nil || !Self.exists(path) { continue }
            var keys: [String] = []
            if kind == .config, let new = now,
               let newEntries = GitConfigFile.parse(new),
               let oldEntries = recorded == nil ? [] : GitConfigFile.parse(recorded!) {
                keys = GitConfigFile.disallowedKeys(from: oldEntries, to: newEntries)
                if keys.isEmpty {
                    w.files[path] = (kind, now)
                    continue
                }
            }
            let restored = Self.restore(path, to: recorded)
            notes.append(Self.describe(path: path, kind: kind, keys: keys, restored: restored))
        }
        return notes
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

    /// The file's bytes, or nil when it is missing, not a regular file, or a link.
    private static func read(_ path: String) -> Data? { WorkspaceGit.readSmall(path) }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Writes `bytes` back over `path` by rename, which replaces a link or file put in its place
    /// without following it; nil removes what is there.
    private static func restore(_ path: String, to bytes: Data?) -> Bool {
        guard let bytes else {
            var info = stat()
            if lstat(path, &info) != 0 { return true }
            return unlink(path) == 0
        }
        let temp = (path as NSString).deletingLastPathComponent + "/.iris-restore-\(UUID().uuidString)"
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: bytes) } catch { unlink(temp); return false }
        guard rename(temp, path) == 0 else { unlink(temp); return false }
        return true
    }
}
