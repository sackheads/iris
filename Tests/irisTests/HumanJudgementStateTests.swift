import Testing
import Foundation
@testable import iris

/// D2's pause state. Deliberately NOT a CheckpointStatus case: that status drives ladder UI in 13
/// places, and ChatView suppresses the completion chip while it is set — which is exactly where
/// this slice's Accept/Reject buttons live (spec §5).
@Suite("Human judgement state (D2)")
struct HumanJudgementStateTests {
    @Test("isPaused covers a checkpoint pause")
    func checkpointPauseIsPaused() {
        var c = GoalContract(objective: "ship", criteria: [])
        c.checkpointStatus = .pausedForReview
        #expect(c.isPaused)
    }

    @Test("isPaused covers a judgement pause")
    func judgementPauseIsPaused() {
        var c = GoalContract(objective: "ship", criteria: [])
        c.awaitingHumanJudgement = true
        #expect(c.isPaused)
    }

    @Test("a running goal is not paused")
    func runningIsNotPaused() {
        let c = GoalContract(objective: "ship", criteria: [])
        #expect(!c.isPaused)
        #expect(!c.awaitingHumanJudgement)
    }

    @Test("a judgement pause does NOT set the checkpoint status")
    func judgementPauseLeavesCheckpointStatusAlone() {
        var c = GoalContract(objective: "ship", criteria: [])
        c.awaitingHumanJudgement = true
        // If this ever flips, ChatView hides the completion chip and the buttons vanish.
        #expect(c.checkpointStatus == .running)
    }

    @Test("the flag round-trips, and a pre-D2 contract decodes false")
    func codable() throws {
        var c = GoalContract(objective: "ship", criteria: [])
        c.awaitingHumanJudgement = true
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(c))
        #expect(back.awaitingHumanJudgement)

        let legacy: [String: Any] = [
            "objective": "ship",
            "criteria": [["id": UUID().uuidString, "text": "builds", "kind": "qualitative"]],
            "state": "locked"
        ]
        let old = try JSONDecoder().decode(
            GoalContract.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!old.awaitingHumanJudgement)
        #expect(old.objective == "ship")
    }

    @Test("a Conversation carrying a pre-D2 contract still decodes")
    func legacyConversationDecodes() throws {
        var conv = Conversation(title: "old")
        conv.goalContract = GoalContract(objective: "ship", criteria: [])
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.goalContract?.awaitingHumanJudgement == false)
        #expect(back.title == "old")
    }
}
