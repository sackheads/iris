import Testing
import Foundation
@testable import iris

/// D2 recorded a human verdict only in `lastGoalEvaluation`, which the next `beginGoalEvaluation`
/// overwrites and `sanitizeLoaded` clears on load. That is invisible while grading happens once,
/// at the terminal gate. D3 grades at every checkpoint, so the decision has to live on the
/// contract or the user is asked again at every later checkpoint (spec §5.1).
@MainActor
@Suite("Durable judgements (D3)")
struct DurableJudgementTests {

    private func lockedContract(_ app: AppState, _ id: UUID) -> (Criterion, Criterion) {
        let a = Criterion(text: "tests pass", kind: .qualitative, check: nil)
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        var c = GoalContract(objective: "ship it", criteria: [a, h])
        c.milestones = [Milestone(title: "First", criterionIds: [a.id, h.id]),
                        Milestone(title: "Last", criterionIds: [])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        return (a, h)
    }

    private func contractWithTwoHuman(_ app: AppState, _ id: UUID) -> (Criterion, Criterion, Criterion) {
        let a = Criterion(text: "tests pass", kind: .qualitative, check: nil)
        let h1 = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        let h2 = Criterion(text: "feels right", kind: .humanJudged, check: nil)
        var c = GoalContract(objective: "ship it", criteria: [a, h1, h2])
        c.milestones = [Milestone(title: "First", criterionIds: [a.id, h1.id, h2.id]),
                        Milestone(title: "Last", criterionIds: [])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        return (a, h1, h2)
    }

    @Test("accepting a criterion records it on the contract, not only the evaluation")
    func testAcceptancePersistsOnContract() {
        let app = AppState(); let id = UUID()
        let (a, h1, h2) = contractWithTwoHuman(app, id)

        let pending = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: h1.id, criterionText: h1.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human),
            CriterionVerdict(criterionId: h2.id, criterionText: h2.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, pending)
        app.beginJudgementPause(for: id, summary: "done")

        #expect(app.recordHumanJudgement(for: id, criterionId: h1.id, accepted: true) == true)

        // h2 is still pending, so the goal is not resolved yet, and the contract survives.
        let contract = app.conversations.first { $0.id == id }?.goalContract
        #expect(contract?.judgements[h1.id] == true, "the decision must outlive lastGoalEvaluation")
    }

    @Test("a recorded judgement survives a later re-grade")
    func testJudgementSurvivesRegrade() {
        let app = AppState(); let id = UUID()
        let (a, h1, h2) = contractWithTwoHuman(app, id)

        let pending = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: h1.id, criterionText: h1.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human),
            CriterionVerdict(criterionId: h2.id, criterionText: h2.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, pending)
        app.beginJudgementPause(for: id, summary: "done")
        _ = app.recordHumanJudgement(for: id, criterionId: h1.id, accepted: true)

        // A later checkpoint grades the projected contract from scratch. Before D3 this reset the
        // criterion to human_pending and asked again. h2 is still pending, so the goal is not
        // resolved yet, and the contract survives.
        let contract = app.conversations.first { $0.id == id }!.goalContract!
        let regraded = GoalEvaluationParsing.verdicts(from: [:], criteria: [a, h1, h2],
                                                      judgements: contract.judgements)

        let h1v = regraded.first { $0.criterionId == h1.id }
        #expect(h1v?.verdict == .met, "the re-grade must not discard the user's decision")
        #expect(h1v?.method == .human)
    }

    @Test("a terminal rejection is consumed by the rework it triggers, not kept forever")
    func testRejectionIsConsumedOnResume() throws {
        // Durability is right for an acceptance and wrong for a rejection. A persisted `false`
        // reconciles to `.notMet` at every later grade, stays in `blockingCriteria`, and refuses
        // the gate on every remaining attempt — a full grader run each time until
        // `maxDoneGateRetries` is gone — on a verdict the agent can never earn by working.
        // Rejecting resumes the agent to rework it, and that rework is what spends the verdict.
        let app = AppState(); let id = UUID()
        let a = Criterion(text: "tests pass", kind: .qualitative, check: nil)
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, GoalContract(objective: "ship it", criteria: [a, h]))

        app.recordEvaluation(for: id, GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: a.id, criterionText: a.text, kind: .qualitative,
                             verdict: .met, evidence: "green", method: .judge),
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date()))
        app.beginJudgementPause(for: id, summary: "done")

        #expect(app.recordHumanJudgement(for: id, criterionId: h.id, accepted: false) == true)

        let contract = try #require(app.conversations.first { $0.id == id }?.goalContract)
        #expect(contract.judgements[h.id] == nil,
                "the rejection must not outlive the rework it just asked for")

        // The next grade therefore puts the question back to the user rather than re-refusing the
        // gate with a verdict nothing the agent does could change.
        let regraded = GoalEvaluationParsing.verdicts(from: [:], criteria: [a, h],
                                                      judgements: contract.judgements)
        let hv = regraded.first { $0.criterionId == h.id }
        #expect(hv?.verdict == .humanPending, "the reworked criterion is the user's to decide again")
        let nextGrade = GoalEvaluation(status: .graded, criteria: regraded,
                                       startedAt: Date(), completedAt: Date())
        #expect(!contract.blockingCriteria(from: nextGrade).contains { $0.criterionId == h.id },
                "a pending verdict is not a block the agent has to clear — and not a refused gate")
    }
}
