import Testing
import Foundation
@testable import iris

/// The row's wording, which is the most-read half of the icon/text pair. Kept out of the view so
/// it is testable without a SwiftUI harness — and because the distinction it draws is the point of
/// the slice (spec §6): a human accept renders "met — your judgement", never a bare "met".
@Suite("Human judgement row (D2)")
struct HumanJudgementRowTests {
    private func verdict(_ v: CriterionVerdictValue, _ m: VerdictMethod) -> CriterionVerdict {
        CriterionVerdict(criterionId: UUID(), criterionText: "reads well", kind: .humanJudged,
                         verdict: v, evidence: "", method: m)
    }

    @Test("a human accept is labelled as the user's judgement, not as verified")
    func humanMetIsLabelled() {
        let text = verdict(.met, .human).graderColumnPresentation.text
        #expect(text.lowercased().contains("judgement"))
        #expect(text != "met")
    }

    @Test("a human rejection is labelled too")
    func humanNotMetIsLabelled() {
        #expect(verdict(.notMet, .human).graderColumnPresentation.text.lowercased().contains("judgement"))
    }

    @Test("a grader verdict claims no judgement of the user's")
    func graderVerdictIsUnlabelled() {
        #expect(!verdict(.met, .judge).graderColumnPresentation.text.contains("judgement"))
        #expect(!verdict(.met, .check).graderColumnPresentation.text.contains("judgement"))
    }

    @Test("an unjudged criterion claims no judgement — the buttons speak for it")
    func pendingIsUnlabelled() {
        #expect(!verdict(.humanPending, .human).graderColumnPresentation.text.contains("judgement"))
    }
}
