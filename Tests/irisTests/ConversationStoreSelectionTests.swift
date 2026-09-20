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

    @Test("skipped rows are surfaced as a system line, written once")
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

        // The corrupted row was quarantined by the first `loadAll`, so a second AppState against
        // the same store finds nothing left to skip: the one persisted notice is all there is.
        let b = AppState(store: store)
        #expect(b.loadedSkippedRows.isEmpty)
        let notices = b.conversations.first?.messages.filter { $0.role == .system && $0.content.contains("quarantine table") } ?? []
        #expect(notices.count == 1)
    }

    /// An unreadable conversation row is left exactly where it is, so — unlike a quarantined
    /// payload row — it is reported again on every launch. The notice is persisted like any other
    /// system message (everything in `messages` must have a row) and de-duplicated by its text, so
    /// it does not stack up.
    @Test("a recurring unreadable-conversation notice is written once, not once per launch")
    func metadataNoticeIsDeduplicated() throws {
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
        #expect(notices(a) == ["1 saved conversation could not be read and was left in place; see the console for details."])
        a.flushSave()

        // Launch 2 hits the same condition and finds its own wording already there.
        let b = AppState(store: store)
        #expect(b.loadedSkippedRows.count == 1)
        #expect(notices(b).count == 1)
        b.flushSave()

        let loaded = try store.loadAll()
        // Filtered to this notice's own wording, not all system messages: a real `AppState` also
        // emits other launch notices independent of this scenario (e.g. the #202 tier-3-unprovisioned
        // one, since this test environment has protection on by default and no model downloaded).
        #expect(loaded.conversations.flatMap { $0.messages }.filter { $0.role == .system && $0.content.contains("could not be read and") }.count == 1)
        for conv in loaded.conversations {
            #expect(try store.counts(for: conv.id).messages == conv.messages.count)
        }
    }

    /// The bug this pins: a launch notice that lived in `messages` without a row on disk shifted
    /// every ordinal after it. On the next launch the notice was absent, the indices shifted back,
    /// and the first append `INSERT OR REPLACE`d the previous session's last message.
    @Test("messages appended after a launch notice survive a relaunch")
    func appendsAfterANoticeSurviveARelaunch() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "damaged")
        c.messages = [ChatMessage(role: .user, content: "kept"), ChatMessage(role: .agent, content: "also kept")]
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ? AND ordinal = 0", arguments: [c.id.uuidString])

        let a = AppState(store: store)
        #expect(a.conversations.first?.messages.contains { $0.content.contains("quarantine table") } == true)
        a.appendMessage(role: .user, content: "u1", to: c.id)
        a.flushSave()
        #expect(try store.counts(for: c.id).messages == a.conversations.first?.messages.count)

        let b = AppState(store: store)
        b.appendMessage(role: .user, content: "u2", to: c.id)
        b.flushSave()

        let live = try #require(b.conversations.first { $0.id == c.id })
        let reloaded = try #require(try store.loadAll().conversations.first { $0.id == c.id })
        #expect(reloaded.messages.map(\.content) == live.messages.map(\.content))
        #expect(try store.counts(for: c.id).messages == live.messages.count)
        let contents = reloaded.messages.map(\.content)
        let u1 = try #require(contents.firstIndex(of: "u1"))
        let u2 = try #require(contents.firstIndex(of: "u2"))
        #expect(u1 < u2)
        #expect(contents.filter { $0.contains("quarantine table") }.count == 1)
    }
}
