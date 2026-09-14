import Testing
import Foundation
@testable import iris

/// A subagent is handed its definition of done; it does not get to renegotiate it. B3 is the
/// first slice that gives a subagent a `goalContract` at all — which also, for the first time,
/// puts `oracleText()` in front of it, and that text names `amend_goal_contract` explicitly.
@MainActor
@Suite("Subagent contract integrity")
struct SubagentContractIntegrityTests {
    private func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "done" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> FunctionCall {
        FunctionCall(name: name, args: args, id: nil, thought_signature: nil, thoughtSignature: nil)
    }

    /// Drives one engine directly rather than going through `SubagentManager.shared`, so nothing
    /// here depends on the manager's global AppState.
    private func runEngine(principal: Principal, responses: [GeminiResponse],
                           on id: UUID, app: AppState) async {
        let engine = IrisEngine(state: app, tier: .easy, principal: principal,
                                roleLabel: principal == .subagent ? "engineer" : nil,
                                client: FakeLLMClient(responses: responses))
        await engine.processInput("go", source: "System", conversationId: id)
    }

    private func lockedContract(on app: AppState, id: UUID) -> GoalContract {
        let contract = GoalContract(objective: "build a widget", criteria: [
            Criterion(text: "the widget exists", kind: .qualitative, check: nil),
            Criterion(text: "it is tested", kind: .qualitative, check: nil)
        ])
        app.setGoalContract(for: id, contract)
        return contract
    }

    @Test("a subagent cannot amend the unit contract it was handed")
    func subagentCannotAmend() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        _ = lockedContract(on: app, id: id)

        let amend = call("amend_goal_contract", [
            "action": .string("remove"),
            "criterion": .string("it is tested"),
            "rationale": .string("too difficult")
        ])
        await runEngine(principal: .subagent, responses: [response(amend), response(nil)], on: id, app: app)

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.criteria.count == 2, "the subagent removed a criterion from its own contract")
        #expect(after?.changeLog.isEmpty == true)
    }

    @Test("the main agent can still amend its own contract")
    func mainAgentCanStillAmend() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        _ = lockedContract(on: app, id: id)

        let amend = call("amend_goal_contract", [
            "action": .string("remove"),
            "criterion": .string("it is tested"),
            "rationale": .string("the widget ships untested by design")
        ])
        await runEngine(principal: .main, responses: [response(amend), response(nil)], on: id, app: app)

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.criteria.count == 1)
        #expect(after?.changeLog.count == 1)
    }
}
