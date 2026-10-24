import Foundation

/// Every folder a sandbox VM was ever able to write (#616). `ReadOnlyCommand.restrictedPath` drops
/// these from a silent host read's `PATH`, because what a VM leaves in a folder outlives the
/// conversation, grant or job that let it write there: a pruned run, a deleted conversation, an
/// unlinked workspace or a replaced grant would otherwise put the folder back on the `PATH` with
/// whatever the VM planted in it.
///
/// Never shrunk, so it can only tighten. The record itself is in the guarded secrets item (#717),
/// where a host command can't delete or rewrite it: `GuardedRoots` keeps it, with an in-memory
/// copy for lookups. The file in `config/` is a readable copy, one canonical real path per line,
/// each a JSON string, rewritten from the item after every write. At launch the file's roots that
/// still parse are merged in (tighten-only, and it heals a root lost to a concurrent write of the
/// item), and a file missing a root the item has is reported as changed outside Iris. An item
/// that can't be read fails closed (`AppState.writableRootsDamaged`). With no guarded Keychain
/// (#678's legacy mode, only a test's own config) the file is the record, as before #717.
/// Recorded before a mount is first used: the two places a read-write mount reaches a container
/// (`SandboxSessionManager.run`, `ToolExecutor`'s one-off run) refuse to start one when the record
/// can't be written, so a crash can't leave a folder that was writable but never recorded.
struct WritableRootsRecord: Sendable {
    let paths: IrisPaths
    let store: GuardedRoots

    /// `store` nil: this home's own (`GuardedRoots.forHome`).
    init(paths: IrisPaths = .default, store: GuardedRoots? = nil) {
        self.paths = paths
        self.store = store ?? GuardedRoots.forHome(paths)
    }

    var url: URL { paths.configDir.appendingPathComponent("sandbox-writable-roots.jsonl") }

    /// One process writes a home at a time (#463), so an in-process lock is enough.
    private static let lock = NSLock()

    static let refusal = "Iris couldn't record this folder as writable by the sandbox (in its Keychain item), so it won't mount it: a folder a sandbox wrote must stay off the PATH Iris's silent reads use."

    /// What the record holds: every root, or damaged (the guarded item can't be read; with no
    /// guarded Keychain, a file that can't be read or holds a line that won't parse). `missing` is
    /// no file, which only the legacy mode reports.
    enum Contents: Equatable { case roots([String]), damaged, missing }

    /// Records each root, as its canonical real path, if it isn't there yet. False when the record
    /// couldn't be written; a mount site then refuses.
    @discardableResult
    func record(_ roots: [String]) -> Bool {
        let wanted = roots.filter { !$0.isEmpty }.map { IrisPaths.canonicalPath(IrisEngine.expandTilde($0)) }
        guard !wanted.isEmpty else { return true }
        return Self.lock.withLock {
            guard store.isGuarded else { return appendLocked(wanted) }
            guard let (all, added) = store.add(wanted, migrating: { parseableLocked() }) else { return false }
            // The item is the record; the file is only its copy, so a failed rewrite fails nothing.
            if added { _ = rewriteLocked(all) }
            return true
        }
    }

    /// Every recorded root, or `.damaged`.
    func contents() -> Contents {
        Self.lock.withLock {
            guard store.isGuarded else { return readLocked() }
            switch store.load(migrating: { parseableLocked() }) {
            case .roots(let roots): return .roots(roots)
            case .unreadable: return .damaged
            }
        }
    }

    /// Every recorded root; empty when damaged (the caller that decides asks `contents()`).
    func all() -> [String] {
        if case .roots(let roots) = contents() { return roots }
        return []
    }

    /// At launch (#717): merges the file's roots that still parse into the record and rewrites the
    /// file from it. True when the file was missing a root the record has: deleted, or rewritten,
    /// outside Iris. The first launch with a guarded record moves the file's roots into it.
    func reconcile() -> Bool {
        Self.lock.withLock {
            guard store.isGuarded else { return false }
            let file = parseableLocked()
            guard case .roots(let known) = store.load(migrating: { file }) else { return false }
            let lost = !Set(known).isSubset(of: Set(file))
            guard let (all, _) = store.add(file, migrating: { file }) else { return lost }
            if lost || Set(all) != Set(file) || readLocked() != .roots(all) { _ = rewriteLocked(all) }
            return lost
        }
    }

