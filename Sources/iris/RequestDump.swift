import Foundation

/// `--dump-requests <dir>`: reconstructs the same body the currently configured provider client
/// builds for one round, without touching the network (5a). Task 10 counts prefix sizes from
/// these dumps.
///
/// Anthropic and OpenAI each expose a pure, static `makeURLRequest(request:model:apiKey:baseURL:
/// stream:)` that returns the exact `URLRequest` a call would send; this reuses that builder
/// directly, passing the caller's `stream` flag so a dump matches what a real turn sends instead
/// of always claiming non-streaming (production streams by default). The result is the same body
/// the client builds, key order aside, until requests are encoded with sorted keys:
/// `JSONSerialization.data(withJSONObject:)`, which both builders use, does not guarantee a stable
/// key order across calls (confirmed independently; see `RequestDumpTests`), so a byte-prefix diff
/// against these dumps should treat a reordering as noise, not a real divergence. The placeholder
/// API key only ever reaches a header (`x-api-key` / `Authorization`), never the body, and is
/// never sent anywhere. Gemini has no equivalent static builder — its instance method
/// (`LLMClient.makeGeminiURLRequest`) reads `ConfigManager.shared.geminiAPIKey` and performs an
/// async ADC handshake before it ever touches the body — but its wire body is nothing but the
/// request's own JSON encoding (`encoder.keyEncodingStrategy = .useDefaultKeys; encoder.encode
/// (request)`), so that one line is replicated directly here instead; Gemini's streaming and
/// non-streaming bodies are identical, so its own `stream` argument is unused.
enum RequestDump {
    /// Never sent over the network: only ever used locally to build a request whose body we then
    /// discard the transport for and write to disk instead.
    static let placeholderAPIKey = "perf-dump-placeholder"

    static func body(for request: GeminiRequest, provider: String, model: String, stream: Bool) throws -> Data {
        switch provider {
        case LLMProvider.anthropic.rawValue:
            let urlRequest = try AnthropicClient.makeURLRequest(request: request, model: model, apiKey: placeholderAPIKey, stream: stream)
            return urlRequest.httpBody ?? Data()
        case LLMProvider.openai.rawValue:
            let urlRequest = try OpenAIClient.makeURLRequest(request: request, model: model, apiKey: placeholderAPIKey, stream: stream)
            return urlRequest.httpBody ?? Data()
        default:
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .useDefaultKeys
            return try encoder.encode(request)
        }
    }
}
