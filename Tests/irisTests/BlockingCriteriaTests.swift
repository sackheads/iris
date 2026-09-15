import Testing
import Foundation
@testable import iris

/// The gate acts on evidence of failure, not absence of evidence (spec §4).
@Suite("Blocking criteria (D1)")
struct BlockingCriteriaTests {
    private func verdict(_ c: Criterion, _ v: CriterionVerdictValue) -> CriterionVerdict {
        CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                         verdict: v, evidence: "because", method: .judge)
    }

    private func setup() -> (GoalContract, Criterion, Criterion, Criterion, Criterion) {
        let a = Criterion(text: "builds", kind: .qualitative, check: nil)
        let b = Criterion(text: "tested", kind: .qualitative, check: nil)
        let c = Criterion(text: "unverifiable", kind: .qualitative, check: nil)
        let d = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        return (GoalContract(objective: "ship", criteria: [a, b, c, d]), a, b, c, d)
    }

    private func evaluation(_ verdicts: [CriterionVerdict], status: EvaluationStatus = .graded) -> GoalEvaluation {
        GoalEvaluation(status: status, criteria: verdicts, startedAt: Date(), completedAt: Date())
    }

    @Test("not_met blocks")
    func notMetBlocks() {
        let (contract, a, b, _, _) = setup()
        let eval = evaluation([verdict(a, .met), verdict(b, .notMet)])
        #expect(contract.blockingCriteria(from: eval).map(\.criterionText) == ["tested"])
    }

    @Test("cannot_verify does not block — the grader could not determine it, not the agent")
    func cannotVerifyPasses() {
        let (contract, a, _, c, _) = setup()
        let eval = evaluation([verdict(a, .met), verdict(c, .cannotVerify)])
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }

    @Test("human_pending does not block — it can never be auto-graded")
    func humanPendingPasses() {
        let (contract, a, _, _, d) = setup()
        let eval = evaluation([verdict(a, .met), verdict(d, .humanPending)])
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }

    @Test("a waived not_met does not block")
    func waivedNotMetPasses() {
        var (contract, a, b, _, _) = setup()
        contract.waivers[b.id] = "no test harness in this repo"
        let eval = evaluation([verdict(a, .met), verdict(b, .notMet)])
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }

    @Test("waiving one criterion does not waive another that is also not_met")
    func waiverIsScoped() {
        var (contract, a, b, _, _) = setup()
        contract.waivers[a.id] = "n/a"
        let eval = evaluation([verdict(a, .notMet), verdict(b, .notMet)])
        #expect(contract.blockingCriteria(from: eval).map(\.criterionText) == ["tested"])
    }

    @Test("a failed grader blocks nothing — its verdicts are placeholders, not findings")
    func failedGraderBlocksNothing() {
        let (contract, a, b, _, _) = setup()
        let eval = evaluation([verdict(a, .notMet), verdict(b, .notMet)], status: .failed)
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }
}
