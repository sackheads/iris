import Testing
import Foundation
@testable import iris

/// #314 engine tests: a scripted client that records what the engine sent, replies carrying fake
/// signed blocks, hooks as shell scripts in a temp dir of the test's own, and the Anthropic body
/// each recorded request builds. No network, no `ConfigManager.shared` writes (invariant 7).
final class RecordingClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    private let script: [GeminiResponse]

    init(_ script: [GeminiResponse]) { self.script = script }

    var requests: [GeminiRequest] { lock.withLock { recorded } }

    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        let n = lock.withLock { recorded.append(request); return recorded.count }
        return script[min(n - 1, script.count - 1)]
    }
}

enum ThinkingFixtures {
    struct Failure: Error { let message: String }

    static func thinkingBlock(_ n: Int) -> String { #"{"type":"thinking","thinking":"","signature":"sig-\#(n)"}"# }

    /// Reply `n`: one signed thinking block, then a `search_memory` call whose input keeps the
    /// model's own spacing (so a verbatim echo is visible), or a closing text.
    static func reply(_ n: Int, toolCall: Bool) -> GeminiResponse {
        if toolCall {
            let id = "toolu_\(n)"
            let blocks = "[\(thinkingBlock(n)),{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"search_memory\",\"input\":{\"query\": \"Seattle \(n)\"}}]"
            let call = FunctionCall(name: "search_memory", args: ["query": .string("Seattle \(n)")], id: id)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)],
                                                                          anthropicBlocks: blocks))], usageMetadata: nil)
        }
        let blocks = "[\(thinkingBlock(n)),{\"type\":\"text\",\"text\":\"done \(n)\"}]"
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done \(n)")],
                                                                      anthropicBlocks: blocks))], usageMetadata: nil)
    }

    /// Reply `n` from a model that did not think: no blocks at all (work's probe: Fable 5.1, 12 of 12).
    static func unthought(_ n: Int, toolCall: Bool) -> GeminiResponse {
        var r = reply(n, toolCall: toolCall)
        r.candidates?[0].content?.anthropicBlocks = nil
        return r
    }

    /// Three tool rounds, then an answer: four requests in one turn.
    static func fourRounds() -> [GeminiResponse] {
        [reply(1, toolCall: true), reply(2, toolCall: true), reply(3, toolCall: true), reply(4, toolCall: false)]
    }

    static func tempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-314-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A HookManager reading only `dir/settings.json`, with each event's hook the given `/bin/sh`
    /// script. No events means no hooks at all.
    static func hooks(in dir: URL, _ scripts: [String: String] = [:]) throws -> HookManager {
        var events: [String: Any] = [:]
        for (event, script) in scripts {
            let url = dir.appendingPathComponent("\(event).sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            events[event] = [["matcher": event, "hooks": [["type": "command", "command": "/bin/sh '\(url.path)'"]]]]
        }
        let settings = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["hooks": events]).write(to: settings)
        var manager = HookManager()
        manager.configPathOverride = settings.path
        return manager
    }

    /// A script that runs `sed` on call `n` only and passes its input through otherwise.
    static func onCall(_ n: Int, sed expression: String, counter: URL) -> String {
        """
        c=$(cat '\(counter.path)' 2>/dev/null || echo 0); c=$((c+1)); echo $c > '\(counter.path)'
        if [ "$c" -eq \(n) ]; then sed -E '\(expression)'; else cat; fi
        """
    }

    static func urlRequest(_ request: GeminiRequest, model: String = "claude-opus-5-5") throws -> URLRequest {
        try AnthropicClient.makeURLRequest(request: request, model: model, apiKey: "k", stream: true)
    }

    static func body(_ request: GeminiRequest, model: String = "claude-opus-5-5") throws -> [String: Any] {
        let data = try urlRequest(request, model: model).httpBody ?? Data()
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "the body is not a JSON object")
        }
        return body
    }

    static func bodyText(_ request: GeminiRequest, model: String = "claude-opus-5-5") throws -> String {
        String(decoding: try urlRequest(request, model: model).httpBody ?? Data(), as: UTF8.self)
    }

    /// Every thinking signature in a body's messages, in order.
    static func signatures(_ body: [String: Any]) -> [String] {
        (body["messages"] as? [[String: Any]] ?? []).flatMap { message in
            (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "thinking" }
                .compactMap { $0["signature"] as? String }
        }
    }

    /// Each message of a body with every `cache_control` removed, as sorted-key bytes.
    static func messagesIgnoringCacheControl(_ body: [String: Any]) throws -> [Data] {
        func strip(_ v: Any) -> Any {
            if let d = v as? [String: Any] { return d.filter { $0.key != "cache_control" }.mapValues(strip) }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        return try (body["messages"] as? [[String: Any]] ?? []).map {
            try JSONSerialization.data(withJSONObject: strip($0), options: [.sortedKeys])
        }
    }

    /// Spec §2.1: each request's blocks are a contiguous run ending at the newest block this
    /// turn produced before it (a front-dropped window), and a block left out once stays out.
    /// `produced[i]` is reply i+1's signature, or nil for a reply that did not think.
    static func expectFrontDroppedWindows(_ sent: [[String]], produced: [String?],
                                          sourceLocation: SourceLocation = #_sourceLocation) {
        var dropped = 0
        for (n, blocks) in sent.enumerated() {
            let available = produced.prefix(n).compactMap { $0 }
            guard let first = blocks.first else { dropped = available.count; continue }
            guard let start = available.firstIndex(of: first) else {
                Issue.record("request \(n + 1) sends \(first), which no earlier reply of this turn produced",
                             sourceLocation: sourceLocation)
                continue
            }
            #expect(Array(available[start...]) == blocks, "request \(n + 1) is not a contiguous tail",
                    sourceLocation: sourceLocation)
            #expect(start >= dropped, "request \(n + 1) sends a block an earlier request left out",
                    sourceLocation: sourceLocation)
            dropped = start
        }
    }
}

