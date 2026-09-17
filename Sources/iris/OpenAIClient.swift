import Foundation

struct OpenAIClient {
    static func generateContent(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "") async throws -> GeminiResponse {
        guard !apiKey.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        
        var openAIMessages: [[String: Any]] = []
        
        if let sysInst = request.systemInstruction, let text = sysInst.parts.first?.text {
            openAIMessages.append([
                "role": "system",
                "content": text
            ])
        }
        
        var callIdCounter = 0
        var pendingIdsForName: [String: [String]] = [:]
        
        for content in request.contents {
            let role = content.role == "model" ? "assistant" : "user"
            var message: [String: Any] = ["role": role]
            var textParts = [String]()
            var messageContentBlocks = [[String: Any]]()
            var hasInlineData = false
            var toolCalls = [[String: Any]]()
            var toolResponses = [[String: Any]]()
            
            var reasoningContent: String? = nil
            
            for part in content.parts {
                if let r = part.thought_signature ?? part.thoughtSignature, !r.isEmpty {
                    reasoningContent = r
                }
                
                if let text = part.text {
                    textParts.append(text)
                    messageContentBlocks.append(["type": "text", "text": text])
                }
                if let inline = part.inlineData {
                    hasInlineData = true
                    messageContentBlocks.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(inline.mimeType);base64,\(inline.data)"]
                    ])
                }
                if let fc = part.functionCall {
                    let id = fc.id ?? "call_\(fc.name)_\(callIdCounter)"
                    callIdCounter += 1
                    pendingIdsForName[fc.name, default: []].append(id)
                    let argsData = try? JSONSerialization.data(withJSONObject: fc.args.mapValues { $0.anyValue })
                    let argsString = String(data: argsData ?? Data(), encoding: .utf8) ?? "{}"
                    
                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": fc.name,
                            "arguments": argsString
                        ]
                    ])
                } else if let fr = part.functionResponse {
                    let id: String
                    if let existingId = fr.id {
                        id = existingId
                    } else if var pending = pendingIdsForName[fr.name], !pending.isEmpty {
                        id = pending.removeFirst()
                        pendingIdsForName[fr.name] = pending
                    } else {
                        id = "call_\(fr.name)_0" // Fallback if no ID is provided
                    }
                    let respData = try? JSONSerialization.data(withJSONObject: fr.response.mapValues { $0.anyValue })
                    let respString = String(data: respData ?? Data(), encoding: .utf8) ?? "{}"
                    
                    toolResponses.append([
                        "role": "tool",
                        "tool_call_id": id,
                        "name": fr.name,
                        "content": respString
                    ])
                }
            }
            
            if hasInlineData {
                message["content"] = messageContentBlocks
            } else if !textParts.isEmpty {
                message["content"] = textParts.joined(separator: "\n")
            } else if toolCalls.isEmpty && toolResponses.isEmpty {
                message["content"] = ""
            }
            
            if let r = reasoningContent {
                message["reasoning_content"] = r
            }
            
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls
            }
            
            let hasContent = message["content"] != nil
            let hasToolCalls = message["tool_calls"] != nil
            
            if hasContent || hasToolCalls || toolResponses.isEmpty {
                openAIMessages.append(message)
            }
            
            for tr in toolResponses {
                openAIMessages.append(tr)
            }
        }
        
        // Removed old name-to-last-id fallback logic as we now preserve the real ID from the backend.
        
        var body: [String: Any] = [
            "model": model,
            "messages": openAIMessages
        ]
        
        if let tools = request.tools, let fds = tools.first?.functionDeclarations {
            var openAITools = [[String: Any]]()
            for fd in fds {
                var parameters: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
                if let schema = fd.parameters {
                    let schemaData = try? JSONEncoder().encode(schema)
                    if var dict = try? JSONSerialization.jsonObject(with: schemaData ?? Data()) as? [String: Any] {
                        func lowerCaseTypes(_ dictionary: inout [String: Any]) {
                            if let type = dictionary["type"] as? String {
                                dictionary["type"] = type.lowercased()
                            }
                            if var properties = dictionary["properties"] as? [String: [String: Any]] {
                                for (k, var v) in properties {
                                    lowerCaseTypes(&v)
                                    properties[k] = v
                                }
                                dictionary["properties"] = properties
                            }
                            if var items = dictionary["items"] as? [String: Any] {
                                lowerCaseTypes(&items)
                                dictionary["items"] = items
                            }
                        }
                        
                        lowerCaseTypes(&dict)
                        parameters = dict
                    }
                }
                openAITools.append([
                    "type": "function",
                    "function": [
                        "name": fd.name,
                        "description": fd.description,
                        "parameters": parameters
                    ]
                ])
            }
            if !openAITools.isEmpty {
                body["tools"] = openAITools
            }
        }
        
        var endpointUrl = "https://api.openai.com/v1/chat/completions"
        if !baseURL.isEmpty {
            if baseURL.hasSuffix("/chat/completions") {
                endpointUrl = baseURL
            } else {
                let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                endpointUrl = "\(trimmed)/chat/completions"
            }
        }
        
        guard let url = URL(string: endpointUrl) else {
            throw APIError(message: "Invalid baseURL configuration: \(endpointUrl)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(message: "Invalid response from OpenAI API")
        }
        
        if httpResponse.statusCode != 200 {
            print("API Error (\(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")")
            throw APIError.http(provider: "OpenAI", statusCode: httpResponse.statusCode, body: data,
                                headers: httpResponse.allHeaderFields)
        }
        
        // Parse OpenAI response back to GeminiResponse
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var geminiResponse = GeminiResponse()
        geminiResponse.candidates = []
        
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first, let msg = first["message"] as? [String: Any] {
            var content = Content(role: "model", parts: [])
            
            let reasoning = msg["reasoning_content"] as? String
            
            if let text = msg["content"] as? String, !text.isEmpty {
                content.parts.append(Part(text: text, functionCall: nil, functionResponse: nil, thought_signature: reasoning, thoughtSignature: reasoning))
            }
            
            if let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let f = call["function"] as? [String: Any], let name = f["name"] as? String, let id = call["id"] as? String, let argsStr = f["arguments"] as? String {
                        let argsDict = (try? JSONDecoder().decode([String: JSONValue].self, from: argsStr.data(using: .utf8) ?? Data())) ?? [:]
                        content.parts.append(Part(text: nil, functionCall: FunctionCall(name: name, args: argsDict, id: id, thought_signature: reasoning, thoughtSignature: reasoning), functionResponse: nil, thought_signature: reasoning, thoughtSignature: reasoning))
                    }
                }
            }
            
            if content.parts.isEmpty {
                // If OpenAI returns content: null and no tool calls, it results in an empty candidate.
                // We add an explicit error message part so the agent loop doesn't just exit silently.
                content.parts.append(Part(text: "Error: The model returned an empty response.", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil))
            }
            
            geminiResponse.candidates?.append(Candidate(content: content))
        }
        
        if let usage = json["usage"] as? [String: Any] {
            geminiResponse.usageMetadata = UsageMetadata(
                promptTokenCount: usage["prompt_tokens"] as? Int,
                candidatesTokenCount: usage["completion_tokens"] as? Int,
                totalTokenCount: usage["total_tokens"] as? Int
            )
        }
        
        return geminiResponse
    }
}
