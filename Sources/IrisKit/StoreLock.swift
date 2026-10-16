import Darwin
import Foundation
import os

/// `Darwin.flock` names the C struct, and inside `Syscalls` a bare `flock` names the property.
private func systemFlock(_ fd: Int32, _ operation: Int32) -> Int32 { flock(fd, operation) }

/// #463: one writer per home. Whoever holds this `flock` is the only process that may open the
/// home's `conversations.sqlite`: the app, one `--run-job`, the seeder, or (on its own scratch
/// path) `--perf`.
///
/// - `flock(2)`, never `fcntl`/`lockf`: a POSIX lock drops when *any* descriptor for the file
///   closes, including a read of the payload.
/// - The descriptor is opened `O_CLOEXEC`, so no child keeps the lock alive past its exec, and
///   kept in a process-lifetime table: never `dup`ed (a `dup` loses `FD_CLOEXEC`), never wrapped in
///   anything that closes on `deinit`, and closed only when a re-claim finds the file replaced. `claim` returns a value with no ownership, so a
///   dropped result releases nothing. The kernel releases it when the process dies, however.
///   A lock the claim gives up is unlocked before it is closed (`release`).
/// - The file is never unlinked or renamed. Others may replace it (a pre-#463 app's atomic write,
///   an editor, the old docs' "delete the file"), so every successful `flock` checks it locked the
///   file that is at the path now.
/// - The payload only describes the holder. The lock decides who holds it.
enum StoreLock {
    enum Kind: String, Sendable {
        case app
        case runJob = "run-job"
        case seedDevHome = "seed-dev-home"
        /// `--perf`'s scratch workspace lock (plan note 3). No GUI ever reads it.
        case perf
    }

    struct Holder: Equatable, Sendable {
        let pid: Int32
        let kind: Kind
        /// The CLI argument as typed. Resolving a name needs the store, which needs the lock.
        let job: String?
    }

    enum Claim: Equatable, Sendable {
        case acquired
        /// Someone else holds it. nil while their payload is empty, unparsable or names a dead pid
        /// (a new holder between its `flock` and its `pwrite`): re-read, don't guess.
        case held(Holder?)
        /// A pre-#463 process: a bare pid naming a live process, in a file it never flocks.
        case legacy(pid: Int32)
        /// The lock could not be taken or advertised: refuse, never open unlocked (decision 4).
        case failed(detail: String)
    }

    /// The syscalls a test needs to fail, plus a hook between the open and the `flock`.
    struct Syscalls: Sendable {
        var flock: @Sendable (Int32, Int32) -> Int32 = { fd, operation in systemFlock(fd, operation) }
        var pwrite: @Sendable (Int32, UnsafeRawPointer, Int, off_t) -> Int = { Darwin.pwrite($0, $1, $2, $3) }
        var afterOpen: @Sendable (_ attempt: Int) -> Void = { _ in }
        /// When a process started (`proc_pidinfo`), nil when it cannot be read. For the bare-pid
        /// staleness check only.
        var processStart: @Sendable (Int32) -> Date? = { ProcessStart.of($0)?.date }
        static let live = Syscalls()
    }

    static let maxAttempts = 3
    static let replacedDetail = "the lock file kept being replaced while it was claimed"

