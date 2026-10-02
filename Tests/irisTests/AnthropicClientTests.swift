import XCTest
@testable import iris

final class AnthropicClientTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    
    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }
    
    func testAnthropicRequestTranslationText() async throws {
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "Hello, Claude", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
            ],
            systemInstruction: Content(role: "system", parts: [Part(text: "System instructions here", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]),
            tools: nil
        )
        
        MockURLProtocol.handler = { urlRequest in
            XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(urlRequest.httpMethod, "POST")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "test-key-anthropic")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
            
            guard let bodyData = urlRequest.bodyData,
                  let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                XCTFail("Failed to read HTTP request body")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(bodyJson["model"] as? String, "claude-3-5-sonnet")
            
            if let systemArray = bodyJson["system"] as? [[String: Any]],
               let firstBlock = systemArray.first,
               let text = firstBlock["text"] as? String {
                XCTAssertEqual(text, "System instructions here")
                if let cacheControl = firstBlock["cache_control"] as? [String: Any] {
                    XCTAssertEqual(cacheControl["type"] as? String, "ephemeral")
                } else {
                    XCTFail("Missing cache_control in system block")
                }
            } else {
                XCTFail("System prompt is not in the expected array of blocks format")
            }
            
            guard let messages = bodyJson["messages"] as? [[String: Any]] else {
                XCTFail("Missing messages array")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(messages.count, 1)
            let firstMessage = messages[0]
            XCTAssertEqual(firstMessage["role"] as? String, "user")
            
            guard let contents = firstMessage["content"] as? [[String: Any]] else {
                XCTFail("Missing content array in message")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(contents.count, 1)
            XCTAssertEqual(contents[0]["type"] as? String, "text")
            XCTAssertEqual(contents[0]["text"] as? String, "Hello, Claude")
            
            let responseJson: [String: Any] = [
                "id": "msg_01",
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [
                    [
                        "type": "text",
                        "text": "Hello there! I am Claude."
                    ]
                ],
                "usage": [
                    "input_tokens": 12,
                    "output_tokens": 24
                ]
            ]
            
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (httpResponse, responseData)
        }
        
        let response = try await AnthropicClient.generateContent(
            request: request,
            model: "claude-3-5-sonnet",
            apiKey: "test-key-anthropic"
        )
        
        XCTAssertNotNil(response.candidates)
        XCTAssertEqual(response.candidates?.count, 1)
        let firstCandidate = response.candidates?[0]
        XCTAssertEqual(firstCandidate?.content?.role, "model")
        XCTAssertEqual(firstCandidate?.content?.parts.count, 1)
        XCTAssertEqual(firstCandidate?.content?.parts[0].text, "Hello there! I am Claude.")
        
        XCTAssertEqual(response.usageMetadata?.promptTokenCount, 12)
        XCTAssertEqual(response.usageMetadata?.candidatesTokenCount, 24)
    }
    
    func testAnthropicRequestTranslationTools() async throws {
        let functionDecl = FunctionDeclaration(
            name: "get_weather",
            description: "Get the current weather",
            parameters: Schema(
                type: "object",
                properties: [
                    "location": Schema(type: "string", properties: nil, required: nil, description: "City and state, e.g. San Francisco, CA")
                ],
                required: ["location"],
                description: nil
            )
        )
        
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "What is the weather in Boston?", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
            ],
            systemInstruction: nil,
            tools: [Tool(functionDeclarations: [functionDecl])]
        )
        
        MockURLProtocol.handler = { urlRequest in
            guard let bodyData = urlRequest.bodyData,
                  let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                XCTFail("Failed to read HTTP request body")
                return (HTTPURLResponse(), Data())
            }
            
            guard let tools = bodyJson["tools"] as? [[String: Any]] else {
                XCTFail("Missing tools field")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(tools.count, 1)
            let firstTool = tools[0]
            XCTAssertEqual(firstTool["name"] as? String, "get_weather")
            XCTAssertEqual(firstTool["description"] as? String, "Get the current weather")
            
            guard let inputSchema = firstTool["input_schema"] as? [String: Any] else {
                XCTFail("Missing input_schema field in tool")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(inputSchema["type"] as? String, "object")
            guard let properties = inputSchema["properties"] as? [String: Any] else {
                XCTFail("Missing properties in schema")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertNotNil(properties["location"])
            
            let responseJson: [String: Any] = [
                "id": "msg_02",
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [
                    [
                        "type": "tool_use",
                        "id": "call_get_weather_1",
                        "name": "get_weather",
                        "input": [
                            "location": "Boston"
                        ]
                    ]
                ],
                "usage": [
                    "input_tokens": 50,
                    "output_tokens": 15
                ]
            ]
            
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (httpResponse, responseData)
        }
        
        let response = try await AnthropicClient.generateContent(
            request: request,
            model: "claude-3-5-sonnet",
            apiKey: "test-key-anthropic"
        )
        
        XCTAssertNotNil(response.candidates)
        XCTAssertEqual(response.candidates?.count, 1)
        let firstCandidate = response.candidates?[0]
        XCTAssertEqual(firstCandidate?.content?.parts.count, 1)
        let firstPart = firstCandidate?.content?.parts[0]
        XCTAssertNotNil(firstPart?.functionCall)
        XCTAssertEqual(firstPart?.functionCall?.args["location"], .string("Boston"))
    }
    
    func testAnthropicMultipleToolCalls() async throws {
        let tools = [
            FunctionDeclaration(
                name: "get_weather",
                description: "Get the current weather",
                parameters: Schema(
                    type: "OBJECT",
                    properties: ["location": Schema(type: "STRING", description: "City")],
                    required: ["location"]
                )
            ),
            FunctionDeclaration(
                name: "get_time",
                description: "Get the current time",
                parameters: Schema(
                    type: "OBJECT",
                    properties: ["location": Schema(type: "STRING", description: "City")],
                    required: ["location"]
                )
            )
        ]
        
        let request = GeminiRequest(
            contents: [Content(role: "user", parts: [Part(text: "What is the weather and time in Boston?", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])],
            systemInstruction: nil,
            tools: [Tool(functionDeclarations: tools)]
        )
        
        MockURLProtocol.handler = { urlRequest in
            let responseJson: [String: Any] = [
                "id": "msg_03",
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [
                    [
                        "type": "tool_use",
                        "id": "call_1",
                        "name": "get_weather",
                        "input": [
                            "location": "Boston"
                        ]
                    ],
                    [
                        "type": "tool_use",
                        "id": "call_2",
                        "name": "get_time",
                        "input": [
                            "location": "Boston"
                        ]
                    ]
                ],
                "usage": [
                    "input_tokens": 50,
                    "output_tokens": 30
                ]
            ]
            
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (httpResponse, responseData)
        }
        
        let response = try await AnthropicClient.generateContent(
            request: request,
            model: "claude-3-5-sonnet",
            apiKey: "test-key-anthropic"
        )
        
        XCTAssertNotNil(response.candidates)
        XCTAssertEqual(response.candidates?.count, 1)
        let firstCandidate = response.candidates?[0]
        XCTAssertEqual(firstCandidate?.content?.parts.count, 2)
        
        let firstPart = firstCandidate?.content?.parts[0]
        XCTAssertEqual(firstPart?.functionCall?.name, "get_weather")
        XCTAssertEqual(firstPart?.functionCall?.id, "call_1")
        
        let secondPart = firstCandidate?.content?.parts[1]
        XCTAssertEqual(secondPart?.functionCall?.name, "get_time")
        XCTAssertEqual(secondPart?.functionCall?.id, "call_2")
    }
    
    func testAnthropicMultiTurnRoundTrip() async throws {
        let history = [
            Content(role: "user", parts: [Part(text: "What is 5 + 5?", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]),
            Content(role: "model", parts: [Part(text: nil, functionCall: FunctionCall(name: "calculate", args: ["equation": .string("5+5")], id: "call_1"), functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]),
            Content(role: "user", parts: [Part(text: nil, functionCall: nil, functionResponse: FunctionResponse(name: "calculate", response: ["result": .string("10")], id: "call_1"), thought_signature: nil, thoughtSignature: nil)])
        ]
        
        let request = GeminiRequest(
            contents: history,
            systemInstruction: nil,
            tools: nil
        )
        
        MockURLProtocol.handler = { urlRequest in
            guard let bodyData = urlRequest.bodyData,
                  let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let messages = bodyJson["messages"] as? [[String: Any]] else {
                XCTFail("Failed to read HTTP request body")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(messages.count, 3)
            
            // Turn 1: user text
            XCTAssertEqual(messages[0]["role"] as? String, "user")
            
            // Turn 2: model tool_use
            XCTAssertEqual(messages[1]["role"] as? String, "assistant")
            let modelContent = messages[1]["content"] as? [[String: Any]]
            XCTAssertEqual(modelContent?.count, 1)
            XCTAssertEqual(modelContent?[0]["type"] as? String, "tool_use")
            XCTAssertEqual(modelContent?[0]["id"] as? String, "call_1")
            XCTAssertEqual(modelContent?[0]["name"] as? String, "calculate")
            let input = modelContent?[0]["input"] as? [String: Any]
            XCTAssertEqual(input?["equation"] as? String, "5+5")
            // One turn entry, at index 0: nothing precedes it, so the only message marker is the
            // last block (5a final review item 1; see AnthropicCacheBreakpointTests).
            XCTAssertNil(modelContent?[0]["cache_control"], "a within-turn tool_use is not a turn boundary")
            
            // Turn 3: user tool_result
            XCTAssertEqual(messages[2]["role"] as? String, "user")
            let userContent = messages[2]["content"] as? [[String: Any]]
            XCTAssertEqual(userContent?.count, 1)
            XCTAssertEqual(userContent?[0]["type"] as? String, "tool_result")
            XCTAssertEqual(userContent?[0]["tool_use_id"] as? String, "call_1")
            XCTAssertEqual((userContent?[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral",
                           "the last block is marked even when it is a tool_result (5a §1)")
            
            let responseJson: [String: Any] = [
                "id": "msg_04",
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [
                    [
                        "type": "text",
                        "text": "The result is 10."
                    ]
                ],
                "usage": ["input_tokens": 10, "output_tokens": 10]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let response = try await AnthropicClient.generateContent(
            request: request,
            model: "claude-3-5-sonnet",
            apiKey: "test"
        )
        
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "The result is 10.")
    }
    
    func testAnthropicErrorPropagation() async throws {
        let request = GeminiRequest(
            contents: [Content(role: "user", parts: [Part(text: "Hello", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])],
            systemInstruction: nil,
            tools: nil
        )
        
        MockURLProtocol.handler = { urlRequest in
            let httpResponse = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            let errorJson = ["error": ["type": "invalid_request_error", "message": "API key is invalid"]]
            let responseData = try! JSONSerialization.data(withJSONObject: errorJson)
            return (httpResponse, responseData)
        }
        
        do {
            _ = try await AnthropicClient.generateContent(
                request: request,
                model: "claude-3-5-sonnet",
                apiKey: "test-key-anthropic"
            )
            XCTFail("Expected an error to be thrown")
        } catch let error as APIError {
            XCTAssertTrue(error.localizedDescription.contains("Anthropic HTTP 400"))
            XCTAssertTrue(error.localizedDescription.contains("API key is invalid"))
        } catch {
            XCTFail("Expected APIError, got \(error)")
        }
    }
    
    func testAnthropicBaseURLOverride() async throws {
        let request = GeminiRequest(
            contents: [Content(role: "user", parts: [Part(text: "Hello", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])],
            systemInstruction: nil,
            tools: nil
        )
        
        let customBaseURL = "https://custom.anthropic.endpoint.com/v1"
        
        MockURLProtocol.handler = { urlRequest in
            XCTAssertEqual(urlRequest.url?.absoluteString, "https://custom.anthropic.endpoint.com/v1/messages")
            
            let responseJson: [String: Any] = [
                "id": "msg_05",
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [["type": "text", "text": "Hi!"]],
                "usage": ["input_tokens": 10, "output_tokens": 10]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let response = try await AnthropicClient.generateContent(
            request: request,
            model: "claude-3-5-sonnet",
            apiKey: "test-key",
            baseURL: customBaseURL
        )
        
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "Hi!")
    }
    func testMultiTurnToolCallRoundTrip() async throws {
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "What is the weather?")]),
                Content(role: "model", parts: [
                    Part(functionCall: FunctionCall(name: "get_weather", args: ["location": JSONValue.string("Seattle")]))
                ]),
                Content(role: "user", parts: [
                    Part(functionResponse: FunctionResponse(name: "get_weather", response: ["temperature": JSONValue.string("70F")]))
                ])
            ]
        )
        
        let expectation = XCTestExpectation(description: "Anthropic API request made with correct multi-turn format and cache_control markers")
        
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            
            let bodyData: Data
            if let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) } else { break }
                }
                buffer.deallocate()
                stream.close()
                bodyData = data
            } else {
                bodyData = request.httpBody ?? Data()
            }
            
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let messages = json["messages"] as? [[String: Any]] {
                
                // Expect 3 messages: user, assistant, user
                XCTAssertEqual(messages.count, 3)
                
                // 1. First message: user
                let msg0 = messages[0]
                XCTAssertEqual(msg0["role"] as? String, "user")
                
                // 2. Second message: assistant
                let msg1 = messages[1]
                XCTAssertEqual(msg1["role"] as? String, "assistant")
                guard let msg1Content = msg1["content"] as? [[String: Any]], msg1Content.count > 0 else {
                    XCTFail("Assistant message should have content")
                    return (HTTPURLResponse(), Data())
                }
                
                let toolUseBlock = msg1Content.last!
                XCTAssertEqual(toolUseBlock["type"] as? String, "tool_use")
                XCTAssertEqual(toolUseBlock["name"] as? String, "get_weather")
                
                // A within-turn tool_use is not a turn boundary, so it carries no marker
                XCTAssertNil(toolUseBlock["cache_control"])
                
                // Extract the tool_use_id that was synthesized
                let synthesizedId = toolUseBlock["id"] as? String
                XCTAssertNotNil(synthesizedId)
                
                // 3. Third message: user (tool_result)
                let msg2 = messages[2]
                XCTAssertEqual(msg2["role"] as? String, "user")
                guard let msg2Content = msg2["content"] as? [[String: Any]], msg2Content.count > 0 else {
                    XCTFail("User tool_result message should have content")
                    return (HTTPURLResponse(), Data())
                }
                
                let toolResultBlock = msg2Content.last!
                XCTAssertEqual(toolResultBlock["type"] as? String, "tool_result")
                XCTAssertEqual(toolResultBlock["tool_use_id"] as? String, synthesizedId, "tool_result block must match the tool_use_id of the preceding functionCall")
                
                // The last block is marked even when it is a tool_result (5a §1)
                let cacheControl2 = toolResultBlock["cache_control"] as? [String: String]
                XCTAssertEqual(cacheControl2?["type"], "ephemeral")
                
                expectation.fulfill()
            } else {
                XCTFail("Failed to parse request body")
            }
            
            let responseJson: [String: Any] = [
                "id": UUID().uuidString,
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [
                    ["type": "text", "text": "It is 70F in Seattle."]
                ],
                "usage": ["input_tokens": 10, "output_tokens": 10]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        _ = try await AnthropicClient.generateContent(
            request: request,
            model: "claude-3-5-sonnet",
            apiKey: "test-key",
            baseURL: ""
        )
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testAnthropicInlineDataPayloadFormat() async throws {
        let part = Part(text: "Look at this image", inlineData: InlineData(mimeType: "image/png", data: "b64data"))
        let content = Content(role: "user", parts: [part])
        let request = GeminiRequest(contents: [content])
        
        MockURLProtocol.handler = { urlRequest in
            guard let bodyData = urlRequest.bodyData,
                  let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let messages = bodyJson["messages"] as? [[String: Any]],
                  let firstMessage = messages.first,
                  let contentBlocks = firstMessage["content"] as? [[String: Any]] else {
                XCTFail("Failed to parse request body or content blocks array")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(firstMessage["role"] as? String, "user")
            XCTAssertEqual(contentBlocks.count, 2)
            
            XCTAssertEqual(contentBlocks[0]["type"] as? String, "text")
            XCTAssertEqual(contentBlocks[0]["text"] as? String, "Look at this image")
            
            XCTAssertEqual(contentBlocks[1]["type"] as? String, "image")
            if let sourceDict = contentBlocks[1]["source"] as? [String: Any] {
                XCTAssertEqual(sourceDict["type"] as? String, "base64")
                XCTAssertEqual(sourceDict["media_type"] as? String, "image/png")
                XCTAssertEqual(sourceDict["data"] as? String, "b64data")
            } else {
                XCTFail("Missing source dictionary")
            }
            
            let responseJson: [String: Any] = [
                "id": "msg_img",
                "type": "message",
                "role": "assistant",
                "model": "claude-3-5-sonnet",
                "content": [["type": "text", "text": "I see the image."]],
                "usage": ["input_tokens": 100, "output_tokens": 10]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let response = try await AnthropicClient.generateContent(
            request: request,
            model: "claude-3-5-sonnet",
            apiKey: "test-key"
        )
        
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "I see the image.")
    }

    // MARK: - #181 Vertex AI transport, end to end through the client

    func testVertexGenerateContentGoesThroughTheTransportAndKeepsCacheUsage() async throws {
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        MockURLProtocol.handler = { urlRequest in
            XCTAssertEqual(urlRequest.url?.absoluteString, "https://aiplatform.googleapis.com/v1/projects/gke-claude-dev/locations/global/publishers/anthropic/models/claude-haiku-4-5@20251001:rawPredict")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer ya29.t")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-goog-user-project"), "gke-claude-dev")
            XCTAssertNil(urlRequest.value(forHTTPHeaderField: "x-api-key"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.bodyData)) as? [String: Any])
            XCTAssertEqual(body["anthropic_version"] as? String, "vertex-2023-10-16")
            XCTAssertNil(body["model"])
            let reply = #"{"model":"claude-haiku-4-5-20251001","id":"msg_vrtx_011","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":14,"cache_creation_input_tokens":50,"cache_read_input_tokens":900,"output_tokens":4}}"#
            return (HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(reply.utf8))
        }
        let response = try await AnthropicClient.generateContent(
            request: request, model: "claude-haiku-4-5-20251001",
            transport: .vertex(project: "gke-claude-dev", location: "global", accessToken: "ya29.t"))
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "ok")
        XCTAssertEqual(response.usageMetadata?.cacheReadTokens, 900)
        XCTAssertEqual(response.usageMetadata?.cacheWriteTokens, 50)
        XCTAssertEqual(response.usageMetadata?.promptTokenCount, 964)
        XCTAssertEqual(response.usageMetadata?.totalTokenCount, 968)
    }

    func testVertexStreamGoesThroughTheTransportAndKeepsCacheUsage() async throws {
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_vrtx_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":14,"cache_creation_input_tokens":50,"cache_read_input_tokens":900,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        MockURLProtocol.handler = { urlRequest in
            XCTAssertTrue(urlRequest.url?.absoluteString.hasSuffix("/models/claude-sonnet-5:streamRawPredict") == true)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.bodyData)) as? [String: Any])
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["anthropic_version"] as? String, "vertex-2023-10-16")
            return (HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
        }
        var assembler = StreamAssembler()
        let stream = AnthropicClient.streamContent(request: request, model: "claude-sonnet-5") {
            .vertex(project: "gke-claude-dev", location: "global", accessToken: "ya29.t")
        }
        for try await event in stream { assembler.apply(event, now: 0) }
        let response = assembler.response()
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "ok")
        XCTAssertEqual(response.usageMetadata?.cacheReadTokens, 900)
        XCTAssertEqual(response.usageMetadata?.cacheWriteTokens, 50)
        XCTAssertEqual(response.usageMetadata?.promptTokenCount, 964)
    }

    func testVertexHTTPErrorNamesVertexAndTheLocation() async {
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        MockURLProtocol.handler = { urlRequest in
            (HTTPURLResponse(url: urlRequest.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":{"code":404,"message":"Publisher Model not found","status":"NOT_FOUND"}}"#.utf8))
        }
        do {
            _ = try await AnthropicClient.generateContent(request: request, model: "claude-sonnet-5",
                                                          transport: .vertex(project: "test-project", location: "us-east5", accessToken: "t"))
            XCTFail("expected a 404")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertTrue(error.message.contains("Anthropic (Vertex AI, us-east5)"), error.message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}