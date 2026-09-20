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

        app.autoAdvanceCheckpoint(for: id, decidedAt: 0, evaluation: gradedEval())

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1)
        #expect(c?.checkpointStatus == .running)
    }

    @Test("auto-advance appends an autoAdvanced outcome naming the milestone it left")
    func testAutoAdvanceRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, decidedAt: 0, evaluation: gradedEval())

        let history = app.conversations.first { $0.id == id }?.checkpointHistory ?? []
        #expect(history.count == 1)
        #expect(history.first?.resolution == .autoAdvanced)
        #expect(history.first?.milestoneIndex == 0)
        #expect(history.first?.milestoneTitle == "First")
    }

    @Test("auto-advance does not re-arm the goal loop")
    func testAutoAdvanceDoesNotResume() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, decidedAt: 0, evaluation: gradedEval())

        // resumeGoalLoop sets isThinking by starting a turn. The auto path must not.
        #expect(app.isThinking == false, "auto-advance must not start a second loop mid-turn")
    }

    @Test("the human approve path records humanApproved")
    func testApproveRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)
        app.recordEvaluation(for: id, gradedEval())

        app.advanceCheckpoint(for: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.checkpointHistory.first?.resolution == .humanApproved)
    }

    @Test("approving with no grade on record stores a nil evaluation, not a fabricated failure")
    func testApproveWithNoGradeRecordsNilEvaluation() {
        // No `recordEvaluation` call here: `lastGoalEvaluation` stays nil, exactly as it would
        // after a restart (`sanitizeLoaded` clears it). Re-adding a
        // `?? GoalEvaluation(status: .failed, criteria: [])` fallback in `recordCheckpointOutcome`
        // would compile and pass every other test while quietly putting a grade nobody produced
        // into the audit trail — this is the test that catches it.
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.advanceCheckpoint(for: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.checkpointHistory.first?.evaluation == nil)
        #expect(conv?.checkpointHistory.first?.resolution == .humanApproved)
    }

    @Test("the human send-back path records humanSentBack and does not advance")
    func testSendBackRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)
        app.recordEvaluation(for: id, gradedEval())

        app.holdCheckpoint(for: id, feedback: "not quite")

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.checkpointHistory.first?.resolution == .humanSentBack)
        #expect(conv?.goalContract?.currentMilestone == 0, "send back keeps working the same milestone")
    }

    @Test("send-back on a ladder-less contract does not clear rejections goal-wide")
    func testSendBackWithoutLadderDoesNotClearRejections() {
        // `currentMilestoneCriteria()` falls back to ALL criteria when `hasLadder` is false.
        // `recordCheckpointOutcome` (called first, just above) already guards on `hasLadder`;
        // the rejection-consuming loop below it did not, so a send-back on a plain goal used to
        // clear every `false` judgement in the contract instead of leaving it for whichever gate
        // owns it.
        let app = AppState(); let id = UUID()
        let a = Criterion(text: "a", kind: .humanJudged, check: nil)
        var c = GoalContract(objective: "ship it", criteria: [a])
        c.milestones = []
        c.judgements[a.id] = false
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)

        app.holdCheckpoint(for: id, feedback: "not quite")

        #expect(app.conversations.first { $0.id == id }?.goalContract?.judgements[a.id] == false,
                "a ladder-less send-back must not touch judgements outside its own milestone")
    }

    @Test("a second advance decided for the same milestone is a no-op")
    func testDuplicateAdvanceForSameMilestoneIsANoOp() {
        // A turn's tool calls run concurrently (AGENTS.md invariant 3), so two `reach_checkpoint`
        // calls in one batch both read milestone 0 and both grade it clean. Advancing twice would
        // land on 2 with milestone 1 never worked, never graded, and nobody stopped — and would
        // stamp the second history entry with milestone 1 while carrying milestone 0's grade.
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, decidedAt: 0, evaluation: gradedEval())
        app.autoAdvanceCheckpoint(for: id, decidedAt: 0, evaluation: gradedEval())

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.currentMilestone == 1, "the ladder must advance exactly once")
        #expect(conv?.checkpointHistory.count == 1, "one checkpoint, one audit entry")
    }

    @Test("the checkpoint history outlives the goal it describes")
    func testHistorySurvivesGoalCompletion() {
        // `clearGoal` nils the contract on `goal_complete`, `/stop`, and LLM errors. A history
        // kept on the contract could only ever describe a goal still running, which is the
        // opposite of an audit trail.
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)
        app.autoAdvanceCheckpoint(for: id, decidedAt: 0, evaluation: gradedEval())

        app.clearGoal(for: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract == nil, "the goal really is over")
        #expect(conv?.checkpointHistory.count == 1, "how its checkpoints went must still be readable")
        #expect(conv?.checkpointHistory.first?.milestoneTitle == "First")
    }

    @Test("auto-advance on a contract with no ladder does nothing")
    func testNoLadderIsANoOp() {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        var c = GoalContract(objective: "ship it",
                             criteria: [Criterion(text: "a", kind: .qualitative, check: nil)])
        c.milestones = []
        app.setGoalContract(for: id, c)

        app.autoAdvanceCheckpoint(for: id, decidedAt: 0, evaluation: gradedEval())

        let after = app.conversations.first { $0.id == id }
        #expect(after?.goalContract?.currentMilestone == 0)
        #expect(after?.checkpointHistory.isEmpty == true)
    }
}
