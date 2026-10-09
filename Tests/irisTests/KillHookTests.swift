import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #377: each runner's kill ladder runs a caller's hook on the ladder's own queue, so what a caller
/// has to do beyond the child's reach — the in-VM group kill, an ephemeral `container delete` —
/// happens with the kill and needs no pool thread. The hook runs when the ladder killed something,
/// and never otherwise.
@Suite("Kill hooks run on the ladder", .timeLimit(.minutes(1)))
struct KillHookTests {
    /// Every hook call, with the dispatch queue it ran on.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String] = []
        var hook: @Sendable () -> Void {
            { [self] in
                let label = String(cString: __dispatch_queue_get_label(nil))
                lock.withLock { labels.append(label) }
            }
        }
        var all: [String] { lock.withLock { labels } }

        /// Waits out the second, end-of-ladder call, and checks both calls and their queues.
        func refired() async -> Bool {
            let deadline = Date().addingTimeInterval(CLIProcessRunner.killGraceSeconds + 2)
            while all.count < 2, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            return all == ["iris.cli-process.ladder", "iris.cli-process.refire"]
        }
    }

    private static func marker() -> String { "30.\(Int.random(in: 100_000...999_999))" }

    // MARK: - CLIProcessRunner

    @Test("a deadline that kills the child runs onKill on the ladder queue before the throw, then again at the ladder's end")
    func cliDeadline() async {
        let nap = Self.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        let calls = Calls()
        await #expect(throws: ContainerRuntimeError.self) {
            _ = try await CLIProcessRunner(executable: "/bin/sh").run(["-c", "sleep \(nap)"], timeoutSeconds: 1, onKill: calls.hook)
        }
        #expect(calls.all == ["iris.cli-process.ladder"])
        #expect(await calls.refired(), "got: \(calls.all)")
    }

    @Test("a cancel that kills the child runs onKill on the ladder queue, then again at the ladder's end")
    func cliCancel() async {
        let nap = Self.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        let calls = Calls()
        let call = Task {
            try await CLIProcessRunner(executable: "/bin/sh").run(["-c", "sleep \(nap)"], timeoutSeconds: 60, onKill: calls.hook)
        }
        #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5))
        call.cancel()
        _ = try? await value(of: call)
        #expect(await calls.refired(), "got: \(calls.all)")
    }

    @Test("an ordinary exit runs no onKill")
    func cliOrdinaryExit() async throws {
        let calls = Calls()
        let r = try await CLIProcessRunner(executable: "/bin/sh").run(["-c", "echo hi"], timeoutSeconds: 30, onKill: calls.hook)
        #expect(r.stdout == "hi\n")
        #expect(calls.all.isEmpty)
    }

    @Test("a call cancelled before the launch runs no onKill: there was nothing to kill")
    func cliCancelledBeforeLaunch() async {
        let calls = Calls()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CLIProcessRunner(executable: "/bin/sh").run(["-c", "true"], timeoutSeconds: 30, onKill: calls.hook)
        }
        await #expect(throws: CancellationError.self) { _ = try await value(of: call) }
        // The ladder that a pre-launch cancel starts finishes after its grace; it must still find
        // nothing running.
        try? await Task.sleep(nanoseconds: UInt64((CLIProcessRunner.killGraceSeconds + 0.5) * 1e9))
        #expect(calls.all.isEmpty)
    }

    // MARK: - ProcessGroupRunner

    @Test("terminate runs onKilled once, on the runner's queue, and marks the output killed")
    func groupTerminate() async throws {
        let nap = Self.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        let calls = Calls()
        let runner = ProcessGroupRunner()
        let call = Task {
            await runner.run(executable: "/bin/sh", arguments: ["-c", "sleep \(nap)"], environment: nil,
                             currentDirectory: nil, onKilled: calls.hook)
        }
        #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5))
        runner.terminate()
        let output = try await value(of: call).get()
        #expect(output.killed)
        #expect(calls.all == ["iris.process-group"])
    }

    @Test("a timeoutSeconds kill runs onKilled once and marks the output killed")
    func groupTimeout() async throws {
        let nap = Self.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        let calls = Calls()
        let output = try await ProcessGroupRunner.capture(executable: "/bin/sh", arguments: ["-c", "sleep \(nap)"],
                                                          environment: nil, timeoutSeconds: 1, onKilled: calls.hook).get()
        #expect(output.killed)
        #expect(output.timedOut)
        #expect(calls.all == ["iris.process-group"])
    }

    @Test("an ordinary exit runs no onKilled, and a terminate after it changes nothing")
    func groupOrdinaryExit() async throws {
        let calls = Calls()
        let runner = ProcessGroupRunner()
        let output = try await runner.run(executable: "/bin/sh", arguments: ["-c", "echo hi"], environment: nil,
                                          currentDirectory: nil, onKilled: calls.hook).get()
        runner.terminate()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!output.killed)
        #expect(calls.all.isEmpty)
    }

    @Test("a terminate before the spawn runs no onKilled: nothing was spawned")
    func groupTerminateBeforeSpawn() async {
        let calls = Calls()
        let runner = ProcessGroupRunner()
        runner.terminate()
        let result = await runner.run(executable: "/bin/sh", arguments: ["-c", "true"], environment: nil,
                                      currentDirectory: nil, onKilled: calls.hook)
        #expect((try? result.get()) == nil)
        #expect(calls.all.isEmpty)
    }
}
