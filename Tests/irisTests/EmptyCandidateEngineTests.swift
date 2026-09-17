import Testing
import Foundation
@testable import iris

/// A model reply with no content is reported as an LLM error pill that names the reason,
/// not as an agent message and not as a decode failure (#136).
@MainActor
@Suite("IrisEngine empty candidate")
struct EmptyCandidateEngineTests {
    private func run(_ response: GeminiResponse) async -> Conversation? {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [response]), retryDelays: [])
        await engine.processInput("hello", source: "User", conversationId: id)
        return app.conversations.first { $0.id == id }
    }

    @Test("a candidate with no parts becomes an LLM_ERROR pill naming the finish reason")
    func emptyPartsIsAPill() async throws {
        let response = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: []), finishReason: "SAFETY")], usageMetadata: nil)
        let conv = try #require(await run(response))
        let pills = conv.messages.compactMap { m in LLMErrorMessage.parse(m.content).map { (m.role, $0) } }
        #expect(pills.count == 1)
        #expect(pills.first?.0 == .system)
        #expect(pills.first?.1.headline.contains("no content") == true)
        #expect(pills.first?.1.headline.contains("SAFETY") == true)
        #expect(!conv.messages.contains { $0.role == .agent && $0.content.hasPrefix("Error: No candidate") })
    }

    @Test("a prompt block with no candidates is reported the same way")
    func noCandidatesIsAPill() async throws {
        var response = GeminiResponse(candidates: nil, usageMetadata: nil)
        response.promptFeedback = PromptFeedback(blockReason: "PROHIBITED_CONTENT")
        let conv = try #require(await run(response))
        let pill = try #require(conv.messages.compactMap { LLMErrorMessage.parse($0.content) }.first)
        #expect(pill.headline.contains("PROHIBITED_CONTENT"))
        #expect(!conv.messages.contains { $0.role == .agent && $0.content.hasPrefix("Error: No candidate") })
    }
}
