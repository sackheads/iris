import Testing
import Foundation
@testable import iris

/// #206 "Test Models" and #207 "List Available Models" — `ModelCatalog`'s URL builders, response
/// parsing, and the network paths through `MockURLProtocol` (session-injected, never global
/// registration and never `ConfigManager.shared`/`ADCCredentialManager`). Uses
/// `MockURLProtocol.scopedSession`, not the shared `.handler` — that single global slot would
/// otherwise race with `StreamingClientTests`, the other Swift Testing suite using this mock,
/// since both can run concurrently.
@Suite("Model catalog (#206, #207)")
struct ModelCatalogTests {
    private func withMock<T>(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data), _ body: (URLSession) async throws -> T) async rethrows -> T {
        let (session, remove) = MockURLProtocol.scopedSession(handler)
        defer { remove() }
        return try await body(session)
    }

    // MARK: - listURL

    @Test("Gemini list URL is the default endpoint, with pageToken and key as query items")
    func geminiListURLDefault() throws {
        let url = try ModelCatalog.listURL(provider: .gemini, baseURL: "", apiKey: "k", pageToken: "tok")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(comps?.path == "/v1beta/models")
        #expect(comps?.host == "generativelanguage.googleapis.com")
        let items = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["pageToken"] == "tok")
        #expect(items["key"] == "k")
    }

    @Test("a custom Gemini base URL cannot be turned into a list URL")
    func geminiCustomBaseThrows() {
        #expect(throws: APIError.self) {
            _ = try ModelCatalog.listURL(provider: .gemini, baseURL: "https://proxy.example/v1beta/models/gemini-x:generateContent")
        }
    }

    @Test("Anthropic list URL defaults, strips a custom /messages suffix, and paginates on after_id")
    func anthropicListURL() throws {
        let defaultURL = try ModelCatalog.listURL(provider: .anthropic, baseURL: "")
        #expect(defaultURL.absoluteString == "https://api.anthropic.com/v1/models")

        let custom = try ModelCatalog.listURL(provider: .anthropic, baseURL: "https://custom.anthropic.endpoint.com/v1/messages")
        #expect(custom.absoluteString == "https://custom.anthropic.endpoint.com/v1/models")

        let paged = try ModelCatalog.listURL(provider: .anthropic, baseURL: "", pageToken: "model_last")
        #expect(paged.query == "after_id=model_last")
    }

    @Test("OpenAI list URL defaults and strips a custom /chat/completions suffix")
    func openAIListURL() throws {
        let defaultURL = try ModelCatalog.listURL(provider: .openai, baseURL: "")
        #expect(defaultURL.absoluteString == "https://api.openai.com/v1/models")

        let custom = try ModelCatalog.listURL(provider: .openai, baseURL: "https://my-proxy.example/v1/chat/completions")
        #expect(custom.absoluteString == "https://my-proxy.example/v1/models")
    }

    // MARK: - parsing

    @Test("Gemini model parsing strips the models/ prefix and reads nextPageToken")
    func parseGemini() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "models": [
                ["name": "models/gemini-3.5-flash", "displayName": "Gemini 3.5 Flash"],
                ["name": "models/gemini-3.1-pro-preview"]
            ],
            "nextPageToken": "page2"
        ])
        let (models, next) = try ModelCatalog.parseGeminiModels(body)
        #expect(models.map(\.id) == ["gemini-3.5-flash", "gemini-3.1-pro-preview"])
        #expect(models[0].displayName == "Gemini 3.5 Flash")
        #expect(models[1].displayName == nil)
        #expect(next == "page2")
    }

    @Test("Anthropic model parsing reads has_more and last_id")
    func parseAnthropic() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5"],
                ["id": "claude-sonnet-5", "display_name": "Claude Sonnet 5"]
            ],
            "has_more": true,
            "last_id": "claude-sonnet-5"
        ])
        let (models, hasMore, lastId) = try ModelCatalog.parseAnthropicModels(body)
        #expect(models.map(\.id) == ["claude-haiku-4-5-20251001", "claude-sonnet-5"])
        #expect(hasMore == true)
        #expect(lastId == "claude-sonnet-5")
    }

    @Test("OpenAI model parsing sorts by id")
    func parseOpenAI() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "object": "list",
            "data": [["id": "gpt-5.6-terra"], ["id": "gpt-5.6-luna"], ["id": "gpt-5.6-sol"]]
        ])
        let models = try ModelCatalog.parseOpenAIModels(body)
        #expect(models.map(\.id) == ["gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra"])
    }

    // MARK: - listModels end to end

    @Test("Gemini listModels (API key) sends the key as a query item and paginates over two pages")
    func listModelsGeminiAPIKey() async throws {
        var callCount = 0
        try await withMock({ request in
            callCount += 1
            #expect(request.url?.path == "/v1beta/models")
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let items = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value) })
            #expect(items["key"] == "test-gemini-key")
            let body: [String: Any]
            if callCount == 1 {
                #expect(items["pageToken"] == nil)
                body = ["models": [["name": "models/gemini-3.5-flash"]], "nextPageToken": "p2"]
            } else {
                #expect(items["pageToken"] == "p2")
                body = ["models": [["name": "models/gemini-3.1-pro-preview"]]]
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }) { session in
            let catalog = ModelCatalog(provider: .gemini, apiKey: "test-gemini-key", baseURL: "", session: session)
            let models = try await catalog.listModels()
            #expect(models.map(\.id) == ["gemini-3.5-flash", "gemini-3.1-pro-preview"])
        }
        #expect(callCount == 2)
    }

    @Test("Gemini listModels (ADC) sends a bearer token and quota project header, not a query key")
    func listModelsGeminiADC() async throws {
        try await withMock({ request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer adc-token-123")
            #expect(request.value(forHTTPHeaderField: "x-goog-user-project") == "my-quota-project")
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            #expect((comps?.queryItems ?? []).allSatisfy { $0.name != "key" })
            let body: [String: Any] = ["models": [["name": "models/gemini-3.5-flash"]]]
            let data = try JSONSerialization.data(withJSONObject: body)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }) { session in
            let catalog = ModelCatalog(provider: .gemini, apiKey: "", baseURL: "", geminiADC: true, session: session)
            let models = try await catalog.listModels(adcToken: "adc-token-123", quotaProject: "my-quota-project")
            #expect(models.map(\.id) == ["gemini-3.5-flash"])
        }
    }

    @Test("Anthropic listModels sends x-api-key and anthropic-version, and paginates over two pages")
    func listModelsAnthropic() async throws {
        var callCount = 0
        try await withMock({ request in
            callCount += 1
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-anthropic-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            let body: [String: Any]
            if callCount == 1 {
                #expect(request.url?.query == nil)
                body = ["data": [["id": "claude-haiku-4-5-20251001"]], "has_more": true, "last_id": "claude-haiku-4-5-20251001"]
            } else {
                #expect(request.url?.query == "after_id=claude-haiku-4-5-20251001")
                body = ["data": [["id": "claude-sonnet-5"]], "has_more": false]
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }) { session in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "test-anthropic-key", baseURL: "", session: session)
            let models = try await catalog.listModels()
            #expect(models.map(\.id) == ["claude-haiku-4-5-20251001", "claude-sonnet-5"])
        }
        #expect(callCount == 2)
    }

    @Test("OpenAI listModels sends a bearer token and returns the sorted list")
    func listModelsOpenAI() async throws {
        try await withMock({ request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-openai-key")
            let body: [String: Any] = ["data": [["id": "gpt-5.6-terra"], ["id": "gpt-5.6-luna"]]]
            let data = try JSONSerialization.data(withJSONObject: body)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }) { session in
            let catalog = ModelCatalog(provider: .openai, apiKey: "test-openai-key", baseURL: "", session: session)
            let models = try await catalog.listModels()
            #expect(models.map(\.id) == ["gpt-5.6-luna", "gpt-5.6-terra"])
        }
    }

    // MARK: - probe

    @Test("probe succeeds against a 200 response, for every provider")
    func probeSuccess() async throws {
        for provider: LLMProvider in [.gemini, .anthropic, .openai] {
            let result = try await withMock({ request in
                let body: [String: Any]
                switch provider {
                case .anthropic:
                    body = ["id": "msg_1", "type": "message", "role": "assistant",
                            "content": [["type": "text", "text": "Hello"]],
                            "usage": ["input_tokens": 5, "output_tokens": 1]]
                case .openai:
                    body = ["choices": [["message": ["role": "assistant", "content": "Hello"]]]]
                case .gemini:
                    body = ["candidates": [["content": ["role": "model", "parts": [["text": "Hello"]]]]]]
                }
                let data = try JSONSerialization.data(withJSONObject: body)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }) { session -> ModelProbeResult in
                let catalog = ModelCatalog(provider: provider, apiKey: "k", baseURL: "", session: session)
                return await catalog.probe(model: "some-model", label: "Easy")
            }
            guard case .ok(let latencyMs) = result.outcome else {
                Issue.record("expected .ok for \(provider), got \(result.outcome)")
                continue
            }
            #expect(latencyMs >= 0)
        }
    }

    @Test("probe surfaces a 401 as .failed carrying the provider's error message")
    func probeUnauthorized() async throws {
        let result = try await withMock({ request in
            let body = ["error": ["type": "authentication_error", "message": "invalid x-api-key"]]
            let data = try JSONSerialization.data(withJSONObject: body)
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, data)
        }) { session -> ModelProbeResult in
            let catalog = ModelCatalog(provider: .anthropic, apiKey: "bad-key", baseURL: "", session: session)
            return await catalog.probe(model: "claude-sonnet-5", label: "Primary/Medium")
        }
        guard case .failed(let message) = result.outcome else {
            Issue.record("expected .failed, got \(result.outcome)")
            return
        }
        #expect(message.contains("invalid x-api-key"))
    }

    @Test("probe surfaces a transport failure as .failed, never throwing")
    func probeTransportError() async throws {
        let result = try await withMock({ _ in
            throw URLError(.notConnectedToInternet)
        }) { session -> ModelProbeResult in
            let catalog = ModelCatalog(provider: .openai, apiKey: "k", baseURL: "", session: session)
            return await catalog.probe(model: "gpt-5.6-terra", label: "Hard")
        }
        guard case .failed = result.outcome else {
            Issue.record("expected .failed, got \(result.outcome)")
            return
        }
    }

    @Test("probe against Gemini in ADC mode with no token supplied fails cleanly, never touching ADCCredentialManager")
    func probeGeminiADCMissingToken() async throws {
        let catalog = ModelCatalog(provider: .gemini, apiKey: "", baseURL: "", geminiADC: true, session: .shared)
        let result = await catalog.probe(model: "gemini-3.5-flash", label: "Primary/Medium")
        guard case .failed(let message) = result.outcome else {
            Issue.record("expected .failed, got \(result.outcome)")
            return
        }
        #expect(message.contains("ADC"))
    }

    // MARK: - probeTargets

    @Test("probeTargets de-duplicates a model shared across tiers, joining labels in tier order")
    func probeTargetsDedup() {
        let targets = ModelCatalog.probeTargets(easy: "gemini-3.1-flash-lite", medium: "gemini-3.5-flash", hard: "gemini-3.1-flash-lite", vision: nil)
        #expect(targets.count == 2)
        #expect(targets[0].label == "Easy, Hard")
        #expect(targets[0].model == "gemini-3.1-flash-lite")
        #expect(targets[1].label == "Primary/Medium")
        #expect(targets[1].model == "gemini-3.5-flash")
    }

    @Test("probeTargets includes Vision only when non-empty")
    func probeTargetsVision() {
        let withVision = ModelCatalog.probeTargets(easy: "e", medium: "m", hard: "h", vision: "v")
        #expect(withVision.map(\.label) == ["Easy", "Primary/Medium", "Hard", "Vision"])

        let withoutVision = ModelCatalog.probeTargets(easy: "e", medium: "m", hard: "h", vision: "")
        #expect(withoutVision.map(\.label) == ["Easy", "Primary/Medium", "Hard"])

        let noneVision = ModelCatalog.probeTargets(easy: "e", medium: "m", hard: "h", vision: nil)
        #expect(noneVision.map(\.label) == ["Easy", "Primary/Medium", "Hard"])
    }

    @Test("probeTargets skips blank tier models")
    func probeTargetsBlank() {
        let targets = ModelCatalog.probeTargets(easy: "", medium: "  ", hard: "h", vision: nil)
        #expect(targets.map(\.label) == ["Hard"])
    }
}
