import Testing
import Foundation
@testable import IrisKit

/// A model reply with no content is reported as an LLM error pill that names the reason,
/// not as an agent message and not as a decode failure (#136).
@MainActor
@Suite("IrisEngine empty candidate", .timeLimit(.minutes(1)))
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

    /// #394: the pill names the engine's own provider, not `ConfigManager.shared`'s. Never touch
    /// the global here (invariant 7) — the whole point is that the pill is right even when the
    /// global disagrees with the engine, as a test harness or a future per-conversation provider
    /// would leave it.
    @Test("an engine built with provider: .anthropic names Anthropic, whatever ConfigManager.shared says")
    func pillNamesEnginesOwnProvider() async throws {
        let globalBefore = ConfigManager.shared.primaryProvider
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let response = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: []), finishReason: "SAFETY")], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [response]),
                                retryDelays: [], provider: LLMProvider.anthropic.rawValue)
        await engine.processInput("hello", source: "User", conversationId: id)
        let conv = try #require(app.conversations.first { $0.id == id })
        let pill = try #require(conv.messages.compactMap { LLMErrorMessage.parse($0.content) }.first)
        #expect(pill.headline.hasPrefix(LLMProvider.anthropic.rawValue))
        #expect(ConfigManager.shared.primaryProvider == globalBefore, "must never mutate ConfigManager.shared (invariant 7)")
    }
}
