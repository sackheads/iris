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
        .init(heading: "Active Sessions", body: "2 other sessions are active.")
    ])

    @Test("rendered() wraps every section in one turn_context element")
    func rendersSections() {
        #expect(context.rendered() == """
        <turn_context>
        # Mid-Term Fact Store Memory (JIT Context)
        - [f1] Brian lives in Seattle

        # Active Sessions
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
        var turn = TurnRequest(context: context, stateHistory: history, initialHistory: history)
        #expect(turn.stateAnchor == 2)

        // Later rounds append a tool call and a role-`user` tool result; the anchor does not move.
        let later = history + [model("call"), user("tool result")]
        let (attached, firstDrop) = turn.contents(for: later, from: .state)
        #expect(!firstDrop)
        #expect(attached[2].parts.first?.text == context.rendered())
        #expect(encoded(attached[4]) == encoded(later[4]))

        // Something rewrote the turn's entry: nothing attached, reported once.
        let rewritten = [user("earlier"), model("reply"), user("now, edited")]
        let first = turn.contents(for: rewritten, from: .state)
        #expect(first.firstDrop)
        #expect(encoded(first.contents) == encoded(rewritten))
        #expect(!turn.contents(for: rewritten, from: .state).firstDrop)
    }

    /// Review fix 1: a PreCompress hook that shortens history must not shift the index applied to
    /// AppState's list onto an earlier message that happens to encode the same.
    @Test("after a hook-shortened round one, later rounds put the block on the turn entry, not an earlier twin")
    func hookRewrittenHistory() {
        let state = [user("yes"), model("noted"), user("yes")]   // index 2 is this turn's entry
        let hooked = [user("yes")]                              // the hook compressed the past away
        var turn = TurnRequest(context: context, stateHistory: state, initialHistory: hooked)

        let round1 = turn.contents(for: hooked, from: .initial)
        #expect(!round1.firstDrop)
        #expect(round1.contents[0].parts.first?.text == context.rendered())

        let round2History = state + [model("call"), user("tool result")]
        let round2 = turn.contents(for: round2History, from: .state)
        #expect(!round2.firstDrop)
        let carrying = round2.contents.indices.filter { round2.contents[$0].parts.count == 2 }
        #expect(carrying == [2], "only the turn's own entry, never the earlier byte-identical \"yes\"")
        #expect(encoded(round2.contents[0]) == encoded(state[0]))
    }

    @Test("an earlier byte-identical entry never receives the block, even when the turn entry is gone")
    func earlierTwinNeverChosen() {
        let state = [user("yes"), model("noted"), user("yes")]
        var turn = TurnRequest(context: context, stateHistory: state, initialHistory: state)
        // The UI removed the turn's entry; index 2 now holds something else, index 0 still says "yes".
        let edited = [user("yes"), model("noted"), model("later")]
        let out = turn.contents(for: edited, from: .state)
        #expect(out.firstDrop)
        #expect(encoded(out.contents) == encoded(edited))
        // And with the entry present, only index 2 carries it.
        let intact = turn.contents(for: state + [model("r")], from: .state).contents
        #expect(intact[0].parts.count == 1)
        #expect(intact[2].parts.first?.text == context.rendered())
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
            #expect(lead.contains("# Active Sessions\n2 other sessions are active."), "round \(i)")
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

/// Counts calls into the tier-2 model rather than reporting a fixed verdict, so a test can prove
/// the guard was (or was not) invoked at all — not just see what it returned. `InjectionGuard`
/// already memoizes a verdict per content/config, so this is the only way to observe whether
/// `IrisEngine`'s own cache (5a Task 7) kept the content from ever reaching the tiers a second time.
private final class CountingCoreMLModel: CoreMLModelProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func evaluate(text: String) async throws -> Double {
        lock.withLock { calls += 1 }
        return 0.0
    }
}

/// Mirror of `CountingCoreMLModel` for the tier-3 canary engine.
private final class CountingInferenceEngine: AuxiliaryInferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func loadModel(config: AuxiliaryModelConfig) async throws {}
    func unloadModel() async {}
    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        lock.withLock { calls += 1 }
        return "SAFE"
    }
}

