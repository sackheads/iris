import Testing
import Foundation
import os
@testable import iris

/// 5b §0.8 — a built-in job runs without a model turn: no request to the client, no background
/// conversation, one ledger row with zero tokens and no transcript, and a card only when the
/// built-in asks for one. It also skips the token budgets, which is the whole reason it can post
/// on the day a spent budget matters most.
///
/// Every test registers its built-in through `BuiltinJobs.$scopedRegistry`, a TaskLocal, so no
/// suite running beside this one sees it (invariant 7).
@MainActor
@Suite("Built-in jobs (5b §0.8)")
struct BuiltinJobTests {

    /// A built-in that records that it ran and answers with a fixed result.
    final class StubBuiltin: BuiltinJob {
        static let name = "stub"
        let result: BuiltinResult
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var runs: Int { count.withLock { $0 } }

        init(outcome: String = "3 jobs ran yesterday", card: Bool = true,
             status: BuiltinResult.Status = .completed) {
            result = BuiltinResult(outcome: outcome, card: card, status: status)
        }

        func run(ledger: JobLedger, now: Date, calendar: Calendar, config: ConfigManager) async -> BuiltinResult {
            count.withLock { $0 += 1 }
            return result
        }
    }

    private func builtinJob(_ name: String = "digest", action: String = StubBuiltin.name) -> Job {
        Job(name: name, prompt: "", trigger: .schedule(.interval(seconds: 60)),
            action: .builtin(action))
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-builtin-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func harness() throws -> (ConversationStore, AppState, IrisEngine, FakeLLMClient) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let user = UUID()
        state.createNewConversation(id: user)
        state.selectedConversationId = user
        // A response is scripted so a turn that *did* happen would succeed and be counted, rather
        // than fail in a way that might pass for "no turn".
        let client = FakeLLMClient(responses: [GeminiResponse(
            candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "tick")]))],
            usageMetadata: nil)])
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, client)
    }

    private func eventCards(_ state: AppState) -> [EventCard] {
        state.conversations.flatMap(\.messages).filter { $0.role == .event }
            .compactMap { EventCard.decode($0.content) }
    }

    @Test("a built-in fire makes no model request, writes one zero-token row with no transcript, and opens no conversation")
    func builtinRunsWithoutAModel() async throws {
        let (store, state, engine, client) = try harness()
        let job = builtinJob()
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let firedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, now: { firedAt }, config: config)
        let stub = StubBuiltin()

        let admission = await BuiltinJobs.$scopedRegistry.withValue([StubBuiltin.name: stub]) {
            await runner.fire(job: job, origin: .schedule)
        }

        #expect(admission == .run)
        #expect(stub.runs == 1)
        #expect(client.callCount == 0, "a built-in is not a turn")
        #expect(state.conversations.filter(\.isBackground).isEmpty, "and has no transcript to open")

        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.status == .completed)
        #expect(run.outcome == "3 jobs ran yesterday")
        #expect(run.totalTokens == 0)
        #expect(run.transcriptConversationId == nil)
        #expect(run.finishedAt == firedAt)
        #expect(try store.ledger.job(id: job.id)?.lastRunAt == firedAt, "/jobs' last-run column moves")

        let cards = eventCards(state)
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.kind == "job_run")
        #expect(card.runId == run.id)
        #expect(card.status == .completed)
        #expect(card.outcome == "3 jobs ran yesterday")
        #expect(card.totalTokens == 0)
        #expect(card.transcriptConversationId == nil)
        // Drawn as a body, so a multi-line report is not cut to its first line.
        #expect(card.builtin)
        #expect(card.outcomeIsBody)
        #expect(state.conversations.first { $0.id == state.activityConversationId() }?
                    .messages.contains { $0.role == .event } == true, "delivered to Iris, the default destination")
    }

    @Test("a built-in that asks for no card delivers nothing, and still writes its row")
    func noCardDeliversNothing() async throws {
        let (store, state, engine, _) = try harness()
        let job = builtinJob()
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let stub = StubBuiltin(outcome: "nothing to report", card: false)

        await BuiltinJobs.$scopedRegistry.withValue([StubBuiltin.name: stub]) {
            await runner.fire(job: job, origin: .schedule)
        }

        #expect(stub.runs == 1)
        #expect(eventCards(state).isEmpty)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).map(\.status) == [.completed])
    }

    @Test("a built-in that reports failure writes a failed row with its fixed reason, which never counts as completed")
    func failedResultIsRecordedAsFailed() async throws {
        let (store, state, engine, client) = try harness()
        let job = builtinJob()
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let stub = StubBuiltin(outcome: DailyDigest.unreadableOutcome,
                               status: .failed(reason: DailyDigest.unreadableReason))

        await BuiltinJobs.$scopedRegistry.withValue([StubBuiltin.name: stub]) {
            await runner.fire(job: job, origin: .schedule)
        }

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 10).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == DailyDigest.unreadableReason)
        #expect(run.outcome == DailyDigest.unreadableOutcome)
        #expect(client.callCount == 0)
        // The digest's window asks this, so a failed digest cannot close it.
        #expect(try store.ledger.lastCompletedRunStart(action: .builtin(StubBuiltin.name),
                                                       before: Date().addingTimeInterval(60)) == nil)
        let card = try #require(eventCards(state).first)
        #expect(card.status == .failed)
        #expect(Briefing.reason(run) == "ledger unreadable")
    }

    @Test("a built-in name nothing registered fails its row and pauses the job on the first failure")
    func unknownBuiltinFailsAndPauses() async throws {
        let (store, state, engine, client) = try harness()
        let job = builtinJob(action: "no_such_thing")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)

        await BuiltinJobs.$scopedRegistry.withValue([StubBuiltin.name: StubBuiltin()]) {
            await runner.fire(job: job, origin: .schedule)
        }

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 10).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == "unknown built-in: no_such_thing")
        #expect(run.transcriptConversationId == nil)
        #expect(client.callCount == 0)
        #expect(state.conversations.filter(\.isBackground).isEmpty)
        // Not the retry ladder: retrying cannot register the name.
        let stored = try #require(try store.ledger.job(id: job.id))
        #expect(stored.pausedReason == "unknown built-in: no_such_thing")
        #expect(stored.retryAttempt == 0)
        let card = try #require(eventCards(state).first)
        #expect(card.outcome == "paused — unknown built-in: no_such_thing")
        // The briefing names it with its fixed word rather than echoing the stored text.
        #expect(Briefing.pausedWord(stored.pausedReason) == "unknown built-in")
        #expect(Briefing.reason(run, knownTools: []) == "unknown built-in")
    }

    @Test("with the global daily budget spent, a built-in still runs and a prompt job is refused")
    func builtinSkipsASpentBudget() async throws {
        let (store, state, engine, client) = try harness()
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.jobGlobalDailyTokenBudget = 100
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        // Spend the global budget on a third job's run, today.
        let spender = Job(name: "spender", prompt: "p", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(spender)
        let spent = JobRun(jobId: spender.id, jobName: spender.name, triggerKind: "schedule",
                           startedAt: at, transcriptConversationId: UUID())
        try store.ledger.begin(run: spent)
        try store.ledger.finish(runId: spent.id, status: .completed, outcome: "spent", failureReason: nil,
                                blockedTool: nil, tokens: TokenUsage(totalTokenCount: 500), finishedAt: at)

        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, now: { at }, config: config)
        let builtin = builtinJob()
        let prompt = Job(name: "asker", prompt: "Reply with tick.", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(builtin)
        try store.ledger.upsert(prompt)
        let stub = StubBuiltin()

        let (builtinAdmission, promptAdmission) = await BuiltinJobs.$scopedRegistry.withValue(
            [StubBuiltin.name: stub]) {
            (await runner.fire(job: builtin, origin: .schedule),
             await runner.fire(job: prompt, origin: .schedule))
        }

        #expect(builtinAdmission == .run)
        #expect(stub.runs == 1)
        #expect(try store.ledger.runs(jobId: builtin.id, limit: 10).map(\.status) == [.completed])
        // The seed bites: the same state refuses the job that would spend tokens.
        #expect(promptAdmission == .pauseBudget(scope: "global", used: 500, limit: 100))
        #expect(try store.ledger.job(id: prompt.id)?.pausedReason != nil)
        #expect(client.callCount == 0)
    }
}
