import Foundation

/// One model an account can reach, as `listModels` (#207) parses it from a provider's list
/// endpoint. `id` is what a user pastes into a tier field.
struct ModelInfo: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String?
}

/// The result of one `probe` call (#206).
enum ModelProbeOutcome: Equatable, Sendable {
    case ok(latencyMs: Int)
    case failed(String)
}

/// One row of a "Test Models" run: a tier label (possibly several tiers sharing one model,
/// joined by `probeTargets`), the model string tested, and the outcome.
struct ModelProbeResult: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let model: String
    let outcome: ModelProbeOutcome
}

/// Lists and probes models for one provider, entirely from values passed in — no
/// `ConfigManager.shared` access, so a test can construct one with explicit values and a
/// `URLSession` that routes through `MockURLProtocol`.
struct ModelCatalog: Sendable {
    let provider: LLMProvider
    /// Empty for Gemini in ADC mode.
    let apiKey: String
    /// "" means the provider's default endpoint.
    let baseURL: String
    /// Gemini only; ignored for Anthropic/OpenAI.
    let geminiADC: Bool
    let session: URLSession

    init(provider: LLMProvider, apiKey: String, baseURL: String, geminiADC: Bool = false, session: URLSession = .shared) {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.geminiADC = geminiADC
        self.session = session
    }

    // MARK: - #207 listing

