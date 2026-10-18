import Testing
import Foundation
import os
@testable import IrisKit

/// #603: a job run's hard deadline must not need the cooperative pool (invariant 4, #372). The
/// watchdog used to be a `Task.sleep` loop, so a pool held by blocking work held the deadline with
/// it: the run, its sleep assertion and its turn all outlived the timeout until the pool freed.
///
/// Run in an exit test, a child process of its own, for the reason `KillEscalationPoolStarvationTests`
/// gives: holding every pool thread in the shared test process would stall the suites beside it.
@Suite("Job run deadline with the cooperative pool held (#603)", .timeLimit(.minutes(1)))
struct JobDeadlinePoolStarvationTests {
    @Test("the deadline cancels the turn and gives the sleep assertion back while the pool is held")
    func deadlineFiresOffPool() async {
        let log: String = Starvation.messageFile()
        await #expect(processExitsWith: .success) { [log = log as String] in
            await DeadlineStarvation.run(log: log)
        }
        Starvation.report(log)
    }

    /// #615: a stop asked for while the pool is held is the run's ending, even when the deadline
    /// passes before a pool thread frees. The claim used to be a pool task's, so the off-pool
    /// deadline won it and the row read "time exceeded" for a run that was stopped first.
    @Test("a stop asked for while the pool is held claims the run before the deadline can")
    func stopClaimsOffPool() async {
        let log: String = Starvation.messageFile()
        await #expect(processExitsWith: .success) { [log = log as String] in
            await DeadlineStarvation.run(log: log, stopFirst: true)
        }
        Starvation.report(log)
    }
}

/// Inside the exit-test child: 0 when the deadline landed on time, 1 when it did not, 2 when the
/// pool could not be held (which would prove nothing).
enum DeadlineStarvation {
    /// Parks in the model call until cancelled. The cancellation handler runs synchronously on
    /// whichever thread cancels, so `cancelled` is set by the deadline's own thread: with the pool
    /// held, a deadline that needs a pool thread never sets it.
    final class ParkedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var wasCancelled = false
        var reached: Bool { lock.withLock { entered } }
        var cancelled: Bool { lock.withLock { wasCancelled } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { entered = true }
            try await withTaskCancellationHandler {
                while true { try await Task.sleep(nanoseconds: 50_000_000) }
            } onCancel: {
                self.lock.withLock { self.wasCancelled = true }
            }
            throw CancellationError()
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()
        func now() -> Date { lock.withLock { current } }
        func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    static func run(log: String, stopFirst: Bool = false) async {
        let client = ParkedClient()
        let clock = Clock()
        let activity = RecordingActivity()
        let name = "iris-603-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let config = ConfigManager(store: defaults)
        let stop = stopFirst ? RunStop(grace: 1, terminateGroups: {}) : nil
        // The runner holds the state and engine weakly, so they are returned to be kept alive.
        let started: (Job, JobRunner, ConversationStore, AppState, IrisEngine)? = await MainActor.run {
            guard let store = try? ConversationStore.inMemory() else { return nil }
            let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
            state.conversations.removeAll()
            state.autoApproveTools = true
            let conversation = UUID()
            state.createNewConversation(id: conversation)
            state.selectedConversationId = conversation
            let engine = IrisEngine(state: state, tier: .medium, client: client, streamResponses: false,
                                    protectionEnabled: false, sessionPeerCount: 0)
            // Far longer than the test: only the manual clock can bring this deadline on, never the
            // engine's own round check, which reads the real one.
            var policy = JobPolicy()
            policy.runTimeoutSeconds = 3_000
            let job = Job(name: "starved", prompt: "do the thing", trigger: .schedule(.interval(seconds: 60)),
                          policy: policy)
            guard (try? store.ledger.upsert(job)) != nil else { return nil }
            let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                                   config: config, activity: activity, watchdogSlice: 0.05,
                                   deadlineClock: clock.now, stop: stop)
            return (job, runner, store, state, engine)
        }
        guard let (job, runner, store, state, engine) = started else { finish(log, 1, "could not build the harness") }
        let fire = Task.detached { await runner.fire(job: job, origin: .schedule) }
        // Awaited, not `usleep`: until the hold below, the run needs a pool thread to get here.
        let reachBy = TestClock.deadline(10)
        while !client.reached, TestClock.now() < reachBy { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard client.reached else {
            let runs = (try? store.ledger.runs(jobId: job.id, limit: 3)) ?? []
            finish(log, 1, "the turn never reached the model (runs: \(runs.map { "\($0.status) \($0.failureReason ?? "-")" }))")
        }

        let hold = PoolHold()
        hold.engage()
        guard hold.isHeld() else {
            hold.release()
            finish(log, 2, "could not hold the cooperative pool")
        }
        if let stop {
            let reason = RunStop.reason(for: SIGTERM)
            _ = stop.request(reason: reason)
            // The deadline passes too, before any pool thread is free: whichever claimed first
            // decides the row, and the stop came first.
            clock.advance(by: 3_001)
            usleep(500_000)
            hold.release()
            let doneBy = TestClock.deadline(10)
            var row: JobRun?
            while TestClock.now() < doneBy {
                row = (try? store.ledger.runs(jobId: job.id, limit: 1))?.first
                if let row, row.status != .running { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            _ = (fire, state, engine)
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
            let ok = row?.status == .interrupted && row?.failureReason == reason
            finish(log, ok ? 0 : 1, ok ? "" : "the stop did not claim the run (row: \(row.map { "\($0.status) \($0.failureReason ?? "-")" } ?? "none"))")
        }
        clock.advance(by: 3_001)
        // One slice to notice, plus generous slack; polled from this blocked thread.
        let until = TestClock.deadline(3)
        func landed() -> Bool { client.cancelled && activity.events.last == .end }
        while !landed(), TestClock.now() < until { usleep(20_000) }
        let ok = landed()
        let detail = "cancelled: \(client.cancelled), activity: \(activity.events)"
        hold.release()
        _ = (fire, state, engine)
        defaults.removePersistentDomain(forName: name)
        IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        finish(log, ok ? 0 : 1, ok ? "" : "the deadline did not land within 3 s with the pool held (\(detail))")
    }

    private static func finish(_ log: String, _ code: Int32, _ message: String) -> Never {
        if !message.isEmpty {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            try? message.write(toFile: log, atomically: true, encoding: .utf8)
        }
        exit(code)
    }
}
