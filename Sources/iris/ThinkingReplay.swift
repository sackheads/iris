import Foundation

/// #314 Phase 1: which thinking blocks one turn sends back. Only this turn's replies, and only
/// those after the turn's last divergence, so whatever is left out is always a run dropped from
/// the front, the one drop the API accepts (PTM §3).
///
/// The mechanism is one prefix-continuity check (amends spec decision 2): before each send, the
/// outgoing system, tools and messages must extend exactly what the server last saw, which is
/// the last request plus the reply as it came back. `cache_control` is not part of `Content`, so it
/// is ignored by construction. Blocks below the floor are ignored on both sides, so a front strip is
/// never an edit. Anything else (a UI edit, a PreCompress list giving way to AppState's, a
/// BeforeModel rewrite of messages, system or tools, or its undoing, an AfterModel rewrite of the
/// stored reply, a hook dropping blocks) diverges, and every block produced so far stays out from
/// then on. A hook that rewrites identically every round does not diverge, and keeps replay.
///
/// Comparing `Content` instead of wire bytes is sound only because `AnthropicClient`'s encoding
/// is a pure function of the whole contents: the same contents give the same messages,
/// `cache_control` aside. Keep it so. It is not a function of each message alone: `echoFrom` makes
/// whether message i is echoed depend on later messages. Only an unechoable reply above the floor
/// changes earlier messages' bytes that way, and such a reply only arrives through a hook, which
/// already diverges. Any merge of adjacent user messages (the API's, or a future client's) only
/// touches the tail after the newest reply, so it never moves a byte before a replayed block.
///
/// Accepted gap: an image is fingerprinted by its MIME type and length (5a's anchor bytes), so a
/// mid-turn swap for a same-type, same-length image is not seen. That takes a UI edit replacing an
/// image while the turn runs, and the backstop retry covers it.
///
/// One value per turn, a local of `processInputBody`: never on the engine or `AppState`, where
/// another turn or a subagent would share it (invariant 3).
struct ThinkingReplay: Sendable {
    /// One message as the check sees it: its blockless 5a anchor bytes (sorted-key JSON, each
    /// image stood in for by MIME type and length) and its `anthropicBlocks` text as stored.
    /// Each outgoing message is encoded once per send, and that fingerprint is carried forward
    /// as what the next send compares against. Nothing is encoded twice.
    struct Fingerprint: Equatable, Sendable {
        let bare: Data
        let blocks: String?
    }

    /// History index (AppState's list) below which no blocks are sent. Only ever rises.
    ///
    /// A message below the floor is rebuilt from `parts` (Task 9). One that was echoed verbatim
    /// before the rise therefore changes bytes, which is safe because every rise goes to AppState's
    /// whole history length: no block produced before the switch is ever sent after it, and every
    /// later block is bound to the rebuilt form, which then never changes again.
    private(set) var floor: Int
    private var lastSystemAndTools: Data?
    /// The last request's messages, then the reply as received: what the next request must extend.
    private var expected: [Fingerprint]?

    init(floor: Int) { self.floor = floor }

    mutating func raiseFloor(to index: Int) { floor = max(floor, index) }

    func applyingFloor(_ contents: [Content]) -> [Content] {
        var out = contents
        for i in out.indices where i < floor { out[i].anthropicBlocks = nil }
        return out
    }

    static func withoutBlocks(_ contents: [Content]) -> [Content] {
        contents.map { var c = $0; c.anthropicBlocks = nil; return c }
    }

    static func fingerprint(_ content: Content) -> Fingerprint {
        var bare = content
        bare.anthropicBlocks = nil
        return Fingerprint(bare: TurnContext.anchorBytes(of: bare) ?? Data(), blocks: content.anthropicBlocks)
    }

    /// nil when `outgoing` extends what the server last saw; otherwise the first message that
    /// differs, or 0 when the system instruction or the tools changed.
    private func divergence(systemAndTools: Data?, outgoing: [Fingerprint]) -> Int? {
        guard let expected else { return nil }
        if systemAndTools != lastSystemAndTools { return 0 }
        for i in expected.indices {
            guard i < outgoing.count else { return i }
            if outgoing[i].bare != expected[i].bare { return i }
            // Below the floor the outgoing side has no blocks by construction; compare above it.
            if i >= floor, outgoing[i].blocks != expected[i].blocks { return i }
        }
        return nil
    }

    /// Run once per send, on the request exactly as it will go out (after the BeforeModel hook).
    /// `historyCount` is AppState's history length now. Nothing at or past it is a reply this turn
    /// received. On a divergence the floor rises to it, past every block produced so far, since
    /// each was bound to the prefix that changed. Returns the divergence.
    @discardableResult
    mutating func prepare(_ request: inout GeminiRequest, historyCount: Int) -> Int? {
        request.contents = applyingFloor(request.contents)
        for i in request.contents.indices where i >= historyCount { request.contents[i].anthropicBlocks = nil }
        let systemAndTools = Self.systemAndTools(request)
        var fingerprints = request.contents.map(Self.fingerprint)
        let diverged = divergence(systemAndTools: systemAndTools, outgoing: fingerprints)
        if diverged != nil {
            raiseFloor(to: historyCount)
            request.contents = Self.withoutBlocks(request.contents)
            fingerprints = fingerprints.map { Fingerprint(bare: $0.bare, blocks: nil) }
        }
        lastSystemAndTools = systemAndTools
        expected = fingerprints
        return diverged
    }

    /// The reply as the model returned it, before any hook: what the server will expect next.
    mutating func recordReceived(_ reply: Content?) {
        if let reply { expected?.append(Self.fingerprint(reply)) }
    }

    private static func systemAndTools(_ request: GeminiRequest) -> Data? {
        struct Bound: Encodable { let system: Content?; let tools: [Tool]? }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Bound(system: request.systemInstruction, tools: request.tools))
    }
}
