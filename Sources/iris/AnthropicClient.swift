import Foundation

struct AnthropicClient {
    /// A `cache_control` value. Five minutes is the bare `ephemeral`, byte-identical to pre-5c;
    /// an hour adds `ttl` (no beta header: 5c spec facts).
    static func cacheControl(_ ttl: CacheTTL) -> [String: Any] {
        switch ttl {
        case .fiveMinutes: return ["type": "ephemeral"]
        case .oneHour: return ["type": "ephemeral", "ttl": "1h"]
        }
    }

    /// The full request for one call against `api.anthropic.com` (or a proxy at `baseURL`).
    static func makeURLRequest(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "", stream: Bool) throws -> URLRequest {
        try makeURLRequest(request: request, model: model, transport: .direct(apiKey: apiKey, baseURL: baseURL), stream: stream)
    }

    /// Vertex spells a dated model id with `@` where the API uses `-` (`claude-haiku-4-5-20251001`
    /// is `claude-haiku-4-5@20251001`); bare ids (`claude-sonnet-5`) are the same on both. Applied
    /// in the Vertex transport only, so a tier field can hold the API's spelling for either.
    static func vertexModelID(_ model: String) -> String {
        guard let dash = model.lastIndex(of: "-") else { return model }
        let suffix = model[model.index(after: dash)...]
        guard suffix.count == 8, suffix.allSatisfy(\.isNumber) else { return model }
        return model[..<dash] + "@" + suffix
    }

    /// `max_tokens` per model. It covers thinking as well as the reply, and thinking cannot be
    /// turned off on some models, so a fixed 4096 cut long answers and large tool inputs short.
    /// Source: claude-api skill `shared/models.md`, "Max Output", and the live models overview.
    /// 5.x models get 32000 (all document 128K); older ones their documented max, capped at
    /// 32000. Unknown ids get `fallbackMaxTokens`; every `ModelCatalog` id has a row (tested).
    static let maxTokensByModel: [String: Int] = [
        "claude-fable-5-1": 32_000,
        "claude-mythos-5-1": 32_000,
        "claude-fable-5": 32_000,
        "claude-mythos-5": 32_000,
        "claude-opus-5-5": 32_000,
        "claude-opus-5": 32_000,
        "claude-sonnet-5-5": 32_000,
        "claude-sonnet-5": 32_000,
        "claude-opus-4-8": 32_000,     // 128K
        "claude-opus-4-7": 32_000,     // 128K
        "claude-opus-4-6": 32_000,     // 128K
        "claude-sonnet-4-6": 32_000,   // 128K
        "claude-opus-4-5": 32_000,     // 64K (live models overview; not in the bundled table)
        "claude-haiku-4-5": 32_000,    // 64K
    ]
    /// Retired 3.x ids some clouds still serve: 4096, what Iris always sent them, so they keep
    /// working rather than meeting a 400 above their documented max.
    static let claude3Prefix = "claude-3-"
    static let claude3MaxTokens = 4096
    static let fallbackMaxTokens = 16_000
    /// A non-streaming reply arrives all at once, so it has to finish inside
    /// `LLMRequestPolicy.timeoutSeconds` (180 s); the docs also warn that above ~16K output a
    /// non-streaming request risks an HTTP timeout. 8192 still doubles the old 4096.
    static let nonStreamingMaxTokens = 8192

    /// The table key for a model: the Vertex spelling with its `@date` dropped, so the API's
    /// dated id, Vertex's, and the bare alias all find the same row.
    static func maxTokensKey(_ model: String) -> String {
        let vertex = vertexModelID(model.trimmingCharacters(in: .whitespaces))
        guard let at = vertex.firstIndex(of: "@") else { return vertex }
        return String(vertex[..<at])
    }

    /// `budgetCap` is what a budgeted run can still afford (`GeminiRequest.maxOutputTokens`).
    static func maxTokens(for model: String, stream: Bool, budgetCap: Int? = nil) -> Int {
        let key = maxTokensKey(model)
        var value = maxTokensByModel[key] ?? (key.hasPrefix(claude3Prefix) ? claude3MaxTokens : fallbackMaxTokens)
        if !stream { value = min(value, nonStreamingMaxTokens) }
        if let budgetCap { value = min(value, max(1, budgetCap)) }
        return value
    }

