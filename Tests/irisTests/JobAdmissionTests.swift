import Testing
import Foundation
@testable import iris

/// #187 §4 "Before a run" — the runner is the single admission point for every fire, scheduled or
/// watcher-driven, and `admit` is the whole decision in one pure function.
///
/// The order is the test: a paused job must not be logged as an overlap, an overlap must not be
/// counted against the breaker, and the breaker must not be reported as a budget. Each branch also
/// has a side effect the ledger (and the user) sees — a row, a pause, a card — and those are
/// driven through `fire` against a real engine below.
@MainActor
@Suite("Job admission (#187 §4)")
struct JobAdmissionTests {

    // MARK: Fixtures

    private func job(name: String = "admit",
                     prompt: String = "Reply with just the word tick.",
                     overlap: JobPolicy.Overlap = .skip,
                     policy: JobPolicy? = nil,
                     paused: String? = nil) -> Job {
        Job(name: name, prompt: prompt, trigger: .schedule(.interval(seconds: 60)),
            pausedReason: paused, policy: policy ?? JobPolicy(overlap: overlap))
    }

    private func limits(maxRunsPerHour: Int = 6,
                        dailyTokens: Int = 1_000_000,
                        globalDailyTokens: Int = 3_000_000,
                        perRunTokens: Int = 200_000,
                        runTimeoutSeconds: Int = 600) -> JobLimits {
        JobLimits(maxRunsPerHour: maxRunsPerHour, dailyTokens: dailyTokens,
                  globalDailyTokens: globalDailyTokens, perRunTokens: perRunTokens,
                  runTimeoutSeconds: runTimeoutSeconds)
    }

