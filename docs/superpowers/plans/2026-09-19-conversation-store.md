# Conversation Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single UserDefaults JSON blob with a per-conversation SQLite store so a mutation costs work proportional to what changed, encoding happens off the main actor, one bad row cannot drop every conversation, and existing users migrate once automatically.

**Architecture:** A `ConversationStore` (GRDB, WAL) holds a `conversations` metadata row plus `messages` and `history` tables with one JSON row per entry. `AppState` keeps its in-memory `[Conversation]`; its 37 mutation sites record a typed `ConversationChange` instead of re-encoding the array, and the existing debounce/max-wait fires a `flush` that snapshots only dirty conversations and writes them off the main actor, one transaction each, idempotently. Load reads rows back per conversation and skips undecodable rows. A one-time import moves the legacy blob to a legacy key.

**Tech Stack:** Swift 6 / SwiftPM, strict concurrency, GRDB (already a dependency; `FactStoreManager.swift` is the in-repo example), Swift Testing.

**Spec:** `docs/specs/2026-09-19-conversation-store-design.md`

## Global Constraints

- Swift 6 strict concurrency; every value handed to a detached task is `Sendable` (`Conversation`, `TokenUsage`, `ChatRole` gain the conformance in Task 1).
- Tests use Swift Testing only; never mutate `ConfigManager.shared`; the test process must never open the user's real `~/.iris/conversations.sqlite` (store selection rule, §1 of the spec: in-memory when XCTest is linked, when `HeadlessMode.isEnabled`, or when `IrisDefaults.isVolatileCopy`).
- Row payloads are the existing Codable encodings of `ChatMessage` and `Content`; no new `Codable` shape, so AGENTS.md invariant 1 keeps applying per row.
- Debounce and max-wait constants and semantics are unchanged: `AppState.saveDebounce = 0.5`, `AppState.saveMaxWait = 2.0`; `flushSave()` is synchronous and is what `applicationWillTerminate` calls before `_exit(0)`.
- Writes are keyed by `(conversationId, ordinal)` and `(conversationId, id)` so replaying a batch is idempotent; a failed batch is merged back into the pending set, never dropped.
- Exactly one asynchronous write batch is in flight at a time; `flushSave()` replays the in-flight batch plus the pending set synchronously.
- The legacy defaults key `iris_conversations` is read only by the migration; after a successful import it is moved to `iris_conversations_legacy` and never read again. `IrisDefaults.perfSeed` keeps excluding both.
- Existing test files are extended with the Edit tool, never overwritten; commits are conventional and end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## File Structure

| file | responsibility |
|---|---|
| `Sources/iris/ConversationStore.swift` (new) | schema + migrator, `ConversationChange`, `ChangeSet`, `ConversationWrite`, `SkippedRow`, `LoadResult`, `ConversationStore` (`apply`, `loadAll`, `counts`, `isEmpty`, `importLegacy`), `makeDefault()` selection rule |
| `Sources/iris/LegacyConversationBlob.swift` (new) | one-time import from the defaults key; key move |
| `Sources/iris/IrisPaths.swift` | `conversationsDB` |
| `Sources/iris/AppState.swift` | `Sendable` on `Conversation`/`TokenUsage`/`ChatRole`; `store`; `markChanged` + pending/in-flight bookkeeping replacing `saveConversations`; `flush`/`flushSave`; load through the store; migration call; skipped-rows notice |
| `AGENTS.md` | invariant 1 wording |
| `Tests/irisTests/ConversationStoreTests.swift`, `LegacyConversationBlobTests.swift`, `ConversationStoreSelectionTests.swift` (new); `SavePersistenceTests.swift`, `DefaultsIsolationTests.swift` (re-pointed) | |

Conventions: `Conversation(id:title:messages:workspacePath:history:tokenUsage:activeGoal:messageCountSinceReflection:goalContract:)`; `ChatMessage(id:role:content:attachments:)`; `Content(role:parts:)`; `Part(text:)`; `GoalContract(objective:criteria:)` with `lock()`; `Criterion(text:kind:check:)`.

---

### Task 1: `ConversationStore` — schema, change model, apply, load

**Files:**
- Create: `Sources/iris/ConversationStore.swift`
- Modify: `Sources/iris/IrisPaths.swift` (add `conversationsDB`), `Sources/iris/AppState.swift:4-11,38-43,44` (`Sendable` on `ChatRole`, `TokenUsage`, `Conversation`)
- Test: `Tests/irisTests/ConversationStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum ConversationChange: Sendable, Equatable { case created, metadata, messagesAppended(from: Int), messageUpdated(id: UUID), messagesReplaced, historyAppended(from: Int), historyReplaced, deleted }`
  - `struct ChangeSet: Sendable, Equatable { created, deleted, metadata, messagesReplaced, historyReplaced: Bool; messagesFrom, historyFrom: Int?; updatedMessageIds: Set<UUID>; mutating func add(_:); mutating func merge(_:); var isEmpty: Bool }`
  - `struct ConversationWrite: Sendable { let id: UUID; let snapshot: Conversation?; let changes: ChangeSet }`
  - `struct SkippedRow: Sendable, Equatable { let conversationId: UUID?; let table: String; let ordinal: Int?; let reason: String }`
  - `struct LoadResult: Sendable { var conversations: [Conversation]; var skipped: [SkippedRow] }`
  - `final class ConversationStore: Sendable` with `static func inMemory() throws -> ConversationStore`, `static func onDisk(at url: URL) throws -> ConversationStore`, `func apply(_ batch: [ConversationWrite]) throws`, `func loadAll() throws -> LoadResult`, `func counts(for id: UUID) throws -> (messages: Int, history: Int)`, `func isEmpty() throws -> Bool`, `func rawWrite(_ sql: String, arguments: StatementArguments) throws` (tests corrupt rows through it)
  - `IrisPaths.conversationsDB: URL` = `root.appendingPathComponent("conversations.sqlite")`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import GRDB