    /// The bare list URL for one page, before any provider-specific auth header is attached.
    /// Gemini's `key` query item is added here (it belongs on the URL, not a header); a custom
    /// Gemini base URL follows the app's `:generateContent`-per-model convention and cannot be
    /// turned into a list URL, so it always throws.
    ///
    /// Gemini has two list paths, and they are not interchangeable: `generateContent` in ADC mode
    /// goes through Vertex (`resolveGeminiRequestURL`'s aiplatform branch) with a
    /// cloud-platform-scoped token, but `generativelanguage.googleapis.com/v1beta/models` needs
    /// the separate generative-language scope that token does not carry — an ADC listing there
    /// 403s even though generation works fine. So `isADC` routes listing to Vertex's own
    /// publisher-models endpoint instead, which accepts the same cloud-platform token
    /// `generateContent` already uses; API-key mode keeps using `generativelanguage`.
    static func listURL(provider: LLMProvider, baseURL: String, apiKey: String? = nil, isADC: Bool = false, pageToken: String? = nil) throws -> URL {
        var comps: URLComponents
        switch provider {
        case .gemini:
            guard baseURL.isEmpty else {
                throw APIError(message: "Listing is not available for a custom Gemini endpoint.")
            }
            if isADC {
                guard let c = URLComponents(string: "https://aiplatform.googleapis.com/v1beta1/publishers/google/models") else {
                    throw APIError(message: "Invalid Gemini (Vertex) model list URL.")
                }
                comps = c
                var items = [URLQueryItem(name: "pageSize", value: "200")]
                if let pageToken, !pageToken.isEmpty {
                    items.append(URLQueryItem(name: "pageToken", value: pageToken))
                }
                comps.queryItems = items
                guard let url = comps.url else {
                    throw APIError(message: "Failed to construct model list URL.")
                }
                return url
            }
            guard let c = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
                throw APIError(message: "Invalid Gemini model list URL.")
            }
            comps = c
            var items: [URLQueryItem] = []
            if let pageToken, !pageToken.isEmpty {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            if let apiKey, !apiKey.isEmpty {
                items.append(URLQueryItem(name: "key", value: apiKey))
            }
            if !items.isEmpty { comps.queryItems = items }
        case .anthropic:
            let base: String
            if baseURL.isEmpty {
                base = "https://api.anthropic.com/v1"
            } else if baseURL.hasSuffix("/messages") {
                base = String(baseURL.dropLast("/messages".count))
            } else {
                base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            guard let c = URLComponents(string: "\(base)/models") else {
                throw APIError(message: "Invalid Anthropic model list URL.")
            }
            comps = c
            if let pageToken, !pageToken.isEmpty {
                comps.queryItems = [URLQueryItem(name: "after_id", value: pageToken)]
            }
        case .openai:
            let base: String
            if baseURL.isEmpty {
                base = "https://api.openai.com/v1"
            } else if baseURL.hasSuffix("/chat/completions") {
                base = String(baseURL.dropLast("/chat/completions".count))
            } else {
                base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            guard let c = URLComponents(string: "\(base)/models") else {
                throw APIError(message: "Invalid OpenAI model list URL.")
            }
            comps = c
        }
        guard let url = comps.url else {
            throw APIError(message: "Failed to construct model list URL.")
        }
        return url
    }

    /// Gemini's `{"models": [{"name": "models/gemini-...", "displayName": ...}], "nextPageToken": ...}`.
    /// The `models/` prefix on `name` is the resource path, not the string a request accepts.
    static func parseGeminiModels(_ data: Data) throws -> (models: [ModelInfo], nextPageToken: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "Gemini model list: unexpected response body")
        }
        let entries = json["models"] as? [[String: Any]] ?? []
        let models: [ModelInfo] = entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            return ModelInfo(id: id, displayName: entry["displayName"] as? String)
        }
        let nextPageToken = json["nextPageToken"] as? String
        return (models, (nextPageToken?.isEmpty == false) ? nextPageToken : nil)
    }

    /// Vertex's publisher-models listing, used for Gemini in ADC mode:
    /// `{"publisherModels": [{"name": "publishers/google/models/gemini-...", "displayName": ...}],
    /// "nextPageToken": ...}`. `name` carries the `publishers/google/models/` resource prefix, not
    /// the bare model string a request accepts (which may itself carry a version suffix, e.g.
    /// `gemini-1.5-pro-002` — left as-is once the prefix is stripped).
    static func parseGeminiPublisherModels(_ data: Data) throws -> (models: [ModelInfo], nextPageToken: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "Gemini model list: unexpected response body")
        }
        let prefix = "publishers/google/models/"
        let entries = json["publisherModels"] as? [[String: Any]] ?? []
        let models: [ModelInfo] = entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let id = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
            return ModelInfo(id: id, displayName: entry["displayName"] as? String)
        }
        let nextPageToken = json["nextPageToken"] as? String
        return (models, (nextPageToken?.isEmpty == false) ? nextPageToken : nil)
    }

    /// Anthropic's `{"data": [{"id": ..., "display_name": ...}], "has_more": bool, "last_id": ...}`.
    static func parseAnthropicModels(_ data: Data) throws -> (models: [ModelInfo], hasMore: Bool, lastId: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "Anthropic model list: unexpected response body")
        }
        let entries = json["data"] as? [[String: Any]] ?? []
        let models: [ModelInfo] = entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return ModelInfo(id: id, displayName: entry["display_name"] as? String)
        }
        let hasMore = json["has_more"] as? Bool ?? false
        return (models, hasMore, json["last_id"] as? String)
    }

    /// OpenAI's `{"data": [{"id": ...}], "object": "list"}`, unordered on the wire — sorted here.
    static func parseOpenAIModels(_ data: Data) throws -> [ModelInfo] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "OpenAI model list: unexpected response body")
        }
        let entries = json["data"] as? [[String: Any]] ?? []
        let models: [ModelInfo] = entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return ModelInfo(id: id, displayName: nil)
        }
        return models.sorted { $0.id < $1.id }
    }

    /// Every model the configured account can reach. Gemini in ADC mode needs `adcToken` (and,
    /// for the header, `quotaProject`); neither is fetched here — the caller reads
    /// `ADCCredentialManager` and passes the values in, so this type never touches it. The result
    /// is de-duplicated by id (first occurrence wins) — `ModelInfo.id` drives `List` identity in
    /// the sheet, and a provider that repeats an id across pages would otherwise break it.
    func listModels(adcToken: String? = nil, quotaProject: String? = nil) async throws -> [ModelInfo] {
        let models: [ModelInfo]
        switch provider {
        case .gemini:
            models = try await listGeminiModels(adcToken: adcToken, quotaProject: quotaProject)
        case .anthropic:
            models = try await listAnthropicModels()
        case .openai:
            models = try await listOpenAIModelsImpl()
        }
        var seen = Set<String>()
        return models.filter { seen.insert($0.id).inserted }
    }

    /// Hard cap on pages fetched for one `listModels` call. Without it, a proxy that ignores the
    /// page token and keeps claiming there is more would loop forever — and since the listing
    /// runs inside a retained `Task`, "forever" means the Models tab's buttons (disabled while a
    /// run is in flight) never re-enable for the rest of the app's life.
    private static let maxListPages = 20

    /// Fetches pages starting from `nil` until `fetchPage` returns a nil next-page token, the
    /// page cap is hit, or the returned token is identical to the one just used (a proxy that
    /// ignores the token and echoes the same one back would otherwise spin forever — this catches
    /// that without needing to know each provider's specific "more" field). Checks for
    /// cancellation before every page, so a caller cancelling the enclosing `Task` (the sheet
    /// closing, the view disappearing) actually stops an in-flight multi-page fetch.
    private func paginate(
        fetchPage: (String?) async throws -> (models: [ModelInfo], nextToken: String?)
    ) async throws -> [ModelInfo] {
        var results: [ModelInfo] = []
        var token: String?
        var pageCount = 0
        repeat {
            try Task.checkCancellation()
            pageCount += 1
            let (models, nextToken) = try await fetchPage(token)
            results.append(contentsOf: models)
            if let nextToken, nextToken == token {
                break
            }
            token = nextToken
        } while token != nil && pageCount < Self.maxListPages
        return results
    }

    /// Dispatches to whichever of Gemini's two list paths matches how it authenticates — see the
    /// doc comment on `listURL` for why ADC cannot use the API-key path's endpoint.
    private func listGeminiModels(adcToken: String?, quotaProject: String?) async throws -> [ModelInfo] {
        if geminiADC {
            return try await listGeminiPublisherModels(adcToken: adcToken, quotaProject: quotaProject)
        }
        return try await paginate { token in
            let url = try Self.listURL(provider: .gemini, baseURL: baseURL, apiKey: apiKey, pageToken: token)
            let request = URLRequest(url: url)
            let data = try await performRequest(request, provider: "Gemini")
            let (models, next) = try Self.parseGeminiModels(data)
            return (models, next)
        }
    }

    /// Vertex's publisher-models listing, authenticated the same way `generateContent` already is
    /// in ADC mode (cloud-platform-scoped Bearer token + `x-goog-user-project`), rather than the
    /// generative-language-scoped `generativelanguage.googleapis.com` path.
    private func listGeminiPublisherModels(adcToken: String?, quotaProject: String?) async throws -> [ModelInfo] {
        guard let adcToken, !adcToken.isEmpty else {
            throw APIError(message: "Missing ADC access token for Gemini model listing.")
        }
        return try await paginate { token in
            let url = try Self.listURL(provider: .gemini, baseURL: baseURL, isADC: true, pageToken: token)
            var request = URLRequest(url: url)
            request.addValue("Bearer \(adcToken)", forHTTPHeaderField: "Authorization")
            if let quotaProject, !quotaProject.isEmpty {
                request.addValue(quotaProject, forHTTPHeaderField: "x-goog-user-project")
            }
            let data = try await performRequest(request, provider: "Gemini")
            let (models, next) = try Self.parseGeminiPublisherModels(data)
            return (models, next)
        }
    }

    private func listAnthropicModels() async throws -> [ModelInfo] {
        try await paginate { token in
            let url = try Self.listURL(provider: .anthropic, baseURL: baseURL, pageToken: token)
            var request = URLRequest(url: url)
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let data = try await performRequest(request, provider: "Anthropic")
            let (models, hasMore, lastId) = try Self.parseAnthropicModels(data)
            return (models, hasMore ? lastId : nil)
        }
    }

    private func listOpenAIModelsImpl() async throws -> [ModelInfo] {
        let url = try Self.listURL(provider: .openai, baseURL: baseURL)
        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await performRequest(request, provider: "OpenAI")
        return try Self.parseOpenAIModels(data)
    }

    // MARK: - #206 probing

    /// Folds tier models into probe targets, de-duplicating a model string shared by two or more
    /// tiers into one target whose label lists every tier it backs (tier order preserved, e.g.
    /// "Easy, Hard"). `vision` is included only when non-nil/non-empty — the caller decides
    /// whether the auxiliary vision engine is in cloud mode.
    static func probeTargets(easy: String, medium: String, hard: String, vision: String?) -> [(label: String, model: String)] {
        var order: [String] = []
        var labelsByModel: [String: [String]] = [:]
        func add(_ label: String, _ model: String) {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if labelsByModel[trimmed] == nil { order.append(trimmed) }
            labelsByModel[trimmed, default: []].append(label)
        }
        add("Easy", easy)
        add("Primary/Medium", medium)
        add("Hard", hard)
        if let vision, !vision.isEmpty {
            add("Vision", vision)
        }
        return order.map { model in (label: labelsByModel[model]!.joined(separator: ", "), model: model) }
    }

    /// One tiny generation against an explicit model name, timed. Never throws — an error becomes
    /// `.failed(message)` so a caller can render every target's outcome uniformly.
    func probe(model: String, label: String, adcToken: String? = nil, quotaProject: String? = nil) async -> ModelProbeResult {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            try await performProbeRequest(model: model, adcToken: adcToken, quotaProject: quotaProject)
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return ModelProbeResult(id: label, label: label, model: model, outcome: .ok(latencyMs: max(0, latencyMs)))
        } catch {
            let message = (error as? APIError)?.message ?? error.localizedDescription
            return ModelProbeResult(id: label, label: label, model: model, outcome: .failed(message))
        }
    }

    /// One request through the real per-provider builders (`AnthropicClient`/`OpenAIClient`
    /// `makeURLRequest`), or the equivalent for Gemini via the pure `resolveGeminiRequestURL`
    /// builder — never `LLMClient.makeGeminiURLRequest`, which reads `ConfigManager.shared`.
    private func performProbeRequest(model: String, adcToken: String?, quotaProject: String?) async throws {
        let request = GeminiRequest(
            contents: [Content(role: "user", parts: [Part(text: "Respond with exactly one word: Hello")])],
            systemInstruction: nil,
            tools: nil
        )
        switch provider {
        case .anthropic:
            let urlRequest = try AnthropicClient.makeURLRequest(request: request, model: model, apiKey: apiKey, baseURL: baseURL, stream: false)
            _ = try await performRequest(urlRequest, provider: "Anthropic")
        case .openai:
            let urlRequest = try OpenAIClient.makeURLRequest(request: request, model: model, apiKey: apiKey, baseURL: baseURL, stream: false)
            _ = try await performRequest(urlRequest, provider: "OpenAI")
        case .gemini:
            let url = try LLMClient.resolveGeminiRequestURL(
                modelName: model, isADC: geminiADC, customBaseURL: baseURL, quotaProject: quotaProject, streaming: false
            )
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            if geminiADC {
                guard let adcToken, !adcToken.isEmpty else {
                    throw APIError(message: "Missing ADC access token for Gemini probe.")
                }
                urlRequest.addValue("Bearer \(adcToken)", forHTTPHeaderField: "Authorization")
                if let quotaProject, !quotaProject.isEmpty {
                    urlRequest.addValue(quotaProject, forHTTPHeaderField: "x-goog-user-project")
                }
            } else {
                guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw APIError(message: "Invalid Gemini request URL.")
                }
                var items = comps.queryItems ?? []
                items.append(URLQueryItem(name: "key", value: apiKey))
                comps.queryItems = items
                guard let finalURL = comps.url else {
                    throw APIError(message: "Failed to construct Gemini request URL.")
                }
                urlRequest.url = finalURL
            }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .useDefaultKeys
            urlRequest.httpBody = try encoder.encode(request)
            _ = try await performRequest(urlRequest, provider: "Gemini")
        }
    }

    /// Every catalog request — probe or list, any provider — gets this short timeout regardless
    /// of what the reused per-provider builder set (`AnthropicClient`/`OpenAIClient`'s
    /// `makeURLRequest` apply `LLMRequestPolicy`'s 180 s, sized for a real chat turn; a manually
    /// built Gemini request would otherwise get URLSession's 60 s default). These are UI buttons a
    /// person is staring at, not a turn in flight, so a bad model string or a slow proxy should
    /// fail fast rather than sit for a minute or three.
    private static let requestTimeoutSeconds: TimeInterval = 20

    private func performRequest(_ request: URLRequest, provider: String) async throws -> Data {
        var request = request
        request.timeoutInterval = Self.requestTimeoutSeconds
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(provider: provider, statusCode: http.statusCode, body: data, headers: http.allHeaderFields)
            }
            return data
        } catch let error as URLError where error.code == .timedOut {
            throw APIError(message: "timed out after \(Int(Self.requestTimeoutSeconds)) s")
        }
    }
}
