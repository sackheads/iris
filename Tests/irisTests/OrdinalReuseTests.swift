import Testing
import Foundation
import GRDB
@testable import IrisKit

/// #501: a message's ordinal is its index in the in-memory `messages` array, and `loadAll`
/// compacts the rows it reads into that array. Before the fix it checked the persisted ordinals
/// were contiguous only when a row failed to decode, so a hole on disk (0..<k, k+1...) loaded one
/// message short of max + 1, and every new session's first append landed on the last persisted
/// ordinal and `INSERT OR REPLACE`d it.
///
/// Every test runs on an on-disk store in its own temp directory, reopened per session the way a
/// new process would open it; nothing touches the real home.
@Suite("Ordinal reuse across sessions (#501)")
@MainActor
struct OrdinalReuseTests {
    /// A store file in a fresh temp directory. The caller removes `root`.
    private func tempStore() throws -> (root: URL, url: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-ordinal-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("conversations.sqlite"))
    }

    private func seed(_ store: ConversationStore, count: Int) throws -> Conversation {
        var c = Conversation(id: UUID(), title: "Iris", workspacePath: "/tmp/w")
        c.messages = (0..<count).map { ChatMessage(role: .user, content: "m\($0)") }
        c.history = (0..<count).map { Content(role: "user", parts: [Part(text: "h\($0)")]) }
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0)); s.add(.historyAppended(from: 0))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        return c
    }

    /// The persisted message rows, by ordinal, as their content.
    private func rows(_ store: ConversationStore, _ id: UUID) throws -> [Int: String] {
        try store.writer.read { db in
            var out: [Int: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT ordinal, payload FROM messages WHERE conversationId = ?",
                                      arguments: [id.uuidString]) {
                let data: Data = r["payload"]
                out[r["ordinal"]] = try JSONDecoder().decode(ChatMessage.self, from: data).content
            }
            return out
        }
    }

    /// The persisted history rows, by ordinal, as their first part's text.
    private func historyRows(_ store: ConversationStore, _ id: UUID) throws -> [Int: String] {
        try store.writer.read { db in
            var out: [Int: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT ordinal, payload FROM history WHERE conversationId = ?",
                                      arguments: [id.uuidString]) {
                let data: Data = r["payload"]
                out[r["ordinal"]] = try JSONDecoder().decode(Content.self, from: data).parts.first?.text ?? ""
            }
            return out
        }
    }

    /// A new process: its own connection to the file, and an `AppState` loaded from it.
    private func session(_ url: URL) throws -> AppState {
        AppState(store: try ConversationStore.onDisk(at: url), createIfEmpty: false, emitLaunchNotices: false)
    }

    @Test("control: without a hole, a second session's first append does not touch the first session's last message")
    func noHoleNoClobber() throws {
        let (root, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try seed(try ConversationStore.onDisk(at: url), count: 5)

        let first = try session(url)
        first.appendMessage(role: .event, content: "card A", to: c.id)
        first.flushSave()

        let second = try session(url)
        second.appendMessage(role: .event, content: "card B", to: c.id)
        second.flushSave()

        let r = try rows(try ConversationStore.onDisk(at: url), c.id)
        #expect(r[5] == "card A")
        #expect(r[6] == "card B")
    }

    @Test("a hole in the persisted ordinals no longer makes each new session overwrite the previous session's last message")
    func holeDoesNotMakeASessionClobberTheLastMessage() throws {
        let (root, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let seedStore = try ConversationStore.onDisk(at: url)
        let c = try seed(seedStore, count: 5)
        // A hole at ordinal 2, the shape left at Iris ordinal 85 on 2026-10-11.
        try seedStore.rawWrite("DELETE FROM messages WHERE conversationId = ? AND ordinal = 2", arguments: [c.id.uuidString])

        let first = try session(url)
        first.appendMessage(role: .event, content: "card A", to: c.id)
        first.flushSave()
        let afterFirst = try rows(try ConversationStore.onDisk(at: url), c.id)

        let second = try session(url)
        second.appendMessage(role: .event, content: "card B", to: c.id)
        second.flushSave()
        let afterSecond = try rows(try ConversationStore.onDisk(at: url), c.id)

        // Neither session's first append may overwrite a message it did not write.
        #expect(afterFirst.values.contains("m4"), "session 1's first append replaced m4: \(afterFirst.sorted { $0.key < $1.key })")
        #expect(afterSecond.values.contains("card A"), "session 2's first append replaced card A: \(afterSecond.sorted { $0.key < $1.key })")
        #expect(afterSecond == [0: "m0", 1: "m1", 2: "m3", 3: "m4", 4: "card A", 5: "card B"])
    }

    @Test("a messages gap heals on load: rows renumber to 0..<n, the search index follows, and nothing is reported")
    func messagesGapHealsOnLoad() throws {
        let (root, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationStore.onDisk(at: url)
        let c = try seed(store, count: 5)
        try store.rawWrite("DELETE FROM messages WHERE conversationId = ? AND ordinal = 2", arguments: [c.id.uuidString])

        let loaded = try store.loadAll()
        let back = try #require(loaded.conversations.first { $0.id == c.id })
        #expect(back.messages.map(\.content) == ["m0", "m1", "m3", "m4"])
        // A gap is not damage: no row was lost on this load, so nothing is reported or quarantined.
        #expect(loaded.skipped.isEmpty)
        #expect(loaded.repairFailed.isEmpty)
        #expect(try store.quarantineCount(for: c.id) == 0)
        #expect(try rows(store, c.id) == [0: "m0", 1: "m1", 2: "m3", 3: "m4"])
        // History had no gap and is untouched.
        #expect(try historyRows(store, c.id) == [0: "h0", 1: "h1", 2: "h2", 3: "h3", 4: "h4"])

        // The search index follows the renumber (#177/#201): its rowids match the rows' own, and a
        // hit's ordinal is the index of that message in the loaded array.
        #expect(try store.ftsRowidsByOrdinal(for: c.id) == store.messageRowidsByOrdinal(for: c.id))
        for (index, message) in back.messages.enumerated() {
            let hits = try store.searchConversations(query: message.content).filter { $0.conversationId == c.id }
            #expect(hits.map(\.ordinal) == [index], "search for \(message.content)")
        }

        // Healed for good: a second load finds nothing to do and returns the same thing.
        let again = try store.loadAll()
        #expect(again.conversations.first { $0.id == c.id }?.messages.map(\.content) == ["m0", "m1", "m3", "m4"])
        #expect(again.skipped.isEmpty)
    }

    @Test("a history gap heals on load, and the next history append no longer replaces the last row")
    func historyGapHealsOnLoad() throws {
        let (root, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationStore.onDisk(at: url)
        let c = try seed(store, count: 5)
        try store.rawWrite("DELETE FROM history WHERE conversationId = ? AND ordinal = 1", arguments: [c.id.uuidString])

        var back = try #require(try store.loadAll().conversations.first { $0.id == c.id })
        #expect(back.history.map { $0.parts.first?.text } == ["h0", "h2", "h3", "h4"])
        #expect(try historyRows(store, c.id) == [0: "h0", 1: "h2", 2: "h3", 3: "h4"])
        // Messages had no gap and are untouched.
        #expect(try rows(store, c.id) == [0: "m0", 1: "m1", 2: "m2", 3: "m3", 4: "m4"])

        // The next history append writes at the loaded count, the way `AppState` marks it.
        back.history.append(Content(role: "model", parts: [Part(text: "h5")]))
        var s = ChangeSet(); s.add(.historyAppended(from: back.history.count - 1))
        try store.apply([ConversationWrite(id: c.id, snapshot: back, changes: s)])
        #expect(try historyRows(store, c.id) == [0: "h0", 1: "h2", 2: "h3", 3: "h4", 4: "h5"])
    }

    @Test("a gap whose renumber fails excludes the conversation, reports it in repairFailed, and leaves the disk as it was")
    func failedGapRepairExcludesTheConversation() throws {
        let (root, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationStore.onDisk(at: url)
        let healthy = try seed(store, count: 3)
        let gapped = try seed(store, count: 3)
        try store.rawWrite("DELETE FROM messages WHERE conversationId = ? AND ordinal = 1", arguments: [gapped.id.uuidString])

        store.failInjection = { $0 == gapped.id }
        let loaded = try store.loadAll()
        store.failInjection = nil
        #expect(loaded.conversations.map(\.id) == [healthy.id])
        #expect(loaded.repairFailed == [gapped.id])
        // Untouched, so the repair is retried at the next launch, which then succeeds.
        #expect(try rows(store, gapped.id) == [0: "m0", 2: "m2"])
        let retried = try store.loadAll()
        #expect(retried.repairFailed.isEmpty)
        #expect(Set(retried.conversations.map(\.id)) == [healthy.id, gapped.id])
        #expect(try rows(store, gapped.id) == [0: "m0", 1: "m2"])
    }

    @Test("how the hole formed: two writers on one store (pre-#491), one with a stale count, leave a gap")
    func twoWritersLeaveAHole() throws {
        let (root, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = try seed(try ConversationStore.onDisk(at: url), count: 3)
        // Both open the same snapshot: the CLI first, then an app launched mid-run.
        let cli = try session(url)
        let app = try session(url)

        app.appendMessage(role: .system, content: "app 1", to: c.id)   // ordinal 3
        app.appendMessage(role: .system, content: "app 2", to: c.id)   // ordinal 4
        app.flushSave()
        cli.appendMessage(role: .event, content: "cli card", to: c.id) // ordinal 3; truncates >= 4
        cli.flushSave()
        app.appendMessage(role: .system, content: "app 3", to: c.id)   // ordinal 5; 4 is never rewritten
        app.flushSave()

        let r = try rows(try ConversationStore.onDisk(at: url), c.id)
        #expect(r[3] == "cli card")
        #expect(r[4] == nil, "the hole")
        #expect(r[5] == "app 3")
    }
}
