import Testing
import Foundation
@testable import iris

private func runCommandResponse(_ command: String) -> GeminiResponse {
    let call = FunctionCall(name: "run_command", args: ["command": .string(command)],
                            id: nil, thought_signature: nil, thoughtSignature: nil)
    let part = Part(text: nil, functionCall: call, functionResponse: nil,
                    thought_signature: nil, thoughtSignature: nil)
    return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                          usageMetadata: nil)
}

@MainActor
@Suite("Loop-stop enforcement")
struct LoopStopEnforcementTests {

    /// Regression guard for #16: when loop detection stops a goal, the follow-up summary turn
    /// runs with `restrictToGoalComplete`. Since 5c §0.3 that turn keeps every declaration (so
    /// its cached prefix holds), which makes the execution layer the only enforcement: it must
    /// block anything but `goal_complete`. Here the model keeps trying to
    /// call `run_command`; the block must fire and the turn must not spin.
    @Test("restricted turn blocks a non-goal_complete tool and runs a single round")
    func restrictedTurnBlocksTool() async {
        let appState = AppState()
        let convId = UUID()
        appState.createNewConversation(id: convId)

        // Two identical run_command responses queued. If the engine honored the second one, the
        // turn spun; a correct single-round turn only asks the model once.
        let mock = FakeLLMClient(responses: [
            runCommandResponse("echo stuck"),
            runCommandResponse("echo stuck"),
        ])
        let engine = IrisEngine(state: appState, tier: .medium, client: mock)

        await engine.processInput("You reached a stopping condition. Summarize and stop.",
                                  source: "System", conversationId: convId,
                                  restrictToGoalComplete: true)

        let messages = appState.conversations.first(where: { $0.id == convId })?.messages ?? []

        // The block fired: a system message names the blocked tool, and it never executed.
        #expect(messages.contains {
            $0.content.contains("[blocked]") && $0.content.contains("run_command")
        })
        // The looping tool never ran, so no [TOOL_CALL] execution notice was emitted for it.
        #expect(!messages.contains { $0.content.contains("[TOOL_CALL]") })
        // Single round: the engine asked the model exactly once and did not reprompt itself.
        #expect(mock.callCount == 1)
    }

    /// 5c §0.3: the soft-stop turn keeps every declaration (stripping them was a removal flap on
    /// the longest history) and says in its turn context that only goal_complete will run.
    @Test("a restricted turn keeps the previous turn's declarations and says goal_complete only")
    func restrictedTurnKeepsDeclarations() async {
        let appState = AppState()
        let convId = UUID()
        appState.createNewConversation(id: convId)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: appState, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: convId)
        await engine.processInput("You reached a stopping condition. Summarize and stop.",
                                  source: "System", conversationId: convId, restrictToGoalComplete: true)
        let requests = client.requests
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        let before = Set(requests[0].tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
        let during = Set(requests[1].tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
        #expect(before.isSubset(of: during), "no removal flap on the longest history (§0.3)")
        #expect(during.contains("goal_complete") && during.contains("run_command"))
        let lastUser = requests[1].contents.last { $0.role == "user" }?.parts.compactMap(\.text).joined() ?? ""
        #expect(lastUser.contains(IrisEngine.goalCompleteOnlyInstruction))
    }
}
