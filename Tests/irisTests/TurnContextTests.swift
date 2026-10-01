import Testing
import Foundation
@testable import iris

private let factHeading = "# Mid-Term Fact Store Memory (JIT Context)"

private func encoded(_ c: Content) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try! encoder.encode(c)
}

private func encoded(_ cs: [Content]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try! encoder.encode(cs)
}

private func user(_ text: String) -> Content { Content(role: "user", parts: [Part(text: text)]) }
private func model(_ text: String) -> Content { Content(role: "model", parts: [Part(text: text)]) }

/// The block itself: what it renders, and where it is allowed to land (5a §1, Review Focus 2).
@Suite("TurnContext block (5a)")
struct TurnContextTests {
    private let context = TurnContext(sections: [
        .init(heading: "Mid-Term Fact Store Memory (JIT Context)", body: "- [f1] Brian lives in Seattle"),
        .init(heading: "Sessions", body: "2 other sessions are active.")
    ])

    @Test("rendered() wraps every section in one turn_context element")
    func rendersSections() {
        #expect(context.rendered() == """
        <turn_context>
        # Mid-Term Fact Store Memory (JIT Context)
        - [f1] Brian lives in Seattle

        # Sessions
        2 other sessions are active.
        </turn_context>
        """)
    }

    @Test("applied inserts the block as the leading part of the anchor entry and nowhere else")
    func insertsAtAnchorOnly() {
        let contents = [user("earlier"), model("reply"), user("now"), model("thinking")]
        let out = context.applied(to: contents, anchor: 2, anchorBytes: TurnContext.anchorBytes(of: contents[2]))
        #expect(out.count == contents.count)
        #expect(out[2].parts.count == 2)
        #expect(out[2].parts[0].text == context.rendered())
        #expect(out[2].parts.dropFirst().first?.text == "now")
        #expect(out[2].role == "user")
        for i in [0, 1, 3] { #expect(encoded(out[i]) == encoded(contents[i]), "entry \(i) must be untouched") }
    }

    @Test("an anchor out of range, or whose entry no longer encodes the same, leaves contents unchanged")
    func refusesWrongEntry() {
        // The same text at a different index: comparing the first text would match "yes" here.
        let original = Content(role: "user", parts: [Part(text: "yes"), Part(text: "attachment note")])
        let anchorBytes = TurnContext.anchorBytes(of: original)
        #expect(anchorBytes != nil)

        let outOfRange = [user("yes")]
        #expect(encoded(context.applied(to: outOfRange, anchor: 3, anchorBytes: anchorBytes)) == encoded(outOfRange))
        #expect(encoded(context.applied(to: outOfRange, anchor: -1, anchorBytes: anchorBytes)) == encoded(outOfRange))

        // A different user entry whose first text is identical sits at the anchor.
        let rewritten = [model("hi"), user("yes")]
        #expect(encoded(context.applied(to: rewritten, anchor: 1, anchorBytes: anchorBytes)) == encoded(rewritten))

        // No bytes to validate against: nothing is attached.
        let intact = [model("hi"), original]
        #expect(encoded(context.applied(to: intact, anchor: 1, anchorBytes: nil)) == encoded(intact))
        // Control: with matching bytes the same call does attach.
        #expect(context.applied(to: intact, anchor: 1, anchorBytes: anchorBytes)[1].parts.count == 3)
    }

    @Test("a turn's anchor is its last user entry, taken once; a broken anchor is reported on the first round only")
    func turnRequestReportsOnce() {
        let history = [user("earlier"), model("reply"), user("now")]
        var turn = TurnRequest(context: context, history: history)
        #expect(turn.anchor == 2)

        // Later rounds append a tool call and a role-`user` tool result; the anchor does not move.
        let later = history + [model("call"), user("tool result")]
        let (attached, firstDrop) = turn.contents(for: later)
        #expect(!firstDrop)
        #expect(attached[2].parts.first?.text == context.rendered())
        #expect(encoded(attached[4]) == encoded(later[4]))

        // Something rewrote the turn's entry: nothing attached, reported once.
        let rewritten = [user("earlier"), model("reply"), user("now, edited")]
        let first = turn.contents(for: rewritten)
        #expect(first.firstDrop)
        #expect(encoded(first.contents) == encoded(rewritten))
        #expect(!turn.contents(for: rewritten).firstDrop)
    }

    @Test("an empty context returns the input byte-equal")
    func emptyIsIdentity() {
        let contents = [user("earlier"), model("reply"), user("now")]
        let empty = TurnContext(sections: [])
        #expect(empty.isEmpty)
        let out = empty.applied(to: contents, anchor: 2, anchorBytes: TurnContext.anchorBytes(of: contents[2]))
        #expect(encoded(out) == encoded(contents))
    }
}

/// Records every request; replies from a script, and runs `onCall` (with the 1-based call number)
/// before replying, so a test can queue a steer between rounds deterministically.
private final class TurnContextClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    private let script: [GeminiResponse]
    private let onCall: @Sendable (Int) async -> Void

    init(_ script: [GeminiResponse], onCall: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.script = script
        self.onCall = onCall
    }

    var requests: [GeminiRequest] { lock.withLock { recorded } }

    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        let n = lock.withLock { recorded.append(request); return recorded.count }
        await onCall(n)
        return script[min(n - 1, script.count - 1)]
    }
}

private func reply(_ text: String) -> GeminiResponse {
    GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))], usageMetadata: nil)
}

private func toolCall(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
    let fc = FunctionCall(name: name, args: args, id: "c1", thought_signature: nil, thoughtSignature: nil)
    return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: fc)]))],
                          usageMetadata: nil)
}

private func systemText(_ r: GeminiRequest) -> String {
    r.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
}

/// The block on a real turn: where it rides, that it holds across rounds and steers, and that it
/// never reaches history (5a §1, §3 unit tests 2-4). In-memory fact store and an injected peer
/// count; nothing here reads `FactStoreManager.shared` or mutates `ConfigManager.shared`.
@MainActor
@Suite("TurnContext on an engine turn (5a)")
struct TurnContextEngineTests {
    @MainActor private struct Run {
        let app: AppState
        let id: UUID
        let client: TurnContextClient
        var history: [Content] { app.conversations.first { $0.id == id }?.history ?? [] }
    }

    /// One turn of "Tell me about Seattle" against a store holding a Seattle fact (unless
    /// `seedFact` is false). Round 1 calls `search_memory`, round 2 answers, so the turn has two
    /// model rounds. `steer`, when set, is queued while round 1 is in flight.
    private func run(seedFact: Bool = true, peers: Int = 2, steer: String? = nil,
                     store: ConversationStore? = nil) async throws -> Run {
        let facts = try FactStoreManager(inMemory: true)
        if seedFact { _ = try facts.addFact(content: "Brian lives in Seattle") }
        let app = store.map { AppState(store: $0, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned) } ?? AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = TurnContextClient(
            [toolCall("search_memory", ["query": .string("Seattle")]), reply("done")],
            onCall: { n in
                guard n == 1, let steer else { return }
                await MainActor.run { app.enqueuePendingUserMessage(text: steer, attachments: [], for: id) }
            })
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: peers)
        await engine.processInput("Tell me about Seattle", source: "UI", conversationId: id)
        return Run(app: app, id: id, client: client)
    }

    @Test("every round's turn entry leads with the block, and the system prompt no longer holds it")
    func blockRidesTurnEntry() async throws {
        let r = try await run()
        let requests = r.client.requests
        #expect(requests.count == 2)
        for (i, request) in requests.enumerated() {
            let lead = request.contents.first?.parts.first?.text ?? ""
            #expect(lead.hasPrefix("<turn_context>"), "round \(i)")
            #expect(lead.contains(factHeading), "round \(i)")
            #expect(lead.contains("Brian lives in Seattle"), "round \(i)")
            #expect(lead.contains("2 other sessions are active."), "round \(i)")
            #expect(request.contents.first?.parts.dropFirst().first?.text == "Tell me about Seattle", "round \(i)")
            #expect(!systemText(request).contains(factHeading), "round \(i)")
            #expect(!systemText(request).contains("other sessions are active"), "round \(i)")
        }
    }

    @Test("the block is byte-identical in round 1 and round 2")
    func blockStableAcrossRounds() async throws {
        let r = try await run()
        let requests = r.client.requests
        try #require(requests.count == 2)
        #expect(encoded(requests[0].contents[0]) == encoded(requests[1].contents[0]))
        // And round 2 really is a later round: it carries the tool call and its result.
        #expect(requests[1].contents.count == 3)
    }

    @Test("a steer queued between rounds leaves the block on the original entry")
    func steerKeepsAnchor() async throws {
        let r = try await run(steer: "also check Portland")
        let requests = r.client.requests
        try #require(requests.count == 2)
        let round2 = requests[1].contents
        #expect(round2.last?.parts.first?.text == "User (mid-task): also check Portland")
        #expect(encoded(round2[0]) == encoded(requests[0].contents[0]))
        let carrying = round2.indices.filter { i in round2[i].parts.contains { $0.text?.contains("<turn_context>") == true } }
        #expect(carrying == [0], "only the turn's own entry carries the block")
    }

    @Test("history never holds the block, before or after a save and reload")
    func neverPersisted() async throws {
        let store = try ConversationStore.inMemory()
        let r = try await run(store: store)
        #expect(r.client.requests.first?.contents.first?.parts.first?.text?.hasPrefix("<turn_context>") == true,
                "control: the block was sent")
        func clean(_ h: [Content]) -> Bool { !h.flatMap(\.parts).contains { $0.text?.contains("<turn_context>") == true } }
        #expect(!r.history.isEmpty)
        #expect(clean(r.history))
        r.app.flushSave()
        let loaded = try store.loadAll().conversations.first { $0.id == r.id }?.history ?? []
        #expect(loaded.count == r.history.count)
        #expect(clean(loaded))
    }

    @Test("a turn with no fact match and no peers sends the turn entry exactly as saved")
    func emptyAddsNothing() async throws {
        let r = try await run(seedFact: false, peers: 0)
        let requests = r.client.requests
        try #require(requests.count == 2)
        let saved = r.history
        for request in requests {
            #expect(encoded(request.contents) == encoded(Array(saved.prefix(request.contents.count))))
        }
    }
}