/// One conversation on an engine over a recording client. `earlierTurn` seeds a finished turn
/// whose reply carries a block signed `sig-0`; `seedFact` gives the turn a non-empty context.
@MainActor
struct ThinkingHarness {
    let app: AppState
    let id: UUID
    let client: RecordingClient
    let engine: IrisEngine
    var history: [Content] { app.conversations.first { $0.id == id }?.history ?? [] }

    static func make(_ script: [GeminiResponse], hooks: HookManager, store: ConversationStore? = nil,
                     seedFact: Bool = false, earlierTurn: Bool = false,
                     roundStart: (@Sendable (Int) async -> Void)? = nil) throws -> ThinkingHarness {
        let facts = try FactStoreManager(inMemory: true)
        if seedFact { _ = try facts.addFact(content: "Brian lives in Seattle") }
        let app = AppState(store: try store ?? ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation(title: "thinking")
        if earlierTurn {
            app.appendContentToHistory(for: id, content: Content(role: "user", parts: [Part(text: "earlier question")]))
            app.appendContentToHistory(for: id, content: Content(
                role: "model", parts: [Part(text: "earlier answer")],
                anthropicBlocks: "[\(ThinkingFixtures.thinkingBlock(0)),{\"type\":\"text\",\"text\":\"earlier answer\"}]"))
        }
        let client = RecordingClient(script)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: false, factStore: facts, protectionEnabled: false,
                                sessionPeerCount: 0, roundStartHook: roundStart, hooks: hooks)
        return ThinkingHarness(app: app, id: id, client: client, engine: engine)
    }

    func run(_ input: String = "Tell me about Seattle") async {
        await engine.processInput(input, source: "UI", conversationId: id)
    }

    /// The signatures in the Anthropic body of each request the engine sent.
    func sentSignatures() throws -> [[String]] {
        try client.requests.map { ThinkingFixtures.signatures(try ThinkingFixtures.body($0)) }
    }
}
