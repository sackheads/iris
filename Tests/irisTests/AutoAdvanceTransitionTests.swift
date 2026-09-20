import Testing
import Foundation
@testable import iris

/// The auto path must NOT reuse `advanceCheckpoint`: that ends in `resumeGoalLoop`, which re-arms
/// the auto-reprompt. Auto-advance fires inside a live tool call, so re-arming would run a second
/// loop beside the turn already in flight — the failure #172/#173 fixed for mid-turn steering.
@MainActor
@Suite("Auto-advance transitions (D3)")
struct AutoAdvanceTransitionTests {

    private func laddered(_ app: AppState, _ id: UUID) -> GoalContract {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let b = Criterion(text: "b", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "ship it", criteria: [a, b])
        c.milestones = [Milestone(title: "First", criterionIds: [a.id]),
                        Milestone(title: "Second", criterionIds: [b.id])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        return app.conversations.first { $0.id == id }!.goalContract!
    }

    private func gradedEval() -> GoalEvaluation {
        GoalEvaluation(status: .graded, criteria: [], startedAt: Date())
    }

    @Test("auto-advance bumps the milestone and leaves the loop running")
    func testAutoAdvanceBumpsAndStaysRunning() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1)
        #expect(c?.checkpointStatus == .running)
    }

    @Test("auto-advance appends an autoAdvanced outcome naming the milestone it left")
    func testAutoAdvanceRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointHistory.count == 1)
        #expect(c?.checkpointHistory.first?.resolution == .autoAdvanced)
        #expect(c?.checkpointHistory.first?.milestoneIndex == 0)
        #expect(c?.checkpointHistory.first?.milestoneTitle == "First")
    }

    @Test("auto-advance does not re-arm the goal loop")
    func testAutoAdvanceDoesNotResume() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        // resumeGoalLoop sets isThinking by starting a turn. The auto path must not.
        #expect(app.isThinking == false, "auto-advance must not start a second loop mid-turn")
    }

    @Test("the human approve path records humanApproved")
    func testApproveRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)
        app.recordEvaluation(for: id, gradedEval())

        app.advanceCheckpoint(for: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointHistory.first?.resolution == .humanApproved)
    }

    @Test("the human send-back path records humanSentBack and does not advance")
    func testSendBackRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)
        app.recordEvaluation(for: id, gradedEval())

        app.holdCheckpoint(for: id, feedback: "not quite")

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointHistory.first?.resolution == .humanSentBack)
        #expect(c?.currentMilestone == 0, "send back keeps working the same milestone")
    }

    @Test("auto-advance on a contract with no ladder does nothing")
    func testNoLadderIsANoOp() {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        var c = GoalContract(objective: "ship it",
                             criteria: [Criterion(text: "a", kind: .qualitative, check: nil)])
        c.milestones = []
        app.setGoalContract(for: id, c)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.currentMilestone == 0)
        #expect(after?.checkpointHistory.isEmpty == true)
    }
}
