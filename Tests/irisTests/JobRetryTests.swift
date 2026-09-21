import Testing
import Foundation
@testable import iris

/// #187 §4 "after a run" — what a failure costs the schedule: three attempts on the backoff
/// ladder, then a pause that says so, and a resume that puts the job back on its cadence. Plus the
/// sleep assertion the run is wrapped in, which is the other half of "a run that started finishes
/// or is stopped": a Mac that idles mid-run would otherwise leave a `running` row behind.
@MainActor
@Suite("Job retry, pause and the sleep assertion (#187)")
struct JobRetryTests {

    // MARK: Fixtures

    private func job(name: String = "pr-sweep", retry: Bool = true, attempt: Int = 0,
                     timeoutSeconds: Int = 600) -> Job {
        var policy = JobPolicy()
        policy.retry = retry
        policy.runTimeoutSeconds = timeoutSeconds
        return Job(name: name, prompt: "do the thing", trigger: .schedule(.interval(seconds: 60)),
                   policy: policy, retryAttempt: attempt)
    }

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func harness(_ responses: [GeminiResponse], client: (any LLMClientProtocol)? = nil)
        throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let conversation = UUID()
        state.createNewConversation(id: conversation)
        state.selectedConversationId = conversation
        let engine = IrisEngine(state: state, tier: .medium,
                                client: client ?? FakeLLMClient(responses: responses),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine)
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-jobretry-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func card(_ state: AppState) -> EventCard? {
        state.conversations.first { $0.id == state.activityConversationId() }?
            .messages.compactMap { EventCard.decode($0.content) }.first
    }

    // MARK: The decision

