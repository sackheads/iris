import Testing
import Foundation
@testable import iris

/// 5b spec §0, decision 4 (last paragraph): nothing rotates automatically, but once the pinned
/// conversation's history passes ~150k estimated tokens, Iris posts a one-line `/new` suggestion
/// — once per crossing, never while a rotation is already running, and never in a non-pinned
/// conversation. These tests build histories directly (no 150k tokens of real turns) and drive
/// at most one or two cheap turns per test through a scripted client.
@MainActor
@Suite struct RotationSuggestionTests {

    // MARK: - estimatedTokens

    @Test func estimatedTokensSumsUtf8BytesOfTextPartsDividedBy4() {
        let history = [
            Content(role: "user", parts: [Part(text: String(repeating: "a", count: 400))]),
            Content(role: "model", parts: [Part(text: String(repeating: "b", count: 400))]),
        ]
        // 800 ascii bytes / 4.
        #expect(RotationSuggestion.estimatedTokens(history) == 200)
    }

    /// The ruling: UTF-8 bytes, never `String.count`. "é" is one `Character` but two UTF-8
    /// bytes — if this used character count the result would be half of what it is here.
    @Test func estimatedTokensCountsBytesNotCharacters() {
        let text = String(repeating: "é", count: 100)
        #expect(text.count == 100)
        #expect(text.utf8.count == 200)
        let history = [Content(role: "user", parts: [Part(text: text)])]
        #expect(RotationSuggestion.estimatedTokens(history) == 50)
    }

    /// Only text parts count. A function call's arguments and inline image data are skipped, as
    /// documented on `estimatedTokens`.
    @Test func estimatedTokensSkipsNonTextParts() {
        let history = [
            Content(role: "model", parts: [Part(functionCall: FunctionCall(name: "run_command", args: ["command": .string(String(repeating: "x", count: 4000))]))]),
            Content(role: "user", parts: [Part(inlineData: InlineData(mimeType: "image/png", data: String(repeating: "A", count: 4000)))]),
        ]
        #expect(RotationSuggestion.estimatedTokens(history) == 0)
    }

    @Test func estimatedTokensOfEmptyHistoryIsZero() {
        #expect(RotationSuggestion.estimatedTokens([]) == 0)
    }

    // MARK: - firing in the pinned conversation

    /// Answers every request with fixed plain text and no tool calls — the only thing under test
    /// is whether/when the suggestion message appears, not the turn's content.
    private final class FixedReplyClient: LLMClientProtocol, @unchecked Sendable {
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let part = Part(text: "ok", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
    }

    private func harness() throws -> (state: AppState, id: UUID) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        let id = state.activityConversationId()
        state.selectedConversationId = id
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: FixedReplyClient(),
                                retryDelays: [], streamResponses: false, protectionEnabled: false,
                                sessionPeerCount: 0)
        state.installEngine(engine)
        return (state, id)
    }

    /// A single `Content` whose text alone estimates comfortably over the threshold, so the one
    /// cheap turn the test drives does not need to add much to cross it.
    private func oversizedHistory() -> [Content] {
        let bytes = (RotationSuggestion.threshold + 10_000) * 4
        return [Content(role: "user", parts: [Part(text: String(repeating: "x", count: bytes))])]
    }

    /// Waits for `startTurn`'s tracked task (including any same-turn reflect/rename follow-up)
    /// to finish, the same way `PinnedConversationTests.driveThreeTurns` does, rather than a
    /// fixed sleep.
    private func waitForTurn(_ state: AppState, _ id: UUID) async throws {
        for _ in 0..<400 where state.hasTurnInFlight(for: id) {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(!state.hasTurnInFlight(for: id), "turn did not finish within the bounded wait")
    }

    private func commandCount(_ state: AppState, _ id: UUID) -> Int {
        state.conversations.first { $0.id == id }?.messages
            .filter { $0.role == .command && $0.content == RotationSuggestion.text }.count ?? 0
    }

    @Test func suggestionFiresOnceWhenPinnedHistoryCrossesThreshold() async throws {
        let (state, id) = try harness()
        state.updateHistory(for: id, history: oversizedHistory())
        state.sendMessage("hi")
        try await waitForTurn(state, id)
        #expect(commandCount(state, id) == 1)
    }

    /// A second turn, still over the threshold, adds no second suggestion — "once per crossing".
    @Test func suggestionDoesNotRepeatOnASecondTurnStillOverThreshold() async throws {
        let (state, id) = try harness()
        state.updateHistory(for: id, history: oversizedHistory())
        state.sendMessage("hi")
        try await waitForTurn(state, id)
        #expect(commandCount(state, id) == 1)

        state.sendMessage("still here")
        try await waitForTurn(state, id)
        #expect(commandCount(state, id) == 1)
    }

    /// Under the threshold, no suggestion — proof the positive tests above are not vacuous (the
    /// turn itself does not unconditionally post the line).
    @Test func suggestionDoesNotFireUnderThreshold() async throws {
        let (state, id) = try harness()
        state.sendMessage("hi")
        try await waitForTurn(state, id)
        #expect(commandCount(state, id) == 0)
    }

    /// Non-pinned conversations never get the suggestion, even with the identical oversized
    /// history and the identical turn driven the identical way.
    @Test func suggestionNeverFiresInNonPinnedConversation() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        let id = state.createNewConversation(select: true)
        state.selectedConversationId = id
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: FixedReplyClient(),
                                retryDelays: [], streamResponses: false, protectionEnabled: false,
                                sessionPeerCount: 0)
        state.installEngine(engine)
        state.updateHistory(for: id, history: oversizedHistory())
        state.sendMessage("hi")
        try await waitForTurn(state, id)
        #expect(commandCount(state, id) == 0)
    }
}
