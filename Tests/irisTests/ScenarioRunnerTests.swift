import Testing
import Foundation
@testable import iris

@MainActor
@Suite("ScenarioRunner")
struct ScenarioRunnerTests {

    @Test("fake scenario with a tool call runs headlessly and profiles one turn")
    func runsFakeToolScenario() async {
        let scenario = Scenario(
            name: "echo",
            clientMode: .fake,
            turns: [Scenario.Turn(prompt: "run echo")],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                    Scenario.ScriptedCall(name: "run_command", args: ["command": .string("echo hello")])
                ]),
                Scenario.ScriptedResponse(kind: .text, text: "done", calls: nil)
            ])

        let result = await ScenarioRunner.run(scenario)

        // One processInput => one profiler turn.
        #expect(result.turnProfiles.count == 1)
        #expect(result.wallClockMs > 0)
        let profile = result.turnProfiles.first
        // The model was consulted and a tool ran, headlessly, with no UI.
        #expect((profile?.categories[.primaryLLM]?.count ?? 0) >= 1)
        #expect((profile?.categories[.toolExecution]?.count ?? 0) >= 1)
    }
}
