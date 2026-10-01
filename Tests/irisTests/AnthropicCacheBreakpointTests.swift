import Testing
import Foundation
@testable import iris

/// 5a §1. `markLastContentBlock` skipped a message whose last block was a `tool_result`, so a
/// round ending in tool results wrote its cache entry at the assistant's `tool_use` instead, and
/// the results were re-sent uncached on the next round and the next turn. The API accepts
/// `cache_control` on `tool_result` blocks; the skip was an artifact.
@Suite("Anthropic cache breakpoints (5a)")
struct AnthropicCacheBreakpointTests {
    private func part(_ text: String) -> Part {
        Part(text: text, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
    }

    private func toolRoundRequest() -> GeminiRequest {
        let call = FunctionCall(name: "run_command", args: ["command": .string("ls")], id: "call_1")
        let callPart = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let results = ["call_1", "call_2"].map { id in
            Part(text: nil, functionCall: nil,
                 functionResponse: FunctionResponse(name: "run_command", response: ["output": .string("ok")], id: id),
                 thought_signature: nil, thoughtSignature: nil)
        }
        return GeminiRequest(contents: [
            Content(role: "user", parts: [part("count the files")]),
            Content(role: "model", parts: [callPart]),
            Content(role: "user", parts: results),
        ], systemInstruction: Content(role: "system", parts: [part("system")]), tools: nil)
    }

    private func body(_ request: GeminiRequest) throws -> [String: Any] {
        let urlRequest = try AnthropicClient.makeURLRequest(request: request, model: "m", apiKey: "k", stream: false)
        let data = try #require(urlRequest.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("a round ending in tool results carries the breakpoint on its last tool_result")
    func toolResultIsMarked() throws {
        let messages = try #require(try body(toolRoundRequest())["messages"] as? [[String: Any]])
        let last = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(last.last?["type"] as? String == "tool_result")
        #expect(last.last?["cache_control"] != nil, "the tool results must be inside the cached prefix of the next round")
    }

    @Test("marking tool results never exceeds the API's four breakpoints")
    func atMostFourMarkers() throws {
        let data = try JSONSerialization.data(withJSONObject: try body(toolRoundRequest()))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.components(separatedBy: "\"cache_control\"").count - 1 <= 4)
    }
}
