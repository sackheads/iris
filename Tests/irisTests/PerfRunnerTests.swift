import Testing
import Foundation
@testable import iris

@MainActor
@Suite("PerfRunner")
struct PerfRunnerTests {
    private let root = PerfPaths.repoRoot()

    @Test("a fake suite yields one scenario result per scenario with turns, tool calls and nil tokens")
    func fakeSuite() async throws {
        let suite = PerfSuite(name: "smoke-test", lane: .fake, repetitions: 2, rungs: [5],
                              scenarios: ["perf/prompts/fake/text-only.json", "perf/prompts/fake/one-command.json"])
        let record = try await PerfRunner.run(suite: suite, repoRoot: root, headless: true)
        #expect(record.suite == "smoke-test")
        #expect(record.scenarios.map(\.name) == ["fake-text-only", "fake-one-command"])
        #expect(record.scenarios.map(\.category) == ["fake", "fake"])
        let cmd = try #require(record.scenarios.last)
        #expect(cmd.rungs.first?.repetitions.count == 2)
        // Cold-start counting is process-global by design; another PerfRunner test may run first
        // in the same process, so only the "later reps are never cold" half is deterministic here.
        #expect(cmd.rungs.first?.repetitions.dropFirst().allSatisfy { !$0.coldStart } == true)
        #expect(cmd.summary.toolCallsByName["run_command"] == 2)
        #expect(cmd.summary.toolCallRate == 1.0)
        #expect(cmd.rungs.first?.repetitions.first?.turns.first?.modelCalls.allSatisfy { $0.promptTokens == nil } == true)
        #expect(record.environment.headless == true)
        #expect(record.environment.toolSandbox == "host", "the fake lane never sandboxes")
        #expect(record.scenarios.first?.rungs.first?.repetitions.first?.turns.first?.finalText == "Canberra.")
    }

    @Test("a real-lane suite with an injected client runs the ladder rungs and computes ratios")
    func ladderWithInjectedClient() async throws {
        let usage = UsageMetadata(promptTokenCount: 10, candidatesTokenCount: 2, totalTokenCount: 12)
        let text = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "Canberra.", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: usage)
        // A zero-latency call can measure exactly 0.0 ms at CFAbsoluteTime resolution, which
        // PerfSummarizer maps to nil ratios by design; force a non-zero rung-1 median instead.
        let client = FakeLLMClient(responses: [text], latency: .init(minMs: 1, maxMs: 1))
        let suite = PerfSuite(name: "ladder-test", lane: .real, repetitions: 1, rungs: [1, 2, 3, 4, 5],
                              scenarios: ["perf/prompts/fake/text-only.json"])
        let record = try await PerfRunner.run(suite: suite, repoRoot: root, client: client, headless: false)
        let s = try #require(record.scenarios.first)
        #expect(s.rungs.map(\.rung) == [1, 2, 3, 4, 5])
        #expect(s.rungs[0].repetitions.first?.modelCalls.first?.promptTokens == 10)
        #expect(s.rungs[4].repetitions.first?.turns.count == 1)
        #expect(s.summary.overheadRatio != nil)
        #expect(s.summary.harnessRatio != nil)
        #expect((record.environment.toolDeclarationCount ?? 0) > 10)
    }

    @Test("repetitions override wins over the suite file")
    func repetitionsOverride() async throws {
        let suite = PerfSuite(name: "o", lane: .fake, repetitions: 5, scenarios: ["perf/prompts/fake/text-only.json"])
        let record = try await PerfRunner.run(suite: suite, repetitionsOverride: 1, repoRoot: root, headless: true)
        #expect(record.scenarios.first?.rungs.first?.repetitions.count == 1)
    }

    @Test("a missing scenario file is a thrown error")
    func missingScenario() async {
        let suite = PerfSuite(name: "m", scenarios: ["perf/prompts/fake/does-not-exist.json"])
        await #expect(throws: (any Error).self) { try await PerfRunner.run(suite: suite, repoRoot: root, headless: true) }
    }

    /// The engine catches provider failures and posts a tagged system message instead of
    /// throwing, so `ScenarioResult.turnProfiles` is never empty for one. `PerfRunner` must read
    /// `turnErrors` (not emptiness of `turnProfiles`) to mark the repetition failed.
    private struct AlwaysFails: LLMClientProtocol {
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            throw APIError.http(provider: "Gemini", statusCode: 401,
                                body: Data(#"{"error":{"code":401,"message":"Bad credentials.","status":"UNAUTHENTICATED"}}"#.utf8))
        }
    }

    @Test("an engine-level failure marks the repetition failed and drops it from the medians")
    func engineLevelFailureFailsRepetition() async throws {
        let suite = PerfSuite(name: "fails", lane: .real, repetitions: 1, rungs: [5],
                              scenarios: ["perf/prompts/fake/text-only.json"])
        let record = try await PerfRunner.run(suite: suite, repoRoot: root, client: AlwaysFails(), headless: true)
        let s = try #require(record.scenarios.first)
        let error = try #require(s.rungs.first?.repetitions.first?.error)
        #expect(error.contains("401"))
        #expect(s.rungs.first?.medianMs == 0)
        #expect(s.summary.medianMs == 0)
    }
}

