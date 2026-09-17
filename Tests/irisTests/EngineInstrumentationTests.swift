import Testing
import Foundation
@testable import iris

/// A fake scenario through the real engine loop must leave the finer records behind.
@MainActor
@Suite("Engine instrumentation")
struct EngineInstrumentationTests {
    private var oneCommandThenText: Scenario {
        Scenario(name: "instrumented", clientMode: .fake,
                 turns: [Scenario.Turn(prompt: "run it")],
                 scriptedResponses: [
                    Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                        Scenario.ScriptedCall(name: "run_command", args: ["command": .string("echo instrumented")])
                    ]),
                    Scenario.ScriptedResponse(kind: .text, text: "done", calls: nil)
                 ])
    }

    @Test("every model round is recorded with its round index and tool-call flag")
    func modelCallsRecorded() async throws {
        let result = await ScenarioRunner.run(oneCommandThenText)
        let profile = try #require(result.turnProfiles.first)
        #expect(profile.modelCalls.map(\.round) == [0, 1])
        #expect(profile.modelCalls.map(\.returnedToolCalls) == [true, false])
        #expect(profile.modelCalls.allSatisfy { $0.promptTokens == nil })
        #expect(profile.modelCalls.allSatisfy { !$0.model.isEmpty })
    }

    @Test("each dispatched tool is recorded by name")
    func toolCallsRecorded() async throws {
        let result = await ScenarioRunner.run(oneCommandThenText)
        let profile = try #require(result.turnProfiles.first)
        #expect(profile.toolCalls.map(\.name) == ["run_command"])
        #expect(profile.toolCalls.first?.ok == true)
    }

    @Test("assembly and guard tier-1 spans are present")
    func spansRecorded() async throws {
        let result = await ScenarioRunner.run(oneCommandThenText)
        let profile = try #require(result.turnProfiles.first)
        #expect(profile.spans["assembly.factSearch"] != nil)
        #expect(profile.spans["assembly.userProfile"] != nil)
        #expect(profile.spans["assembly.systemPrompt"] != nil)
        #expect((profile.spans["guard.tier1"]?.count ?? 0) >= 1)
    }
}
