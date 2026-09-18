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

    @Test("the static user profile is sanitized through the model tiers once, not on every turn")
    func staticContextSanitizedOnce() async throws {
        // A fail-closed tier-3 error is deliberately never cached, and a bare test process has
        // no canary engine, so give the guard working mocks (the same ones InjectionGuardTests
        // installs) or every turn re-evaluates USER.md regardless of the cache.
        AuxiliaryModelManager.shared.setMockEngine(MockInferenceEngine(shouldHijack: false), for: "canary")
        CoreMLEvaluator.shared.setModel(MockCoreMLModel(probability: 0.0))
        let scenario = Scenario(name: "two-turns", clientMode: .fake,
                                turns: [Scenario.Turn(prompt: "one"), Scenario.Turn(prompt: "two")],
                                scriptedResponses: [
                                    Scenario.ScriptedResponse(kind: .text, text: "ack one", calls: nil),
                                    Scenario.ScriptedResponse(kind: .text, text: "ack two", calls: nil)
                                ])
        let result = await ScenarioRunner.run(scenario)
        #expect(result.turnProfiles.count == 2)
        let second = try #require(result.turnProfiles.last)
        // USER.md did not change between the turns, so the cached verdict is served (#130).
        #expect(second.spans["guard.tier3"] == nil)
        #expect(second.spans["assembly.userProfile"] != nil)
    }

    @Test("each tool call records its arguments")
    func toolArgsRecorded() async throws {
        let result = await ScenarioRunner.run(oneCommandThenText)
        let profile = try #require(result.turnProfiles.first)
        #expect(profile.toolCalls.first?.args?.contains("echo instrumented") == true)
    }
}
