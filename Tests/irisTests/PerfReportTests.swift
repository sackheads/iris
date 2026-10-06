// Tests/irisTests/PerfReportTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfReport")
struct PerfReportTests {
    @Test("report names the suite, sha, provider and each scenario rung")
    func basics() {
        let text = PerfReport.render(PerfRecordTests.sampleRecord())
        #expect(text.contains("# perf: ladder"))
        #expect(text.contains("abc1234"))
        #expect(text.contains("Gemini"))
        #expect(text.contains("capital-city"))
        #expect(text.contains("| 5 |"))
        #expect(text.contains("guard.tier1"))
    }

    @Test("a debug build and a dirty tree are called out")
    func warnings() {
        var r = PerfRecordTests.sampleRecord()
        r.environment.buildConfiguration = "debug"
        r.environment.gitDirty = true
        let text = PerfReport.render(r)
        #expect(text.contains("WARNING: debug build"))
        #expect(text.contains("WARNING: dirty tree"))
        #expect(!PerfReport.render(PerfRecordTests.sampleRecord()).contains("WARNING"))
    }

    @Test("ratios and tool calls are shown when present")
    func ratiosAndTools() {
        var r = PerfRecordTests.sampleRecord()
        r.scenarios[0].summary.overheadRatio = 3.25
        r.scenarios[0].summary.harnessRatio = 1.5
        r.scenarios[0].summary.toolCallsByName = ["run_command": 2]
        r.scenarios[0].summary.toolCallRate = 0.5
        let text = PerfReport.render(r)
        #expect(text.contains("overhead 3.25x"))
        #expect(text.contains("harness 1.50x"))
        #expect(text.contains("run_command: 2"))
        #expect(text.contains("tool-call rate 50%"))
    }

    @Test("failed repetitions are counted")
    func errors() {
        var r = PerfRecordTests.sampleRecord()
        r.scenarios[0].rungs[0].repetitions[0].error = "Gemini HTTP 429"
        #expect(PerfReport.render(r).contains("1 failed"))
    }

