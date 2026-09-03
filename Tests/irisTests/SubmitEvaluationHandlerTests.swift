import Testing
import Foundation
@testable import iris

@MainActor
@Suite("submit_evaluation handler")
struct SubmitEvaluationHandlerTests {
    private func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "done" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    @Test("submit_evaluation fires onEvaluationComplete with the payload and ends the evaluator loop")
    func firesCallback() async {
        let app = AppState()
        let evalId = UUID()
        app.createNewConversation(id: evalId, isSubagent: true)
        app.setGoal(for: evalId, goal: "grade the work")   // gives the evaluator loop a goal to clear

        // Capture the payload the handler forwards.
        actor Box { var v: JSONValue?; func set(_ x: JSONValue?) { v = x }; func get() -> JSONValue? { v } }
        let box = Box()
        app.onEvaluationComplete[evalId] = { payload in Task { await box.set(payload) } }

        let submit = FunctionCall(name: "submit_evaluation",
            args: ["evaluations": .array([.object(["criterion_id": .string(UUID().uuidString), "verdict": .string("met"), "evidence": .string("ok")])])],
            id: nil, thought_signature: nil, thoughtSignature: nil)
        // Response 1: submit_evaluation. Response 2: text (loop should already be ending).
        let mock = FakeLLMClient(responses: [response(submit), response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .evaluator, client: mock)
        await engine.processInput("grade", source: "System", conversationId: evalId)

        #expect(await box.get() != nil)                                   // callback fired with payload
        #expect(app.conversations.first { $0.id == evalId }?.activeGoal == nil)   // evaluator loop cleared
    }
}
