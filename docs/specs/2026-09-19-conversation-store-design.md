# Conversation Store (#163)

* **Status**: design, awaiting review
* **Issue**: #163 (replace the UserDefaults JSON blob). Follow-ups already filed: #177 (cross-conversation search and lazy loading), #178 (stale volatile plists, unrelated but found here).
* **Decision taken**: SQLite through GRDB with normalized message and history rows (approach A). One JSON file per conversation (B) was rejected because a long conversation is still re-encoded whole on every append and search would need a second index; Core Data was rejected as model churn for no gain.

## Problem

Every conversation persists as one JSON blob under the `iris_conversations` key in UserDefaults (4.79 MB on the reporting machine). `AppState.saveConversations()` re-encodes the whole array on the main actor on every mutation and hands the blob to `UserDefaults.set`. Cost is O(total history) per mutation, lands on the UI thread, and one undecodable field drops every conversation at load (AGENTS.md invariant 1 exists to defend against that). The debounce and 2 s max-wait from #62 bound how stale the store may be, not how much each write costs.

## Goals

1. A mutation costs work proportional to what changed: appending a message inserts one row.
2. Encoding and writing happen off the main actor; the main actor only records what changed.
3. One undecodable conversation, message, or history entry is skipped and logged; everything else loads.
4. Existing users migrate once, automatically, with the old blob kept as a fallback.
5. The debounce, the max-wait, and the synchronous flush on quit keep their semantics and their tests.
6. Headless runs (`--perf`, `--bench`) and the test process never touch the user's real store.
7. The schema leaves #177 additive: an FTS index over the messages table and title-only loading need no restructuring.

## Non-goals

