import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Goal checkpoint state")
struct GoalCheckpointStateTests {
    private func lockedLadder(on app: AppState, _ id: UUID) {
        app.createNewConversation(id: id)
        let a = Criterion(text: "build", kind: .executable, check: "swift build")
        let b = Criterion(text: "docs", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship", criteria: [a, b])
        c.milestones = [Milestone(title: "Compile", criterionIds: [a.id]),
                        Milestone(title: "Verify", criterionIds: [b.id])]
        app.setGoalContract(for: id, c)   // locks + normalizes
    }

    @Test("setCheckpointPaused pauses without clearing the goal")
    func pauses() {
        let app = AppState(); let id = UUID(); lockedLadder(on: app, id)
        app.setCheckpointPaused(for: id)
        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.checkpointStatus == .pausedForReview)
        #expect(conv?.activeGoal != nil)                 // loop gate intact
        #expect(conv?.goalContract?.currentMilestone == 0)
    }

    @Test("advanceCheckpoint moves to the next milestone and resumes")
    func advances() {
        let app = AppState(); let id = UUID(); lockedLadder(on: app, id)
        app.setCheckpointPaused(for: id)
        app.advanceCheckpoint(for: id)
        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.currentMilestone == 1)
        #expect(conv?.goalContract?.checkpointStatus == .running)
    }

    @Test("advanceCheckpoint clamps at the final milestone")
    func advanceClamps() {
        let app = AppState(); let id = UUID(); lockedLadder(on: app, id)
        app.advanceCheckpoint(for: id)   // -> 1 (final)
        app.advanceCheckpoint(for: id)   // stays 1
        #expect(app.conversations.first { $0.id == id }?.goalContract?.currentMilestone == 1)
    }

    @Test("holdCheckpoint keeps the milestone and resumes")
    func holds() {
        let app = AppState(); let id = UUID(); lockedLadder(on: app, id)
        app.setCheckpointPaused(for: id)
        app.holdCheckpoint(for: id, feedback: "not done")
        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.currentMilestone == 0)     // unchanged
        #expect(conv?.goalContract?.checkpointStatus == .running)
    }

    @Test("resume resets the goal iteration counter")
    func resumeResetsIterationCounter() {
        let app = AppState(); let id = UUID(); lockedLadder(on: app, id)
        // advanceCheckpoint path
        if let i = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[i].goalIterationCount = 7
        }
        app.setCheckpointPaused(for: id)
        app.advanceCheckpoint(for: id)
        #expect(app.conversations.first { $0.id == id }?.goalIterationCount == 0)
        // holdCheckpoint path
        if let i = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[i].goalIterationCount = 5
        }
        app.setCheckpointPaused(for: id)
        app.holdCheckpoint(for: id, feedback: nil)
        #expect(app.conversations.first { $0.id == id }?.goalIterationCount == 0)
    }

    @Test("setGoalContract normalizes an incomplete ladder on lock")
    func normalizesOnLock() {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let b = Criterion(text: "b", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "x", criteria: [a, b])
        c.milestones = [Milestone(title: "Only", criterionIds: [a.id])]   // b unassigned
        app.setGoalContract(for: id, c)
        let stored = app.conversations.first { $0.id == id }?.goalContract
        #expect(stored?.ladderIsValidPartition() == true)                  // b folded into a final milestone
        #expect(stored?.milestones.count == 2)
    }
}
