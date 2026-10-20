import Foundation

/// Every folder a sandbox VM was ever able to write (#616). `ReadOnlyCommand.restrictedPath` drops
/// these from a silent host read's `PATH`, because what a VM leaves in a folder outlives the
/// conversation, grant or job that let it write there: a pruned run, a deleted conversation, an
/// unlinked workspace or a replaced grant would otherwise put the folder back on the `PATH` with
/// whatever the VM planted in it.
///
/// Append-only and never shrunk, so it can only tighten. One canonical real path per line, each a
/// JSON string so no path can break the format, each line one `write` on an `O_APPEND` descriptor
/// under an in-process lock. Kept in `config/`, a protected write directory. A file that can't be
/// read, or holds a line that won't parse, is damaged: that line could be a lost root, so it
/// fails closed (`AppState.writableRootsDamaged`) rather than being skipped.
/// Recorded before a mount is first used: the two places a read-write mount reaches a container
/// (`SandboxSessionManager.run`, `ToolExecutor`'s one-off run) refuse to start one when the record
/// can't be written, so a crash can't leave a folder that was writable but never recorded.
struct WritableRootsRecord: Sendable {
    let paths: IrisPaths

    init(paths: IrisPaths = .default) { self.paths = paths }

    var url: URL { paths.configDir.appendingPathComponent("sandbox-writable-roots.jsonl") }

    /// One process writes a home at a time (#463), so an in-process lock is enough.
    private static let lock = NSLock()

    static let refusal = "Iris couldn't record this folder as writable by the sandbox (in its config folder), so it won't mount it: a folder a sandbox wrote must stay off the PATH Iris's silent reads use."

    /// What the file holds: every root, or damaged (unreadable, or a line that won't parse).
    /// A file that isn't there yet is simply empty.
    enum Contents: Equatable { case roots([String]), damaged }

    /// Records each root, as its canonical real path, if it isn't there yet. False when the file
    /// couldn't be written; a mount site then refuses. Recorded even into a damaged file, so a
    /// root made writable while it's damaged isn't lost too.
    @discardableResult
    func record(_ roots: [String]) -> Bool {
        let wanted = roots.filter { !$0.isEmpty }.map { IrisPaths.canonicalPath(IrisEngine.expandTilde($0)) }
        guard !wanted.isEmpty else { return true }
        return Self.lock.withLock {
            var known: Set<String> = []
            if case .roots(let roots) = readLocked() { known = Set(roots) }
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
    }

    /// Every recorded root, or `.damaged`.
    func contents() -> Contents { Self.lock.withLock { readLocked() } }

    /// Every recorded root; empty when damaged (the caller that decides asks `contents()`).
    func all() -> [String] {
        if case .roots(let roots) = contents() { return roots }
        return []
    }

    private func readLocked() -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .roots([]) }
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
