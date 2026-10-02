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
        for _ in 0..<200 {
            if state.archiveRefusal(for: id) == .turnInFlight { sawInFlight = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
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
            for _ in 0..<1000 where state.hasTurnInFlight(for: id) {
                try await Task.sleep(nanoseconds: 10_000_000)
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
}
