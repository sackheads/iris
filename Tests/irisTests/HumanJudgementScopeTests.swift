import Testing
import Foundation
@testable import iris

/// D2 must not disturb the ladder, the loop guards, or D1's paths (spec §9).
@MainActor
@Suite("Human judgement scope (D2)", .serialized)
struct HumanJudgementScopeTests {
    @Test("a checkpoint pause is still a checkpoint pause, not a judgement pause")
    func checkpointPauseIsUnchanged() {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let a = Criterion(text: "one", kind: .qualitative, check: nil)
        let b = Criterion(text: "two", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [a, b])
        contract.milestones = [Milestone(title: "One", criterionIds: [a.id]),
                               Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, contract)
        app.setCheckpointPaused(for: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointStatus == .pausedForReview)
        #expect(c?.awaitingHumanJudgement == false,
                "the two pauses must stay distinct — ChatView shows different panels for them")
        #expect(c?.isPaused == true, "but both suppress the loop")
    }

    @Test("no tool named judge_criterion exists — the model must not judge")
    func noJudgementTool() async {
        // AGENTS.md invariant 6, and the point of the humanJudged kind. If a future change adds a
        // tool for this, it hands the model a verdict it is not entitled to give.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let recorder = ToolNameRecorder()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: recorder)
        await engine.processInput("hello", source: "User", conversationId: id)

        #expect(!recorder.seenToolNames.contains("judge_criterion"))
        #expect(!recorder.seenToolNames.contains { $0.contains("judge") })
    }

    /// Captures the tool names offered on a plain turn.
    final class ToolNameRecorder: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        var seenToolNames: Set<String> { lock.withLock { names } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock {
                for tool in request.tools ?? [] {
                    for d in tool.functionDeclarations { names.insert(d.name) }
                }
            }
            let part = Part(text: "ok", functionCall: nil, functionResponse: nil,
                            thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                  usageMetadata: nil)
        }
    }
}
