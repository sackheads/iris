import Testing
import Foundation
@testable import iris

/// The completion chip pairs the agent's self-report with the grader's verdict per criterion.
/// The self-report carries criterion TEXT, not ids, so pairing is a text match — and a sloppy one
/// can attribute the wrong status to a criterion, which is the opposite of what an honesty-focused
/// panel is for (#54).
@Suite("Completion self-report matching")
struct CompletionReportMatchingTests {
    private func item(_ criterion: String, _ status: String) -> CompletionReportItem {
        CompletionReportItem(id: criterion, criterion: criterion, status: status, evidence: "")
    }

    @Test("an exact match wins")
    func exactMatch() {
        let items = [item("tests pass", "met"), item("docs updated", "not_met")]
        #expect(CompletionSelfReportMatching.status(for: "tests pass", in: items) == "met")
        #expect(CompletionSelfReportMatching.status(for: "docs updated", in: items) == "not_met")
    }

    @Test("matching ignores case and surrounding whitespace")
    func looseButSafe() {
        let items = [item("  Tests Pass  ", "met")]
        #expect(CompletionSelfReportMatching.status(for: "tests pass", in: items) == "met")
    }

    @Test("a single partial match is still used — the model rarely echoes text verbatim")
    func uniquePartialMatch() {
        let items = [item("the tests pass on CI", "met")]
        #expect(CompletionSelfReportMatching.status(for: "tests pass", in: items) == "met")
    }

    @Test("an AMBIGUOUS partial match reports nothing rather than guessing")
    func ambiguousPartialIsRefused() {
        // Two criteria sharing a prefix is the exact case the old `contains` matcher got wrong:
        // it returned the first hit, silently attributing one criterion's status to another.
        let items = [item("tests pass on macOS", "met"), item("tests pass on Linux", "not_met")]
        #expect(CompletionSelfReportMatching.status(for: "tests pass", in: items) == "",
                "an ambiguous match must not be attributed to a criterion")
    }

    @Test("no match reports nothing")
    func noMatch() {
        #expect(CompletionSelfReportMatching.status(for: "something else", in: [item("tests pass", "met")]) == "")
    }

    @Test("an exact match is preferred over a partial one that would otherwise be ambiguous")
    func exactBeatsAmbiguity() {
        let items = [item("tests pass", "met"), item("tests pass on Linux", "not_met")]
        #expect(CompletionSelfReportMatching.status(for: "tests pass", in: items) == "met")
    }
}