    @Test("prompt tokens from ladder-shaped repetitions appear in the rung row")
    func ladderPromptTokens() {
        var r = PerfRecordTests.sampleRecord()
        let call = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: 42, outputTokens: 3, returnedToolCalls: false)
        let rep = PerfRepetition(index: 0, coldStart: true, wallClockMs: 100, turns: [], modelCalls: [call], error: nil)
        let rung = PerfRungResult(rung: 1, repetitions: [rep], medianMs: 100, p90Ms: 100)
        r.scenarios[0].rungs.append(rung)
        let text = PerfReport.render(r)
        // No cache read/write reported: both render as "—" (unknown, not zero) and the whole
        // prompt counts uncached.
        #expect(text.contains("| 1 | 1 | 100.0 | 100.0 | - | 42 | — | — | 42 | 57 | — | - |"))
    }

    @Test("the first-token column is the median over the rung's successful turns, or a dash")
    func firstTokenColumn() throws {
        var r = PerfRecordTests.sampleRecord()
        r.environment.streaming = true
        let call1 = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: nil, outputTokens: nil, returnedToolCalls: false, firstTokenMs: 100)
        let call2 = ModelCallRecord(round: 0, model: "m", latencyMs: 100, promptTokens: nil, outputTokens: nil, returnedToolCalls: false, firstTokenMs: 300)
        let rep1 = PerfRepetition(index: 0, coldStart: true, wallClockMs: 100, turns: [], modelCalls: [call1], error: nil)
        let rep2 = PerfRepetition(index: 1, coldStart: false, wallClockMs: 100, turns: [], modelCalls: [call2], error: nil)
        let streamedRung = PerfRungResult(rung: 4, repetitions: [rep1, rep2], medianMs: 999, p90Ms: 999)
        r.scenarios[0].rungs.append(streamedRung)
        // Rung 5 from sampleRecord() has one modelCall with no firstTokenMs, so its row is "- ".
        let text = PerfReport.render(r)
        #expect(text.contains("| 200 |"))
        #expect(text.contains("| - |"))
        #expect(text.contains("- streaming: on"))
    }

    @Test("top spans come from the highest rung number even when rungs are unsorted")
    func topSpansUseHighestRung() {
        var r = PerfRecordTests.sampleRecord()
        var low = r.scenarios[0].rungs[0]
        low.rung = 1
        low.repetitions[0].turns[0].spans = ["ladder.only": CategoryStat(ms: 999, count: 1)]
        r.scenarios[0].rungs = [r.scenarios[0].rungs[0], low]   // rung 5 first, rung 1 last
        let text = PerfReport.render(r)
        #expect(text.contains("top spans (rung 5"))
        #expect(!text.contains("ladder.only"))
    }

    @Test("the unexpected tool-call rate is shown when scored")
    func unexpectedRateShown() {
        var r = PerfRecordTests.sampleRecord()
        r.scenarios[0].summary.unexpectedToolCallRate = 0.5
        r.scenarios[0].summary.unexpectedToolCallsByName = ["read_file": 1]
        let text = PerfReport.render(r)
        #expect(text.contains("unexpected tool-call rate 50%: read_file: 1"))
        #expect(!PerfReport.render(PerfRecordTests.sampleRecord()).contains("unexpected tool-call rate"))
        r.scenarios[0].summary.missedExpectedToolRate = 1.0
        #expect(PerfReport.render(r).contains("missed expected tool in 100% of turns"))
    }

    @Test("unknown cache read, write and uncached render as an em dash, never a hyphen or zero (spec §0.4)")
    func unknownCacheColumnsUseEmDash() {
        // sampleRecord()'s one call has no cache fields at all.
        let text = PerfReport.render(PerfRecordTests.sampleRecord())
        #expect(text.contains("| 5 | 1 | 860.0 | 860.0 | - | 3000 | — | — | 3000 | 3200 | — | - |"))
        #expect(!text.contains("| 5 | 1 | 860.0 | 860.0 | - | 3000 | - | - | 3000 | 3200 | — | - |"), "a hyphen must not stand in for the cache columns")
    }

    @Test("the rung table carries a median cache write column (spec §0.5)")
    func medianCacheWriteColumn() {
        let text = PerfReport.render(PerfReportCacheTests.cachingRecord())
        #expect(text.contains("| rung | n | median ms | p90 ms | first token ms | prompt tokens | cache read | cache write | uncached | weighted | cost | failed |"))
        // prompt tokens: median([1000,1200,1400,1500]) = 1300. cache read: median([900,1150,1100]) = 1100.
        // cache write: median([250,200,300]) = 250. uncached: median([1000,50,50,100]) = 75.
        // weighted (Anthropic): median([1050, 503, 465, 635]) = 569.
        #expect(text.contains("| 4 | 1 | 400.0 | 400.0 | - | 1300 | 1100 | 250 | 75 | 569 | — | - |"))
    }

    @Test("weighted tokens price each component, and dollars need a base price (5c)")
    func weightedAndCostColumns() throws {
        let call = ModelCallRecord(round: 0, model: "claude-sonnet-5", latencyMs: 1, promptTokens: 20_000,
                                   outputTokens: 500, returnedToolCalls: false,
                                   cacheReadTokens: 19_400, cacheWriteTokens: 400, cacheWrite1hTokens: 100)
        #expect(PerfReport.weightedTokens(call, provider: "Anthropic") == 200 + 1_940 + 375 + 200 + 2_500)
        #expect(PerfReport.dollars(weighted: 1_000_000, basePricePerMTok: 3) == 3)
        #expect(PerfReport.dollars(weighted: 1_000_000, basePricePerMTok: nil) == nil)
    }

    @Test("with a base price the header names it, and the cost cell and per-repetition total are in dollars")
    func costWithBasePrice() {
        var r = PerfReportCacheTests.cachingRecord()
        r.environment.basePricePerMTok = 4
        let text = PerfReport.render(r)
        #expect(text.contains("- cost: weighted × $4.00 / MTok (IRIS_PERF_BASE_PRICE_PER_MTOK)"))
        // 569 weighted × $4 / MTok.
        #expect(text.contains("| 75 | 569 | $0.0023 | - |"))
        // 1050 + 503 + 465 + 635 over the repetition's four rounds.
        #expect(text.contains("- weighted total (rung 4, repetition 1): 2653 ≈ $0.0106"))
        let unpriced = PerfReport.render(PerfReportCacheTests.cachingRecord())
        #expect(unpriced.contains("- weighted total (rung 4, repetition 1): 2653 ≈ —"))
        #expect(!unpriced.contains("- cost:"))
    }

    @Test("IRIS_PERF_BASE_PRICE_PER_MTOK is read when positive and ignored otherwise")
    func basePriceFromEnvironment() {
        #expect(PerfEnvironment.basePrice(from: ["IRIS_PERF_BASE_PRICE_PER_MTOK": "4"]) == 4)
        #expect(PerfEnvironment.basePrice(from: ["IRIS_PERF_BASE_PRICE_PER_MTOK": "2.5"]) == 2.5)
        #expect(PerfEnvironment.basePrice(from: ["IRIS_PERF_BASE_PRICE_PER_MTOK": "free"]) == nil)
        #expect(PerfEnvironment.basePrice(from: ["IRIS_PERF_BASE_PRICE_PER_MTOK": "0"]) == nil)
        #expect(PerfEnvironment.basePrice(from: [:]) == nil)
    }

    @Test("a committed pre-5c baseline still renders, with no price and no 1-hour split")
    func oldRecordsStillRender() throws {
        // From #filePath, never the cwd (invariant 7).
        let baselines = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("perf/baselines")
        let url = baselines.appendingPathComponent("20260918T040234Z-ladder-43ed273.json")
        let record = try PerfRunRecord.decode(from: Data(contentsOf: url))
        #expect(record.environment.basePricePerMTok == nil)
        let text = PerfReport.render(record)
        #expect(text.contains("| weighted | cost | failed |"))
        #expect(!text.contains("- cost:"))
        // Rung rows only: twelve columns (the per-round cache table has seven).
        let rows = text.split(separator: "\n")
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { $0.count == 14 && Int($0[1]) != nil }
        #expect(!rows.isEmpty)
        // Every rung row's cost cell is "—" without a base price.
        for cells in rows { #expect(cells[11] == "—", "cost cell of rung \(cells[1])") }
    }
}
