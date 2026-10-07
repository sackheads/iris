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

    @Test("a non-streaming request never asks for more than 8192, which fits the 180 s timeout")
    func nonStreamingCap() {
        #expect(AnthropicClient.maxTokens(for: "claude-opus-5-5", stream: false) == 8192)
        #expect(AnthropicClient.maxTokens(for: "claude-next-9", stream: false) == 8192)
    }

    @Test("a budget cap lowers the model's value and never raises it")
    func budgetCap() {
        #expect(AnthropicClient.maxTokens(for: "claude-opus-5-5", stream: true, budgetCap: 4000) == 4000)
        #expect(AnthropicClient.maxTokens(for: "claude-opus-5-5", stream: true, budgetCap: 100_000) == 32_000)
        #expect(AnthropicClient.maxTokens(for: "claude-opus-5-5", stream: false, budgetCap: 20_000) == 8192)
    }

    @Test("the direct route's body carries the model's value")
    func directBody() throws {
        #expect(try maxTokens(model: "claude-opus-5-5", transport: Self.direct, stream: true) == 32_000)
        #expect(try maxTokens(model: "claude-opus-5-5", transport: Self.direct, stream: false) == 8192)
        #expect(try maxTokens(model: "claude-next-9", transport: Self.direct, stream: true) == 16_000)
    }

    @Test("the Vertex route's body carries the model's value, dated ids included")
    func vertexBody() throws {
        #expect(try maxTokens(model: "claude-fable-5-1", transport: Self.vertex, stream: true) == 32_000)
        #expect(try maxTokens(model: "claude-haiku-4-5-20251001", transport: Self.vertex, stream: true) == 32_000)
        #expect(try maxTokens(model: "claude-haiku-4-5-20251001", transport: Self.vertex, stream: false) == 8192)
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

    @Test("a non-streamed tool_use cut off at max_tokens is refused, never returned to run")
    func truncatedToolUseRefused() throws {
        let cut: [String: Any] = [
            "content": [["type": "text", "text": "writing it"],
                        ["type": "tool_use", "id": "t1", "name": "write_file", "input": ["path": "/tmp/x"]]],
            "stop_reason": "max_tokens"]
        #expect(throws: APIError.self) { _ = try AnthropicClient.parseResponse(cut) }

        // A complete tool_use before a cut-off text block is fine, as is one that ended normally.
        let cutAfter: [String: Any] = [
            "content": [["type": "tool_use", "id": "t1", "name": "read_file", "input": ["path": "/tmp/x"]],
                        ["type": "text", "text": "and then"]],
            "stop_reason": "max_tokens"]
        #expect(try AnthropicClient.parseResponse(cutAfter).candidates?.first?.content?.parts.contains { $0.functionCall != nil } == true)
        var whole = cut
        whole["stop_reason"] = "tool_use"
        #expect(try AnthropicClient.parseResponse(whole).candidates?.first?.content?.parts.contains { $0.functionCall != nil } == true)
    }

    @Test("the streaming path refuses a tool block whose JSON was cut off")
    func streamedTruncatedToolRefused() throws {
        var mapper = AnthropicStreamMapper()
        _ = try mapper.handle(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"write_file","input":{}}}"#))
        _ = try mapper.handle(SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\": \"/tmp/x\", \"content\": \"half"}}"#))
        #expect(throws: (any Error).self) {
            _ = try mapper.handle(SSEEvent(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#))
        }
    }
}

/// The engine half: a truncated reply keeps its text and gets an error pill after it.
@MainActor
@Suite("IrisEngine truncated reply")
struct TruncatedReplyEngineTests {
    private func run(_ responses: [GeminiResponse]) async -> Conversation? {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: responses), retryDelays: [])
        await engine.processInput("hello", source: "User", conversationId: id)
        return app.conversations.first { $0.id == id }
    }

    private func run(_ response: GeminiResponse) async -> Conversation? { await run([response]) }

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

    @Test("a truncated final round fails a job run")
    func finalRoundFailsJob() async throws {
        let conv = try #require(await run([reply("half an ans", finish: "max_tokens")]))
        #expect(JobRunner.status(messages: conv.messages, denials: [], softStopped: false) == .failed)
    }

    @Test("a truncated middle round is a warning; the turn continues and a job run completes")
    func middleRoundIsAWarning() async throws {
        let call = FunctionCall(name: "no_such_tool", args: [:], id: "c1")
        let middle = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "first part"), Part(functionCall: call)]),
                                                           finishReason: "max_tokens")], usageMetadata: nil)
        let conv = try #require(await run([middle, reply("all done", finish: "end_turn")]))
        #expect(conv.messages.compactMap { LLMErrorMessage.parse($0.content) }.isEmpty)
        #expect(conv.messages.contains { $0.role == .system && $0.content.hasPrefix(IrisEngine.outputLimitWarningPrefix) })
        #expect(conv.messages.last { $0.role == .agent }?.content == "all done")
        #expect(JobRunner.status(messages: conv.messages, denials: [], softStopped: false) == .completed)
    }

    @Test("a reply that ended normally gets no pill", arguments: ["end_turn", "STOP", "stop"])
    func finishedIsQuiet(finish: String) async throws {
        let conv = try #require(await run(reply("a whole answer", finish: finish)))
        #expect(conv.messages.compactMap { LLMErrorMessage.parse($0.content) }.isEmpty)
    }
}

/// A budgeted run asks for no more output than its remaining budget can pay for.
@MainActor
@Suite("Output cap from the run budget")
struct BudgetOutputCapTests {
    private func firstRequest(budget: TurnBudget?) async throws -> GeminiRequest {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = CapturingLLMClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [])
        await engine.processInput("hello", source: "job:test", conversationId: id, turnBudget: budget)
        return try #require(client.requests.first)
    }

    @Test("20K weighted left sends max_tokens <= 4000, not 32000")
    func twentyKLeft() async throws {
        let budget = TurnBudget(maxTokens: 20_000, deadline: Date().addingTimeInterval(600), provider: LLMProvider.anthropic.rawValue)
        let request = try await firstRequest(budget: budget)
        #expect(request.maxOutputTokens == 4000)
        let urlRequest = try AnthropicClient.makeURLRequest(request: request, model: "claude-opus-5-5",
                                                            transport: .direct(apiKey: "k", baseURL: ""), stream: true)
        let data = try #require(urlRequest.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(body["max_tokens"] as? Int)
        #expect(sent <= 4000)
    }

    @Test("a nearly spent budget still asks for the 1024 floor")
    func floor() {
        let budget = TurnBudget(maxTokens: 2000, deadline: Date().addingTimeInterval(600), provider: LLMProvider.anthropic.rawValue)
        #expect(budget.outputTokenCap(weightedTokens: 1500) == TurnBudget.minOutputTokenCap)
        #expect(TurnBudget(maxTokens: 0, deadline: Date()).outputTokenCap(weightedTokens: 0) == nil)
        #expect(TurnBudget(maxTokens: 10_000, deadline: Date()).outputTokenCap(weightedTokens: 0) == 10_000, "no provider weighs output at 1x")
    }

    @Test("an unbudgeted turn sets no cap")
    func noBudget() async throws {
        #expect(try await firstRequest(budget: nil).maxOutputTokens == nil)
    }
}