@testable import iris

@Suite("Conversation store")
struct ConversationStoreTests {
    private func sample(id: UUID = UUID(), title: String = "t") -> Conversation {
        var c = Conversation(id: id, title: title, workspacePath: "/tmp/w")
        c.messages = [ChatMessage(role: .user, content: "hi", attachments: [
            FileAttachment(id: UUID(), filename: "a.txt", fileURL: URL(fileURLWithPath: "/tmp/a.txt"), mimeType: "text/plain", fileSize: 3, category: .text)
        ]), ChatMessage(role: .agent, content: "hello")]
        c.history = [Content(role: "user", parts: [Part(text: "hi")]), Content(role: "model", parts: [Part(text: "hello")])]
        c.tokenUsage = TokenUsage(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 7)
        c.mainAgentSandbox = .sandboxed
        var contract = GoalContract(objective: "ship", criteria: [Criterion(text: "tests pass", kind: .executable, check: "swift test")])
        contract.lock()
        c.goalContract = contract
        c.activeGoal = "ship"
        c.goalIterationCount = 2
        c.messageCountSinceReflection = 5
        return c
    }
    private func created(_ c: Conversation) -> ConversationWrite {
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0)); s.add(.historyAppended(from: 0))
        return ConversationWrite(id: c.id, snapshot: c, changes: s)
    }
    private func write(_ c: Conversation, _ changes: ConversationChange...) -> ConversationWrite {
        var s = ChangeSet(); changes.forEach { s.add($0) }
        return ConversationWrite(id: c.id, snapshot: c, changes: s)
    }

    @Test("ChangeSet coalesces: smallest append ordinal wins, replaced absorbs appended, ids accumulate")
    func changeSetCoalescing() {
        var s = ChangeSet()
        #expect(s.isEmpty)
        s.add(.messagesAppended(from: 7)); s.add(.messagesAppended(from: 3)); s.add(.messageUpdated(id: UUID()))
        s.add(.historyAppended(from: 2)); s.add(.historyReplaced); s.add(.metadata)
        #expect(s.messagesFrom == 3)
        #expect(s.updatedMessageIds.count == 1)
        #expect(s.historyReplaced && s.historyFrom == nil)
        #expect(s.metadata)
        var other = ChangeSet(); other.add(.messagesAppended(from: 1)); other.add(.deleted)
        s.merge(other)
        #expect(s.messagesFrom == 1 && s.deleted)
    }

    @Test("a conversation round-trips through the store with every stored field")
    func roundTrip() throws {
        let store = try ConversationStore.inMemory()
        let c = sample()
        try store.apply([created(c)])
        let loaded = try store.loadAll()
        #expect(loaded.skipped.isEmpty)
        let back = try #require(loaded.conversations.first)
        #expect(back.id == c.id && back.title == "t" && back.workspacePath == "/tmp/w")
        #expect(back.messages == c.messages)
        #expect(back.history.map(\.parts.first?.text) == ["hi", "hello"])
        #expect(back.tokenUsage == c.tokenUsage)
        #expect(back.mainAgentSandbox == .sandboxed)
        #expect(back.goalContract?.isLocked == true && back.goalContract?.criteria.count == 1)
        #expect(back.activeGoal == "ship" && back.goalIterationCount == 2 && back.messageCountSinceReflection == 5)
        #expect(back.isSubagent == false && back.lastGoalEvaluation == nil && back.lastGoalCompletionReport == nil)
    }

    @Test("appending writes only the new rows")
    func appendIsIncremental() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        try store.apply([created(c)])
        c.messages.append(ChatMessage(role: .agent, content: "third"))
        c.history.append(Content(role: "model", parts: [Part(text: "third")]))
        try store.apply([write(c, .messagesAppended(from: 2), .historyAppended(from: 2))])
        let counts = try store.counts(for: c.id)
        #expect(counts.messages == 3 && counts.history == 3)
        #expect(try store.loadAll().conversations.first?.messages.last?.content == "third")
        // Replaying the same batch changes nothing (idempotent by ordinal).
        try store.apply([write(c, .messagesAppended(from: 2), .historyAppended(from: 2))])
        #expect(try store.counts(for: c.id).messages == 3)
    }

    @Test("a message is updated in place by id; history can be replaced wholesale; messages can be cleared")
    func updateReplaceClear() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        try store.apply([created(c)])
        c.messages[1].content = "hello, edited"
        try store.apply([write(c, .messageUpdated(id: c.messages[1].id))])
        #expect(try store.loadAll().conversations.first?.messages[1].content == "hello, edited")
        c.history = [Content(role: "user", parts: [Part(text: "only")])]
        try store.apply([write(c, .historyReplaced)])
        #expect(try store.counts(for: c.id).history == 1)
        c.messages.removeAll()
        try store.apply([write(c, .messagesReplaced)])
        #expect(try store.counts(for: c.id).messages == 0)
        #expect(try store.loadAll().conversations.first?.history.first?.parts.first?.text == "only")
    }

    @Test("metadata-only writes update the row without touching message rows")
    func metadataOnly() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        try store.apply([created(c)])
        c.title = "renamed"; c.tokenUsage.totalTokenCount = 99
        c.messages.append(ChatMessage(role: .agent, content: "not written"))   // deliberately not marked
        try store.apply([write(c, .metadata)])
        let back = try store.loadAll().conversations.first
        #expect(back?.title == "renamed" && back?.tokenUsage.totalTokenCount == 99)
        #expect(back?.messages.count == 2)
    }

    @Test("delete cascades to message and history rows; created-then-deleted leaves nothing")
    func deleteCascades() throws {
        let store = try ConversationStore.inMemory()
        let c = sample()
        try store.apply([created(c)])
        try store.apply([ConversationWrite(id: c.id, snapshot: nil, changes: { var s = ChangeSet(); s.add(.deleted); return s }())])
        #expect(try store.counts(for: c.id) == (0, 0))
        #expect(try store.isEmpty())
        let d = sample()
        try store.apply([ConversationWrite(id: d.id, snapshot: d, changes: { var s = ChangeSet(); s.add(.created); s.add(.deleted); return s }())])
        #expect(try store.isEmpty())
    }

    @Test("positions preserve creation order across loads")
    func ordering() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b"), c = sample(title: "c")
        try store.apply([created(a), created(b), created(c)])
        try store.apply([ConversationWrite(id: b.id, snapshot: nil, changes: { var s = ChangeSet(); s.add(.deleted); return s }())])
        let d = sample(title: "d")
        try store.apply([created(d)])
        #expect(try store.loadAll().conversations.map(\.title) == ["a", "c", "d"])
    }

    @Test("a corrupted message row is skipped and reported; the conversation and its neighbours still load")
    func corruptedMessageRowIsIsolated() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b")
        try store.apply([created(a), created(b)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ? AND ordinal = 0", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["a", "b"])
        #expect(loaded.conversations[0].messages.count == 1)
        #expect(loaded.conversations[1].messages.count == 2)
        #expect(loaded.skipped == [SkippedRow(conversationId: a.id, table: "messages", ordinal: 0, reason: loaded.skipped.first?.reason ?? "")])
        #expect(loaded.skipped.first?.reason.isEmpty == false)
        // The row is left on disk, not deleted.
        #expect(try store.counts(for: a.id).messages == 2)
    }

    @Test("a corrupted metadata row skips only that conversation")
    func corruptedMetadataIsIsolated() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b")
        try store.apply([created(a), created(b)])
        try store.rawWrite("UPDATE conversations SET goalContract = 'nope' WHERE id = ?", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["b"])
        #expect(loaded.skipped.count == 1 && loaded.skipped.first?.table == "conversations" && loaded.skipped.first?.conversationId == a.id)
    }

    @Test("a write for an id the store has never seen upserts the row even without a created flag")
    func upsertWithoutCreated() throws {
        let store = try ConversationStore.inMemory()
        let c = sample()
        try store.apply([write(c, .metadata, .messagesAppended(from: 0), .historyAppended(from: 0))])
        #expect(try store.loadAll().conversations.count == 1)
        #expect(try store.counts(for: c.id) == (2, 2))
    }

    @Test("the on-disk store lives at IrisPaths.conversationsDB and persists across opens")
    func onDiskRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        #expect(paths.conversationsDB.lastPathComponent == "conversations.sqlite")
        try paths.ensureDirectories()
        let c = sample()
        do { let s = try ConversationStore.onDisk(at: paths.conversationsDB); try s.apply([created(c)]) }
        let again = try ConversationStore.onDisk(at: paths.conversationsDB)
        #expect(try again.loadAll().conversations.first?.id == c.id)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -5`
