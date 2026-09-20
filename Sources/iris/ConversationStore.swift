import Foundation
import GRDB

/// What changed on one conversation since the last write (spec §3). `AppState` records these
/// instead of re-encoding the whole array; the store turns them into row writes.
enum ConversationChange: Sendable, Equatable {
    case created
    case metadata
    case messagesAppended(from: Int)
    case messageUpdated(id: UUID)
    case messagesReplaced
    case historyAppended(from: Int)
    case historyReplaced
    case deleted
}

/// The coalesced changes for one conversation.
struct ChangeSet: Sendable, Equatable {
    var created = false
    var deleted = false
    var metadata = false
    var messagesFrom: Int? = nil
    var messagesReplaced = false
    var updatedMessageIds: Set<UUID> = []
    var historyFrom: Int? = nil
    var historyReplaced = false

    var isEmpty: Bool {
        !created && !deleted && !metadata && messagesFrom == nil && !messagesReplaced
            && updatedMessageIds.isEmpty && historyFrom == nil && !historyReplaced
    }

    mutating func add(_ change: ConversationChange) {
        switch change {
        case .created: created = true
        case .metadata: metadata = true
        case .messagesAppended(let from): if !messagesReplaced { messagesFrom = min(messagesFrom ?? from, from) }
        case .messageUpdated(let id): updatedMessageIds.insert(id)
        case .messagesReplaced: messagesReplaced = true; messagesFrom = nil
        case .historyAppended(let from): if !historyReplaced { historyFrom = min(historyFrom ?? from, from) }
        case .historyReplaced: historyReplaced = true; historyFrom = nil
        case .deleted: deleted = true
        }
    }

    /// Fold another set in (a failed batch re-queued behind newer changes).
    mutating func merge(_ other: ChangeSet) {
        created = created || other.created
        deleted = deleted || other.deleted
        metadata = metadata || other.metadata
        messagesReplaced = messagesReplaced || other.messagesReplaced
        historyReplaced = historyReplaced || other.historyReplaced
        messagesFrom = messagesReplaced ? nil : [messagesFrom, other.messagesFrom].compactMap { $0 }.min()
        historyFrom = historyReplaced ? nil : [historyFrom, other.historyFrom].compactMap { $0 }.min()
        updatedMessageIds.formUnion(other.updatedMessageIds)
    }
}

/// One conversation's pending write: a value snapshot (nil when deleted) plus what changed.
struct ConversationWrite: Sendable {
    let id: UUID
    let snapshot: Conversation?
    let changes: ChangeSet
}

struct SkippedRow: Sendable, Equatable {
    let conversationId: UUID?
    let table: String
    let ordinal: Int?
    let reason: String
}

struct LoadResult: Sendable {
    var conversations: [Conversation]
    var skipped: [SkippedRow]
}

/// Per-conversation SQLite persistence (spec §2, §4, §5). One metadata row per conversation,
/// one JSON row per message and per history entry. Every write is keyed by ordinal or id, so
/// applying the same batch twice is harmless.
final class ConversationStore: Sendable {
    private let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static func inMemory() throws -> ConversationStore {
        try ConversationStore(writer: DatabaseQueue(configuration: Self.configuration))
    }

