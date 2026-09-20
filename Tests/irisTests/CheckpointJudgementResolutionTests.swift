import Testing
import Foundation
@testable import iris

/// A judgement pause at a CHECKPOINT is not terminal. Resolving one must not finish the goal:
/// `resolveJudgementIfComplete` was written for the `goal_complete` gate, where clearing the
/// contract is correct, and a mid-ladder pause reaching that path would erase the whole goal.
@MainActor
@Suite("Checkpoint judgement resolution")
struct CheckpointJudgementResolutionTests {

    /// A locked two-milestone contract with one humanJudged criterion, paused at checkpoint 0
    /// awaiting judgement — the state a checkpoint judgement pause leaves behind.
    private func pausedAtCheckpoint(_ app: AppState, _ id: UUID) -> Criterion {
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [h, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [h.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)

        let eval = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, eval)
        app.setCheckpointPaused(for: id)
        app.beginJudgementPause(for: id, summary: "milestone done")
        return h
    }

    @Test("accepting the last criterion at a checkpoint does not complete the goal")
    func testAcceptAtCheckpointDoesNotCompleteGoal() {
        let app = AppState(); let id = UUID()
        let h = pausedAtCheckpoint(app, id)

        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract != nil, "a checkpoint judgement must not clear the contract")
        #expect(conv?.activeGoal != nil, "the goal is still running; only a milestone was judged")
        #expect(conv?.goalContract?.judgements[h.id] == true, "the decision must survive")
    }

    @Test("resolution at a checkpoint clears the judgement flag but stays paused for review")
    func testCheckpointStaysPausedForReview() {
        let app = AppState(); let id = UUID()
        let h = pausedAtCheckpoint(app, id)

        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.awaitingHumanJudgement == false, "judging is done")
        #expect(c?.checkpointStatus == .pausedForReview,
                "approving the milestone is a separate decision, made with the existing controls")
    }

    @Test("resolution at a checkpoint does not resume the goal loop")
    func testCheckpointResolutionDoesNotResumeLoop() {
        let app = AppState(); let id = UUID()
        let h = pausedAtCheckpoint(app, id)

        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true)

        // `runThinkingTask` calls `beginThinking()` synchronously before its Task, so this cannot
        // race: if the loop had been resumed, `isThinking` would already be true here.
        #expect(app.isThinking == false, "the human is still deciding; nothing should be running")
    }

    @Test("rejecting at a checkpoint also stays paused rather than resuming")
    func testRejectAtCheckpointStaysPaused() {
        let app = AppState(); let id = UUID()
        let h = pausedAtCheckpoint(app, id)

        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: false)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.checkpointStatus == .pausedForReview)
        #expect(conv?.goalContract?.awaitingHumanJudgement == false)
        #expect(conv?.goalContract?.judgements[h.id] == false)
        #expect(app.isThinking == false, "'Send back' is the human's next click, not an auto-resume")
    }

    @Test("a terminal judgement pause still completes and clears the goal")
    func testTerminalPauseUnchanged() {
        let app = AppState(); let id = UUID()
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        var c = GoalContract(objective: "Ship it", criteria: [h])
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)   // no ladder, checkpointStatus stays .running

        let eval = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, eval)
        app.beginJudgementPause(for: id, summary: "all done")

        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract == nil, "the terminal path still clears the goal")
        #expect(conv?.activeGoal == nil)
    }
}
