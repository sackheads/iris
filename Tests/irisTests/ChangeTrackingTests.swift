import Testing
import Foundation
@testable import iris

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

    @Test("create, append, update, history append/replace, metadata and delete map to their change kinds")
    func kinds() {
        let (a, id) = app()
        #expect(a.pendingChangeSet(for: id)?.created == true)
        a.appendMessage(role: .user, content: "one", to: id)
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
}
