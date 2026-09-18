import Testing
import Foundation
@testable import iris

/// `rename_conversation` was offered on every turn with a description that invited a rename on
/// a first message; the eagerness suite measured it as the only unprompted tool call (#132).
/// It is now offered only on the rename-trigger turn, which both `/rename` and the automatic
/// third-message trigger send with the exact prefix `System Event [Rename Trigger]`.
@MainActor
@Suite("rename_conversation gating")
struct RenameToolGatingTests {
    private func toolNames(prompt: String, source: String) async -> [String] {
        let client = CapturingLLMClient(reply: "ok")
        let scenario = Scenario(name: "gate", clientMode: .fake, turns: [Scenario.Turn(prompt: prompt, source: source)])
        _ = await ScenarioRunner.run(scenario, clientOverride: client)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("a plain user turn does not offer rename_conversation")
    func userTurnHasNoRenameTool() async {
        let names = await toolNames(prompt: "What is the capital of Australia?", source: "UI")
        #expect(!names.contains("rename_conversation"))
        #expect(names.contains("run_command"), "the rest of the tool list is unaffected")
    }

    @Test("other system events do not offer it either")
    func otherSystemEventHasNoRenameTool() async {
        let names = await toolNames(prompt: "System Event [Reflection Trigger]: consolidate memory.", source: "System")
        #expect(!names.contains("rename_conversation"))
    }

    @Test("the rename trigger turn offers it")
    func renameTriggerHasRenameTool() async {
        let prompt = "System Event [Rename Trigger]: Evaluate the conversation history and use the `rename_conversation` tool to assign a short, descriptive title (1-4 words) that captures the true gist of this conversation."
        let names = await toolNames(prompt: prompt, source: "System")
        #expect(names.contains("rename_conversation"))
    }
}
