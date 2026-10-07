import Testing
import Foundation
@testable import iris

/// `max_tokens` is sized per model instead of a fixed 4096, which thinking alone could use up,
/// and a reply cut off at the limit is surfaced instead of reading as a finished one.
@Suite("Anthropic max_tokens per model")
struct AnthropicMaxTokensTests {

    private static let request = GeminiRequest(
        contents: [Content(role: "user", parts: [Part(text: "hi")])],
        systemInstruction: nil, tools: nil)

    private static let vertex = AnthropicTransport.vertex(project: "test-project", location: "global", accessToken: "t")
    private static let direct = AnthropicTransport.direct(apiKey: "k", baseURL: "")

    private func maxTokens(model: String, transport: AnthropicTransport, stream: Bool) throws -> Int? {
        let req = try AnthropicClient.makeURLRequest(request: Self.request, model: model, transport: transport, stream: stream)
        let data = try #require(req.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return body["max_tokens"] as? Int
    }

    @Test("5.x and documented older models get 32000; Haiku's 64K is capped to 32000",
          arguments: ["claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5", "claude-mythos-5",
                      "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8",
                      "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"])
    func tableValues(model: String) {
        #expect(AnthropicClient.maxTokens(for: model, stream: true) == 32_000)
    }

    @Test("the API's dated id and Vertex's @-dated id find the alias's row")
    func datedIDs() {
        #expect(AnthropicClient.maxTokens(for: "claude-haiku-4-5-20251001", stream: true) == 32_000)
        #expect(AnthropicClient.maxTokens(for: "claude-haiku-4-5@20251001", stream: true) == 32_000)
    }

    @Test("unknown ids, and models with no documented max, get the conservative 16000",
          arguments: ["claude-next-9", "", "gpt-5", "claude-opus-4-5-20251101", "claude-sonnet-4-5"])
    func fallback(model: String) {
        #expect(AnthropicClient.maxTokens(for: model, stream: true) == 16_000)
    }

    @Test("a non-streaming request never asks for more than 16000")
    func nonStreamingCap() {
        #expect(AnthropicClient.maxTokens(for: "claude-opus-5-5", stream: false) == 16_000)
        #expect(AnthropicClient.maxTokens(for: "claude-next-9", stream: false) == 16_000)
    }

    @Test("the direct route's body carries the model's value")
    func directBody() throws {
        #expect(try maxTokens(model: "claude-opus-5-5", transport: Self.direct, stream: true) == 32_000)
        #expect(try maxTokens(model: "claude-opus-5-5", transport: Self.direct, stream: false) == 16_000)
        #expect(try maxTokens(model: "claude-next-9", transport: Self.direct, stream: true) == 16_000)
    }

    @Test("the Vertex route's body carries the model's value, dated ids included")
    func vertexBody() throws {
        #expect(try maxTokens(model: "claude-fable-5-1", transport: Self.vertex, stream: true) == 32_000)
        #expect(try maxTokens(model: "claude-haiku-4-5-20251001", transport: Self.vertex, stream: true) == 32_000)
        #expect(try maxTokens(model: "claude-haiku-4-5-20251001", transport: Self.vertex, stream: false) == 16_000)
    }

    @Test("a non-streamed reply's stop_reason reaches the candidate")
    func parseStopReason() throws {
        let cut = try AnthropicClient.parseResponse(["content": [["type": "text", "text": "partial"]], "stop_reason": "max_tokens"])
        #expect(cut.candidates?.first?.finishReason == "max_tokens")
        #expect(cut.truncatedReason == "max_tokens")

        // All thinking, no text: the empty pill names the cause instead of "no candidates".
        let empty = try AnthropicClient.parseResponse(["content": [[String: Any]](), "stop_reason": "max_tokens"])
        #expect(empty.emptyReason == "finishReason: max_tokens")
        #expect(empty.truncatedReason == nil)

        let done = try AnthropicClient.parseResponse(["content": [["type": "text", "text": "ok"]], "stop_reason": "end_turn"])
        #expect(done.truncatedReason == nil)
    }
}

/// The engine half: a truncated reply keeps its text and gets an error pill after it.
@MainActor
@Suite("IrisEngine truncated reply")
struct TruncatedReplyEngineTests {
    private func run(_ response: GeminiResponse) async -> Conversation? {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [response]), retryDelays: [])
        await engine.processInput("hello", source: "User", conversationId: id)
        return app.conversations.first { $0.id == id }
    }

    private func reply(_ text: String, finish: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]), finishReason: finish)],
                       usageMetadata: nil)
    }

    @Test("max_tokens with text: the text is kept and a pill names the limit", arguments: ["max_tokens", "MAX_TOKENS", "length"])
    func truncatedIsSurfaced(finish: String) async throws {
        let conv = try #require(await run(reply("half an ans", finish: finish)))
        #expect(conv.messages.contains { $0.role == .agent && $0.content.contains("half an ans") })
        let pills = conv.messages.compactMap { LLMErrorMessage.parse($0.content) }
        #expect(pills.count == 1)
        #expect(pills.first?.headline.contains("output limit") == true)
        #expect(pills.first?.headline.contains(finish) == true)
    }

    @Test("a reply that ended normally gets no pill", arguments: ["end_turn", "STOP", "stop"])
    func finishedIsQuiet(finish: String) async throws {
        let conv = try #require(await run(reply("a whole answer", finish: finish)))
        #expect(conv.messages.compactMap { LLMErrorMessage.parse($0.content) }.isEmpty)
    }
}
