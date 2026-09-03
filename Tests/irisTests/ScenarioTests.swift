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
