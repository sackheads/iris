import Testing
import Foundation
import GRDB
@testable import iris

/// A store created by a pre-merge build of #226 recorded its archive migration as `v6_archive`;
/// main renumbered it `v7_archive`. Opening such a store re-ran the ALTER and failed with
/// "duplicate column name: isArchived", and the app fell back to memory without saying so.
/// Temp files only; never `~/.iris`.
@Suite("Store repair: pre-merge v6_archive")
struct StoreArchiveRepairTests {
    private func tempStoreURL() throws -> (root: URL, url: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-store-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("conversations.sqlite"))
    }

    /// The exact shape the owner's store has: v1..v5 from the real migrator, then the pre-merge
    /// `v6_archive` DDL (452fd80: one nullable BOOLEAN column, nothing else), then
    /// `v6_pause_surfacing`, each recorded under its own identifier.
    private func buildPreMergeStore(at url: URL, archived: UUID, active: UUID, unset: UUID) throws {
        let queue = try DatabaseQueue(path: url.path)
        try ConversationStore.migrator.migrate(queue, upTo: "v5_quarantine_ordinal_nullable")
        try queue.write { db in
            try db.execute(sql: #"ALTER TABLE "conversations" ADD COLUMN "isArchived" BOOLEAN"#)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v6_archive')")
            try db.execute(sql: #"ALTER TABLE "conversations" ADD COLUMN "lastGoalEvaluation" TEXT"#)
            try db.execute(sql: #"ALTER TABLE "conversations" ADD COLUMN "lastGoalCompletionReport" TEXT"#)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v6_pause_surfacing')")
            let usage = String(decoding: try JSONEncoder().encode(TokenUsage()), as: UTF8.self)
            for (pos, (id, flag)) in [(archived, true as Bool?), (active, false), (unset, nil)].enumerated() {
                try db.execute(sql: """
                    INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage, isArchived)
                    VALUES (?, ?, ?, datetime('now'), datetime('now'), ?, ?)
                    """, arguments: [id.uuidString, pos, "chat \(pos)", usage, flag])
            }
            let msg = ChatMessage(role: .user, content: "kept across the repair")
            let payload = String(decoding: try JSONEncoder().encode(msg), as: UTF8.self)
            try db.execute(sql: "INSERT INTO messages (conversationId, ordinal, id, payload) VALUES (?, 0, ?, ?)",
                           arguments: [archived.uuidString, msg.id.uuidString, payload])
        }
        try queue.close()
    }

    @Test("a store that recorded v6_archive opens, migrates to the latest, and keeps its rows")
    func preMergeStoreOpens() throws {
        let (root, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let archived = UUID(), active = UUID(), unset = UUID()
        try buildPreMergeStore(at: url, archived: archived, active: active, unset: unset)

        let store = try ConversationStore.onDisk(at: url)

        let (complete, applied) = try store.writer.read { db in
            (try ConversationStore.migrator.hasCompletedMigrations(db),
             try ConversationStore.migrator.appliedIdentifiers(db))
        }
        #expect(complete)
        #expect(applied.contains("v7_archive"))
        let loaded = try store.loadAll()
        #expect(loaded.skipped.isEmpty)
        let byId = Dictionary(uniqueKeysWithValues: loaded.conversations.map { ($0.id, $0) })
        #expect(byId.count == 3)
        #expect(byId[archived]?.isArchived == true)
        #expect(byId[active]?.isArchived == false)
        #expect(byId[unset]?.isArchived == false)
        #expect(byId[archived]?.messages.map(\.content) == ["kept across the repair"])
        // A second open is a plain no-op migrate.
        _ = try ConversationStore.onDisk(at: url)
    }

    @Test("v6_archive recorded without its column is left for v7_archive to add")
    func recordedButMissingColumnStillMigrates() throws {
        let (root, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DatabaseQueue(path: url.path)
        try ConversationStore.migrator.migrate(queue, upTo: "v6_pause_surfacing")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v6_archive')")
        }
        try queue.close()

        let store = try ConversationStore.onDisk(at: url)
        let (columns, complete) = try store.writer.read { db in
            (try db.columns(in: "conversations").map(\.name),
             try ConversationStore.migrator.hasCompletedMigrations(db))
        }
        #expect(columns.contains("isArchived"))
        #expect(complete)
    }

    @Test("a fresh on-disk store still migrates to the latest")
    func freshStoreMigrates() throws {
        let (root, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ConversationStore.onDisk(at: url)
        let (complete, applied) = try store.writer.read { db in
            (try ConversationStore.migrator.hasCompletedMigrations(db),
             try ConversationStore.migrator.appliedIdentifiers(db))
        }
        #expect(complete)
        #expect(!applied.contains("v6_archive"))
        #expect(store.openFailure == nil)
    }

    @Test("a store that cannot open falls back to memory and says so at launch")
    @MainActor func unopenableStoreIsLoud() throws {
        let (root, url) = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("this is not a database, just text long enough to fill a header page".utf8).write(to: url)

        let store = ConversationStore.openOrFallBack(at: url)
        #expect(store.path == nil)
        let failure = try #require(store.openFailure)
        #expect(!failure.isEmpty)

        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let target = try #require(state.selectedConversationId)
        let texts = state.conversations.first { $0.id == target }?.messages
            .filter { $0.role == .system }.map(\.content) ?? []
        #expect(texts.contains { $0.contains("could not be opened") && $0.contains("will not be saved") && $0.contains(failure) })
    }
}
