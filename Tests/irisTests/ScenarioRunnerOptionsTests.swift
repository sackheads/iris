// Tests/irisTests/ScenarioRunnerOptionsTests.swift
import Testing
import Foundation
@testable import iris

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
}
