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
        #expect(JobRunner.retryDecision(status: .failed, attempt: 0, retryEnabled: true, watcherFire: false, now: now)
                == .retry(at: now.addingTimeInterval(60)))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 1, retryEnabled: true, watcherFire: false, now: now)
                == .retry(at: now.addingTimeInterval(300)))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 2, retryEnabled: true, watcherFire: false, now: now)
                == .retry(at: now.addingTimeInterval(1_500)))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 3, retryEnabled: true, watcherFire: false, now: now)
                == .pause(reason: JobRunner.retriesExhaustedReason))
        #expect(JobRunner.retryDecision(status: .failed, attempt: 9, retryEnabled: true, watcherFire: false, now: now)
                == .pause(reason: JobRunner.retriesExhaustedReason))
    }

    @Test("retry off means a failure is reported once and left alone")
    func retryDisabled() {
        let now = Date()
        #expect(JobRunner.retryDecision(status: .failed, attempt: 0, retryEnabled: false, watcherFire: false, now: now) == .none)
        #expect(JobRunner.retryDecision(status: .failed, attempt: 3, retryEnabled: false, watcherFire: false, now: now) == .none)
    }

    @Test("a watch fire does not retry: the next save re-runs it with real paths")
    func watcherFiresDoNotRetry() {
        let now = Date()
        #expect(JobRunner.retryDecision(status: .failed, attempt: 0, retryEnabled: true,
                                        watcherFire: true, now: now) == .none)
        #expect(JobRunner.retryDecision(status: .failed, attempt: 3, retryEnabled: true,
                                        watcherFire: true, now: now) == .none,
                "and it never reaches the pause at the end of the ladder either")
    }

    @Test("only a failure retries: an approval needs a human, and the other outcomes are not failures")
    func onlyFailuresRetry() {
        let now = Date()
        for status: JobRun.Status in [.completed, .blockedOnApproval, .interrupted, .running] {
            #expect(JobRunner.retryDecision(status: status, attempt: 1, retryEnabled: true, watcherFire: false, now: now) == .none,
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

        await runner.fire(job: j, origin: .schedule)

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

        await runner.fire(job: j, origin: .schedule)

        let stored = try #require(try store.ledger.job(id: j.id))
        #expect(stored.pausedReason == JobRunner.retriesExhaustedReason)
        let card = try #require(self.card(state))
        #expect(card.outcome?.contains(JobRunner.retriesExhaustedReason) == true,
                "got: \(card.outcome ?? "nil")")
    }

    @Test("a failed watch fire leaves the schedule alone, ladder and all")
    func watcherFailureDoesNotClimbTheLadder() async throws {
        let (store, state, engine) = try harness([textResponse("")])
        var j = Job(name: "inbox", prompt: "Sort it.", trigger: .fsEvent(FSWatch(path: "/tmp/in")))
        j.retryAttempt = 0
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: RecordingActivity())

        await runner.fire(job: j, origin: .watcher(paths: ["/tmp/in/a.txt"]))

        let stored = try #require(try store.ledger.job(id: j.id))
        #expect(stored.retryAttempt == 0)
        #expect(stored.nextFireAt == nil, "a watch has no cadence for a retry to move")
        #expect(try store.ledger.runs(jobId: j.id, limit: 1).first?.status == .failed)
        #expect(self.card(state)?.outcome?.contains("retrying") != true)
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

        await runner.fire(job: j, origin: .schedule)

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

        await runner.fire(job: j, origin: .schedule)

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

    @Test("/jobs run refuses a paused or a disabled job, and names one that is not there")
    func runCommandRefusals() {
        var paused = job(name: "sleeping")
        paused.pausedReason = JobRunner.retriesExhaustedReason
        var off = job(name: "switched-off")
        off.enabled = false
        let (app, id) = makeApp(with: [paused, off])

        app.sendMessage("/jobs run sleeping")
        app.sendMessage("/jobs run switched-off")
        app.sendMessage("/jobs run nightly")

        let out = output(app, id)
        #expect(out.contains("'sleeping' is paused (\(JobRunner.retriesExhaustedReason))"))
        #expect(out.contains("'switched-off' is disabled."))
        #expect(out.contains("No job named 'nightly'."))
        // None of the three reached a runner, so none of them needed a model client.
        #expect(app.conversations.filter { $0.isBackground }.isEmpty)
    }

    @Test("/jobs run says it is starting straight away, then what admission decided")
    func runCommandSaysItIsStartingFirst() async throws {
        // A job whose own policy trips the breaker on this fire, so admission refuses it before
        // any model call — and nothing here touches the global settings to arrange that.
        var j = job(name: "thrasher")
        j.policy.maxRunsPerHour = 1
        let (app, id) = makeApp(with: [j])
        let previous = JobRun(jobId: j.id, jobName: j.name, triggerKind: "schedule",
                              startedAt: Date().addingTimeInterval(-60),
                              transcriptConversationId: UUID())
        try app.store.ledger.begin(run: previous)
        try app.store.ledger.finish(runId: previous.id, status: .completed, outcome: "did a thing",
                                    failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                    finishedAt: Date().addingTimeInterval(-59))

        app.sendMessage("/jobs run thrasher")

        #expect(output(app, id).contains("Starting **thrasher** …"),
                "a run takes as long as it takes; silence until then reads as a command that did nothing")
        await waitFor("admission to report back") {
            output(app, id).contains("**thrasher** was not started: \(JobRunner.breakerReason(count: 1))")
        }
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

    /// A client that parks inside the model call and never comes back — cancellation or no
    /// cancellation. `withCheckedContinuation` installs no cancellation handler, so
    /// `turnTask.cancel()` slides straight off it, which is the shape of a blocking `Process` or a
    /// stream with no resource timeout. `GatedClient` above cannot stand in for this: it parks in
    /// `Task.sleep`, which throws the moment the turn is cancelled.
    private final class WedgedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var parked: [CheckedContinuation<GeminiResponse, Never>] = []
        private var calls = 0
        private let response: GeminiResponse

        init(response: GeminiResponse) { self.response = response }

        var callCount: Int { lock.withLock { calls } }
        var parkedCount: Int { lock.withLock { parked.count } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { calls += 1 }
            return await withCheckedContinuation { continuation in
                lock.withLock { parked.append(continuation) }
            }
        }

        /// Lets every orphaned turn finish at teardown. Not needed for the assertions — the point
        /// of the test is that the run ends without this — but a `CheckedContinuation` that is
        /// never resumed keeps its task (and the engine, state and store behind it) alive for the
        /// rest of the process, which is a leak the next suite would pay for.
        func releaseAll() {
            let waiting = lock.withLock { () -> [CheckedContinuation<GeminiResponse, Never>] in
                defer { parked = [] }
                return parked
            }
            for continuation in waiting { continuation.resume(returning: response) }
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

        let fire = Task { await runner.fire(job: j, origin: .schedule) }
        await waitFor("the turn to reach the model") { client.callCount == 1 }
        #expect(activity.events == [.begin("Iris job pr-sweep")],
                "the assertion is held while the turn is in flight")

        client.release()
        await fire.value
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end])
    }

    @Test("a run that overruns its timeout is ended at the deadline, and the row says so")
    func deadlineEndsTheRun() async throws {
        // A client that never returns: the round-boundary budget check cannot reach a turn parked
        // inside a model call, so the deadline has to cancel the turn itself.
        let client = GatedClient(response: textResponse("tick"))
        let (store, state, engine) = try harness([], client: client)
        let j = job(timeoutSeconds: 1)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let activity = RecordingActivity()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: activity)

        await runner.fire(job: j, origin: .schedule)

        #expect(client.callCount == 1, "and it was never released")
        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == TurnBudget.timeExceeded)
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end],
                "the assertion went back at the deadline, exactly once")
        let card = try #require(self.card(state))
        #expect(card.outcome?.contains(TurnBudget.timeExceeded) == true)
    }

    @Test("a turn that ignores cancellation is left behind at the deadline, not waited on")
    func deadlineDoesNotWaitForANonCooperativeTurn() async throws {
        // The failure this covers: the deadline used to cancel the turn and then go on awaiting
        // it. A turn parked where cancellation is not checked never came back, so `fire` never
        // returned, the job kept its `inFlight` slot forever, its row stayed `running`, and every
        // later tick wrote another skip row. The job stopped, and nothing said why.
        let client = WedgedClient(response: textResponse("too late"))
        let (store, state, engine) = try harness([], client: client)
        let j = job(timeoutSeconds: 1)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let activity = RecordingActivity()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: activity)
        defer { client.releaseAll() }

        // No timeout around this on purpose: if the deadline cannot end the wait, the right
        // failure is the suite hanging here, which is exactly what the shipped bug did.
        await runner.fire(job: j, origin: .schedule)

        #expect(client.parkedCount == 1, "the turn is still parked in the model call")
        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .failed, "the row is closed, not left running")
        #expect(run.failureReason == TurnBudget.timeExceeded)
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end],
                "and the Mac is not held awake by a turn nothing can end")
        // M1: the thinking indicator is a global reference count, so an abandoned turn that kept
        // its claim would leave the spectrum and the LED bar lit for the rest of the session, and
        // Escape appending "Interrupted." to whatever conversation the user is actually reading.
        #expect(state.isThinking == false, "the abandoned turn gave its indicator back")

        // The other half of the wedge: the job has to be firable again. A second fire admitted is
        // proof `inFlight` was given back.
        let second = await runner.fire(job: j, origin: .manual)
        #expect(second == .run, "got: \(String(describing: second))")
        #expect(client.callCount == 2, "the second fire reached the model rather than being skipped")
        let runs = try store.ledger.runs(jobId: j.id, limit: 5)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.status == .failed && $0.failureReason == TurnBudget.timeExceeded })
        #expect(runs.allSatisfy { $0.finishedAt != nil })
        #expect(state.isThinking == false, "two abandoned turns, two indicators given back")
    }

    @Test("a turn that comes back releases its indicator once, and the deadline cannot take it twice")
    func aCooperativeTurnReleasesItsIndicatorExactlyOnce() async throws {
        // The other half of M1. A release the run made as well as the turn would not show up as a
        // stuck indicator but as a *missing* one: `endThinking` clamps at zero, so the extra
        // decrement would take a concurrent real turn's indicator down with it.
        let (store, state, engine) = try harness([textResponse("tick")])
        let j = job()
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: RecordingActivity())

        // Held across the run: a second turn's claim, which nothing in this run may give back.
        state.beginThinking()
        await runner.fire(job: j, origin: .schedule)

        #expect(try store.ledger.runs(jobId: j.id, limit: 1).first?.status == .completed)
        #expect(state.isThinking == true, "the other turn is still thinking")
        state.endThinking()
        #expect(state.isThinking == false, "and its own release is the last one needed")
    }

    @Test("the watchdog re-reads the clock every slice, so a short slice still ends the run once")
    func theWatchdogLoopsUntilTheDeadline() async throws {
        // R17's loop had no test: every other deadline test takes its first slice and exits, so an
        // inverted condition or a slice that never shrinks would spin unnoticed. A tenth of a
        // second against a one-second timeout is about ten times round.
        let client = WedgedClient(response: textResponse("too late"))
        let (store, state, engine) = try harness([], client: client)
        let j = job(timeoutSeconds: 1)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let activity = RecordingActivity()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: activity, watchdogSlice: 0.1)
        defer { client.releaseAll() }

        await runner.fire(job: j, origin: .schedule)

        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == TurnBudget.timeExceeded)
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end],
                "the loop ended the run exactly once, however many times it went round")
        #expect(try store.ledger.runs(jobId: j.id, limit: 5).count == 1, "and only the one run")
    }

    @Test("the turn and the deadline race for one claim, and exactly one of them wins it")
    func theEndingIsClaimedOnce() async {
        let ending = DeadlineFlag()
        #expect(await ending.claim(deadline: false) == true)
        #expect(await ending.claim(deadline: true) == false, "the loser gets no say in how the run ended")
        #expect(await ending.claim(deadline: false) == false)
        #expect(await ending.wait() == false, "and the run hears the winner's answer, not the loser's")
    }

    @Test("the run waits for the claim, and the deadline taking it is what releases the wait")
    func theRunWaitsForWhicheverClaimsTheEnding() async {
        let ending = DeadlineFlag()
        let waiting = Task { await ending.wait() }
        // Resolved by the claim, not by the racer it belongs to finishing: this is the difference
        // between a run that ends at its deadline and one that waits on a turn that never returns.
        #expect(await ending.claim(deadline: true) == true)
        #expect(await waiting.value == true)
    }

    @Test("a turn that came back on its own is never written up as a timeout, whatever the watchdog does")
    func aTurnThatFinishedIsNotATimeout() async throws {
        // The watchdog used to set the timeout flag unconditionally, so a turn that returned in
        // the moments around the deadline was recorded `failed` / "budget: time exceeded" with a
        // perfectly good reply sitting in its transcript. The claim makes it one decision: this
        // turn returns first, so the deadline behind it has nothing left to say.
        let client = GatedClient(response: textResponse("tick"))
        let (store, state, engine) = try harness([], client: client)
        let j = job(timeoutSeconds: 2)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let activity = RecordingActivity()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: activity)

        let fire = Task { await runner.fire(job: j, origin: .schedule) }
        await waitFor("the turn to reach the model") { client.callCount == 1 }
        // Late in the window, so the watchdog is awake and armed behind the turn rather than
        // nowhere near it — but far enough inside it that a loaded machine cannot invert the two.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        client.release()
        await fire.value

        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .completed)
        #expect(run.failureReason == nil, "got: \(run.failureReason ?? "nil")")
        #expect(run.outcome == "tick")
        #expect(activity.events == [.begin("Iris job pr-sweep"), .end], "and the assertion went back once")
    }

    // MARK: What the fire was, after it is over (R7)

    @Test("a hand-started fire of a watch job does not retry: it never had paths to retry with")
    func manualFireOfAWatchJobDoesNotRetry() async throws {
        let (store, state, engine) = try harness([textResponse("")])
        let j = Job(name: "inbox", prompt: "Sort it.", trigger: .fsEvent(FSWatch(path: "/tmp/in")))
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: RecordingActivity())

        await runner.fire(job: j, origin: .manual)

        let stored = try #require(try store.ledger.job(id: j.id))
        #expect(stored.retryAttempt == 0, "a retry minutes later would run the prompt with no paths")
        #expect(stored.nextFireAt == nil)
        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.triggerKind == "manual", "the row says what the fire was, not how the job is configured")
    }

    @Test("a held re-fire of a watch fire does not retry either: it is still that watch fire")
    func queuedReFireOfAWatchFireDoesNotRetry() async throws {
        let gate = JobSchedulerTests.Gate()
        let client = JobAdmissionTests.GatedClient(gate: gate, response: textResponse(""))
        let (store, state, engine) = try harness([], client: client)
        var j = Job(name: "inbox", prompt: "Sort it.", trigger: .fsEvent(FSWatch(path: "/tmp/in")))
        j.policy.overlap = .queue
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: RecordingActivity())

        let first = Task { await runner.fire(job: j, origin: .watcher(paths: ["/tmp/in/a.txt"])) }
        await gate.waitForEntry()
        await runner.fire(job: j, origin: .watcher(paths: ["/tmp/in/b.txt"]))
        await gate.open()
        await first.value

        let runs = try store.ledger.runs(jobId: j.id, limit: 10)
        #expect(runs.count == 2, "the held fire ran")
        #expect(runs.allSatisfy { $0.status == .failed })
        let stored = try #require(try store.ledger.job(id: j.id))
        #expect(stored.retryAttempt == 0, "re-entering as \"queued\" must not lose what woke the job")
        #expect(stored.pausedReason == nil)
        // And it carried the paths, which is the other half of the same carry.
        let queued = try #require(runs.first { $0.triggerKind == "queued" })
        let transcript = try #require(state.conversations.first { $0.id == queued.transcriptConversationId })
        #expect((transcript.history.first?.parts.compactMap(\.text).joined() ?? "").contains("/tmp/in/b.txt"))
    }
}