    private func textResponse(_ text: String, tokens: UsageMetadata? = nil) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: tokens)
    }

    /// An isolated settings store, never `ConfigManager.shared` (AGENTS invariant 7).
    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-admission-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let teardown = {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        return (ConfigManager(store: store), teardown)
    }

    private func harness(_ responses: [GeminiResponse], latencyMs: Int = 0)
        throws -> (ConversationStore, AppState, IrisEngine, FakeLLMClient) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let userConversation = UUID()
        state.createNewConversation(id: userConversation)
        state.selectedConversationId = userConversation
        let client = FakeLLMClient(responses: responses,
                                   latency: .init(minMs: latencyMs, maxMs: latencyMs))
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, client)
    }

    /// A finished run already on the books, so the breaker and the budgets have something to count.
    private func recordRun(_ ledger: JobLedger, job: Job, at: Date, tokens: Int) throws {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: at)
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: .completed, outcome: "did a thing",
                          failureReason: nil, blockedTool: nil,
                          tokens: TokenUsage(promptTokenCount: 0, candidatesTokenCount: tokens,
                                             totalTokenCount: tokens),
                          finishedAt: at)
    }

    // MARK: admit — the pure decision

    @Test("admit decides in one order: paused, then in flight, then the breaker, then the budgets")
    func admissionOrder() {
        let l = limits(maxRunsPerHour: 2, dailyTokens: 100, globalDailyTokens: 500)
        let plain = job()
        let queueing = job(overlap: .queue)
        let paused = job(paused: "paused by hand")

        let cases: [(what: String, job: Job, inFlight: Bool, runs: Int, jobTokens: Int,
                     allTokens: Int, expected: JobRunner.Admission)] = [
            ("everything wrong at once: the pause wins and nothing is recorded",
             paused, true, 9, 999, 9_999, .dropPaused),
            ("a paused job that is otherwise fine is still dropped",
             paused, false, 0, 0, 0, .dropPaused),
            ("in flight outranks the breaker: an overlap is not a run",
             plain, true, 9, 0, 0, .skipInFlight),
            ("in flight under the queue policy holds the trigger instead of dropping it",
             queueing, true, 9, 0, 0, .queued),
            ("the breaker outranks the budgets: it says why the job is thrashing",
             plain, false, 2, 999, 9_999, .pauseBreaker(count: 2)),
            ("one run under the breaker still runs",
             plain, false, 1, 0, 0, .run),
            ("the job's own daily budget, at the limit",
             plain, false, 1, 100, 0, .pauseBudget(scope: "job", used: 100, limit: 100)),
            ("the job budget outranks the global one",
             plain, false, 1, 100, 9_999, .pauseBudget(scope: "job", used: 100, limit: 100)),
            ("the global daily budget stops a job that is well inside its own",
             plain, false, 1, 0, 500, .pauseBudget(scope: "global", used: 500, limit: 500)),
            ("clear on every count",
             plain, false, 1, 99, 499, .run),
        ]

        for c in cases {
            let decision = JobRunner.admit(job: c.job, inFlight: c.inFlight, runsLastHour: c.runs,
                                           tokensTodayJob: c.jobTokens, tokensTodayAll: c.allTokens,
                                           limits: l)
            #expect(decision == c.expected, "\(c.what): got \(decision)")
        }
    }

    @Test("a limit of zero or less is no limit, not a job that can never run")
    func nonPositiveLimitsAreUnlimited() {
        let none = limits(maxRunsPerHour: 0, dailyTokens: 0, globalDailyTokens: -1)
        #expect(JobRunner.admit(job: job(), inFlight: false, runsLastHour: 1_000,
                                tokensTodayJob: 10_000_000, tokensTodayAll: 99_000_000,
                                limits: none) == .run)
    }

    // MARK: JobLimits.resolve

    @Test("the job's policy overrides the global numbers, and nil means take the global one")
    func limitsResolvePreferOverrides() {
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 4
        config.jobDailyTokenBudget = 50_000
        config.jobGlobalDailyTokenBudget = 90_000
        config.jobPerRunTokenBudget = 12_000
        config.jobRunTimeoutSeconds = 120

        let defaults = JobLimits.resolve(job: job(), config: config)
        #expect(defaults == JobLimits(maxRunsPerHour: 4, dailyTokens: 50_000, globalDailyTokens: 90_000,
                                      perRunTokens: 12_000, runTimeoutSeconds: 120))

        let overridden = job(policy: JobPolicy(runTimeoutSeconds: 30, perRunTokenBudget: 7,
                                               dailyTokenBudget: 8, maxRunsPerHour: 9))
        #expect(JobLimits.resolve(job: overridden, config: config)
                == JobLimits(maxRunsPerHour: 9, dailyTokens: 8, globalDailyTokens: 90_000,
                             perRunTokens: 7, runTimeoutSeconds: 30),
                "the global daily budget is the only one a job cannot raise for itself")
    }

    @Test("an unset settings key resolves to the spec's default, not zero")
    func limitsResolveDefaults() {
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        #expect(JobLimits.resolve(job: job(), config: config)
                == JobLimits(maxRunsPerHour: 6, dailyTokens: 1_000_000, globalDailyTokens: 3_000_000,
                             perRunTokens: 200_000, runTimeoutSeconds: 600))
    }

    // MARK: fire — overlap

    @Test("a scheduled fire that overlaps a run writes one interrupted row and starts nothing")
    func scheduledOverlapWritesOneSkipRow() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")], latencyMs: 400)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "slow")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, reason: "schedule") }
        try await Task.sleep(nanoseconds: 100_000_000)
        await runner.fire(job: job, reason: "schedule")
        await first.value

        #expect(client.callCount == 1, "one run, not two")
        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 2)
        let skips = runs.filter { $0.failureReason == JobRunner.skipReason }
        #expect(skips.count == 1)
        #expect(skips.first?.status == .interrupted)
        #expect(skips.first?.transcriptConversationId == nil)
        #expect(state.conversations.filter { $0.isBackground }.count == 1)
    }

    @Test("a watcher fire that overlaps a run is dropped silently — a burst is not a ledger of rows")
    func watcherOverlapWritesNoRow() async throws {
        // D2's decision, kept: FSEvents delivers a burst per save, and one `interrupted` row per
        // event would spam the ledger far worse than the overlap it recorded.
        let (store, state, engine, client) = try harness([textResponse("tick")], latencyMs: 400)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = Job(name: "watched", prompt: "Reply with just the word tick.",
                      trigger: .fsEvent(FSWatch(path: "/tmp/watched")))
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, reason: "fsEvent", changedPaths: ["/tmp/a"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await runner.fire(job: job, reason: "fsEvent", changedPaths: ["/tmp/b"])
        await runner.fire(job: job, reason: "fsEvent", changedPaths: ["/tmp/c"])
        await first.value

        #expect(client.callCount == 1)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1,
                "a dropped watch fire writes no row")
    }

    @Test("the queue policy holds one fire and takes it when the run ends")
    func queuedFireRunsOnceAfterTheRun() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")], latencyMs: 400)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "queued-job", overlap: .queue)
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, reason: "schedule") }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Two triggers while it runs: the policy keeps one, never two.
        await runner.fire(job: job, reason: "schedule")
        await runner.fire(job: job, reason: "schedule")
        #expect(try store.ledger.job(id: job.id)?.queuedFire != nil, "the pending trigger is durable")
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1, "and it writes no row")
        await first.value

        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 2, "exactly one more run, not one per held trigger")
        #expect(runs.contains { $0.triggerKind == "queued" })
        #expect(client.callCount == 2)
        #expect(try store.ledger.job(id: job.id)?.queuedFire == nil, "and the queue is empty again")
    }

    @Test("a paused job's fire does nothing at all: no run, no row, no card")
    func pausedFireIsDroppedSilently() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "paused", paused: "daily token budget reached (job): 1 / 1")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        await runner.fire(job: job, reason: "schedule")

        #expect(client.callCount == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).isEmpty)
        #expect(state.conversations.filter { $0.isBackground }.isEmpty)
        let activity = state.conversations.first { $0.id == state.activityConversationId() }
        #expect(activity?.messages.filter { $0.role == .event }.isEmpty != false,
                "the pause card already went out when it was paused")
    }

    // MARK: fire — the breaker

    @Test("the run after the breaker's limit pauses the job, with the count on the row and the card")
    func breakerPausesWithTheCount() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 2
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = self.job(name: "thrasher")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, config: config, protectionEnabled: false)

        // One run inside the hour is still under the limit.
        try recordRun(store.ledger, job: job, at: now.addingTimeInterval(-600), tokens: 10)
        await runner.fire(job: job, reason: "schedule")
        #expect(client.callCount == 1, "the second run of the hour is allowed")
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)

        // The third is the one over the line.
        await runner.fire(job: job, reason: "schedule")
        #expect(client.callCount == 1, "no turn happened")
        let paused = try #require(try store.ledger.job(id: job.id))
        #expect(paused.pausedReason == "breaker: 2 runs in the last hour")

        let rows = try store.ledger.runs(jobId: job.id, limit: 10)
        let breaker = rows.filter { $0.failureReason == paused.pausedReason }
        #expect(breaker.count == 1)
        #expect(breaker.first?.status == .interrupted)

        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let cards = activity.messages.compactMap { EventCard.decode($0.content) }
        let pauseCard = try #require(cards.last)
        #expect(pauseCard.status == .interrupted)
        #expect(pauseCard.outcome == paused.pausedReason, "the card says the figure that tripped it")
    }

    @Test("an hour-old run is not counted by the breaker")
    func breakerCountsOnlyTheLastHour() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 1
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = self.job(name: "hourly")
        try store.ledger.upsert(job)
        try recordRun(store.ledger, job: job, at: now.addingTimeInterval(-3601), tokens: 10)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, config: config, protectionEnabled: false)

        await runner.fire(job: job, reason: "schedule")

        #expect(client.callCount == 1)
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)
    }

    // MARK: fire — the daily budgets

    @Test("the job's own daily budget pauses it, naming what it spent against what it had")
    func jobDailyBudgetPauses() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = self.job(name: "spender", policy: JobPolicy(dailyTokenBudget: 500))
        try store.ledger.upsert(job)
        try recordRun(store.ledger, job: job, at: now.addingTimeInterval(-60), tokens: 500)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, config: config, protectionEnabled: false)

        await runner.fire(job: job, reason: "schedule")

        #expect(client.callCount == 0)
        let paused = try #require(try store.ledger.job(id: job.id))
        #expect(paused.pausedReason == "daily token budget reached (job): 500 / 500")
        let rows = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(rows.filter { $0.failureReason == paused.pausedReason }.count == 1)
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        #expect(activity.messages.compactMap { EventCard.decode($0.content) }.last?.outcome
                == paused.pausedReason)
    }

    @Test("the global daily budget pauses a job that is well inside its own, with its own reason")
    func globalDailyBudgetPauses() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobGlobalDailyTokenBudget = 1_000
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let other = self.job(name: "the-other-job")
        let job = self.job(name: "innocent", policy: JobPolicy(dailyTokenBudget: 1_000_000))
        try store.ledger.upsert(other)
        try store.ledger.upsert(job)
        // Someone else spent the day's allowance.
        try recordRun(store.ledger, job: other, at: now.addingTimeInterval(-60), tokens: 1_000)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, config: config, protectionEnabled: false)

        await runner.fire(job: job, reason: "schedule")

        #expect(client.callCount == 0)
        #expect(try store.ledger.job(id: job.id)?.pausedReason
                == "daily token budget reached (global): 1000 / 1000")
    }

    @Test("yesterday's spend does not count against today")
    func budgetsCountTheLocalDay() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9))!
        let job = self.job(name: "yesterday", policy: JobPolicy(dailyTokenBudget: 500))
        try store.ledger.upsert(job)
        try recordRun(store.ledger, job: job, at: now.addingTimeInterval(-12 * 3600), tokens: 5_000)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, calendar: calendar, config: config,
                               protectionEnabled: false)

        await runner.fire(job: job, reason: "schedule")

        #expect(client.callCount == 1, "the spend was before local midnight")
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)
    }
}
