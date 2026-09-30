import Foundation

/// `--dump-requests <dir>`: reconstructs the exact wire body the currently configured provider
/// client would send for one round, without touching the network and without changing how any
/// client builds its requests (5a). Task 10 counts prefix sizes from these dumps.
///
/// Anthropic and OpenAI each expose a pure, static `makeURLRequest(request:model:apiKey:baseURL:
/// stream:)` that returns the exact `URLRequest` a call would send; this reuses that builder
/// directly, so the dumped bytes are identical to production, byte for byte. The placeholder API
/// key only ever reaches a header (`x-api-key` / `Authorization`), never the body, and is never
/// sent anywhere. Gemini has no equivalent static builder — its instance method
/// (`LLMClient.makeGeminiURLRequest`) reads `ConfigManager.shared.geminiAPIKey` and performs an
/// async ADC handshake before it ever touches the body — but its wire body is nothing but the
/// request's own JSON encoding (`encoder.keyEncodingStrategy = .useDefaultKeys; encoder.encode
/// (request)`), so that one line is replicated directly here instead.
enum RequestDump {
    /// Never sent over the network: only ever used locally to build a request whose body we then
    /// discard the transport for and write to disk instead.
    static let placeholderAPIKey = "perf-dump-placeholder"

    static func body(for request: GeminiRequest, provider: String, model: String) throws -> Data {
        switch provider {
        case LLMProvider.anthropic.rawValue:
            let urlRequest = try AnthropicClient.makeURLRequest(request: request, model: model, apiKey: placeholderAPIKey, stream: false)
            return urlRequest.httpBody ?? Data()
        case LLMProvider.openai.rawValue:
            let urlRequest = try OpenAIClient.makeURLRequest(request: request, model: model, apiKey: placeholderAPIKey, stream: false)
            return urlRequest.httpBody ?? Data()
        default:
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .useDefaultKeys
            return try encoder.encode(request)
        }
    }
}
