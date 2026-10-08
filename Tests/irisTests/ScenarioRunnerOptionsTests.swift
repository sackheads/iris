// Tests/irisTests/ScenarioRunnerOptionsTests.swift
import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("ScenarioRunner options")
struct ScenarioRunnerOptionsTests {
    private var textOnly: Scenario {
        Scenario(name: "text", clientMode: .fake,
                 turns: [Scenario.Turn(prompt: "one"), Scenario.Turn(prompt: "two")],
                 scriptedResponses: [
                    Scenario.ScriptedResponse(kind: .text, text: "ack one", calls: nil),
                    Scenario.ScriptedResponse(kind: .text, text: "ack two", calls: nil)
                 ])
    }

    @Test("the final agent text of each turn is returned")
    func finalTexts() async {
        let result = await ScenarioRunner.run(textOnly)
        #expect(result.finalTexts == ["ack one", "ack two"])
    }

    @Test("guards=off is ignored outside a volatile settings copy")
    func guardsOffIsGatedOnVolatileCopy() async {
        let before = (ConfigManager.shared.enableVibecop, ConfigManager.shared.enableAdvancedPromptInjectionProtection)
        let result = await ScenarioRunner.run(textOnly, guards: .off)
        let after = (ConfigManager.shared.enableVibecop, ConfigManager.shared.enableAdvancedPromptInjectionProtection)
        #expect(result.guardsWereOff == false)
        #expect(before == after, "a test process must never see its config mutated")
    }

    @Test("a client override receives exactly what a real turn would send")
    func clientOverrideCapturesRequest() async throws {
        let capture = CapturingLLMClient(reply: "captured")
        let result = await ScenarioRunner.run(textOnly, clientOverride: capture)
        #expect(result.finalTexts == ["captured", "captured"])
        let request = try #require(capture.requests.first)
        #expect(request.systemInstruction?.parts.first?.text?.isEmpty == false)
        #expect((request.tools?.first?.functionDeclarations.count ?? 0) > 10)
    }

    /// The engine catches provider failures and posts a `[LLM_ERROR]`-tagged system message
    /// instead of throwing, so a failed turn still yields a `CommandProfile`. 401 is not retried
    /// (unlike 429/503/529), so the pill lands immediately instead of after the engine's backoff.
    private struct AlwaysFails: LLMClientProtocol {
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            throw APIError.http(provider: "Gemini", statusCode: 401,
                                body: Data(#"{"error":{"code":401,"message":"Bad credentials.","status":"UNAUTHENTICATED"}}"#.utf8))
        }
    }

    private var singleTurn: Scenario {
        Scenario(name: "single", clientMode: .fake, turns: [Scenario.Turn(prompt: "hi")],
                 scriptedResponses: [Scenario.ScriptedResponse(kind: .text, text: "ack", calls: nil)])
    }

    @Test("an engine-level LLM failure is surfaced per turn")
    func engineLevelFailureSurfaced() async {
        let result = await ScenarioRunner.run(singleTurn, clientOverride: AlwaysFails())
        #expect(result.turnErrors == ["Gemini HTTP 401 UNAUTHENTICATED: Bad credentials."])
        // The failing turn posts only a system pill, no agent text.
        #expect(result.finalTexts == [""])

        let happy = await ScenarioRunner.run(textOnly)
        #expect(happy.turnErrors == [nil, nil])
    }