    /// `global` has no regional host; `us`/`eu` are multi-region hosts; anything else is a region.
    static func vertexEndpointURL(project: String, location: String, model: String, stream: Bool) throws -> URL {
        let host = AnthropicVertexTarget(project: project, location: location).host
        let method = stream ? "streamRawPredict" : "rawPredict"
        let string = "https://\(host)/v1/projects/\(project)/locations/\(location)/publishers/anthropic/models/\(vertexModelID(model)):\(method)"
        guard let url = URL(string: string) else { throw APIError(message: "Invalid Vertex AI endpoint: \(string)") }
        return url
    }

    /// The full request for one call. `stream` adds the provider's streaming switch and nothing
    /// else. The transport decides the URL, the auth headers, and whether the model is named in
    /// the body (API) or the path (Vertex, which takes `anthropic_version` in the body instead).
    static func makeURLRequest(request: GeminiRequest, model: String, transport: AnthropicTransport, stream: Bool) throws -> URLRequest {
        switch transport {
        case .direct(let apiKey, _):
            guard !apiKey.isEmpty else { throw URLError(.userAuthenticationRequired) }
        case .vertex(let project, let location, let accessToken):
            guard !project.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw APIError(message: "Anthropic on Vertex AI needs a Google Cloud project.")
            }
            guard AnthropicTransport.isValidProject(project) else {
                throw APIError(message: "Vertex AI project \"\(project)\" is not a valid project id.")
            }
            guard AnthropicTransport.isValidLocation(location) else {
                throw APIError(message: "Vertex AI location \"\(location)\" is not valid: use global, us, eu, or a region such as us-east5.")
            }
            guard !accessToken.isEmpty else { throw URLError(.userAuthenticationRequired) }
        }
        
        var anthropicMessages: [[String: Any]] = []
        var systemPrompt = ""
        
        if let sysInst = request.systemInstruction, let text = sysInst.parts.first?.text {
            systemPrompt = text
        }
        
        var callIdCounter = 0
        var pendingIdsForName: [String: [String]] = [:]
        func register(_ fc: FunctionCall) -> String {
            let id = fc.id ?? "call_\(fc.name)_\(callIdCounter)"
            callIdCounter += 1
            pendingIdsForName[fc.name, default: []].append(id)
            return id
        }

        // #314 decision 2: a reply's stored blocks go out exactly as received. Only a front run is
        // ever dropped: a reply whose blocks cannot be echoed takes every earlier reply's with it,
        // so no gap opens in the middle (PTM §3).
        // Keep this builder a pure function of the whole of `request.contents` (cache markers
        // aside): `ThinkingReplay` compares contents, not bytes, and is only sound while equal
        // contents encode to equal messages. It is not prefix-stable in one case: an unechoable
        // reply above the floor turns every earlier echoed reply back into parts, changing earlier
        // messages' bytes. Such a reply only arrives through a hook rewriting a call, and that
        // request has already diverged.
        let lastUnechoable = request.contents.indices.last {
            request.contents[$0].anthropicBlocks != nil && !AnthropicBlocks.echoable(request.contents[$0])
        }
        let echoFrom = (lastUnechoable ?? -1) + 1
        // Spliced in after serialisation, so the blocks are never re-encoded. The token is unique
        // per request, and in its quoted form it cannot occur inside any other JSON string.
        let spliceToken = "IRIS_ANTHROPIC_BLOCKS_\(UUID().uuidString)_"
        var echoed: [Int: String] = [:]

