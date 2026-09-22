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

    /// An LLM client whose FIRST call parks until the test opens the gate, so a run can be held
    /// open at a known point instead of by sleeping next to a slow fake. Every later call returns
    /// at once: what is being tested is what a second fire does while the first run is in flight.
    final class GatedClient: LLMClientProtocol, @unchecked Sendable {
        private let gate: JobSchedulerTests.Gate
        private let response: GeminiResponse
        private let lock = NSLock()
        private var calls = 0

        init(gate: JobSchedulerTests.Gate, response: GeminiResponse) {
            self.gate = gate
            self.response = response
        }

        /// Synchronous, so the lock is never held across a suspension (and never taken from an
        /// async context, which the compiler refuses).
        private func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            if bump() == 1 { await gate.arriveAndWait() }
            return response
        }
    }

    private func harness(_ responses: [GeminiResponse])
        throws -> (ConversationStore, AppState, IrisEngine, FakeLLMClient) {
        let client = FakeLLMClient(responses: responses)
        let (store, state, engine) = try harness(client: client)
        return (store, state, engine, client)
    }

    private func harness(client: any LLMClientProtocol)
        throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let userConversation = UUID()
        state.createNewConversation(id: userConversation)
        state.selectedConversationId = userConversation
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine)
    }

    /// A finished run already on the books, so the breaker and the budgets have something to
    /// count. It carries a transcript id because a real run always has one — that is exactly what
    /// tells the breaker a row was work rather than a refusal.
    private func recordRun(_ ledger: JobLedger, job: Job, at: Date, tokens: Int) throws {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: at,
                         transcriptConversationId: UUID())
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
        var disabled = job()
        disabled.enabled = false
        var pausedAndDisabled = job(paused: "paused by hand")
        pausedAndDisabled.enabled = false

        let cases: [(what: String, job: Job, inFlight: Bool, runs: Int, jobTokens: Int,
                     allTokens: Int, expected: JobRunner.Admission)] = [
            ("everything wrong at once: the pause wins and nothing is recorded",
             paused, true, 9, 999, 9_999, .dropPaused),
            ("a paused job that is otherwise fine is still dropped",
             paused, false, 0, 0, 0, .dropPaused),
            ("a disabled job is dropped the same way, whatever woke it",
             disabled, false, 0, 0, 0, .dropDisabled),
            ("the pause outranks the disable: it is the reason a person set",
             pausedAndDisabled, false, 0, 0, 0, .dropPaused),
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

        // Zero is not "no timeout" the way a zero token budget is: a turn nothing can end is the
        // failure the deadline exists for, so a hand-written zero takes the global default.
        let noTimeout = job(policy: JobPolicy(runTimeoutSeconds: 0))
        #expect(JobLimits.resolve(job: noTimeout, config: config).runTimeoutSeconds == 120)
        let negativeTimeout = job(policy: JobPolicy(runTimeoutSeconds: -1))
        #expect(JobLimits.resolve(job: negativeTimeout, config: config).runTimeoutSeconds == 120)

        // The known cost of reading "the job set it" as "it is not the struct's default":
        // a policy that deliberately pins 600 s is indistinguishable from one that never asked,
        // so the global stepper moves it anyway. The alternative — an optional column — is a
        // migration, and nothing yet lets a person pin a per-job timeout at all.
        let pinnedToTheDefault = job(policy: JobPolicy(runTimeoutSeconds: JobPolicy().runTimeoutSeconds))
        #expect(JobLimits.resolve(job: pinnedToTheDefault, config: config).runTimeoutSeconds == 120,
                "an explicit 600 reads as unset")
    }

    @Test("a negative limit resolves to the default, exactly as an absent one does")
    func limitsResolveClampNegatives() {
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 4
        config.jobDailyTokenBudget = 50_000
        config.jobGlobalDailyTokenBudget = 90_000
        config.jobPerRunTokenBudget = 12_000
        config.jobRunTimeoutSeconds = 120

        // A hand-edited policy. -1 is a typo, never a request for no limit at all, so each of
        // these takes the global number rather than switching its limit off.
        let negatives = job(policy: JobPolicy(runTimeoutSeconds: -1, perRunTokenBudget: -1,
                                              dailyTokenBudget: -5, maxRunsPerHour: -99))
        #expect(JobLimits.resolve(job: negatives, config: config)
                == JobLimits(maxRunsPerHour: 4, dailyTokens: 50_000, globalDailyTokens: 90_000,
                             perRunTokens: 12_000, runTimeoutSeconds: 120))

        // And a global set negative after launch — the one path `ConfigManager`'s own clamp at
        // init cannot see — falls back to the spec's figure rather than unbounding the system.
        config.jobMaxRunsPerHour = -1
        config.jobDailyTokenBudget = -1
        config.jobGlobalDailyTokenBudget = -1
        config.jobPerRunTokenBudget = -1
        config.jobRunTimeoutSeconds = -1
        #expect(JobLimits.resolve(job: job(), config: config)
                == JobLimits(maxRunsPerHour: 6, dailyTokens: 1_000_000, globalDailyTokens: 3_000_000,
                             perRunTokens: 200_000, runTimeoutSeconds: 600))

        // Zero is still the other reading, and deliberately so: a person may want a budget
        // unbounded, and only the timeout refuses that (a turn nothing can end).
        let zeroes = job(policy: JobPolicy(runTimeoutSeconds: 0, perRunTokenBudget: 0,
                                           dailyTokenBudget: 0, maxRunsPerHour: 0))
        let resolved = JobLimits.resolve(job: zeroes, config: config)
        #expect(resolved.perRunTokens == 0 && resolved.dailyTokens == 0 && resolved.maxRunsPerHour == 0)
        #expect(resolved.runTimeoutSeconds == 600)
    }

    @Test("a negative settings key reads back as the default, the same as an unset one")
    func configClampsNegativeJobLimits() {
        let name = "iris-admission-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        // A hand-edited plist, or a stepper driven past zero, before the app is launched.
        store.set(-1, forKey: "JOB_PER_RUN_TOKEN_BUDGET")
        store.set(-1, forKey: "JOB_DAILY_TOKEN_BUDGET")
        store.set(-1, forKey: "JOB_GLOBAL_DAILY_TOKEN_BUDGET")
        store.set(-1, forKey: "JOB_MAX_RUNS_PER_HOUR")
        store.set(-1, forKey: "JOB_RUN_TIMEOUT_SECONDS")

        let config = ConfigManager(store: store)
        #expect(config.jobPerRunTokenBudget == 200_000)
        #expect(config.jobDailyTokenBudget == 1_000_000)
        #expect(config.jobGlobalDailyTokenBudget == 3_000_000)
        #expect(config.jobMaxRunsPerHour == 6)
        #expect(config.jobRunTimeoutSeconds == 600)
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
        let gate = JobSchedulerTests.Gate()
        let client = GatedClient(gate: gate, response: textResponse("tick"))
        let (store, state, engine) = try harness(client: client)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "slow")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, origin: .schedule) }
        await gate.waitForEntry()
        await runner.fire(job: job, origin: .schedule)
        await gate.open()
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
        let gate = JobSchedulerTests.Gate()
        let client = GatedClient(gate: gate, response: textResponse("tick"))
        let (store, state, engine) = try harness(client: client)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = Job(name: "watched", prompt: "Reply with just the word tick.",
                      trigger: .fsEvent(FSWatch(path: "/tmp/watched")))
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, origin: .watcher(paths: ["/tmp/a"])) }
        await gate.waitForEntry()
        await runner.fire(job: job, origin: .watcher(paths: ["/tmp/b"]))
        await runner.fire(job: job, origin: .watcher(paths: ["/tmp/c"]))
        await gate.open()
        await first.value

        #expect(client.callCount == 1)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1,
                "a dropped watch fire writes no row")
    }

    @Test("a paused job's watch burst decides on the stored row, not the copy the watcher captured")
    func pausedWatchBurstWritesNothing() async throws {
        // `WatcherManager` captures the `Job` when it starts the stream and hands that same copy
        // to every event for the life of the watch. Deciding on it would re-admit a job paused
        // since — a pause row and a card per saved file.
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let stale = Job(name: "watched", prompt: "Reply with just the word tick.",
                        trigger: .fsEvent(FSWatch(path: "/tmp/watched")))
        try store.ledger.upsert(stale)
        try store.ledger.setPaused(jobId: stale.id, reason: "breaker: 6 runs in the last hour")
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        for path in ["/tmp/a", "/tmp/b", "/tmp/c"] {
            await runner.fire(job: stale, origin: .watcher(paths: [path]))
        }

        #expect(client.callCount == 0)
        #expect(try store.ledger.runs(jobId: stale.id, limit: 10).isEmpty, "no rows for a paused job")
        #expect(state.conversations.filter { $0.isBackground }.isEmpty)
        let activity = state.conversations.first { $0.id == state.activityConversationId() }
        #expect(activity?.messages.filter { $0.role == .event }.isEmpty != false, "and no cards")
    }

    @Test("a job deleted out from under a fire is dropped silently")
    func deletedJobIsDropped() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "gone")
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        await runner.fire(job: job, origin: .schedule)

        #expect(client.callCount == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).isEmpty)
    }

    @Test("the queue policy holds one fire, with the paths that woke it, and takes it when the run ends")
    func queuedFireRunsOnceAfterTheRun() async throws {
        let gate = JobSchedulerTests.Gate()
        let client = GatedClient(gate: gate, response: textResponse("tick"))
        let (store, state, engine) = try harness(client: client)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        var job = self.job(name: "queued-job", overlap: .queue)
        job.trigger = .fsEvent(FSWatch(path: "/tmp/queued"))
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, origin: .watcher(paths: ["/tmp/first"])) }
        await gate.waitForEntry()
        // Two triggers while it runs: the policy keeps one, never two.
        await runner.fire(job: job, origin: .watcher(paths: ["/tmp/second"]))
        await runner.fire(job: job, origin: .watcher(paths: ["/tmp/third"]))
        #expect(try store.ledger.job(id: job.id)?.queuedFire != nil, "the pending trigger is durable")
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1, "and it writes no row")
        await gate.open()
        await first.value

        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 2, "exactly one more run, not one per held trigger")
        #expect(runs.contains { $0.triggerKind == "queued" })
        #expect(client.callCount == 2)
        #expect(try store.ledger.job(id: job.id)?.queuedFire == nil, "and the queue is empty again")

        // The held fire kept what woke it: a run told only "something changed" cannot do the work.
        let queued = try #require(runs.first { $0.triggerKind == "queued" })
        let transcript = try #require(state.conversations.first { $0.id == queued.transcriptConversationId })
        let prompt = transcript.history.first?.parts.compactMap(\.text).joined() ?? ""
        #expect(prompt.contains("/tmp/third"), "the latest burst's paths travel with the held fire")
    }

    @Test("a job switched off the queue policy mid-run drops the fire it was holding, column and all")
    func switchingAwayFromQueueClearsTheHeldFire() async throws {
        let gate = JobSchedulerTests.Gate()
        let client = GatedClient(gate: gate, response: textResponse("tick"))
        let (store, state, engine) = try harness(client: client)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        var job = self.job(name: "flipper", overlap: .queue)
        job.trigger = .fsEvent(FSWatch(path: "/tmp/flip"))
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, origin: .watcher(paths: ["/tmp/flip/a"])) }
        await gate.waitForEntry()
        await runner.fire(job: job, origin: .watcher(paths: ["/tmp/flip/b"]))
        #expect(try store.ledger.job(id: job.id)?.queuedFire != nil)
        // The user (or a tool) switches the policy while the run is still going.
        var flipped = try #require(try store.ledger.job(id: job.id))
        flipped.policy.overlap = .skip
        try store.ledger.upsert(flipped)
        await gate.open()
        await first.value

        #expect(client.callCount == 1, "the held fire is abandoned, not deferred")
        #expect(try store.ledger.job(id: job.id)?.queuedFire == nil,
                "and the column goes with it, or `/jobs` shows a fire nothing will take")

        // Switched back, the job starts empty rather than inheriting the abandoned trigger.
        var back = try #require(try store.ledger.job(id: job.id))
        back.policy.overlap = .queue
        try store.ledger.upsert(back)
        await runner.fire(job: back, origin: .schedule)
        #expect(client.callCount == 2, "this fire runs; nothing was held for it")
        #expect(try store.ledger.job(id: job.id)?.queuedFire == nil)
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

        await runner.fire(job: job, origin: .schedule)

        #expect(client.callCount == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).isEmpty)
        #expect(state.conversations.filter { $0.isBackground }.isEmpty)
        let activity = state.conversations.first { $0.id == state.activityConversationId() }
        #expect(activity?.messages.filter { $0.role == .event }.isEmpty != false,
                "the pause card already went out when it was paused")
    }

    @Test("a disabled job's fire does nothing either: the scheduler skips it, a watch does not")
    func disabledFireIsDroppedSilently() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        // A watch fire never goes through the scheduler's `enabled` query, so this is the only
        // thing standing between a disabled job and a run per saved file.
        var job = Job(name: "switched-off", prompt: "Reply with just the word tick.",
                      trigger: .fsEvent(FSWatch(path: "/tmp/watched")))
        job.enabled = false
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let admission = await runner.fire(job: job, origin: .watcher(paths: ["/tmp/watched/a"]))

        #expect(admission == .dropDisabled)
        #expect(client.callCount == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).isEmpty)
        #expect(state.conversations.filter { $0.isBackground }.isEmpty)
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
        await runner.fire(job: job, origin: .schedule)
        #expect(client.callCount == 1, "the second run of the hour is allowed")
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)

        // The third is the one over the line.
        await runner.fire(job: job, origin: .schedule)
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

    @Test("skip rows do not count towards the breaker: refusals are not work")
    func breakerIgnoresSkipRows() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 2
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = self.job(name: "overlapper")
        try store.ledger.upsert(job)
        // A `.skip` job that overlapped itself all morning: rows, but no runs.
        for offset in [-900.0, -600.0, -300.0] {
            try JobRunner.recordSkip(job: job, ledger: store.ledger, triggerKind: "schedule", now: now.addingTimeInterval(offset))
        }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, config: config, protectionEnabled: false)

        await runner.fire(job: job, origin: .schedule)

        #expect(client.callCount == 1, "three skips are not three runs")
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)
    }

    @Test("the breaker's own pause row does not re-trip it the moment the job is resumed")
    func breakerIgnoresItsOwnPauseRow() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 1
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = self.job(name: "resumed")
        try store.ledger.upsert(job)
        let reason = JobRunner.breakerReason(count: 1)
        try JobRunner.recordStillborn(job: job, ledger: store.ledger, reason: reason,
                                      triggerKind: "schedule", now: now.addingTimeInterval(-300))
        try store.ledger.setPaused(jobId: job.id, reason: reason)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, config: config, protectionEnabled: false)

        // What `/jobs resume` does.
        try store.ledger.setPaused(jobId: job.id, reason: nil)
        await runner.fire(job: job, origin: .schedule)

        #expect(client.callCount == 1, "a resumed job runs; its pause row is not a run")
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)
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

        await runner.fire(job: job, origin: .schedule)

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

        await runner.fire(job: job, origin: .schedule)

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

        await runner.fire(job: job, origin: .schedule)

        #expect(client.callCount == 0)
        #expect(try store.ledger.job(id: job.id)?.pausedReason
                == "daily token budget reached (global): 1000 / 1000")
    }

    @Test("lastRunAt is stamped by a run that happens, and untouched by a fire that is refused")
    func lastRunAtFollowsRunsNotTriggers() async throws {
        // The scheduler advances the cadence before admission has decided anything, so it cannot
        // be the one to stamp this: a refused fire would look like a run in `/jobs`.
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 1
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = self.job(name: "stamped")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { now }, config: config, protectionEnabled: false)

        await runner.fire(job: job, origin: .schedule)
        #expect(client.callCount == 1)
        #expect(try store.ledger.job(id: job.id)?.lastRunAt == now, "the run stamps it")

        // The next fire trips the breaker: refused, so the stamp must not move.
        let later = now.addingTimeInterval(60)
        let refuser = JobRunner(state: state, engine: engine, ledger: store.ledger,
                                now: { later }, config: config, protectionEnabled: false)
        await refuser.fire(job: job, origin: .schedule)
        #expect(client.callCount == 1)
        #expect(try store.ledger.job(id: job.id)?.pausedReason != nil)
        #expect(try store.ledger.job(id: job.id)?.lastRunAt == now, "a refusal is not a run")
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

        await runner.fire(job: job, origin: .schedule)

        #expect(client.callCount == 1, "the spend was before local midnight")
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)
    }

    // MARK: fire — a ledger that cannot answer

    /// A usage read that always fails. Only the read: the writes that record the refusal still go
    /// to the real ledger, which is the half of the behaviour under test.
    private struct UnreadableUsage: JobUsageReading {
        struct Failure: Error, CustomStringConvertible { var description: String { "database is locked" } }
        func usage(jobId: UUID, now: Date, calendar: Calendar) throws -> JobUsage { throw Failure() }
        func tokensToday(jobId: UUID?, calendar: Calendar, now: Date) throws -> Int { throw Failure() }
    }

    @Test("a usage read that throws skips the fire and writes why — it does not open the breaker")
    func unreadableUsageSkipsTheFire() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = self.job(name: "unreadable")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, now: { now },
                               config: config, protectionEnabled: false,
                               usageSource: UnreadableUsage())

        let admission = await runner.fire(job: job, origin: .schedule)

        #expect(client.callCount == 0, "swallowed, the zero it used to read would have let this run")
        #expect(admission == .dropUnavailable(reason: "admission unavailable: database is locked"))
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .interrupted)
        #expect(run.failureReason == "admission unavailable: database is locked")
        #expect(run.transcriptConversationId == nil)
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil,
                "a transient read error is not worth a pause only a person can undo")
    }

    // MARK: fire — the catch-up count follows whatever ended the fire (§5, R44)

    /// The scheduler hands the first slot of a `replay` burst a note saying how many older
    /// occurrences the cap dropped. Whatever admission then does with that fire, the count has to
    /// land somewhere a person can find it: the pause card and the gate row were threaded first,
    /// and these three are the rest of the ways a burst's first slot ends. Two of them are
    /// *ordinary* on a wake, which is exactly when a catch-up happens — the job still running from
    /// before the sleep, and the `queue` policy holding the fire it could not start.
    private static let dropped = JobScheduler.skippedNote(27)

    @Test("a fire that overlaps a run records the catch-up count on the skip row")
    func anOverlapSkipCarriesTheCatchUpCount() async throws {
        let gate = JobSchedulerTests.Gate()
        let client = GatedClient(gate: gate, response: textResponse("tick"))
        let (store, state, engine) = try harness(client: client)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "still-going")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        // The job woke still running the turn it started before the Mac slept.
        let first = Task { await runner.fire(job: job, origin: .schedule) }
        await gate.waitForEntry()
        let overlapped = await runner.fire(job: job, origin: .schedule, note: Self.dropped)
        await gate.open()
        await first.value

        #expect(overlapped == .skipInFlight)
        let skip = try #require(try store.ledger.runs(jobId: job.id, limit: 10)
            .first { ($0.failureReason ?? "").hasPrefix(JobRunner.skipReason) })
        #expect(skip.failureReason == "\(JobRunner.skipReason) (\(Self.dropped))",
                "the skip row is the only thing this outcome writes, so the count goes on it")
    }

    @Test("a fire the queue policy holds keeps the catch-up count and spends it on the run it becomes")
    func aHeldFireCarriesTheCatchUpCount() async throws {
        let gate = JobSchedulerTests.Gate()
        let client = GatedClient(gate: gate, response: textResponse("tick"))
        let (store, state, engine) = try harness(client: client)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "queue-on-wake", overlap: .queue)
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false)

        let first = Task { await runner.fire(job: job, origin: .schedule) }
        await gate.waitForEntry()
        // Held, not dropped: nothing is written now, so the count has to wait with the fire.
        let held = await runner.fire(job: job, origin: .schedule, note: Self.dropped)
        #expect(held == .queued)
        await gate.open()
        await first.value

        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        let queued = try #require(runs.first { $0.triggerKind == "queued" })
        let cards = state.conversations
            .first { $0.id == state.activityConversationId() }?
            .messages.compactMap { EventCard.decode($0.content) } ?? []
        #expect(cards.count == 2)
        #expect(cards.first { $0.runId == queued.id }?.catchUpNote == Self.dropped,
                "the held fire *is* that fire, so it arrives with what it was carrying")
        #expect(cards.filter { $0.catchUpNote != nil }.count == 1,
                "and the run that was already going says nothing about a burst it was not part of")
    }

    @Test("a fire a ledger that cannot answer refuses still records the catch-up count")
    func anUnreadableLedgerCarriesTheCatchUpCount() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = self.job(name: "unreadable-on-wake")
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: config, protectionEnabled: false,
                               usageSource: UnreadableUsage())

        let admission = await runner.fire(job: job, origin: .schedule, note: Self.dropped)

        #expect(client.callCount == 0)
        #expect(admission == .dropUnavailable(reason: "admission unavailable: database is locked"))
        let row = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(row.failureReason == "admission unavailable: database is locked (\(Self.dropped))")
    }

    @Test("a refused hand-started fire writes a row that says manual, not the job's trigger")
    func aRefusedManualFireSaysManual() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobMaxRunsPerHour = 1
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var job = self.job(name: "watched")
        job.trigger = .fsEvent(FSWatch(path: "/tmp/watched"))
        try store.ledger.upsert(job)
        try recordRun(store.ledger, job: job, at: now.addingTimeInterval(-60), tokens: 10)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, now: { now },
                               config: config, protectionEnabled: false)

        await runner.fire(job: job, origin: .manual)

        #expect(client.callCount == 0)
        let refusal = try #require(try store.ledger.runs(jobId: job.id, limit: 10)
            .first { $0.failureReason == JobRunner.breakerReason(count: 1) })
        #expect(refusal.triggerKind == "manual")
    }
}