    /// Text on turn one, a non-retryable failure on turn two.
    private final class TextThenFail: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let n: Int = lock.withLock { calls += 1; return calls }
            if n > 1 {
                throw APIError.http(provider: "Gemini", statusCode: 401, body: Data(#"{"error":{"code":401,"message":"Bad credentials.","status":"UNAUTHENTICATED"}}"#.utf8))
            }
            let part = Part(text: "first answer", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
    }

    @Test("a turn with no agent text does not inherit the previous turn's text")
    func finalTextsDoNotBleedAcrossTurns() async {
        let result = await ScenarioRunner.run(textOnly, clientOverride: TextThenFail())
        #expect(result.finalTexts == ["first answer", ""])
        #expect(result.turnErrors[0] == nil && result.turnErrors[1] != nil)
    }

    @Test("a run ends its conversation's sandbox session so headless runs do not leak VMs")
    func sandboxSessionEnded() async {
        let result = await ScenarioRunner.run(textOnly)
        let live = await SandboxSessionManager.shared.hasSession(result.conversationId)
        #expect(live == false)
    }

    @Test("toolExecution: .sandboxed is ignored outside a volatile settings copy")
    func sandboxedToolsGatedOnVolatileCopy() async {
        let before = ConfigManager.shared.mainAgentSandboxDefault
        let result = await ScenarioRunner.run(textOnly, toolExecution: .sandboxed)
        #expect(result.toolsSandboxed == false)
        #expect(ConfigManager.shared.mainAgentSandboxDefault == before, "a test process must never see its config mutated")
        let plain = await ScenarioRunner.run(textOnly)
        #expect(plain.toolsSandboxed == false)
    }

    @Test("a run can bind its throwaway conversation to a workspace (#151)")
    func workspaceBinding() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = "WORKSPACE-RULE-\(UUID().uuidString)"
        try "# Rules\n\(marker)\n".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let capture = CapturingLLMClient(reply: "ok")
        _ = await ScenarioRunner.run(textOnly, clientOverride: capture, workspacePath: dir.path)
        // The body is sanitized through tier 3, which a bare test process fails closed on, so
        // assert the section the engine appends whenever the bound workspace has an AGENTS.md.
        let header = "# Project Workspace Rules (AGENTS.md)"
        let system = capture.requests.first?.systemInstruction?.parts.first?.text ?? ""
        #expect(system.contains(header), "AGENTS.md from the bound workspace is part of the request")
        _ = marker
        let unbound = CapturingLLMClient(reply: "ok")
        _ = await ScenarioRunner.run(textOnly, clientOverride: unbound)
        #expect(unbound.requests.first?.systemInstruction?.parts.first?.text?.contains(header) == false)
    }

    /// Never seeds `.shared`, the process-global store: under FTS5 any-token matching, a fact
    /// seeded there would linger for and pollute every other scenario/test sharing this process
    /// (invariant 7's "fails in company" shape; 5a fix round 2, review finding #1). The scenario's
    /// own store is injected so this test can inspect exactly what was seeded, in isolation.
    @Test("seedFacts are written to the injected fact store before turn 1, never .shared (5a)")
    func seedFactsSeedBeforeFirstTurn() async throws {
        let marker = "PERFSEED\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let scenario = Scenario(name: "seeded", clientMode: .fake,
                                turns: [Scenario.Turn(prompt: "one")],
                                scriptedResponses: [Scenario.ScriptedResponse(kind: .text, text: "ack", calls: nil)],
                                seedFacts: ["The \(marker) codename ships on Thursdays."])
        let store = try FactStoreManager(inMemory: true)
        _ = await ScenarioRunner.run(scenario, factStore: store)
        let found = try store.search(query: marker, countsAsRetrieval: false)
        #expect(found.contains { $0.content.contains(marker) })
        let leaked = try FactStoreManager.shared.search(query: marker, countsAsRetrieval: false)
        #expect(leaked.isEmpty, "seeding must never reach the process-global store")
    }

    /// A scenario with `seedFacts` and no injected store must still not touch `.shared`: it mints
    /// its own fresh in-memory store per run (5a fix round 2, review finding #2b/2a).
    @Test("seedFacts with no injected store still avoid .shared")
    func seedFactsWithoutInjectedStoreAvoidsShared() async throws {
        let marker = "PERFSEED\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let scenario = Scenario(name: "seeded-default", clientMode: .fake,
                                turns: [Scenario.Turn(prompt: "one")],
                                scriptedResponses: [Scenario.ScriptedResponse(kind: .text, text: "ack", calls: nil)],
                                seedFacts: ["The \(marker) codename ships on Thursdays."])
        _ = await ScenarioRunner.run(scenario)
        let leaked = try FactStoreManager.shared.search(query: marker, countsAsRetrieval: false)
        #expect(leaked.isEmpty, "seeding must never reach the process-global store, even with no injected store")
    }

