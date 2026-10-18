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
            let deadline = TestClock.deadline(20)
            while !released && lock.wait(until: deadline) {}
        }
    }

    private static func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition(), "timed out waiting for \(what)")
    }

    /// A `OneShot` that is never resumed fails the test at the bound instead of hanging the run.
    private static func answer<T: Sendable>(of shot: OneShot<T>, within seconds: Double = 5) async throws -> T {
        try await value(of: Task { await shot.wait() }, within: seconds)
    }

    /// Runs `call` with the hook hung, cancels it once the work is inside, and returns what it
    /// answered, how long the cancel took, and the queue the work ran on.
    private func cancelWhileHung(_ call: @escaping @Sendable () async -> String) async throws
        -> (answer: String, seconds: Double, queue: String, hang: Hang) {
        let hang = Hang()
        let task = Task { await OffPool.$testHook.withValue({ hang.block() }) { await call() } }
        await Self.eventually("the work to start") { hang.isInside }
        let asked = TestClock.now()
        task.cancel()
        // Above every site's `cancelBound` (a main-actor hop can be slow, #594) and below the
        // 20 s hang, so a cancel that waited the hang out still fails here.
        let answer = try await value(of: task, within: 15)
        return (answer, TestClock.seconds(since: asked), hang.queueLabel, hang)
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
        #expect(try await Self.answer(of: saw) == true)
    }

    @Test("a call that is already cancelled when it starts answers cancelled at once")
    func alreadyCancelledEntry() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await OffPool.run(cancelled: "cancelled") { _ in
                Thread.sleep(forTimeInterval: 5)
                return "late"
            }
        }
        task.cancel()
        let asked = TestClock.now()
        #expect(try await value(of: task, within: 3) == "cancelled")
        #expect(TestClock.seconds(since: asked) < 2)
    }

    @Test("the first answer wins: a second resume changes nothing")
    func firstAnswerWins() async throws {
        let shot = OneShot<String>()
        shot.resume("first")
        shot.resume("second")
        #expect(try await Self.answer(of: shot) == "first")
        let late = OneShot<String>()
        let waiter = Task { await late.wait() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        late.resume("first")
        late.resume("second")
        #expect(try await value(of: waiter, within: 5) == "first")
    }

    // MARK: Every site

    enum Site: String, CaseIterable { case read, write, grantRead, grantWrite, approvedRead, decidedRead, decidedWrite, directorySize }

    /// How soon a cancel must answer. `Hang` holds the syscall for 20 s, so any bound well under that
    /// proves the cancel did not wait it out. 2 s for the nonisolated sites. `directorySize` is
    /// `GoalWorkspacesSection.size(of:)`, a main-actor view helper: its cancel answers off the pool at
    /// once, but handing the answer back needs the main actor, and under a starved main actor (load
    /// 48-97 with the disk full) that hop alone took over 2 s (#594). That hop is inherent and
    /// harmless, so the bound there allows for it.
    static func cancelBound(_ site: Site) -> Double { site == .directorySize ? 10 : 2 }

    @Test("each blocking site runs off the pool and a cancel answers well within the 20 s hang, never as success or empty",
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
        #expect(seconds < Self.cancelBound(site), "\(site): the cancel took \(seconds) s")
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

    /// The other order (#548 review): a cancel that lands after the commit gate does not answer
    /// early. The write renames and its own success sentence is the answer, so the engine records
    /// the path and a SKILL.md write still invalidates the skill cache.
    @Test("a write cancelled after its commit gate lands, and answers success", arguments: [false, true])
    func cancelAfterTheGateLands(granted: Bool) async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("f.txt")
        try "old".write(to: target, atomically: false, encoding: .utf8)
        let executor = ToolExecutor()
        let hang = Hang()
        let task = Task {
            await OffPool.$afterCommitGateHook.withValue({ hang.block() }) {
                granted
                    ? await executor.writeFile(grantRoot: dir.path, relative: ["f.txt"], content: "new")
                    : await executor.execute(name: "write_file", args: ["path": .string(target.path), "content": .string("new")])
            }
        }
        await Self.eventually("the write to pass its commit gate") { hang.isInside }
        task.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        hang.release()
        let answer = try await value(of: task, within: 5)
        #expect(answer == "Successfully wrote to \(target.path)", "\(answer)")
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        #expect(IrisEngine.writtenPaths(tool: "write_file", args: ["path": .string(target.path)], cwd: nil,
                                        result: answer) == [target.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["f.txt"])
    }

    @Test("a SKILL.md write cancelled after its gate still invalidates the skill cache")
    func cancelAfterTheGateInvalidatesSkills() async throws {
        let folder = IrisPaths.default.skillsDir.appendingPathComponent("probe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let skill = folder.appendingPathComponent("SKILL.md")
        let invalidated = OneShot<Bool>()
        var executor = ToolExecutor()
        executor.onSkillsChanged = { invalidated.resume(true) }
        let hang = Hang()
        let call = executor
        let task = Task {
            await OffPool.$afterCommitGateHook.withValue({ hang.block() }) {
                await call.execute(name: "write_file", args: ["path": .string(skill.path),
                                                               "content": .string("---\nname: x\n---\nbody")])
            }
        }
        await Self.eventually("the write to pass its commit gate") { hang.isInside }
        task.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        hang.release()
        let answer = try await value(of: task, within: 5)
        #expect(answer.hasPrefix("Successfully wrote to"), "\(answer)")
        #expect(try await Self.answer(of: invalidated) == true)
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