/// Throws on its first call (simulating a transient tier-3 outage), then answers normally — proves
/// `IrisEngine`'s guarded-file cache (5a Task 7 fix round 1) never pins a transient error as a
/// permanent block.
private final class FlakyThenHealthyInferenceEngine: AuxiliaryInferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func loadModel(config: AuxiliaryModelConfig) async throws {}
    func unloadModel() async {}
    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        let n = lock.withLock { calls += 1; return calls }
        if n == 1 {
            struct TransientError: Error {}
            throw TransientError()
        }
        return "SAFE"
    }
}

/// Throws the first time it is asked about text containing `marker`, and answers SAFE otherwise.
/// USER.md is guarded before AGENTS.md on every turn, so a fail-first engine would spend its one
/// error on USER.md; keying on the probe text aims the error at the file under test.
private final class FlakyOnceForMarkerInferenceEngine: AuxiliaryInferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    let marker: String
    init(marker: String) { self.marker = marker }
    func loadModel(config: AuxiliaryModelConfig) async throws {}
    func unloadModel() async {}
    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        let fail = lock.withLock { () -> Bool in
            guard !failed, prompt.contains(marker) else { return false }
            failed = true
            return true
        }
        if fail {
            struct TransientError: Error {}
            throw TransientError()
        }
        return "SAFE"
    }
}

/// `USER.md` and the workspace's `AGENTS.md` are re-read and re-guarded only when they actually
/// change (5a Task 7) — the engine-level cache in `IrisEngine.guardedUserProfileText` /
/// `guardedAgentsMdText` / `assembledSystemPrompt`. `IrisEngine(memory:)` (fix round 1) is an
/// injection seam mirroring `factStore:`: a test that needs an isolated USER.md constructs its own
/// `MemoryManager(paths:)` and hands it to the engine, so none of these ever mutate the
/// process-global `MemoryManager.shared.paths` (invariant 7). No `.serialized` needed — nothing
/// here shares mutable state across tests any more.
@MainActor
@Suite("USER.md / AGENTS.md guarded-text cache (5a Task 7)")
struct GuardedFileCacheTests {

    private func newConversation(_ app: AppState) -> UUID {
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        return id
    }

    /// A fresh `MemoryManager` over its own temp `IrisPaths` (fix round 1's injection seam). Callers
    /// clean up `paths.root` themselves.
    private func tempMemory() -> (manager: MemoryManager, paths: IrisPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-guard-cache-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        return (MemoryManager(paths: paths), paths)
    }

    /// Reads a modification date exactly the way `IrisEngine.fileModificationDate` does — through
    /// the symlink-following seam — so a captured stamp and a later comparison can never disagree
    /// over which API read it.
    private func modDate(_ url: URL) -> Date? {
        try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Restores a file's modification date to exactly `date`. `URL.setResourceValues` round-trips
    /// bit-for-bit with `resourceValues(forKeys:)` (both go through the same `URLResourceValues`
    /// bridging); `FileManager.setAttributes(.modificationDate:)` does not — it loses enough
    /// sub-second precision converting through `NSDate`/`timespec` that the date read back compares
    /// unequal to the one that was set, which would make this file's restored timestamp look like a
    /// change that never happened.
    private func restoreModDate(_ url: URL, to date: Date) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.contentModificationDate = date
        try mutableURL.setResourceValues(values)
    }

    /// The real, deterministic signal that the cache is doing anything at all: black-box output is
    /// identical whether the engine re-reads every turn or not, so a test that only checks the
    /// FINAL text (`profileRefreshesAfterUpdate`, `agentsMdRefreshesOnChange`) would pass unchanged
    /// against the pre-Task-7 code, which always re-reads — it was never red. This test pins the
    /// mechanism directly: edit the file's bytes but restore its PRIOR modification date exactly,
    /// so the stamp genuinely does not change. A cache keyed on the stamp must then serve the old
    /// text; a naive re-read would show the new bytes regardless of mtime.
    @Test("a stamp-unchanged turn serves the cached USER.md text even though the file's bytes changed underneath")
    func profileCacheTrustsUnchangedStamp() async throws {
        let (manager, paths) = tempMemory()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let v1 = "V1 \(UUID().uuidString)"
        manager.updateUserProfile(content: v1)
        let originalModified = modDate(paths.userMd)

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0, memory: manager)

