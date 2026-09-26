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
    /// Whether the conversation survived this loss (#233).
    ///
    /// A field rather than a suffix on `reason`, because the launch notice has to tell "this
    /// conversation could not be read" apart from "this conversation lost an audit trail", and
    /// substring-matching prose to decide which sentence a user sees is a way to get it wrong
    /// later. Defaults to `false`: a row that does not say it was kept is a row that cost the
    /// conversation.
    var kept: Bool = false
}

struct LoadResult: Sendable {
    var conversations: [Conversation]
    var skipped: [SkippedRow]
    /// Conversations that had a quarantine repair to write, where the repair transaction itself
    /// failed (#189) — e.g. a read-only database. They are excluded from `conversations` rather
    /// than returned with their in-memory array compacted past ordinals the disk still has gaps
    /// in, which would re-open the append-clobber bug #163's quarantine exists to prevent. Left
    /// entirely untouched on disk, so the repair is retried at the next launch.
    var repairFailed: [UUID] = []
}

/// A message/history row `loadAll` could not decode, captured with its raw bytes so it can be
/// moved to `quarantine` and the surviving rows renumbered before the read returns (review
/// finding, #163 round 1: leaving the bad row's ordinal occupied while the in-memory array is
/// compacted made the next append — which uses the compacted index as the ordinal — overwrite
/// the wrong row and its trailing-row cleanup delete a good one).
private struct QuarantineCandidate {
    let conversationId: UUID
    let table: String   // "messages" | "history"
    /// nil when the ordinal itself is what's unreadable (#189) — the row is then found and
    /// deleted by `rowid` instead, and the quarantine row records `ordinal` as NULL.
    let ordinal: Int?
    /// Needed only to locate the row when `ordinal` is nil; the `messages`/`history` primary key
    /// is `(conversationId, ordinal)`, so an unreadable ordinal leaves rowid as the only handle.
    let rowid: Int64?
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

/// The stand-down flag a detached write checks under the writer lock. One instance per detached
/// write; `AppState.flushSave` signals it before cancelling the task, so the write knows to write
/// nothing even though a detached `Task`'s cancellation is invisible from inside a synchronous
/// GRDB write block (`Task.isCancelled` read there is the *enclosing* task's flag, which on a
/// non-Task thread is simply always false — an explicit flag says what we mean).
final class WriteStandDown: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var flag = false
    func signal() { lock.withLock { flag = true } }
    var isSignalled: Bool { lock.withLock { flag } }
}

/// One message matching a conversation search, with enough context for the model or the user to
/// know which chat it came from (#177).
struct ConversationHit: Sendable, Equatable {
    let conversationId: UUID
    let title: String
    let role: ChatRole
    let ordinal: Int
    let snippet: String
}

/// Per-conversation SQLite persistence (spec §2, §4, §5). One metadata row per conversation,
/// one JSON row per message and per history entry. Every write is keyed by ordinal or id, so
/// applying the same batch twice is harmless.
final class ConversationStore: Sendable {
    /// Internal, not private: `JobLedger` (#187) shares this writer so a job row and the
    /// conversation it produces commit against one database, and a store test can seed a raw
    /// row that the typed API would refuse to write.
    let writer: any DatabaseWriter
    private let failInjectionLock = NSLock()
    nonisolated(unsafe) private var _failInjection: (@Sendable (UUID) -> Bool)?

    /// Test-only seam: when set, consulted with each conversation's id at the top of its
    /// savepoint in `apply(_:)`; returning `true` makes that conversation's write fail without
    /// needing a naturally-occurring constraint violation, so `apply`'s partial-failure handling
    /// (spec §3 retry-by-merge) can be exercised deterministically. `nil` (the default) never
    /// fails anything; nothing in the app sets this. Also consulted once (with a throwaway id) at
    /// the top of `importLegacy`'s transaction, so `LegacyConversationBlob`'s `.importFailed`
    /// outcome can be exercised the same way; and once per conversation at the top of `loadAll`'s
    /// quarantine-repair transaction, so its failure handling (#189) can be exercised the same way
    /// a real write failure (a read-only database, a full disk) cannot be triggered on demand.
    var failInjection: (@Sendable (UUID) -> Bool)? {
        get { failInjectionLock.withLock { _failInjection } }
        set { failInjectionLock.withLock { _failInjection = newValue } }
    }

    /// Where this store's database file lives, or nil for an in-memory store. Lets a test assert
    /// the isolation rule in §1 directly ("this process got a memory store") instead of only
    /// inferring it from the absence of a file under the real paths.
    let path: URL?
    var isOnDisk: Bool { path != nil }

    /// Scheduled and event-driven jobs (#187), on this store's writer and this store's schema.
    let ledger: JobLedger

    private init(writer: any DatabaseWriter, path: URL?) throws {
        self.writer = writer
        self.path = path
        try Self.migrator.migrate(writer)
        self.ledger = JobLedger(writer: writer)
    }

    static func inMemory() throws -> ConversationStore {
        try ConversationStore(writer: DatabaseQueue(configuration: Self.configuration), path: nil)
    }

