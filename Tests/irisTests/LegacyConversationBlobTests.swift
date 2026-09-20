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

    @Test("a second run finds no key; a blob against a non-empty store is not imported but is still moved")
    func idempotent() throws {
        let store = try ConversationStore.inMemory()
        let (d, name) = defaults()
        defer { cleanup(d, name) }
        d.set(blob([conv("a")]), forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .imported(1))
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .nothingToDo)
        d.set(blob([conv("stale")]), forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .storeNotEmpty)
        #expect(try store.loadAll().conversations.map(\.title) == ["a"])
        #expect(d.data(forKey: LegacyConversationBlob.key) == nil)
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
