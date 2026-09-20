import Testing
import Foundation
@testable import iris

@MainActor
@Suite("GoalEvaluator trigger")
struct GoalEvaluatorTriggerTests {
    private func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "done" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    @Test("goal_complete on a locked contract snapshots a .verifying evaluation before clearing the goal")
    func snapshots() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        var contract = GoalContract(objective: "obj", criteria: [Criterion(text: "c", kind: .qualitative, check: nil)])
        contract.lock()
        app.setGoalContract(for: id, contract)

        let done = FunctionCall(name: "goal_complete", args: ["summary": .string("done")],
                                id: nil, thought_signature: nil, thoughtSignature: nil)
        // The evaluator subagent will also spin up and hit the scripted client; give it a submit_evaluation then text.
        let submit = FunctionCall(name: "submit_evaluation",
            args: ["evaluations": .array([.object(["criterion_id": .string(contract.criteria[0].id.uuidString), "verdict": .string("met"), "evidence": .string("ok")])])],
            id: nil, thought_signature: nil, thoughtSignature: nil)
        let mock = FakeLLMClient(responses: [response(done), response(submit), response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: mock)
        await engine.processInput("go", source: "System", conversationId: id)

        // The self-report path still clears the goal…
        #expect(app.conversations.first { $0.id == id }?.activeGoal == nil)
        // …and #191's clearGoal nils lastGoalEvaluation along with goalContract once completion
        // finishes, so the snapshot this test used to find here (verifying, or graded if the
        // detached grader already finished) is no longer observable post-hoc.
        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.lastGoalEvaluation == nil)
        #expect(conv?.goalContract == nil)
    }
}