    @Test("three failures climb the ladder; the fourth pauses")
    func retryDecisionTable() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(JobRunner.retryDecision(status: .failed, attempt: 0, retryEnabled: true, now: now)
                == .retry(at: now.addingTimeInterval(60)))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 1, retryEnabled: true, now: now)
                == .retry(at: now.addingTimeInterval(300)))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 2, retryEnabled: true, now: now)
                == .retry(at: now.addingTimeInterval(1_500)))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 3, retryEnabled: true, now: now)
                == .pause(reason: JobRunner.retriesExhaustedReason))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 9, retryEnabled: true, now: now)
                == .pause(reason: JobRunner.retriesExhaustedReason))
    }

    @Test("retry off means a failure is reported once and left alone")
    func retryDisabled() {
        let now = Date()
        #expect(JobRunner.retryDecision(status: .failed, attempt: 0, retryEnabled: false, now: now) == .none)
        #expect(JobRunner.retryDecision(status: .failed, attempt: 3, retryEnabled: false, now: now) == .none)
    }

    @Test("only a failure retries: an approval needs a human, and the other outcomes are not failures")
    func onlyFailuresRetry() {
        let now = Date()
        for status: JobRun.Status in [.completed, .blockedOnApproval, .interrupted, .running] {
            #expect(JobRunner.retryDecision(status: status, attempt: 1, retryEnabled: true, now: now) == .none,
                    "\(status) must not be retried")
        }
    }

    // MARK: Through a run

    @Test("a failed run is scheduled again a minute out, and its card says so")
    func failedRunRetriesInAMinute() async throws {
        // An empty reply is a failure with nothing to show (`noReplyReason`), which is the
        // cheapest way to fail a real turn without a network or an error path.
        let (store, state, engine) = try harness([textResponse("")])
        let j = job()
        try store.ledger.upsert(j)
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, now: { firedAt },
                               config: config, activity: RecordingActivity())

        await runner.fire(job: j, reason: "schedule")

        let stored = try #require(try store.ledger.job(id: j.id))
        #expect(stored.retryAttempt == 1)
        #expect(stored.nextFireAt == firedAt.addingTimeInterval(60))
        #expect(stored.pausedReason == nil)
        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .failed)
        let card = try #require(self.card(state))
        #expect(card.outcome?.contains("retrying in 1 m") == true, "got: \(card.outcome ?? "nil")")
    }

    @Test("the fourth failure pauses the job with the reason on the card")
    func fourthFailurePauses() async throws {
        let (store, state, engine) = try harness([textResponse("")])
        let j = job(attempt: 3)
        try store.ledger.upsert(j)
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, now: { firedAt },
                               config: config, activity: RecordingActivity())

        await runner.fire(job: j, reason: "schedule")

        let stored = try #require(try store.ledger.job(id: j.id))
        #expect(stored.pausedReason == JobRunner.retriesExhaustedReason)
        let card = try #require(self.card(state))
        #expect(card.outcome?.contains(JobRunner.retriesExhaustedReason) == true,
                "got: \(card.outcome ?? "nil")")
    }

    @Test("a run that finally works clears the ladder")
    func completedRunResetsTheLadder() async throws {
        let (store, state, engine) = try harness([textResponse("tick")])
        let j = job(attempt: 2)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: RecordingActivity())

        await runner.fire(job: j, reason: "schedule")

        #expect(try store.ledger.job(id: j.id)?.retryAttempt == 0)
        #expect(try store.ledger.runs(jobId: j.id, limit: 1).first?.status == .completed)
    }

    @Test("with retry off a failure neither reschedules nor pauses")
    func retryOffLeavesTheScheduleAlone() async throws {
        let (store, state, engine) = try harness([textResponse("")])
        var j = job(retry: false)
        j.nextFireAt = Date(timeIntervalSince1970: 1_700_000_500)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { Date(timeIntervalSince1970: 1_700_000_000) },
                               config: config, activity: RecordingActivity())

        await runner.fire(job: j, reason: "schedule")

        let stored = try #require(try store.ledger.job(id: j.id))
        #expect(stored.retryAttempt == 0)
        #expect(stored.pausedReason == nil)
        #expect(stored.nextFireAt == j.nextFireAt, "its cadence is untouched")
        #expect(self.card(state)?.outcome?.contains("retrying") != true)
    }

    // MARK: /jobs pause and resume

    private func makeApp(with jobs: [Job]) -> (AppState, UUID) {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        for job in jobs { try? app.store.ledger.upsert(job) }
        return (app, id)
    }

    private func output(_ app: AppState, _ id: UUID) -> String {
        (app.conversations.first { $0.id == id }?.messages ?? [])
            .filter { $0.role == .command }.map(\.content).joined(separator: "\n")
    }

    @Test("/jobs pause stops a job and says who stopped it")
    func pauseCommand() throws {
        let j = job()
        let (app, id) = makeApp(with: [j])

        app.sendMessage("/jobs pause pr-sweep")

        #expect(try app.store.ledger.job(id: j.id)?.pausedReason == JobsCommand.pausedByUserReason)
        #expect(output(app, id).contains("pr-sweep"))
    }

    @Test("/jobs resume clears the pause and the retry ladder, and recomputes the next fire")
    func resumeCommand() throws {
        var j = job(attempt: 2)
        j.pausedReason = JobRunner.retriesExhaustedReason
        j.nextFireAt = nil
        let (app, id) = makeApp(with: [j])
        let before = Date()

        app.sendMessage("/jobs resume pr-sweep")

        let stored = try #require(try app.store.ledger.job(id: j.id))
        #expect(stored.pausedReason == nil)
        #expect(stored.retryAttempt == 0)
        let next = try #require(stored.nextFireAt)
        // Recomputed from the schedule (60 s), not left where the failed ladder put it.
        #expect(next >= before.addingTimeInterval(59) && next <= Date().addingTimeInterval(61))
        #expect(output(app, id).contains("pr-sweep"))
    }

    @Test("pausing or resuming a job that is not there names it rather than reporting success")
    func pauseResumeUnknownJob() {
        let (app, id) = makeApp(with: [job()])

        app.sendMessage("/jobs pause nightly")
        app.sendMessage("/jobs resume nightly")

        #expect(output(app, id).contains("No job named 'nightly'."))
    }

    // MARK: The sleep assertion

    /// A client that parks inside the model call until the test lets it go, so the assertion's
    /// begin/end can be observed *while* the turn is still in flight.
    private final class GatedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var calls = 0
        private let response: GeminiResponse

        init(response: GeminiResponse) { self.response = response }

        var callCount: Int { lock.withLock { calls } }
        func release() { lock.withLock { released = true } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { calls += 1 }
            while !lock.withLock({ released }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return response
        }
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 10,
                         _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out waiting for \(description)")
    }

    @Test("the sleep assertion is held for the run: begun before the turn, ended after it")
    func activityWrapsTheRun() async throws {
        let client = GatedClient(response: textResponse("tick"))
        let (store, state, engine) = try harness([], client: client)
        let j = job()
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let activity = RecordingActivity()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: activity)

        let fire = Task { await runner.fire(job: j, reason: "schedule") }
        await waitFor("the turn to reach the model") { client.callCount == 1 }
        #expect(activity.events == [.begin("Iris job pr-sweep")],
                "the assertion is held while the turn is in flight")

        client.release()
        await fire.value
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end])
    }

    @Test("a run that overruns its timeout gives the assertion back at the deadline")
    func activityEndsAtTheDeadline() async throws {
        let client = GatedClient(response: textResponse("tick"))
        let (store, state, engine) = try harness([], client: client)
        let j = job(timeoutSeconds: 1)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let activity = RecordingActivity()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: activity)

        let fire = Task { await runner.fire(job: j, reason: "schedule") }
        await waitFor("the deadline to give the assertion back") { activity.events.count == 2 }
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end])
        #expect(client.callCount == 1, "the turn itself is still parked in the model call")

        client.release()
        await fire.value
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end],
                "and ending it twice is not two ends")
    }
}