Expected: `cannot find 'ConversationStore' in scope`, `cannot find type 'ChangeSet'`, `value of type 'IrisPaths' has no member 'conversationsDB'`.

- [ ] **Step 3: `Sendable` and the path**

In `Sources/iris/AppState.swift` change `enum ChatRole: String, Codable {` to `enum ChatRole: String, Codable, Sendable {`, `struct TokenUsage: Codable, Equatable {` to `struct TokenUsage: Codable, Equatable, Sendable {`, and `struct Conversation: Identifiable, Codable, Hashable {` to `struct Conversation: Identifiable, Codable, Hashable, Sendable {`. If the compiler names a non-Sendable member (`JSONValue` is `Sendable`; check `SubagentResult`, `GoalEvaluation` are too), add the conformance to that value type rather than `@unchecked`.

In `Sources/iris/IrisPaths.swift`, next to `factStoreDB`:

```swift
    /// The conversation store (#163). At the root on purpose: `makeVolatileCopy` copies only
    /// memory/, rules/, config/ and plugins/, so a headless copy starts with no conversations,
    /// which is the choice `IrisDefaults.perfSeed` already made for the old blob.
    var conversationsDB: URL { root.appendingPathComponent("conversations.sqlite") }
```

- [ ] **Step 4: Implement `ConversationStore.swift`**

