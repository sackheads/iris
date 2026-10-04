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

/// Counts detached writes that have finished their completion hop, and lets a test await them
/// (#325). Tests wait on this instead of polling: the main actor is shared by every `@MainActor`
/// suite in the run and was measured unavailable for up to 2.9 s at a time under parallel
/// `swift test` runs, which turned a 3 s wall-clock poll into a coin toss. Create it before the
/// change that triggers the write.
@MainActor
final class WriteSettlements {
    private(set) var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ app: AppState) {
        app.onWriteSettled = { [weak self] in
            self?.count += 1
            self?.release()
        }
    }

    private func release() {
        let woken = waiters
        waiters = []
        for w in woken { w.resume() }
    }

    /// Returns once `n` writes have settled, or the task is cancelled (the suites' time limit).
    func wait(for n: Int) async {
        while count < n && !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: {
                Task { @MainActor in self.release() }
            }
        }
    }

    /// Returns once no write is in flight, waiting out each one that is.
    func waitUntilIdle(_ app: AppState) async {
        while app.isWriteInFlight && !Task.isCancelled { await wait(for: count + 1) }
    }
}

/// Every mutation records what changed instead of re-encoding the whole array (spec §3).
/// The time limit backstops `WriteSettlements`, which waits without a deadline.
@MainActor
@Suite("Conversation change tracking (#163)", .timeLimit(.minutes(1)))
struct ChangeTrackingTests {
    private func app() -> (AppState, UUID) {
        let a = AppState(store: try! .inMemory())
        let id = UUID()
        a.createNewConversation(id: id)
        return (a, id)
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
        let writes = WriteSettlements(a)
        a.appendMessage(role: .user, content: "only x", to: x)
        await writes.wait(for: 1)
        #expect(!a.isWriteInFlight)
        #expect(a.pendingChangeSet(for: x) == nil && a.pendingChangeSet(for: y) == nil)
        #expect(try a.store.counts(for: x).messages == 1)
        #expect(try a.store.counts(for: y).messages == 0)
    }

    /// The store assigns `position` as `MAX(position) + 1` at first insert, so the order a batch
    /// is applied in is the order the sidebar comes back in. Taken straight out of the pending
    /// dictionary that order was whatever hashing gave us, which shuffled conversations created
    /// inside one debounce window. Repeated, because a single run passes by luck about a sixth of
    /// the time.
    @Test("conversations created in one window are written in creation order, every time")
    func batchOrderFollowsConversationOrder() throws {
        for _ in 0..<5 {
            let a = AppState(store: try .inMemory())
            let x = UUID(), y = UUID(), z = UUID()
            a.createNewConversation(id: x); a.createNewConversation(id: y); a.createNewConversation(id: z)
            a.renameConversation(id: x, newTitle: "first")
            a.renameConversation(id: y, newTitle: "second")
            a.renameConversation(id: z, newTitle: "third")
            a.flushSave()
            // An empty store gets a default conversation from `init`, so it leads the list.
            #expect(try a.store.loadAll().conversations.map(\.title) == ["New Conversation", "first", "second", "third"])
            #expect(try a.store.loadAll().conversations.map(\.id) == a.conversations.map(\.id))
        }
    }

    /// `flushSave` signals the in-flight write's stand-down flag and then writes the current state
    /// itself. A detached write that went ahead anyway would re-apply its stale snapshot, whose
    /// trailing-row `DELETE ... ordinal >= count` drops exactly the rows the quit-time write just
    /// added. The debounced write is let go first and `flushSave` lands on top of it while it may
    /// still be running; whichever way the race falls, the store must end up holding exactly one
    /// copy of what is in memory.
    @Test("a debounced write overtaken by flushSave leaves exactly one copy of every row, matching memory")
    func flushSaveBeatsAnInFlightWrite() async throws {
        let a = AppState(store: try .inMemory())
        let id = UUID()
        a.createNewConversation(id: id)
        a.flushSave()
        let writes = WriteSettlements(a)

        // A batch big enough that the detached write is plausibly still inside its transaction
        // when flushSave lands.
        for i in 0..<400 {
            a.appendMessage(role: .agent, content: "m\(i)", to: id)
            a.appendContentToHistory(for: id, content: Content(role: "model", parts: [Part(text: "h\(i)")]))
        }
        // Let the debounce fire and the detached write start...
        try await Task.sleep(nanoseconds: UInt64((AppState.saveDebounce + 0.02) * 1_000_000_000))
        // ...then quit on top of it, with more state than the in-flight snapshot carries.
        a.appendMessage(role: .agent, content: "last", to: id)
        a.flushSave()

        let live = try #require(a.conversations.first { $0.id == id })
        #expect(try a.store.counts(for: id) == (live.messages.count, live.history.count))
        let reloaded = try #require(try a.store.loadAll().conversations.first { $0.id == id })
        #expect(reloaded.messages.map(\.content) == live.messages.map(\.content))
        #expect(reloaded.history.map { $0.parts.first?.text } == live.history.map { $0.parts.first?.text })

        // Let a detached write still running finish, then check it changed nothing. If the
        // debounce had not fired yet, flushSave cancelled it and there is nothing to wait for.
        await writes.waitUntilIdle(a)
        #expect(try a.store.counts(for: id) == (live.messages.count, live.history.count))
        #expect(try a.store.loadAll().conversations.first { $0.id == id }?.messages.last?.content == "last")
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
        let writes = WriteSettlements(a)
        a.appendMessage(role: .user, content: "x1", to: x)
        a.appendMessage(role: .user, content: "y1", to: y)
        // One batch carries both; x clears at take-time and stays clear, y is re-queued.
        await writes.wait(for: 1)

        #expect(attempts.count == 2)
        #expect(a.pendingChangeSet(for: x) == nil)
        #expect(a.pendingChangeSet(for: y)?.messagesFrom != nil)
        #expect(try store.counts(for: x).messages == 1)
        #expect(try store.counts(for: y).messages == 0)

        // No self-retry: the completion hop that re-queued y started no write of its own. The
        // quiet window below catches a later retry; it can only miss one, never invent one.
        #expect(!a.isWriteInFlight, "a failed write retried itself from its own completion")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(attempts.count == 2, "a failed write retried itself in a loop")
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
        let writes = WriteSettlements(a)
        a.appendMessage(role: .user, content: "x1", to: x)
        a.appendMessage(role: .user, content: "y1", to: y)
        await writes.wait(for: 1)

        #expect(attempts.count == 2)
        #expect(!a.isWriteInFlight, "the failed batch retried itself from its own completion")
        // Quiet window: can only miss a retry, never invent one.
        try await Task.sleep(nanoseconds: 500_000_000)
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
