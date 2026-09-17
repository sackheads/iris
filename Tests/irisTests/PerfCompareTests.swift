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

    @Test("prompt tokens are compared for ladder-shaped rungs")
    func ladderPromptTokens() {
        let call100 = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 100, outputTokens: 3, returnedToolCalls: false)
        let rep100 = PerfRepetition(index: 0, coldStart: true, wallClockMs: 100, turns: [], modelCalls: [call100], error: nil)
        let rung100 = PerfRungResult(rung: 1, repetitions: [rep100], medianMs: 100, p90Ms: 100)
        var base = record(medianMs: 100)
        base.scenarios[0].rungs.removeAll()
        base.scenarios[0].rungs.append(rung100)

        let call130 = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 130, outputTokens: 3, returnedToolCalls: false)
        let rep130 = PerfRepetition(index: 0, coldStart: true, wallClockMs: 100, turns: [], modelCalls: [call130], error: nil)
        let rung130 = PerfRungResult(rung: 1, repetitions: [rep130], medianMs: 100, p90Ms: 100)
        var curr = record(medianMs: 100)
        curr.scenarios[0].rungs.removeAll()
        curr.scenarios[0].rungs.append(rung130)

        let c = PerfCompare.compare(baseline: base, current: curr, threshold: 0.2)
        #expect(c.flagged.count == 1)
        #expect(c.flagged.first?.metric == "prompt tokens")
        #expect(c.flagged.first?.rung == 1)
        #expect(c.flagged.first?.change == 0.3)
    }

    @Test("a rung whose current repetitions all failed is flagged instead of scored")
    func currentAllFailed() {
        var baseline = PerfRecordTests.sampleRecord()
        let okRep = baseline.scenarios[0].rungs[0].repetitions[0]
        baseline.scenarios[0].rungs[0].repetitions = (0..<3).map { i in
            var r = okRep; r.index = i; return r
        }

        var failedRep = baseline.scenarios[0].rungs[0].repetitions[0]
        failedRep.error = "Gemini HTTP 429"
        var current = PerfRecordTests.sampleRecord()
        current.scenarios[0].rungs[0].repetitions = (0..<3).map { i in
            var r = failedRep; r.index = i; return r
        }
        current.scenarios[0].rungs[0].medianMs = 0

        let c = PerfCompare.compare(baseline: baseline, current: current, threshold: 0.2)
        let rungRows = c.rows.filter { $0.rung == 5 }
        #expect(rungRows.count == 1)
        #expect(rungRows.first?.metric == "successful repetitions")
        #expect(rungRows.first?.before == 3)
        #expect(rungRows.first?.after == 0)
        #expect(rungRows.first?.flagged == true)
        #expect(!c.rows.contains { $0.metric == "median ms" })
        #expect(PerfCompare.exitCode(c) == 1)
    }

    @Test("a rung that failed on both sides is flagged but does not fail the gate")
    func bothSidesAllFailed() {
        var failedRep = PerfRecordTests.sampleRecord().scenarios[0].rungs[0].repetitions[0]
        failedRep.error = "Gemini HTTP 429"

        var baseline = PerfRecordTests.sampleRecord()
        baseline.scenarios[0].rungs[0].repetitions = [failedRep]
        baseline.scenarios[0].rungs[0].medianMs = 0

        var current = PerfRecordTests.sampleRecord()
        current.scenarios[0].rungs[0].repetitions = [failedRep]
        current.scenarios[0].rungs[0].medianMs = 0

        let c = PerfCompare.compare(baseline: baseline, current: current, threshold: 0.2)
        let rungRows = c.rows.filter { $0.rung == 5 }
        #expect(rungRows.count == 1)
        #expect(rungRows.first?.metric == "successful repetitions")
        #expect(rungRows.first?.flagged == false)
        #expect(PerfCompare.exitCode(c) == 0)
    }
}
