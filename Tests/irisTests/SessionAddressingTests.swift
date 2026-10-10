import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Session addressing and listing", .timeLimit(.minutes(1)))
struct SessionAddressingTests {
    func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    func runToolCall(_ call: FunctionCall, on app: AppState, as id: UUID) async -> String {
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResultText(app, conversationId: id)
    }

    @Test("list_sessions shows role, lane and skills; describe_session shows examples")
    func listingAndDescribe() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), pr = UUID(), w = UUID()
        for id in [me, pr, w] { app.createNewConversation(id: id) }
        _ = app.assignRole("pr-minder", to: pr)
        app.setSessionCard(for: pr, SessionCard(name: "prm", description: "watching PRs", skills: [
            AgentSkill(id: "review-pr", name: "Review a PR", description: "d", tags: ["github"], examples: ["review PR 12"])]))
        app.setSessionCard(for: w, SessionCard(name: "sw", description: "ui work", lane: "swift UI"))

        let list = await runToolCall(FunctionCall(name: "list_sessions", args: [:], id: "c1"), on: app, as: me)
        #expect(list.contains("role: pr-minder"))
        #expect(list.contains("lane: \"swift UI\""))
        #expect(list.contains("review-pr"))
        #expect(!list.contains("review PR 12"), "examples only in describe_session")

        let card = await runToolCall(FunctionCall(name: "describe_session", args: ["to": .string("role:pr-minder")], id: "c2"), on: app, as: me)
        #expect(card.contains("review PR 12"))
        #expect(card.contains(pr.uuidString))
    }
}