        for (contentIndex, content) in request.contents.enumerated() {
            let role = content.role == "model" ? "assistant" : "user"
            if contentIndex >= echoFrom, let raw = content.anthropicBlocks {
                for part in content.parts { if let fc = part.functionCall { _ = register(fc) } }
                echoed[anthropicMessages.count] = raw
                anthropicMessages.append(["role": role, "content": spliceToken + String(anthropicMessages.count)])
                continue
            }
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
                    let id = register(fc)
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
        // TTL (5c §0.8): (a) takes the hints' prefix TTL, (b)-(d) their history TTL; no hints is
        // five minutes everywhere, byte-identical to pre-5c. Longer TTLs must precede shorter
        // ones; `CacheTTLPolicy` clamps history to the prefix, so this order always holds.
        let ttl = request.cacheHints?.ttl ?? .standard
        let ephemeral: [String: Any] = ["cache_control": Self.cacheControl(ttl.history)]
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
        var markedEchoes = Set<Int>()
        for index in marked.sorted() {
            // An echoed reply's content is still a token here; its marker is merged after the splice.
            if echoed[index] != nil { markedEchoes.insert(index) } else { markLastContentBlock(&anthropicMessages, at: index) }
        }

        var body: [String: Any] = [
            "max_tokens": Self.maxTokens(for: model, stream: stream, budgetCap: request.maxOutputTokens),
            "messages": anthropicMessages
        ]
        switch transport {
        case .direct: body["model"] = model
        case .vertex: body["anthropic_version"] = AnthropicTransport.vertexAnthropicVersion
        }
        
        if !systemPrompt.isEmpty {
            body["system"] = [["type": "text", "text": systemPrompt, "cache_control": Self.cacheControl(ttl.prefix)]]
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
                    anthropicTools[anthropicTools.count - 1]["cache_control"] = Self.cacheControl(ttl.prefix)
                }
                body["tools"] = anthropicTools
            }
        }
        
        // #314 decisions 4 and 6: the binding field travels only with its header (alone it is a
        // 400, "Extra inputs are not permitted"), and only to a model and route the table says
        // take the beta, unless this is the retry after a binding 400, which proved the model checks.
        // Without the field no `thinking` object is sent at all, as before #314: each model keeps
        // its own default. `block_binding` works only inside adaptive thinking, so the object is
        // adaptive. Opus 5.5 and Fable 5.1 accept nothing but adaptive anyway, so for them it adds
        // only the binding. Sonnet 5.5 is the one whose thinking this changes: Iris otherwise sends
        // it no thinking object, and its `between_tools` mode rejects `block_binding`, so the retry
        // (and every later request of that conversation, while the table says it takes the beta)
        // runs it on adaptive thinking.
        let takesBeta = AnthropicCapabilities.takesBindingBeta(model: model, transport: transport)
        let binding = (takesBeta || request.forceBindingBeta) ? request.prefixMismatchBehavior : nil
        if let binding {
            body["thinking"] = ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": binding.rawValue]] as [String: Any]
        }

        if stream { body["stream"] = true }

        var urlRequest: URLRequest
        switch transport {
        case .direct(let apiKey, let baseURL):
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
            urlRequest = URLRequest(url: url)
            urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .vertex(let project, let location, let accessToken):
            urlRequest = URLRequest(url: try vertexEndpointURL(project: project, location: location, model: model, stream: stream))
            urlRequest.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            // The quota project, as the Gemini ADC path sends it: billing and quota land on the
            // project that serves the model, not on whatever the ADC file names.
            urlRequest.addValue(project, forHTTPHeaderField: "x-goog-user-project")
        }
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // #314 decisions 4-5: the binding beta, to the models and routes known to take it, on the
        // API and Vertex alike, and with the binding field wherever that goes (the retry after a
        // binding 400 reaches any model or route). Without the field it changes no behaviour: an
        // unenforced account lists mismatches in `input_transformations` and keeps the blocks.
        if takesBeta || binding != nil {
            urlRequest.addValue(AnthropicCapabilities.bindingBeta, forHTTPHeaderField: "anthropic-beta")
        }
        var bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        if !echoed.isEmpty {
            let marker = String(decoding: try JSONSerialization.data(withJSONObject: Self.cacheControl(ttl.history),
                                                                     options: [.sortedKeys]), as: UTF8.self)
            var blocksByIndex: [Int: String] = [:]
            for (index, raw) in echoed {
                blocksByIndex[index] = markedEchoes.contains(index) ? AnthropicBlocks.withCacheControl(raw, marker) : raw
            }
            bodyData = splice(bodyData, token: spliceToken, blocks: blocksByIndex)
        }
        urlRequest.httpBody = bodyData

        LLMRequestPolicy.apply(to: &urlRequest)
        return urlRequest
    }

    /// Replaces each quoted `"<token><index>"` in `body` with `blocks[index]`, in one forward pass
    /// (one `replacingOccurrences` per reply rescanned the whole body each time: 262 ms for 30
    /// replies on 1.1 MB). The closing quote keeps `_1` and `_10` apart; an index written any
    /// other way (a leading zero, no closing quote, not in `blocks`) is copied through unchanged.
    static func splice(_ body: Data, token: String, blocks: [Int: String]) -> Data {
        let quote = UInt8(ascii: "\"")
        let needle = Array(("\"" + token).utf8)
        let bytes = [UInt8](body)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + blocks.values.reduce(0) { $0 + $1.utf8.count })
        var copied = 0
        var i = 0
        while i <= bytes.count - needle.count {
            guard bytes[i] == quote, bytes[i..<(i + needle.count)].elementsEqual(needle) else { i += 1; continue }
            var j = i + needle.count
            var index = 0
            while j < bytes.count, j - (i + needle.count) < 18, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[j]) {
                index = index * 10 + Int(bytes[j] - UInt8(ascii: "0"))
                j += 1
            }
            let digits = j - (i + needle.count)
            guard digits > 0, digits == 1 || bytes[i + needle.count] != UInt8(ascii: "0"),
                  j < bytes.count, bytes[j] == quote, let replacement = blocks[index] else { i += 1; continue }
            out.append(contentsOf: bytes[copied..<i])
            out.append(contentsOf: replacement.utf8)
            i = j + 1
            copied = i
        }
        out.append(contentsOf: bytes[copied...])
        return Data(out)
    }

    /// One streamed call: the same request with the streaming switch on, mapped to stream events.
    static func streamContent(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "") -> AsyncThrowingStream<LLMStreamEvent, Error> {
        streamContent(request: request, model: model) { .direct(apiKey: apiKey, baseURL: baseURL) }
    }

    /// `transport` is resolved inside the stream's own task, because the Vertex transport needs
    /// an access token and fetching it is async; a failure there surfaces as the stream's error,
    /// recorded like any other failed call.
    static func streamContent(request: GeminiRequest, model: String, session: URLSession = .shared,
                              transport: @escaping @Sendable () async throws -> AnthropicTransport) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        @Sendable func attempt(_ request: GeminiRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            LLMStreaming.stream(mapper: AnthropicStreamMapper(), session: session) {
                let resolved = try await transport()
                return (try makeURLRequest(request: request, model: model, transport: resolved, stream: true), resolved.providerLabel)
            }
        }
        // A non-200 throws before any event, so a TTL or binding rejection can be retried without
        // the consumer ever seeing half a reply. Only before the first event, and only once: a
        // retry that fails again throws from inside its `catch`, which nothing above catches.
        return AsyncThrowingStream { continuation in
            let task = Task {
                var yielded = false
                do {
                    do {
                        for try await event in attempt(request) { yielded = true; continuation.yield(event) }
                    } catch let error where !yielded && isTTLRejection(error, request: request) {
                        logTTLFallback(error)
                        for try await event in attempt(withoutTTL(request)) { continuation.yield(event) }
                    } catch let error where !yielded && isBindingRejection(error, request: request) {
                        logBindingFallback(error)
                        for try await event in attempt(withDropBlock(request)) { continuation.yield(event) }
                        // Last, once the retry has finished: the event means the retry succeeded,
                        // and the engine raises the floor and persists drop_block on it.
                        continuation.yield(.prefixMismatchFallback)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 5c §0.8 insurance: the API is documented to take `ttl` with no beta header, but if one ever
    /// answers 400 naming it, every Iris turn would fail. Such a rejection is retried once with
    /// every marker at the 5-minute default (no `ttl` at all), which is what pre-5c sent.
    static func isTTLRejection(_ error: Error, request: GeminiRequest) -> Bool {
        // The prefix is never shorter than history, so a request with any 1h marker has a 1h prefix.
        guard let error = error as? APIError, error.statusCode == 400,
              request.cacheHints?.ttl.prefix == .oneHour else { return false }
        let text = (error.message + " " + (error.detail ?? "")).lowercased()
        return text.contains("ttl") || text.contains("cache_control")
    }

    static func withoutTTL(_ request: GeminiRequest) -> GeminiRequest {
        var copy = request
        copy.cacheHints?.ttl = .standard
        return copy
    }

    private static func logTTLFallback(_ error: Error) {
        print("Anthropic rejected a 1-hour cache TTL; retrying once at the 5-minute default: \(error.localizedDescription)")
    }

    /// #314 decision 6: the 400 an enforced account returns for a replayed block whose prefix
    /// changed (MM:1624; the probe confirmed the text). A tampered signature has the same leading
    /// clause without this sentence and is not retried. Never twice: the retry is forced.
    static func isBindingRejection(_ error: Error, request: GeminiRequest) -> Bool {
        guard !request.forceBindingBeta, let error = error as? APIError, error.statusCode == 400 else { return false }
        return (error.message + " " + (error.detail ?? "")).contains("bound to a different conversation")
    }

    static func withDropBlock(_ request: GeminiRequest) -> GeminiRequest {
        var copy = request
        copy.prefixMismatchBehavior = .dropBlock
        copy.forceBindingBeta = true
        return copy
    }

    private static func logBindingFallback(_ error: Error) {
        let diagnosis = (error as? APIError)?.prefixMismatchDiagnosis.map { "; \(InputTransformation.diagnosisHeader): \($0)" } ?? ""
        print("Anthropic rejected a replayed thinking block (bound to a different conversation); retrying once with drop_block, which this conversation keeps from now on if the retry succeeds (sent only where the beta is taken)\(diagnosis)")
    }

    static func generateContent(request: GeminiRequest, model: String, apiKey: String, baseURL: String = "") async throws -> GeminiResponse {
        try await generateContent(request: request, model: model, transport: .direct(apiKey: apiKey, baseURL: baseURL))
    }

    static func generateContent(request: GeminiRequest, model: String, transport: AnthropicTransport,
                                session: URLSession = .shared) async throws -> GeminiResponse {
        do {
            return try await generateOnce(request: request, model: model, transport: transport, session: session)
        } catch let error where isTTLRejection(error, request: request) {
            logTTLFallback(error)
            return try await generateOnce(request: withoutTTL(request), model: model, transport: transport, session: session)
        } catch let error where isBindingRejection(error, request: request) {
            logBindingFallback(error)
            var response = try await generateOnce(request: withDropBlock(request), model: model, transport: transport, session: session)
            response.anthropicBindingFallback = true
            return response
        }
    }

    private static func generateOnce(request: GeminiRequest, model: String, transport: AnthropicTransport,
                                     session: URLSession) async throws -> GeminiResponse {
        let urlRequest = try makeURLRequest(request: request, model: model, transport: transport, stream: false)
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if httpResponse.statusCode != 200 {
            print("API Error (\(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")")
            throw APIError.http(provider: transport.providerLabel, statusCode: httpResponse.statusCode, body: data,
                                headers: httpResponse.allHeaderFields)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var parsed = try parseResponse(json, raw: data)
        parsed.anthropicPrefixDiagnosis = InputTransformation.diagnosis(in: httpResponse.allHeaderFields)
        return parsed
    }

    /// Anthropic's non-stream Messages response back to `GeminiResponse`. `usage.input_tokens`
    /// alone undercounts the prompt: a cache hit or write moves tokens into
    /// `cache_read_input_tokens` / `cache_creation_input_tokens`, so `promptTokenCount` is their
    /// sum (5a §0.4). Anthropic never sends a total, so `.withTotal()` fills one from prompt +
    /// output — otherwise the job budgets, which read the total, charge these runs nothing.
    /// The stop reasons that can cut a block off partway.
    static let truncatingStopReasons: Set<String> = ["max_tokens", GeminiResponse.contextWindowReason]

    /// `raw` is the response's bytes; without it no blocks are stored (#314).
    static func parseResponse(_ json: [String: Any], raw: Data? = nil) throws -> GeminiResponse {
        var geminiResponse = GeminiResponse()
        geminiResponse.candidates = []

        if let contentArray = json["content"] as? [[String: Any]] {
            // Blocks arrive in order, so only the last can have been cut. Its input is partial
            // and must never run: refused like the stream's undecodable tool JSON.
            if let stop = json["stop_reason"] as? String, truncatingStopReasons.contains(stop),
               contentArray.last?["type"] as? String == "tool_use" {
                throw APIError(message: "Anthropic stopped (\(stop)) inside a tool call; its input is incomplete, so the call was not run.")
            }
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

            // #314: the array as it arrived, cut from the response bytes, never re-serialised.
            if let raw, let array = RawJSON.topLevelValue("content", in: raw),
               let stored = AnthropicBlocks.storable(array) {
                content.anthropicBlocks = stored
            }

            // `stop_reason` rides on the candidate as the stream's does, so a non-streamed
            // `max_tokens` or `refusal` is reported the same way (an empty one names it).
            let stopReason = json["stop_reason"] as? String
            if !content.parts.isEmpty || stopReason != nil {
                geminiResponse.candidates?.append(Candidate(content: content.parts.isEmpty ? nil : content,
                                                            finishReason: stopReason))
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
                cacheWriteTokens: cacheWrite,
                cacheWrite1hTokens: UsageMetadata.anthropicOneHourWrites(usage)
            ).withTotal()
        }

        geminiResponse.anthropicInputTransformations = InputTransformation.list(json["input_transformations"])
        return geminiResponse
    }
}
