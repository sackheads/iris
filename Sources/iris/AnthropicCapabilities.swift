import Foundation

/// #314 decision 3: what each Anthropic model is known to do, keyed on its id with any date
/// dropped. It grows with its readers: each field arrives with the first code that reads it.
/// PR 1 ships only the binding beta's own gate; no stored field exists yet because nothing but
/// `takesBindingBeta` reads this table.
enum AnthropicCapabilities {
    /// Where the binding beta may go, on the API and Vertex alike. Vertex validates
    /// `anthropic-beta` and answers 400 "Unexpected value(s)" for a beta it does not accept; all
    /// three took it there, and Sonnet 5.5 took adaptive thinking and drop_block too (work's
    /// probe, 2026-10-06). The API is unprobed and follows Vertex.
    static let bindingBetaModels: Set<String> = ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"]

    static let bindingBeta = "thinking-binding-controls-2026-08-01"

    /// The Vertex spelling with its `@date` dropped, so the API's dated id, Vertex's and the bare
    /// alias find the same row. One normaliser with #385's `maxTokensKey`: this just calls it.
    static func key(_ model: String) -> String {
        AnthropicClient.maxTokensKey(model)
    }

    /// Whether the binding beta may go to this model on this route (decision 4, plan note 4). A
    /// beta a route rejects is a 400 on every request, so unknown ids never get it. A custom
    /// `baseURL` is unprobed: a gateway in front of it may validate `anthropic-beta` the way
    /// Vertex does and 400 every request, so it gets no header regardless of model.
    static func takesBindingBeta(model: String, transport: AnthropicTransport) -> Bool {
        switch transport {
        case .direct(_, let baseURL): return baseURL.isEmpty && bindingBetaModels.contains(key(model))
        case .vertex: return bindingBetaModels.contains(key(model))
        }
    }
}
