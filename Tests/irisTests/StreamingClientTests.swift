import Testing
import Foundation
@testable import iris

/// The streaming request shapes and the URLSession → SSE → mapper pump, against a mocked transport.
@Suite("Streaming clients", .serialized)
struct StreamingClientTests {
    private func withMock<T>(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data), _ body: () async throws -> T) async rethrows -> T {
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = handler
        defer { MockURLProtocol.handler = nil; URLProtocol.unregisterClass(MockURLProtocol.self) }
        return try await body()
    }

    private func ok(_ url: URL, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(body.utf8))
    }

    private var request: GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
    }

    @Test("the Gemini streaming URL swaps the method and asks for SSE, on both endpoint forms")
    func geminiStreamingURL() throws {
        let direct = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: false, customBaseURL: "", quotaProject: nil, streaming: true)
        #expect(direct.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:streamGenerateContent?alt=sse")
        let vertex = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: true, customBaseURL: "", quotaProject: "proj", streaming: true)
        #expect(vertex.absoluteString == "https://aiplatform.googleapis.com/v1/projects/proj/locations/global/publishers/google/models/gemini-x:streamGenerateContent?alt=sse")
        let plain = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: false, customBaseURL: "", quotaProject: nil)
        #expect(plain.absoluteString.hasSuffix(":generateContent"))
        // A custom endpoint is rewritten only when it names the plain method; anything else is taken as configured.
        let custom = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: false,
                                                           customBaseURL: "https://proxy.example/v1beta/models/gemini-x:generateContent",
                                                           quotaProject: nil, streaming: true)
        #expect(custom.absoluteString == "https://proxy.example/v1beta/models/gemini-x:streamGenerateContent?alt=sse")
        let opaque = try LLMClient.resolveGeminiRequestURL(modelName: "gemini-x", isADC: false,
                                                           customBaseURL: "https://proxy.example/stream", quotaProject: nil, streaming: true)
        #expect(opaque.absoluteString == "https://proxy.example/stream")
    }

    @Test("Anthropic: stream flag in the body, events mapped end to end, non-streaming body unchanged")
    func anthropicStream() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let events: [LLMStreamEvent] = try await withMock({ req in
            let body = try JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(body?["stream"] as? Bool == true)
            #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
            return self.ok(req.url!, body: sse)
        }) {
            var got: [LLMStreamEvent] = []
            for try await e in AnthropicClient.streamContent(request: request, model: "claude-x", apiKey: "k") { got.append(e) }
            return got
        }
        #expect(events == [
            .usage(UsageMetadata(promptTokenCount: 12, candidatesTokenCount: nil, totalTokenCount: nil)),
            .textDelta("Hel"), .textDelta("lo"),
            .usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 5, totalTokenCount: nil)),
            .done(finishReason: "end_turn")
        ])
        let plain = try AnthropicClient.makeURLRequest(request: request, model: "claude-x", apiKey: "k", baseURL: "", stream: false)
        let plainBody = try JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any]
        #expect(plainBody?["stream"] == nil)
    }

    @Test("OpenAI: stream and stream_options in the body, chunks mapped end to end")
    func openAIStream() async throws {
        let sse = """
        data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}

        data: [DONE]

        """
        let events: [LLMStreamEvent] = try await withMock({ req in
            let body = try JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(body?["stream"] as? Bool == true)
            #expect((body?["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
            return self.ok(req.url!, body: sse)
        }) {
            var got: [LLMStreamEvent] = []
            for try await e in OpenAIClient.streamContent(request: request, model: "gpt-x", apiKey: "k") { got.append(e) }
            return got
        }
        #expect(events == [.textDelta("Hi"),
                           .usage(UsageMetadata(promptTokenCount: 3, candidatesTokenCount: 1, totalTokenCount: 4)),
                           .done(finishReason: "stop")])
    }

    @Test("a non-2xx response is read to the end and thrown as the same APIError as a plain call")
    func httpErrorThrows() async throws {
        let body = #"{"error":{"type":"rate_limit_error","message":"Too many"}}"#
        let thrown: Error? = await withMock({ req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "7"])!, Data(body.utf8))
        }) {
            do {
                for try await _ in AnthropicClient.streamContent(request: request, model: "claude-x", apiKey: "k") {}
                return nil
            } catch { return error }
        }
        let api = try #require(thrown as? APIError)
        #expect(api.statusCode == 429)
        #expect(api.retryAfter == 7)
        #expect(api.message == "Anthropic HTTP 429 rate_limit_error: Too many")
    }

    @Test("an empty API key fails before any request, as the plain call does")
    func emptyKey() async {
        var thrown: Error?
        do { for try await _ in OpenAIClient.streamContent(request: request, model: "m", apiKey: "") {} } catch { thrown = error }
        #expect((thrown as? URLError)?.code == .userAuthenticationRequired)
    }

    @Test("the production client advertises native streaming")
    func nativeFlag() {
        #expect(LLMClient().supportsStreaming == true)
    }
}
