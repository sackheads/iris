import Testing
import Foundation
@testable import IrisKit

/// #532: the file tools' blocking I/O runs off the cooperative pool, a cancel answers at once, and
/// a cancelled write commits nothing.
@Suite("Blocking file I/O off the cooperative pool (#532)", .timeLimit(.minutes(1)))
struct OffPoolTests {
    /// Stands in for a hung mount: blocks the work until released, and records its queue.
    final class Hang: @unchecked Sendable {
        private let lock = NSCondition()
        private var released = false
        private var entered = false
        private var label = ""
        var isInside: Bool { lock.withLock { entered } }
        var queueLabel: String { lock.withLock { label } }
        func release() { lock.lock(); released = true; lock.broadcast(); lock.unlock() }
        func block() {
            let here = String(cString: __dispatch_queue_get_label(nil))
            lock.lock(); defer { lock.unlock() }
            label = here
            entered = true
            let deadline = Date().addingTimeInterval(20)
            while !released && lock.wait(until: deadline) {}
        }
    }

    private static func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition(), "timed out waiting for \(what)")
    }

    /// Runs `call` with the hook hung, cancels it once the work is inside, and returns what it
    /// answered, how long the cancel took, and the queue the work ran on.
    private func cancelWhileHung(_ call: @escaping @Sendable () async -> String) async throws
        -> (answer: String, seconds: Double, queue: String, hang: Hang) {
        let hang = Hang()
        let task = Task { await OffPool.$testHook.withValue({ hang.block() }) { await call() } }
        await Self.eventually("the work to start") { hang.isInside }
        let asked = Date()
        task.cancel()
        let answer = try await value(of: task, within: 5)
        return (answer, Date().timeIntervalSince(asked), hang.queueLabel, hang)
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-532-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: The helper

    @Test("the work runs on a dispatch queue, not a cooperative-pool thread")
    func runsOffThePool() async {
        let label = await OffPool.run(cancelled: "cancelled") { _ in String(cString: __dispatch_queue_get_label(nil)) }
        #expect(!label.contains("cooperative"), "ran on \(label)")
        #expect(label != "cancelled")
    }

    @Test("a cancel answers at once with the cancelled value, and the late answer is dropped")
    func cancelIsPromptAndTheLateAnswerIsDropped() async throws {
        let (answer, seconds, _, hang) = try await cancelWhileHung {
            await OffPool.run(cancelled: "cancelled") { _ in "late" }
        }
        #expect(answer == "cancelled")
        #expect(seconds < 2)
        hang.release()                                   // the work now finishes and resumes again: a no-op
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test("the work sees the cancel, so it can decline to commit")
    func workSeesTheCancel() async throws {
        let saw = OneShot<Bool>()
        let (_, _, _, hang) = try await cancelWhileHung {
            await OffPool.run(cancelled: "cancelled") { cancel in saw.resume(cancel.isCancelled); return "done" }
        }
        hang.release()
        #expect(await saw.wait() == true)
    }

    // MARK: Every site

    enum Site: String, CaseIterable { case read, write, grantRead, grantWrite, approvedRead, decidedRead, decidedWrite, directorySize }

    @Test("each blocking site runs off the pool and a cancel answers within 2 s, never as success or empty",
          arguments: Site.allCases)
    func everySite(site: Site) async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try "old".write(to: dir.appendingPathComponent("f.txt"), atomically: false, encoding: .utf8)
        let path = dir.appendingPathComponent("f.txt").path
        let executor = ToolExecutor()
        let call: @Sendable () async -> String
        switch site {
        case .read: call = { await executor.execute(name: "read_file", args: ["path": .string(path)]) }
        case .write: call = { await executor.execute(name: "write_file", args: ["path": .string(path), "content": .string("new")]) }
        case .grantRead: call = { await executor.readFile(grantRoot: dir.path, relative: ["f.txt"]) }
        case .grantWrite: call = { await executor.writeFile(grantRoot: dir.path, relative: ["f.txt"], content: "new") }
        case .approvedRead: call = { await executor.readFile(approvedWorkspace: dir.path, relative: ["f.txt"]) }
        case .decidedRead: call = { await executor.readFile(decided: path) }
        case .decidedWrite: call = { await executor.writeFile(decided: path, content: "new") }
        case .directorySize: call = { await GoalWorkspacesSection.size(of: dir).map(String.init) ?? "cancelled" }
        }
        let (answer, seconds, queue, hang) = try await cancelWhileHung(call)
        defer { hang.release() }
        #expect(!queue.contains("cooperative"), "\(site) ran on \(queue)")
        #expect(seconds < 2, "\(site): the cancel took \(seconds) s")
        switch site {
        case .read, .grantRead, .approvedRead, .decidedRead: #expect(answer == ToolExecutor.readCancelled)
        case .write, .grantWrite, .decidedWrite: #expect(answer == ToolExecutor.writeCancelled)
        case .directorySize: #expect(answer == "cancelled")
        }
    }

    // MARK: The commit gate

    @Test("a write cancelled before its rename leaves the target unchanged and no temp file", arguments: [false, true])
    func cancelledWriteCommitsNothing(granted: Bool) async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("f.txt")
        try "old".write(to: target, atomically: false, encoding: .utf8)
        let executor = ToolExecutor()
        let (answer, _, _, hang) = try await cancelWhileHung {
            granted
                ? await executor.writeFile(grantRoot: dir.path, relative: ["f.txt"], content: "new")
                : await executor.execute(name: "write_file", args: ["path": .string(target.path), "content": .string("new")])
        }
        #expect(answer == ToolExecutor.writeCancelled)
        hang.release()                                   // the write now runs, sees the cancel, and stops short of renaming
        await Self.eventually("the staging file to be gone") {
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["f.txt"]
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old", "nothing was committed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["f.txt"], "no temp file left")
    }

    @Test("an uncancelled write still lands, keeping an existing file's mode", arguments: [false, true])
    func uncancelledWriteLands(granted: Bool) async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("f.txt")
        try "old".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: target.path)
        let executor = ToolExecutor()
        let answer = granted
            ? await executor.writeFile(grantRoot: dir.path, relative: ["f.txt"], content: "new")
            : await executor.execute(name: "write_file", args: ["path": .string(target.path), "content": .string("new")])
        #expect(answer.hasPrefix("Successfully wrote to"), "\(answer)")
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o750)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["f.txt"])
    }
}
