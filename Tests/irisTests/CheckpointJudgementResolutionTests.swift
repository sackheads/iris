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
        // The verdict stands while the pause is open — it is what the user is about to act on.
        #expect(conv?.goalContract?.judgements[h.id] == false)
        #expect(app.isThinking == false, "'Send back' is the human's next click, not an auto-resume")
    }

    @Test("sending back at a checkpoint consumes the rejection rather than making it permanent")
    func testSendBackConsumesRejection() {
        // The mirror of the terminal gate's rejection branch (spec §6.1). `judgements` is durable,
        // so a `false` left in place reconciles to `.notMet` at every later grade, blocks
        // `canAutoAdvance` for the rest of the ladder, and refuses the terminal gate on a verdict
        // the agent can never earn. Send-back IS the rework trigger at a checkpoint, exactly as
        // resume is at the terminal gate, so it is what spends the verdict; the user is asked
        // again once the work has actually changed.
        let app = AppState(); let id = UUID()
        let h = pausedAtCheckpoint(app, id)
        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: false)

        app.holdCheckpoint(for: id, feedback: "try the phrasing again")

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.judgements[h.id] == nil, "the rework consumes the rejection")
        #expect(c?.currentMilestone == 0, "send back keeps working the same milestone")
    }

    @Test("sending back does not discard an acceptance")
    func testSendBackKeepsAcceptance() {
        let app = AppState(); let id = UUID()
        let h = pausedAtCheckpoint(app, id)
        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true)

        app.holdCheckpoint(for: id, feedback: "the other criterion needs work")

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.judgements[h.id] == true, "nothing about an acceptance needs re-deciding")
    }

    @Test("approving a checkpoint clears any outstanding judgement flag")
    func testAdvanceCheckpointClearsJudgementFlag() {
        // Defence in depth. `advanceCheckpoint` sets `checkpointStatus = .running`, which is half
        // the discriminator `resolveJudgementIfComplete` reads. Leaving `awaitingHumanJudgement`
        // set would make a later Accept/Reject take the TERMINAL branch — finishing and clearing
        // the whole goal at milestone 1 of 2 because the user answered one criterion.
        let app = AppState(); let id = UUID()
        _ = pausedAtCheckpoint(app, id)

        app.advanceCheckpoint(for: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.awaitingHumanJudgement == false,
                "the checkpoint is over, so nothing may still claim to be awaiting a verdict")
        #expect(c?.checkpointStatus == .running)
    }

    @Test("sending a checkpoint back clears any outstanding judgement flag")
    func testHoldCheckpointClearsJudgementFlag() {
        let app = AppState(); let id = UUID()
        _ = pausedAtCheckpoint(app, id)

        app.holdCheckpoint(for: id, feedback: "needs another pass")

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.awaitingHumanJudgement == false)
        #expect(c?.checkpointStatus == .running)
    }

    @Test("a LADDERED goal at its final milestone still completes through the terminal gate")
    func testLadderedTerminalPauseCompletes() {
        // The checkpoint early return keys on `checkpointStatus`, which a ladder-less contract can
        // never set — so the no-ladder case below pins nothing about the laddered terminal path.
        // A ladder that has walked to its last milestone finishes through `goal_complete` like any
        // other goal, and the early return must not swallow that.
        let app = AppState(); let id = UUID()
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, h])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Polish", criterionIds: [h.id])]
        c.currentMilestone = 1   // the final milestone, reached by walking the ladder
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)

        let eval = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: a.id, criterionText: a.text, kind: .qualitative,
                             verdict: .met, evidence: "saw it work", method: .judge),
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, eval)
        app.beginJudgementPause(for: id, summary: "all done")

        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract == nil, "the final milestone completes the goal")
        #expect(conv?.activeGoal == nil)
    }

    @Test("a terminal judgement pause still completes and clears the goal")
    func testTerminalPauseUnchanged() {
        let app = AppState(); let id = UUID()
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        let c = GoalContract(objective: "Ship it", criteria: [h])
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
