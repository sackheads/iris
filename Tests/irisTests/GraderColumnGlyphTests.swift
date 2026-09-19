import Testing
import Foundation
import SwiftUI
@testable import iris

/// The graded column's whole rendering — glyph, spoken label, visible text, tint — from one
/// derivation keyed on BOTH `method` and `verdict`. That keying is the bug this covers: a verdict
/// the USER gave must never render, announce, or read as grader-verified evidence (spec §6). It
/// was split across three switches and only two of them were ever fixed.
@Suite("Grader column presentation (D2 follow-up)")
struct GraderColumnGlyphTests {
    private func verdict(_ v: CriterionVerdictValue, _ m: VerdictMethod) -> CriterionVerdict {
        CriterionVerdict(criterionId: UUID(), criterionText: "reads well", kind: .humanJudged,
                         verdict: v, evidence: "", method: m)
    }

    @Test("a human accept gets its own symbol and is announced as the user's judgement")
    func humanMet() {
        let column = verdict(.met, .human).graderColumnPresentation
        #expect(column.symbolName != "checkmark.circle.fill")
        #expect(column.accessibilityLabel == "Your judgement: met")
        #expect(!column.accessibilityLabel.contains("Grader"))
        #expect(column.isHumanJudgement)
    }

    @Test("a human accept's VISIBLE text says whose judgement it is, and is not grader green")
    func humanMetText() {
        let column = verdict(.met, .human).graderColumnPresentation
        #expect(column.text.contains("judgement"),
                "a bare 'met' beside a blue person glyph credits the grader for the user's call")
        #expect(column.tint != .green, "green is the grader's verified colour")
    }

    @Test("a human rejection gets its own symbol, text and announcement")
    func humanNotMet() {
        let column = verdict(.notMet, .human).graderColumnPresentation
        #expect(column.symbolName != "xmark.octagon.fill")
        #expect(column.accessibilityLabel == "Your judgement: not met")
        #expect(column.text.contains("judgement"))
        #expect(column.tint != .red)
        #expect(column.isHumanJudgement)
    }

    @Test("a grader met verdict keeps today's icon, text and label")
    func graderMet() {
        let column = verdict(.met, .judge).graderColumnPresentation
        #expect(column.symbolName == "checkmark.circle.fill")
        #expect(column.accessibilityLabel == "Grader: met")
        #expect(column.text == "met")
        #expect(column.tint == .green)
        #expect(!column.isHumanJudgement)
    }

    @Test("a grader not-met verdict keeps today's icon, text and label")
    func graderNotMet() {
        let column = verdict(.notMet, .check).graderColumnPresentation
        #expect(column.symbolName == "xmark.octagon.fill")
        #expect(column.accessibilityLabel == "Grader: not met")
        #expect(column.text == "not met")
        #expect(column.tint == .red)
    }

    @Test("a criterion still awaiting judgement keeps its current treatment")
    func humanPending() {
        let column = verdict(.humanPending, .human).graderColumnPresentation
        #expect(column.symbolName == "person.crop.circle.badge.questionmark")
        #expect(column.accessibilityLabel == "Awaiting human judgment")
        #expect(column.text == "your call")
        #expect(!column.isHumanJudgement, "nobody has judged it yet")
    }

    @Test("cannot_verify is neutral, whatever the method says")
    func cannotVerify() {
        let column = verdict(.cannotVerify, .judge).graderColumnPresentation
        #expect(column.text == "cannot verify")
        #expect(column.accessibilityLabel == "Grader: cannot verify")
    }
}