    /// Path to descriptor, for every lock this process holds. Removed only when a re-claim finds the
    /// file replaced, and then the claim runs again on the file at the path (#494).
    private static let descriptors = OSAllocatedUnfairLock<[String: Int32]>(initialState: [:])

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    static func claim(at url: URL, kind: Kind, job: String? = nil, syscalls: Syscalls = .live) -> Claim {
        let path = key(url)
        // Everything that can take time happens here, before the first `flock`: from the `flock`
        // to the `pwrite` only the inode check runs (and one `kill(pid, 0)` for a bare-pid prior
        // payload), so a holder is never unnamed for longer than a few syscalls (decision 5).
        let me = getpid()
        let line = Payload.encode(Holder(pid: me, kind: kind, job: job))
        // This process already holds it (a lock is never released, decision 2): the claim is
        // already won. Re-advertised, so a vacated payload names this process again.
        if let fd = descriptors.withLock({ $0[path] }) {
            if isStillAtPath(fd, path) { return readvertise(fd, line, path, syscalls) }
            // Replaced by rename since (#494): the hold is on an orphan and protects nothing, so
            // let it go and claim the file that is there now, like any first claim.
            descriptors.withLock { $0[path] = nil }
            release(fd)
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(detail: "could not create \(directory.path): \(error.localizedDescription)")
        }
        for attempt in 0..<maxAttempts {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return .failed(detail: errnoDetail("open", path, errno)) }
            syscalls.afterOpen(attempt)
            // Read before the `flock` (plan note 1): only a bare pid matters here, and a pre-#463
            // writer replaces the file by path, which the inode check below catches.
            let priorPid = Payload.legacyPid(readAll(fd))
            // A bare pid whose process started after the file was written is a reused pid, not
            // the pre-#463 writer: that file is stale, and this claim takes it over.
            let staleLegacy = priorPid.map { isReusedPid($0, writtenAt: mtime(fd), syscalls: syscalls) } ?? false
            guard syscalls.flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(fd)
                if code == EWOULDBLOCK { return .held(readHolder(at: url)) }
                return .failed(detail: errnoDetail("flock", path, code))
            }
            guard isStillAtPath(fd, path) else {
                release(fd)
                continue
            }
            if let pid = priorPid, pid != me, !staleLegacy, isAlive(pid) {
                release(fd)   // a lock this process never advertised
                return .legacy(pid: pid)
            }
            let written = line.withUnsafeBytes { syscalls.pwrite(fd, $0.baseAddress!, $0.count, 0) }
            guard written == line.count else {
                let code = errno
                abandon(fd)
                if written >= 0 { return .failed(detail: "write \(path): wrote \(written) of \(line.count) bytes") }
                return .failed(detail: errnoDetail("write", path, code))
            }
            guard ftruncate(fd, off_t(line.count)) == 0 else {
                let code = errno
                abandon(fd)
                return .failed(detail: errnoDetail("truncate", path, code))
            }
            descriptors.withLock { $0[path] = fd }
            return .acquired
        }
        return .failed(detail: "\(replacedDetail): \(path)")
    }

    /// A re-claim's payload. A short or failed write empties the file, so no part of the new line
    /// sits on the old one's tail, and is `.failed`. The lock is kept: this process may already have
    /// the store open, and letting go would let a second writer in (#494).
    private static func readvertise(_ fd: Int32, _ line: Data, _ path: String, _ syscalls: Syscalls) -> Claim {
        let written = line.withUnsafeBytes { syscalls.pwrite(fd, $0.baseAddress!, $0.count, 0) }
        guard written == line.count else {
            let code = errno
            _ = ftruncate(fd, 0)
            if written >= 0 { return .failed(detail: "write \(path): wrote \(written) of \(line.count) bytes") }
            return .failed(detail: errnoDetail("write", path, code))
        }
        guard ftruncate(fd, off_t(line.count)) == 0 else {
            let code = errno
            _ = ftruncate(fd, 0)
            return .failed(detail: errnoDetail("truncate", path, code))
        }
        return .acquired
    }

    /// Allowance between the clock that stamps a process's start and the one that stamps a file.
    static let clockSlack: TimeInterval = 1

    /// True when `pid` cannot be the process that wrote a file at `writtenAt`: it started later,
    /// so the kernel handed the pid out again after the writer died. Fails open: a start that
    /// cannot be read (no such process, or `EPERM` for another user's, which a pre-#463 Iris of
    /// this user's never is) is a reused pid too, so a stale file never refuses every launch.
    static func isReusedPid(_ pid: Int32, writtenAt: Date?, syscalls: Syscalls) -> Bool {
        guard let writtenAt else { return false }
        guard let started = syscalls.processStart(pid) else { return true }
        return started > writtenAt.addingTimeInterval(clockSlack)
    }

    private static func mtime(_ fd: Int32) -> Date? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let m = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(m.tv_sec) + TimeInterval(m.tv_nsec) / 1_000_000_000)
    }

    /// Gives up a lock this process holds but failed to advertise. Empties the file first, while
    /// the lock is still held, so no partial line or stale payload outlives the failed claim.
    private static func abandon(_ fd: Int32) {
        _ = ftruncate(fd, 0)
        release(fd)
    }

    /// Unlocks, then closes. `close` alone releases nothing while another reference to the open
    /// file description exists, and a child mid-`posix_spawn` or between `fork` and `exec` holds
    /// one, `O_CLOEXEC` or not, until its exec. `LOCK_UN` acts on the description itself.
    private static func release(_ fd: Int32) {
        _ = systemFlock(fd, LOCK_UN)
        close(fd)
    }

    /// `claim`, retrying a held lock whose holder has not said what it is, for up to `settle`
    /// seconds (decision 5's re-read). For the CLI and the seeder, which may block; the app counts
    /// the same second across its polls instead (plan note 2).
    /// Blocks its thread with `usleep`: never call it from the cooperative pool (invariant 4).
    static func claimSettling(at url: URL, kind: Kind, job: String? = nil, settle: TimeInterval = 1,
                              syscalls: Syscalls = .live) -> Claim {
        let deadline = Date().addingTimeInterval(settle)
        while true {
            let result = claim(at: url, kind: kind, job: job, syscalls: syscalls)
            guard case .held(nil) = result, Date() < deadline else { return result }
            usleep(100_000)
        }
    }

    static func holds(_ url: URL) -> Bool {
        let path = key(url)
        return descriptors.withLock { $0[path] != nil }
    }

    /// Empties this process's payload on a clean exit. The lock stays held until the process
    /// ends. A no-op for a path this process does not hold: a refused or waiting process must
    /// never erase the holder's payload.
    static func vacate(at url: URL) {
        let path = key(url)
        guard let fd = descriptors.withLock({ $0[path] }) else { return }
        _ = ftruncate(fd, 0)
    }

    static func descriptor(for url: URL) -> Int32? {
        let path = key(url)
        return descriptors.withLock { $0[path] }
    }

    /// Who the payload names, if it names a live process. Its own descriptor, opened and closed
    /// here: harmless with `flock`, which no other descriptor's close can release.
    static func readHolder(at url: URL) -> Holder? {
        let fd = open(key(url), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let holder = Payload.decode(readAll(fd)), isAlive(holder.pid) else { return nil }
        return holder
    }

    /// Signal 0 asks the kernel without sending anything. `EPERM` is alive and somebody else's.
    static func isAlive(_ pid: Int32) -> Bool { IrisDefaults.isProcessAlive(pid) }

    enum Payload {
        /// Caps `job` in Unicode scalars, not graphemes: a scalar is at most 6 bytes once encoded
        /// (`\uXXXX`), so the line stays far below `readAll`'s 4 KiB and always reads back whole.
        static let maxJobScalars = 256

        static func encode(_ holder: Holder) -> Data {
            var object: [String: Any] = ["pid": Int(holder.pid), "kind": holder.kind.rawValue]
            if let job = holder.job {
                var scalars = String.UnicodeScalarView()
                scalars.append(contentsOf: job.unicodeScalars.prefix(maxJobScalars))
                object["job"] = String(scalars)
            }
            let json = (try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return json + Data("\n".utf8)
        }

        /// Up to the first newline only. A line with none was never finished.
        static func decode(_ data: Data) -> Holder? {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
                  let object = try? JSONSerialization.jsonObject(with: Data(data[data.startIndex..<newline])) as? [String: Any],
                  let pid = object["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
                  let raw = object["kind"] as? String, let kind = Kind(rawValue: raw) else { return nil }
            return Holder(pid: Int32(pid), kind: kind, job: object["job"] as? String)
        }

        /// The whole file as a bare positive pid: what pre-#463 binaries wrote.
        static func legacyPid(_ data: Data) -> Int32? {
            guard let text = String(data: data, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
            return pid
        }
    }

    private static func readAll(_ fd: Int32) -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
        return count > 0 ? Data(buffer[..<count]) : Data()
    }

    private static func isStillAtPath(_ fd: Int32, _ path: String) -> Bool {
        var mine = stat()
        var there = stat()
        guard fstat(fd, &mine) == 0, stat(path, &there) == 0 else { return false }
        return mine.st_dev == there.st_dev && mine.st_ino == there.st_ino
    }

    private static func errnoDetail(_ call: String, _ path: String, _ code: Int32) -> String {
        "\(call) \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// When a process started, as the kernel records it. A pid the kernel hands out again belongs to
/// a process that started later (restored from D2's `LaunchLock`, deleted in #463 Task 6).
struct ProcessStart: Equatable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
    }

    /// nil when no process has that pid, and also when it belongs to another user
    /// (`proc_pidinfo` fails with `EPERM`). Callers treat nil as "not the writer" (fail open).
    static func of(_ pid: Int32) -> ProcessStart? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}
