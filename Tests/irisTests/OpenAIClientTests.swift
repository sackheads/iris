import XCTest
@testable import IrisKit

final class OpenAIClientTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    
    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }
    
    func testOpenAIRequestTranslationText() async throws {
        let request = GeminiRequest(
            contents: [
                Content(role: "user", parts: [Part(text: "Hello, GPT", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
            ],
            systemInstruction: Content(role: "system", parts: [Part(text: "Act as a helpful helper", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]),
            tools: nil
        )
        
        MockURLProtocol.handler = { urlRequest in
            XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
            XCTAssertEqual(urlRequest.httpMethod, "POST")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-openai")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
            
            guard let bodyData = urlRequest.bodyData,
                  let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                XCTFail("Failed to read HTTP request body")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(bodyJson["model"] as? String, "gpt-4o")
            
            guard let messages = bodyJson["messages"] as? [[String: Any]] else {
                XCTFail("Missing messages field in OpenAI body")
                return (HTTPURLResponse(), Data())
            }
            
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages[0]["role"] as? String, "system")
            XCTAssertEqual(messages[0]["content"] as? String, "Act as a helpful helper")
            
            XCTAssertEqual(messages[1]["role"] as? String, "user")
            XCTAssertEqual(messages[1]["content"] as? String, "Hello, GPT")
            
            let responseJson: [String: Any] = [
                "id": "chatcmpl-001",
                "object": "chat.completion",
                "created": 123456789,
                "model": "gpt-4o",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                          "role": "assistant",
                          "content": "Hi! How can I assist you?"
                        ],
                        "finish_reason": "stop"
                    ]
                ],
                "usage": [
                    "prompt_tokens": 15,
                    "completion_tokens": 10,
                    "total_tokens": 25
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
        
        let response = try await OpenAIClient.generateContent(
            request: request,
            model: "gpt-4o",
            apiKey: "test-key-openai"
        )
        
        XCTAssertNotNil(response.candidates)
        XCTAssertEqual(response.candidates?.count, 1)
        let firstCandidate = response.candidates?[0]
        XCTAssertEqual(firstCandidate?.content?.parts.count, 1)
        XCTAssertEqual(firstCandidate?.content?.parts[0].text, "Hi! How can I assist you?")
        
        XCTAssertEqual(response.usageMetadata?.promptTokenCount, 15)
        XCTAssertEqual(response.usageMetadata?.candidatesTokenCount, 10)
        XCTAssertEqual(response.usageMetadata?.totalTokenCount, 25)
    }
    
    func testOpenAIRequestTranslationTools() async throws {
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
            XCTAssertEqual(firstTool["type"] as? String, "function")
            
            guard let function = firstTool["function"] as? [String: Any] else {
                XCTFail("Missing function subfield in tool")
                return (HTTPURLResponse(), Data())
            }
            XCTAssertEqual(function["name"] as? String, "get_weather")
            XCTAssertEqual(function["description"] as? String, "Get the current weather")
            
            guard let parameters = function["parameters"] as? [String: Any] else {
                XCTFail("Missing parameters schema in tool function")
                return (HTTPURLResponse(), Data())
            }
            XCTAssertEqual(parameters["type"] as? String, "object")
            
            let responseJson: [String: Any] = [
                "id": "chatcmpl-002",
                "object": "chat.completion",
                "model": "gpt-4o",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "tool_calls": [
                                [
                                    "id": "call_get_weather_1",
                                    "type": "function",
                                    "function": [
                                        "name": "get_weather",
                                        "arguments": "{\"location\":\"Boston\"}"
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                "usage": [
                    "prompt_tokens": 42,
                    "completion_tokens": 12,
                    "total_tokens": 54
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
        
        let response = try await OpenAIClient.generateContent(
            request: request,
            model: "gpt-4o",
            apiKey: "test-key-openai"
        )
        
        XCTAssertNotNil(response.candidates)
        XCTAssertEqual(response.candidates?.count, 1)
        let firstCandidate = response.candidates?[0]
        XCTAssertEqual(firstCandidate?.content?.parts.count, 1)
        let firstPart = firstCandidate?.content?.parts[0]
        XCTAssertNotNil(firstPart?.functionCall)
        XCTAssertEqual(firstPart?.functionCall?.name, "get_weather")
        XCTAssertEqual(firstPart?.functionCall?.args["location"], .string("Boston"))
    }
    
    func testOpenAIMultipleToolCalls() async throws {
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
                "id": "chatcmpl-multi",
                "object": "chat.completion",
                "model": "gpt-4o",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "tool_calls": [
                                [
                                    "id": "call_1",
                                    "type": "function",
                                    "function": [
                                        "name": "get_weather",
                                        "arguments": "{\"location\":\"Boston\"}"
                                    ]
                                ],
                                [
                                    "id": "call_2",
                                    "type": "function",
                                    "function": [
                                        "name": "get_time",
                                        "arguments": "{\"location\":\"Boston\"}"
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                "usage": [
                    "prompt_tokens": 50,
                    "completion_tokens": 20,
                    "total_tokens": 70
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
        
        let response = try await OpenAIClient.generateContent(
            request: request,
            model: "gpt-4o",
            apiKey: "test-key-openai"
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
    
    
    func testOpenAIMultiTurnRoundTrip() async throws {
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
            
            // Turn 2: model tool_calls
            XCTAssertEqual(messages[1]["role"] as? String, "assistant")
            let toolCalls = messages[1]["tool_calls"] as? [[String: Any]]
            XCTAssertEqual(toolCalls?.count, 1)
            XCTAssertEqual(toolCalls?[0]["type"] as? String, "function")
            XCTAssertEqual(toolCalls?[0]["id"] as? String, "call_1")
            
            let functionDict = toolCalls?[0]["function"] as? [String: Any]
            XCTAssertEqual(functionDict?["name"] as? String, "calculate")
            let argumentsString = functionDict?["arguments"] as? String
            
            let argsData = argumentsString?.data(using: .utf8) ?? Data()
            let argsJson = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any]
            XCTAssertEqual(argsJson?["equation"] as? String, "5+5")
            
            // Turn 3: tool message
            XCTAssertEqual(messages[2]["role"] as? String, "tool")
            XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_1")
            let contentString = messages[2]["content"] as? String
            let contentData = contentString?.data(using: .utf8) ?? Data()
            let contentJson = (try? JSONSerialization.jsonObject(with: contentData)) as? [String: Any]
            XCTAssertEqual(contentJson?["result"] as? String, "10")
            
            let responseJson: [String: Any] = [
                "id": "chatcmpl-123",
                "object": "chat.completion",
                "created": 1677652288,
                "model": "gpt-4o",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": "The result is 10."
                        ],
                        "finish_reason": "stop"
                    ]
                ],
                "usage": [
                    "prompt_tokens": 10,
                    "completion_tokens": 10,
                    "total_tokens": 20
                ]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let response = try await OpenAIClient.generateContent(
            request: request,
            model: "gpt-4o",
            apiKey: "test"
        )
        
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "The result is 10.")
    }
    
    func testOpenAIErrorPropagation() async throws {
        let request = GeminiRequest(
            contents: [Content(role: "user", parts: [Part(text: "Hello", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])],
            systemInstruction: nil,
            tools: nil
        )
        
        MockURLProtocol.handler = { urlRequest in
            let httpResponse = HTTPURLResponse(
                url: urlRequest.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            let errorJson = ["error": ["message": "Incorrect API key provided.", "type": "invalid_request_error"]]
            let responseData = try! JSONSerialization.data(withJSONObject: errorJson)
            return (httpResponse, responseData)
        }
        
        do {
            _ = try await OpenAIClient.generateContent(
                request: request,
                model: "gpt-4o",
                apiKey: "test-key-openai"
            )
            XCTFail("Expected an error to be thrown")
        } catch let error as APIError {
            XCTAssertTrue(error.localizedDescription.contains("OpenAI HTTP 401"))
            XCTAssertTrue(error.localizedDescription.contains("Incorrect API key provided."))
        } catch {
            XCTFail("Expected APIError, got \(error)")
        }
    }
    
    func testOpenAIBaseURLOverride() async throws {
        let request = GeminiRequest(
            contents: [Content(role: "user", parts: [Part(text: "Hello", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])],
            systemInstruction: nil,
            tools: nil
        )
        
        let customBaseURL = "https://custom.openai.endpoint.com/v1"
        
        MockURLProtocol.handler = { urlRequest in
            XCTAssertEqual(urlRequest.url?.absoluteString, "https://custom.openai.endpoint.com/v1/chat/completions")
            
            let responseJson: [String: Any] = [
                "id": "chatcmpl-123",
                "object": "chat.completion",
                "created": 1677652288,
                "model": "gpt-4o",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": "Hi!"
                        ],
                        "finish_reason": "stop"
                    ]
                ],
                "usage": ["prompt_tokens": 9, "completion_tokens": 12, "total_tokens": 21]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let response = try await OpenAIClient.generateContent(
            request: request,
            model: "gpt-4o",
            apiKey: "test-key",
            baseURL: customBaseURL
        )
        
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "Hi!")
    }
    
    func testOpenAIInlineDataPayloadFormat() async throws {
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
            
            XCTAssertEqual(contentBlocks[1]["type"] as? String, "image_url")
            if let imageUrlDict = contentBlocks[1]["image_url"] as? [String: Any] {
                XCTAssertEqual(imageUrlDict["url"] as? String, "data:image/png;base64,b64data")
            } else {
                XCTFail("Missing image_url dictionary")
            }
            
            let responseJson: [String: Any] = [
                "id": "chatcmpl-img",
                "object": "chat.completion",
                "model": "gpt-4o",
                "choices": [
                    [
                        "index": 0,
                        "message": ["role": "assistant", "content": "I see the image."],
                        "finish_reason": "stop"
                    ]
                ],
                "usage": ["prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: responseJson)
            let httpResponse = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, responseData)
        }
        
        let response = try await OpenAIClient.generateContent(
            request: request,
            model: "gpt-4o",
            apiKey: "test-key"
        )
        
        XCTAssertEqual(response.candidates?.first?.content?.parts.first?.text, "I see the image.")
    }
}

