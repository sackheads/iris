import Testing
import Foundation
@testable import iris

@MainActor
@Suite("Conversation store selection and load (#163)")
struct ConversationStoreSelectionTests {
    @Test("the test process gets an in-memory store and never a file under the real paths")
    func testProcessIsIsolated() {
        let before = FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path)
        let a = AppState()
        a.createNewConversation(id: UUID())
        a.flushSave()
        #expect(FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path) == before)
    }

    @Test("a fresh AppState loads what its store holds, in order, and applies the load-time repairs")
    func loadsFromStore() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "kept")
        c.lastGoalCompletionReport = .string("transient")
        var s = ChangeSet(); s.add(.created)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        let a = AppState(store: store)
        #expect(a.conversations.map(\.title) == ["kept"])
        #expect(a.conversations.first?.lastGoalCompletionReport == nil)
        #expect(a.selectedConversationId == c.id)
    }

    @Test("the legacy blob in the defaults store is imported on first load and the key moved")
    func migratesBlob() throws {
        let store = try ConversationStore.inMemory()
        let legacy = [Conversation(id: UUID(), title: "from blob")]
        IrisDefaults.store.set(try JSONEncoder().encode(legacy), forKey: LegacyConversationBlob.key)
        defer { IrisDefaults.store.removeObject(forKey: LegacyConversationBlob.legacyKey) }
        let a = AppState(store: store)
        #expect(a.conversations.map(\.title) == ["from blob"])
        #expect(IrisDefaults.store.data(forKey: LegacyConversationBlob.key) == nil)
        #expect(IrisDefaults.store.data(forKey: LegacyConversationBlob.legacyKey) != nil)
    }

    @Test("skipped rows are reported and surfaced once as a system line")
    func skippedRowsSurface() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "damaged")
        c.messages = [ChatMessage(role: .user, content: "ok")]
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        try store.rawWrite("UPDATE messages SET payload = 'x' WHERE conversationId = ?", arguments: [c.id.uuidString])
        let a = AppState(store: store)
        #expect(a.loadedSkippedRows.count == 1)
        #expect(a.conversations.first?.messages.contains { $0.role == .system && $0.content.contains("could not be read") } == true)
    }
}
