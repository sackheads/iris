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
        #expect(text.contains("| 1 | 1 | 100.0 | 100.0 | 42 | - |"))
    }
}
