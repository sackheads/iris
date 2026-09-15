import Testing
import Foundation
@testable import iris

/// D1 gates terminal goal_complete for a main-principal goal with a locked contract. Everything
/// else must behave exactly as before — these are the guards for that claim (spec §2, §8).
@MainActor
@Suite("Done gate scope (D1)", .serialized)
struct DoneGateScopeTests {
    private func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "ok" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    private func goalComplete() -> GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string("done")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    @Test("a goal with no contract completes ungated, exactly as before")
    func contractlessGoalIsUngated() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.setGoal(for: id, goal: "do the thing")   // activeGoal, no contract
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "no contract means no gate")
        #expect(conv?.lastGoalEvaluation == nil)
    }

    @Test("a subagent's goal_complete is never gated")
    func subagentIsUngated() async {
        // A subagent terminates via goal_complete and its unit contract is graded by B3's own
        // machinery. Gating it here would change B2/B3/B4 semantics.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        let c = Criterion(text: "unit done", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "the unit", criteria: [c]))
        let engine = IrisEngine(state: app, tier: .easy, principal: .subagent, roleLabel: "engineer",
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("go", source: "System", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "a subagent must still terminate on goal_complete")
        #expect(conv?.goalContract?.gateAttempts == nil, "and the gate must not have run")
    }

    @Test("a soft-stop completes regardless of the verdict")
    func softStopBypassesTheGate() async {
        // restrictToGoalComplete is an emergency termination (iteration cap / loop detection). It
        // must be able to end a goal whatever the grader would have said, or a stuck loop with a
        // failing criterion could never stop.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let c = Criterion(text: "impossible", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [c]))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("summarize and stop", source: "System",
                                  conversationId: id, restrictToGoalComplete: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "an emergency stop must always be able to end the goal")
    }

    @Test("a non-final checkpoint still redirects to reach_checkpoint before the gate runs")
    func ladderGateStillWins() async {
        // §7's assumption: a paused checkpoint and a terminal goal_complete cannot coincide,
        // because the ladder redirect happens first. The gate's refusal depends on the
        // auto-reprompt, which is suppressed while paused — so this must stay true.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let a = Criterion(text: "one", kind: .qualitative, check: nil)
        let b = Criterion(text: "two", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [a, b])
        contract.milestones = [Milestone(title: "One", criterionIds: [a.id]),
                               Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, contract)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal != nil, "the ladder redirect must fire before any gating")
        #expect(conv?.goalContract?.gateAttempts == 0, "and the gate must not have run at all")
        #expect(conv?.goalContract?.checkpointStatus == .running)
    }
}
