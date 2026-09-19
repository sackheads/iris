import Testing
import Foundation
@testable import iris

/// The row's wording. Kept out of the view so it is testable without a SwiftUI harness — and
/// because the distinction it draws is the point of the slice (spec §6).
@Suite("Human judgement row (D2)")
struct HumanJudgementRowTests {
    private func verdict(_ v: CriterionVerdictValue, _ m: VerdictMethod) -> CriterionVerdict {
        CriterionVerdict(criterionId: UUID(), criterionText: "reads well", kind: .humanJudged,
                         verdict: v, evidence: "", method: m)
    }

    @Test("a human accept is labelled as the user's judgement, not as verified")
    func humanMetIsLabelled() {
        let label = verdict(.met, .human).humanJudgementLabel
        #expect(label?.lowercased().contains("judgement") == true)
    }

    @Test("a human rejection is labelled too")
    func humanNotMetIsLabelled() {
        #expect(verdict(.notMet, .human).humanJudgementLabel != nil)
    }

    @Test("a grader verdict carries no judgement label")
    func graderVerdictIsUnlabelled() {
        #expect(verdict(.met, .judge).humanJudgementLabel == nil)
        #expect(verdict(.met, .check).humanJudgementLabel == nil)
    }

    @Test("an unjudged criterion carries no label — the buttons speak for it")
    func pendingIsUnlabelled() {
        #expect(verdict(.humanPending, .human).humanJudgementLabel == nil)
    }
}
