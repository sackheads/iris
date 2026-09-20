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
        // Assert the rule itself, not only its absence of side effects: "no file appeared" is also
        // true of an on-disk store that happened to fail to open.
        #expect(a.store.isOnDisk == false)
        #expect(a.store.path == nil)
        #expect(FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path) == before)
    }

    @Test("the isolation rule: a store goes on disk only in a plain app process")
    func isolationTruthTable() {
        #expect(ConversationStore.shouldIsolate(xctestLinked: false, headless: false, volatileDefaults: false) == false)
        #expect(ConversationStore.shouldIsolate(xctestLinked: true, headless: false, volatileDefaults: false))
        #expect(ConversationStore.shouldIsolate(xctestLinked: false, headless: true, volatileDefaults: false))
        // The fake-lane perf run: volatile defaults but the real IrisPaths.
        #expect(ConversationStore.shouldIsolate(xctestLinked: false, headless: false, volatileDefaults: true))
        #expect(ConversationStore.shouldIsolate(xctestLinked: true, headless: true, volatileDefaults: true))
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

    @Test("skipped rows are surfaced as a transient system line that is never persisted")
    func skippedRowsSurface() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "damaged")
        c.messages = [ChatMessage(role: .user, content: "ok"), ChatMessage(role: .agent, content: "also ok")]
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        try store.rawWrite("UPDATE messages SET payload = 'x' WHERE conversationId = ? AND ordinal = 0", arguments: [c.id.uuidString])

        let a = AppState(store: store)
        #expect(a.loadedSkippedRows.count == 1)
        #expect(a.conversations.first?.messages.contains { $0.role == .system && $0.content.contains("quarantine table") } == true)
        a.flushSave()

        // The corrupted row was quarantined by the first `loadAll` and the notice was never
        // persisted, so a second AppState against the same store shows no notice at all.
        let b = AppState(store: store)
        #expect(b.loadedSkippedRows.isEmpty)
        let notices = b.conversations.first?.messages.filter { $0.role == .system && $0.content.contains("quarantine table") } ?? []
        #expect(notices.isEmpty)
    }

    /// An unreadable conversation row is left exactly where it is, so — unlike a quarantined
    /// payload row — it recurs on every launch. The notice must therefore be shown every time and
    /// written never; persisting it accumulated one copy per launch in whatever conversation
    /// happened to be selected.
    @Test("an unreadable conversation row notifies on every launch and persists on none")
    func metadataNoticeIsTransientAndRepeats() throws {
        let store = try ConversationStore.inMemory()
        let c = Conversation(id: UUID(), title: "unreadable")
        var s = ChangeSet(); s.add(.created)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        try store.rawWrite("UPDATE conversations SET title = X'FFFE' WHERE id = ?", arguments: [c.id.uuidString])

        func notices(_ app: AppState) -> [String] {
            app.conversations.flatMap { $0.messages }
                .filter { $0.role == .system && $0.content.contains("could not be read and") }
                .map(\.content)
        }

        let a = AppState(store: store)
        #expect(a.loadedSkippedRows.count == 1)
        #expect(notices(a).count == 1)
        a.flushSave()

        let b = AppState(store: store)
        #expect(b.loadedSkippedRows.count == 1)
        #expect(notices(b).count == 1)
        b.flushSave()

        // Nothing the notices said was written: every conversation the store holds has no messages.
        for conv in try store.loadAll().conversations {
            #expect(try store.counts(for: conv.id).messages == 0)
        }
    }
}
