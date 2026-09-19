import Foundation

/// Seam for injecting a scripted client in tests. The production `LLMClient` conforms;
/// tests supply a mock to drive `IrisEngine` deterministically without network calls.
protocol LLMClientProtocol: Sendable {
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse
    /// Streams the same call. Default (LLMStream.swift): one `generateContent` replayed as events.
    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// True only when `streamContent` reads the provider's stream natively. Default false.
    var supportsStreaming: Bool { get }
}

extension LLMClient: LLMClientProtocol {}

struct LLMClient {
    /// `streaming` swaps the generate method for the SSE one; a custom base URL is rewritten
    /// only when it names the plain method, and is otherwise taken exactly as configured.
    static func resolveGeminiRequestURL(
        modelName: String,
        isADC: Bool,
        customBaseURL: String,
        quotaProject: String?,
        streaming: Bool = false
    ) throws -> URL {
        let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"
        let baseURLString: String
        if !customBaseURL.isEmpty {
            if streaming, customBaseURL.hasSuffix(":generateContent") {
                baseURLString = customBaseURL.dropLast("generateContent".count) + method
            } else {
                baseURLString = customBaseURL
            }
        } else if isADC {
            guard let project = quotaProject?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty else {
                throw APIError(message: "GCP Project ID not found. Required for Application Default Credentials (ADC) Vertex AI endpoint. Set via 'gcloud config set project <PROJECT_ID>' or export GOOGLE_CLOUD_QUOTA_PROJECT.")
            }
            baseURLString = "https://aiplatform.googleapis.com/v1/projects/\(project)/locations/global/publishers/google/models/\(modelName):\(method)"
        } else {
            baseURLString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):\(method)"
        }
        
