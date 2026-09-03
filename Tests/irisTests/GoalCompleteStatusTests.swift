import Testing
import Foundation
@testable import iris

/// Builds a GeminiResponse that calls goal_complete with a summary and optional criteria_status.
private func goalCompleteResponse(summary: String, criteriaStatus: JSONValue? = nil) -> GeminiResponse {
    var args: [String: JSONValue] = ["summary": .string(summary)]
    if let status = criteriaStatus {
        args["criteria_status"] = status
    }
    let call = FunctionCall(name: "goal_complete", args: args,
                            id: nil, thought_signature: nil, thoughtSignature: nil)
    let part = Part(text: nil, functionCall: call, functionResponse: nil,
                    thought_signature: nil, thoughtSignature: nil)
    return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                          usageMetadata: nil)
}

@MainActor
@Suite("GoalComplete status report")
struct GoalCompleteStatusTests {

    /// When goal_complete carries a criteria_status array, it is stored on the conversation
    /// as lastGoalCompletionReport (recorded BEFORE clearGoal nils the contract).
    @Test("criteria_status is stored and contract is cleared")
    func criteriaStatusStored() async {
        let appState = AppState()
        let convId = UUID()
        appState.createNewConversation(id: convId)
        appState.setGoal(for: convId, goal: "Ship the feature")

        let statusPayload: JSONValue = .array([
            .object([
                "criterion": .string("swift build green"),
                "status": .string("met"),
                "evidence": .string("Build succeeded with exit 0")
            ])
        ])
        let mock = FakeLLMClient(responses: [
            goalCompleteResponse(summary: "Done", criteriaStatus: statusPayload)
        ])
        // Use .subagent principal to skip the principal == .main reflection re-entry that would
        // loop infinitely in a scripted-client harness.
        let engine = IrisEngine(state: appState, tier: .medium, principal: .subagent, client: mock)

        await engine.processInput("Finish the goal.", source: "User", conversationId: convId)

        let conv = appState.conversations.first(where: { $0.id == convId })
        // The status report was captured before clearGoal ran.
        #expect(conv?.lastGoalCompletionReport == statusPayload)
        // The contract was cleared as usual.
        #expect(conv?.goalContract == nil)
    }

    /// When goal_complete omits criteria_status, lastGoalCompletionReport stays nil
    /// and everything else (clearGoal, summary push) still fires normally.
    @Test("omitting criteria_status leaves lastGoalCompletionReport nil")
    func noCriteriaStatus() async {
        let appState = AppState()
        let convId = UUID()
        appState.createNewConversation(id: convId)
        appState.setGoal(for: convId, goal: "Do something")

        let mock = FakeLLMClient(responses: [
            goalCompleteResponse(summary: "All done, no criteria")
        ])
        let engine = IrisEngine(state: appState, tier: .medium, principal: .subagent, client: mock)

        await engine.processInput("Finish.", source: "User", conversationId: convId)

        let conv = appState.conversations.first(where: { $0.id == convId })
        #expect(conv?.lastGoalCompletionReport == nil)
        #expect(conv?.goalContract == nil)
        // Summary was pushed to the conversation.
        #expect(conv?.messages.contains(where: { $0.content == "All done, no criteria" }) == true)
    }
}
