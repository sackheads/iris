import Testing
import Foundation
@testable import iris

/// An ungated completion must say so. The panel's job across this whole arc is separating claims
/// from verified facts, and "completed without passing" is exactly such a fact.
@Suite("Gate outcome rendering (D1)")
struct GateOutcomeRenderingTests {
    @Test("a passed gate needs no banner")
    func passedIsQuiet() {
        #expect(GateOutcome.passed.bannerText(unmetCount: 0) == nil)
    }

    @Test("hitting the cap says so, with the count")
    func capIsLoud() {
        let text = GateOutcome.ungatedAtCap.bannerText(unmetCount: 2)
        #expect(text?.contains("without passing") == true)
        #expect(text?.contains("2") == true)
    }

    @Test("a failed grader is distinguished from an unmet criterion")
    func graderFailureIsItsOwnThing() {
        let text = GateOutcome.ungatedGraderFailed.bannerText(unmetCount: 0)
        #expect(text?.lowercased().contains("grader") == true)
        #expect(text?.contains("without passing") != true,
                "a grader that never ran is not the same as work that failed")
    }
}
