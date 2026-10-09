import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Goal Complete Tests")
struct GoalCompleteTests {

    @Test("pushToUI emits summary on goal completion")
    func testGoalCompletePushesSummaryToUI() async throws {
        let appState = AppState()
        let convId = UUID()
        appState.createNewConversation(id: convId)
        appState.setGoal(for: convId, goal: "Fix the bug")

        let engine = IrisEngine(state: appState, tier: .medium)
        await engine.pushToUI(role: .agent, text: "Goal accomplished successfully.", conversationId: convId)

        let conv = appState.conversations.first(where: { $0.id == convId })
        #expect(conv != nil)
        #expect(conv?.messages.contains(where: { $0.content == "Goal accomplished successfully." }) == true)
    }
}
