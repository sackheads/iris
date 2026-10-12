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

    @Test("two claims in one process conflict, and the second names the first")
    func twoClaimsConflict() {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        #expect(StoreLock.claim(at: url, kind: .runJob) == .held(.init(pid: me, kind: .app, job: nil)))
    }

    @Test("a dropped claim still excludes, in this process and in another")
    func droppedClaimStillExcludes() {
        let url = path()
        _ = StoreLock.claim(at: url, kind: .runJob)
        #expect(StoreLock.claim(at: url, kind: .app) != .acquired)
        #expect(LockStub.tryLock(url) == 3, "another process cannot take it either")
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

    @Test("a failed payload write is .failed and closes the descriptor, so the lock is free again")
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
        try Data("1\n".utf8).write(to: url)   // launchd: alive, and not us
        #expect(StoreLock.claim(at: url, kind: .app) == .legacy(pid: 1))
        #expect(!StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 0, "the refused claim let go of the lock")
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
