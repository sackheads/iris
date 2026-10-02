import Foundation

/// `--dump-requests <dir>`: reconstructs the same body the currently configured provider client
/// builds for one round, without touching the network (5a). Task 10 counts prefix sizes from
/// these dumps.
///
/// Anthropic and OpenAI each expose a pure, static `makeURLRequest(request:model:apiKey:baseURL:
/// stream:)` that returns the exact `URLRequest` a call would send; this reuses that builder
/// directly, passing the caller's `stream` flag so a dump matches what a real turn sends instead
/// of always claiming non-streaming (production streams by default). The result is exactly the
/// same body the client builds: every `JSONSerialization.data(withJSONObject:)` and `JSONEncoder`
/// on the request path now encodes with sorted keys, so two dumps of the same logical request are
/// byte-identical, and a byte-prefix diff against these dumps reflects a real content or prefix
/// change, never key reordering (`RequestByteStabilityTests`; previously confirmed unstable in
/// `RequestDumpTests`). The placeholder API key only ever reaches a header (`x-api-key` /
/// `Authorization`), never the body, and is never sent anywhere. Gemini has no equivalent static
/// builder — its instance method (`LLMClient.makeGeminiURLRequest`) reads
/// `ConfigManager.shared.geminiAPIKey` and performs an async ADC handshake before it ever touches
/// the body — but its wire body is nothing but `LLMClient.encodeGeminiBody(request)`, which both
/// call; Gemini's streaming and non-streaming bodies are identical, so its own `stream` argument
/// is unused.
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
            return try LLMClient.encodeGeminiBody(request)
        }
    }
}