```swift
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
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)", arguments: [c.id.uuidString]) ?? false
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
                    c = Conversation(id: id, title: row["title"] ?? "Untitled", workspacePath: row["workspacePath"])
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
```

Notes for the implementer: `Conversation`'s memberwise init does not take `activeGoal`'s siblings, hence the property assignments after construction. `Row` subscripts return optionals for nullable columns; where the plan writes `row["title"] ?? "Untitled"` the type is inferred from the assignment. If GRDB's `Bool.fetchOne` with `EXISTS` is awkward, use `Int.fetchOne(...) == 1`.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter ConversationStoreTests 2>&1 | tail -15`
Expected: 11 tests pass. Then `swift build 2>&1 | grep -c "error:"` prints `0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/ConversationStore.swift Sources/iris/IrisPaths.swift Sources/iris/AppState.swift Tests/irisTests/ConversationStoreTests.swift
git commit -m "feat(store): per-conversation SQLite store with typed change sets (#163)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Legacy blob import

**Files:**
- Create: `Sources/iris/LegacyConversationBlob.swift`
- Modify: `Sources/iris/ConversationStore.swift` (add `importLegacy`)
- Test: `Tests/irisTests/LegacyConversationBlobTests.swift`

**Interfaces:**
- Consumes: `ConversationStore.inMemory()`, `apply`, `isEmpty`, `loadAll`, `ChangeSet`, `ConversationWrite` (Task 1); `AppState.durableConversations(_:)` (existing, `nonisolated static`).
- Produces:
  - `ConversationStore.importLegacy(_ conversations: [Conversation]) throws -> Bool` (false, and no writes, when the store already has rows; the emptiness check runs inside the transaction).
  - `enum LegacyConversationBlob { static let key = "iris_conversations"; static let legacyKey = "iris_conversations_legacy"; enum Outcome: Equatable { case nothingToDo, imported(Int), storeNotEmpty, undecodable }; static func migrateIfNeeded(into store: ConversationStore, defaults: UserDefaults, now: Date = Date()) -> Outcome }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import iris