    static func onDisk(at url: URL) throws -> ConversationStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try ConversationStore(writer: DatabasePool(path: url.path, configuration: Self.configuration), path: url)
    }

    private static var configuration: Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        c.prepareDatabase { db in db.trace { _ in } }
        return c
    }

    /// Internal, not private, so a test can build a v1-era database (`migrate(_:upTo:)`) and prove
    /// the v2 backfill runs against it.
    static var migrator: DatabaseMigrator {
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
            // One-off facts about the store itself. Today it holds exactly one key,
            // `legacy_import_done`, which is what makes the blob import at-most-once (review
            // finding, #163 round 2: "the store has rows" is not the same question — after a
            // failed import the app creates its default conversation, so the next launch saw a
            // non-empty store, declared the import already done, and parked the blob unimported).
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        // Cross-conversation full-text search (#177). A standalone FTS5 table, deliberately NOT
        // `synchronize(withTable: "messages")`: the indexed text is a field *inside* the message
        // payload JSON, and only two of the four roles are indexed at all, so the shadow triggers
        // GRDB would install cannot express what belongs in the index. Every write path in
        // `applyOne` maintains it explicitly, in the same transaction as the row it mirrors.
        m.registerMigration("v2_conversation_search") { db in
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.column("conversationId").notIndexed()
                t.column("ordinal").notIndexed()
                t.column("role").notIndexed()
                t.column("content")
            }
            let decoder = JSONDecoder()
            // Streamed, not `fetchAll`: this runs once over every message the user has ever sent,
            // and materializing all of them — payload text included — would spike memory on a
            // large store at the worst moment, during a migration.
            let cursor = try Row.fetchCursor(db, sql: "SELECT rowid, conversationId, ordinal, payload FROM messages")
            while let row = try cursor.next() {
                guard let conversationId = Self.readText(row, "conversationId"),
                      let rowid: Int64 = row["rowid"],
                      let payload: Data = row["payload"],
                      let m = try? decoder.decode(ChatMessage.self, from: payload)
                else { continue }   // an undecodable row is #163's quarantine concern, not ours
                // Not the trapping `Int` subscript (#189): a pre-existing TEXT ordinal must skip
                // this row, not crash the migration before #189's own hardening ever runs.
                guard case .value(let ordinal) = Self.readInt(row, "ordinal") else { continue }
                try Self.indexMessage(m, conversationId: conversationId, ordinal: ordinal, rowid: rowid, db: db)
            }
        }
        // Slice D3's audit trail (`Conversation.checkpointHistory`). A new nullable column rather
        // than a rebuild: every existing row reads back as SQL NULL, which `loadAll` turns into
        // `[]` — the same forward-compat rule invariant 1 imposes on the JSON codec.
        m.registerMigration("v3_checkpoint_history") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "checkpointHistory", .text)
            }
        }
        // Keys `messages_fts` rows by the `messages` rowid instead of finding them by a
        // `(conversationId, ordinal)` scan over UNINDEXED columns (#201). The index is derived
        // data, so a full rebuild is safe and simplest: it also gives existing installs, which
        // built their v2 rows with FTS5's own auto-assigned rowids, a consistent keying.
        m.registerMigration("v4_fts_rowid") { db in
            try db.execute(sql: "DELETE FROM messages_fts")
            let decoder = JSONDecoder()
            let cursor = try Row.fetchCursor(db, sql: "SELECT rowid, conversationId, ordinal, payload FROM messages")
            while let row = try cursor.next() {
                guard let conversationId = Self.readText(row, "conversationId"),
                      let rowid: Int64 = row["rowid"],
                      let payload: Data = row["payload"],
                      let m = try? decoder.decode(ChatMessage.self, from: payload)
                else { continue }
                // Not the trapping `Int` subscript (#189): a store with a TEXT ordinal must skip
                // this row during the migration, not crash on every launch before `loadAll` (and
                // #189's own hardening) ever gets a chance to quarantine it.
                guard case .value(let ordinal) = Self.readInt(row, "ordinal") else { continue }
                try Self.indexMessage(m, conversationId: conversationId, ordinal: ordinal, rowid: rowid, db: db)
            }
        }
        // `quarantine.ordinal` was NOT NULL, but an unreadable ordinal (#189) has no valid ordinal
        // to record — the row is found and deleted by rowid instead, and NULL is what the
        // quarantine row honestly reports. SQLite has no ALTER to drop a NOT NULL constraint, so
        // the table is rebuilt: renamed aside, recreated with the relaxed column, data copied back.
        m.registerMigration("v5_quarantine_ordinal_nullable") { db in
            try db.execute(sql: "ALTER TABLE quarantine RENAME TO quarantine_v1")
            try db.create(table: "quarantine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .text).notNull()
                t.column("sourceTable", .text).notNull()
                t.column("ordinal", .integer)
                t.column("payload", .blob)
                t.column("reason", .text).notNull()
                t.column("quarantinedAt", .datetime).notNull()
            }
            try db.execute(sql: """
                INSERT INTO quarantine (id, conversationId, sourceTable, ordinal, payload, reason, quarantinedAt)
                SELECT id, conversationId, sourceTable, ordinal, payload, reason, quarantinedAt FROM quarantine_v1
                """)
            try db.drop(table: "quarantine_v1")
        }
        // #191: the checkpoint judgement pause's surfacing state. `lastGoalEvaluation` is the only
        // thing Accept/Reject act on and the only thing that makes the chip render a row to click,
        // so a pause restored without it is a question nobody can answer. Nullable: every row
        // written before v6 reads back NULL, which `loadAll` turns into nil — exactly the value
        // those fields had on load before this migration, so an existing store is unchanged.
        m.registerMigration("v6_pause_surfacing") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "lastGoalEvaluation", .text)
                t.add(column: "lastGoalCompletionReport", .text)
            }
        }
        // #182. A new nullable column rather than a table rebuild: NULL reads back as `false`,
        // so every existing conversation loads active, which is the desired migration. v7, not
        // v6: v6_pause_surfacing (#191) landed on main first and took that number.
        m.registerMigration("v7_archive") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "isArchived", .boolean)
            }
        }
        // #185. Nullable: NULL reads back as nil, so every existing conversation loads uncarded.
        m.registerMigration("v8_session_card") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sessionCard", .text)
            }
        }
        // #187 deliverables 1–2: jobs and their run ledger live beside the conversations they
        // produce. Both tables are created here so deliverable 2 needs no second migration; the
        // two conversation columns are nullable so NULL reads back as false for every existing row.
        m.registerMigration("v9_jobs") { db in
            try db.create(table: "jobs") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique()
                t.column("prompt", .text).notNull()
                t.column("triggerKind", .text).notNull()
                t.column("trigger", .text).notNull()
                t.column("profile", .text).notNull().defaults(to: "readOnly")
                t.column("destinationConversationId", .text)
                t.column("createdInConversationId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("nextFireAt", .datetime)
                t.column("lastRunAt", .datetime)
                t.column("pausedReason", .text)
            }
            try db.create(index: "jobs_due", on: "jobs", columns: ["enabled", "nextFireAt"])
            try db.create(table: "job_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("jobId", .text).notNull().references("jobs", onDelete: .cascade)
                t.column("jobName", .text).notNull()
                t.column("triggerKind", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("outcome", .text)
                t.column("failureReason", .text)
                t.column("blockedTool", .text)
                t.column("promptTokens", .integer).notNull().defaults(to: 0)
                t.column("candidateTokens", .integer).notNull().defaults(to: 0)
                t.column("totalTokens", .integer).notNull().defaults(to: 0)
                t.column("costMicros", .integer)
                t.column("gateSignal", .text)
                t.column("transcriptConversationId", .text)
                t.column("acknowledgedAt", .datetime)
            }
            try db.create(index: "job_runs_by_job", on: "job_runs", columns: ["jobId", "startedAt"])
            try db.create(index: "job_runs_open", on: "job_runs", columns: ["status", "acknowledgedAt"])
            try db.alter(table: "conversations") { t in
                t.add(column: "isBackground", .boolean)
                t.add(column: "isPinned", .boolean)
            }
        }
        // #187 deliverable 3: one additive migration for every column the runtime needs (spec
        // ruling 6). `jobs.policy` is JSON like `trigger` is — the policy fields are read together
        // and the set of them will grow; NULL reads back as the default policy. The `job_runs`
        // columns carry the persisted blocked call and its one-shot approval, and `jobProfile` is
        // what a background conversation's turn narrows its tool surface by. All nullable except
        // `retryAttempt`, which SQLite needs a default for to add NOT NULL in place.
        m.registerMigration("v10_job_policy") { db in
            try db.alter(table: "jobs") { t in
                t.add(column: "policy", .text)
                t.add(column: "retryAttempt", .integer).notNull().defaults(to: 0)
                t.add(column: "queuedFire", .datetime)
            }
            try db.alter(table: "job_runs") { t in
                t.add(column: "blockedCall", .text)
                t.add(column: "approvedAt", .datetime)
                t.add(column: "parentRunId", .text)
            }
            try db.alter(table: "conversations") { t in
                t.add(column: "jobProfile", .text)
            }
        }
        // #187 deliverable 4: the figures a watch fire produced (spec §6), plus a one-time rewrite
        // of each stored watch root whose canonical spelling differs from what is stored. The
        // rewrite is the load-bearing half: from here on, FSEvents paths are canonicalised and
        // matched against the root by lexical prefix, so a root stored as `/tmp/notes` when the
        // events say `/private/tmp/notes` would match nothing and the watch would go quiet without
        // saying why. A root that no longer exists is
        // left exactly as stored — there is nothing to resolve it against, and the launch check
        // pauses the job with a reason instead.
        //
        // The decision is "did the root move?", never "does the re-encoded JSON differ?" (ruling
        // R-D4-3). Every row whose root was already canonical is left byte for byte as it was,
        // including one whose stored `quietWindowSeconds` is out of range: the clamp is a rule the
        // decoder applies on read, and a data migration that quietly wrote it back would be doing
        // a second, unannounced thing. That keeps the set of rows this touches auditable — exactly
        // the ones that moved — which matters because the rewrite is a round-trip through
        // `Trigger`/`FSWatch` and so drops any key a future build had written into the blob.
        m.registerMigration("v11_watches") { db in
            try db.alter(table: "job_runs") { t in
                t.add(column: "watchSummary", .text)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, trigger FROM jobs WHERE triggerKind = ?",
                                        arguments: [Trigger.fsEventKind])
            for row in rows {
                guard let id = String.fromDatabaseValue(row["id"]),
                      let json: String = String.fromDatabaseValue(row["trigger"]),
                      case .fsEvent(var watch)? = try? JSONDecoder()
                        .decode(Trigger.self, from: Data(json.utf8)),
                      let canonical = WatchRoot.canonical(watch.path),
                      canonical != watch.path
                else { continue }
                watch.path = canonical
                guard let rewritten = try? JobLedger.encodeJSON(Trigger.fsEvent(watch)) else { continue }
                try db.execute(sql: "UPDATE jobs SET trigger = ? WHERE id = ?",
                               arguments: [rewritten, id])
            }
        }
        // #282: the grant of the job whose run a background conversation holds. One JSON column,
        // NULL for every conversation that is not a granted run; an unreadable blob reads as nil,
        // which is "no grant" — the narrow direction — and never costs the row.
        m.registerMigration("v12_sandbox_grant") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sandboxGrant", .text)
            }
        }
        return m
    }

    // MARK: Search index (#177)

    /// The roles whose text is worth searching: what the user and Iris actually said. `system`
    /// (tool-call pills, launch notices) and `command` (deterministic slash output) are harness
    /// chatter that would drown the record of the conversation.
    private static let indexedRoles: Set<ChatRole> = [.user, .agent]

    /// `rowid` is the indexed row's key, explicitly set to the mirrored `messages` row's own
    /// rowid (#201) rather than left to FTS5's own auto-assignment, so the index can be found and
    /// maintained by primary-key subselect instead of a scan over the UNINDEXED
    /// `(conversationId, ordinal)` columns.
    private static func indexMessage(_ m: ChatMessage, conversationId: String, ordinal: Int, rowid: Int64, db: Database) throws {
        guard indexedRoles.contains(m.role) else { return }
        try db.execute(sql: "INSERT INTO messages_fts (rowid, conversationId, ordinal, role, content) VALUES (?, ?, ?, ?, ?)",
                       arguments: [rowid, conversationId, ordinal, m.role.rawValue, m.content])
    }

    /// Deletes index rows by a primary-key subselect against the *current* `messages` table, so
    /// this must run before the `messages` rows it targets are themselves deleted or replaced:
    /// `INSERT OR REPLACE` allocates a new rowid, and a plain `DELETE` removes the very rows the
    /// subselect needs to find their index counterparts (#201).
    private static func deleteIndex(conversationId: String, fromOrdinal: Int?, db: Database) throws {
        if let fromOrdinal {
            try db.execute(sql: """
                DELETE FROM messages_fts WHERE rowid IN (
                    SELECT rowid FROM messages WHERE conversationId = ? AND ordinal >= ?
                )
                """, arguments: [conversationId, fromOrdinal])
        } else {
            try db.execute(sql: """
                DELETE FROM messages_fts WHERE rowid IN (
                    SELECT rowid FROM messages WHERE conversationId = ?
                )
                """, arguments: [conversationId])
        }
    }

    /// Rebuilds one conversation's index rows from what is currently in `messages`. Used by the
    /// load-time quarantine repair, which renumbers the surviving rows underneath the index. A
    /// direct wipe by `conversationId` rather than `deleteIndex`'s rowid subselect: some of the
    /// stale index rows here point at `messages` rows already quarantined and deleted, so a
    /// subselect against the current table would silently leave those orphaned.
    private static func rebuildIndex(conversationId: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM messages_fts WHERE conversationId = ?", arguments: [conversationId])
        let decoder = JSONDecoder()
        for row in try Row.fetchAll(db, sql: "SELECT rowid, ordinal, payload FROM messages WHERE conversationId = ? ORDER BY ordinal",
                                    arguments: [conversationId]) {
            guard let rowid: Int64 = row["rowid"], let payload: Data = row["payload"],
                  let m = try? decoder.decode(ChatMessage.self, from: payload) else { continue }
            // Not the trapping `Int` subscript (#189).
            guard case .value(let ordinal) = readInt(row, "ordinal") else { continue }
            try indexMessage(m, conversationId: conversationId, ordinal: ordinal, rowid: rowid, db: db)
        }
    }

    /// Test support: how many index rows this conversation has.
    func indexCount(for id: UUID) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts WHERE conversationId = ?",
                             arguments: [id.uuidString]) ?? 0
        }
    }

    /// Test support: proves the #201 keying invariant directly — each index row's rowid, by
    /// ordinal — rather than only observing search behavior that would also pass under the old
    /// ordinal-scan keying. Compare against `messageRowidsByOrdinal(for:)`.
    func ftsRowidsByOrdinal(for id: UUID) throws -> [Int: Int64] {
        try writer.read { db in
            var out: [Int: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT rowid, ordinal FROM messages_fts WHERE conversationId = ?",
                                        arguments: [id.uuidString]) {
                // Not the trapping `Int` subscript (#189): a fixture testing an unreadable-ordinal
                // row can otherwise crash this test-support helper itself.
                guard case .value(let ordinal) = Self.readInt(row, "ordinal"), let rowid: Int64 = row["rowid"] else { continue }
                out[ordinal] = rowid
            }
            return out
        }
    }

    /// Test support: the `messages` table's own rowids, by ordinal — the ground truth
    /// `ftsRowidsByOrdinal(for:)` is checked against.
    func messageRowidsByOrdinal(for id: UUID) throws -> [Int: Int64] {
        try writer.read { db in
            var out: [Int: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT rowid, ordinal FROM messages WHERE conversationId = ?",
                                        arguments: [id.uuidString]) {
                // Not the trapping `Int` subscript (#189): a fixture testing an unreadable-ordinal
                // row can otherwise crash this test-support helper itself.
                guard case .value(let ordinal) = Self.readInt(row, "ordinal"), let rowid: Int64 = row["rowid"] else { continue }
                out[ordinal] = rowid
            }
            return out
        }
    }

    /// Set once the legacy blob import has run to completion, successful or empty.
    static let legacyImportDoneKey = "legacy_import_done"

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
            // Before the cascade delete: `deleteIndex` finds its rows through a subselect against
            // `messages`, so it must run while those rows still exist (#201). `messages` goes with
            // the conversation by foreign key; a virtual table cannot carry one, so the search
            // index is cleared by hand (#177).
            try Self.deleteIndex(conversationId: w.id.uuidString, fromOrdinal: nil, db: db)
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [w.id.uuidString])
            return
        }
        guard let c = w.snapshot else { return }
        let exists = try (Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)", arguments: [c.id.uuidString]) ?? 0) == 1
        if !exists || w.changes.created || w.changes.metadata {
            try Self.upsertMetadata(c, exists: exists, db: db, encoder: encoder)
        }
        if w.changes.messagesReplaced {
            // Before the delete, same reason as the conversation-deleted branch above (#201).
            try Self.deleteIndex(conversationId: c.id.uuidString, fromOrdinal: nil, db: db)
            try db.execute(sql: "DELETE FROM messages WHERE conversationId = ?", arguments: [c.id.uuidString])
            try Self.insertMessages(c, from: 0, db: db, encoder: encoder)
        } else {
            if let from = w.changes.messagesFrom { try Self.insertMessages(c, from: from, db: db, encoder: encoder) }
            for id in w.changes.updatedMessageIds {
                guard let m = c.messages.first(where: { $0.id == id }) else { continue }
                try db.execute(sql: "UPDATE messages SET payload = ? WHERE conversationId = ? AND id = ?",
                               arguments: [try Self.json(m, encoder), c.id.uuidString, id.uuidString])
                // A plain UPDATE, unlike `INSERT OR REPLACE`, never reallocates the row's rowid, so
                // the index row keyed by it is still the right one to update in place (#201) — no
                // need to read the ordinal back first or scan the UNINDEXED columns.
                try db.execute(sql: """
                    UPDATE messages_fts SET content = ? WHERE rowid = (
                        SELECT rowid FROM messages WHERE conversationId = ? AND id = ?
                    )
                    """, arguments: [m.content, c.id.uuidString, id.uuidString])
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
        // The column takes the conversation's own `updatedAt`, not the write clock. Now that
        // `markChanged` advances the field when a conversation is touched (#185 §4), a batch of
        // several dirty conversations flushed together would otherwise all land on the same
        // instant and come back from a restart ordered by flush order rather than by activity.
        let touched = c.updatedAt
        let tokenUsage = try json(c.tokenUsage, encoder)
        let contract = try c.goalContract.map { try json($0, encoder) }
        let result = try c.subagentResult.map { try json($0, encoder) }
        // NULL when empty, so the overwhelming majority of rows carry nothing rather than "[]".
        // `loadAll` reads NULL back as `[]`, so the two are indistinguishable to every caller.
        let history = c.checkpointHistory.isEmpty ? nil : try json(c.checkpointHistory, encoder)
        // NULL when absent (the overwhelming majority of rows), like `checkpointHistory` (#191).
        let evaluation = try c.lastGoalEvaluation.map { try json($0, encoder) }
        let report = try c.lastGoalCompletionReport.map { try json($0, encoder) }
        // NULL when absent, like `goalContract` a few lines above (#185).
        let card = try c.sessionCard.map { try json($0, encoder) }
        let grant = try c.sandboxGrant.map { try json($0, encoder) }
        if exists {
            try db.execute(sql: """
                UPDATE conversations SET title = ?, updatedAt = ?, workspacePath = ?, activeGoal = ?,
                    messageCountSinceReflection = ?, goalIterationCount = ?, mainAgentSandbox = ?,
                    tokenUsage = ?, goalContract = ?, subagentResult = ?, checkpointHistory = ?,
                    lastGoalEvaluation = ?, lastGoalCompletionReport = ?, isArchived = ?,
                    isBackground = ?, isPinned = ?, sessionCard = ?, jobProfile = ?, sandboxGrant = ?
                WHERE id = ?
                """, arguments: [c.title, touched, c.workspacePath, c.activeGoal, c.messageCountSinceReflection,
                                 c.goalIterationCount, c.mainAgentSandbox?.rawValue, tokenUsage, contract, result,
                                 history, evaluation, report, c.isArchived, c.isBackground, c.isPinned, card,
                                 c.jobProfile?.rawValue, grant, c.id.uuidString])
        } else {
            let position = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) FROM conversations") ?? 0) + 1
            try db.execute(sql: """
                INSERT INTO conversations (id, position, title, createdAt, updatedAt, workspacePath, activeGoal,
                    messageCountSinceReflection, goalIterationCount, mainAgentSandbox, tokenUsage, goalContract,
                    subagentResult, checkpointHistory, lastGoalEvaluation, lastGoalCompletionReport, isArchived,
                    isBackground, isPinned, sessionCard, jobProfile, sandboxGrant)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [c.id.uuidString, position, c.title, now, touched, c.workspacePath, c.activeGoal,
                                 c.messageCountSinceReflection, c.goalIterationCount, c.mainAgentSandbox?.rawValue,
                                 tokenUsage, contract, result, history, evaluation, report, c.isArchived,
                                 c.isBackground, c.isPinned, card, c.jobProfile?.rawValue, grant])
        }
    }

    private static func insertMessages(_ c: Conversation, from: Int, db: Database, encoder: JSONEncoder) throws {
        // The search index mirrors exactly what this method writes, so it is truncated from the
        // same ordinal and refilled alongside the rows (#177). `INSERT OR REPLACE` has no
        // equivalent on a virtual table, hence delete-then-insert; it also allocates a fresh
        // `messages` rowid for any ordinal it overwrites, so the truncating delete below (which
        // finds its rows through a `messages` subselect, #201) must run before this loop's
        // `INSERT OR REPLACE`s, while the old rows — and their old rowids — are still there to
        // find. The truncating delete is taken only when there is something at or past `from`:
        // even keyed by rowid, it costs a scan to build the subselect, and a plain append — the
        // hot path, once per message — has nothing there to remove. `messagesReplaced` clears the
        // index itself, before it empties `messages` out from under this check.
        //
        // Both are taken from `min(from, count)`, never `from`: the row truncation below deletes
        // everything at or past `count`, so a `from` beyond the end of the array — a coalesced
        // ChangeSet against a snapshot that shrank — would otherwise check and clear a range
        // starting past the rows it is removing, and leave orphaned index entries behind.
        let truncateFrom = min(from, c.messages.count)
        let staleRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversationId = ? AND ordinal >= ?",
                                         arguments: [c.id.uuidString, truncateFrom]) ?? 0
        if staleRows > 0 {
            try deleteIndex(conversationId: c.id.uuidString, fromOrdinal: truncateFrom, db: db)
        }
        if from < c.messages.count {
            for ordinal in from..<c.messages.count {
                let m = c.messages[ordinal]
                try db.execute(sql: "INSERT OR REPLACE INTO messages (conversationId, ordinal, id, payload) VALUES (?, ?, ?, ?)",
                               arguments: [c.id.uuidString, ordinal, m.id.uuidString, try json(m, encoder)])
                try indexMessage(m, conversationId: c.id.uuidString, ordinal: ordinal, rowid: db.lastInsertedRowID, db: db)
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

    /// `readText` with SQL NULL and undecodable bytes told apart. A missing value is ordinary
    /// (`workspacePath` is nullable); bytes that are not UTF8 are damage, and silently reading
    /// them as "absent" would load the conversation with a blanked title or a dropped goal
    /// contract and then persist that loss on the next metadata write (review finding, #163
    /// round 2). `loadAll` skips the whole conversation instead.
    private enum TextValue {
        case null
        case invalid
        case text(String)
    }

    private static func readTextValue(_ row: Row, _ column: String) -> TextValue {
        guard let data: Data = row[column] else { return .null }
        guard let s = String(data: data, encoding: .utf8) else { return .invalid }
        return .text(s)
    }

    /// The same trap as `readText`, for integer columns: GRDB's typed `Row` subscript
    /// force-tries the SQLite→Swift conversion, so `row[column] as Int` *and* `row[column] as
    /// Int?` both crash — rather than returning nil — when a `rawWrite` (or any other means) has
    /// left a non-NULL, non-numeric value in the column (#189). `.null` and `.unconvertible` are
    /// told apart because callers treat them differently: an absent `ordinal` is quarantine-worthy
    /// damage the same as a garbled one, but a NULL `messageCountSinceReflection` is just an
    /// unset counter defaulting to 0, while a *garbled* one is still worth a console warning.
    private enum IntValue {
        case null
        case unconvertible
        case value(Int)
    }

    private static func readInt(_ row: Row, _ column: String) -> IntValue {
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .null: return .null
        case .int64(let v): return .value(Int(v))
        default: return .unconvertible
        }
    }

    /// Same trap, for `isArchived` (#182): SQLite stores a `Bool` column as an integer 0/1, so
    /// this mirrors `readInt` rather than reusing GRDB's typed subscript, which force-tries the
    /// conversion and crashes the whole load on a garbled (non-NULL, non-0/1) value (#189).
    private enum BoolValue {
        case null
        case unconvertible
        case value(Bool)
    }

    private static func readBool(_ row: Row, _ column: String) -> BoolValue {
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .null: return .null
        case .int64(let v): return .value(v != 0)
        default: return .unconvertible
        }
    }

    // MARK: Read

    func loadAll() throws -> LoadResult {
        let decoder = JSONDecoder()
        var (result, candidates): (LoadResult, [QuarantineCandidate]) = try writer.read { db in
            var out = LoadResult(conversations: [], skipped: [])
            var candidates: [QuarantineCandidate] = []
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM conversations ORDER BY position")
            for row in rows {
                guard let idString = Self.readText(row, "id"), let id = UUID(uuidString: idString) else {
                    out.skipped.append(SkippedRow(conversationId: nil, table: "conversations", ordinal: nil, reason: "bad id"))
                    continue
                }
                // Read every metadata text column first: an undecodable one is damage, and loading
                // the conversation with that column silently blank would persist the loss on the
                // next metadata write.
                var unreadableColumn: String? = nil
                func text(_ column: String) -> String? {
                    switch Self.readTextValue(row, column) {
                    case .null: return nil
                    case .invalid:
                        if unreadableColumn == nil { unreadableColumn = column }
                        return nil
                    case .text(let s): return s
                    }
                }
                let title = text("title")
                let workspacePath = text("workspacePath")
                let activeGoal = text("activeGoal")
                let sandbox = text("mainAgentSandbox")
                let tokenUsage = text("tokenUsage")
                let goalContract = text("goalContract")
                // Supplementary columns lose themselves rather than the conversation (#233).
                //
                // The line is what the conversation *is* versus what happened in it. `title`,
                // `workspacePath`, `activeGoal` and `position` are identity. `mainAgentSandbox`
                // read as absent means "no preference", which would run on the host what was meant
                // to be contained. `tokenUsage` read as absent is a fresh `TokenUsage()`, which a
                // per-run budget compares against as an unspent allowance. `goalContract` is the
                // goal. Those four still take the conversation with them.
                // Collected, not appended: a loss is only reported once the conversation is known
                // to survive it. Three later paths still drop the row — the metadata decode
                // `catch` below, the bulk message/history breaker, and the repair-failure rollback
                // — and a row that reported "kept without its audit trail" and then vanished would
                // tell someone reading the log the opposite of what happened.
                var localSoftLosses: [(column: String, detail: String)] = []
                func supplementary(_ column: String) -> String? {
                    switch Self.readTextValue(row, column) {
                    case .null: return nil
                    case .invalid:
                        localSoftLosses.append((column, "invalid text encoding"))
                        return nil
                    case .text(let s): return s
                    }
                }
                let subagentResult = supplementary("subagentResult")
                let sandboxGrant = supplementary("sandboxGrant")
                let checkpointHistory = supplementary("checkpointHistory")
                let lastGoalEvaluation = supplementary("lastGoalEvaluation")
                let lastGoalCompletionReport = supplementary("lastGoalCompletionReport")
                // `position` only orders the `SELECT` above and is never decoded into `Conversation`,
                // but an unconvertible value is exactly the same class of damage as an unreadable
                // text column, so it is checked the same way (#189).
                switch Self.readInt(row, "position") {
                case .null, .unconvertible:
                    if unreadableColumn == nil { unreadableColumn = "position" }
                case .value: break
                }
                if let column = unreadableColumn {
                    out.skipped.append(SkippedRow(conversationId: id, table: "conversations", ordinal: nil, reason: "unreadable \(column)"))
                    continue
                }

                var c: Conversation
                do {
                    c = Conversation(id: id, title: title ?? "Untitled", workspacePath: workspacePath)
                    c.activeGoal = activeGoal
                    // Losing a whole conversation over a counter is disproportionate: NULL already
                    // means 0 here, and a garbled value gets the same default plus a console
                    // warning rather than quarantining the conversation (#189).
                    func counter(_ column: String) -> Int {
                        switch Self.readInt(row, column) {
                        case .null: return 0
                        case .value(let v): return v
                        case .unconvertible:
                            print("WARNING: unreadable \(column) for conversation \(id); defaulting to 0")
                            return 0
                        }
                    }
                    c.messageCountSinceReflection = counter("messageCountSinceReflection")
                    c.goalIterationCount = counter("goalIterationCount")
                    c.mainAgentSandbox = sandbox.flatMap(SandboxPref.init(rawValue:))
                    c.tokenUsage = try tokenUsage.map { try decoder.decode(TokenUsage.self, from: Data($0.utf8)) } ?? TokenUsage()
                    if let s = goalContract { c.goalContract = try decoder.decode(GoalContract.self, from: Data(s.utf8)) }
                } catch {
                    // Whole-conversation skip: nothing in memory represents this conversation, so
                    // nothing can ever write to it again. No quarantine/renumber needed.
                    out.skipped.append(SkippedRow(conversationId: id, table: "conversations", ordinal: nil, reason: "\(error)"))
                    continue
                }

                // NULL (a row written before v3) leaves the property at its `[]` default. Unlike
                // goalContract/tokenUsage above, a corrupt checkpointHistory is not fatal to the
                // conversation: it's slice D3's supplementary audit trail of past checkpoint
                // resolutions, not the goal itself. Degrade to `[]` and record the loss rather
                // than dropping every message, contract, and workspace the row also carries.
                // #233 round 2: this decode used to sit in the fatal `do` above, so the column was
                // soft on bad bytes and fatal on bad JSON — the asymmetry #233 exists to remove,
                // with the two halves swapped. Bad JSON is the likelier corruption of the two, and
                // the argument for the column being supplementary does not change with which byte
                // went wrong: it records a run that already finished, and the parent reads its
                // result from `SubagentManager`'s return value rather than from here.
                if let s = subagentResult {
                    do { c.subagentResult = try decoder.decode(SubagentResult.self, from: Data(s.utf8)) }
                    catch { localSoftLosses.append(("subagentResult", "\(error)")) }
                }

                // #282 — supplementary like `subagentResult`: a grant this build cannot read is no
                // grant, which is the narrow answer, and the conversation is kept.
                if let s = sandboxGrant {
                    do { c.sandboxGrant = try decoder.decode(JobGrant.self, from: Data(s.utf8)) }
                    catch { localSoftLosses.append(("sandboxGrant", "\(error)")) }
                }

                if let s = checkpointHistory {
                    do { c.checkpointHistory = try decoder.decode([CheckpointOutcome].self, from: Data(s.utf8)) }
                    catch { localSoftLosses.append(("checkpointHistory", "\(error)")) }
                }

                // #191: the pause's surfacing state follows the `checkpointHistory` policy, not the
                // `goalContract` one — a snapshot that will not parse means one empty chip, not a
                // lost conversation (spec §4). The `SkippedRow` reaches the launch notice.
                if let s = lastGoalEvaluation {
                    do { c.lastGoalEvaluation = try decoder.decode(GoalEvaluation.self, from: Data(s.utf8)) }
                    catch { localSoftLosses.append(("lastGoalEvaluation", "\(error)")) }
                }
                if let s = lastGoalCompletionReport {
                    do { c.lastGoalCompletionReport = try decoder.decode(JSONValue.self, from: Data(s.utf8)) }
                    catch { localSoftLosses.append(("lastGoalCompletionReport", "\(error)")) }
                }

                // A garbled flag must not cost the user a conversation: default to active and
                // warn, matching the counter policy above rather than `position`'s quarantine
                // (#189). The failure direction is toward visibility. Read through `readBool`,
                // not GRDB's typed subscript, which force-tries the conversion and crashes the
                // whole load on a non-NULL, non-0/1 value instead of defaulting.
                switch Self.readBool(row, "isArchived") {
                case .null: c.isArchived = false
                case .value(let v): c.isArchived = v
                case .unconvertible:
                    print("WARNING: unreadable isArchived for conversation \(id); defaulting to active")
                    c.isArchived = false
                }

                // #187 — same policy as `isArchived` above: a garbled flag degrades to false
                // (visible, foreground, unpinned) with a warning rather than costing the row.
                switch Self.readBool(row, "isBackground") {
                case .null: c.isBackground = false
                case .value(let v): c.isBackground = v
                case .unconvertible:
                    print("WARNING: unreadable isBackground for conversation \(id); defaulting to foreground")
                    c.isBackground = false
                }
                switch Self.readBool(row, "isPinned") {
                case .null: c.isPinned = false
                case .value(let v): c.isPinned = v
                case .unconvertible:
                    print("WARNING: unreadable isPinned for conversation \(id); defaulting to unpinned")
                    c.isPinned = false
                }

                // #187 deliverable 3 — degrades like the flags above rather than costing the
                // conversation, but NOT to nil: nil means "not a job run", which is the unnarrowed
                // tool surface, so a profile this build cannot read would fail *open* and the next
                // metadata write would make that permanent. A stamped-but-unrecognized value
                // therefore reads as `.readOnly`, the narrowest profile. Only SQL NULL is nil.
                let profileValue: DatabaseValue? = row["jobProfile"]
                if let profileValue, !profileValue.isNull {
                    if let parsed = String.fromDatabaseValue(profileValue).flatMap(JobProfile.init(rawValue:)) {
                        c.jobProfile = parsed
                    } else {
                        print("WARNING: unreadable jobProfile for conversation \(id); narrowing to readOnly")
                        c.jobProfile = .readOnly
                    }
                }

                // #185 -- surfaced, not just written: `updatedAt` has been a store column since v1
                // but nothing decoded it back into `Conversation` until now. `Date`'s own
                // `fromDatabaseValue` (unlike the trapping typed row subscript, #189) returns nil
                // rather than crashing on a garbled value, so a damaged timestamp defaults instead
                // of costing the conversation.
                let updatedAtValue: DatabaseValue = row["updatedAt"]
                c.updatedAt = Date.fromDatabaseValue(updatedAtValue) ?? Date()

                // An unreadable identity must not cost the user a conversation (#185 §6.1). Same
                // policy as `checkpointHistory`, opposite of `goalContract`: read directly through
                // `readTextValue` rather than the `text()` closure above, whose `.invalid` case is
                // fatal to the whole row -- here even non-UTF8 bytes degrade to "uncarded" plus a
                // reported loss, never a dropped conversation.
                switch Self.readTextValue(row, "sessionCard") {
                case .null:
                    break
                case .invalid:
                    localSoftLosses.append(("sessionCard", "invalid text encoding"))
                case .text(let s):
                    do { c.sessionCard = try decoder.decode(SessionCard.self, from: Data(s.utf8)) }
                    catch { localSoftLosses.append(("sessionCard", "\(error)")) }
                }

                // Per-conversation, so the bulk breaker below can throw the lot away.
                var localSkipped: [SkippedRow] = []
                var localCandidates: [QuarantineCandidate] = []
                var totals: [String: Int] = ["messages": 0, "history": 0]
                var failures: [String: Int] = ["messages": 0, "history": 0]

                // `rowid` is selected alongside `ordinal`/`payload` so a row whose ordinal is
                // itself unreadable can still be found and removed in the repair transaction
                // below — its primary key, `(conversationId, ordinal)`, is exactly the column
                // that's damaged (#189).
                for r in try Row.fetchAll(db, sql: "SELECT rowid, ordinal, payload FROM messages WHERE conversationId = ? ORDER BY ordinal", arguments: [idString]) {
                    let rowid: Int64? = r["rowid"]
                    let raw: Data? = r["payload"]
                    totals["messages", default: 0] += 1
                    switch Self.readInt(r, "ordinal") {
                    case .null, .unconvertible:
                        failures["messages", default: 0] += 1
                        localSkipped.append(SkippedRow(conversationId: id, table: "messages", ordinal: nil, reason: "unreadable ordinal"))
                        localCandidates.append(QuarantineCandidate(conversationId: id, table: "messages", ordinal: nil, rowid: rowid, payload: raw, reason: "unreadable ordinal"))
                    case .value(let ordinal):
                        guard let raw else {
                            failures["messages", default: 0] += 1
                            localSkipped.append(SkippedRow(conversationId: id, table: "messages", ordinal: ordinal, reason: "unreadable payload"))
                            localCandidates.append(QuarantineCandidate(conversationId: id, table: "messages", ordinal: ordinal, rowid: rowid, payload: nil, reason: "unreadable payload"))
                            continue
                        }
                        do { c.messages.append(try decoder.decode(ChatMessage.self, from: raw)) }
                        catch {
                            failures["messages", default: 0] += 1
                            localSkipped.append(SkippedRow(conversationId: id, table: "messages", ordinal: ordinal, reason: "\(error)"))
                            localCandidates.append(QuarantineCandidate(conversationId: id, table: "messages", ordinal: ordinal, rowid: rowid, payload: raw, reason: "\(error)"))
                        }
                    }
                }
                for r in try Row.fetchAll(db, sql: "SELECT rowid, ordinal, payload FROM history WHERE conversationId = ? ORDER BY ordinal", arguments: [idString]) {
                    let rowid: Int64? = r["rowid"]
                    let raw: Data? = r["payload"]
                    totals["history", default: 0] += 1
                    switch Self.readInt(r, "ordinal") {
                    case .null, .unconvertible:
                        failures["history", default: 0] += 1
                        localSkipped.append(SkippedRow(conversationId: id, table: "history", ordinal: nil, reason: "unreadable ordinal"))
                        localCandidates.append(QuarantineCandidate(conversationId: id, table: "history", ordinal: nil, rowid: rowid, payload: raw, reason: "unreadable ordinal"))
                    case .value(let ordinal):
                        guard let raw else {
                            failures["history", default: 0] += 1
                            localSkipped.append(SkippedRow(conversationId: id, table: "history", ordinal: ordinal, reason: "unreadable payload"))
                            localCandidates.append(QuarantineCandidate(conversationId: id, table: "history", ordinal: ordinal, rowid: rowid, payload: nil, reason: "unreadable payload"))
                            continue
                        }
                        do { c.history.append(try decoder.decode(Content.self, from: raw)) }
                        catch {
                            failures["history", default: 0] += 1
                            localSkipped.append(SkippedRow(conversationId: id, table: "history", ordinal: ordinal, reason: "\(error)"))
                            localCandidates.append(QuarantineCandidate(conversationId: id, table: "history", ordinal: ordinal, rowid: rowid, payload: raw, reason: "\(error)"))
                        }
                    }
                }

                // Bulk breaker (review finding, #163 round 2): one bad row among good ones is a
                // damaged row and gets quarantined so the good ones stay usable. An entire table
                // failing is a different animal — a schema or decoder regression, not rot — and
                // emptying it into `quarantine` would turn a fixable bug into real data loss. Leave
                // every row exactly where it is, report it once, and drop the conversation from
                // this load so nothing in memory can overwrite it.
                let bulkFailed = ["messages", "history"].filter { (totals[$0] ?? 0) > 0 && failures[$0] == totals[$0] }
                if !bulkFailed.isEmpty {
                    for table in bulkFailed {
                        out.skipped.append(SkippedRow(conversationId: id, table: table, ordinal: nil,
                                                      reason: "all \(totals[table] ?? 0) rows unreadable; left in place"))
                    }
                    // The other table's individual bad rows are still worth reporting — they are
                    // real damage and the console log is the only place they surface. They are not
                    // quarantined: this conversation is excluded from the load, so nothing may be
                    // rewritten under it.
                    out.skipped.append(contentsOf: localSkipped.filter { !bulkFailed.contains($0.table) })
                    continue
                }

                out.skipped.append(contentsOf: localSkipped)
                // The one point the conversation is genuinely known to survive.
                for loss in localSoftLosses {
                    out.skipped.append(SkippedRow(conversationId: id, table: "conversations", ordinal: nil,
                                                  reason: "unreadable \(loss.column): \(loss.detail)", kept: true))
                }
                candidates.append(contentsOf: localCandidates)
                out.conversations.append(c)
            }
            return (out, candidates)
        }

        guard !candidates.isEmpty else { return result }
        let candidateConversationIds = Set(candidates.map(\.conversationId))

        // Repair inside one write transaction, only when there is something to repair: quarantine
        // the bad rows, then renumber what's left so ordinals stay contiguous 0..<n. Left as-is,
        // the in-memory array above (already compacted by the skips) and the on-disk ordinals
        // disagree — the next append uses the compacted in-memory index as the ordinal, so it
        // `INSERT OR REPLACE`s the wrong row while the trailing-row `DELETE` drops a good one
        // (review finding, #163 round 1).
        //
        // A thrown error here rolls the whole transaction back — every group's quarantine and
        // renumber together, not just the one that failed — so on failure every conversation that
        // had a candidate is excluded and reported via `repairFailed` (#189); a conversation with
        // nothing to repair was never touched by this transaction and is returned as-is.
        do {
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
                    if self.failInjection?(first.conversationId) == true {
                        throw InjectedWriteFailure()
                    }
                    for candidate in group {
                        try db.execute(sql: """
                            INSERT INTO quarantine (conversationId, sourceTable, ordinal, payload, reason, quarantinedAt)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """, arguments: [convIdString, table, candidate.ordinal, candidate.payload, candidate.reason, now])
                        // A normal candidate is found by its (conversationId, ordinal) primary key;
                        // one whose ordinal is itself unreadable (#189) has no usable ordinal to
                        // match on, so it is found and removed by rowid instead.
                        if let ordinal = candidate.ordinal {
                            try db.execute(sql: "DELETE FROM \(table) WHERE conversationId = ? AND ordinal = ?",
                                           arguments: [convIdString, ordinal])
                        } else if let rowid = candidate.rowid {
                            try db.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [rowid])
                        }
                    }
                    // Renumber the survivors to a contiguous 0..<n, preserving relative order.
                    // Shifting by a large, out-of-range offset first avoids colliding with the
                    // (conversationId, ordinal) primary key while rows are retargeted one at a time.
                    try db.execute(sql: "UPDATE \(table) SET ordinal = ordinal + 1000000 WHERE conversationId = ?", arguments: [convIdString])
                    let survivors = try Row.fetchAll(db, sql: "SELECT ordinal FROM \(table) WHERE conversationId = ? ORDER BY ordinal ASC", arguments: [convIdString])
                    for (index, row) in survivors.enumerated() {
                        let shifted: Int = row["ordinal"]
                        try db.execute(sql: "UPDATE \(table) SET ordinal = ? WHERE conversationId = ? AND ordinal = ?", arguments: [index, convIdString, shifted])
                    }
                    // The index row itself is now correctly keyed (rowid is untouched by the plain
                    // UPDATEs above, #201), but it still carries the pre-renumber `ordinal` as a
                    // display column, and some index rows point at messages just quarantined and
                    // deleted. Rebuild from the survivors so both are right (#177).
                    if table == "messages" {
                        try Self.rebuildIndex(conversationId: convIdString, db: db)
                    }
                }
            }
        } catch {
            result.conversations.removeAll { candidateConversationIds.contains($0.id) }
            result.repairFailed = candidateConversationIds.sorted { $0.uuidString < $1.uuidString }
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

    /// Test support: the `(sourceTable, ordinal, reason)` of every quarantined row for this
    /// conversation. `ordinal` is nil for #189's "unreadable ordinal" case — proves the
    /// `v5_quarantine_ordinal_nullable` migration actually relaxed the column, since a still-NOT
    /// NULL column would have failed the `INSERT` that put the row here in the first place.
    func quarantinedRows(for id: UUID) throws -> [(table: String, ordinal: Int?, reason: String)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT sourceTable, ordinal, reason FROM quarantine WHERE conversationId = ?",
                             arguments: [id.uuidString]).map {
                (table: Self.readText($0, "sourceTable") ?? "", ordinal: $0["ordinal"], reason: Self.readText($0, "reason") ?? "")
            }
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

    /// Full-text search across every persisted conversation's user and agent messages. Ranked by
    /// bm25 (best match first), ties broken by the conversation's `updatedAt` so the more recent
    /// chat wins. An empty or all-punctuation query matches nothing: the fact store answers a
    /// blank query with "the most recent facts", but there is no equivalent here — "the most
    /// recent messages" are the ones already in context.
    func searchConversations(query: String, limit: Int = 10) throws -> [ConversationHit] {
        let sanitized = Self.sanitizeFTSQuery(query.trimmingCharacters(in: .whitespacesAndNewlines))
        // FTS5Pattern, not FTS3Pattern: the pattern is tokenized by the same unicode61 tokenizer
        // that built the index, so a query for "Café" finds the row indexed as "cafe". The FTS3
        // tokenizer folds ASCII case only and keeps diacritics, which silently missed those rows.
        guard !sanitized.trimmingCharacters(in: .whitespaces).isEmpty,
              let pattern = FTS5Pattern(matchingAnyTokenIn: sanitized) else { return [] }
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT messages_fts.conversationId AS cid, messages_fts.ordinal AS ord,
                       messages_fts.role AS role, conversations.title AS title,
                       snippet(messages_fts, 3, '', '', '\u{2026}', 12) AS snippet
                FROM messages_fts
                JOIN conversations ON conversations.id = messages_fts.conversationId
                WHERE messages_fts MATCH ?
                ORDER BY bm25(messages_fts), conversations.updatedAt DESC
                LIMIT ?
                """, arguments: [pattern, limit])
            return rows.compactMap { row in
                guard let idString = Self.readText(row, "cid"), let id = UUID(uuidString: idString),
                      let ordinal: Int = row["ord"],
                      let role = Self.readText(row, "role").flatMap(ChatRole.init(rawValue:))
                else { return nil }
                return ConversationHit(conversationId: id,
                                       title: Self.readText(row, "title") ?? "Untitled",
                                       role: role,
                                       ordinal: ordinal,
                                       snippet: Self.readText(row, "snippet") ?? "")
            }
        }
    }

    /// Same rule as the fact store's: strip everything that is not alphanumeric or whitespace, so
    /// no user text can be read as FTS5 query syntax.
    private static func sanitizeFTSQuery(_ query: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        return String(String.UnicodeScalarView(query.unicodeScalars.filter { allowed.contains($0) }))
    }

    /// Tests corrupt rows through this; nothing in the app calls it.
    func rawWrite(_ sql: String, arguments: StatementArguments = []) throws {
        try writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    /// Tests read a single scalar (e.g. `typeof(column)`) through this; nothing in the app calls it.
    func rawScalar(_ sql: String, arguments: StatementArguments = []) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: sql, arguments: arguments) }
    }
}

