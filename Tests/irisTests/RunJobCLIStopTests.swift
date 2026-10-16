import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decision 16, in this process: signals are *delivered by hand* to `CLIStop.receive`, so
/// nothing installs a handler here and Ctrl-C still stops `swift test`. Each test has its own
/// registry and box, and records exits, deletes and the SIGINT reset rather than doing them.
/// Real signals run in `CLISignalTests`.
@MainActor
@Suite("--run-job's clean stop (#463)", .timeLimit(.minutes(1)))
final class RunJobCLIStopTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-463-stop-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    /// What the stop did, in order.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ event: String) { lock.withLock { list.append(event) } }
        var values: [String] { lock.withLock { list } }
        var exits: [Int32] { values.compactMap { $0.hasPrefix("exit ") ? Int32($0.dropFirst(5)) : nil } }
    }

    /// Spawns `/bin/sleep 30` in a group of the test's registry, says so, then waits on it,
    /// terminating it when the turn is cancelled: a turn that is "mid-run" by construction.
    final class SleepingClient: LLMClientProtocol, @unchecked Sendable {
        private let registry: LiveProcessGroups
        private let onRunning: @Sendable () -> Void
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var exited = false
        var sleepPid: pid_t { lock.withLock { pid } }

        init(registry: LiveProcessGroups, onRunning: @escaping @Sendable () -> Void) {
            self.registry = registry
            self.onRunning = onRunning
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let runner = ProcessGroupRunner(registry: registry)
            Task {
                _ = await runner.run(executable: "/bin/sleep", arguments: ["30"], environment: nil, currentDirectory: nil)
                self.lock.withLock { self.exited = true }
            }
            var waited = 0
            while runner.processIdentifier == 0, waited < 500 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
            }
            lock.withLock { pid = runner.processIdentifier }
            onRunning()
            // Bounded, and not `value(of:within:)` (ruling P8's intent): the stop cancels this
            // call, and that helper records an issue when its waiter is cancelled. A cancelled
            // sleep throws, so the cancellation ends this wait at once.
            do {
                for _ in 0..<4000 where !lock.withLock({ exited }) {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            } catch {
                runner.terminate()
                throw error
            }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "woke")]))],
                                  usageMetadata: nil)
        }
    }

    private func lockPath() -> URL {
        base.appendingPathComponent(UUID().uuidString).appendingPathComponent("conversations.sqlite.lock")
    }

    private func stop(_ registry: LiveProcessGroups, _ events: Events, grace: TimeInterval = 5) -> CLIStop {
        CLIStop(grace: grace, teardown: 2,
                terminateGroups: { registry.terminateAll() },
                closeGroups: { events.add("close"); _ = registry.closeAndSnapshot() },
                drainGroups: { registry.waitUntilEmpty(within: 3) },
                killGroups: { events.add("kill"); registry.killAll() },
                deleteContainers: { events.add("delete") },
                resetInterrupt: { _ in events.add("reset") },
                flush: { events.add("flush") },
                vacate: { events.add("vacate") },
                exitNow: { events.add("exit \($0)") })
    }

    @Test("SIGINT, SIGTERM and SIGHUP mid-run: interrupted with the reason, the card, the groups drained, exit 2",
          arguments: [SIGINT, SIGTERM, SIGHUP])
    func signalMidRun(_ signal: Int32) async throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "napper", prompt: "Nap.", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let registry = LiveProcessGroups()
        let events = Events()
        let cliStop = stop(registry, events)
        let client = SleepingClient(registry: registry, onRunning: { cliStop.receive(signal) })

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "napper"), store: store, client: client,
                                       lockPath: lockPath(), protectionEnabled: false, stop: cliStop,
                                       out: { _ in }, err: { _ in })

        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(events.exits.isEmpty, "the first signal stops the run; it does not exit the process")
        let row = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(row.status == .interrupted)
        #expect(row.failureReason == "stopped by a signal (\(RunStop.signalName(signal)))")
        let cards = try store.loadAll().conversations.flatMap(\.messages).compactMap { EventCard.decode($0.content) }
        #expect(cards.contains { $0.runId == row.id }, "the card was delivered and the save flushed")
        // `settle` waited for the SIGTERM'd group's ladder (its SIGKILL rung is 2 s on) before
        // `run` returned, so a group that ignored SIGTERM could not outlive the `_exit`.
        #expect(registry.count == 0)
        #expect(kill(client.sleepPid, 0) == -1 && errno == ESRCH, "the sleep's group is gone")
        #expect(events.values == ["close", "delete"], "settle closes the registry and deletes what containers are left; nothing was killed early")
        #expect(!registry.admit(ProcessGroupRunner(registry: registry)), "no group may start after the settle")
    }

    @Test("a signal before admission: groups killed, containers deleted, the payload emptied, exit 2, no row")
    func signalBeforeAdmission() async throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "napper", prompt: "Nap.", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        cliStop.receive(SIGINT)
        #expect(events.values == ["reset", "kill", "delete", "flush", "vacate", "exit 2"])
        // In production that exit is `_exit`. Here the run goes on, and the run armed too late
        // writes nothing.
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "napper"), store: store,
                                       client: FakeLLMClient(responses: []), lockPath: lockPath(),
                                       protectionEnabled: false, stop: cliStop, out: { _ in }, err: { _ in })
        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("Review Focus 4: a signal during --dry-run while its gate runs: exit 2 at once, host groups killed, containers deleted, nothing written")
    func signalDuringDryRun() async throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "gated", prompt: "p",
                      trigger: .poll(PollSpec(schedule: .interval(seconds: 60), gate: .pathChanged(path: "/tmp/whatever"))))
        try store.ledger.upsert(job)
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        _ = await RunJobCLI.run(RunJobCLI.Invocation(target: "gated", dryRun: true), store: store,
                                client: FakeLLMClient(responses: []), lockPath: lockPath(), protectionEnabled: false,
                                gate: { _, _ in cliStop.receive(SIGINT); return .unchanged(signal: "same") },
                                stop: cliStop, out: { _ in }, err: { _ in })
        #expect(events.values == ["reset", "kill", "delete", "flush", "vacate", "exit 2"],
                "the exit path runs the kill and the delete, in that order; Task 12 shows a gate's container is in the box")
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("a second signal resets SIGINT, kills the groups, deletes the containers, and exits 128 + signal")
    func secondSignalExitsNow() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        #expect(cliStop.run.arm() == nil)
        cliStop.receive(SIGINT)
        #expect(events.values.isEmpty)
        cliStop.receive(SIGINT)
        #expect(events.values == ["reset", "kill", "delete", "flush", "vacate", "exit 130"],
                "SIGINT back to its default first, so a third Ctrl-C ends the CLI while the deletes run")
    }

    /// Coordinator's ruling: a runner queued but not yet spawned is in neither registry, so the
    /// turn is cancelled first, which stops the spawn, and only then are the groups snapshotted.
    @Test("a second signal cancels the run's turn before it kills the groups")
    func secondSignalCancelsTheTurnFirst() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        #expect(cliStop.run.arm() == nil)
        cliStop.run.attachTurn { events.add("cancel") }
        cliStop.receive(SIGINT)
        #expect(events.values == ["cancel"], "the first signal cancels the turn itself")
        cliStop.receive(SIGINT)
        #expect(events.values == ["cancel", "reset", "cancel", "kill", "delete", "flush", "vacate", "exit 130"])
    }

    /// Fix wave, finding 1: the first signal acts on the caller's queue, before it returns, rather
    /// than in a stop watcher that needs a pool thread. `CLISignalTests.firstSignalActsOffThePool`
    /// holds the pool for real.
    @Test("the first signal cancels the turn, SIGTERMs the groups and starts the grace before it returns")
    func firstSignalActsAtOnce() {
        let events = Events()
        let cliStop = CLIStop(grace: 7, terminateGroups: { events.add("terminate") }, closeGroups: {},
                              drainGroups: { true }, killGroups: { events.add("kill") }, deleteContainers: {},
                              resetInterrupt: { _ in }, flush: {}, vacate: {}, exitNow: { events.add("exit \($0)") })
        #expect(cliStop.run.arm() == nil)
        cliStop.run.attachTurn { events.add("cancel") }
        #expect(cliStop.run.graceDeadline == nil)
        let before = DispatchTime.now()
        cliStop.receive(SIGINT)
        #expect(events.values == ["cancel", "terminate"], "the turn first, so a queued runner refuses to spawn")
        let deadline = cliStop.run.graceDeadline
        #expect(deadline != nil)
        if let deadline { #expect(deadline >= before + 7 && deadline <= .now() + 7, "the grace counts from the request") }
    }

    @Test("a turn attached after the stop was asked for is cancelled at once")
    func lateTurnIsCancelled() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        #expect(cliStop.run.arm() == nil)
        cliStop.receive(SIGTERM)
        cliStop.run.attachTurn { events.add("cancel") }
        #expect(events.values == ["cancel"])
    }

    /// Fix wave, finding 3: the run's own exit and a second signal's used to race to two codes.
    @Test("the exit is single-shot: the run's exit first keeps its code, and a later second signal does nothing")
    func runExitWins() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        #expect(cliStop.run.arm() == nil)
        cliStop.receive(SIGINT)
        cliStop.exit(code: RunJobCLI.Exit.notCompleted)
        cliStop.receive(SIGINT)
        #expect(events.values == ["flush", "vacate", "exit 2"])
    }

    @Test("the exit is single-shot: a second signal first keeps 130, and the run's exit after it does nothing")
    func secondSignalWins() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        #expect(cliStop.run.arm() == nil)
        cliStop.receive(SIGINT)
        cliStop.receive(SIGINT)
        cliStop.exit(code: RunJobCLI.Exit.notCompleted)
        #expect(events.exits == [130])
        #expect(events.values.filter { $0 == "flush" }.count == 1)
    }

    @Test("a signal after the run is over is left to the CLI's own exit")
    func signalAfterTheRun() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        _ = cliStop.run.arm()
        cliStop.run.disarm()
        cliStop.receive(SIGTERM)
        #expect(events.values.isEmpty)
    }

    @Test("settle kills what has not drained by its bound")
    func settleKillsTheStragglers() async throws {
        let events = Events()
        let cliStop = CLIStop(terminateGroups: {}, closeGroups: { events.add("close") }, drainGroups: { false },
                              killGroups: { events.add("kill") },
                              deleteContainers: { events.add("delete") }, resetInterrupt: { _ in },
                              vacate: {}, exitNow: { _ in })
        cliStop.settle()
        #expect(events.values == ["close", "kill", "delete"])
    }

    @Test("settle closes the host registry on the drained path too")
    func settleClosesWhenDrained() {
        let events = Events()
        let registry = LiveProcessGroups()
        let cliStop = CLIStop(terminateGroups: {}, closeGroups: { events.add("close"); _ = registry.closeAndSnapshot() },
                              drainGroups: { registry.waitUntilEmpty(within: 3) }, killGroups: { events.add("kill") },
                              deleteContainers: { events.add("delete") }, resetInterrupt: { _ in },
                              vacate: {}, exitNow: { _ in })
        cliStop.settle()
        #expect(events.values == ["close", "delete"], "drained, so nothing to kill")
        #expect(!registry.admit(ProcessGroupRunner(registry: registry)), "closed all the same")
    }

    @Test("the stopping signals are SIGINT, SIGTERM and SIGHUP")
    func stoppingSignals() {
        #expect(CLISignals.stopping == [SIGINT, SIGTERM, SIGHUP])
        #expect(CLISignals.keepsInheritedIgnore == [SIGINT, SIGHUP], "SIGTERM is always caught")
    }
}
