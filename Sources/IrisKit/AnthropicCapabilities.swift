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

    /// What a model does with reasoning effort and thinking display (#314 PR 7). Both read from
    /// one place: the request builder, the Settings picker and the setting's own validation.
    ///
    /// Measured by work's Vertex (global) probe, 2026-11-07: all three models accept exactly
    /// low, medium, high, xhigh and max for `output_config.effort` and answer 400 to anything else,
    /// and all three accept `thinking: {type: adaptive, display: "summarized"}` with no beta. The
    /// direct API route was NOT probed; it follows Vertex here, as `bindingBetaModels` does. An
    /// empty `effortLevels` means the model takes no effort, and a nil `display` means none is sent.
    struct ThinkingSupport: Equatable, Sendable {
        var effortLevels: [String]
        var display: String?
    }

    static let effortScale = ["low", "medium", "high", "xhigh", "max"]

    static let thinkingSupport: [String: ThinkingSupport] = [
        "claude-opus-5-5": ThinkingSupport(effortLevels: effortScale, display: "summarized"),
        "claude-fable-5-1": ThinkingSupport(effortLevels: effortScale, display: "summarized"),
        "claude-sonnet-5-5": ThinkingSupport(effortLevels: effortScale, display: "summarized"),
    ]

    /// The effort levels this model accepts, in the order the picker lists them. Empty for a
    /// model with none and for an id the table does not know: a level a model rejects is a 400
    /// on every request, so an unknown id is sent nothing.
    static func effortLevels(model: String) -> [String] {
        thinkingSupport[key(model)]?.effortLevels ?? []
    }

    /// The `thinking.display` mode to request, or nil to send none. It goes out only with a
    /// user-picked effort (`effortChosen`): a user who picks nothing sees the request they always
    /// had, which carries no `thinking` object unless the binding needs one (ruling 2). Whether
    /// the default should also ask for a summary is Brian's call, raised in the PR.
    static func thinkingDisplay(model: String, effortChosen: Bool) -> String? {
        effortChosen ? thinkingSupport[key(model)]?.display : nil
    }
}
