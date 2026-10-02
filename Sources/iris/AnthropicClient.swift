import Foundation

struct AnthropicClient {
    /// The full request for one call. `stream` adds the provider's streaming switch and nothing else.
    static func makeURLRequest(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "", stream: Bool) throws -> URLRequest {
        guard !apiKey.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        
        var anthropicMessages: [[String: Any]] = []
        var systemPrompt = ""
        
        if let sysInst = request.systemInstruction, let text = sysInst.parts.first?.text {
            systemPrompt = text
        }
        
        var callIdCounter = 0
        var pendingIdsForName: [String: [String]] = [:]
        
        for content in request.contents {
            let role = content.role == "model" ? "assistant" : "user"
            var partsArray: [[String: Any]] = []
            
            for part in content.parts {
                if let text = part.text {
                    partsArray.append(["type": "text", "text": text])
                }
                if let inline = part.inlineData {
                    partsArray.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": inline.mimeType,
                            "data": inline.data
                        ]
                    ])
                }
                if let fc = part.functionCall {
                    let id = fc.id ?? "call_\(fc.name)_\(callIdCounter)"
                    callIdCounter += 1
                    pendingIdsForName[fc.name, default: []].append(id)
                    
                    partsArray.append([
                        "type": "tool_use",
                        "id": id,
                        "name": fc.name,
                        "input": fc.args.mapValues { $0.anyValue }
                    ])
                } else if let fr = part.functionResponse {
                    let id: String
                    if let existingId = fr.id {
                        id = existingId
                    } else if var pending = pendingIdsForName[fr.name], !pending.isEmpty {
                        id = pending.removeFirst()
                        pendingIdsForName[fr.name] = pending
                    } else {
                        id = "call_\(fr.name)_0"
                    }
                    let respData = try? JSONSerialization.data(withJSONObject: fr.response.mapValues { $0.anyValue }, options: [.sortedKeys])
                    let respString = String(data: respData ?? Data(), encoding: .utf8) ?? "{}"
                    
                    partsArray.append([
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": respString
                    ])
                }
            }
            
            if !partsArray.isEmpty {
                anthropicMessages.append([
                    "role": role,
                    "content": partsArray
                ])
            }
        }

        // Cache breakpoints. The API allows four `cache_control` markers, and a request reads
        // the cache only at a marked block or within the 20 blocks before one. The four are:
        //  (a) system: the prefix of tools + system. Tools render before system, so this one
        //      marker covers both; no separate last-tool marker (the tool takes it only when
        //      there is no system block).
        //  (b) the last message before the previous turn's entry, i.e. the end of turn k-2. This
        //      is the read point: turn k-1 sent its own entry with a turn-context block that is
        //      gone now, so nothing from turn k-1 onward can match, and the end of turn k-2 is
        //      the longest prefix that can. Turn k-1 wrote it with marker (c). It is explicit
        //      because a tool-heavy turn k-1 puts it beyond the 20-block lookback from (c).
        //  (c) the last message before this turn's entry, i.e. the end of turn k-1. It misses
        //      now and is written, so that the next turn reads it as its (b).
        //  (d) the last message: each round within a turn reads the previous round's (d) and
        //      writes its own. A `tool_result` is marked like any block; skipping it put the
        //      write at the `tool_use` and re-sent the results uncached (5a §1).
        // A turn's entry is a `user` message with at least one non-`tool_result` block: typed
        // input, a system event, a reprompt. A mid-turn steer that rides its own entry qualifies
        // too, which moves (b)/(c) to the steer; that costs at most one turn of reuse, and only
        // on the turn after a steer. With fewer than two entries the missing markers are skipped.
        let ephemeral: [String: Any] = ["cache_control": ["type": "ephemeral"]]
        func markLastContentBlock(_ messages: inout [[String: Any]], at index: Int) {
            var msg = messages[index]
            if var content = msg["content"] as? [[String: Any]], !content.isEmpty {
                content[content.count - 1].merge(ephemeral) { _, new in new }
                msg["content"] = content
                messages[index] = msg
            }
        }
        let turnEntries = anthropicMessages.indices.filter { i in
            guard anthropicMessages[i]["role"] as? String == "user",
                  let content = anthropicMessages[i]["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["type"] as? String != "tool_result" }
        }
        var marked = Set<Int>()
        if turnEntries.count >= 2, turnEntries[turnEntries.count - 2] > 0 {
            marked.insert(turnEntries[turnEntries.count - 2] - 1)   // (b)
        }
        if let current = turnEntries.last, current > 0 {
            marked.insert(current - 1)                              // (c)
        }
        if !anthropicMessages.isEmpty {
            marked.insert(anthropicMessages.count - 1)              // (d)
        }
        for index in marked.sorted() {
            markLastContentBlock(&anthropicMessages, at: index)
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": anthropicMessages
        ]
        
        if !systemPrompt.isEmpty {
            body["system"] = [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]]
        }
        
        if let tools = request.tools, let fds = tools.first?.functionDeclarations {
            var anthropicTools = [[String: Any]]()
            for fd in fds {
                var inputSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
                if let schema = fd.parameters {
                    let schemaEncoder = JSONEncoder()
                    schemaEncoder.outputFormatting = [.sortedKeys]
                    let schemaData = try? schemaEncoder.encode(schema)
                    if var dict = try? JSONSerialization.jsonObject(with: schemaData ?? Data()) as? [String: Any] {
                        // Gemini often uses uppercase types (e.g. "OBJECT", "STRING").
                        // JSON Schema (Anthropic) requires lowercase.
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
                        inputSchema = dict
                    }
                }
                anthropicTools.append([
                    "name": fd.name,
                    "description": fd.description,
                    "input_schema": inputSchema
                ])
            }
            if !anthropicTools.isEmpty {
                // Marker (a) sits on system, which covers the tools; only without one do the
                // tools need their own.
                if systemPrompt.isEmpty {
                    anthropicTools[anthropicTools.count - 1]["cache_control"] = ["type": "ephemeral"]
                }
                body["tools"] = anthropicTools
            }
        }
        
        if stream { body["stream"] = true }

        var endpointUrl = "https://api.anthropic.com/v1/messages"
        if !baseURL.isEmpty {
            if baseURL.hasSuffix("/messages") {
                endpointUrl = baseURL
            } else {
                let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                endpointUrl = "\(trimmed)/messages"
            }
        }
        
        guard let url = URL(string: endpointUrl) else {
            throw APIError(message: "Invalid baseURL configuration: \(endpointUrl)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        LLMRequestPolicy.apply(to: &urlRequest)
        return urlRequest
    }

    /// One streamed call: the same request with the streaming switch on, mapped to stream events.
    static func streamContent(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "") -> AsyncThrowingStream<LLMStreamEvent, Error> {
        LLMStreaming.stream(provider: "Anthropic", mapper: AnthropicStreamMapper()) {
            try makeURLRequest(request: request, model: model, apiKey: apiKey, baseURL: baseURL, stream: true)
        }
    }

    static func generateContent(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "") async throws -> GeminiResponse {
        let urlRequest = try makeURLRequest(request: request, model: model, apiKey: apiKey, baseURL: baseURL, stream: false)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if httpResponse.statusCode != 200 {
            print("API Error (\(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")")
            throw APIError.http(provider: "Anthropic", statusCode: httpResponse.statusCode, body: data,
                                headers: httpResponse.allHeaderFields)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try parseResponse(json)
    }

    /// Anthropic's non-stream Messages response back to `GeminiResponse`. `usage.input_tokens`
    /// alone undercounts the prompt: a cache hit or write moves tokens into
    /// `cache_read_input_tokens` / `cache_creation_input_tokens`, so `promptTokenCount` is their
    /// sum (5a §0.4). Anthropic never sends a total, so `.withTotal()` fills one from prompt +
    /// output — otherwise the job budgets, which read the total, charge these runs nothing.
    static func parseResponse(_ json: [String: Any]) throws -> GeminiResponse {
        var geminiResponse = GeminiResponse()
        geminiResponse.candidates = []

        if let contentArray = json["content"] as? [[String: Any]] {
            var content = Content(role: "model", parts: [])

            for part in contentArray {
                if let type = part["type"] as? String {
                    if type == "text", let text = part["text"] as? String {
                        content.parts.append(Part(text: text, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil))
                    } else if type == "tool_use", let id = part["id"] as? String, let name = part["name"] as? String, let input = part["input"] as? [String: Any] {
                        var jsonArgs: [String: JSONValue] = [:]
                        if let data = try? JSONSerialization.data(withJSONObject: input),
                           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                            jsonArgs = decoded
                        }
                        content.parts.append(Part(text: nil, functionCall: FunctionCall(name: name, args: jsonArgs, id: id, thought_signature: nil, thoughtSignature: nil), functionResponse: nil, thought_signature: nil, thoughtSignature: nil))
                    }
                }
            }

            if !content.parts.isEmpty {
                geminiResponse.candidates?.append(Candidate(content: content))
            }
        }

        if let usage = json["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int
            let cacheRead = usage["cache_read_input_tokens"] as? Int
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int
            // nil, not 0, when all three are absent: an unreported input must not become a
            // confident zero that `withTotal()` then bakes into a confident total (5a review F6).
            let prompt = UsageMetadata.anthropicPromptTokenCount(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite)
            geminiResponse.usageMetadata = UsageMetadata(
                promptTokenCount: prompt,
                candidatesTokenCount: usage["output_tokens"] as? Int,
                totalTokenCount: nil,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite
            ).withTotal()
        }

        return geminiResponse
    }
}
