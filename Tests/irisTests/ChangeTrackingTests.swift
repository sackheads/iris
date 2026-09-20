import Testing
import Foundation
@testable import iris

/// Counts `apply` attempts from the store's failure-injection hook, which is consulted once per
/// conversation per attempt — a spinning retry loop shows up here as an ever-growing count.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

/// Every mutation records what changed instead of re-encoding the whole array (spec §3).
@MainActor
@Suite("Conversation change tracking (#163)")
struct ChangeTrackingTests {
    private func app() -> (AppState, UUID) {
        let a = AppState(store: try! .inMemory())
        let id = UUID()
        a.createNewConversation(id: id)
        return (a, id)
    }

    /// Waits for a main-actor condition (the detached write's completion hop has run) without
    /// pinning a fixed sleep to the debounce.
    private func poll(_ timeout: TimeInterval = 3, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("create, append, update, history append/replace, metadata and delete map to their change kinds")
    func kinds() {
        let (a, id) = app()
        #expect(a.pendingChangeSet(for: id)?.created == true)
        a.appendMessage(role: .user, content: "one", to: id)
        #expect(a.pendingChangeSet(for: id)?.metadata == true)   // the first user message set the title
        a.appendMessage(role: .agent, content: "two", to: id)
        #expect(a.pendingChangeSet(for: id)?.messagesFrom == 0)
        let mid = a.conversations.first { $0.id == id }!.messages[1].id
        a.updateMessageContent(id: mid, content: "two!", in: id, persist: true)
        #expect(a.pendingChangeSet(for: id)?.updatedMessageIds == [mid])
        a.appendContentToHistory(for: id, content: Content(role: "user", parts: [Part(text: "h")]))
        #expect(a.pendingChangeSet(for: id)?.historyFrom == 0)
        a.updateHistory(for: id, history: [])
        #expect(a.pendingChangeSet(for: id)?.historyReplaced == true)
        a.renameConversation(id: id, newTitle: "new")
        #expect(a.pendingChangeSet(for: id)?.metadata == true)
        a.deleteConversation(id)
        #expect(a.pendingChangeSet(for: id)?.deleted == true)
    }

    @Test("updateMessageContent without persist records nothing")
    func streamingUpdatesAreNotRecorded() {
        let (a, id) = app()
        a.appendMessage(role: .agent, content: "x", to: id)
        a.flushSave()
        let mid = a.conversations.first { $0.id == id }!.messages[0].id
        a.updateMessageContent(id: mid, content: "xy", in: id)
        #expect(a.pendingChangeSet(for: id) == nil)
    }

    @Test("sub-process conversations are never written")
    func subagentsNotPersisted() throws {
        let a = AppState(store: try .inMemory())
        let id = UUID()
        a.createNewConversation(id: id, isSubagent: true)
        a.appendMessage(role: .agent, content: "scratch", to: id)
        a.flushSave()
        #expect(try a.store.loadAll().conversations.contains { $0.id == id } == false)
    }

    @Test("a flush writes only the dirty conversation, and the pending set is empty afterwards")
    func flushWritesDirtyOnly() async throws {
        let a = AppState(store: try .inMemory())
        let x = UUID(), y = UUID()
        a.createNewConversation(id: x); a.createNewConversation(id: y)
        a.flushSave()
        a.appendMessage(role: .user, content: "only x", to: x)
        try await Task.sleep(nanoseconds: UInt64((AppState.saveDebounce + 0.6) * 1_000_000_000))
        #expect(a.pendingChangeSet(for: x) == nil && a.pendingChangeSet(for: y) == nil)
        #expect(try a.store.counts(for: x).messages == 1)
        #expect(try a.store.counts(for: y).messages == 0)
    }

    @Test("a conversation deleted and re-created in the same window is written, not deleted")
    func deleteThenRecreateInOneWindow() throws {
        let a = AppState(store: try .inMemory())
        let id = UUID()
        a.createNewConversation(id: id)
        a.flushSave()
        a.deleteConversation(id)
        a.createNewConversation(id: id)
        a.appendMessage(role: .user, content: "back", to: id)
        #expect(a.pendingChangeSet(for: id)?.deleted == true)
        a.flushSave()
        #expect(try a.store.loadAll().conversations.contains { $0.id == id })
        #expect(try a.store.counts(for: id).messages == 1)
    }

    @Test("a partial failure re-queues only the failed conversation, and does not retry on its own")
    func partialFailureRequeuesOnlyFailedIds() async throws {
        let store = try ConversationStore.inMemory()
        let attempts = AttemptCounter()
        let a = AppState(store: store)
        let x = UUID(), y = UUID()
        a.createNewConversation(id: x); a.createNewConversation(id: y)
        a.flushSave()

        store.failInjection = { id in attempts.bump(); return id == y }
        a.appendMessage(role: .user, content: "x1", to: x)
        a.appendMessage(role: .user, content: "y1", to: y)
        // x clears at take-time and stays clear; y comes back only once the failure is handled.
        try await poll { a.pendingChangeSet(for: x) == nil && a.pendingChangeSet(for: y) != nil }

        #expect(a.pendingChangeSet(for: x) == nil)
        #expect(a.pendingChangeSet(for: y)?.messagesFrom != nil)
        #expect(try store.counts(for: x).messages == 1)
        #expect(try store.counts(for: y).messages == 0)

        // No self-retry: the failed set waits for the next change or flush, and the write is not
        // attempted again in the meantime.
        let after = attempts.count
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(attempts.count == after, "a failed write retried itself in a loop")
        #expect(a.pendingChangeSet(for: y)?.messagesFrom != nil)

        store.failInjection = nil
        a.flushSave()
        #expect(try store.counts(for: y).messages == 1)
        #expect(a.pendingChangeSet(for: y) == nil)
    }

    /// `apply` reports every failure as `partialFailure`, so "every id failed" is the strongest
    /// whole-batch failure reachable without a real disk error; it exercises the same re-queue
    /// path the non-partial `else` branch takes.
    @Test("a batch in which every conversation fails is re-queued whole and does not spin")
    func wholeBatchFailureRequeuesEverything() async throws {
        let store = try ConversationStore.inMemory()
        let attempts = AttemptCounter()
        let a = AppState(store: store)
        let x = UUID(), y = UUID()
        a.createNewConversation(id: x); a.createNewConversation(id: y)
        a.flushSave()

        store.failInjection = { _ in attempts.bump(); return true }
        a.appendMessage(role: .user, content: "x1", to: x)
        a.appendMessage(role: .user, content: "y1", to: y)
        try await poll { attempts.count >= 2 }
        try await Task.sleep(nanoseconds: 500_000_000)   // the completion hop, then quiet

        #expect(attempts.count == 2, "the failed batch retried itself in a loop")
        #expect(a.pendingChangeSet(for: x)?.messagesFrom != nil)
        #expect(a.pendingChangeSet(for: y)?.messagesFrom != nil)
        #expect(try store.counts(for: x).messages == 0)
        #expect(try store.counts(for: y).messages == 0)

        store.failInjection = nil
        a.flushSave()
        #expect(try store.counts(for: x).messages == 1)
        #expect(try store.counts(for: y).messages == 1)
    }
}
