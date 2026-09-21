# Agency Deliverable 2: Run Ledger, Background Runs, and Event Cards — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A job fires into its own hidden, persisted conversation; every run is recorded in `job_runs`; an approval-gated tool in a background run fails closed; the outcome reaches an "Iris Activity" conversation as an event card that never wakes a model turn; `list_jobs`, `get_job_run`, `/jobs`, and retention exist.

**Architecture:** Deliverable 1 already created the `job_runs` table and the `isBackground`/`isPinned` columns (migration `v9_jobs`), so this plan adds no migration. New code: `JobRun` + ledger run methods; `Conversation.isBackground/isPinned` read and written by the store and honoured by the sidebar; `ChatRole.event` + `EventCard`; a fail-closed branch in `requestApproval`; `EventDelivery` with a `pendingEventLines` queue drained at the steer boundary; `JobRunner` replacing `IrisEngine.fireHandler()`; the two pinned-only tools and `/jobs`; a prune at launch and daily.

**Tech Stack:** Swift 6 strict concurrency, GRDB, SwiftUI (`MessageView` only), Swift Testing.

**Spec:** `docs/specs/2026-09-21-agency-model-and-ledger.md` §4 (job_runs), §6, §7, §8, §9, §10, §12, §13. Facts about the code after deliverable 1: `.superpowers/briefs/agency-d2-facts.md` in the main checkout (file:line for every seam named below).

## Global Constraints

- Every new stored property on a persisted `Codable` type decodes with `decodeIfPresent` and a default (invariant 1); `Conversation.isBackground`/`isPinned` mirror `isArchived` exactly (`AppState.swift` `init(from:)`, `CodingKeys`, and the store's `upsertMetadata` UPDATE + INSERT column lists and `loadAll`'s `readBool`).
- A delivered event card NEVER starts a model turn. Its history line is appended directly only when the destination has no turn in flight; otherwise it waits in `pendingEventLines` and is drained at the steer boundary or at turn end. `drainPendingUserMessages` never sees event lines.
- The default destination is the Activity conversation (title "Iris Activity", `isPinned = true`, id stored in `meta` under `activity_conversation_id`), never `selectedConversationId`.
- Fail-closed: a background conversation never enqueues a `ToolApprovalRequest`; the tool result string the model sees is the existing "User denied permission to execute this tool. You must ask the user for clarification or suggest an alternative."
- `list_jobs`/`get_job_run` are declared only when the current conversation `isPinned` (invariant 6); `/jobs` works in any conversation and never calls the model.
- FTS is not extended to `.event`. `MessageItem.group` needs no change.
- Retention: rows older than 90 days deleted unless `status ∈ {failed, blockedOnApproval}` and `acknowledgedAt == nil`; per job, background conversations beyond the 20 most recent deleted unless referenced by such a row. The decision is a pure function; the caller applies it.
- Tests: Swift Testing; in-memory store; never `~/.iris`, network, or `ConfigManager.shared`; `AppState()` in tests is in-memory automatically. Engine-level tests copy `CheckpointAutoAdvanceTests`' setup (`AppState()`, `createNewConversation(id:)`, `IrisEngine(state:tier:principal:client:)`, `FakeLLMClient`).
- GRDB stores `Date` to the millisecond: never assert `Job`/`JobRun` round-trip equality on values built from `Date()`; use whole-second epochs.
- `swift test; echo exit=$?` = 0 and zero `with [1-9][0-9]* failures` before each commit; conventional commits ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; never `git add` `.superpowers/` or `.claude/`.

---

### Task 1: `isBackground` / `isPinned` end to end, the Activity conversation, pinned ordering, `/clear` refusal

