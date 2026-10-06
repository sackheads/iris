import Testing
import Foundation
@testable import iris

@Suite("Scenario schema")
struct ScenarioTests {

    @Test("decodes a fake scenario with scripted text and tool-call responses")
    func decodesFakeScenario() throws {
        let json = """
        {
          "name": "goal-loop",
          "clientMode": "fake",
          "tier": "medium",
          "toggles": { "guards": false, "hooks": false, "sandbox": false },
          "latencyMs": { "minMs": 100, "maxMs": 300 },
          "turns": [ { "prompt": "do the thing", "source": "User" } ],
          "scriptedResponses": [
            { "kind": "toolCalls", "calls": [ { "name": "run_command", "args": { "command": "echo hi" } } ] },
            { "kind": "text", "text": "all done" }
          ]
        }
        """
        let scenario = try Scenario.decode(from: Data(json.utf8))
        #expect(scenario.name == "goal-loop")
        #expect(scenario.clientMode == .fake)
        #expect(scenario.tier == .medium)
        #expect(scenario.toggles.guards == false)
        #expect(scenario.latencyMs?.minMs == 100)
        #expect(scenario.turns.count == 1)
        #expect(scenario.turns.first?.prompt == "do the thing")
        #expect(scenario.scriptedResponses.count == 2)
    }

    @Test("turn source defaults to User and toggles default to off when omitted")
    func defaultsApply() throws {
        let json = """
        { "name": "minimal", "turns": [ { "prompt": "hi" } ] }
        """
        let scenario = try Scenario.decode(from: Data(json.utf8))
        #expect(scenario.clientMode == .fake)          // default
        #expect(scenario.turns.first?.source == "User") // default
        #expect(scenario.toggles.guards == false)
        #expect(scenario.toggles.hooks == false)
        #expect(scenario.toggles.sandbox == false)
        #expect(scenario.scriptedResponses.isEmpty)
    }

    @Test("scripted toolCalls response maps to a GeminiResponse function call with args")
    func toolCallMapping() throws {
        let call = Scenario.ScriptedCall(name: "run_command", args: ["command": .string("ls")])
        let resp = Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [call])
        let gemini = resp.asGeminiResponse()
        let part = gemini.candidates?.first?.content?.parts.first
        #expect(part?.functionCall?.name == "run_command")
        #expect(part?.functionCall?.args["command"] == .string("ls"))
        #expect(part?.text == nil)
    }

    @Test("scripted text response maps to a GeminiResponse text part")
    func textMapping() throws {
        let resp = Scenario.ScriptedResponse(kind: .text, text: "hello", calls: nil)
        let gemini = resp.asGeminiResponse()
        let part = gemini.candidates?.first?.content?.parts.first
        #expect(part?.text == "hello")
        #expect(part?.functionCall == nil)
    }
}

@Suite("Scenario 5c fields")
struct Scenario5cFieldTests {
    @Test("pauseBeforeSeconds, background and freshConversationPerTurn decode; absent means nil, false, false")
    func decodes() throws {
        let json = #"""
        { "name": "c", "background": true, "freshConversationPerTurn": true,
          "turns": [ { "prompt": "a" }, { "prompt": "b", "pauseBeforeSeconds": 900 } ] }
        """#
        let s = try Scenario.decode(from: Data(json.utf8))
        #expect(s.background && s.freshConversationPerTurn)
        #expect(s.turns.map(\.pauseBeforeSeconds) == [nil, 900])

        let old = try Scenario.decode(from: Data(#"{"name":"n","turns":[{"prompt":"p"}]}"#.utf8))
        #expect(!old.background && !old.freshConversationPerTurn)
        #expect(old.turns[0].pauseBeforeSeconds == nil)
    }
}

@Suite("PerfExperiments (5c)")
struct PerfExperimentsTests {
    @Test("an empty environment is an ordinary run")
    func defaults() {
        let e = PerfExperiments.fromEnvironment([:])
        #expect(e == PerfExperiments())
        #expect(e.stickyTools && !e.declareStateGatedTools && e.ttlOverride == nil)
        #expect(e.activeNames.isEmpty)
    }

    @Test("each switch maps to its field and its record name")
    func mapsEachValue() {
        #expect(PerfExperiments.fromEnvironment(["IRIS_PERF_DECLARE_STATE_TOOLS": "1"]).declareStateGatedTools)
        #expect(!PerfExperiments.fromEnvironment(["IRIS_PERF_STICKY_TOOLS": "0"]).stickyTools)
        #expect(PerfExperiments.fromEnvironment(["IRIS_PERF_STICKY_TOOLS": "1"]).stickyTools)
        #expect(PerfExperiments.fromEnvironment(["IRIS_PERF_TTL": "5m"]).ttlOverride == .standard)
        #expect(PerfExperiments.fromEnvironment(["IRIS_PERF_TTL": "1h"]).ttlOverride
                == CacheTTLPolicy(prefix: .oneHour, history: .oneHour))
        #expect(PerfExperiments.fromEnvironment(["IRIS_PERF_TTL": "1h-prefix"]).ttlOverride
                == CacheTTLPolicy(prefix: .oneHour, history: .fiveMinutes))
        let all = PerfExperiments.fromEnvironment(["IRIS_PERF_DECLARE_STATE_TOOLS": "1", "IRIS_PERF_STICKY_TOOLS": "0",
                                                   "IRIS_PERF_TTL": "1h-prefix"])
        #expect(all.activeNames == ["IRIS_PERF_DECLARE_STATE_TOOLS=1", "IRIS_PERF_STICKY_TOOLS=0", "IRIS_PERF_TTL=1h-prefix"])
    }

    @Test("an unknown TTL is ignored with a warning")
    func unknownTTLIgnored() {
        var warnings: [String] = []
        let e = PerfExperiments.fromEnvironment(["IRIS_PERF_TTL": "2h"], warn: { warnings.append($0) })
        #expect(e.ttlOverride == nil)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("IRIS_PERF_TTL=2h") == true)
    }

    @Test("the report prints one EXPERIMENT line per recorded switch")
    func reportLines() {
        var r = PerfRecordTests.sampleRecord()
        r.environment.experiments = ["IRIS_PERF_STICKY_TOOLS=0", "IRIS_PERF_TTL=5m"]
        let text = PerfReport.render(r)
        #expect(text.contains("- EXPERIMENT: sticky tool declarations off"))
        #expect(text.contains("- EXPERIMENT: every Anthropic cache marker at 5 minutes (IRIS_PERF_TTL=5m)"))
        #expect(!PerfReport.render(PerfRecordTests.sampleRecord()).contains("EXPERIMENT"))
    }
}