    /// The file's roots, skipping any line that won't parse: what the file can still vouch for.
    private func parseableLocked() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? JSONDecoder().decode(String.self, from: Data($0)) }
    }

    /// Replaces the file with `roots`, whole: written beside it and renamed over it.
    private func rewriteLocked(_ roots: [String]) -> Bool {
        guard (try? FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        var data = Data()
        for root in roots {
            guard let line = try? JSONEncoder().encode(root) else { return false }
            data.append(line); data.append(0x0A)
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// The legacy record: the file alone, appended to.
    private func appendLocked(_ wanted: [String]) -> Bool {
        var known: Set<String> = []
        if case .roots(let roots) = readLocked() { known = Set(roots) }   // missing or damaged: none known
        let fresh = wanted.filter { known.insert($0).inserted }
        guard !fresh.isEmpty else { return true }
        guard (try? FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // After a torn last line (#616 review), a newline first, so the new root is a line of
        // its own rather than merged into the broken one the notice says to delete.
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        var last: UInt8 = 0x0A
        if st.st_size > 0, pread(fd, &last, 1, st.st_size - 1) != 1 { return false }
        if last != 0x0A {
            var newline: UInt8 = 0x0A
            guard Darwin.write(fd, &newline, 1) == 1 else { return false }
        }
        for root in fresh {
            guard var line = try? JSONEncoder().encode(root) else { return false }
            line.append(0x0A)
            // One line, one write: an append on O_APPEND lands whole at the end.
            let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == line.count else { return false }
        }
        return fsync(fd) == 0
    }

    private func readLocked() -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .damaged }
        var roots: [String] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let root = try? JSONDecoder().decode(String.self, from: Data(line)) else { return .damaged }
            roots.append(root)
        }
        // A last line with no newline is a write cut short: damaged, even if it happens to parse.
        if let last = data.last, last != 0x0A { return .damaged }
        return .roots(roots)
    }
}

/// The writable roots themselves (#717), in the guarded secrets item under `key`, with a copy in
/// memory so a lookup never reads the Keychain. An item that can't be read, or a value that won't
/// parse, is unreadable: lookups fail closed and nothing writes over it.
final class GuardedRoots: @unchecked Sendable {
    enum Read: Equatable { case roots([String]), unreadable }

    static let key = "SANDBOX_WRITABLE_ROOTS"

    /// nil: #678's legacy mode, where the file is the record.
    let keychain: KeychainManager?
    private let lock = NSLock()
    private var cached: [String]?
    private var failed = false

    init(keychain: KeychainManager?) { self.keychain = keychain }

    var isGuarded: Bool { keychain != nil }

    /// The record, read once. With no value yet (the first launch of #717), `file`'s roots become it.
    func load(migrating file: () -> [String]) -> Read { lock.withLock { loadLocked(file) } }

    /// Adds `roots`: the record after, and whether that changed it. nil when it can't be read or written.
    func add(_ roots: [String], migrating file: () -> [String]) -> (all: [String], added: Bool)? {
        lock.withLock {
            guard case .roots(let known) = loadLocked(file), let keychain else { return nil }
            let all = Set(known).union(roots).sorted()
            guard all != known else { return (all, false) }
            guard save(all, keychain) else { return nil }
            cached = all
            return (all, true)
        }
    }

    private func loadLocked(_ file: () -> [String]) -> Read {
        if let cached { return .roots(cached) }
        guard !failed, let keychain else { return failed ? .unreadable : .roots([]) }
        guard let secrets = try? keychain.secretsOrThrow(service: KeychainManager.legacyService) else {
            failed = true
            return .unreadable
        }
        if let stored = secrets[Self.key] {
            guard let roots = try? JSONDecoder().decode([String].self, from: Data(stored.utf8)) else {
                failed = true
                return .unreadable
            }
            cached = Set(roots).sorted()
            return .roots(cached ?? [])
        }
        let migrated = Set(file()).sorted()
        guard save(migrated, keychain) else {
            failed = true
            return .unreadable
        }
        cached = migrated
        return .roots(migrated)
    }

    /// Read fresh, so another key written since this process's own read isn't put back.
    private func save(_ roots: [String], _ keychain: KeychainManager) -> Bool {
        guard !keychain.areWritesBlocked,
              var secrets = try? keychain.secretsOrThrow(service: KeychainManager.legacyService),
              let data = try? JSONEncoder().encode(roots) else { return false }
        secrets[Self.key] = String(decoding: data, as: UTF8.self)
        return (try? keychain.saveSecretsOrThrow(secrets, service: KeychainManager.legacyService)) != nil
    }

    private static let homesLock = NSLock()
    nonisolated(unsafe) private static var homes: [String: GuardedRoots] = [:]

    /// One per home, so every writer of a home shares its copy. The process's own home keeps its
    /// record in the shared Keychain item; any other home (a test's) in an item of its own in memory.
    static func forHome(_ paths: IrisPaths) -> GuardedRoots {
        homesLock.withLock {
            let root = paths.root.standardizedFileURL.path
            if let known = homes[root] { return known }
            let isOwn = root == IrisPaths.default.root.standardizedFileURL.path
            let store = GuardedRoots(keychain: isOwn ? KeychainManager.shared
                                     : KeychainManager(serviceSuffix: ".roots-\(UUID().uuidString)", inMemory: true))
            homes[root] = store
            return store
        }
    }
}
