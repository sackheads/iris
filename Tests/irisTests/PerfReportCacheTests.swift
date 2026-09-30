// Tests/irisTests/PerfReportCacheTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfReport cache table (5a)")
struct PerfReportCacheTests {
    /// A rung-4 repetition of 3 turns: turn 1 has one round, turn 2 has two rounds (the second
    /// hits cache), turn 3 has one round. Matches the task-3 brief fixture verbatim.
    static func cachingRecord() -> PerfRunRecord {
        let env = PerfEnvironment(gitSha: "abc1234", gitDirty: false, machineModel: "Mac16,7", osVersion: "26.0",
                                  cpuCount: 12, buildConfiguration: "release", provider: "Anthropic",
                                  models: ["medium": "claude"], vibecopEnabled: false, vibecopEngine: "cloud",
                                  injectionGuardEnabled: false, promptGuardEngine: "cloud", sandboxEnabled: false,
                                  headless: false)

        let turn1 = PerfTurn(totalMs: 100, categories: [:], spans: [:],
                             modelCalls: [ModelCallRecord(round: 0, model: "claude", latencyMs: 100,
                                                          promptTokens: 1000, outputTokens: 10, returnedToolCalls: false)],
                             toolCalls: [], finalTextLength: 5)
        let turn2 = PerfTurn(totalMs: 200, categories: [:], spans: [:],
                             modelCalls: [
                                ModelCallRecord(round: 0, model: "claude", latencyMs: 100, promptTokens: 1200,
                                               outputTokens: 10, returnedToolCalls: true,
                                               cacheReadTokens: 900, cacheWriteTokens: 250),
                                ModelCallRecord(round: 1, model: "claude", latencyMs: 100, promptTokens: 1400,
                                               outputTokens: 10, returnedToolCalls: false,
                                               cacheReadTokens: 1150, cacheWriteTokens: 200)
                             ], toolCalls: [], finalTextLength: 5)
        let turn3 = PerfTurn(totalMs: 100, categories: [:], spans: [:],
                             modelCalls: [ModelCallRecord(round: 0, model: "claude", latencyMs: 100, promptTokens: 1500,
                                                          outputTokens: 10, returnedToolCalls: false,
                                                          cacheReadTokens: 1100, cacheWriteTokens: 300)],
                             toolCalls: [], finalTextLength: 5)

        let rep = PerfRepetition(index: 0, coldStart: true, wallClockMs: 400, turns: [turn1, turn2, turn3], modelCalls: [], error: nil)
        let rung = PerfRungResult(rung: 4, repetitions: [rep], medianMs: 400, p90Ms: 400)
        let summary = PerfScenarioSummary(medianMs: 400, p90Ms: 400, overheadRatio: nil, harnessRatio: nil, toolCallRate: 0, toolCallsByName: [:])
        let scenario = PerfScenarioResult(name: "six-turns", path: "perf/prompts/caching/six-turns.json", category: "caching",
                                          lane: "real", rungs: [rung], summary: summary)
        return PerfRunRecord(schemaVersion: 1, suite: "caching", startedAt: Date(timeIntervalSince1970: 1_000),
                             finishedAt: Date(timeIntervalSince1970: 1_400), environment: env, scenarios: [scenario])
    }

    @Test("the report carries a per-round cache table for a multi-turn scenario")
    func perRoundCacheTable() {
        let text = PerfReport.render(Self.cachingRecord())
        #expect(text.contains("| turn | round | prompt | cache read | cache write | uncached |"))
        // An unknown cache read (fake/older records) counts as fully uncached, shown as "—".
        #expect(text.contains("| 1 | 0 | 1000 | — | — | 1000 |"))
        // uncached = prompt - read - write.
        #expect(text.contains("| 2 | 1 | 1400 | 1150 | 200 | 50 |"))
    }

    @Test("cacheTable is empty for a scenario with no per-turn model calls")
    func emptyWhenNoTurns() {
        let call = ModelCallRecord(round: 0, model: "m", latencyMs: 1, promptTokens: 1, outputTokens: 1, returnedToolCalls: false)
        let rep = PerfRepetition(index: 0, coldStart: true, wallClockMs: 1, turns: [], modelCalls: [call], error: nil)
        let rung = PerfRungResult(rung: 1, repetitions: [rep], medianMs: 1, p90Ms: 1)
        let summary = PerfScenarioSummary(medianMs: 1, p90Ms: 1, overheadRatio: nil, harnessRatio: nil, toolCallRate: 0, toolCallsByName: [:])
        let scenario = PerfScenarioResult(name: "bare", path: "p", category: "c", lane: "real", rungs: [rung], summary: summary)
        #expect(PerfReport.cacheTable(scenario).isEmpty)
    }

    @Test("only the first repetition is rendered, not a table per repetition")
    func onlyFirstRepetition() {
        var record = Self.cachingRecord()
        // A second repetition with a wildly different prompt count would show up if the table
        // were built from every repetition instead of just the first.
        let extraCall = ModelCallRecord(round: 0, model: "claude", latencyMs: 1, promptTokens: 99999,
                                        outputTokens: 1, returnedToolCalls: false)
        let extraTurn = PerfTurn(totalMs: 1, categories: [:], spans: [:], modelCalls: [extraCall], toolCalls: [], finalTextLength: 1)
        let extraRep = PerfRepetition(index: 1, coldStart: false, wallClockMs: 1, turns: [extraTurn], modelCalls: [], error: nil)
        record.scenarios[0].rungs[0].repetitions.append(extraRep)
        let text = PerfReport.render(record)
        #expect(!text.contains("99999"))
    }

    @Test("seedFacts decodes and defaults to nil")
    func seedFactsDecoding() throws {
        let withFacts = try Scenario.decode(from: Data(#"{"name":"n","turns":[{"prompt":"p"}],"seedFacts":["a","b"]}"#.utf8))
        #expect(withFacts.seedFacts == ["a", "b"])
        let withoutFacts = try Scenario.decode(from: Data(#"{"name":"n","turns":[{"prompt":"p"}]}"#.utf8))
        #expect(withoutFacts.seedFacts == nil)
    }
}
