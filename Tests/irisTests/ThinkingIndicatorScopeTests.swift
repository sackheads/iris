import Testing
import Foundation
@testable import IrisKit

/// #234: the "Iris is thinking" indicator (and the spectrum line, LED bar, and Escape's
/// interrupt guard) must reflect the SELECTED conversation's own turn, not whether ANY
/// conversation (main, subagent, evaluator) has one running. `AppState.isThinking` stays global
/// on purpose — a future menu-bar-style surface may legitimately want "is anything busy
/// anywhere" — but every per-conversation surface must go through `AppState.isThinking(in:)`.
///
/// Each test drives `beginThinking()`/`beginEngineTurn(for:)` (and their `end*` counterparts) in
/// the same pairing `IrisEngine.withEngineTurn` uses in production, on a fresh `AppState()` —
/// never `AppState.shared` (Invariant 7) — so a test that regressed `isThinking(in:)` back to
/// reading the global flag would see it return true for an idle, unselected conversation.
@MainActor
@Suite("Thinking indicator scope (#234)")
struct ThinkingIndicatorScopeTests {
    private func app() -> (AppState, UUID, UUID) {
        let state = AppState()
        let a = state.createNewConversation(select: false)
        let b = state.createNewConversation(select: false)
        return (state, a, b)
    }

    private func start(_ state: AppState, _ id: UUID) {
        state.beginThinking()
        state.beginEngineTurn(for: id)
    }

    private func end(_ state: AppState, _ id: UUID) {
        state.endEngineTurn(for: id)
        state.endThinking()
    }

    @Test("A busy, B selected: B's indicator is off, A's is on")
    func busyConversationDoesNotLightUpAnother() {
        let (state, a, b) = app()
        state.selectedConversationId = b
        start(state, a)
        defer { end(state, a) }

        #expect(state.isThinking(in: a) == true)
        #expect(state.isThinking(in: b) == false)
        // The global flag is true throughout — that is exactly the bug: a surface that still
        // read it instead of `isThinking(in:)` would wrongly light up B.
        #expect(state.isThinking == true)
    }

    @Test("both busy: both indicators are on")
    func bothBusyBothOn() {
        let (state, a, b) = app()
        start(state, a)
        start(state, b)
        defer {
            end(state, a)
            end(state, b)
        }

        #expect(state.isThinking(in: a) == true)
        #expect(state.isThinking(in: b) == true)
    }

    @Test("ending a turn clears its own indicator, leaving the other conversation's alone")
    func endingATurnClearsOnlyItsOwnIndicator() {
        let (state, a, b) = app()
        start(state, a)
        start(state, b)

        end(state, a)
        #expect(state.isThinking(in: a) == false)
        #expect(state.isThinking(in: b) == true)

        end(state, b)
        #expect(state.isThinking(in: b) == false)
    }

    @Test("nil conversation id is never thinking")
    func nilConversationIsNeverThinking() {
        let (state, a, _) = app()
        start(state, a)
        defer { end(state, a) }

        #expect(state.isThinking(in: nil) == false)
    }

    @Test("Escape's interrupt guard follows the selected conversation, not the global flag")
    func interruptFollowsSelectedConversation() {
        let (state, a, b) = app()
        state.selectedConversationId = b
        start(state, a)
        defer { end(state, a) }

        // Nothing is running on B, so interrupting must be a no-op even though A (and the
        // global flag) are busy — this is the Escape-on-an-idle-conversation half of #234.
        state.interruptActiveConversation()
        let bMessages = state.conversations.first { $0.id == b }!.messages
        #expect(bMessages.isEmpty)
    }
}
