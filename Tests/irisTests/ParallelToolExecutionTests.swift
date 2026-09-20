import XCTest
@testable import iris

@MainActor
final class ParallelToolExecutionTests: XCTestCase {

    /// Routes straight to `AnthropicClient`'s static entry point with a fixed model/key, bypassing
    /// `LLMClient`'s `ConfigManager.shared.primaryProvider` dispatch entirely. `IrisEngine` already
    /// takes an injectable `client:`, so nothing here needs to mutate the process-global config to
    /// pick a provider (invariant 7, #215; the per-call injection pattern from #109).
    private struct AnthropicRoutingClient: LLMClientProtocol {
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            try await AnthropicClient.generateContent(request: request, model: "claude-3-5-sonnet", apiKey: "mock-api-key")
        }
        func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AnthropicClient.streamContent(request: request, model: "claude-3-5-sonnet", apiKey: "mock-api-key")
        }
        var supportsStreaming: Bool { false }
    }

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testParallelToolExecutionMaintainsOrder() async throws {
        // We will mock the LLM to return TWO tool calls in its first response.
        // We will then intercept the SECOND request (which contains the tool results)
        // and verify that the tool results are in the exact same order as the tool calls.

        let expectation = XCTestExpectation(description: "Second request contains ordered tool results")

        // Stateless handler: inspects the request body to decide which response to return
        // instead of relying on mutable counter state (which is fragile under parallel test
        // execution where MockURLProtocol.handler is a shared global).
        //
        // The body-content heuristic relies on the specific request bodies this test generates:
        // the first request contains only the user prompt; the second contains tool result IDs
        // (call_1, call_2). This is an implicit contract with the test's own mock responses.
        MockURLProtocol.handler = { request in
            let bodyData = request.bodyData ?? Data()
            let bodyString = String(data: bodyData, encoding: .utf8) ?? ""

            if bodyString.contains("call_1") || bodyString.contains("call_2") {
                // Second request: this contains tool results being sent back to the LLM.
                // Verify that tool results maintain order — call_1 must appear before call_2.
                if let call1Index = bodyString.range(of: "call_1")?.lowerBound,
                   let call2Index = bodyString.range(of: "call_2")?.lowerBound {
                    XCTAssertTrue(call1Index < call2Index, "Tool results must maintain the order of the original tool calls")
                    expectation.fulfill()
                } else {
                    XCTFail("Could not find tool call IDs in the request body")
                }

                // Return a final Finished message
                let responseJson: [String: Any] = [
                    "id": UUID().uuidString,
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-3-5-sonnet",
                    "content": [
                        [
                            "type": "text",
                            "text": "Finished."
                        ]
                    ],
                    "usage": ["input_tokens": 10, "output_tokens": 10]
                ]
                let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, responseData)
            } else {
                // First request: return two tool calls
                let responseJson: [String: Any] = [
                    "id": UUID().uuidString,
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-3-5-sonnet",
                    "content": [
                        [
                            "type": "tool_use",
                            "id": "call_1",
                            "name": "rename_conversation",
                            "input": [
                                "title": "Parallel Test 1"
                            ]
                        ],
                        [
                            "type": "tool_use",
                            "id": "call_2",
                            "name": "rename_conversation",
                            "input": [
                                "title": "Parallel Test 2"
                            ]
                        ]
                    ],
                    "usage": ["input_tokens": 10, "output_tokens": 10]
                ]
                let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, responseData)
            }
        }

        let state = AppState(tier3Provisioning: .provisioned)
        let convId = UUID()
        await MainActor.run {
            state.conversations.append(Conversation(id: convId, title: "Test", history: []))
        }
        let engine = IrisEngine(state: state, client: AnthropicRoutingClient())
        await engine.processInput("Do the parallel test", source: "User", conversationId: convId)

        await fulfillment(of: [expectation], timeout: 5.0)
    }
}
