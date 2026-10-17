import Foundation

/// Blocking work kept off the cooperative pool (#532, the #372 class): a read, write or walk on a
/// hung or slow mount blocks its thread until the mount answers, and the model drives the file
/// tools in parallel (Invariant 3), so a few such calls on pool threads could take every one a
/// low-core Mac has, stalling every turn. `run` does the work on a dispatch queue instead and
/// returns `cancelled` at once if its task is cancelled. The work runs on regardless — a blocked
/// syscall cannot be stopped — and its late answer is dropped; it can read `OffPool.Cancel` to
/// avoid committing anything once nobody is waiting for it.
enum OffPool {
    /// The call's state, moved in one step each way so a cancel and a commit racing have exactly
    /// one outcome (#548 review): `running`, then either `cancelled` (the caller answers
    /// `cancelled` at once and the work must not commit) or `committing` (the work has passed its
    /// commit gate; a cancel now waits for the work's real answer, which comes once its rename
    /// returns).
    final class Cancel: @unchecked Sendable {
        private enum State { case running, committing, cancelled }
        private let lock = NSLock()
        private var state = State.running
        fileprivate var afterCommitGate: (@Sendable () -> Void)?
        var isCancelled: Bool { lock.withLock { state == .cancelled } }
        /// The commit gate: true, and committing, unless the call was cancelled first.
        func beginCommit() -> Bool {
            let won = lock.withLock { () -> Bool in
                guard state == .running else { return false }
                state = .committing
                return true
            }
            if won { afterCommitGate?() }
            return won
        }
        /// True when this cancel took effect: nothing had begun committing.
        fileprivate func cancel() -> Bool {
            lock.withLock {
                guard state == .running else { return false }
                state = .cancelled
                return true
            }
        }
    }

    /// Test seam: runs inside the dispatched work, before it, so a test can stand in for a hung
    /// mount or record which queue the work ran on. Never set in production.
    @TaskLocal static var testHook: (@Sendable () -> Void)?
    /// Test seam: runs once a write has passed its commit gate, before its rename.
    @TaskLocal static var afterCommitGateHook: (@Sendable () -> Void)?

    static func run<T: Sendable>(cancelled: T, _ work: @escaping @Sendable (Cancel) -> T) async -> T {
        let answer = OneShot<T>()
        let flag = Cancel()
        let hook = testHook
        flag.afterCommitGate = afterCommitGateHook
        return await withTaskCancellationHandler {
            // A queue of its own per call, not `DispatchQueue.global()`, which does not overcommit:
            // a few calls blocked on a hung mount must not hold up the next one (#377, the same
            // reason `BlockingSpawn.detached` makes its own; #548 review).
            DispatchQueue(label: "iris.off-pool").async {
                hook?()
                answer.resume(work(flag))
            }
            return await answer.wait()
        } onCancel: {
            // Once a write is committing, its own answer is the true one, and it comes as soon as
            // the rename returns.
            if flag.cancel() { answer.resume(cancelled) }
        }
    }
}

/// `write_file`'s attended write (#532): what `String.write(toFile:atomically:)` did — stage a
/// temp file beside the target, then rename it over the target — done by hand so the rename can be
/// skipped once the call is cancelled. Kept as Foundation left things (measured): an existing
/// entry's mode bits carry over (a symlink is replaced by a file, its own target untouched), a new
/// file gets 0666 less the umask. A failure leaves no temp file behind.
enum StagedFileWrite {
    static func write(_ content: String, to path: String, shouldCommit: () -> Bool) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        let staging = directory + "/.\(url.lastPathComponent).iris-\(UUID().uuidString.prefix(8)).tmp"
        var st = stat()
        let existingMode: mode_t? = lstat(path, &st) == 0 ? st.st_mode & 0o7777 : nil
        if existingMode != nil, (st.st_mode & S_IFMT) == S_IFDIR { throw error(EISDIR, path) }
        let fd = open(staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw error(errno, path) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(staging) }
        }
        if let existingMode, fchmod(fd, existingMode) != 0 { throw error(errno, path) }
        let bytes = Array(content.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress! + written, $0.count - written) }
            guard n > 0 else { throw error(errno, path) }
            written += n
        }
        guard shouldCommit() else { throw CancellationError() }
        guard rename(staging, path) == 0 else { throw error(errno, path) }
        renamed = true
    }

    /// Foundation's own file errors, so the tool's sentence reads as it did before.
    private static func error(_ code: Int32, _ path: String) -> NSError {
        let cocoa: Int
        switch code {
        case EACCES, EPERM: cocoa = NSFileWriteNoPermissionError
        case ENOSPC, EDQUOT: cocoa = NSFileWriteOutOfSpaceError
        case EROFS: cocoa = NSFileWriteVolumeReadOnlyError
        case ENOENT, ENOTDIR: cocoa = NSFileNoSuchFileError
        default: cocoa = NSFileWriteUnknownError
        }
        return NSError(domain: NSCocoaErrorDomain, code: cocoa, userInfo: [
            NSFilePathErrorKey: path,
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
        ])
    }
}
