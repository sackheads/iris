import Testing
import Foundation
@testable import iris

/// Slice D3 §3 and §4. Auto-advance requires an affirmative clean grade; everything else pauses.
@Suite("Auto-advance rule (D3)")
struct AutoAdvanceRuleTests {

    /// A two-milestone ladder sitting on milestone 0, so `isFinalMilestone` is false.
    private func ladder(_ criteria: [Criterion]) -> GoalContract {
        var c = GoalContract(objective: "ship it", criteria: criteria)
        c.milestones = [Milestone(title: "First", criterionIds: criteria.map { $0.id }),
                        Milestone(title: "Last", criterionIds: [])]
        c.currentMilestone = 0
        c.lock()
        return c
    }

    private func eval(_ status: EvaluationStatus,
                      _ verdicts: [CriterionVerdict]) -> GoalEvaluation {
        GoalEvaluation(status: status, criteria: verdicts, startedAt: Date())
    }

    private func verdict(_ c: Criterion, _ v: CriterionVerdictValue,
                         method: VerdictMethod = .judge) -> CriterionVerdict {
        CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                         verdict: v, evidence: "e", method: method)
    }

    @Test("an all-met clean grade advances")
    func testCleanPassAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let contract = ladder([a])
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .met)])) == true)
    }

    @Test("one not_met pauses")
    func testNotMetPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let b = Criterion(text: "b", kind: .qualitative, check: nil)
        let contract = ladder([a, b])
        #expect(contract.canAutoAdvance(
            from: eval(.graded, [verdict(a, .met), verdict(b, .notMet)])) == false)
    }

    @Test("cannot_verify pauses")
    func testCannotVerifyPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let contract = ladder([a])
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .cannotVerify)])) == false)
    }

    @Test("a failed evaluation pauses (fail-safe)")
    func testFailedEvaluationPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let contract = ladder([a])
        #expect(contract.canAutoAdvance(from: eval(.failed, [verdict(a, .met)])) == false)
    }

    @Test("a missing evaluation pauses (fail-safe)")
    func testMissingEvaluationPauses() {
        let contract = ladder([Criterion(text: "a", kind: .qualitative, check: nil)])
        #expect(contract.canAutoAdvance(from: nil) == false)
    }

    @Test("an empty criteria list pauses (fail-safe)")
    func testEmptyCriteriaPauses() {
        let contract = ladder([])
        #expect(contract.canAutoAdvance(from: eval(.graded, [])) == false)
    }

    @Test("an unjudged humanJudged criterion pauses even when the grader said met")
    func testUnjudgedHumanCriterionPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        let contract = ladder([a, h])
        // Grader said .met, but no judgement (nil) — judgement logic must block this.
        let e = eval(.graded, [verdict(a, .met), verdict(h, .met, method: .human)])
        #expect(contract.canAutoAdvance(from: e) == false)
    }

    @Test("an accepted humanJudged criterion advances even when the grader said not met")
    func testAcceptedHumanCriterionAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        var contract = ladder([a, h])
        contract.judgements[h.id] = true
        // Grader said .notMet, but user accepted (true) — judgement logic must govern this.
        let e = eval(.graded, [verdict(a, .met), verdict(h, .notMet, method: .human)])
        #expect(contract.canAutoAdvance(from: e) == true)
    }

    @Test("a rejected humanJudged criterion pauses even when the grader said met")
    func testRejectedHumanCriterionPauses() {
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        var contract = ladder([h])
        contract.judgements[h.id] = false
        // Grader said .met, but user rejected (false) — judgement logic must block this.
        let e = eval(.graded, [verdict(h, .met, method: .human)])
        #expect(contract.canAutoAdvance(from: e) == false)
    }

    @Test("a waived criterion counts as resolved")
    func testWaivedCriterionAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        var contract = ladder([a])
        contract.waivers[a.id] = "not applicable on macOS"
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .notMet)])) == true)
    }

    @Test("a waived humanJudged criterion resolves without requiring a judgement")
    func testWaivedHumanJudgedCriterionAdvances() {
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        var contract = ladder([h])
        contract.waivers[h.id] = "grader has sufficient visibility"
        // Waiver is an independent resolution path; judgement is never consulted.
        let e = eval(.graded, [verdict(h, .met, method: .human)])
        #expect(contract.canAutoAdvance(from: e) == true)
    }

    @Test("the final milestone never auto-advances")
    func testFinalMilestoneNeverAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        var contract = ladder([a])
        contract.currentMilestone = 1   // the last index
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .met)])) == false)
    }

    @Test("a contract with no ladder never auto-advances")
    func testNoLadderNeverAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship it", criteria: [a])
        contract.lock()
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .met)])) == false)
    }
}
