import Testing
import Foundation
@testable import IrisKit

/// D6 decision 5: `AppState.runningJobs` holds a job while any of its activities is in flight —
/// a run, a gate being asked, a built-in, an approved call — and lets it go on every way out.
@MainActor
@Suite("Running jobs (D6)", .timeLimit(.minutes(1)))
struct RunningJobsTests {
    private func harness(_ responses: [GeminiResponse] = [], autoApprove: Bool = true,
                         client: (any LLMClientProtocol)? = nil)
        throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = autoApprove
        let engine = IrisEngine(state: state, tier: .medium, client: client ?? FakeLLMClient(responses: responses),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine)
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-running-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))],
                       usageMetadata: nil)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    private func job(name: String = "pr-sweep", profile: JobProfile = .readOnly) -> Job {
        Job(name: name, prompt: "Reply with just the word tick.",
            trigger: .schedule(.interval(seconds: 60)), profile: profile)
    }

    /// Every value `runningJobs` took for one job, as its activity count (0 = absent).
    private final class Transitions { var counts: [Int] = [] }

    private func watch(_ state: AppState, _ jobId: UUID) -> Transitions {
        let seen = Transitions()
        state.runningJobsDidChange = { seen.counts.append($0[jobId]?.activities ?? 0) }
        return seen
    }

    @Test("two activities of one job are one entry, which goes only when both have ended")
    func countsActivitiesPerJob() throws {
        let (_, state, _) = try harness()
        let id = UUID()
        state.adjustRunningJob(id: id, name: "pr-sweep", by: 1)
        state.adjustRunningJob(id: id, name: "pr-sweep", by: 1)
        #expect(state.runningJobs.count == 1, "the menu counts jobs, not runs")
        state.adjustRunningJob(id: id, name: "pr-sweep", by: -1)
        #expect(state.runningJobs[id] == RunningJob(name: "pr-sweep", activities: 1),
                "one ending leaves the other running")
        state.adjustRunningJob(id: id, name: "pr-sweep", by: -1)
        #expect(state.runningJobs[id] == nil)
        state.adjustRunningJob(id: id, name: "pr-sweep", by: -1)
        #expect(state.runningJobs[id] == nil, "a stray decrement never leaves a negative count behind")
    }

    @Test("a completed run is running for its length, and cleared after")
    func completedRun() async throws {
        let (store, state, engine) = try harness([text("tick")])
        let job = self.job()
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("the run log's revision moves once a run's row exists, not before (D6 decision 15)")
    func runLogRevisionAfterBegin() async throws {
        let (store, state, engine) = try harness()
        let job = Job(name: "digest-like", prompt: "", trigger: .schedule(.interval(seconds: 60)),
                      action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        final class Seen { var running: [Bool] = [] }
        let seen = Seen()
        let ledger = store.ledger
        // At each bump, is this job's row already there and still running?
        state.runLogRevisionDidChange = { _ in
            seen.running.append((try? ledger.runs(jobId: job.id, limit: 1).first?.status) == .running)
        }
        let before = state.runLogRevision

        await runner.fire(job: job, origin: .schedule)

        #expect(state.runLogRevision > before)
        #expect(seen.running.first == true, "the first bump comes after begin, while the row says running")
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("a failed run is cleared")
    func failedRun() async throws {
        let (store, state, engine) = try harness([])   // no responses queued: the model call fails
        let job = self.job()
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .failed)
    }

    @Test("a blocked run is cleared")
    func blockedRun() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-running-\(UUID().uuidString).txt").path
        let (store, state, engine) = try harness([
            call("write_file", ["path": .string(path), "content": .string("nope")]),
            text("I could not do that."),
        ])
        let job = self.job(name: "wants-to-write")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .blockedOnApproval)
    }

    @Test("a gate counts as running while it is asked, and its refusal clears it")
    func gateRefusal() async throws {
        let (store, state, engine) = try harness([text("tick")])
        let job = Job(name: "poller", prompt: "Reply with just the word tick.",
                      trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                              gate: .urlChanged(url: "https://example.invalid/f"))))
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config, protectionEnabled: false,
                               gateEvaluator: { _, _ in .unchanged(signal: "etag=aaa") })
        let seen = watch(state, job.id)

        let admission = await runner.fire(job: job, origin: .cadence(kind: "poll"))

        #expect(admission == .gateUnchanged)
        #expect(seen.counts == [1, 0])
    }

    @Test("a built-in, which runs no engine turn, still counts")
    func builtinRun() async throws {
        let (store, state, engine) = try harness()
        let job = Job(name: "mystery", prompt: "", trigger: .schedule(.interval(seconds: 60)),
                      action: .builtin("no-such-builtin"))
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
    }

    @Test("a fire admission refuses (its interrupted row) is never counted as running")
    func breakerRefusalNeverRuns() async throws {
        let (store, state, engine) = try harness()
        var job = self.job(name: "thrasher")
        job.policy.maxRunsPerHour = 1
        try store.ledger.upsert(job)
        let previous = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                              startedAt: Date().addingTimeInterval(-60), transcriptConversationId: UUID())
        try store.ledger.begin(run: previous)
        try store.ledger.finish(runId: previous.id, status: .completed, outcome: "did a thing",
                                failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                finishedAt: Date().addingTimeInterval(-59))
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        let admission = await runner.fire(job: job, origin: .schedule)

        #expect(admission == .pauseBreaker(count: 1))
        #expect(seen.counts.isEmpty)
    }

    @Test("an approved call counts for its length, including a refusal")
    func approvedCall() async throws {
        let dir = try tempDirectory(prefix: "iris-running")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness(autoApprove: false)
        let job = self.job(name: "writer", profile: .mutating)
        try store.ledger.upsert(job)
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(dir.appendingPathComponent("a.txt").path),
                                      "content": .string("once")], cwd: dir.path)
        let blocked = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.ledger.begin(run: blocked)
        try store.ledger.finish(runId: blocked.id, status: .blockedOnApproval, outcome: nil,
                                failureReason: "needs approval: write_file", blockedTool: "write_file",
                                tokens: TokenUsage(), finishedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try store.ledger.setBlockedCall(runId: blocked.id, call)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config, sandboxAvailable: { true })
        let seen = watch(state, job.id)

        guard case .dispatched = await runner.runApproved(runId: blocked.id) else {
            Issue.record("the approval was refused")
            return
        }
        #expect(seen.counts == [1, 0])

        seen.counts = []
        #expect(await runner.runApproved(runId: blocked.id) == .refused(JobRunner.alreadyApprovedRefusal))
        #expect(seen.counts == [1, 0], "a refused click is bracketed too, so nothing is left behind")
    }

    /// The run deadline's clock, held still until the test moves it (the #335 pattern).
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()
        func now() -> Date { lock.withLock { current } }
        func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    /// Parks inside the model call until cancelled, so only the deadline can end the run.
    private final class ParkedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { calls += 1 }
            try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            throw CancellationError()
        }
    }

    @Test("a run the deadline interrupts is cleared")
    func interruptedRun() async throws {
        let client = ParkedClient()
        let (store, state, engine) = try harness(client: client)
        var job = self.job(name: "overrunner")
        // Long enough that the engine's own round check, on the real clock, never trips.
        job.policy.runTimeoutSeconds = 600
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let clock = ManualClock()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config,
                               watchdogSlice: 0.01, deadlineClock: clock.now)
        let seen = watch(state, job.id)

        let fire = Task { await runner.fire(job: job, origin: .schedule) }
        defer { fire.cancel() }
        // The deadline lands mid-run: not before the turn is inside the model call.
        let reached = Date().addingTimeInterval(30)
        while client.callCount == 0, Date() < reached { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(client.callCount == 1, "the turn reached the model")
        #expect(state.runningJobs[job.id] == RunningJob(name: "overrunner", activities: 1),
                "running while the turn is parked")
        clock.advance(by: 601)
        _ = try await value(of: fire)

        #expect(seen.counts == [1, 0])
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.failureReason == TurnBudget.timeExceeded, "it was the deadline that ended it")
    }
}