**Files:**
- Modify: `Sources/iris/AppState.swift` (`Conversation` stored props + `CodingKeys` + `init(from:)`; `createNewConversation`; new `activityConversationId()`; `handleClearCommand`), `Sources/iris/ConversationStore.swift` (`upsertMetadata` UPDATE/INSERT lists, `loadAll` mapping; new `metaValue(forKey:)`/`setMetaValue(_:forKey:)`), `Sources/iris/ChatView.swift` (sidebar filters ~:67-69 and ~:88 use the new pure helper)
- Create: `Sources/iris/SidebarOrdering.swift`
- Test: `Tests/irisTests/ConversationFlagsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // Conversation
  var isBackground: Bool = false   // hidden from the sidebar, persisted, searchable
  var isPinned: Bool = false       // sorted first; /clear refuses
  // ConversationStore
  func metaValue(forKey key: String) throws -> String?
  func setMetaValue(_ value: String, forKey key: String) throws
  // AppState
  func createNewConversation(id: UUID = UUID(), isSubagent: Bool = false, isBackground: Bool = false, title: String? = nil, select: Bool? = nil) -> UUID
  static let activityConversationTitle = "Iris Activity"
  static let activityConversationMetaKey = "activity_conversation_id"
  /// Returns the Activity conversation's id, creating it (pinned, unselected) and recording it in meta on first use.
  func activityConversationId() -> UUID
  enum ClearRefusal: Equatable { case pinned }
  func clearRefusal(for id: UUID) -> ClearRefusal?
  // SidebarOrdering (pure)
  enum SidebarOrdering {
      static func visible(_ all: [Conversation]) -> [Conversation]   // !isSubagent && !isBackground && !isArchived, pinned first, then array order
      static func archived(_ all: [Conversation]) -> [Conversation]  // !isSubagent && !isBackground && isArchived
  }
  ```
- `createNewConversation` keeps its current behaviour for existing callers (default args); `select` nil means "select unless subagent or background".

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import iris

@Suite("Conversation flags: isBackground / isPinned")
struct ConversationFlagsTests {
    @Test("both flags round-trip through the store and default to false when absent")
    func roundTrip() throws {
        let store = try ConversationStore.inMemory()
        var a = Conversation(id: UUID(), title: "bg"); a.isBackground = true
        var b = Conversation(id: UUID(), title: "pin"); b.isPinned = true
        let c = Conversation(id: UUID(), title: "plain")
        for conv in [a, b, c] {
            var cs = ChangeSet(); cs.created = true; cs.metadata = true
            try store.apply([ConversationWrite(id: conv.id, snapshot: conv, changes: cs)])
        }
        let back = try store.loadAll().conversations
        #expect(back.first { $0.id == a.id }?.isBackground == true && back.first { $0.id == a.id }?.isPinned == false)
        #expect(back.first { $0.id == b.id }?.isPinned == true)
        #expect(back.first { $0.id == c.id }?.isBackground == false && back.first { $0.id == c.id }?.isPinned == false)
    }

