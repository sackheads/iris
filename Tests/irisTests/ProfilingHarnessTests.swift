import Testing
import Foundation
@testable import iris

/// End-to-end guard for the headless harness: a scenario drives the real engine loop with no UI
/// and yields per-turn PerformanceProfiler breakdowns. Proves the core is profileable without a
/// human clicking through the app.
@MainActor
@Suite("Profiling harness")
struct ProfilingHarnessTests {

    @Test("a multi-turn scenario yields one profile per turn")
    func multiTurnProfiles() async {
        let scenario = Scenario(
            name: "two-turns",
            clientMode: .fake,
            turns: [
                Scenario.Turn(prompt: "first"),
                Scenario.Turn(prompt: "second")
            ],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .text, text: "ack one", calls: nil),
                Scenario.ScriptedResponse(kind: .text, text: "ack two", calls: nil)
            ])

        let result = await ScenarioRunner.run(scenario)

        #expect(result.turnProfiles.count == 2)
        #expect(result.wallClockMs > 0)
        // Every turn consulted the model.
        for profile in result.turnProfiles {
            #expect((profile.categories[.primaryLLM]?.count ?? 0) >= 1)
        }
    }

    @Test("a JSON scenario with a tool call is profiled end-to-end")
    func jsonToolScenario() async throws {
        let json = """
        {
          "name": "json-tool",
          "clientMode": "fake",
          "turns": [ { "prompt": "run it" } ],
          "scriptedResponses": [
            { "kind": "toolCalls", "calls": [ { "name": "run_command", "args": { "command": "echo harness" } } ] },
            { "kind": "text", "text": "done" }
          ]
        }
        """
        let scenario = try Scenario.decode(from: Data(json.utf8))
        let result = await ScenarioRunner.run(scenario)

        #expect(result.turnProfiles.count == 1)
        let profile = result.turnProfiles.first
        #expect((profile?.categories[.toolExecution]?.count ?? 0) >= 1)
        #expect((profile?.categories[.primaryLLM]?.count ?? 0) >= 1)
    }
}