    static func onDisk(at url: URL) throws -> ConversationStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try ConversationStore(writer: DatabasePool(path: url.path, configuration: Self.configuration))
    }

    private static var configuration: Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        c.prepareDatabase { db in db.trace { _ in } }
        return c
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_conversation_store") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("position", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("workspacePath", .text)
                t.column("activeGoal", .text)
                t.column("messageCountSinceReflection", .integer).notNull().defaults(to: 0)
                t.column("goalIterationCount", .integer).notNull().defaults(to: 0)
                t.column("mainAgentSandbox", .text)
                t.column("tokenUsage", .text).notNull()
                t.column("goalContract", .text)
                t.column("subagentResult", .text)
            }
            try db.create(table: "messages") { t in
                t.column("conversationId", .text).notNull().references("conversations", column: "id", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("id", .text).notNull()
                t.column("payload", .text).notNull()
                t.primaryKey(["conversationId", "ordinal"])
            }
            try db.create(index: "messages_by_id", on: "messages", columns: ["conversationId", "id"])
            try db.create(table: "history") { t in
                t.column("conversationId", .text).notNull().references("conversations", column: "id", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("payload", .text).notNull()
                t.primaryKey(["conversationId", "ordinal"])
            }
        }
        return m
    }

    // MARK: Write

    func apply(_ batch: [ConversationWrite]) throws {
        guard !batch.isEmpty else { return }
        let encoder = JSONEncoder()
        try writer.write { db in
            for w in batch {
                if w.changes.deleted {
                    try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [w.id.uuidString])
                    continue
                }
                guard let c = w.snapshot else { continue }
                let exists = try (Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)", arguments: [c.id.uuidString]) ?? 0) == 1
                if !exists || w.changes.created || w.changes.metadata {
                    try Self.upsertMetadata(c, exists: exists, db: db, encoder: encoder)
                }
                if w.changes.messagesReplaced {
                    try db.execute(sql: "DELETE FROM messages WHERE conversationId = ?", arguments: [c.id.uuidString])
                    try Self.insertMessages(c, from: 0, db: db, encoder: encoder)
                } else {
                    if let from = w.changes.messagesFrom { try Self.insertMessages(c, from: from, db: db, encoder: encoder) }
                    for id in w.changes.updatedMessageIds {
                        guard let m = c.messages.first(where: { $0.id == id }) else { continue }
                        try db.execute(sql: "UPDATE messages SET payload = ? WHERE conversationId = ? AND id = ?",
                                       arguments: [try Self.json(m, encoder), c.id.uuidString, id.uuidString])
                    }
                }
                if w.changes.historyReplaced {
                    try db.execute(sql: "DELETE FROM history WHERE conversationId = ?", arguments: [c.id.uuidString])
                    try Self.insertHistory(c, from: 0, db: db, encoder: encoder)
                } else if let from = w.changes.historyFrom {
                    try Self.insertHistory(c, from: from, db: db, encoder: encoder)
                }
            }
        }
    }

    private static func json<T: Encodable>(_ value: T, _ encoder: JSONEncoder) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func upsertMetadata(_ c: Conversation, exists: Bool, db: Database, encoder: JSONEncoder) throws {
        let now = Date()
        let tokenUsage = try json(c.tokenUsage, encoder)
        let contract = try c.goalContract.map { try json($0, encoder) }
        let result = try c.subagentResult.map { try json($0, encoder) }
        if exists {
            try db.execute(sql: """
                UPDATE conversations SET title = ?, updatedAt = ?, workspacePath = ?, activeGoal = ?,
                    messageCountSinceReflection = ?, goalIterationCount = ?, mainAgentSandbox = ?,
                    tokenUsage = ?, goalContract = ?, subagentResult = ?
                WHERE id = ?
                """, arguments: [c.title, now, c.workspacePath, c.activeGoal, c.messageCountSinceReflection,
                                 c.goalIterationCount, c.mainAgentSandbox?.rawValue, tokenUsage, contract, result, c.id.uuidString])
        } else {
            let position = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) FROM conversations") ?? 0) + 1
            try db.execute(sql: """
                INSERT INTO conversations (id, position, title, createdAt, updatedAt, workspacePath, activeGoal,
                    messageCountSinceReflection, goalIterationCount, mainAgentSandbox, tokenUsage, goalContract, subagentResult)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [c.id.uuidString, position, c.title, now, now, c.workspacePath, c.activeGoal,
                                 c.messageCountSinceReflection, c.goalIterationCount, c.mainAgentSandbox?.rawValue,
                                 tokenUsage, contract, result])
        }
    }

    private static func insertMessages(_ c: Conversation, from: Int, db: Database, encoder: JSONEncoder) throws {
        guard from < c.messages.count else { return }
        for ordinal in from..<c.messages.count {
            let m = c.messages[ordinal]
            try db.execute(sql: "INSERT OR REPLACE INTO messages (conversationId, ordinal, id, payload) VALUES (?, ?, ?, ?)",
                           arguments: [c.id.uuidString, ordinal, m.id.uuidString, try json(m, encoder)])
        }
    }

    private static func insertHistory(_ c: Conversation, from: Int, db: Database, encoder: JSONEncoder) throws {
        guard from < c.history.count else { return }
        for ordinal in from..<c.history.count {
            try db.execute(sql: "INSERT OR REPLACE INTO history (conversationId, ordinal, payload) VALUES (?, ?, ?)",
                           arguments: [c.id.uuidString, ordinal, try json(c.history[ordinal], encoder)])
        }
    }

    // MARK: Read

    func loadAll() throws -> LoadResult {
        let decoder = JSONDecoder()
        return try writer.read { db in
            var out = LoadResult(conversations: [], skipped: [])
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM conversations ORDER BY position")
            for row in rows {
                guard let idString: String = row["id"], let id = UUID(uuidString: idString) else {
                    out.skipped.append(SkippedRow(conversationId: nil, table: "conversations", ordinal: nil, reason: "bad id"))
                    continue
                }
                var c: Conversation
                do {
                    let title: String = row["title"] ?? "Untitled"
                    c = Conversation(id: id, title: title, workspacePath: row["workspacePath"])
                    c.activeGoal = row["activeGoal"]
                    c.messageCountSinceReflection = row["messageCountSinceReflection"] ?? 0
                    c.goalIterationCount = row["goalIterationCount"] ?? 0
                    c.mainAgentSandbox = (row["mainAgentSandbox"] as String?).flatMap(SandboxPref.init(rawValue:))
                    c.tokenUsage = try decoder.decode(TokenUsage.self, from: Data((row["tokenUsage"] as String? ?? "{}").utf8))
                    if let s: String = row["goalContract"] { c.goalContract = try decoder.decode(GoalContract.self, from: Data(s.utf8)) }
                    if let s: String = row["subagentResult"] { c.subagentResult = try decoder.decode(SubagentResult.self, from: Data(s.utf8)) }
                } catch {
                    out.skipped.append(SkippedRow(conversationId: id, table: "conversations", ordinal: nil, reason: "\(error)"))
                    continue
                }
                for r in try Row.fetchAll(db, sql: "SELECT ordinal, payload FROM messages WHERE conversationId = ? ORDER BY ordinal", arguments: [idString]) {
                    let ordinal: Int = r["ordinal"]
                    do { c.messages.append(try decoder.decode(ChatMessage.self, from: Data((r["payload"] as String).utf8))) }
                    catch { out.skipped.append(SkippedRow(conversationId: id, table: "messages", ordinal: ordinal, reason: "\(error)")) }
                }
                for r in try Row.fetchAll(db, sql: "SELECT ordinal, payload FROM history WHERE conversationId = ? ORDER BY ordinal", arguments: [idString]) {
                    let ordinal: Int = r["ordinal"]
                    do { c.history.append(try decoder.decode(Content.self, from: Data((r["payload"] as String).utf8))) }
                    catch { out.skipped.append(SkippedRow(conversationId: id, table: "history", ordinal: ordinal, reason: "\(error)")) }
                }
                out.conversations.append(c)
            }
            return out
        }
    }

    func counts(for id: UUID) throws -> (messages: Int, history: Int) {
        try writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversationId = ?", arguments: [id.uuidString]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history WHERE conversationId = ?", arguments: [id.uuidString]) ?? 0)
        }
    }

    func isEmpty() throws -> Bool {
        try writer.read { db in (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0) == 0 }
    }

    /// Tests corrupt rows through this; nothing in the app calls it.
    func rawWrite(_ sql: String, arguments: StatementArguments = []) throws {
        try writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    }
}
