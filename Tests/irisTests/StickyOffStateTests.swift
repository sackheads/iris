import Testing
import Foundation
@testable import IrisKit

/// 5c §0.2: a sticky declaration does not widen what can be done. Every sticky tool, called while
/// its state is off, is refused at dispatch with a sentence.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct StickyOffStateTests {
    /// Scripted replies like `FakeLLMClient`, plus the requests it was sent.
    private final class ScriptedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [GeminiRequest] = []
        private let responses: [GeminiResponse]
        init(_ responses: [GeminiResponse]) { self.responses = responses }
        var requests: [GeminiRequest] { lock.withLock { sent } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock {
                sent.append(request)
                return responses[min(sent.count - 1, responses.count - 1)]
            }
        }
    }

    private static func reply(_ part: Part) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    // SessionToolsTests' shape, with a factStore and a prompt.
    private func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
    }

    @discardableResult
    private func runToolCall(_ call: FunctionCall, on app: AppState, as conversationId: UUID,
                             peerCount: Int, factStore: FactStoreManager? = nil,
                             prompt: String = "go") async -> String {
        let client = ScriptedClient([Self.reply(Part(functionCall: call)), Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], factStore: factStore, protectionEnabled: false,
                                sessionPeerCount: peerCount)
        await engine.processInput(prompt, source: "UI", conversationId: conversationId)
        return toolResultText(app, conversationId: conversationId)
    }

    // DelegateMilestoneTests' shape.
    private func ladder(on app: AppState, _ id: UUID, currentMilestone: Int = 0) {
        app.createNewConversation(id: id)
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = currentMilestone
        app.setGoalContract(for: id, c)
    }

    @Test func manageFactRefusesANonexistentId() async throws {
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        let facts = try FactStoreManager(inMemory: true)
        let staleId = UUID().uuidString
        let call = FunctionCall(name: "manage_fact",
                                args: ["action": .string("retract"), "fact_id": .string(staleId)], id: "c1")
        // No new guard here (plan note 2): the store's own id validation is the only boundary,
        // exactly as it was pre-5c. A sticky manage_fact declaration has no dangerous off state.
        let result = await runToolCall(call, on: app, as: id, peerCount: 0, factStore: facts)
        #expect(result.contains("unknown fact id"), Comment(rawValue: result))
    }

    @Test func manageFactActsOnAnIdFromHistory() async throws {
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        let facts = try FactStoreManager(inMemory: true)
        let fact = try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")

        // Turn 1 surfaces the fact (and so its id).
        let surfacing = ScriptedClient([Self.reply(Part(text: "Seattle."))])
        let first = IrisEngine(state: app, tier: .medium, client: surfacing, retryDelays: [],
                               factStore: facts, protectionEnabled: false, sessionPeerCount: 0)
        await first.processInput("Where does Brian live?", source: "UI", conversationId: id)
        let firstText = surfacing.requests.first?.contents.flatMap { $0.parts }.compactMap(\.text).joined() ?? ""
        #expect(firstText.contains(fact.id), "turn 1 must surface the id")

        // Turn 2 surfaces nothing new, and acts on the id from history.
        let call = FunctionCall(name: "manage_fact",
                                args: ["action": .string("retract"), "fact_id": .string(fact.id)], id: "c1")
        let client = ScriptedClient([Self.reply(Part(functionCall: call)), Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [],
                                factStore: facts, protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("carry on", source: "UI", conversationId: id)
        let turnContext = client.requests.first?.contents.last { $0.role == "user" }?.parts.compactMap(\.text).joined() ?? ""
        #expect(!turnContext.contains("Mid-Term Fact Store Memory"), "turn 2 surfaced no facts")
        let result = toolResultText(app, conversationId: id)
        #expect(result.contains("is now retracted"), Comment(rawValue: result))
    }

    /// `set_session_card` is not among them since #418: a session may name itself before a peer
    /// exists (`SessionToolsTests.setSessionCardWithNoPeers`).
    @Test func peerToolsRefuseWithNoPeers() async {
        let app = AppState(); let me = UUID(); app.createNewConversation(id: me)
        for call in [FunctionCall(name: "list_sessions", args: [:], id: "c1"),
                     FunctionCall(name: "send_to_session", args: ["session_id": .string(UUID().uuidString),
                                                                  "message": .string("hi")], id: "c1")] {
            #expect(await runToolCall(call, on: app, as: me, peerCount: 0) == IrisEngine.noPeersRefusal,
                    Comment(rawValue: call.name))
        }
    }

    @Test func reachCheckpointRefusesAtTheFinalMilestoneAndWithNoLadder() async {
        let call = FunctionCall(name: "reach_checkpoint",
                                args: ["milestone_summary": .string("done")], id: "c1")
        let app = AppState(); let id = UUID(); ladder(on: app, id, currentMilestone: 1)
        #expect(await runToolCall(call, on: app, as: id, peerCount: 0)
                == "This is the final checkpoint — call `goal_complete` to finish, not `reach_checkpoint`.")
        #expect(app.conversations.first { $0.id == id }?.goalContract?.checkpointStatus == .running)

        let bare = AppState(); let plain = UUID(); bare.createNewConversation(id: plain)
        #expect(await runToolCall(call, on: bare, as: plain, peerCount: 0)
                == "No checkpoint ladder is active. Call goal_complete when the goal is finished.")
    }

    @Test func delegateMilestoneRefusesWithNoLadder() async {
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        let call = FunctionCall(name: "delegate_milestone",
                                args: ["role": .string("engineer"), "effort": .string("low")], id: "c1")
        let result = await runToolCall(call, on: app, as: id, peerCount: 0)
        #expect(result.hasPrefix("No checkpoint ladder is active, so there is no milestone to delegate."),
                Comment(rawValue: result))
    }

    @Test func amendRefusesWithoutALockedContract() async {
        let call = FunctionCall(name: "amend_goal_contract",
                                args: ["action": .string("add"), "criterion": .string("also docs"),
                                       "rationale": .string("the work showed it")], id: "c1")
        // No contract at all (the goal ended; the declaration is sticky).
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        #expect(await runToolCall(call, on: app, as: id, peerCount: 0) == IrisEngine.amendUnlockedRefusal)

        // A draft under the user's review: refused, and the draft is untouched.
        let draftApp = AppState(); let d = UUID(); draftApp.createNewConversation(id: d)
        draftApp.setDraftContract(for: d, GoalContract(objective: "Ship",
                                                       criteria: [Criterion(text: "works", kind: .qualitative)]))
        #expect(await runToolCall(call, on: draftApp, as: d, peerCount: 0) == IrisEngine.amendUnlockedRefusal)
        #expect(draftApp.conversations.first { $0.id == d }?.goalContract?.criteria.map(\.text) == ["works"])
    }

    @Test func waiveRefusesWithoutAFailedGrade() async {
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        let criterion = Criterion(text: "works", kind: .qualitative)
        app.setGoalContract(for: id, GoalContract(objective: "Ship", criteria: [criterion]))
        #expect(app.conversations.first { $0.id == id }?.goalContract?.gateAttempts == 0)
        let call = FunctionCall(name: "waive_criterion",
                                args: ["criterion_id": .string(criterion.id.uuidString),
                                       "reason": .string("not applicable")], id: "c1")
        let result = await runToolCall(call, on: app, as: id, peerCount: 0)
        #expect(result.hasPrefix("Waiver rejected. "), Comment(rawValue: result))
        #expect(app.conversations.first { $0.id == id }?.goalContract?.waivers.isEmpty == true)
    }

    @Test func goalCompleteRefusesWithNoActiveGoal() async {
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        let call = FunctionCall(name: "goal_complete", args: ["summary": .string("Registered 3 flights")], id: "c1")
        let result = await runToolCall(call, on: app, as: id, peerCount: 0)
        #expect(result == IrisEngine.noGoalRefusal, Comment(rawValue: result))
        // No trace beyond the refusal result: no summary push, no tool-call pill, no panel.
        let conv = app.conversations.first { $0.id == id }
        let messages = conv?.messages ?? []
        #expect(!messages.contains { $0.content.contains("Registered 3 flights") }, "the summary was pushed")
        #expect(!messages.contains { $0.content.contains("[TOOL_CALL]") || $0.content.contains("Running tool:") },
                "the refused call left a pill")
        #expect(messages.filter { $0.role == .system }.isEmpty, Comment(rawValue: messages.map(\.content).joined(separator: " | ")))
        #expect(conv?.lastGoalCompletionReport == nil)
    }

    /// The reply-round bound (plain chat has no loop detector). Self-bounded: the client answers
    /// `goal_complete` eight times and then plain text, so a missing bound fails at 9 calls
    /// instead of spinning.
    @Test func refusedGoalCompleteGetsOneReplyRoundOnly() async {
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        app.stickyTools.record(["goal_complete"], for: id)
        #expect(app.conversations.first { $0.id == id }?.activeGoal == nil)
        let call = FunctionCall(name: "goal_complete", args: ["summary": .string("done")], id: "c1")
        let client = ScriptedClient(Array(repeating: Self.reply(Part(functionCall: call)), count: 8)
                                    + [Self.reply(Part(text: "ok"))])
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("carry on", source: "UI", conversationId: id)
        let declared = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        #expect(declared.contains("goal_complete"), "the sticky declaration is what this probes")
        #expect(client.requests.count <= 2, "a refused goal_complete must not loop: \(client.requests.count) calls")
    }

    /// A draft with a ladder, as `propose_goal_contract` leaves it while the user reviews.
    private func draftLadder(on app: AppState, _ id: UUID) {
        app.createNewConversation(id: id)
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        app.setDraftContract(for: id, c)
    }

    @Test func reachCheckpointRefusesOnAnUnlockedDraft() async {
        let app = AppState(); let id = UUID(); draftLadder(on: app, id)
        #expect(app.conversations.first { $0.id == id }?.goalContract?.isLocked == false)
        let call = FunctionCall(name: "reach_checkpoint", args: ["milestone_summary": .string("done")], id: "c1")
        #expect(await runToolCall(call, on: app, as: id, peerCount: 0) == IrisEngine.ladderUnlockedRefusal)
        let contract = app.conversations.first { $0.id == id }?.goalContract
        #expect(contract?.currentMilestone == 0 && contract?.checkpointStatus == .running && contract?.isLocked == false)
    }

    @Test func delegateMilestoneRefusesOnAnUnlockedDraft() async {
        let app = AppState(); let id = UUID(); draftLadder(on: app, id)
        let before = app.conversations.count
        let call = FunctionCall(name: "delegate_milestone",
                                args: ["role": .string("engineer"), "effort": .string("low")], id: "c1")
        #expect(await runToolCall(call, on: app, as: id, peerCount: 0) == IrisEngine.ladderUnlockedRefusal)
        #expect(app.conversations.count == before, "no subagent conversation was spawned")
    }
}