extension ConversationStore {
    /// First-launch import (spec §6). Returns nil and writes nothing when the `meta` marker says
    /// an import already ran; otherwise imports everything, sets the marker, and returns how many
    /// conversations were actually written. Both the check and the marker live in the same write
    /// transaction as the rows, so a crash between the commit and the key move cannot
    /// double-import.
    ///
    /// The gate is the marker, deliberately not "the store has rows": after an `.importFailed`
    /// launch the app goes on to create its default conversation, so a row-count gate declared the
    /// import already done on the next launch and `migrateIfNeeded` parked the blob unimported —
    /// silent data loss (review finding, #163 round 2). Importing behind conversations that
    /// already exist is fine: positions continue from `MAX(position) + 1`, so the imported ones
    /// simply land after them.
    func importLegacy(_ conversations: [Conversation]) throws -> Int? {
        try writer.write { db in
            let done = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meta WHERE key = ?",
                                        arguments: [Self.legacyImportDoneKey]) ?? 0
            if done > 0 { return nil }
            if self.failInjection?(UUID()) == true { throw InjectedWriteFailure() }
            let encoder = JSONEncoder()
            var collided = 0
            for c in conversations {
                let exists = try (Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)",
                                               arguments: [c.id.uuidString]) ?? 0) == 1
                // An id the store already holds is the live copy; the blob's is the older one.
                if exists { collided += 1; continue }
                try Self.upsertMetadata(c, exists: false, db: db, encoder: encoder)
                try Self.insertMessages(c, from: 0, db: db, encoder: encoder)
                try Self.insertHistory(c, from: 0, db: db, encoder: encoder)
            }
            if collided > 0 {
                print("Legacy import skipped \(collided) conversation(s) already present in the store.")
            }
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
                           arguments: [Self.legacyImportDoneKey, ISO8601DateFormatter().string(from: Date())])
            return conversations.count - collided
        }
    }

    /// Generic `meta` get by key — nil when the key has never been set. #187's
    /// `activity_conversation_id` is the first caller; `legacyImportDoneKey` predates it and keeps
    /// its own inline SQL because it is read and written inside the import transaction.
    func metaValue(forKey key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    /// Generic `meta` set by key, overwriting any previous value.
    func setMetaValue(_ value: String, forKey key: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        }
    }

    /// Test support: whether the legacy-import marker has been set.
    func legacyImportMarked() throws -> Bool {
        try writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meta WHERE key = ?",
                              arguments: [Self.legacyImportDoneKey]) ?? 0) > 0
        }
    }
}

extension ConversationStore {
    /// Spec §1: on disk only in a normal app process. The test bundle links XCTest (the same
    /// signal `IrisDefaults` uses); headless runs set `HeadlessMode`; a fake-lane perf run has
    /// volatile defaults but the real `IrisPaths`, and must not open the user's database.
    /// The §1 rule as a pure function, so it can be tested as a truth table rather than only
    /// through whichever process the suite happens to run in.
    static func shouldIsolate(xctestLinked: Bool, headless: Bool, volatileDefaults: Bool) -> Bool {
        xctestLinked || headless || volatileDefaults
    }

    static func makeDefault() -> ConversationStore {
        let isolated = shouldIsolate(xctestLinked: NSClassFromString("XCTestCase") != nil,
                                     headless: HeadlessMode.isEnabled,
                                     volatileDefaults: IrisDefaults.isVolatileCopy)
        if !isolated {
            do { return try onDisk(at: IrisPaths.default.conversationsDB) }
            catch { print("WARNING: conversation store failed to open on disk, using memory only: \(error)") }
        }
        return try! inMemory()
    }
}