    @Test("a seeding failure (e.g. empty content) is ignored, not thrown")
    func seedFactsIgnoresErrors() async {
        let scenario = Scenario(name: "seeded-empty", clientMode: .fake,
                                turns: [Scenario.Turn(prompt: "one")],
                                scriptedResponses: [Scenario.ScriptedResponse(kind: .text, text: "ack", calls: nil)],
                                seedFacts: [""])
        let result = await ScenarioRunner.run(scenario)
        #expect(result.finalTexts == ["ack"])
    }

    @Test("--dump-requests writes one valid-JSON file per round, named <turn>-<round>.json (5a)")
    func dumpRequestsWritesOneFilePerRound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-dump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await ScenarioRunner.run(textOnly, dumpRequestsTo: dir)
        #expect(result.finalTexts == ["ack one", "ack two"])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["1-0.json", "2-0.json"])
        for name in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let parsed = try JSONSerialization.jsonObject(with: data)
            #expect(parsed is [String: Any], "\(name) is valid JSON")
        }
    }

    /// Fails once with a retryable error, then succeeds. Used to prove dumped files pair 1:1 with
    /// `ModelCallRecord.round` even across a retry (5a review F4): the engine's retry resends the
    /// same round, not a new one, so the retried request must not shift round 1's dump to a
    /// different number.
    private final class FailsOnceThenSucceeds: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let n: Int = lock.withLock { calls += 1; return calls }
            if n == 1 {
                throw APIError.http(provider: "Anthropic", statusCode: 529,
                                    body: Data(#"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
            }
            let part = Part(text: "ack", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
    }

    @Test("a retried round dumps <turn>-<round>.json and <turn>-<round>-retry1.json, both at round 0 (5a review F4)")
    func dumpRequestsNameRetriesExplicitly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-dump-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let singleTurnScenario = Scenario(name: "single", clientMode: .fake, turns: [Scenario.Turn(prompt: "hi")])
        let result = await ScenarioRunner.run(singleTurnScenario, clientOverride: FailsOnceThenSucceeds(),
                                              dumpRequestsTo: dir, retryDelays: [0])
        #expect(result.finalTexts == ["ack"])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["1-0-retry1.json", "1-0.json"], "both the failed attempt and the retry pair with round 0")
        // The round that actually got recorded by the profiler matches: exactly one ModelCallRecord
        // at round 0 for this turn.
        #expect(result.turnProfiles.first?.modelCalls.map(\ModelCallRecord.round) == [0])
    }

    /// `IrisEngine` allocates the retry-attempt counter only when a dump sink is set (task 8,
    /// carried item 3): with no `dumpRequestsTo`, `requestDumpSink` is nil, so the counter is never
    /// built and `onRetry` sets nothing. There is no seam to observe the allocation itself without
    /// adding test-only instrumentation to production code, so this proves the behavior that
    /// matters instead: a retried round still succeeds, with no dump sink, exactly as it did
    /// before the counter became conditional.
    @Test("a retry still succeeds with no dump sink configured (no counter needed)")
    func retrySucceedsWithNoDumpSink() async throws {
        let singleTurnScenario = Scenario(name: "single", clientMode: .fake, turns: [Scenario.Turn(prompt: "hi")])
        let result = await ScenarioRunner.run(singleTurnScenario, clientOverride: FailsOnceThenSucceeds(),
                                              retryDelays: [0])
        #expect(result.finalTexts == ["ack"])
        #expect(result.turnErrors == [nil])
    }

    /// A sanity baseline for the refactor away from the client-wrapping collector (5a review F4):
    /// a plain single-round turn still produces exactly one dump, named by the engine's own round.
    private final class RecordingClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requestCount = 0
        private let response: GeminiResponse
        init(response: GeminiResponse) { self.response = response }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { requestCount += 1 }
            return response
        }
    }

    @Test("dump-requests records only the top-level engine's own rounds, named <turn>-<round>.json")
    func dumpRequestsOnlyTopLevelRounds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-dump-top-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let part = Part(text: "ack", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let response = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        let client = RecordingClient(response: response)
        let singleTurnScenario = Scenario(name: "single", clientMode: .fake, turns: [Scenario.Turn(prompt: "hi")])
        _ = await ScenarioRunner.run(singleTurnScenario, clientOverride: client, dumpRequestsTo: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["1-0.json"], "exactly one dump for the one top-level round")
    }
}
