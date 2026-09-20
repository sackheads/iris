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

/// A message/history row `loadAll` could not decode, captured with its raw bytes so it can be
/// moved to `quarantine` and the surviving rows renumbered before the read returns (review
/// finding, #163 round 1: leaving the bad row's ordinal occupied while the in-memory array is
/// compacted made the next append — which uses the compacted index as the ordinal — overwrite
/// the wrong row and its trailing-row cleanup delete a good one).
private struct QuarantineCandidate {
    let conversationId: UUID
    let table: String   // "messages" | "history"
    let ordinal: Int
    let payload: Data?
    let reason: String
}

/// Thrown by `apply(_:)` when one or more conversations in the batch failed to write. The
/// conversations not listed here committed normally.
enum ConversationStoreError: Error, Equatable {
    case partialFailure(failedIds: [UUID])
}

/// Internal signal thrown by `failInjection` to make one conversation's savepoint roll back;
/// never escapes `apply(_:)`, which reports the id through `ConversationStoreError` instead;
/// `importLegacy` lets it propagate so the legacy import can report `.importFailed`.
private struct InjectedWriteFailure: Error {}

/// Per-conversation SQLite persistence (spec §2, §4, §5). One metadata row per conversation,
/// one JSON row per message and per history entry. Every write is keyed by ordinal or id, so
/// applying the same batch twice is harmless.
final class ConversationStore: Sendable {
    private let writer: any DatabaseWriter
    private let failInjectionLock = NSLock()
    nonisolated(unsafe) private var _failInjection: (@Sendable (UUID) -> Bool)?

