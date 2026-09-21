import Testing
import Foundation
@testable import iris

/// #187 §4 "during a run" — the per-run token and time budget. The admission checks in
/// `JobRunner.fire` decide whether a run may start; this is the half that decides when one that
/// has started must stop, and it has to bite *between* model calls: a budget that is only read
/// afterwards has already been spent.
@MainActor
@Suite("Turn budget (#187)")
struct TurnBudgetTests {

    // MARK: Fixtures

    private func harness(_ responses: [GeminiResponse])
        throws -> (ConversationStore, AppState, IrisEngine, FakeLLMClient, UUID) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let conversation = UUID()
        state.createNewConversation(id: conversation)
        state.selectedConversationId = conversation
        let client = FakeLLMClient(responses: responses)
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, client, conversation)
    }

    /// A settings store of this suite's own (AGENTS invariant 7).
    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-turnbudget-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    /// A round that keeps the loop going: any tool call does, and an unknown name executes
    /// nothing at all ("Error: Unknown tool …") while still being a round the model asked for.
    private func probeRound(total: Int) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: "noop_probe", args: [:]))]))],
                       usageMetadata: UsageMetadata(promptTokenCount: total - 1,
                                                    candidatesTokenCount: 1, totalTokenCount: total))
    }

    private func textRound(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func systemLines(_ state: AppState, _ conversationId: UUID) -> [String] {
        (state.conversations.first { $0.id == conversationId }?.messages ?? [])
            .filter { $0.role == .system }.map(\.content)
    }

    // MARK: The decision

    @Test("tokens are compared at the budget, not past it; a zero budget is no budget")
    func stopReasonOnTokens() {
        let budget = TurnBudget(maxTokens: 100, deadline: Date().addingTimeInterval(600))
        #expect(budget.stopReason(tokensUsed: 99, now: Date()) == nil)
        #expect(budget.stopReason(tokensUsed: 100, now: Date()) == TurnBudget.tokensExceeded)
        #expect(budget.stopReason(tokensUsed: 4_000, now: Date()) == TurnBudget.tokensExceeded)

        let unlimited = TurnBudget(maxTokens: 0, deadline: Date().addingTimeInterval(600))
        #expect(unlimited.stopReason(tokensUsed: 10_000_000, now: Date()) == nil)
    }

    @Test("the deadline stops the turn at the instant it arrives")
    func stopReasonOnTime() {
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        let budget = TurnBudget(maxTokens: 0, deadline: deadline)
        #expect(budget.stopReason(tokensUsed: 0, now: deadline.addingTimeInterval(-1)) == nil)
        #expect(budget.stopReason(tokensUsed: 0, now: deadline) == TurnBudget.timeExceeded)
        #expect(budget.stopReason(tokensUsed: 0, now: deadline.addingTimeInterval(1)) == TurnBudget.timeExceeded)
    }

    @Test("an exhausted token budget outranks a passed deadline: it is the figure that was spent")
    func tokensOutrankTime() {
        let past = Date(timeIntervalSince1970: 1)
        let budget = TurnBudget(maxTokens: 10, deadline: past)
        #expect(budget.stopReason(tokensUsed: 10, now: Date()) == TurnBudget.tokensExceeded)
    }

    // MARK: In the turn

    @Test("a deadline already passed ends the turn before the first model call")
    func pastDeadlineEndsBeforeAnyModelCall() async throws {
        let (_, state, engine, client, conversation) = try harness([textRound("should never be asked")])

        await engine.processInput("do the thing", source: "job:test", conversationId: conversation,
                                  turnBudget: TurnBudget(maxTokens: 100_000,
                                                         deadline: Date().addingTimeInterval(-1)))

        #expect(client.callCount == 0, "the budget is read before the call, not after it")
        let line = try #require(systemLines(state, conversation).last)
        #expect(line == "[Main agent] \(TurnBudget.timeExceeded). \(IrisEngine.budgetStopMarker)")
        #expect(!line.contains("Summarizing"), "nothing promises a summary the stop does not produce")
        #expect(state.conversations.first { $0.id == conversation }?.messages.contains { $0.role == .agent } != true)
    }

    @Test("a three-round turn stops after the round that spent the budget")
    func tokenBudgetEndsTheTurnAfterOneRound() async throws {
        let (_, state, engine, client, conversation) = try harness([
            probeRound(total: 40), probeRound(total: 40), textRound("all done"),
        ])

        await engine.processInput("do the thing", source: "job:test", conversationId: conversation,
                                  turnBudget: TurnBudget(maxTokens: 30,
                                                         deadline: Date().addingTimeInterval(600)))

        #expect(client.callCount == 1, "round two is never asked for")
        let line = try #require(systemLines(state, conversation).last)
        #expect(line.contains(TurnBudget.tokensExceeded))
        #expect(line.contains(IrisEngine.budgetStopMarker))
        #expect(!line.contains("Summarizing"))
    }

    @Test("a turn inside its budget runs to its natural end")
    func aTurnInsideItsBudgetIsUntouched() async throws {
        let (_, state, engine, client, conversation) = try harness([
            probeRound(total: 40), textRound("all done"),
        ])

        await engine.processInput("do the thing", source: "job:test", conversationId: conversation,
                                  turnBudget: TurnBudget(maxTokens: 10_000,
                                                         deadline: Date().addingTimeInterval(600)))

        #expect(client.callCount == 2)
        #expect(systemLines(state, conversation).allSatisfy { !$0.contains(TurnBudget.tokensExceeded) })
        #expect(state.conversations.first { $0.id == conversation }?.messages
            .last { $0.role == .agent }?.content == "all done")
    }

    @Test("a message that arrived mid-turn is not stranded by the budget stop")
    func theBudgetStopDrainsWhatArrived() async throws {
        let (_, state, engine, _, conversation) = try harness([probeRound(total: 40), textRound("done")])
        state.enqueuePendingUserMessage(text: "actually, stop after this", attachments: [],
                                        for: conversation)

        // A deadline already gone, so the stop is the only thing that ever drains the inbox: the
        // round-boundary drain never runs at all.
        await engine.processInput("do the thing", source: "job:test", conversationId: conversation,
                                  turnBudget: TurnBudget(maxTokens: 0,
                                                         deadline: Date().addingTimeInterval(-1)))

        // Taken from the inbox AND written to history: taken and dropped is how a mid-task message
        // disappears without a trace.
        #expect(state.pendingUserMessageCount(for: conversation) == 0)
        let history = state.conversations.first { $0.id == conversation }?.history ?? []
        #expect(history.contains { $0.parts.contains { $0.text?.contains("actually, stop after this") == true } })
    }

    // MARK: Through a run

    @Test("a run that spends its per-run budget is a failed row and a card that says why")
    func budgetStopIsAFailedRun() async throws {
        let (store, state, engine, client, _) = try harness([
            probeRound(total: 40), probeRound(total: 40), textRound("all done"),
        ])
        var job = Job(name: "chatty", prompt: "Work forever.",
                      trigger: .schedule(.interval(seconds: 60)))
        job.policy.perRunTokenBudget = 30
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               activity: RecordingActivity())

        await runner.fire(job: job, reason: "schedule")

        #expect(client.callCount == 1)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == TurnBudget.tokensExceeded,
                "the reason alone, not the whole transcript line")
        #expect(run.totalTokens == 40, "what it spent is on the row")

        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.status == .failed)
        #expect(card.outcome == "\(TurnBudget.tokensExceeded) — retrying in 1 m")
        #expect(card.outcome?.contains("Summarizing") != true,
                "a budget stop does not summarize, and the card must not say it did")
    }
}
