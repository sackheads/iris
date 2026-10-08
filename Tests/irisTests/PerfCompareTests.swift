// Tests/irisTests/PerfCompareTests.swift
import Testing
import Foundation
@testable import IrisKit

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
        let slow = PerfCompare.compare(baseline: record(medianMs: 1000), current: record(medianMs: 1250), threshold: 0.2)
        #expect(slow.flagged.count == 1)
        #expect(slow.flagged.first?.metric == "median ms")
        #expect(slow.flagged.first?.rung == 5)
        #expect(PerfCompare.exitCode(slow) == 1)
        let fine = PerfCompare.compare(baseline: record(medianMs: 1000), current: record(medianMs: 1100), threshold: 0.2)
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
        let c = PerfCompare.compare(baseline: record(medianMs: 1000), current: record(medianMs: 1250), threshold: 0.2)
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

    @Test("a large relative change on a tiny absolute delta is not a regression")
    func noiseFloor() {
        // 2 ms -> 3 ms is +50% but below the absolute floor: fake-lane smoke runs live here.
        let tiny = PerfCompare.compare(baseline: record(medianMs: 2), current: record(medianMs: 3), threshold: 0.2)
        #expect(tiny.flagged.isEmpty)
        #expect(tiny.rows.first?.change == 0.5, "the change is still reported, just not flagged")
        #expect(PerfCompare.minFlaggedDeltaMs == 50)
        // Just over the floor and over the threshold: flagged.
        let real = PerfCompare.compare(baseline: record(medianMs: 200), current: record(medianMs: 260), threshold: 0.2)
        #expect(real.flagged.count == 1)
    }

    @Test("records with different tool sandbox modes are not comparable")
    func sandboxModeMismatch() {
        var host = record(medianMs: 1000); host.environment.toolSandbox = "host"
        var boxed = record(medianMs: 1000); boxed.environment.toolSandbox = "sandboxed"
        let c = PerfCompare.compare(baseline: host, current: boxed, threshold: 0.2)
        #expect(c.refusal?.contains("sandbox") == true)
        #expect(PerfCompare.exitCode(c) == 2)
        let legacy = PerfCompare.compare(baseline: record(medianMs: 1000), current: record(medianMs: 1000), threshold: 0.2)
        #expect(legacy.refusal == nil, "records that predate the field still compare")
    }

    @Test("a streaming flag mismatch is not a refusal")
    func streamingMismatchCompares() {
        var baseline = record(medianMs: 1000)
        var current = record(medianMs: 1000)
        baseline.environment.streaming = nil
        current.environment.streaming = true
        let comparison = PerfCompare.compare(baseline: baseline, current: current, threshold: 0.2)
        #expect(comparison.refusal == nil)
    }

    private func rung(_ calls: [ModelCallRecord], rung: Int = 1) -> PerfRungResult {
        let rep = PerfRepetition(index: 0, coldStart: true, wallClockMs: 100, turns: [], modelCalls: calls, error: nil)
        return PerfRungResult(rung: rung, repetitions: [rep], medianMs: 100, p90Ms: 100)
    }

    /// Across 5a, Anthropic prompt tokens jump because they now include cache reads/writes. Once
    /// both records are marked `cacheCountsVersion` (recorded by this build), both rows are
    /// emitted: "prompt tokens" is still the flagging size metric the gate exists for, "uncached
    /// prompt tokens" is informational only (5a review F1).
    @Test("when both records carry cache counts, both prompt-token rows are emitted; only 'prompt tokens' can flag")
    func bothRowsEmittedWhenBothRecordsCarryCacheCounts() {
        let baseCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 1000, outputTokens: 3,
                                       returnedToolCalls: false, cacheReadTokens: 900, cacheWriteTokens: 0)
        var base = record(medianMs: 100)
        base.scenarios[0].rungs = [rung([baseCall])]
        base.cacheCountsVersion = 1

        let currCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 1200, outputTokens: 3,
                                       returnedToolCalls: false, cacheReadTokens: 1050, cacheWriteTokens: 0)
        var curr = record(medianMs: 100)
        curr.scenarios[0].rungs = [rung([currCall])]
        curr.cacheCountsVersion = 1

        let c = PerfCompare.compare(baseline: base, current: curr, threshold: 0.2)
        let uncached = c.rows.first { $0.metric == "uncached prompt tokens" }
        #expect(uncached?.before == 100, "1000 prompt - 900 read - 0 write")
        #expect(uncached?.after == 150, "1200 prompt - 1050 read - 0 write")
        let prompt = c.rows.first { $0.metric == "prompt tokens" }
        #expect(prompt?.before == 1000 && prompt?.after == 1200)
        #expect(c.notes.isEmpty)
    }

    /// F1's two consequences, named directly: a size regression inside the cached prefix must
    /// still flag on "prompt tokens" even though "uncached prompt tokens" doesn't move, and a
    /// cache-warmth swing (cold vs warm TTL) on "uncached prompt tokens" must never flag by
    /// itself.
    @Test("prompt tokens flags on a real size regression; uncached tokens never flags on its own")
    func promptTokensFlagsUncachedNeverDoes() {
        // Identical prompt tokens, uncached swings 2k -> 60k (cache cold vs warm): must not flag.
        let baseCold = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 60000, outputTokens: 3,
                                       returnedToolCalls: false, cacheReadTokens: 0, cacheWriteTokens: 0)
        var base1 = record(medianMs: 100)
        base1.scenarios[0].rungs = [rung([baseCold])]
        base1.cacheCountsVersion = 1

        let currWarm = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 60000, outputTokens: 3,
                                       returnedToolCalls: false, cacheReadTokens: 58000, cacheWriteTokens: 0)
        var curr1 = record(medianMs: 100)
        curr1.scenarios[0].rungs = [rung([currWarm])]
        curr1.cacheCountsVersion = 1

        let c1 = PerfCompare.compare(baseline: base1, current: curr1, threshold: 0.2)
        #expect(c1.flagged.isEmpty, "prompt tokens unchanged, uncached swings only with cache warmth")

        // Prompt tokens +25%, uncached unchanged: must flag on "prompt tokens".
        let baseSmall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 1000, outputTokens: 3,
                                        returnedToolCalls: false, cacheReadTokens: 900, cacheWriteTokens: 0)
        var base2 = record(medianMs: 100)
        base2.scenarios[0].rungs = [rung([baseSmall])]
        base2.cacheCountsVersion = 1

        let currBig = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 1250, outputTokens: 3,
                                      returnedToolCalls: false, cacheReadTokens: 1150, cacheWriteTokens: 0)
        var curr2 = record(medianMs: 100)
        curr2.scenarios[0].rungs = [rung([currBig])]
        curr2.cacheCountsVersion = 1

        let c2 = PerfCompare.compare(baseline: base2, current: curr2, threshold: 0.2)
        #expect(c2.flagged.map(\.metric) == ["prompt tokens"], "uncached tokens are unchanged (100 both sides) and must not flag")
    }

    /// F2: the discriminator is the record-level `cacheCountsVersion` marker written by this
    /// build, not per-call nil-ness. Two post-5a records whose calls all happen to have nil cache
    /// fields (a Gemini run with no implicit-cache hit) must not straddle.
    @Test("two post-5a records with all-nil per-call cache fields do not straddle (5a review F2)")
    func postFiveARecordsWithNilCacheFieldsDoNotStraddle() {
        let baseCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 100, outputTokens: 3, returnedToolCalls: false)
        var base = record(medianMs: 100)
        base.scenarios[0].rungs = [rung([baseCall])]
        base.cacheCountsVersion = 1

        let currCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 130, outputTokens: 3, returnedToolCalls: false)
        var curr = record(medianMs: 100)
        curr.scenarios[0].rungs = [rung([currCall])]
        curr.cacheCountsVersion = 1

        let c = PerfCompare.compare(baseline: base, current: curr, threshold: 0.2)
        #expect(c.notes.isEmpty, "both sides are post-5a (marked), even though neither call reports a cache field")
        // Both sides lack cache fields entirely, so uncached == prompt; the uncached row still
        // appears because both records are marked.
        #expect(c.rows.contains { $0.metric == "prompt tokens" })
        #expect(c.rows.contains { $0.metric == "uncached prompt tokens" })
    }

    /// F2/F3: when only one side carries the marker, the records straddle the cache-count
    /// change. Comparing uncached tokens would compare a real figure against one invented by
    /// treating an unknown read as zero, so fall back to raw prompt tokens — but that row must
    /// stay informational (F3): a straddled compare must not fail its own gate on the jump it
    /// just explained.
    @Test("one marked, one unmarked record straddles: prompt tokens falls back, is informational, and the gate stays green")
    func straddleFallsBackAndStaysInformational() {
        let baseCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 100, outputTokens: 3, returnedToolCalls: false)
        var base = record(medianMs: 100)
        base.scenarios[0].rungs = [rung([baseCall])]
        base.cacheCountsVersion = nil // pre-5a

        // A 40% prompt jump that the straddle note explains, not a real regression.
        let currCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 140, outputTokens: 3,
                                       returnedToolCalls: false, cacheReadTokens: 20, cacheWriteTokens: 0)
        var curr = record(medianMs: 100)
        curr.scenarios[0].rungs = [rung([currCall])]
        curr.cacheCountsVersion = 1

        let c = PerfCompare.compare(baseline: base, current: curr, threshold: 0.2)
        let row = c.rows.first { $0.metric == "prompt tokens" }
        #expect(row != nil)
        #expect(row?.before == 100 && row?.after == 140)
        #expect(row?.flagged == false, "a straddled compare must not fail the gate on the jump it just explained")
        #expect(!c.rows.contains { $0.metric == "uncached prompt tokens" })
        #expect(!c.notes.isEmpty)
        #expect(c.notes.contains { $0.contains("cache") })
        #expect(PerfCompare.render(c, threshold: 0.2).contains("cache"), "the note reaches the rendered report")
        #expect(PerfCompare.exitCode(c) == 0, "the straddle note explains the only row that moved; the gate must not fail on it")
    }

    /// The tool-list experiment changes what is sent, so a pair where only one side ran it is not
    /// like-for-like on prompt size. Compare still runs (the latency rows are valid), but says so
    /// and keeps the prompt-token row from failing the gate (5a final review item 3).
    @Test("records that differ in the tool-list experiment get a note and an informational prompt-token row")
    func experimentMismatchIsNotedAndInformational() {
        let baseCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 1000, outputTokens: 3,
                                       returnedToolCalls: false, cacheReadTokens: 0, cacheWriteTokens: 0)
        var base = record(medianMs: 100)
        base.scenarios[0].rungs = [rung([baseCall])]
        base.cacheCountsVersion = 1

        let currCall = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 1400, outputTokens: 3,
                                       returnedToolCalls: false, cacheReadTokens: 0, cacheWriteTokens: 0)
        var curr = record(medianMs: 100)
        curr.scenarios[0].rungs = [rung([currCall])]
        curr.cacheCountsVersion = 1
        curr.environment.stateGatedToolsAlwaysDeclared = true

        let c = PerfCompare.compare(baseline: base, current: curr, threshold: 0.2)
        #expect(c.refusal == nil, "a note, not a refusal")
        let prompt = c.rows.first { $0.metric == "prompt tokens" }
        #expect(prompt?.before == 1000 && prompt?.after == 1400)
        #expect(prompt?.flagged == false)
        #expect(c.notes.contains { $0.contains("IRIS_PERF_DECLARE_STATE_TOOLS") })
        #expect(PerfCompare.render(c, threshold: 0.2).contains("IRIS_PERF_DECLARE_STATE_TOOLS"))
        #expect(PerfCompare.exitCode(c) == 0)

        // Same setting on both sides (true/true): no note, and the row flags as usual.
        var base2 = base
        base2.environment.stateGatedToolsAlwaysDeclared = true
        let c2 = PerfCompare.compare(baseline: base2, current: curr, threshold: 0.2)
        #expect(c2.notes.isEmpty)
        #expect(c2.flagged.map(\.metric) == ["prompt tokens"])
    }
}