        await engine.processInput("one", source: "UI", conversationId: id)

        let v2 = "V2 \(UUID().uuidString)"
        try v2.write(to: paths.userMd, atomically: true, encoding: .utf8)
        if let originalModified {
            try restoreModDate(paths.userMd, to: originalModified)
        }

        await engine.processInput("two", source: "UI", conversationId: id)

        let requests = client.requests
        try #require(requests.count == 2)
        #expect(systemText(requests[0]).contains(v1))
        #expect(systemText(requests[1]).contains(v1), "the stamp did not move, so the cache must serve the prior text")
        #expect(!systemText(requests[1]).contains(v2))
    }

    /// `AGENTS.md` mirror of `profileCacheTrustsUnchangedStamp`, per workspace.
    @Test("a stamp-unchanged turn serves the cached AGENTS.md text even though the file's bytes changed underneath")
    func agentsCacheTrustsUnchangedStamp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-agents-stable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentsPath = dir.appendingPathComponent("AGENTS.md")

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else {
            Issue.record("conversation not found")
            return
        }
        app.conversations[idx].workspacePath = dir.path
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)

        try "agents v1".write(to: agentsPath, atomically: true, encoding: .utf8)
        let originalModified = modDate(agentsPath)
        await engine.processInput("one", source: "UI", conversationId: id)

        try "agents v2".write(to: agentsPath, atomically: true, encoding: .utf8)
        if let originalModified {
            try restoreModDate(agentsPath, to: originalModified)
        }
        await engine.processInput("two", source: "UI", conversationId: id)

        let requests = client.requests
        try #require(requests.count == 2)
        #expect(systemText(requests[0]).contains("agents v1"))
        #expect(systemText(requests[1]).contains("agents v1"), "the stamp did not move, so the cache must serve the prior text")
        #expect(!systemText(requests[1]).contains("agents v2"))
    }

    @Test("two turns with an unchanged AGENTS.md run tier 2/3 once, not twice")
    func agentsMdGuardedOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-agents-once-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unique = "Prefers \(UUID().uuidString) for everything."
        try unique.write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else {
            Issue.record("conversation not found")
            return
        }
        app.conversations[idx].workspacePath = dir.path
        let client = CapturingLLMClient(reply: "ok")
        let (manager, paths) = tempMemory()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: true, sessionPeerCount: 0, memory: manager)

        let coreML = CountingCoreMLModel()
        let aux = CountingInferenceEngine()
        var (coreMLAfterTurn1, auxAfterTurn1) = (0, 0)
        await CoreMLEvaluator.$scopedModel.withValue(.init(coreML)) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": aux]) {
                await engine.processInput("hello", source: "UI", conversationId: id)
                (coreMLAfterTurn1, auxAfterTurn1) = (coreML.count, aux.count)
                await engine.processInput("hello again", source: "UI", conversationId: id)
            }
        }

        #expect(client.requests.count == 2)
        #expect(systemText(client.requests[0]).contains(unique))

        if !HeadlessMode.isEnabled {
            // Deltas, not fixed totals: every turn also guards USER.md (`guardedUserProfileText`),
            // which shares these same scoped mocks, so turn 1 alone legitimately spends one call on
            // USER.md and one on AGENTS.md (both now against this engine's own isolated `manager` —
            // see `tempMemory()` — so no other test's content can land here, unlike before fix
            // round 1). What this test actually pins is that turn 2 adds NONE.
            #expect(coreMLAfterTurn1 >= 1)
            #expect(coreML.count == coreMLAfterTurn1, "tier 2 must not re-run against an unchanged turn")
            #expect(aux.count == auxAfterTurn1, "tier 3 must not re-run against an unchanged turn")
        }
    }

    @Test("after update_user_profile, the next turn's system prompt contains the new profile text")
    func profileRefreshesAfterUpdate() async throws {
        let (manager, paths) = tempMemory()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        manager.updateUserProfile(content: "old profile")
        let originalModified = modDate(paths.userMd)

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        let newProfile = "Now prefers \(UUID().uuidString)."
        let client = TurnContextClient([
            toolCall("update_user_profile", ["content": .string(newProfile)]),
            reply("saved"),
            reply("second turn"),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0, memory: manager)

        await engine.processInput("remember this", source: "UI", conversationId: id)
        // Review minor: restore the file's ORIGINAL mtime right after the write. Without this, the
        // write naturally moves the mtime, and the next turn would refresh even if
        // `invalidateUserProfile()` were never called from the `update_user_profile` handler — the
        // test would then pass for the wrong reason. With the mtime restored, the ONLY thing that
        // can make turn 2 see the new text is that explicit invalidate call.
        if let originalModified {
            try restoreModDate(paths.userMd, to: originalModified)
        }
        await engine.processInput("anything else", source: "UI", conversationId: id)

        let requests = client.requests
        try #require(requests.count == 3)
        #expect(!systemText(requests[0]).contains(newProfile), "round 1 built the prompt before the tool ran")
        #expect(!systemText(requests[1]).contains(newProfile), "a turn's system prompt is fixed for all its rounds")
        #expect(systemText(requests[2]).contains(newProfile), "the next turn must see the update even though its mtime was restored")
    }

    @Test("touching AGENTS.md's modification date, including through a symlink's target, causes a re-read; an older mtime still refreshes")
    func agentsMdRefreshesOnChange() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentsPath = dir.appendingPathComponent("AGENTS.md")

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else {
            Issue.record("conversation not found")
            return
        }
        app.conversations[idx].workspacePath = dir.path
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)

        try "first content".write(to: agentsPath, atomically: true, encoding: .utf8)
        await engine.processInput("one", source: "UI", conversationId: id)

        // A restore with an OLDER mtime (`cp -p`, `rsync -t`) must still refresh: the cache
        // compares with `!=`, never "newer than".
        try "second content".write(to: agentsPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                               ofItemAtPath: agentsPath.path)
        await engine.processInput("two", source: "UI", conversationId: id)

        // AGENTS.md becomes a symlink to CLAUDE.md; editing the TARGET must refresh too —
        // `attributesOfItem(atPath:)` (lstat) would miss this, `resolvingSymlinksInPath` must not.
        let targetPath = dir.appendingPathComponent("CLAUDE.md")
        try "claude v1".write(to: targetPath, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: agentsPath)
        try FileManager.default.createSymbolicLink(at: agentsPath, withDestinationURL: targetPath)
        await engine.processInput("three", source: "UI", conversationId: id)

        try "claude v2".write(to: targetPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)],
                                               ofItemAtPath: targetPath.path)
        await engine.processInput("four", source: "UI", conversationId: id)

        let requests = client.requests
        try #require(requests.count == 4)
        #expect(systemText(requests[0]).contains("first content"))
        #expect(systemText(requests[1]).contains("second content"))
        #expect(!systemText(requests[1]).contains("first content"))
        #expect(systemText(requests[2]).contains("claude v1"))
        #expect(systemText(requests[3]).contains("claude v2"))
        #expect(!systemText(requests[3]).contains("claude v1"))
    }

    @Test("two turns with nothing changed send byte-identical systemInstruction")
    func systemInstructionByteIdenticalAcrossUnchangedTurns() async throws {
        let (manager, paths) = tempMemory()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        manager.updateUserProfile(content: "stable profile \(UUID().uuidString)")

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0, memory: manager)

        await engine.processInput("turn one", source: "UI", conversationId: id)
        await engine.processInput("turn two", source: "UI", conversationId: id)

        let requests = client.requests
        try #require(requests.count == 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let a = try encoder.encode(requests[0].systemInstruction)
        let b = try encoder.encode(requests[1].systemInstruction)
        #expect(a == b)
    }

    /// Fix round 1, item 1: a transient guard error must be shown for the turn it happens on but
    /// never pinned as a permanent block. Turn 1's tier-3 call throws
    /// (`FlakyThenHealthyInferenceEngine`'s first call); turn 2's answers normally — it must see the
    /// real profile, not a cached error.
    @Test("a transient guard error is shown for one turn but never cached as a permanent block")
    func errorOutcomeIsNeverCachedAsAPermanentBlock() async throws {
        let (manager, paths) = tempMemory()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let unique = "Error-cache probe \(UUID().uuidString)"
        manager.updateUserProfile(content: unique)

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: true, sessionPeerCount: 0, memory: manager)

        await AuxiliaryModelManager.$scopedEngines.withValue(["canary": FlakyThenHealthyInferenceEngine()]) {
            await engine.processInput("one", source: "UI", conversationId: id)
            await engine.processInput("two", source: "UI", conversationId: id)
        }

        let requests = client.requests
        try #require(requests.count == 2)
        #expect(systemText(requests[0]).contains("[CONTENT BLOCKED BY TIER 3 CANARY GUARD]"),
                "turn 1: the transient error is shown as blocked for that turn")
        #expect(!systemText(requests[0]).contains(unique))
        #expect(systemText(requests[1]).contains(unique),
                "turn 2: the engine is healthy again and the error was never cached as a permanent block")
        #expect(!systemText(requests[1]).contains("[CONTENT BLOCKED"))
    }

    /// The AGENTS.md twin of the test above (5a final review item 6): the workspace file goes
    /// through the same guarded-text cache, so a transient guard error on it must not stick either.
    @Test("a transient guard error on AGENTS.md is shown for one turn but never cached as a permanent block")
    func agentsErrorOutcomeIsNeverCachedAsAPermanentBlock() async throws {
        let (manager, paths) = tempMemory()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-agents-error-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unique = "AGENTS error-cache probe \(UUID().uuidString)"
        try unique.write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        let idx = try #require(app.conversations.firstIndex(where: { $0.id == id }))
        app.conversations[idx].workspacePath = dir.path
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: true, sessionPeerCount: 0, memory: manager)

        let canary = FlakyOnceForMarkerInferenceEngine(marker: unique)
        await AuxiliaryModelManager.$scopedEngines.withValue(["canary": canary]) {
            await engine.processInput("one", source: "UI", conversationId: id)
            await engine.processInput("two", source: "UI", conversationId: id)
        }

        let requests = client.requests
        try #require(requests.count == 2)
        #expect(systemText(requests[0]).contains("[CONTENT BLOCKED BY TIER 3 CANARY GUARD]"),
                "turn 1: the transient error is shown as blocked for that turn")
        #expect(!systemText(requests[0]).contains(unique))
        #expect(systemText(requests[1]).contains(unique),
                "turn 2: the engine is healthy again and the error was never cached as a permanent block")
        #expect(!systemText(requests[1]).contains("[CONTENT BLOCKED"))
    }

    /// Fix round 1, item 4: the signal that distinguishes old from new for USER.md, independent of
    /// `HeadlessMode` (which the counting-mock tests above have to guard against — see their
    /// comments). `assembly.userProfile`'s span is recorded only when `guardedUserProfileText()`
    /// actually performs a guard pass; a cache hit returns before `measureSpan` is ever entered, so
    /// the pre-Task-7 code (which always performs the pass) fails this on turn 2. Captured via
    /// `PerformanceProfiler`'s task-scoped `runSink` (its own invariant-7 seam, mirroring
    /// `CoreMLEvaluator.scopedModel`) rather than any guard-tier mock.
    @Test("USER.md is re-guarded on a real change and skipped on an unchanged turn, independent of HeadlessMode")
    func profileSpanTracksRealChangesOnly() async throws {
        let (manager, paths) = tempMemory()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        manager.updateUserProfile(content: "v1 \(UUID().uuidString)")

        let facts = try FactStoreManager(inMemory: true)
        let app = AppState()
        let id = newConversation(app)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0, memory: manager)

        final class ProfileCollector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var profiles: [CommandProfile] = []
            func append(_ p: CommandProfile) { lock.withLock { profiles.append(p) } }
        }
        let collector = ProfileCollector()

        await PerformanceProfiler.$runSink.withValue({ profile in collector.append(profile) }) {
            await engine.processInput("one", source: "UI", conversationId: id)
            await engine.processInput("two", source: "UI", conversationId: id)
            manager.updateUserProfile(content: "v2 \(UUID().uuidString)")
            await engine.processInput("three", source: "UI", conversationId: id)
        }

        try #require(collector.profiles.count == 3)
        #expect(collector.profiles[0].spans["assembly.userProfile"] != nil, "turn 1: a fresh engine must guard")
        #expect(collector.profiles[1].spans["assembly.userProfile"] == nil, "turn 2: unchanged file must hit the cache")
        #expect(collector.profiles[2].spans["assembly.userProfile"] != nil, "turn 3: changed file must re-guard")
    }
}
