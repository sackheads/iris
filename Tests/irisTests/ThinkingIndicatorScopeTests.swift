import Testing
import Foundation
import Observation
@testable import IrisKit

/// #234: the "Iris is thinking" indicator (and the spectrum line, LED bar, and Escape's
/// interrupt guard) must reflect the SELECTED conversation's own turn, not whether ANY
/// conversation (main, subagent, evaluator) has one running. No view reads the global
/// `AppState.isThinking` any more — every per-conversation surface goes through
/// `AppState.isThinking(in:)`; the global stays only as a turn-lifecycle probe other tests use
/// (`JobRetryTests`, `CheckpointJudgementResolutionTests`) — see its doc comment.
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

    /// Regression for the #438 review's observation-gap finding: `isThinking(in:)` reads
    /// `rotationHold`, `rotationTask` and `rotationConversationIds`, which used to be
    /// `@ObservationIgnored`. A view rendering `isThinking(in:)` would then never re-render when a
    /// rotation starts holding or ends, since the rotation runs under no conversation id and
    /// those three fields are its only signal here. `withObservationTracking` is the
    /// non-SwiftUI way to assert a stored property participates in Observation: register tracking
    /// over a read of `isThinking(in:)`, mutate one field, and require the callback to fire.
    @Test("rotationHold, rotationTask and rotationConversationIds are observed by isThinking(in:)")
    func rotationFieldsAreObservedByIsThinking() {
        let (state, a, _) = app()

        // `onChange` is `@Sendable`; a plain class mutated only from this (MainActor) test body
        // is safe but not provably so to the compiler, so this is `@unchecked` like the other
        // small test-only boxes in this suite (e.g. `RotationClient` in
        // `ConversationRotationTests`).
        final class Fired: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = false
            var value: Bool { lock.withLock { _value } }
            func set() { lock.withLock { _value = true } }
        }

        func tracked() -> Fired {
            let flag = Fired()
            withObservationTracking({ _ = state.isThinking(in: a) }, onChange: { flag.set() })
            return flag
        }

        let holdFlag = tracked()
        state.rotationHold = a
        #expect(holdFlag.value, "setting rotationHold must notify an observer reading isThinking(in:)")
        state.rotationHold = nil

        let idsFlag = tracked()
        state.rotationConversationIds = [a]
        #expect(idsFlag.value, "setting rotationConversationIds must notify an observer reading isThinking(in:)")
        state.rotationConversationIds = []

        let taskFlag = tracked()
        state.setRotationTaskForTesting(Task {})
        #expect(taskFlag.value, "setting rotationTask must notify an observer reading isThinking(in:)")
        state.setRotationTaskForTesting(nil)
    }

    @Test("a rotation transition (hold set, then released at the summary phase) changes isThinking(in:)")
    func rotationTransitionChangesIsThinking() {
        let (state, a, b) = app()
        state.selectedConversationId = b
        // A rotation is running throughout this test, same as production: `rotationTask` is
        // non-nil from the `/new` handler until `rotatePinned` returns on every exit path.
        state.setRotationTaskForTesting(Task {})
        defer { state.setRotationTaskForTesting(nil) }

        // The hold phase (reflection): the OLD conversation reads thinking even with no engine
        // turn counted against it directly.
        state.rotationHold = a
        #expect(state.isThinking(in: a) == true)
        #expect(state.isThinking(in: b) == false)

        // The hold releases before the summary call (`releaseRotationHold`, called right after
        // the reflection turn), but the rotation is still in flight over the (old, new) pair.
        state.rotationHold = nil
        state.rotationConversationIds = [a, b]
        #expect(state.isThinking(in: a) == true)
        #expect(state.isThinking(in: b) == true, "the new conversation stays lit through the summary phase")

        // The rotation ends: both go idle.
        state.rotationConversationIds = []
        #expect(state.isThinking(in: a) == false)
        #expect(state.isThinking(in: b) == false)
    }
}
