import Testing
import Foundation
@testable import iris

/// 5b: the pinned conversation became "Iris", the owner's main conversation, and is exempt from
/// rename and archive (spec §0.1–0.2).
@MainActor
@Suite struct PinnedConversationTests {
    private func app() throws -> (ConversationStore, AppState) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        return (store, state)
    }

    @Test func newPinnedConversationIsTitledIris() throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        #expect(state.conversations.first { $0.id == id }?.title == "Iris")
    }

    @Test func legacyTitleIsRetitledButOwnerRenameIsKept() throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        let idx = state.conversations.firstIndex { $0.id == id }!
        state.conversations[idx].title = "Iris Activity"
        state.retitleLegacyPinnedConversation()
        #expect(state.conversations[idx].title == "Iris")
        state.conversations[idx].title = "My HQ"
        state.retitleLegacyPinnedConversation()
        #expect(state.conversations[idx].title == "My HQ")
    }

    @Test func autoTitleSkipsPinned() throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        state.appendMessage(role: .user, content: "hello there, plan my week", to: id)
        #expect(state.conversations.first { $0.id == id }?.title == "Iris")
    }

    @Test func renameRefusedOnPinned() throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        #expect(state.renameConversation(id: id, newTitle: "Something") == .pinned)
        #expect(state.conversations.first { $0.id == id }?.title == "Iris")
    }

    /// Final-review fix wave (#187): `renameConversation` used to conflate "no such conversation"
    /// into the same `false` the pinned refusal returned.
    @Test func renameRefusesUnknownId() throws {
        let (_, state) = try app()
        #expect(state.renameConversation(id: UUID(), newTitle: "Something") == .noSuchConversation)
    }

    @Test func archiveRefusedOnPinned() throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        #expect(state.archiveRefusal(for: id) == .pinned)
        #expect(state.archiveConversation(id) == .pinned)
        #expect(state.conversations.first { $0.id == id }?.isArchived == false)
    }

    /// `archiveRefusal` checks `.pinned` last: a pinned conversation mid-turn must still report
    /// `.turnInFlight`, since a later task's `/new` rotation relies on that ordering to refuse a
    /// rotation attempted while a turn is running, rather than reporting "pinned" and inviting a
    /// retry that races the in-flight turn.
    @Test func turnInFlightOutranksPinnedInArchiveRefusal() async throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        state.autoApproveTools = true
        state.selectedConversationId = id
        // A scripted client that never replies lets the turn stay "in flight" for the duration of
        // the assertion below.
        final class NeverReplies: LLMClientProtocol, @unchecked Sendable {
            func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw APIError(message: "never reached")
            }
        }
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: NeverReplies(),
                                retryDelays: [], streamResponses: false, protectionEnabled: false,
                                sessionPeerCount: 0)
        state.installEngine(engine)
        state.sendMessage("hello")
        var sawInFlight = false
        // Flakiness follow-up (#340/5b): widened from a 10ms tick to a modest 25ms (80 iterations,
        // same ~2s ceiling as 200 * 10ms) — the positive case still stops on the first iteration
        // that sees it, and a tighter tick only costs MainActor pressure under the full suite.
        for _ in 0..<80 {
            if state.archiveRefusal(for: id) == .turnInFlight { sawInFlight = true; break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(sawInFlight, "expected .turnInFlight to outrank .pinned while a turn is running")
        // Final-review fix wave (#187): `NeverReplies` sleeps 10s before it would ever throw, and
        // nothing stopped the turn it started — the test returned while that sleep kept running in
        // the background for the rest of the 10s regardless. `interruptActiveConversation` cancels
        // the tracked task, which cancels the `Task.sleep` inside `NeverReplies` almost immediately.
        state.interruptActiveConversation()
    }

    /// Records every request the engine sends and answers each with fixed plain text — no tool
    /// calls, so the only thing to check is whether a rename-trigger turn was ever sent at all.
    private final class RecordingLLMClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [GeminiRequest] = []
        var requests: [GeminiRequest] { lock.withLock { recorded } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { recorded.append(request) }
            let part = Part(text: "ok", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
    }

    private func requestTexts(_ request: GeminiRequest) -> [String] {
        request.contents.flatMap { $0.parts.compactMap(\.text) }
    }

    /// Drives three real user turns (the path that fires the 3-message auto-rename trigger) into
    /// the given conversation through `sendMessage`/`startTurn`, waiting for each turn to finish
    /// before sending the next, and returns every request the engine issued along the way.
    private func driveThreeTurns(_ state: AppState, into id: UUID) async throws -> [GeminiRequest] {
        state.autoApproveTools = true
        state.selectedConversationId = id
        let client = RecordingLLMClient()
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, protectionEnabled: false,
                                sessionPeerCount: 0)
        state.installEngine(engine)
        for text in ["hi", "how are you", "what can you do"] {
            state.sendMessage(text)
            // `hasTurnInFlight` covers the whole `runThinkingTask` closure, including a same-turn
            // rename/reflection follow-up call — waiting for it to clear (rather than a fixed
            // sleep) is what makes the next `sendMessage` start turn N+1 instead of enqueuing a
            // pending message behind a turn the harness only guessed had finished.
            // Flakiness follow-up (#340/5b): widened from a 10ms tick to a modest 25ms (400
            // iterations, same ~10s ceiling as 1000 * 10ms) to ease MainActor pressure under the
            // full suite; the expected case still exits as soon as the turn clears.
            for _ in 0..<400 where state.hasTurnInFlight(for: id) {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        return client.requests
    }

    /// The pinned conversation never gets the rename-trigger turn, across three real user turns
    /// driven the same way a person typing would. Negative-only assertions can pass vacuously, so
    /// `renameTriggerFiresInNonPinnedControl` below drives the identical three turns into an
    /// ordinary conversation and asserts the trigger DOES fire there — proof this test can fail.
    @Test func renameTriggerNeverFiresInPinned() async throws {
        let (_, state) = try app()
        let id = state.activityConversationId()
        let requests = try await driveThreeTurns(state, into: id)
        #expect(requests.count >= 3, "expected at least the three driven turns to have reached the engine")
        for request in requests {
            let texts = requestTexts(request)
            #expect(!texts.contains { $0.contains(IrisEngine.renameTriggerPrefix) },
                    "a pinned conversation must never be sent the rename trigger")
        }
    }

    /// Positive control for the test above: the same three turns into a non-pinned conversation DO
    /// produce a rename-trigger request. If this ever stopped passing, the negative test above
    /// would be vacuous.
    @Test func renameTriggerFiresInNonPinnedControl() async throws {
        let (_, state) = try app()
        let id = UUID()
        state.createNewConversation(id: id)
        let requests = try await driveThreeTurns(state, into: id)
        let fired = requests.contains { request in
            requestTexts(request).contains { $0.contains(IrisEngine.renameTriggerPrefix) }
        }
        #expect(fired, "expected the rename trigger to fire on the third turn of a non-pinned conversation")
    }

    // MARK: - Crash window (5b §0.4)

    /// A crash between pinning the new Iris and unpinning the old one leaves two pins; the meta
    /// key decides which is Iris on the next load.
    @Test func reloadUnpinsAllButTheMetaKeysConversation() throws {
        let store = try ConversationStore.inMemory()
        let a = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let keep = UUID(), stray = UUID()
        a.createNewConversation(id: keep)
        a.createNewConversation(id: stray)
        for id in [keep, stray] {
            let i = a.conversations.firstIndex { $0.id == id }!
            a.conversations[i].isPinned = true
            a.markChanged(id, .metadata)
        }
        try store.setMetaValue(keep.uuidString, forKey: AppState.activityConversationMetaKey)
        a.flushSave()

        let b = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        #expect(b.conversations.filter(\.isPinned).map(\.id) == [keep])
        b.flushSave()
        let c = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        #expect(c.conversations.filter(\.isPinned).map(\.id) == [keep], "the unpin was persisted")
    }

    // MARK: - Load repair, both directions

    private func reload(_ store: ConversationStore) -> AppState {
        AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    private func set(_ state: AppState, _ id: UUID, pinned: Bool? = nil, archived: Bool? = nil) {
        let i = state.conversations.firstIndex { $0.id == id }!
        if let pinned { state.conversations[i].isPinned = pinned }
        if let archived { state.conversations[i].isArchived = archived }
        state.markChanged(id, .metadata)
    }

    private func meta(_ store: ConversationStore) throws -> UUID? {
        try store.metaValue(forKey: AppState.activityConversationMetaKey).flatMap(UUID.init(uuidString:))
    }

    /// A crash between the meta write and the flush: the key names a row that was never
    /// persisted, and the old Iris is still flagged pinned. It stays Iris rather than being
    /// unpinned in favour of a brand-new conversation.
    @Test func reloadWithMissingMetaRowPointsTheKeyBackAtThePinned() throws {
        let store = try ConversationStore.inMemory()
        let a = reload(store)
        let oldIris = UUID()
        a.createNewConversation(id: oldIris)
        set(a, oldIris, pinned: true)
        try store.setMetaValue(UUID().uuidString, forKey: AppState.activityConversationMetaKey)
        a.flushSave()

        let b = reload(store)
        #expect(try meta(store) == oldIris)
        #expect(b.conversations.filter(\.isPinned).map(\.id) == [oldIris])
        #expect(b.activityConversationId() == oldIris, "no fresh Iris is created")
        b.flushSave()
        #expect(reload(store).conversations.filter(\.isPinned).map(\.id) == [oldIris], "persisted")
    }

    /// Finding 1's repro: the target's pin flag was lost. Reload pins it again, so `/archive`
    /// is refused on it.
    @Test func reloadPinsAnUnpinnedMetaTarget() throws {
        let store = try ConversationStore.inMemory()
        let a = reload(store)
        let iris = a.activityConversationId()
        set(a, iris, pinned: false)
        a.flushSave()

        let b = reload(store)
        #expect(b.conversations.first { $0.id == iris }?.isPinned == true)
        #expect(b.archiveConversation(iris) == .pinned)
        b.flushSave()
        #expect(reload(store).conversations.first { $0.id == iris }?.isPinned == true, "persisted")
    }

    /// The target lost its pin and was then archived. Reload restores it, and the next card
    /// lands in it rather than in the archive or in a second Iris.
    @Test func reloadUnarchivesAndPinsAnArchivedMetaTarget() async throws {
        let store = try ConversationStore.inMemory()
        let a = reload(store)
        let iris = a.activityConversationId()
        set(a, iris, pinned: false, archived: true)
        a.flushSave()

        let b = reload(store)
        let back = try #require(b.conversations.first { $0.id == iris })
        #expect(back.isPinned && !back.isArchived)
        #expect(try meta(store) == iris)
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "sweep", status: .completed,
                             startedAt: Date(), finishedAt: Date())
        await b.deliverEvent(card, to: b.activityConversationId())
        let cards = b.conversations.first { $0.id == iris }?.messages.filter { $0.role == .event }
        #expect(cards?.count == 1)
        #expect(b.conversations.filter(\.isPinned).count == 1)
    }

    /// No key at all (a store from before it existed) and two pins: one survives, the newest,
    /// and the key is recorded for it.
    @Test func reloadWithNoMetaAndTwoPinsKeepsExactlyOne() throws {
        let store = try ConversationStore.inMemory()
        let a = reload(store)
        let older = UUID(), newer = UUID()
        a.createNewConversation(id: older)
        a.createNewConversation(id: newer)
        set(a, older, pinned: true)
        set(a, newer, pinned: true)
        // Explicit, so the tie-break never rests on two `Date()` calls differing.
        a.conversations[a.conversations.firstIndex { $0.id == older }!].updatedAt = Date(timeIntervalSince1970: 1_000)
        a.conversations[a.conversations.firstIndex { $0.id == newer }!].updatedAt = Date(timeIntervalSince1970: 2_000)
        #expect(try meta(store) == nil)
        a.flushSave()

        let b = reload(store)
        let pinned = b.conversations.filter(\.isPinned).map(\.id)
        #expect(pinned.count == 1)
        #expect(pinned == [newer])
        #expect(try meta(store) == newer)
    }

    /// At runtime too: an archived target is never handed out as Iris.
    @Test func activityConversationIdNeverReturnsAnArchivedTarget() throws {
        let (store, state) = try app()
        let iris = state.activityConversationId()
        let i = state.conversations.firstIndex { $0.id == iris }!
        state.conversations[i].isArchived = true
        let fresh = state.activityConversationId()
        #expect(fresh != iris)
        #expect(try meta(store) == fresh)
        #expect(state.conversations.filter(\.isPinned).map(\.id) == [fresh], "the flags follow the key")
        #expect(state.activityConversationId() == fresh, "stable once recovered")
    }

    // MARK: - PinRepair.decide

    private func row(_ id: UUID, pinned: Bool = false, archived: Bool = false, at t: TimeInterval = 0) -> PinRepair.Row {
        PinRepair.Row(id: id, isPinned: pinned, isArchived: archived, updatedAt: Date(timeIntervalSince1970: t))
    }

    @Test func decideAgreeingStateChangesNothing() {
        let iris = UUID()
        #expect(PinRepair.decide(metaValue: iris.uuidString, rows: [row(iris, pinned: true), row(UUID())]).isEmpty)
        #expect(PinRepair.decide(metaValue: nil, rows: [row(UUID())]).isEmpty)
        #expect(PinRepair.decide(metaValue: UUID().uuidString, rows: [row(UUID())]).isEmpty,
                "missing target, nothing pinned: left to activityConversationId()")
    }

    @Test func decideLiveTargetWinsOverOtherPins() {
        let iris = UUID(), other = UUID()
        let r = PinRepair.decide(metaValue: iris.uuidString, rows: [row(iris), row(other, pinned: true, at: 99)])
        #expect(r == PinRepair(newMetaId: nil, pin: [iris], unpin: [other], unarchive: []))
    }

    @Test func decideArchivedTargetDefersToALivePin() {
        let iris = UUID(), pinned = UUID()
        let r = PinRepair.decide(metaValue: iris.uuidString, rows: [row(iris, archived: true), row(pinned, pinned: true)])
        #expect(r == PinRepair(newMetaId: pinned, pin: [], unpin: [], unarchive: []))
    }

    @Test func decideMissingTargetKeepsTheNewestOfSeveralPins() {
        let a = UUID(), b = UUID(), c = UUID()
        let r = PinRepair.decide(metaValue: UUID().uuidString,
                                 rows: [row(a, pinned: true, at: 1), row(b, pinned: true, archived: true, at: 3),
                                        row(c, pinned: true, at: 2)])
        #expect(r == PinRepair(newMetaId: b, pin: [], unpin: [a, c], unarchive: [b]))
    }
}
