import Testing
import Foundation
@testable import iris

/// The graded-column icon/accessibility-label choice. Kept out of the view so it is testable
/// without a SwiftUI harness — and because keying it on `method`, not just `verdict`, is the bug
/// this covers: a human's own verdict must never render, or announce, as grader-verified evidence
/// (spec §6).
@Suite("Grader column glyph (D2 follow-up)")
struct GraderColumnGlyphTests {
    private func verdict(_ v: CriterionVerdictValue, _ m: VerdictMethod) -> CriterionVerdict {
        CriterionVerdict(criterionId: UUID(), criterionText: "reads well", kind: .humanJudged,
                         verdict: v, evidence: "", method: m)
    }

    @Test("a human accept gets its own symbol and is announced as the user's judgement")
    func humanMet() {
        let glyph = verdict(.met, .human).graderColumnGlyph
        #expect(glyph.symbolName != "checkmark.circle.fill")
        #expect(glyph.accessibilityLabel == "Your judgement: met")
        #expect(!glyph.accessibilityLabel.contains("Grader"))
    }

    @Test("a human rejection gets its own symbol and is announced as the user's judgement")
    func humanNotMet() {
        let glyph = verdict(.notMet, .human).graderColumnGlyph
        #expect(glyph.symbolName != "xmark.octagon.fill")
        #expect(glyph.accessibilityLabel == "Your judgement: not met")
        #expect(!glyph.accessibilityLabel.contains("Grader"))
    }

    @Test("a grader met verdict keeps today's icon and label")
    func graderMet() {
        let glyph = verdict(.met, .judge).graderColumnGlyph
        #expect(glyph.symbolName == "checkmark.circle.fill")
        #expect(glyph.accessibilityLabel == "Grader: met")
    }

    @Test("a grader not-met verdict keeps today's icon and label")
    func graderNotMet() {
        let glyph = verdict(.notMet, .check).graderColumnGlyph
        #expect(glyph.symbolName == "xmark.octagon.fill")
        #expect(glyph.accessibilityLabel == "Grader: not met")
    }

    @Test("a criterion still awaiting judgement keeps its current treatment")
    func humanPending() {
        let glyph = verdict(.humanPending, .human).graderColumnGlyph
        #expect(glyph.symbolName == "person.crop.circle.badge.questionmark")
        #expect(glyph.accessibilityLabel == "Awaiting human judgment")
    }
}
