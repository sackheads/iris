import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decisions 1-5: one lifetime `flock` per home, the inode check, the payload written
/// inside the claim, and `.failed`/`.legacy`. Real `flock` on temp files; never a real home.
/// Every claim here is held for the rest of the test process (decision 2), so every test uses a
/// path of its own.
@Suite("StoreLock (#463)", .timeLimit(.minutes(1)))
final class StoreLockTests {
    /// Swift Testing makes one instance per test, so `deinit` removes that test's files (a
    /// crowded `TMPDIR` slows Foundation's listings to seconds, #309).
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-storelock-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    private func path(_ name: String = "store") -> URL {
        base.appendingPathComponent(UUID().uuidString).appendingPathComponent("\(name).sqlite.lock")
    }

    private var me: Int32 { ProcessInfo.processInfo.processIdentifier }

    @Test("a claim acquires, and writes its own payload before it returns")
    func payloadIsThereWhenClaimReturns() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .runJob, job: "pr sweep") == .acquired)
        let line = try Data(contentsOf: url)
        #expect(StoreLock.Payload.decode(line) == .init(pid: me, kind: .runJob, job: "pr sweep"))
        #expect(String(decoding: line, as: UTF8.self) == #"{"job":"pr sweep","kind":"run-job","pid":\#(me)}"# + "\n")
        #expect(StoreLock.holds(url))
    }

    @Test("Review Focus 1: a claim creates a home that does not exist yet")
    func claimCreatesTheMissingHome() throws {
        let url = path()
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
    }

    @Test("a second claim in one process reuses its hold and re-advertises, and another process is still excluded")
    func secondClaimReusesTheHold() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        let fd = StoreLock.descriptor(for: url)
        StoreLock.vacate(at: url)
        #expect(StoreLock.claim(at: url, kind: .runJob, job: "again") == .acquired)
        #expect(StoreLock.descriptor(for: url) == fd, "the same descriptor: nothing reopened or released")
        #expect(StoreLock.readHolder(at: url) == .init(pid: me, kind: .runJob, job: "again"))
        #expect(LockStub.tryLock(url) == 3)
    }

    /// #494: a re-claim checks the inode too. A file replaced by rename leaves this process's lock
    /// on an orphan that protects nothing, so the claim takes the file now at the path instead.
    @Test("a re-claim after the file was replaced claims the new file, and the payload lands on it")
    func reclaimAfterReplacement() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh")
        FileManager.default.createFile(atPath: fresh.path, contents: nil)
        #expect(rename(fresh.path, url.path) == 0)

        #expect(StoreLock.claim(at: url, kind: .runJob, job: "again") == .acquired)
        let fd = try #require(StoreLock.descriptor(for: url))
        var mine = stat()
        var there = stat()
        #expect(fstat(fd, &mine) == 0)
        #expect(stat(url.path, &there) == 0)
        #expect(mine.st_ino == there.st_ino && mine.st_dev == there.st_dev, "the lock is on the file at the path")
        #expect(StoreLock.readHolder(at: url) == .init(pid: me, kind: .runJob, job: "again"))
        #expect(LockStub.tryLock(url) == 3, "another process is excluded from the new file")
    }

    /// #522: `vacate` looked the descriptor up, let the table's lock go, then truncated it. Since
    /// #494 a re-claim closes a replaced file's descriptor, and the next `open` reuses the lowest
    /// free number, so a re-claim landing in that gap left `vacate` truncating the *new* holder's
    /// payload. Here the re-claim is started from inside `vacate`, at the gap: with the fix it
    /// blocks on the table until `vacate` is done with the old file, and the new payload survives.
    /// Each round takes a path of its own; ten of them make the number reuse all but certain if
    /// the gap were still open. Run off the pool, so the waits park a dispatch thread, not a
    /// cooperative one (#486).
    @Test("a re-claim racing vacate never lets vacate empty the new holder's payload (#522)")
    func vacateRacingReclaimKeepsTheNewPayload() async throws {
        for _ in 0..<10 {
            let url = path()
            #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
            let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh")
            FileManager.default.createFile(atPath: fresh.path, contents: nil)
            #expect(rename(fresh.path, url.path) == 0)

            let reclaimed = await withCheckedContinuation { (c: CheckedContinuation<StoreLock.Claim?, Never>) in
                DispatchQueue.global().async {
                    let done = DispatchSemaphore(value: 0)
                    let result = Locked<StoreLock.Claim?>(nil)
                    StoreLock.vacate(at: url, beforeTruncate: {
                        DispatchQueue.global().async {
                            result.mutate { $0 = StoreLock.claim(at: url, kind: .runJob, job: "again") }
                            done.signal()
                        }
                        _ = done.wait(timeout: .now() + 0.2)   // a gap left open would let it finish here
                    })
                    _ = done.wait(timeout: .now() + 5)
                    c.resume(returning: result.value)
                }
            }
            #expect(reclaimed == .acquired)
            #expect(StoreLock.readHolder(at: url) == .init(pid: me, kind: .runJob, job: "again"),
                    "vacate emptied the payload of the file claimed after it looked the descriptor up")
        }
    }

    /// #494: a short re-advertise leaves no mixed line. The lock is kept: this process may already
    /// have the store open, and letting go would let a second writer in.
    @Test("a short re-claim write is .failed, empties the payload, and keeps the lock")
    func shortReclaimWrite() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .runJob, job: "a fairly long first job name") == .acquired)
        var calls = StoreLock.Syscalls.live
        calls.pwrite = { fd, buffer, count, offset in Darwin.pwrite(fd, buffer, count / 2, offset) }
        guard case .failed(let detail) = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(detail.contains("wrote"))
        #expect(try Data(contentsOf: url).isEmpty, "no half line mixed with the old payload's tail")
        #expect(StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 3, "still held")
    }

    @Test("a dropped claim still excludes another process")
    func droppedClaimStillExcludes() {
        let url = path()
        _ = StoreLock.claim(at: url, kind: .runJob)
        #expect(StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 3, "another process cannot take it")
    }

    @Test("the descriptor is close-on-exec from the open")
    func descriptorIsCloexec() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        let fd = try #require(StoreLock.descriptor(for: url))
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test("a stub holding the lock blocks a claim, and SIGKILLing it frees the lock")
    func stubBlocksThenFrees() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url, payload: #"{"job":"nap","kind":"run-job","pid":%PID%}"# + "\n")
        #expect(StoreLock.claim(at: url, kind: .app) == .held(.init(pid: stub.pid, kind: .runJob, job: "nap")))
        stub.kill()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        #expect(StoreLock.readHolder(at: url) == .init(pid: me, kind: .app, job: nil), "the stale payload was overwritten")
    }

    @Test("a holder with no payload yet is held by nobody named")
    func emptyPayloadIsUnknown() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url)
        defer { stub.kill() }
        #expect(StoreLock.claim(at: url, kind: .app) == .held(nil))
    }

    @Test("claimSettling waits up to its bound for a holder to say what it is")
    func settlingGivesUpAtTheBound() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url)
        defer { stub.kill() }
        let started = Date()
        #expect(StoreLock.claimSettling(at: url, kind: .runJob, settle: 0.3) == .held(nil))
        #expect(Date().timeIntervalSince(started) >= 0.3)
    }

    @Test("a path replaced between the open and the flock is detected, and the claim reopens")
    func replacedPathIsDetected() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let holder = LockedCell<LockStub?>(nil)
        var calls = StoreLock.Syscalls.live
        calls.afterOpen = { attempt in
            guard attempt == 0 else { return }
            // A pre-#463 app's atomic write: a new file renamed over the path, which a live
            // holder then locks. The claim's descriptor is on the old, unlinked inode.
            let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh")
            FileManager.default.createFile(atPath: fresh.path, contents: nil)
            _ = rename(fresh.path, url.path)
            holder.value = try? LockStub.start(holding: url, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        }
        let claim = StoreLock.claim(at: url, kind: .runJob, syscalls: calls)
        let stub = try #require(holder.value)
        defer { stub.kill() }
        #expect(claim == .held(.init(pid: stub.pid, kind: .app, job: nil)),
                "locking the unlinked inode is not holding the store")
    }

    @Test("a path that keeps being replaced fails after 3 tries")
    func endlessReplacementFails() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tries = LockedCell(0)
        var calls = StoreLock.Syscalls.live
        calls.afterOpen = { _ in
            tries.value += 1
            let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh-\(tries.value)")
            FileManager.default.createFile(atPath: fresh.path, contents: nil)
            _ = rename(fresh.path, url.path)
        }
        guard case .failed(let detail) = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(detail.contains(StoreLock.replacedDetail))
        #expect(tries.value == StoreLock.maxAttempts)
    }

    @Test("a flock that fails with anything but EWOULDBLOCK is .failed, naming the path and the errno")
    func flockErrorIsFailed() {
        let url = path()
        var calls = StoreLock.Syscalls.live
        calls.flock = { _, _ in errno = ENOTSUP; return -1 }
        guard case .failed(let detail) = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(detail.contains(url.lastPathComponent))
        #expect(detail.contains("errno \(ENOTSUP)"))
        #expect(!StoreLock.holds(url))
    }

    @Test("a failed payload write unlocks and closes the descriptor, so the lock is free again")
    func failedWriteReleases() {
        let url = path()
        var calls = StoreLock.Syscalls.live
        calls.pwrite = { _, _, _, _ in errno = ENOSPC; return -1 }
        guard case .failed = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(!StoreLock.holds(url))
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired, "a lock it never advertised was released")
    }

    /// What a child mid-`posix_spawn` holds until its exec: another reference to the claim's open
    /// file description. `F_DUPFD_CLOEXEC`, so the copy itself never reaches a child.
    private func copyingDescriptor(into copies: LockedCell<[Int32]>) -> @Sendable (Int32) -> Void {
        { fd in copies.value.append(fcntl(fd, F_DUPFD_CLOEXEC, 0)) }
    }

    @Test("a failed write unlocks, so another reference to the descriptor (a child yet to exec) keeps nothing held")
    func failedWriteUnlocksDespiteAnotherReference() {
        let url = path()
        let copies = LockedCell<[Int32]>([])
        defer { copies.value.forEach { close($0) } }
        let copy = copyingDescriptor(into: copies)
        var calls = StoreLock.Syscalls.live
        calls.pwrite = { fd, _, _, _ in copy(fd); errno = ENOSPC; return -1 }
        guard case .failed = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(copies.value.count == 1)
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired, "close alone left the copy holding the lock")
    }

    @Test("a .legacy refusal unlocks, so another reference to the descriptor keeps nothing held")
    func legacyRefusalUnlocksDespiteAnotherReference() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(getppid())\n".utf8).write(to: url)   // as bareLivePidIsLegacy
        let copies = LockedCell<[Int32]>([])
        defer { copies.value.forEach { close($0) } }
        let copy = copyingDescriptor(into: copies)
        var calls = StoreLock.Syscalls.live
        calls.flock = { fd, operation in copy(fd); return flock(fd, operation) }
        #expect(StoreLock.claim(at: url, kind: .app, syscalls: calls) == .legacy(pid: getppid()))
        #expect(LockStub.tryLock(url) == 0, "close alone left the copy holding the lock")
    }

    @Test("a short payload write is .failed, leaves the file empty, and frees the lock")
    func shortWriteLeavesNothingBehind() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"kind":"app","pid":999999}"# + "\n").utf8).write(to: url)   // a dead holder's line
        var calls = StoreLock.Syscalls.live
        calls.pwrite = { fd, buffer, count, offset in Darwin.pwrite(fd, buffer, count / 2, offset) }
        guard case .failed(let detail) = StoreLock.claim(at: url, kind: .runJob, job: "half", syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(detail.contains("wrote"))
        #expect(try Data(contentsOf: url).isEmpty, "no half line and no stale payload outlive the claim")
        #expect(!StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 0)
    }

    @Test("a lock file replaced once with nobody holding it is reopened, and the payload lands on the new inode")
    func replacedOnceWithoutHolderAcquires() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let tries = LockedCell(0)
        var calls = StoreLock.Syscalls.live
        calls.afterOpen = { attempt in
            tries.value += 1
            guard attempt == 0 else { return }
            let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh")
            FileManager.default.createFile(atPath: fresh.path, contents: nil)
            _ = rename(fresh.path, url.path)
        }
        #expect(StoreLock.claim(at: url, kind: .app, syscalls: calls) == .acquired)
        #expect(tries.value == 2, "the first descriptor was on the replaced inode")
        let fd = try #require(StoreLock.descriptor(for: url))
        var mine = stat()
        var there = stat()
        #expect(fstat(fd, &mine) == 0)
        #expect(stat(url.path, &there) == 0)
        #expect(mine.st_ino == there.st_ino && mine.st_dev == there.st_dev)
        #expect(StoreLock.readHolder(at: url) == .init(pid: me, kind: .app, job: nil))
        #expect(LockStub.tryLock(url) == 3)
    }

    @Test("a long job is capped, so the payload always fits the read and decodes")
    func longJobIsCapped() {
        let job = String(repeating: "\u{1}", count: 5000)   // each escapes to six bytes
        let line = StoreLock.Payload.encode(.init(pid: 7, kind: .runJob, job: job))
        #expect(line.count < 4096)
        let decoded = StoreLock.Payload.decode(line)
        #expect(decoded?.job?.unicodeScalars.count == StoreLock.Payload.maxJobScalars)
    }

    @Test("a bare pid naming a live process is a pre-#463 holder, .legacy")
    func bareLivePidIsLegacy() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The test runner's parent: alive, this user's, not us, and started before the file was
        // written. Not launchd: its start time is another user's, so it reads as a reused pid.
        let parent = getppid()
        try Data("\(parent)\n".utf8).write(to: url)
        #expect(StoreLock.claim(at: url, kind: .app) == .legacy(pid: parent))
        #expect(!StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 0, "the refused claim let go of the lock")
    }

    /// A bare pid naming launchd (alive, not us), with its start time chosen by the seam.
    private func legacyClaim(started: Date?) throws -> (URL, StoreLock.Claim) {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: url)
        var syscalls = StoreLock.Syscalls()
        syscalls.processStart = { _ in started }
        return (url, StoreLock.claim(at: url, kind: .app, syscalls: syscalls))
    }

    @Test("a bare live pid whose process started after the file was written is a reused pid: stale, taken over")
    func reusedLegacyPidIsTakenOver() throws {
        let (url, claim) = try legacyClaim(started: Date().addingTimeInterval(3600))
        #expect(claim == .acquired)
        #expect(StoreLock.readHolder(at: url) == .init(pid: me, kind: .app, job: nil))
    }

    @Test("a bare live pid whose process started before the file was written is still .legacy")
    func olderLegacyPidStillRefuses() throws {
        let (url, claim) = try legacyClaim(started: Date().addingTimeInterval(-3600))
        #expect(claim == .legacy(pid: 1))
        #expect(!StoreLock.holds(url))
    }

    /// #494: the edges of `clockSlack`, so a change to its value or to the comparison is caught.
    @Test("a start within the clock slack of the write is the writer; one past it is a reused pid")
    func clockSlackBoundary() {
        let written = Date(timeIntervalSince1970: 1_000_000)
        func reused(_ offset: TimeInterval) -> Bool {
            var syscalls = StoreLock.Syscalls()
            syscalls.processStart = { _ in written.addingTimeInterval(offset) }
            return StoreLock.isReusedPid(1, writtenAt: written, syscalls: syscalls)
        }
        #expect(StoreLock.clockSlack == 1)
        #expect(!reused(0.5), "inside the slack")
        #expect(!reused(1.0), "exactly at the slack is still the writer")
        #expect(reused(1.5), "just past the slack")
        #expect(!reused(-0.5))
    }

    @Test("a start time that cannot be read (EPERM) fails open: the file is stale")
    func unreadableStartFailsOpen() throws {
        let (_, claim) = try legacyClaim(started: nil)
        #expect(claim == .acquired)
    }

    @Test("a bare pid naming nobody is stale, and the claim takes it")
    func bareDeadPidIsStale() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("999999\n".utf8).write(to: url)
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
    }

    @Test("the payload round-trips, and anything partial or foreign reads as nil")
    func payloadCodec() {
        let holder = StoreLock.Holder(pid: 42, kind: .seedDevHome, job: nil)
        #expect(StoreLock.Payload.decode(StoreLock.Payload.encode(holder)) == holder)
        let withJob = StoreLock.Holder(pid: 7, kind: .runJob, job: "line\nbreak \"quoted\"")
        #expect(StoreLock.Payload.decode(StoreLock.Payload.encode(withJob)) == withJob)
        #expect(StoreLock.Payload.decode(Data(#"{"kind":"app","pid":42}"#.utf8)) == nil, "no newline: half-written")
        #expect(StoreLock.Payload.decode(Data()) == nil)
        #expect(StoreLock.Payload.decode(Data((#"{"kind":"toaster","pid":42}"# + "\n").utf8)) == nil)
        #expect(StoreLock.Payload.decode(Data("42\n".utf8)) == nil)
        #expect(StoreLock.Payload.legacyPid(Data("42\n".utf8)) == 42)
        #expect(StoreLock.Payload.legacyPid(StoreLock.Payload.encode(holder)) == nil)
    }

    @Test("vacate empties this process's payload and keeps the lock")
    func vacateEmptiesAndKeeps() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .runJob) == .acquired)
        StoreLock.vacate(at: url)
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 3)
    }

    @Test("Review Focus 2: vacate is a no-op for a path this process does not hold")
    func vacateIsANoOpForANonHolder() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url, payload: #"{"kind":"run-job","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        StoreLock.vacate(at: url)
        #expect(StoreLock.readHolder(at: url) == .init(pid: stub.pid, kind: .runJob, job: nil))
    }
}