@Suite("PerfSummarizer")
struct PerfSummarizerTests {
    private func rung(_ n: Int, _ ms: [Double], tools: [[String]] = []) -> PerfRungResult {
        let reps = ms.enumerated().map { i, v in
            let turn = PerfTurn(totalMs: v, categories: [:], spans: [:], modelCalls: [],
                                toolCalls: (i < tools.count ? tools[i] : []).map { ToolCallRecord(name: $0, ms: 1, ok: true) },
                                finalTextLength: 0)
            return PerfRepetition(index: i, coldStart: i == 0, wallClockMs: v, turns: n >= 4 ? [turn] : [],
                                  modelCalls: n < 4 ? [ModelCallRecord(round: 0, model: "m", latencyMs: v, promptTokens: nil, outputTokens: nil, returnedToolCalls: false)] : [],
                                  error: nil)
        }
        return PerfRungResult(rung: n, repetitions: reps, medianMs: PerfStats.median(ms) ?? 0, p90Ms: PerfStats.p90(ms) ?? 0)
    }

    @Test("ratios divide rung 5 and rung 4 medians by the rung 1 median")
    func ratios() {
        let s = PerfSummarizer.summarize([rung(1, [100, 110, 120]), rung(4, [200, 220, 240]), rung(5, [300, 330, 360])])
        #expect(s.overheadRatio == 3.0)
        #expect(s.harnessRatio == 2.0)
        #expect(s.medianMs == 330)
    }

    @Test("without rung 1 the ratios are nil and the summary uses the highest rung")
    func noDenominator() {
        let s = PerfSummarizer.summarize([rung(5, [300, 330, 360])])
        #expect(s.overheadRatio == nil)
        #expect(s.harnessRatio == nil)
        #expect(s.p90Ms == 360)
    }

    @Test("tool call rate and histogram come from rung-5 turns")
    func toolCalls() {
        let s = PerfSummarizer.summarize([rung(5, [1, 2, 3, 4], tools: [["run_command"], [], ["run_command", "read_file"], []])])
        #expect(s.toolCallRate == 0.5)
        #expect(s.toolCallsByName == ["run_command": 2, "read_file": 1])
    }

    @Test("failed repetitions are excluded from medians")
    func failuresExcluded() {
        var r = rung(5, [100, 900])
        r.repetitions[1].error = "HTTP 429"
        let s = PerfSummarizer.summarize([r])
        #expect(s.medianMs == 100)
    }

    @Test("tool-call rate and histogram ignore failed repetitions (#137)")
    func failedRepetitionsExcludedFromEagerness() {
        var r = rung(5, [1, 2], tools: [["run_command"], ["run_command", "read_file"]])
        r.repetitions[1].error = "request timed out after 180 s"
        let s = PerfSummarizer.summarize([r])
        #expect(s.toolCallRate == 1.0)
        #expect(s.toolCallsByName == ["run_command": 1])
    }

    @Test("unexpected tool-call rate scores calls outside expectedTools")
    func unexpectedToolCalls() {
        // Bait: nothing expected, one turn called something -> 1/2.
        let bait = PerfSummarizer.summarize([rung(5, [1, 2], tools: [["set_workspace"], []])], expectedTools: [])
        #expect(bait.unexpectedToolCallRate == 0.5)
        #expect(bait.unexpectedToolCallsByName == ["set_workspace": 1])
        // Control with extras: the expected tool plus a read_file -> unexpected.
        let extras = PerfSummarizer.summarize([rung(5, [1, 2], tools: [["set_workspace", "read_file"], ["set_workspace"]])], expectedTools: ["set_workspace"])
        #expect(extras.unexpectedToolCallRate == 0.5)
        #expect(extras.unexpectedToolCallsByName == ["read_file": 1])
        #expect(extras.toolCallRate == 1.0, "the plain rate is unchanged")
        // Controls can also miss the tool they exist to exercise: 1 of 2 turns called nothing relevant.
        let missed = PerfSummarizer.summarize([rung(5, [1, 2], tools: [["schedule_job"], ["run_command"]])], expectedTools: ["schedule_job"])
        #expect(missed.missedExpectedToolRate == 0.5)
        #expect(bait.missedExpectedToolRate == nil, "a bait prompt expects nothing, so nothing can be missed")
        // Unscored scenario: no expectation, no score.
        let unscored = PerfSummarizer.summarize([rung(5, [1], tools: [["run_command"]])])
        #expect(unscored.unexpectedToolCallRate == nil)
        #expect(unscored.unexpectedToolCallsByName == nil)
        #expect(unscored.missedExpectedToolRate == nil)
    }
}