- Search, lazy loading, or paging of conversations (#177).
- Retention or pruning of old conversations.
- Changing the in-memory model: `AppState.conversations` stays `[Conversation]`, views are untouched.
- Storing sub-process (subagent, evaluator) conversations; they stay ephemeral, as today.

## 1. Where it lives

`IrisPaths.conversationsDB` = `<root>/conversations.sqlite`, opened as a GRDB `DatabasePool` (WAL), the same shape as the fact store. It sits at the root of `~/.iris` on purpose: `IrisPaths.useVolatileCopy` copies `memory/`, `rules/`, `config/`, `plugins/` and symlinks `models/`, so a volatile copy gets no conversations, which is the behaviour `IrisDefaults.perfSeed` already chose for the blob.

**Store selection** (one rule, in one place):

| process | store |
|---|---|
| normal app | on disk at `IrisPaths.default.conversationsDB` |
| `swift test` (XCTest linked, the signal `IrisDefaults` already uses) | in-memory `DatabaseQueue` |
| `HeadlessMode.isEnabled` or `IrisDefaults.isVolatileCopy` | in-memory `DatabaseQueue` |

A fake-lane `--perf` run has volatile defaults but the real `IrisPaths`; without the third row it would open the user's real database. In-memory is right for every headless run because the perf record already captures each turn's final text.

## 2. Schema (GRDB migration `v1_conversation_store`)

```
conversations
  id                          TEXT PRIMARY KEY          -- Conversation.id
  position                    INTEGER NOT NULL          -- sidebar order; max+1 on insert
  title                       TEXT NOT NULL
  createdAt                   DATETIME NOT NULL
  updatedAt                   DATETIME NOT NULL
  workspacePath               TEXT
  activeGoal                  TEXT
  messageCountSinceReflection INTEGER NOT NULL DEFAULT 0
  goalIterationCount          INTEGER NOT NULL DEFAULT 0
  mainAgentSandbox            TEXT                      -- SandboxPref raw value
  tokenUsage                  TEXT NOT NULL             -- JSON of TokenUsage
  goalContract                TEXT                      -- JSON of GoalContract
  subagentResult              TEXT                      -- JSON of SubagentResult

messages
  conversationId TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE
  ordinal        INTEGER NOT NULL                       -- index in Conversation.messages
  id             TEXT NOT NULL                          -- ChatMessage.id, for in-place updates
  payload        TEXT NOT NULL                          -- JSON of ChatMessage
  PRIMARY KEY (conversationId, ordinal)
  INDEX (conversationId, id)

history
  conversationId TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE
  ordinal        INTEGER NOT NULL                       -- index in Conversation.history
  payload        TEXT NOT NULL                          -- JSON of Content
  PRIMARY KEY (conversationId, ordinal)

quarantine                                              -- where loadAll moves rows it can't decode
  id             INTEGER PRIMARY KEY AUTOINCREMENT
  conversationId TEXT NOT NULL                          -- no FK: survives the conversation's deletion
  sourceTable    TEXT NOT NULL                          -- "messages" | "history"
  ordinal        INTEGER NOT NULL                       -- the ordinal it occupied
  payload        BLOB                                   -- raw bytes as stored; may be NULL
  reason         TEXT NOT NULL
  quarantinedAt  DATETIME NOT NULL
```

- Payloads are the existing Codable encodings, so every custom `init(from:)` and every `decodeIfPresent` keeps working unchanged; invariant 1 still applies to new fields, but its blast radius is now one row.
- `lastGoalCompletionReport` and `lastGoalEvaluation` are not stored: `sanitizeLoaded` already clears them at load because they are per-session UI state.
- `isSubagent` is not stored: sub-process conversations never reach the store (`durableConversations` stays the filter).
- `Conversation`, `TokenUsage` and `ChatRole` gain `Sendable` (value types of Sendable members; `ChatMessage`, `GoalContract`, `GoalEvaluation`, `SubagentResult`, `SandboxPref`, `FileAttachment` already are). Encoding off the main actor needs it.

## 3. Change tracking instead of whole-array saves

`AppState.saveConversations()` is replaced by `markChanged(_ id: UUID, _ change: ConversationChange)`:

```swift
enum ConversationChange: Sendable, Equatable {
    case created
    case metadata                         // title, workspace, goal state, token usage, counters, sandbox
    case messagesAppended(from: Int)      // ordinal of the first new message
    case messageUpdated(id: UUID)         // in-place content change (streaming, legacy migration)
    case historyAppended(from: Int)
    case historyReplaced                  // updateHistory, stripInlineDataFromHistory, /clear
    case deleted
}
```

`AppState` keeps `pendingChanges: [UUID: ChangeSet]` where a `ChangeSet` coalesces: `created` or `deleted` dominate; `historyReplaced` absorbs `historyAppended`; appends keep the smallest `from`; updated ids accumulate; `metadata` is a flag. The mapping of today's 37 call sites:

| call sites | change |
|---|---|
| `createNewConversation` | `.created` |
| `deleteConversation` | `.deleted` |
| `appendMessage` | `.messagesAppended(from: count - 1)` |
| `updateMessageContent(persist: true)` | `.messageUpdated(id)` |
| `appendContentToHistory`, `appendContentsToHistory` | `.historyAppended(from:)` |
| `updateHistory`, `stripInlineDataFromHistory` (when it changed something), `handleClearCommand` | `.historyReplaced` (plus `.metadata` where counters change) |
| everything else (title, workspace, sandbox, goal contract and evaluation, token usage, counters, checkpoints, judgements, waivers, subagent result) | `.metadata` |

The debounce (`saveDebounce` 0.5 s) and max-wait (`saveMaxWait` 2 s) logic moves verbatim onto `markChanged`: it schedules `flush()` exactly as it schedules `writeConversationsNow()` today.

## 4. The store and the flush

`ConversationStore` (new file) owns the database and exposes:

```swift
final class ConversationStore: Sendable {
    init(inMemory: Bool) throws / init(at url: URL) throws
    func loadAll() throws -> LoadResult          // conversations in position order + skipped-row report
    func apply(_ batch: [ConversationWrite]) throws   // one transaction per conversation
    func importLegacyBlob(_ conversations: [Conversation]) throws
    func counts(for id: UUID) throws -> (messages: Int, history: Int)   // tests
}

struct ConversationWrite: Sendable {
    let snapshot: Conversation?     // nil for .deleted
    let changes: ChangeSet
}
```

**Flush.** On the main actor, `flush()` takes the pending map, pairs each entry with a value copy of its conversation (a `Conversation` is a value type, so this is a snapshot), clears the map, and hands the batch to a detached task that calls `store.apply`. Per conversation, in one transaction:

- `created` or `metadata`: upsert the `conversations` row; `position` is assigned on first insert.
- `messagesAppended(from: n)`: `INSERT OR REPLACE` message rows for ordinals `n...`; `messageUpdated(id)`: `UPDATE messages SET payload WHERE conversationId AND id`.
- `historyAppended(from: n)`: `INSERT OR REPLACE` history rows for ordinals `n...`; `historyReplaced`: `DELETE` the conversation's history rows and insert all of them.
- `deleted`: `DELETE FROM conversations WHERE id`; rows cascade.

Writes are keyed by ordinal and id, so replaying a batch after a failed write is idempotent. If `apply` throws, the batch is merged back into `pendingChanges` (append `from` takes the minimum) and the error is logged once; the next mutation retries. Nothing is dropped silently.

**Quit.** `flushSave()` cancels the debounce task and runs the same `apply` synchronously on the calling thread through GRDB's synchronous `write`, then returns; `applicationWillTerminate` still calls it before `_exit`. A detached flush in progress cannot corrupt this: GRDB serializes writers and both batches write the same ordinals.

**Ordering.** `flush` batches are applied in submission order by a single serial executor inside the store (a private `DispatchQueue` or actor), so a `deleted` that follows a `created` for the same id cannot land first.

## 5. Load

`AppState.init` calls `store.loadAll()` synchronously, as `loadConversations()` is synchronous today. For each `conversations` row in `position` order: decode the metadata columns; fetch message and history rows in ordinal order and decode each payload; a payload that fails to decode is skipped and counted; a metadata row that fails to decode skips the whole conversation. The result goes through `sanitizeLoaded` exactly as today. `LoadResult.skipped` (conversation id, table, ordinal, error) is printed to the console.

A message/history payload that fails to decode is **quarantined and the survivors renumbered**, inside one write transaction, before `loadAll` returns: the row (with its raw bytes, whatever they were) moves to `quarantine`, the bad row is deleted from its table, and the remaining rows for that conversation/table are renumbered to a contiguous `0..<n`, preserving order. This matters because `loadAll`'s in-memory array is already compacted past the skip — leaving the bad row's ordinal occupied on disk let the next append (which uses the compacted in-memory index as the ordinal) `INSERT OR REPLACE` the wrong row while its trailing-row `DELETE ... ordinal >= count` dropped a good one, silently losing a readable message on the next flush. A metadata row that fails to decode skips the whole conversation and is left alone: nothing in memory represents that conversation, so nothing can ever write to it again.

Because the bad row is gone after quarantining, a second `loadAll` against the same store reports no skips for it — the skipped-rows notice shown once in the selected conversation (worded around "moved to the quarantine table in `conversations.sqlite`") is naturally one-shot, with no separate dedup state needed. If `store.loadAll()` itself throws (rather than a per-row skip), the error is logged, surfaced as its own one-line notice ("Saved conversations could not be loaded... the database was left untouched"), and the app starts with an empty list.

Position gaps after deletes are fine; positions are only compared.

## 6. Migration from the blob

On the first launch that finds the store empty and the `iris_conversations` key present:

1. Decode the blob with today's decoder. If that throws: write the `iris_conversations_backup_<ts>` key **and remove the live `iris_conversations` key**, report `.undecodable`, and surface a one-line notice ("could not be read... a copy was kept..."). The live key must go here, not just on success — leaving it in place made this re-run (and, once the notice existed, re-tell the user) on every single launch instead of once; the data is presumed lost, so there is nothing to retry.
2. `importLegacy(durableConversations(decoded))` inserts every conversation, message and history row in one transaction, positions in array order. If the write itself fails (disk full, some other transient condition), the live key is **left in place**, `.importFailed` is reported, and a one-line notice says it will be retried at the next launch — unlike an undecodable blob, the data here is fine and worth another attempt.
3. Only after the transaction commits: copy the blob to `iris_conversations_legacy`, then remove `iris_conversations`. A crash between the commit and the key move re-runs the import on next launch against a non-empty store, so step 2 first checks emptiness again inside the transaction and skips if rows exist.

The legacy key is never read again. An issue is filed at implementation time to delete it two releases later. `perfSeed` keeps excluding both keys.

## 7. What changes for tests

- `SavePersistenceTests` assert through the store (`counts(for:)` and `loadAll()`) instead of the defaults key; the three behaviours they pin (max-wait defeats starvation, `flushSave` is synchronous, a locked contract survives a busy period) are unchanged.
- `DefaultsIsolationTests` "saving conversations does not touch the real UserDefaults" becomes "does not touch the real store": the test process is in-memory by the rule in §1.
- `VolatileDefaultsTests.perfSeed` keeps its expectation.
- New `ConversationStoreTests`: round trip of a conversation with attachments, goal contract, token usage and sandbox pref; append writes only the new rows (row counts before and after); in-place message update; history replace; delete cascades; a corrupted message payload is skipped and the conversation still loads with the others; a corrupted metadata row skips only that conversation; legacy import moves the key and is idempotent when re-run; positions preserve array order; the `.created` then `.deleted` batch leaves nothing behind.
- A `ScenarioRunner`-level check that a headless run's `AppState` used an in-memory store (no file appears under the real `IrisPaths`).

## 8. Files

| file | change |
|---|---|
| `Sources/iris/ConversationStore.swift` (new) | schema and migrator, `ConversationStore`, `ConversationChange`/`ChangeSet`/`ConversationWrite`, legacy import |
| `Sources/iris/AppState.swift` | `markChanged` replaces `saveConversations` at the 37 sites; `pendingChanges`; `flush`/`flushSave`; load through the store; migration call in init |
| `Sources/iris/IrisPaths.swift` | `conversationsDB` |
| `Sources/iris/AppState.swift`, `Models.swift` | `Sendable` on `Conversation`, `TokenUsage`, `ChatRole` |
| `AGENTS.md` | invariant 1 wording: a missing key now drops one row, not every conversation; still mandatory |
| tests as in §7 | |

## 9. Risks

- **Load time at init stays synchronous.** For the 4.79 MB case this is a few thousand row decodes on launch, comparable to today's one big decode; lazy loading is #177.
- **Two writers at quit.** Covered in §4; both paths are idempotent and GRDB serializes them.
- **A mutation site that forgets `markChanged`.** Today it would forget `saveConversations` the same way; a test that walks every public mutating method against a fresh `AppState` and asserts `pendingChanges` is non-empty catches the ones that exist now.
