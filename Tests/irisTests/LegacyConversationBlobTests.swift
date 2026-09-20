import Testing
import Foundation
@testable import iris

@Suite("Legacy conversation blob import")
struct LegacyConversationBlobTests {
    /// Builds an isolated UserDefaults suite for one test. The caller must call `cleanup(name)`
    /// in a `defer` so no plist survives the test run — `removePersistentDomain` alone clears the
    /// in-memory domain but leaves the backing file on disk (#178).
    private func defaults() -> (UserDefaults, String) {
        let name = "iris-legacy-blob-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (d, name)
    }
    private func cleanup(_ d: UserDefaults, _ name: String) {
        d.removePersistentDomain(forName: name)
        IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
    }
    private func blob(_ conversations: [Conversation]) -> Data { try! JSONEncoder().encode(conversations) }
    private func conv(_ title: String, subagent: Bool = false) -> Conversation {
        var c = Conversation(id: UUID(), title: title)
        c.isSubagent = subagent
        c.messages = [ChatMessage(role: .user, content: "m-\(title)")]
        c.history = [Content(role: "user", parts: [Part(text: "h-\(title)")])]
        return c
    }

    @Test("no blob means nothing to do")
    func nothingToDo() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .nothingToDo)
    }

    @Test("the blob is imported in order, sub-process conversations dropped, and the key moved to the legacy name")
    func imports() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        let data = blob([conv("a"), conv("scratch", subagent: true), conv("b")])
        d.set(data, forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .imported(2))
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["a", "b"])
        #expect(loaded.conversations.first?.messages.first?.content == "m-a")
        #expect(loaded.conversations.first?.history.first?.parts.first?.text == "h-a")
        #expect(d.data(forKey: LegacyConversationBlob.key) == nil)
        #expect(d.data(forKey: LegacyConversationBlob.legacyKey) == data)
    }

    @Test("a second run finds no key; a stale key against an already-imported store is not imported but is still moved")
    func idempotent() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        d.set(blob([conv("a")]), forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .imported(1))
        #expect(try store.legacyImportMarked())
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .nothingToDo)
        d.set(blob([conv("stale")]), forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .alreadyImported)
        #expect(try store.loadAll().conversations.map(\.title) == ["a"])
        #expect(d.data(forKey: LegacyConversationBlob.key) == nil)
    }

    /// The bug this pins: the "already imported?" gate used to be `COUNT(*) FROM conversations > 0`.
    /// After a failed import the app creates its default conversation, so the next launch found a
    /// non-empty store, concluded the import had already happened, and moved the key anyway — the
    /// blob was parked unimported and the conversations were gone, silently.
    @Test("an import that failed at launch 1 is retried at launch 2, behind the conversation created in between")
    func retriesBehindAnAutoCreatedConversation() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        let data = blob([conv("a"), conv("b")])
        d.set(data, forKey: LegacyConversationBlob.key)

        // Launch 1: the write fails, the key is kept, nothing is marked.
        store.failInjection = { _ in true }
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .importFailed)
        #expect(d.data(forKey: LegacyConversationBlob.key) == data)
        #expect(try store.isEmpty())
        #expect(try store.legacyImportMarked() == false)

        // ...and the app carries on and writes its default conversation into the store.
        store.failInjection = nil
        let fresh = Conversation(id: UUID(), title: "New Conversation")
        var created = ChangeSet(); created.add(.created)
        try store.apply([ConversationWrite(id: fresh.id, snapshot: fresh, changes: created)])

        // Launch 2: the store is no longer empty, but the marker is what gates the import.
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .imported(2))
        #expect(try store.loadAll().conversations.map(\.title) == ["New Conversation", "a", "b"])
        #expect(try store.legacyImportMarked())
        #expect(d.data(forKey: LegacyConversationBlob.key) == nil)
        #expect(d.data(forKey: LegacyConversationBlob.legacyKey) == data)

        // Launch 3: the key is gone, so there is nothing left to do.
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .nothingToDo)
    }

    @Test("with the marker set: no key is nothing to do, and a stale key is moved without importing")
    func markerGatesWithoutKey() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        #expect(try store.importLegacy([]) == 0)     // sets the marker, imports nothing
        #expect(try store.legacyImportMarked())
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .nothingToDo)

        let stale = blob([conv("stale")])
        d.set(stale, forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .alreadyImported)
        #expect(try store.isEmpty())
        #expect(d.data(forKey: LegacyConversationBlob.key) == nil)
        #expect(d.data(forKey: LegacyConversationBlob.legacyKey) == stale)
    }

    @Test("an id already in the store is skipped rather than colliding, and the rest still import")
    func collidingIdIsSkipped() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        let shared = conv("live")
        var created = ChangeSet(); created.add(.created)
        try store.apply([ConversationWrite(id: shared.id, snapshot: shared, changes: created)])

        var older = shared
        older.title = "older copy"
        d.set(blob([older, conv("new")]), forKey: LegacyConversationBlob.key)
        // One of the two was written; the count reports what the user actually got.
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .imported(1))
        // The live row wins; the blob's other conversation lands behind it.
        #expect(try store.loadAll().conversations.map(\.title) == ["live", "new"])
    }

    @Test("an undecodable blob is backed up under a timestamped key and the live key removed, so it runs once")
    func undecodable() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        d.set(Data("{not json".utf8), forKey: LegacyConversationBlob.key)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d, now: now) == .undecodable)
        #expect(d.data(forKey: "iris_conversations_backup_1700000000.0") != nil)
        #expect(d.data(forKey: LegacyConversationBlob.key) == nil)
        #expect(try store.isEmpty())
        // The live key is gone, so a second launch finds nothing to do.
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .nothingToDo)
    }

    @Test("an import failure leaves the live key in place so it is retried at the next launch")
    func importFailed() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        let data = blob([conv("a")])
        d.set(data, forKey: LegacyConversationBlob.key)
        store.failInjection = { _ in true }
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .importFailed)
        #expect(d.data(forKey: LegacyConversationBlob.key) == data)
        #expect(try store.isEmpty())
        // Clearing the injection and retrying (as the next launch would) succeeds.
        store.failInjection = nil
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .imported(1))
    }
}