    @Test("Conversation decodes with both flags false when the keys are absent")
    func lenientDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","messages":[],"history":[],"tokenUsage":{},"messageCountSinceReflection":0,"goalIterationCount":0}"#
        let conv = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(conv.isBackground == false && conv.isPinned == false)
    }

    @Test("sidebar ordering: pinned first, background and subagent hidden, archived separate")
    func ordering() {
        var p = Conversation(id: UUID(), title: "p"); p.isPinned = true
        var bg = Conversation(id: UUID(), title: "bg"); bg.isBackground = true
        var sub = Conversation(id: UUID(), title: "sub"); sub.isSubagent = true
        var arch = Conversation(id: UUID(), title: "arch"); arch.isArchived = true
        let x = Conversation(id: UUID(), title: "x"), y = Conversation(id: UUID(), title: "y")
        let all = [x, bg, arch, sub, p, y]
        #expect(SidebarOrdering.visible(all).map(\.title) == ["p", "x", "y"])
        #expect(SidebarOrdering.archived(all).map(\.title) == ["arch"])
    }

    @Test("meta get/set by key")
    func meta() throws {
        let store = try ConversationStore.inMemory()
        #expect(try store.metaValue(forKey: "k") == nil)
        try store.setMetaValue("v1", forKey: "k"); try store.setMetaValue("v2", forKey: "k")
        #expect(try store.metaValue(forKey: "k") == "v2")
    }

    @Test("activityConversationId creates once, pinned, unselected, and is stable across calls")
    @MainActor func activity() throws {
        let app = AppState()
        let before = app.selectedConversationId
        let id1 = app.activityConversationId()
        let id2 = app.activityConversationId()
        #expect(id1 == id2)
        let conv = app.conversations.first { $0.id == id1 }
        #expect(conv?.title == AppState.activityConversationTitle && conv?.isPinned == true && conv?.isBackground == false)
        #expect(app.selectedConversationId == before)
        #expect(try app.store.metaValue(forKey: AppState.activityConversationMetaKey) == id1.uuidString)
    }

    @Test("/clear refuses a pinned conversation and leaves its messages alone")
    @MainActor func clearRefused() {
        let app = AppState()
        let id = app.activityConversationId()
        app.appendMessage(role: .system, content: "keep me", to: id)
        #expect(app.clearRefusal(for: id) == .pinned)
        app.handleClearCommand(convId: id)
        #expect(app.conversations.first { $0.id == id }?.messages.contains { $0.content == "keep me" } == true)
    }
}
```
If `handleClearCommand` is private, make it internal. If `ChangeSet`'s stored flags differ from `created`/`metadata`, use the real names (see `ConversationStore.swift:6-57`).

- [ ] **Step 2: Run** `swift test --filter ConversationFlagsTests` → compile errors for missing members.
- [ ] **Step 3: Implement** — `Conversation`: two stored `var`s after `isArchived`, `CodingKeys` entries, `decodeIfPresent ?? false`. Store: add both columns to the UPDATE and INSERT lists next to `isArchived` (bound as `c.isBackground`/`c.isPinned`), and to `loadAll` via the `readBool` switch (garbled → false + warning, as `isArchived`). `metaValue`/`setMetaValue`: `SELECT value FROM meta WHERE key = ?` / `INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`. `SidebarOrdering` as specified (stable partition: pinned first preserving order, then the rest). `ChatView`: replace the two inline filters with `SidebarOrdering.visible(state.conversations)` / `.archived(...)`; the search-results branch's archived marker unchanged. `createNewConversation`: new parameters, `isBackground` sets the flag and skips selection, `title` overrides "New Conversation". `activityConversationId()`: read meta; if it names a live conversation return it; else create with `isBackground: false, title: activityConversationTitle, select: false`, set `isPinned = true`, `markChanged(.metadata)`, write meta. `handleClearCommand`: `if let r = clearRefusal(for: convId) { emitCommandOutput("This conversation is pinned and cannot be cleared.", format: .system, to: convId); return }`.
- [ ] **Step 4: Run** the new suite and `swift test --filter "ConversationStore|ArchiveUnarchive"`; then the full suite.
- [ ] **Step 5: Commit** `feat(conversations): isBackground and isPinned flags, the Iris Activity conversation, pinned-first sidebar, /clear refuses pinned (#187)`.

---

### Task 2: `JobRun` and the ledger's run methods, with the prune decision

**Files:**
- Modify: `Sources/iris/JobLedger.swift`
- Create: `Sources/iris/JobRun.swift`
- Test: `Tests/irisTests/JobRunLedgerTests.swift`

**Interfaces:**
```swift
struct JobRun: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable, Codable { case running, completed, failed, blockedOnApproval, interrupted }
    let id: UUID; let jobId: UUID; let jobName: String; let triggerKind: String
    let startedAt: Date; var finishedAt: Date?; var status: Status
    var outcome: String?; var failureReason: String?; var blockedTool: String?
    var promptTokens: Int; var candidateTokens: Int; var totalTokens: Int
    var costMicros: Int64?; var gateSignal: String?; var transcriptConversationId: UUID?; var acknowledgedAt: Date?
    init(id: UUID = UUID(), jobId: UUID, jobName: String, triggerKind: String, startedAt: Date, status: Status = .running, transcriptConversationId: UUID? = nil)   // other fields default nil/0
}
extension JobLedger {
    func begin(run: JobRun) throws
    func finish(runId: UUID, status: JobRun.Status, outcome: String?, failureReason: String?, blockedTool: String?, tokens: TokenUsage, finishedAt: Date) throws   // throws JobLedgerError.unknownRun(UUID) when no row changed
    func run(id: UUID) throws -> JobRun?
    func runs(jobId: UUID, limit: Int) throws -> [JobRun]          // newest first
    func recentRuns(limit: Int) throws -> [JobRun]                 // across jobs, newest first
    func unacknowledgedFailures() throws -> [JobRun]               // status failed|blockedOnApproval, acknowledgedAt NULL, oldest first
    func acknowledge(runId: UUID, at: Date) throws
    func closeRunningRuns(reason: String, at: Date) throws -> Int  // running → interrupted; returns count
    struct PruneDecision: Equatable, Sendable { let deleteRunIds: [UUID]; let deleteTranscriptIds: [UUID] }
    static func pruneDecision(runs: [JobRun], now: Date, rowRetention: TimeInterval, transcriptsPerJob: Int) -> PruneDecision  // pure
    func prune(now: Date, rowRetention: TimeInterval, transcriptsPerJob: Int) throws -> PruneDecision   // computes, deletes rows, returns the decision (caller deletes transcripts)
}
```
`outcome` is truncated to 200 characters by `finish`. `JobLedgerError` gains `unknownRun(UUID)`.

- [ ] **Step 1: Failing tests** — `begin`/`run(id:)` round trip (whole-second dates); `finish` sets status/outcome/tokens/finishedAt and truncates a 300-char outcome to 200; `finish` on an unknown id throws `unknownRun`; `runs(jobId:limit:)` newest first and limited; `recentRuns` across jobs; `unacknowledgedFailures` includes failed and blockedOnApproval, excludes acknowledged and completed, oldest first; `acknowledge`; `closeRunningRuns` converts only `running` rows and returns the count; `pruneDecision`: a 91-day-old completed row deleted, a 91-day-old unacknowledged failed row kept, a 91-day-old acknowledged failed row deleted, 25 runs for one job → the 5 oldest transcripts deleted except one referenced by an unacknowledged failure, a run with `transcriptConversationId == nil` contributes nothing; `prune` deletes the rows the decision names and returns it; deleting a job cascades its runs (already covered in D1 — keep).
- [ ] **Step 2: Run** → compile errors. **Step 3: Implement** with the same `DatabaseValue`-based row decoding style as `job(from:)` (never the trapping subscript). **Step 4: Run** `swift test --filter "JobRunLedgerTests|JobLedgerTests"` then full. **Step 5: Commit** `feat(store): job_runs ledger methods and the retention decision (#187)`.

---

### Task 3: `ChatRole.event`, `EventCard`, rendering, and the transcript sheet

**Files:**
- Modify: `Sources/iris/AppState.swift` (`ChatRole`), `Sources/iris/ChatView.swift` (`MessageView` new branch; `backgroundColor`/`textColor` switches; the three role-name ternaries at ~:274-284, ~:667-674, ~:713-720), `Sources/iris/SessionStripView.swift` (`SubagentTranscriptSheet` → internal `TranscriptSheet`; its `copyTranscript` ternary)
- Create: `Sources/iris/EventCard.swift`, `Sources/iris/EventCardView.swift`
- Test: `Tests/irisTests/EventCardTests.swift`

**Interfaces:**
```swift
enum ChatRole: String, Codable, Sendable, Equatable { case user, agent, system, command, event }
struct EventCard: Codable, Equatable, Sendable {
    let kind: String            // "job_run"
    let runId: UUID; let jobId: UUID; let jobName: String
    let status: JobRun.Status
    let outcome: String?; let blockedTool: String?
    let startedAt: Date; let finishedAt: Date
    let totalTokens: Int
    let transcriptConversationId: UUID?
    init(from decoder: Decoder) throws   // decodeIfPresent everywhere; kind defaults "job_run", status defaults .completed
    static func decode(_ messageContent: String) -> EventCard?          // nil when the content is not a card
    func encodedContent() -> String                                     // JSON for ChatMessage.content
    var transcriptLine: String        // "[job pr-sweep · completed · 4.2k tokens] outcome"  (SessionActivity.formatTokenCount for the count)
    var historyLine: String           // "[Event] job pr-sweep completed: outcome (run 1a2b3c4d)"  — first 8 chars of runId
    var headline: String              // "pr-sweep · completed" / "pr-sweep · blocked on approval: run_command" / "pr-sweep · failed"
}
```
- `EventCardView(card:onViewRun:)`: one line — status glyph (green filled circle completed, red for failed, orange for blockedOnApproval, gray for interrupted), `jobName` monospaced, `outcome` truncated with `lineLimit(1)`, trailing `elapsed · tokens`, and a "View run" button when `transcriptConversationId != nil` and that conversation still exists (else the text "transcript pruned"). `MessageView`: `else if message.role == .event, let card = EventCard.decode(message.content) { EventCardView(card: card) { transcriptSessionId = card.transcriptConversationId } }` and a `.sheet` presenting `TranscriptSheet(state:sessionId:)` (rename of `SubagentTranscriptSheet`, now internal; header falls back to the conversation title, which it already does). The three copy/export ternaries and `TranscriptSheet.copyTranscript` render `.event` as `card.transcriptLine` (or the raw content when it does not decode). `backgroundColor`/`textColor` get an `.event` arm (same as `.system`).

- [ ] **Step 1: Failing tests** — encode/decode round trip; `decode` returns nil for plain text; lenient decode with missing `kind`/`status`/`outcome`; `transcriptLine` exact text for 4,200 tokens; `historyLine` exact text with an 8-char run prefix; `headline` for the three statuses; `ChatRole.event` raw value "event" and `ChatMessage` with role event decodes. **Step 2: Run** → errors. **Step 3: Implement** (compile will force the two exhaustive switches; grep `== .system ? "System"` and `"Iris"` for the ternaries). **Step 4:** full suite. **Step 5: Commit** `feat(chat): ChatRole.event and the EventCard message, rendered as a one-line card with a transcript sheet (#187)`.

---

### Task 4: Fail-closed approvals in background conversations

**Files:**
- Modify: `Sources/iris/AppState.swift` (`requestApproval`; new `backgroundDenials`, `takeBackgroundDenials(for:)`)
- Test: `Tests/irisTests/BackgroundApprovalTests.swift`

**Interfaces:**
```swift
struct BlockedToolCall: Equatable, Sendable { let toolName: String; let details: String; let at: Date }
// AppState
private(set) var backgroundDenials: [UUID: [BlockedToolCall]]
func takeBackgroundDenials(for conversationId: UUID) -> [BlockedToolCall]   // returns and clears
static let unattendedDenialNotice = "Not run: `%@` needs approval, and this is an unattended run."
```
In `requestApproval`, before the `autoApproveTools` check: `if let id = conversationId, conversations.first(where: { $0.id == id })?.isBackground == true { backgroundDenials[id, default: []].append(...); appendMessage(role: .system, content: String(format: Self.unattendedDenialNotice, toolName), to: id); return false }`.

- [ ] **Step 1: Failing tests** — `@MainActor` tests on `AppState()`: a background conversation's `requestApproval(toolName: "run_command", details: "rm -rf x", conversationId: id)` returns false, `pendingApprovals` stays empty, `takeBackgroundDenials` returns one entry then empty, the conversation's last message is `.system` with the notice; a non-background conversation with `autoApproveTools = true` still returns true (unchanged path); order matters — a background conversation with `autoApproveTools = true` is STILL denied (fail closed beats auto-approve). **Steps 2–5** as usual; commit `feat(approvals): a background conversation never asks — gated tools fail closed and are recorded (#187)`.

---

### Task 5: Event delivery and the `pendingEventLines` queue

**Files:**
- Create: `Sources/iris/EventDelivery.swift`
- Modify: `Sources/iris/AppState.swift` (queue + `enqueueEventLine`/`takePendingEventLines`/flush at turn end in `endEngineTurn` before `drainPendingUserMessages`), `Sources/iris/iris.swift` (drain at the steer boundary, immediately after `takePendingSteers` at ~:1193, appending each line as `Content(role: "user", parts: [Part(text:)])` via `appendContentToHistory` and refreshing `request.contents` — the existing steer code already does the refresh; put the event lines through the same path)
- Test: `Tests/irisTests/EventDeliveryTests.swift`

**Interfaces:**
```swift
// AppState
func enqueueEventLine(_ text: String, for conversationId: UUID)
func takePendingEventLines(for conversationId: UUID) -> [String]
/// Appends the card message now; routes the history line per the in-flight rule. Never starts a turn.
func deliverEvent(_ card: EventCard, to destinationId: UUID) async
```
`deliverEvent`: sanitize `card.historyLine` with `InjectionGuard.sanitize(_, contextTag: "event_card", maxTier: .tier1_structural)`; `appendMessage(role: .event, content: card.encodedContent(), to: destinationId)`; `if hasTurnInFlight(for: destinationId) { enqueueEventLine(safeLine, for: destinationId) } else { appendContentToHistory(for: destinationId, content: Content(role: "user", parts: [Part(text: safeLine)])) }`. `endEngineTurn` at count → 0: `for line in takePendingEventLines(for: id) { appendContentToHistory(...) }` BEFORE `drainPendingUserMessages`.

- [ ] **Step 1: Failing tests** — AppState-level: `deliverEvent` to an idle conversation appends one `.event` message and one history `Content` and starts no turn (`hasTurnInFlight` false, `engineTurnCounts` untouched); to a conversation with `beginEngineTurn` held, the message appears immediately but the history line is queued (`takePendingEventLines` returns it) and `endEngineTurn` flushes it into history without a new turn (`pendingUserMessages` untouched — check via `takePendingSteers` returning empty). Engine-level (FakeLLMClient with a two-round turn: first response a `functionCall` for a harmless tool such as `read_file` on a temp file, second a text): call `deliverEvent` after the first round starts (use a client that signals when it is called, as `CheckpointAutoAdvanceTests`' routing clients do), assert the history line is present after the turn AND it sits after the function response, not between call and response (inspect `conversation.history` roles/parts order). **Steps 2–5**; commit `feat(events): deliver an event card without waking a turn; history line waits for the steer boundary (#187)`.

---

### Task 6: `JobRunner`, the fire handler, overlap and launch bookkeeping

**Files:**
- Create: `Sources/iris/JobRunner.swift`
- Modify: `Sources/iris/iris.swift` (`fireHandler()` → `JobRunner`; watcher fire path passes changed paths; `IrisEngine.start()` calls `closeRunningRuns` and hands the scheduler an `onSkip`), `Sources/iris/JobScheduler.swift` (an `onSkip: @Sendable (Job) async -> Void` hook called where `firing` skips), `Sources/iris/SessionActivity.swift` (`SessionSummary.Kind.job`), `Sources/iris/AppState.swift` (`registerSubagent(id:role:kind:)` accepts `.job`; the strip already renders any kind)
- Test: `Tests/irisTests/JobRunnerTests.swift`

**Interfaces:**
```swift
actor JobRunner {
    init(state: AppState, engine: IrisEngine, ledger: JobLedger, now: @escaping @Sendable () -> Date = Date.init)
    /// Creates the background conversation, records the run, runs the turn, finishes the row, delivers the card.
    func run(job: Job, reason: String, changedPaths: [String] = []) async
    static func outcome(from messages: [ChatMessage]) -> String?            // first line of the last .agent message, ≤ 200 chars
    static func status(messages: [ChatMessage], denials: [BlockedToolCall], softStopped: Bool) -> JobRun.Status
    static func recordSkip(job: Job, ledger: JobLedger, now: Date) throws  // interrupted row, "skipped: previous run still in progress"
}
```
`run`: `let convId = state.createNewConversation(isBackground: true, title: "\(job.name) · \(ISO8601 now)")`; set `mainAgentSandbox = .sandboxed` when `job.profile == .mutating`; `registerSubagent(id: convId, role: "job:\(job.name)", kind: .job)`; `ledger.begin(run:)` with `transcriptConversationId = convId`; prompt = `job.prompt` + (`changedPaths` non-empty ? "\n\nChanged paths:\n- …" : ""); `await engine.processInput(prompt, source: "job:\(job.name)", conversationId: convId)`; then `status` from: denials (`takeBackgroundDenials`) → `.blockedOnApproval` with `blockedTool` = first; a `.system` message parsed by `LLMErrorMessage.parse` → `.failed` with its headline as `failureReason`; a soft-stop marker (the `.system` line `softStopWithSummary` posts — match its prefix) → `.failed`; else `.completed`. `tokens` = the conversation's `tokenUsage` (fresh conversation, so it is the delta). `finishSession(id:status:)`; `ledger.finish(...)`; `deliverEvent(card, to: job.destinationConversationId ?? state.activityConversationId())`. `IrisEngine.fireHandler()` becomes `{ job, reason in await runner.run(job: job, reason: reason) }` and the watcher path `run(job:reason: "fsEvent", changedPaths:)`. `start()`: `_ = try? ledger.closeRunningRuns(reason: "app was not running", at: Date())` before the scheduler starts; `scheduler.onSkip = { job in try? JobRunner.recordSkip(...) }`.

- [ ] **Step 1: Failing tests** — pure: `outcome(from:)` (first line, truncation, nil when no agent message), `status(...)` precedence (denials beat LLM error beat soft stop beat completed). Engine-level (`AppState()`, `FakeLLMClient(responses: [text "tick"])`, `IrisEngine(state:client:)`, `JobRunner`): after `run(job:)` — a conversation with `isBackground == true` exists and is not in `SidebarOrdering.visible`, the ledger row is `completed` with `outcome == "tick"` and the fake's token counts, the Activity conversation has exactly one `.event` message decoding to a card with that `runId`, the previously selected conversation has no new messages, `state.sessions` no longer lists the run (finished), a second `run` for the same job makes a second background conversation. Blocked path: a client whose first response is a `functionCall` for `run_command` with `"command": "echo hi"` (non-allowlisted → `requestApproval`) and second is text; `autoApproveTools` false; assert `.blockedOnApproval`, `blockedTool == "run_command"`, `pendingApprovals` empty, the card's headline names the tool. `recordSkip` writes an interrupted row with no transcript. `closeRunningRuns` at start closes a seeded running row. **Steps 2–5**; commit `feat(jobs): background JobRunner — hidden per-run conversation, ledger row, fail-closed status, event card (#187)`.

---

### Task 7: `list_jobs`, `get_job_run`, and `/jobs`

**Files:**
- Modify: `Sources/iris/iris.swift` (pinned-gated declarations next to the session-tools block; handlers), `Sources/iris/AppState.swift` (`/jobs` dispatch in `sendMessage` + `handleJobsCommand`)
- Create: `Sources/iris/JobsCommand.swift` (pure parsing and rendering)
- Test: `Tests/irisTests/JobsCommandTests.swift`, `Tests/irisTests/JobToolsTests.swift`

**Interfaces:**
```swift
enum JobsCommand: Equatable {
    case list, ack(runId: String), delete(name: String), usage
    static func parse(_ text: String) -> JobsCommand            // "/jobs", "/jobs ack <id>", "/jobs delete <name>"
    static func render(jobs: [Job], lastRuns: [UUID: JobRun], unacknowledged: [JobRun], unreadableJobs: Int, now: Date) -> String   // markdown table + failure lines
    static let usageText = "Usage: /jobs · /jobs ack <run id> · /jobs delete <name>"
}
```
Tools: `list_jobs` (no params) → JSON array of `{name, trigger, enabled, nextFireAt, lastStatus}`; `get_job_run(run_id)` → the ledger row as JSON plus `lastAgentMessage` (first 2,000 chars of the transcript's last agent message, sanitized under `tool_output_get_job_run`), or "No run with that id." Both declared only when `isPinned` (copy the `hasActiveGoal` lookup shape). `/jobs delete <name>` → `ledger.delete(jobId:)` + `WatcherManager.shared.reload()`; `/jobs ack <id>` → `acknowledge`; outputs via `emitCommandOutput(_, format: .markdown)`.

- [ ] **Step 1: Failing tests** — `parse` for all four forms including a run id prefix; `render` for zero jobs ("No jobs."), one job with a last run, one unacknowledged failure line, the unreadable count line; tool handlers via the engine harness with a pinned conversation (declaration present in the request's tools — inspect the `FakeLLMClient`'s received request if it records it, else test the pure gate helper `IrisEngine.jobToolsDeclared(isPinned:)`), and absent in a non-pinned one; `get_job_run` output for a seeded run. **Steps 2–5**; commit `feat(jobs): list_jobs and get_job_run in pinned conversations; /jobs everywhere (#187)`.

---

### Task 8: Retention at launch and daily; docs

**Files:**
- Modify: `Sources/iris/iris.swift` (`start()`: prune at launch; `JobScheduler` gets `onDailyMaintenance` invoked every 24 h from its loop), `Sources/iris/JobScheduler.swift`, `README.md`, `docs/jobs.md`, `docs/agency/agency.md` (deliverable 2 landed), `docs/specs/2026-09-21-agency-model-and-ledger.md` (status line)
- Test: `Tests/irisTests/JobSchedulerTests.swift` (daily hook fires when the injected clock passes 24 h)

- [ ] Steps: failing test for the maintenance hook (clock-injected); implement `applyPrune()` on the engine: `let d = try ledger.prune(...)`; for each transcript id `state.deleteConversation(id)` (verify it does not touch selection when the id is not selected); docs: README "Jobs" bullet gains cards and the Activity conversation; `docs/jobs.md` gains runs, cards, fail-closed, `/jobs`, retention; agency.md deliverable 2 landed; spec status "implemented (D1 PR #, D2 PR #)". Full suite; commit `feat(jobs): retention at launch and daily; docs for runs, cards and /jobs (#187)`.

---

## Self-review

- **Spec coverage:** §4 run methods → T2; §6.1 → T1 (flags), T6 (runner); §6.2 → T6; §6.3 (costMicros NULL) → nothing writes it, by spec; §7 → T4; §8.1 → T1; §8.2 → T3; §8.3 → T5; §9 → T7; §10 → T2 (decision) + T8 (apply); §11 (removals) done in D1; §12 tests distributed per task; §13 → T8.
- **Placeholders:** none. **Type consistency:** `JobRun.Status` used by `EventCard` (T3) and `JobRunner` (T6); `EventCard.historyLine` consumed by `deliverEvent` (T5); `takeBackgroundDenials` (T4) consumed by `JobRunner.status` (T6); `SidebarOrdering.visible` (T1) used in T6's test; `activityConversationId()` (T1) used by T6.
