// Tests/irisTests/PerfCompareTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfCompare")
struct PerfCompareTests {
    private func record(medianMs: Double, ratio: Double? = nil, provider: String = "Gemini", model: String = "gemini-3.8-flash", scenario: String = "capital-city") -> PerfRunRecord {
        var r = PerfRecordTests.sampleRecord()
        r.environment.provider = provider
        r.environment.models = ["medium": model]
        r.scenarios[0].name = scenario
        r.scenarios[0].rungs[0].medianMs = medianMs
        r.scenarios[0].summary.medianMs = medianMs
        r.scenarios[0].summary.overheadRatio = ratio
        return r
    }

    @Test("a 25% slower median is flagged at the default threshold; 10% is not")
    func flagging() {
        let slow = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 125), threshold: 0.2)
        #expect(slow.flagged.count == 1)
        #expect(slow.flagged.first?.metric == "median ms")
        #expect(slow.flagged.first?.rung == 5)
        #expect(PerfCompare.exitCode(slow) == 1)
        let fine = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 110), threshold: 0.2)
        #expect(fine.flagged.isEmpty)
        #expect(PerfCompare.exitCode(fine) == 0)
    }

    @Test("faster is never flagged")
    func fasterIsFine() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 50), threshold: 0.2)
        #expect(c.flagged.isEmpty)
        #expect(c.rows.first?.change == -0.5)
    }

    @Test("overhead ratio is compared when both records have it")
    func ratioCompared() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100, ratio: 2.0), current: record(medianMs: 100, ratio: 2.6), threshold: 0.2)
        #expect(c.flagged.map(\.metric) == ["overhead ratio"])
    }

    @Test("mismatched provider or model is refused with exit 2")
    func refusal() {
        let p = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 100, provider: "Anthropic"), threshold: 0.2)
        #expect(p.refusal?.contains("provider") == true)
        #expect(PerfCompare.exitCode(p) == 2)
        let m = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 100, model: "gemini-4"), threshold: 0.2)
        #expect(m.refusal?.contains("model") == true)
    }

    @Test("scenarios present in only one record are skipped")
    func unmatchedSkipped() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 300, scenario: "other"), threshold: 0.2)
        #expect(c.rows.isEmpty)
        #expect(PerfCompare.exitCode(c) == 0)
    }

    @Test("render shows percent change and marks flagged rows")
    func render() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 125), threshold: 0.2)
        let text = PerfCompare.render(c, threshold: 0.2)
        #expect(text.contains("+25.0%"))
        #expect(text.contains("REGRESSION"))
        #expect(text.contains("threshold 20%"))
    }
}
