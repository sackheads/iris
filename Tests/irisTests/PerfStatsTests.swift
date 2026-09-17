import Testing
@testable import iris

@Suite("PerfStats")
struct PerfStatsTests {
    @Test("median of empty is nil, of one is itself, of two is the mean")
    func medianSmall() {
        #expect(PerfStats.median([]) == nil)
        #expect(PerfStats.median([5]) == 5)
        #expect(PerfStats.median([1, 3]) == 2)
    }

    @Test("median handles odd and even lengths and unsorted input")
    func medianGeneral() {
        #expect(PerfStats.median([3, 1, 2]) == 2)
        #expect(PerfStats.median([4, 1, 3, 2]) == 2.5)
    }

    @Test("p90 is nearest-rank")
    func p90() {
        #expect(PerfStats.p90([]) == nil)
        #expect(PerfStats.p90([7]) == 7)
        #expect(PerfStats.p90([1, 2]) == 2)
        #expect(PerfStats.p90((1...10).map(Double.init)) == 9)
        #expect(PerfStats.p90((1...100).map(Double.init)) == 90)
    }

    @Test("percent change is relative to the baseline and nil for a zero baseline")
    func percentChange() {
        #expect(PerfStats.percentChange(from: 100, to: 120) == 0.2)
        #expect(PerfStats.percentChange(from: 100, to: 80) == -0.2)
        #expect(PerfStats.percentChange(from: 0, to: 5) == nil)
    }
}