@Suite("Legacy conversation blob import")
struct LegacyConversationBlobTests {
    private func defaults() -> UserDefaults {
        let name = "iris-legacy-blob-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
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
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: defaults()) == .nothingToDo)
    }

    @Test("the blob is imported in order, sub-process conversations dropped, and the key moved to the legacy name")
    func imports() throws {
        let store = try ConversationStore.inMemory()
        let d = defaults()
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
        let d = defaults()
        d.set(blob([conv("a")]), forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .imported(1))
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .nothingToDo)
        d.set(blob([conv("stale")]), forKey: LegacyConversationBlob.key)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d) == .storeNotEmpty)
        #expect(try store.loadAll().conversations.map(\.title) == ["a"])
        #expect(d.data(forKey: LegacyConversationBlob.key) == nil)
    }

    @Test("an undecodable blob is backed up under a timestamped key and left in place, as before")
    func undecodable() throws {
        let store = try ConversationStore.inMemory()
        let d = defaults()
        d.set(Data("{not json".utf8), forKey: LegacyConversationBlob.key)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(LegacyConversationBlob.migrateIfNeeded(into: store, defaults: d, now: now) == .undecodable)
        #expect(d.data(forKey: "iris_conversations_backup_1700000000.0") != nil)
        #expect(d.data(forKey: LegacyConversationBlob.key) != nil)
        #expect(try store.isEmpty())
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `cannot find 'LegacyConversationBlob' in scope`.

- [ ] **Step 3: Implement**

Append to `ConversationStore.swift`:

```swift
extension ConversationStore {
    /// First-launch import (spec §6). Returns false and writes nothing when the store already
    /// holds conversations; the check runs inside the write transaction so a crash between a
    /// previous import's commit and the key move cannot double-import.
    func importLegacy(_ conversations: [Conversation]) throws -> Bool {
        try writer.write { db in
            if (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0) > 0 { return false }
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
```

(`upsertMetadata`/`insertMessages`/`insertHistory` are `private static`; make them `fileprivate static` or put this extension in the same file, which the file map already does.)

Create `Sources/iris/LegacyConversationBlob.swift`:

```swift
import Foundation

/// One-time move from the UserDefaults JSON blob to the conversation store (#163, spec §6).
enum LegacyConversationBlob {
    static let key = "iris_conversations"
    static let legacyKey = "iris_conversations_legacy"

    enum Outcome: Equatable {
        case nothingToDo
        case imported(Int)
        case storeNotEmpty
        case undecodable
    }

    static func migrateIfNeeded(into store: ConversationStore, defaults: UserDefaults, now: Date = Date()) -> Outcome {
        guard let data = defaults.data(forKey: key) else { return .nothingToDo }
        let decoded: [Conversation]
        do {
            decoded = try JSONDecoder().decode([Conversation].self, from: data)
        } catch {
            // Same behaviour as the old loader: keep the blob, park a copy, start empty.
            print("Failed to decode legacy conversations: \(error)")
            defaults.set(data, forKey: "iris_conversations_backup_\(now.timeIntervalSince1970)")
            return .undecodable
        }
        let durable = AppState.durableConversations(decoded)
        let imported: Bool
        do {
            imported = try store.importLegacy(durable)
        } catch {
            print("Legacy conversation import failed; leaving the blob in place: \(error)")
            return .undecodable
        }
        // Only after the transaction committed: park the blob and stop reading it.
        defaults.set(data, forKey: legacyKey)
        defaults.removeObject(forKey: key)
        return imported ? .imported(durable.count) : .storeNotEmpty
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "LegacyConversationBlobTests|ConversationStoreTests" 2>&1 | tail -6`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/LegacyConversationBlob.swift Sources/iris/ConversationStore.swift Tests/irisTests/LegacyConversationBlobTests.swift
git commit -m "feat(store): one-time import of the UserDefaults conversation blob (#163)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `AppState` write path — `markChanged`, flush, `flushSave`

**Files:**
- Modify: `Sources/iris/AppState.swift` (the `saveTask`/`firstDirtyAt`/`saveConversations`/`flushSave`/`writeConversationsNow` block near lines 1309-1396; the 37 call sites listed below; `init`)
- Modify: `Sources/iris/ConversationStore.swift` (add `makeDefault()`)
- Test: `Tests/irisTests/SavePersistenceTests.swift` (re-point the `persisted()` helper; keep the three tests), new `Tests/irisTests/ChangeTrackingTests.swift`

**Interfaces:**
- Consumes: Task 1 types; Task 2 is not wired yet (load stays on the blob in this task; Task 4 switches it).
- Produces:
  - `ConversationStore.makeDefault() -> ConversationStore` (spec §1 rule).
  - `AppState.store: ConversationStore` (internal `let`), `init(store: ConversationStore = .makeDefault())`.
  - `AppState.markChanged(_ id: UUID, _ change: ConversationChange)` replacing every `saveConversations()`.
  - `AppState.pendingChangeSet(for id: UUID) -> ChangeSet?` (tests).
  - `AppState.flushSave()` unchanged signature; `AppState.saveDebounce`/`saveMaxWait` unchanged.

- [ ] **Step 1: Write the failing tests**

`Tests/irisTests/ChangeTrackingTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Every mutation records what changed instead of re-encoding the whole array (spec §3).
@MainActor
@Suite("Conversation change tracking (#163)")
struct ChangeTrackingTests {
    private func app() -> (AppState, UUID) {
        let a = AppState(store: try! .inMemory())
        let id = UUID()
        a.createNewConversation(id: id)
        return (a, id)
    }

    @Test("create, append, update, history append/replace, metadata and delete map to their change kinds")
    func kinds() {
        let (a, id) = app()
        #expect(a.pendingChangeSet(for: id)?.created == true)
        a.appendMessage(role: .user, content: "one", to: id)
        a.appendMessage(role: .agent, content: "two", to: id)
        #expect(a.pendingChangeSet(for: id)?.messagesFrom == 0)
        let mid = a.conversations.first { $0.id == id }!.messages[1].id
        a.updateMessageContent(id: mid, content: "two!", in: id, persist: true)
        #expect(a.pendingChangeSet(for: id)?.updatedMessageIds == [mid])
        a.appendContentToHistory(for: id, content: Content(role: "user", parts: [Part(text: "h")]))
        #expect(a.pendingChangeSet(for: id)?.historyFrom == 0)
        a.updateHistory(for: id, history: [])
        #expect(a.pendingChangeSet(for: id)?.historyReplaced == true)
        a.renameConversation(id: id, newTitle: "new")
        #expect(a.pendingChangeSet(for: id)?.metadata == true)
        a.deleteConversation(id)
        #expect(a.pendingChangeSet(for: id)?.deleted == true)
    }

    @Test("updateMessageContent without persist records nothing")
    func streamingUpdatesAreNotRecorded() {
        let (a, id) = app()
        a.appendMessage(role: .agent, content: "x", to: id)
        a.flushSave()
        let mid = a.conversations.first { $0.id == id }!.messages[0].id
        a.updateMessageContent(id: mid, content: "xy", in: id)
        #expect(a.pendingChangeSet(for: id) == nil)
    }

    @Test("sub-process conversations are never written")
    func subagentsNotPersisted() throws {
        let a = AppState(store: try .inMemory())
        let id = UUID()
        a.createNewConversation(id: id, isSubagent: true)
        a.appendMessage(role: .agent, content: "scratch", to: id)
        a.flushSave()
        #expect(try a.store.loadAll().conversations.contains { $0.id == id } == false)
    }

    @Test("a flush writes only the dirty conversation, and the pending set is empty afterwards")
    func flushWritesDirtyOnly() async throws {
        let a = AppState(store: try .inMemory())
        let x = UUID(), y = UUID()
        a.createNewConversation(id: x); a.createNewConversation(id: y)
        a.flushSave()
        a.appendMessage(role: .user, content: "only x", to: x)
        try await Task.sleep(nanoseconds: UInt64((AppState.saveDebounce + 0.6) * 1_000_000_000))
        #expect(a.pendingChangeSet(for: x) == nil && a.pendingChangeSet(for: y) == nil)
        #expect(try a.store.counts(for: x).messages == 1)
        #expect(try a.store.counts(for: y).messages == 0)
    }
}
```

In `SavePersistenceTests.swift` replace the `persisted()` helper body with:

```swift
    private func persisted(_ app: AppState) -> [Conversation] {
        (try? app.store.loadAll().conversations) ?? []
    }
```

and change the three call sites from `persisted()` to `persisted(app)`; construct each `AppState` as `AppState(store: try .inMemory())` (mark those two `throws` tests already `throws`; `testFlushSaveIsImmediate` already is). No other change: the three behaviours stay.

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -4`
Expected: `extra argument 'store' in call`, `value of type 'AppState' has no member 'pendingChangeSet'`.

- [ ] **Step 3: Store selection**

Append to `ConversationStore.swift`:

```swift
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
```

- [ ] **Step 4: `AppState` bookkeeping**

Change `init()` to `init(store: ConversationStore = .makeDefault())` and store it: add `let store: ConversationStore` next to `engine`, assign `self.store = store` as the first line of init (before `loadConversations()`; loading still reads the blob in this task).

Replace the block from `private var saveTask` through the end of `writeConversationsNow()` with:

```swift
    private var saveTask: Task<Void, Never>? = nil
    /// When the oldest currently-unwritten change arrived; nil when nothing is pending.
    private var firstDirtyAt: Date? = nil
    /// Changes recorded since the last flush, per conversation (spec §3).
    private var pendingChanges: [UUID: ChangeSet] = [:]
    /// The batch a detached write is currently applying. Exactly one at a time; `flushSave`
    /// replays it, which is harmless because every row write is keyed by ordinal or id.
    private var inFlight: [ConversationWrite]? = nil

    // (durableConversations / sanitizeLoaded / saveDebounce / saveMaxWait stay exactly as they are)

    /// Records one change and schedules a flush with the #62 debounce and max-wait.
    func markChanged(_ id: UUID, _ change: ConversationChange) {
        pendingChanges[id, default: ChangeSet()].add(change)
        let now = Date()
        let dirtySince = firstDirtyAt ?? now
        firstDirtyAt = dirtySince
        let elapsed = now.timeIntervalSince(dirtySince)
        guard elapsed < Self.saveMaxWait else {
            saveTask?.cancel()
            flush()
            return
        }
        saveTask?.cancel()
        let wait = min(Self.saveDebounce, Self.saveMaxWait - elapsed)
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    func pendingChangeSet(for id: UUID) -> ChangeSet? { pendingChanges[id] }

    /// Snapshots the dirty conversations (value copies) and clears the pending set. Sub-process
    /// conversations never persist, so their changes are dropped here.
    private func takeBatch() -> [ConversationWrite] {
        firstDirtyAt = nil
        let batch: [ConversationWrite] = pendingChanges.compactMap { id, changes in
            let live = conversations.first { $0.id == id }
            if let live, live.isSubagent { return nil }
            if live == nil && !changes.deleted { return nil }   // vanished without a delete: nothing to write
            return ConversationWrite(id: id, snapshot: changes.deleted ? nil : live, changes: changes)
        }
        pendingChanges = [:]
        return batch
    }

    /// Off-main write of the dirty set. One batch in flight at a time; a batch that arrives
    /// while one is being written waits and is flushed when that write completes.
    private func flush() {
        guard inFlight == nil, !pendingChanges.isEmpty else { return }
        let batch = takeBatch()
        guard !batch.isEmpty else { return }
        inFlight = batch
        let store = self.store
        Task.detached(priority: .utility) { [weak self] in
            var failure: Error? = nil
            do { try store.apply(batch) } catch { failure = error }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight = nil
                if let failure {
                    print("Conversation store write failed; will retry: \(failure)")
                    for w in batch { self.pendingChanges[w.id, default: ChangeSet()].merge(w.changes) }
                    self.firstDirtyAt = self.firstDirtyAt ?? Date()
                }
                if !self.pendingChanges.isEmpty { self.flush() }
            }
        }
    }

    /// Writes everything pending synchronously, right now. `applicationWillTerminate` calls
    /// `_exit(0)` after this, which runs no atexit handlers and would kill the debounce task
    /// and any detached write (#62). The in-flight batch is replayed too: it may not have
    /// started, and replaying rows keyed by ordinal and id is harmless.
    func flushSave() {
        saveTask?.cancel()
        let batch = (inFlight ?? []) + takeBatch()
        guard !batch.isEmpty else { return }
        do { try store.apply(batch) } catch { print("Conversation store flush failed: \(error)") }
    }
```

Then replace the 37 `saveConversations()` calls. Each becomes one `markChanged` with the conversation id in scope (the local is `id`, `convId`, or `conversationId` depending on the method):

| method | replacement |
|---|---|
| `createNewConversation` | `markChanged(newConv.id, .created)` |
| `deleteConversation` (the `else { saveConversations() }` branch AND the `createNewConversation()` branch: the delete must be recorded in both) | `markChanged(id, .deleted)` before the `if`, keep the `createNewConversation()` call |
| `appendMessage` | after the append: `markChanged(conversationId, .messagesAppended(from: conversations[idx].messages.count - 1))`; the title assignment inside stays and adds `markChanged(conversationId, .metadata)` |
| `updateMessageContent(persist: true)` | `if persist { markChanged(conversationId, .messageUpdated(id: id)) }` |
| `appendContentToHistory` | `markChanged(conversationId, .historyAppended(from: conversations[idx].history.count - 1))` |
| `appendContentsToHistory` | `markChanged(conversationId, .historyAppended(from: conversations[idx].history.count - contents.count))` |
| `updateHistory`, `stripInlineDataFromHistory` (inside `if modified`) | `.historyReplaced` |
| `handleClearCommand` | `.messagesReplaced` |
| `startTurn` (the three counter sites), `updateTokenUsage`, `renameConversation`, `updateConversationTitle`, `setWorkspace`, `setMainAgentSandbox`, `setSubagentResult`, `setGoal`, `clearGoal`, `setGoalContract`, `setDraftContract`, `amendGoalContract`, `beginGoalEvaluation`, `recordEvaluation`, `recordCompletionSelfReport`, `dismissCompletionReport`, `recordGateRefusal`, `waiveCriterion`, `finishGatedGoal`, `recordHumanJudgement`, `resolveJudgementIfComplete`, `beginJudgementPause`, `holdCheckpoint`, `advanceCheckpoint`, `setCheckpointPaused` | `.metadata` |

`grep -n "saveConversations()" Sources/iris/AppState.swift` must return nothing when done; delete the old `saveConversations`/`writeConversationsNow` bodies.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter "ChangeTrackingTests|SavePersistenceTests|ConversationStoreTests" 2>&1 | tail -8`
Expected: pass. Then `swift test 2>&1 | grep -E "✘|Test run with"` — `DefaultsIsolationTests.conversationsDoNotLeak` may now be vacuous but still passes; Task 4 rewrites it.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/ConversationStore.swift Tests/irisTests/ChangeTrackingTests.swift Tests/irisTests/SavePersistenceTests.swift
git commit -m "feat(store): AppState records typed changes and flushes dirty conversations off the main actor (#163)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Load through the store, migration wiring, isolation

**Files:**
- Modify: `Sources/iris/AppState.swift` (`loadConversations`, `init`), `Tests/irisTests/DefaultsIsolationTests.swift`
- Test: `Tests/irisTests/ConversationStoreSelectionTests.swift`

**Interfaces:**
- Consumes: `store.loadAll()`, `LegacyConversationBlob.migrateIfNeeded(into:defaults:)`, `IrisDefaults.store`.
- Produces: `AppState.loadedSkippedRows: [SkippedRow]` (internal, for the notice and tests).

- [ ] **Step 1: Write the failing tests**

```swift
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
```

In `DefaultsIsolationTests.swift`, replace `conversationsDoNotLeak` and `freshStateIsClean` with:

```swift
    @Test("saving conversations touches neither the real UserDefaults nor the real store file")
    func conversationsDoNotLeak() {
        let key = LegacyConversationBlob.key
        let before = UserDefaults.standard.data(forKey: key)
        let fileBefore = FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path)
        let app = AppState()
        app.createNewConversation(id: UUID())
        app.flushSave()
        #expect(UserDefaults.standard.data(forKey: key) == before)
        #expect(FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path) == fileBefore)
    }

    @Test("a fresh AppState with its own store starts empty apart from the default conversation")
    func freshStateIsClean() throws {
        let app = AppState(store: try .inMemory())
        #expect(app.conversations.count == 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `value of type 'AppState' has no member 'loadedSkippedRows'`; `loadsFromStore` would fail at runtime because load still reads the blob.

- [ ] **Step 3: Implement**

In `AppState`: add `private(set) var loadedSkippedRows: [SkippedRow] = []`. Replace `loadConversations()` with:

```swift
    private func loadConversations() {
        // One-time move off the UserDefaults blob (spec §6). Cheap when there is no key.
        let outcome = LegacyConversationBlob.migrateIfNeeded(into: store, defaults: IrisDefaults.store)
        if case .imported(let n) = outcome { print("Imported \(n) conversations from the legacy blob.") }

        do {
            let result = try store.loadAll()
            loadedSkippedRows = result.skipped
            let loaded = Self.sanitizeLoaded(result.conversations)
            self.conversations = loaded
            self.selectedConversationId = loaded.last?.id
            for row in result.skipped {
                print("Skipped unreadable \(row.table) row (conversation \(row.conversationId?.uuidString ?? "?"), ordinal \(row.ordinal.map(String.init) ?? "-")): \(row.reason)")
            }
        } catch {
            print("Failed to load conversations: \(error)")
        }
    }
```

In `init`, after `loadConversations()` and the empty check, surface skips once:

```swift
        if !loadedSkippedRows.isEmpty, let target = selectedConversationId {
            let convs = Set(loadedSkippedRows.compactMap(\.conversationId)).count
            appendMessage(role: .system,
                          content: "\(loadedSkippedRows.count) saved entr\(loadedSkippedRows.count == 1 ? "y" : "ies") in \(convs) conversation\(convs == 1 ? "" : "s") could not be read and were skipped. They remain in conversations.sqlite.",
                          to: target)
        }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "ConversationStoreSelectionTests|DefaultsIsolationTests|ChangeTrackingTests|SavePersistenceTests|LegacyConversationBlobTests|ConversationStoreTests" 2>&1 | tail -8`, then the full `swift test`.
Expected: all pass. `SubagentManagerTests` still removes the old key from `UserDefaults.standard` in its setUp; harmless, leave it.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/AppState.swift Tests/irisTests/ConversationStoreSelectionTests.swift Tests/irisTests/DefaultsIsolationTests.swift
git commit -m "feat(store): load conversations from the store, import the legacy blob once, surface skipped rows (#163)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Docs, follow-up issue, verification

**Files:**
- Modify: `AGENTS.md` (invariant 1), `docs/specs/2026-09-19-conversation-store-design.md` (status line)

- [ ] **Step 1: Invariant wording**

In `AGENTS.md` invariant 1, replace "which causes the entire `conversations` array to fail to load and silently drops ALL conversations" with "which makes that row unreadable: since #163 a message or history entry that fails to decode is skipped (and reported at launch) rather than dropping every conversation, but a skipped row is still lost to the user". Keep the rule mandatory.

- [ ] **Step 2: Follow-up issue**

Run `gh issue create --title "Delete the iris_conversations_legacy defaults key two releases after #163" --body "..."` describing: the import (#163) parks the old blob under \`iris_conversations_legacy\`; after two releases with the store, remove the key at launch (and the \`iris_conversations_backup_*\` keys) to free the multi-MB plist entry. Record the issue number in the spec's status line.

- [ ] **Step 3: Full verification**

Run: `swift build 2>&1 | grep -c "warning:.*ConversationStore\|warning:.*AppState.swift"` → `0`; `swift test 2>&1 | tail -3` → green.

- [ ] **Step 4: Manual check (the controller hands this to the user; the release binary blocks on the Keychain dialog when agent-launched)**

1. Back up `~/Library/Preferences/com.bnaylor.iris.plist`. Launch via `scripts/run-dev.sh` (dev domain) or the release build. Console shows `Imported N conversations from the legacy blob.`; the sidebar lists the same conversations in the same order; `~/.iris/conversations.sqlite` exists; `defaults read com.bnaylor.iris iris_conversations` now fails and `iris_conversations_legacy` exists.
2. Send a message; quit; relaunch: the message is there.
3. `sqlite3 ~/.iris/conversations.sqlite 'select count(*) from messages'` grows by exactly the messages sent.

- [ ] **Step 5: Commit and PR**

```bash
git add AGENTS.md docs/specs/2026-09-19-conversation-store-design.md
git commit -m "docs: invariant 1 after the conversation store; legacy-key follow-up (#163)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

PR body: link spec and plan, the one-time migration and where the old blob is parked, the manual checklist, and the sizes before/after if the user reports them.

---

## Self-review

- **Spec coverage.** §1 store location and selection → Tasks 1 (path) and 3 (`makeDefault`), tested in Task 4. §2 schema and `Sendable` → Task 1. §3 change tracking and the 37-site table → Task 3. §4 flush, one-in-flight, retry-by-merge, `flushSave` replay → Task 3 (tested by `flushWritesDirtyOnly` and the re-pointed #62 tests). §5 load, skip and surface → Tasks 1 and 4. §6 migration incl. in-transaction emptiness check and key move → Tasks 2 and 4. §7 tests → Tasks 1–4. §8 files → matches. §9 risks: the "forgotten `markChanged`" catch is `ChangeTrackingTests.kinds` plus the `grep` in Task 3 Step 4.
- **Placeholders.** Task 5 Step 2's issue body is described in prose; it is an issue, not code. No other prose-only steps.
- **Type consistency.** `ChangeSet.add/merge/isEmpty`, `ConversationWrite(id:snapshot:changes:)`, `SkippedRow(conversationId:table:ordinal:reason:)`, `LoadResult`, `ConversationStore.inMemory()/onDisk(at:)/apply/loadAll/counts(for:)/isEmpty()/rawWrite/importLegacy/makeDefault()`, `LegacyConversationBlob.key/legacyKey/Outcome/migrateIfNeeded(into:defaults:now:)`, `AppState.init(store:)/store/markChanged/pendingChangeSet(for:)/flushSave/loadedSkippedRows` are used with the same names and labels in every task.
