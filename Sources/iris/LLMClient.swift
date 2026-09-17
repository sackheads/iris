import Foundation

/// Seam for injecting a scripted client in tests. The production `LLMClient` conforms;
/// tests supply a mock to drive `IrisEngine` deterministically without network calls.
protocol LLMClientProtocol: Sendable {
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse
}

extension LLMClient: LLMClientProtocol {}

struct LLMClient {
    static func resolveGeminiRequestURL(
        modelName: String,
        isADC: Bool,
        customBaseURL: String,
        quotaProject: String?
    ) throws -> URL {
        let baseURLString: String
        if !customBaseURL.isEmpty {
            baseURLString = customBaseURL
        } else if isADC {
            guard let project = quotaProject?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty else {
                throw APIError(message: "GCP Project ID not found. Required for Application Default Credentials (ADC) Vertex AI endpoint. Set via 'gcloud config set project <PROJECT_ID>' or export GOOGLE_CLOUD_QUOTA_PROJECT.")
            }
            baseURLString = "https://aiplatform.googleapis.com/v1/projects/\(project)/locations/global/publishers/google/models/\(modelName):generateContent"
        } else {
            baseURLString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent"
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
                    quotaProject: quotaProject
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
