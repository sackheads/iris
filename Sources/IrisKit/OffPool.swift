import Foundation

/// Blocking work kept off the cooperative pool (#532, the #372 class): a read, write or walk on a
/// hung or slow mount blocks its thread until the mount answers, and the model drives the file
/// tools in parallel (Invariant 3), so a few such calls on pool threads could take every one a
/// low-core Mac has, stalling every turn. `run` does the work on a dispatch queue instead and
/// returns `cancelled` at once if its task is cancelled. The work runs on regardless — a blocked
/// syscall cannot be stopped — and its late answer is dropped; it can read `OffPool.Cancel` to
/// avoid committing anything once nobody is waiting for it.
enum OffPool {
    /// Set the moment the caller is cancelled.
    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        var isCancelled: Bool { lock.withLock { set } }
        func cancel() { lock.withLock { set = true } }
    }

    /// Test seam: runs inside the dispatched work, before it, so a test can stand in for a hung
    /// mount or record which queue the work ran on. Never set in production.
    @TaskLocal static var testHook: (@Sendable () -> Void)?

    static func run<T: Sendable>(cancelled: T, _ work: @escaping @Sendable (Cancel) -> T) async -> T {
        let answer = OneShot<T>()
        let flag = Cancel()
        let hook = testHook
        return await withTaskCancellationHandler {
            DispatchQueue.global(qos: .utility).async {
                hook?()
                answer.resume(work(flag))
            }
            return await answer.wait()
        } onCancel: {
            flag.cancel()
            answer.resume(cancelled)
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