        guard let url = URL(string: baseURLString) else {
            throw APIError(message: "Invalid Gemini base URL configuration: \(baseURLString)")
        }
        return url
    }

    func endpoint(for tier: ModelTier) async -> String {
        let config = ConfigManager.shared
        let modelName = config.getModel(for: tier)
        let isADC = config.geminiAuthMode == GeminiAuthMode.adc.rawValue
        let quotaProject = isADC ? await ADCCredentialManager.shared.getQuotaProject() : nil
        if let url = try? LLMClient.resolveGeminiRequestURL(
            modelName: modelName,
            isADC: isADC,
            customBaseURL: config.geminiBaseURL,
            quotaProject: quotaProject
        ) {
            return url.absoluteString
        }
        return "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent"
    }
    
    /// The full Gemini request for one call, authenticated as configured. `streaming` only
    /// changes the endpoint method; the body is the same encoded `GeminiRequest` either way.
    func makeGeminiURLRequest(request: GeminiRequest, modelName: String, streaming: Bool) async throws -> URLRequest {
        let config = ConfigManager.shared
        let isADC = config.geminiAuthMode == GeminiAuthMode.adc.rawValue
        let apiKey = config.geminiAPIKey

        if !isADC && apiKey.isEmpty {
            throw APIError(message: "GEMINI_FALLBACK_AUTH_ERROR_1013")
        }

        let cleanRequest = request
        // We no longer strip thought_signature because Gemini requires it to be echoed back

        let quotaProject = isADC ? await ADCCredentialManager.shared.getQuotaProject() : nil
        let requestURL = try LLMClient.resolveGeminiRequestURL(
            modelName: modelName,
            isADC: isADC,
            customBaseURL: config.geminiBaseURL,
            quotaProject: quotaProject,
            streaming: streaming
        )

        guard var urlComponents = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Invalid Gemini request URL: \(requestURL.absoluteString)")
        }

        if !isADC {
            var items = urlComponents.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: apiKey))
            urlComponents.queryItems = items
        }

        guard let finalURL = urlComponents.url else {
            throw APIError(message: "Failed to construct Gemini request URL.")
        }
        var urlRequest = URLRequest(url: finalURL)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if isADC {
            let accessToken = try await ADCCredentialManager.shared.getAccessToken()
            urlRequest.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if let project = quotaProject {
                urlRequest.addValue(project, forHTTPHeaderField: "x-goog-user-project")
            }
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        let requestData = try encoder.encode(cleanRequest)
        urlRequest.httpBody = requestData

        LLMRequestPolicy.apply(to: &urlRequest)
        return urlRequest
    }

    var supportsStreaming: Bool { true }

    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let config = ConfigManager.shared
        let provider = config.primaryProvider
        let modelName = config.getModel(for: tier)
        let metricOp: MetricOperationType
        switch tier {
        case .easy: metricOp = .easy
        case .medium: metricOp = .medium
        case .hard: metricOp = .hard
        }
        let inner: AsyncThrowingStream<LLMStreamEvent, Error>
        if provider == LLMProvider.anthropic.rawValue {
            inner = AnthropicClient.streamContent(request: request, model: modelName, apiKey: config.anthropicAPIKey, baseURL: config.anthropicBaseURL)
        } else if provider == LLMProvider.openai.rawValue {
            inner = OpenAIClient.streamContent(request: request, model: modelName, apiKey: config.openAIAPIKey, baseURL: config.openAIBaseURL)
        } else {
            // The missing-key check lives in `makeGeminiURLRequest`, so it throws inside the
            // metrics wrapper below and is recorded like any other failed call.
            inner = LLMStreaming.stream(provider: "Gemini", mapper: GeminiStreamMapper()) {
                try await self.makeGeminiURLRequest(request: request, modelName: modelName, streaming: true)
            }
        }
        // Provider latency metrics, as the plain call records them.
        let start = CFAbsoluteTimeGetCurrent()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var succeeded = true
                do {
                    for try await event in inner { continuation.yield(event) }
                } catch {
                    succeeded = false
                    continuation.finish(throwing: error)
                }
                await MetricsManager.shared.trackLatency(operation: metricOp, modelName: modelName,
                                                         durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0, success: succeeded)
                if succeeded { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generateContent(request: GeminiRequest, tier: ModelTier = .medium) async throws -> GeminiResponse {
        let config = ConfigManager.shared
        let provider = config.primaryProvider
        
        let metricOp: MetricOperationType
        switch tier {
        case .easy: metricOp = .easy
        case .medium: metricOp = .medium
        case .hard: metricOp = .hard
        }
        
        let modelName = config.getModel(for: tier)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let response: GeminiResponse
            if provider == LLMProvider.anthropic.rawValue {
                response = try await AnthropicClient.generateContent(request: request, model: modelName, apiKey: config.anthropicAPIKey, baseURL: config.anthropicBaseURL)
            } else if provider == LLMProvider.openai.rawValue {
                response = try await OpenAIClient.generateContent(request: request, model: modelName, apiKey: config.openAIAPIKey, baseURL: config.openAIBaseURL)
            } else {
                // Fallback to Gemini
                let urlRequest = try await makeGeminiURLRequest(request: request, modelName: modelName, streaming: false)
                let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)
                
                guard let httpResponse = urlResponse as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                
                if httpResponse.statusCode != 200 {
                    // Full body goes to the console; the chat only ever sees the capped form.
                    print("API Error (\(httpResponse.statusCode)): \(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")")
                    throw APIError.http(provider: "Gemini", statusCode: httpResponse.statusCode, body: data,
                                headers: httpResponse.allHeaderFields)
                }
                
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .useDefaultKeys
                response = try decoder.decode(GeminiResponse.self, from: data)
            }
            
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            // primaryLLM profiling now happens at the engine's call seam (measure(.primaryLLM))
            // so it covers every client uniformly; here we only track provider latency metrics.
            await MetricsManager.shared.trackLatency(operation: metricOp, modelName: modelName, durationMs: durationMs, success: true)
            return response

        } catch {
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            await MetricsManager.shared.trackLatency(operation: metricOp, modelName: modelName, durationMs: durationMs, success: false)
            throw error
        }
    }
}
