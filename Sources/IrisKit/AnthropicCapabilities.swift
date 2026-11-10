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

    /// The `thinking.display` mode to request, or nil to send none: the table's, for a model it
    /// lists, whether or not an effort was picked (#1018). The stream carries thinking text only
    /// when the request asks for a display, because the API's default is "omitted"; gating it on
    /// a picked effort left every user at "Model default" with no live thinking. It rides an
    /// adaptive `thinking` object, which is what those models run anyway. A model the table does
    /// not list gets nil, so nothing new goes to it.
    static func thinkingDisplay(model: String) -> String? {
        thinkingSupport[key(model)]?.display
    }

    /// Endpoints that rejected `thinking.display` (#1018): the 400 named it, and the retry without it
    /// then succeeded. Kept for the life of the process so only the first request to one ever fails.
    /// Per endpoint, not per model: a gateway that rejects it for one model drops it for the others
    /// there too, which fails soft. The route table cannot
    /// say which custom base URLs take the field, so the answer is learned, per endpoint. In memory
    /// on purpose: a relaunch costs one retried request, and nothing is persisted that a route
    /// fixing itself would leave stale.
    private final class DisplayRejections: @unchecked Sendable {
        private let lock = NSLock()
        private var endpoints: Set<String> = []
        func contains(_ key: String) -> Bool { lock.withLock { endpoints.contains(key) } }
        func insert(_ key: String) { lock.withLock { _ = endpoints.insert(key) } }
    }
    private static let displayRejections = DisplayRejections()

    private static func endpointKey(_ transport: AnthropicTransport) -> String {
        switch transport {
        case .direct(_, let baseURL): return "direct|\(baseURL)"
        case .vertex(let project, let location, _): return "vertex|\(project)|\(location)"
        }
    }

    static func rejectsDisplay(_ transport: AnthropicTransport) -> Bool {
        displayRejections.contains(endpointKey(transport))
    }

    static func rememberDisplayRejection(_ transport: AnthropicTransport) {
        displayRejections.insert(endpointKey(transport))
    }
}