    /// Test-only seam: when set, consulted with each conversation's id at the top of its
    /// savepoint in `apply(_:)`; returning `true` makes that conversation's write fail without
    /// needing a naturally-occurring constraint violation, so `apply`'s partial-failure handling
    /// (spec §3 retry-by-merge) can be exercised deterministically. `nil` (the default) never
    /// fails anything; nothing in the app sets this. Also consulted once (with a throwaway id) at
    /// the top of `importLegacy`'s transaction, so `LegacyConversationBlob`'s `.importFailed`
    /// outcome can be exercised the same way.
    var failInjection: (@Sendable (UUID) -> Bool)? {
        get { failInjectionLock.withLock { _failInjection } }
        set { failInjectionLock.withLock { _failInjection = newValue } }
    }

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
            // Where `loadAll` moves a message/history row it could not decode (review finding,
            // #163 round 1). Deliberately NOT a foreign key to `conversations`: a quarantined row
            // must survive the conversation being deleted so it can still be recovered manually.
            try db.create(table: "quarantine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull()
                t.column("sourceTable", .text).notNull()      // "messages" | "history"
                t.column("ordinal", .integer).notNull()       // the ordinal it occupied
                t.column("payload", .blob)                    // raw bytes as stored; may be NULL
                t.column("reason", .text).notNull()
                t.column("quarantinedAt", .datetime).notNull()
            }
        }
        return m
    }

    // MARK: Write

    /// Applies a batch of conversation writes in one transaction, but each conversation gets its
    /// own savepoint: if one conversation's writes fail, only that savepoint rolls back and the
    /// rest of the batch still commits. This matters because the spec's retry-by-merge (§3) folds
    /// a failed write's `ChangeSet` into the next one and tries again — one conversation stuck in
    /// a permanently failing state (a decode bug, a future migration mismatch) must not block
    /// persistence for every other open conversation. If any conversation failed, `apply` throws
    /// `ConversationStoreError.partialFailure(failedIds:)` after the transaction commits the
    /// successful ones, so the caller knows exactly which writes to re-queue.
    ///
    /// `unlessCancelled` is checked as the first statement inside the write transaction, after the
    /// writer lock is held: a detached write that lost the race to `AppState.flushSave` must not
    /// re-apply its now-stale snapshot, because the append paths truncate trailing rows and would
    /// delete exactly the rows the quit-time write just added. Standing down here writes nothing
    /// and throws nothing — the caller that cancelled it has already written the current state.
    func apply(_ batch: [ConversationWrite], unlessCancelled: @Sendable () -> Bool = { false }) throws {
        guard !batch.isEmpty else { return }
        let encoder = JSONEncoder()
        var failedIds: [UUID] = []
        try writer.write { db in
            if unlessCancelled() { return }
            for w in batch {
                do {
                    try db.inSavepoint {
                        if self.failInjection?(w.id) == true {
                            throw InjectedWriteFailure()
                        }
                        try Self.applyOne(w, db: db, encoder: encoder)
                        return .commit
                    }
                } catch {
                    failedIds.append(w.id)
                }
            }
        }
        if !failedIds.isEmpty {
            throw ConversationStoreError.partialFailure(failedIds: failedIds)
        }
    }

    private static func applyOne(_ w: ConversationWrite, db: Database, encoder: JSONEncoder) throws {
        if w.changes.deleted {
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [w.id.uuidString])
            return
        }
        guard let c = w.snapshot else { return }
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
        if from < c.messages.count {
            for ordinal in from..<c.messages.count {
                let m = c.messages[ordinal]
                try db.execute(sql: "INSERT OR REPLACE INTO messages (conversationId, ordinal, id, payload) VALUES (?, ?, ?, ?)",
                               arguments: [c.id.uuidString, ordinal, m.id.uuidString, try json(m, encoder)])
            }
        }
        // A snapshot shorter than what's on disk (e.g. history/messages cleared and re-appended
        // to fewer entries) leaves stale trailing rows behind; drop anything past the new end.
        try db.execute(sql: "DELETE FROM messages WHERE conversationId = ? AND ordinal >= ?", arguments: [c.id.uuidString, c.messages.count])
    }

    private static func insertHistory(_ c: Conversation, from: Int, db: Database, encoder: JSONEncoder) throws {
        if from < c.history.count {
            for ordinal in from..<c.history.count {
                try db.execute(sql: "INSERT OR REPLACE INTO history (conversationId, ordinal, payload) VALUES (?, ?, ?)",
                               arguments: [c.id.uuidString, ordinal, try json(c.history[ordinal], encoder)])
            }
        }
        try db.execute(sql: "DELETE FROM history WHERE conversationId = ? AND ordinal >= ?", arguments: [c.id.uuidString, c.history.count])
    }

    /// Reads a nullable text column without GRDB's forced-conversion trap on invalid UTF8 bytes.
    /// GRDB's typed `Row` subscript force-tries (`try!`) the SQLite→Swift conversion for both
    /// `String` and `String?`, and `String.fromDatabaseValue` *fails* — rather than returning
    /// nil — when the stored bytes are not valid UTF8, so an ordinary `row[column] as String?`
    /// still crashes the whole load on a corrupted or `rawWrite`-poked column. `Data` never fails
    /// that conversion (it just copies the bytes), so the metadata text columns are read through it
    /// (message and history payloads are read as `Data?` directly and decoded from bytes)
    /// and decoded ourselves; invalid bytes and SQL NULL both come back as `nil`, which is what
    /// every caller below already treats them as (missing/unreadable).
    private static func readText(_ row: Row, _ column: String) -> String? {
        guard let data: Data = row[column] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Read

    func loadAll() throws -> LoadResult {
        let decoder = JSONDecoder()
        let (result, candidates): (LoadResult, [QuarantineCandidate]) = try writer.read { db in
            var out = LoadResult(conversations: [], skipped: [])
            var candidates: [QuarantineCandidate] = []
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM conversations ORDER BY position")
            for row in rows {
                guard let idString = Self.readText(row, "id"), let id = UUID(uuidString: idString) else {
                    out.skipped.append(SkippedRow(conversationId: nil, table: "conversations", ordinal: nil, reason: "bad id"))
                    continue
                }
                var c: Conversation
                do {
                    let title = Self.readText(row, "title") ?? "Untitled"
                    c = Conversation(id: id, title: title, workspacePath: Self.readText(row, "workspacePath"))
                    c.activeGoal = Self.readText(row, "activeGoal")
                    c.messageCountSinceReflection = row["messageCountSinceReflection"] ?? 0
                    c.goalIterationCount = row["goalIterationCount"] ?? 0
                    c.mainAgentSandbox = Self.readText(row, "mainAgentSandbox").flatMap(SandboxPref.init(rawValue:))
                    c.tokenUsage = try Self.readText(row, "tokenUsage").map { try decoder.decode(TokenUsage.self, from: Data($0.utf8)) } ?? TokenUsage()
                    if let s = Self.readText(row, "goalContract") { c.goalContract = try decoder.decode(GoalContract.self, from: Data(s.utf8)) }
                    if let s = Self.readText(row, "subagentResult") { c.subagentResult = try decoder.decode(SubagentResult.self, from: Data(s.utf8)) }
                } catch {
                    // Whole-conversation skip: nothing in memory represents this conversation, so
                    // nothing can ever write to it again. No quarantine/renumber needed.
                    out.skipped.append(SkippedRow(conversationId: id, table: "conversations", ordinal: nil, reason: "\(error)"))
                    continue
                }
                for r in try Row.fetchAll(db, sql: "SELECT ordinal, payload FROM messages WHERE conversationId = ? ORDER BY ordinal", arguments: [idString]) {
                    let ordinal: Int? = r["ordinal"]
                    let raw: Data? = r["payload"]
                    guard let raw else {
                        out.skipped.append(SkippedRow(conversationId: id, table: "messages", ordinal: ordinal, reason: "unreadable payload"))
                        if let ordinal { candidates.append(QuarantineCandidate(conversationId: id, table: "messages", ordinal: ordinal, payload: nil, reason: "unreadable payload")) }
                        continue
                    }
                    do { c.messages.append(try decoder.decode(ChatMessage.self, from: raw)) }
                    catch {
                        out.skipped.append(SkippedRow(conversationId: id, table: "messages", ordinal: ordinal, reason: "\(error)"))
                        if let ordinal { candidates.append(QuarantineCandidate(conversationId: id, table: "messages", ordinal: ordinal, payload: raw, reason: "\(error)")) }
                    }
                }
                for r in try Row.fetchAll(db, sql: "SELECT ordinal, payload FROM history WHERE conversationId = ? ORDER BY ordinal", arguments: [idString]) {
                    let ordinal: Int? = r["ordinal"]
                    let raw: Data? = r["payload"]
                    guard let raw else {
                        out.skipped.append(SkippedRow(conversationId: id, table: "history", ordinal: ordinal, reason: "unreadable payload"))
                        if let ordinal { candidates.append(QuarantineCandidate(conversationId: id, table: "history", ordinal: ordinal, payload: nil, reason: "unreadable payload")) }
                        continue
                    }
                    do { c.history.append(try decoder.decode(Content.self, from: raw)) }
                    catch {
                        out.skipped.append(SkippedRow(conversationId: id, table: "history", ordinal: ordinal, reason: "\(error)"))
                        if let ordinal { candidates.append(QuarantineCandidate(conversationId: id, table: "history", ordinal: ordinal, payload: raw, reason: "\(error)")) }
                    }
                }
                out.conversations.append(c)
            }
            return (out, candidates)
        }

        guard !candidates.isEmpty else { return result }

        // Repair inside one write transaction, only when there is something to repair: quarantine
        // the bad rows, then renumber what's left so ordinals stay contiguous 0..<n. Left as-is,
        // the in-memory array above (already compacted by the skips) and the on-disk ordinals
        // disagree — the next append uses the compacted in-memory index as the ordinal, so it
        // `INSERT OR REPLACE`s the wrong row while the trailing-row `DELETE` drops a good one
        // (review finding, #163 round 1).
        try writer.write { db in
            let now = Date()
            var grouped: [String: [QuarantineCandidate]] = [:]
            for candidate in candidates {
                grouped[candidate.conversationId.uuidString + "|" + candidate.table, default: []].append(candidate)
            }
            for (_, group) in grouped {
                guard let first = group.first else { continue }
                let convIdString = first.conversationId.uuidString
                let table = first.table
                for candidate in group {
                    try db.execute(sql: """
                        INSERT INTO quarantine (conversationId, sourceTable, ordinal, payload, reason, quarantinedAt)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [convIdString, table, candidate.ordinal, candidate.payload, candidate.reason, now])
                    try db.execute(sql: "DELETE FROM \(table) WHERE conversationId = ? AND ordinal = ?",
                                   arguments: [convIdString, candidate.ordinal])
                }
                // Renumber the survivors to a contiguous 0..<n, preserving relative order. Shifting
                // by a large, out-of-range offset first avoids colliding with the
                // (conversationId, ordinal) primary key while rows are retargeted one at a time.
                try db.execute(sql: "UPDATE \(table) SET ordinal = ordinal + 1000000 WHERE conversationId = ?", arguments: [convIdString])
                let survivors = try Row.fetchAll(db, sql: "SELECT ordinal FROM \(table) WHERE conversationId = ? ORDER BY ordinal ASC", arguments: [convIdString])
                for (index, row) in survivors.enumerated() {
                    let shifted: Int = row["ordinal"]
                    try db.execute(sql: "UPDATE \(table) SET ordinal = ? WHERE conversationId = ? AND ordinal = ?", arguments: [index, convIdString, shifted])
                }
            }
        }
        return result
    }

    func counts(for id: UUID) throws -> (messages: Int, history: Int) {
        try writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversationId = ?", arguments: [id.uuidString]) ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history WHERE conversationId = ?", arguments: [id.uuidString]) ?? 0)
        }
    }

    /// Test support: how many rows this conversation has had quarantined by `loadAll`.
    func quarantineCount(for id: UUID) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quarantine WHERE conversationId = ?", arguments: [id.uuidString]) ?? 0
        }
    }

    func isEmpty() throws -> Bool {
        try writer.read { db in (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0) == 0 }
    }

    /// Test support: the raw `position` column, keyed by conversation id — lets a test assert
    /// positions stay distinct across deletions and re-insertions without relying solely on
    /// `loadAll`'s array order.
    func positions() throws -> [UUID: Int] {
        try writer.read { db in
            var out: [UUID: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, position FROM conversations") {
                guard let idString = Self.readText(row, "id"), let id = UUID(uuidString: idString) else { continue }
                if let position: Int = row["position"] { out[id] = position }
            }
            return out
        }
    }

    /// Tests corrupt rows through this; nothing in the app calls it.
    func rawWrite(_ sql: String, arguments: StatementArguments = []) throws {
        try writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    }
}

extension ConversationStore {
    /// First-launch import (spec §6). Returns false and writes nothing when the store already
    /// holds conversations; the check runs inside the write transaction so a crash between a
    /// previous import's commit and the key move cannot double-import.
    func importLegacy(_ conversations: [Conversation]) throws -> Bool {
        try writer.write { db in
            if (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0) > 0 { return false }
            if self.failInjection?(UUID()) == true { throw InjectedWriteFailure() }
            let encoder = JSONEncoder()
            for c in conversations {
                try Self.upsertMetadata(c, exists: false, db: db, encoder: encoder)
                try Self.insertMessages(c, from: 0, db: db, encoder: encoder)
                try Self.insertHistory(c, from: 0, db: db, encoder: encoder)
            }
            return true
        }
    }
}

extension ConversationStore {
    /// Spec §1: on disk only in a normal app process. The test bundle links XCTest (the same
    /// signal `IrisDefaults` uses); headless runs set `HeadlessMode`; a fake-lane perf run has
    /// volatile defaults but the real `IrisPaths`, and must not open the user's database.
    static func makeDefault() -> ConversationStore {
        let isolated = NSClassFromString("XCTestCase") != nil || HeadlessMode.isEnabled || IrisDefaults.isVolatileCopy
        if !isolated {
            do { return try onDisk(at: IrisPaths.default.conversationsDB) }
            catch { print("WARNING: conversation store failed to open on disk, using memory only: \(error)") }
        }
        return try! inMemory()
    }
}
