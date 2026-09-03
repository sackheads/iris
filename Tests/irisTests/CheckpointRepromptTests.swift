import Testing
import Foundation
@testable import iris

@MainActor
@Suite("Checkpoint reprompt suppression")
struct CheckpointRepromptTests {
    @Test("a paused checkpoint does not auto-reprompt")
    func pausedDoesNotReprompt() async {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        let a = Criterion(text: "build", kind: .qualitative, check: nil)
        let b = Criterion(text: "docs", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship", criteria: [a, b])
        c.milestones = [Milestone(title: "One", criterionIds: [a.id]),
                        Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, c)

        // reach_checkpoint, then a grader submit. If the loop wrongly reprompted, the scripted
        // client would run dry and the test would surface extra turns.
        let reach = FunctionCall(name: "reach_checkpoint", args: ["milestone_summary": .string("done")],
                                 id: nil, thought_signature: nil, thoughtSignature: nil)
        let reachResp = GeminiResponse(candidates: [Candidate(content: Content(role: "model",
                          parts: [Part(text: nil, functionCall: reach, functionResponse: nil,
                                       thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: nil)
        let submit = FunctionCall(name: "submit_evaluation", args: ["evaluations": .array([])],
                                  id: nil, thought_signature: nil, thoughtSignature: nil)
        let submitResp = GeminiResponse(candidates: [Candidate(content: Content(role: "model",
                          parts: [Part(text: nil, functionCall: submit, functionResponse: nil,
                                       thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: nil)
        let mock = FakeLLMClient(responses: [reachResp, submitResp])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: mock)
        await engine.processInput("work", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.checkpointStatus == .pausedForReview)
        // No "Auto-continuing goal loop" system message was pushed for this conversation.
        let autoContinue = conv?.messages.contains { $0.content.contains("Auto-continuing goal loop") } ?? false
        #expect(!autoContinue)
    }
}
