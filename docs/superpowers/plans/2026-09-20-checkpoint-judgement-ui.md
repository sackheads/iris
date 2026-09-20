# Checkpoint Judgement UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A checkpoint that stops on an unjudged `humanJudged` criterion asks for the verdict inline (Accept/Reject on the checkpoint chip), survives a restart with the question still answerable, and cannot be approved past an unjudged or rejected criterion.

**Architecture:** Two new persisted columns keep the pause's surfacing state (`lastGoalEvaluation`, `lastGoalCompletionReport`) across a relaunch; `sanitizeLoaded` stops clearing them while a pause is open. `performCheckpoint` opens the existing D2 judgement pause when the graded evaluation carries a `.humanPending` row, and D3's already-written checkpoint branch of `resolveJudgementIfComplete` resolves it. The chip reuses `DriftCriterionRow`'s Accept/Reject through a file-private handler helper shared with the terminal gate, and its Approve button is gated by a pure `GoalContract` query scoped to the current milestone.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI (macOS), GRDB (SQLite, migrations), Swift Testing (never XCTest for new tests).

**Spec:** `docs/specs/2026-09-20-checkpoint-judgement-ui.md` (issue #191). Builds on `docs/specs/2026-09-20-checkpoint-auto-advance.md` (D3) and `docs/specs/2026-09-18-human-judged-verdicts.md` (D2).

## Global Constraints

- AGENTS.md invariant 1: every persisted type decodes leniently; a corrupt `lastGoalEvaluation` / `lastGoalCompletionReport` column degrades to nil with a `SkippedRow` and never drops the conversation (spec §4).
- AGENTS.md invariant 7: tests never mutate `ConfigManager.shared` or `IrisDefaults.store`; construct `AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)` so launch notices do not depend on the developer's machine.
- AGENTS.md invariant 8: no unbounded chip in the composer stack; `CheckpointPauseChip` keeps its `.frame(maxHeight: 340)`.
- AGENTS.md invariant 9: every sentence this slice makes untrue is corrected in the same branch (spec §12; Task 6).
- Migration name: the spec says `v4_pause_surfacing` "beside `v3_checkpoint_history`"; main has since gained `v4_fts_rowid` and `v5_quarantine_ordinal_nullable` (#214). The migration is **`v6_pause_surfacing`**, registered after `v5_quarantine_ordinal_nullable`. Task 6 corrects the spec sentence.
- Every write to either surfacing field is followed by `markChanged(id, .metadata)` in the same mutation (spec §4); in `clearGoal` the two nils go **before** the existing `markChanged`.
- Read pause conditions off the **evaluation**, never the contract (spec §8): a judgement pause opens only when `evaluation.criteria` contains a `.humanPending` verdict.
- The Approve gate's set is exactly `currentMilestoneCriteria()` intersected with the evaluation (spec §6), the same set `holdCheckpoint` consumes.
- No chip-wide key equivalent on Accept/Reject (spec §9.1). No undo.
- Commit messages: conventional, one per task, ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never `git add` anything under `.superpowers/` or `.claude/`.
- Run the full suite before each commit: `swift test; echo exit=$?`; the Swift Testing summary does not include XCTest results, so check the exit code and grep for `with [1-9][0-9]* failures`. If a failure appears once, run that suite alone before calling it a flake.

---

## File map

| File | Responsibility in this slice |
|---|---|
| `Sources/iris/ConversationStore.swift` | `v6_pause_surfacing` migration; `upsertMetadata` writes both columns; `loadAll` reads both with degrade-to-nil |
| `Sources/iris/AppState.swift` | `sanitizeLoaded` keeps fields while paused; `clearGoal` nils them before `markChanged`; doc-comment corrections |
| `Sources/iris/GoalContract.swift` | `checkpointApproveBlockers(from:)` pure gate query |
| `Sources/iris/iris.swift` | `performCheckpoint` opens the judgement pause; transcript line and tool result say so |
| `Sources/iris/GoalContractPanel.swift` | file-private `judgementHandlers(state:conversation:criterionId:)`; `CheckpointPauseChip` passes handlers, gates Approve, caption, header; `DriftCriterionRow` accessibility labels |
| `Tests/irisTests/ConversationStoreTests.swift`, `ConversationStoreHardeningTests.swift` | column round trip, nil round trip, pre-v6 load, corrupt column |
| `Tests/irisTests/CheckpointJudgementUITests.swift` (new) | sanitizeLoaded, clearGoal on disk, restart round trip, write scheduled, approve gate, waiver order, history entry |
| `Tests/irisTests/CheckpointAutoAdvanceTests.swift`, `DelegateMilestoneTests.swift` | engine-level: the pause opens on both paths, not for future milestones |
| `docs/specs/2026-09-20-checkpoint-auto-advance.md`, `docs/specs/2026-09-20-checkpoint-judgement-ui.md`, `README.md` | invariant-9 corrections |

Existing helpers the tasks rely on (read them before starting): `ConversationStore.inMemory()`, `store.apply([ConversationWrite])`, `store.loadAll() -> LoadResult`, `store.rawWrite(_:arguments:)` (test support, #214), `ConversationStoreTests.sample()` / `created(_:)`, `AppState.flushSave()`, `CheckpointJudgementResolutionTests.pausedAtCheckpoint(_:_:)` (a checkpoint judgement pause fixture), `CheckpointAutoAdvanceTests.RoutingClient`.

---

### Task 1: Persist the two surfacing fields (spec §4)

**Files:**
- Modify: `Sources/iris/ConversationStore.swift` (migrator after `v5_quarantine_ordinal_nullable`; `upsertMetadata` ~:511-541; `loadAll` ~:671-723)
- Test: `Tests/irisTests/ConversationStoreTests.swift` (`roundTrip`, ~:63-84), `Tests/irisTests/ConversationStoreHardeningTests.swift`

**Interfaces:**
- Consumes: `Conversation.lastGoalEvaluation: GoalEvaluation?`, `Conversation.lastGoalCompletionReport: JSONValue?` (`AppState.swift:74-75`), `json(_:_:)` encoder helper, `text(_:)` column reader, `SkippedRow`.
- Produces: columns `conversations.lastGoalEvaluation TEXT NULL`, `conversations.lastGoalCompletionReport TEXT NULL`; `loadAll` populates both properties.

- [ ] **Step 1: Extend `roundTrip` to expect the fields back**

In `Tests/irisTests/ConversationStoreTests.swift`, find `sample()` (top of file) and give the sample conversation both fields. Add after the `c.checkpointHistory = [...]` assignment:

```swift
        c.lastGoalCompletionReport = .array([.object(["criterion": .string("parses"), "status": .string("met"), "evidence": .string("ran it")])])
        c.lastGoalEvaluation = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: UUID(), criterionText: "reads well", kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
```

Then in `roundTrip` replace the line

```swift
        #expect(back.isSubagent == false && back.lastGoalEvaluation == nil && back.lastGoalCompletionReport == nil)
```

with

```swift
        #expect(back.isSubagent == false)
        // #191: the pause's surfacing state has columns of its own, so a checkpoint judgement
        // pause is still answerable after a relaunch (spec §4). Before v6 both came back nil.
        #expect(back.lastGoalEvaluation?.criteria.first?.verdict == .humanPending)
        #expect(back.lastGoalCompletionReport == c.lastGoalCompletionReport)
```

Add three tests to the same suite:

```swift
    @Test("nil surfacing fields round-trip as SQL NULL, not JSON null")
    func surfacingFieldsNilRoundTrip() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        c.lastGoalEvaluation = nil
        c.lastGoalCompletionReport = nil
        try store.apply([created(c)])
        let raw = try store.rawScalar("SELECT typeof(lastGoalEvaluation) || ',' || typeof(lastGoalCompletionReport) FROM conversations WHERE id = ?",
                                      arguments: [c.id.uuidString])
        #expect(raw == "null,null")
        let back = try #require(try store.loadAll().conversations.first)
        #expect(back.lastGoalEvaluation == nil && back.lastGoalCompletionReport == nil)
    }

    @Test("a v5-era row loads with both surfacing fields nil after the v6 migration")
    func preV6RowLoadsNil() throws {
        // Build the schema up to v5 by running the real migrator, then pretend v6 never ran:
        // drop the two columns is not possible in SQLite without a rebuild, so instead insert a
        // row through raw SQL that names only the v5 columns. That is byte-for-byte what a v5
        // database row looks like to the v6 reader: both new columns NULL.
        let store = try ConversationStore.inMemory()
        let id = UUID()
        try store.rawWrite("""
            INSERT INTO conversations (id, position, title, createdAt, updatedAt, messageCountSinceReflection, goalIterationCount, tokenUsage)
            VALUES (?, 1, 'old', ?, ?, 0, 0, '{"promptTokens":0,"completionTokens":0,"totalTokens":0}')
            """, arguments: [id.uuidString, Date(), Date()])
        let loaded = try store.loadAll()
        #expect(loaded.skipped.isEmpty)
        let back = try #require(loaded.conversations.first { $0.id == id })
        #expect(back.lastGoalEvaluation == nil && back.lastGoalCompletionReport == nil)
    }
```

(If `rawScalar` does not exist beside `rawWrite` in the store's test-support extension, add it there: `func rawScalar(_ sql: String, arguments: StatementArguments = []) throws -> String? { try writer.read { try String.fetchOne($0, sql: sql, arguments: arguments) } }`. Check the `tokenUsage` JSON keys against `TokenUsage`'s stored properties before using the literal above.)

In `Tests/irisTests/ConversationStoreHardeningTests.swift` add, mirroring the existing `checkpointHistory` corruption test in that file:

```swift
    @Test("an undecodable lastGoalEvaluation degrades to nil and keeps the conversation (#191)")
    func corruptLastGoalEvaluationDegradesToNil() throws {
        let store = try ConversationStore.inMemory()
        let c = ConversationStoreTests.sample()
        try store.apply([ConversationStoreTests.created(c)])
        try store.rawWrite("UPDATE conversations SET lastGoalEvaluation = '{not json', lastGoalCompletionReport = '[oops' WHERE id = ?",
                           arguments: [c.id.uuidString])
        let loaded = try store.loadAll()
        let back = try #require(loaded.conversations.first { $0.id == c.id })
        #expect(back.lastGoalEvaluation == nil && back.lastGoalCompletionReport == nil)
        #expect(back.messages.count == c.messages.count, "the conversation itself survives")
        #expect(loaded.skipped.contains { $0.conversationId == c.id && $0.reason.hasPrefix("unreadable lastGoalEvaluation") })
        #expect(loaded.skipped.contains { $0.conversationId == c.id && $0.reason.hasPrefix("unreadable lastGoalCompletionReport") })
    }
```

(If `sample()`/`created(_:)` are not `static`, make them `static` in `ConversationStoreTests` so the hardening suite can call them; that is a two-keyword change.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "ConversationStoreTests|ConversationStoreHardeningTests"`
Expected: FAIL. `roundTrip` fails on `lastGoalEvaluation?.criteria.first?.verdict == .humanPending` (comes back nil); `preV6RowLoadsNil` and the corruption test fail because the columns do not exist (`no such column: lastGoalEvaluation`).

- [ ] **Step 3: Add the migration**

In `Sources/iris/ConversationStore.swift`, directly after the `v5_quarantine_ordinal_nullable` registration block (before `return m`):

```swift
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
```

- [ ] **Step 4: Write both columns in `upsertMetadata`**

After `let history = ...` add:

```swift
        // NULL when absent (the overwhelming majority of rows), like `checkpointHistory` (#191).
        let evaluation = try c.lastGoalEvaluation.map { try json($0, encoder) }
        let report = try c.lastGoalCompletionReport.map { try json($0, encoder) }
```

Extend the UPDATE:

```swift
                UPDATE conversations SET title = ?, updatedAt = ?, workspacePath = ?, activeGoal = ?,
                    messageCountSinceReflection = ?, goalIterationCount = ?, mainAgentSandbox = ?,
                    tokenUsage = ?, goalContract = ?, subagentResult = ?, checkpointHistory = ?,
                    lastGoalEvaluation = ?, lastGoalCompletionReport = ?
                WHERE id = ?
```

with arguments `[..., history, evaluation, report, c.id.uuidString]`, and the INSERT column list gains `lastGoalEvaluation, lastGoalCompletionReport` with two more `?` and arguments `[..., history, evaluation, report]`.

- [ ] **Step 5: Read both columns in `loadAll`**

Beside `let checkpointHistory = text("checkpointHistory")` add:

```swift
                let lastGoalEvaluation = text("lastGoalEvaluation")
                let lastGoalCompletionReport = text("lastGoalCompletionReport")
```

Directly after the `checkpointHistory` decode block (the one that appends `SkippedRow(... "unreadable checkpointHistory ...")`), add:

```swift
                // #191: the pause's surfacing state follows the `checkpointHistory` policy, not the
                // `goalContract` one — a snapshot that will not parse means one empty chip, not a
                // lost conversation (spec §4). The `SkippedRow` reaches the launch notice.
                if let s = lastGoalEvaluation {
                    do { c.lastGoalEvaluation = try decoder.decode(GoalEvaluation.self, from: Data(s.utf8)) }
                    catch { out.skipped.append(SkippedRow(conversationId: id, table: "conversations", ordinal: nil, reason: "unreadable lastGoalEvaluation: \(error)")) }
                }
                if let s = lastGoalCompletionReport {
                    do { c.lastGoalCompletionReport = try decoder.decode(JSONValue.self, from: Data(s.utf8)) }
                    catch { out.skipped.append(SkippedRow(conversationId: id, table: "conversations", ordinal: nil, reason: "unreadable lastGoalCompletionReport: \(error)")) }
                }
```

Note the `text(_:)` helper marks an *unreadable* (non-text) column as fatal via `unreadableColumn`; that is the existing policy for every text column and stays. Only an undecodable JSON string is the degrade-to-nil case.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "ConversationStoreTests|ConversationStoreHardeningTests"`
Expected: PASS.

- [ ] **Step 7: Full suite, then commit**

Run: `swift test; echo exit=$?` — expect exit 0 and no `with [1-9]` failures line.

```bash
git add Sources/iris/ConversationStore.swift Tests/irisTests/ConversationStoreTests.swift Tests/irisTests/ConversationStoreHardeningTests.swift
git commit -m "feat(store): persist the pause surfacing fields (v6_pause_surfacing) (#191)

lastGoalEvaluation and lastGoalCompletionReport get nullable columns, written by
upsertMetadata and read by loadAll; a corrupt value degrades to nil with a
SkippedRow, following the checkpointHistory policy, never dropping the conversation.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Keep the fields across a restart; clear them with the goal (spec §3, §9.1)

**Files:**
- Modify: `Sources/iris/AppState.swift` (`sanitizeLoaded` ~:1630-1638; `clearGoal` ~:999-1006)
- Create: `Tests/irisTests/CheckpointJudgementUITests.swift`

**Interfaces:**
- Consumes: Task 1's columns; `AppState(store:tier2Provisioning:tier3Provisioning:)`; `flushSave()`; `CheckpointJudgementResolutionTests.pausedAtCheckpoint` pattern (copy it, do not import a private helper).
- Produces: `AppState.sanitizeLoaded` keeps both fields when `goalContract.checkpointStatus == .pausedForReview || goalContract.awaitingHumanJudgement`; `clearGoal` nils both before `markChanged`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/CheckpointJudgementUITests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// #191: a checkpoint that stops on a humanJudged criterion asks for the verdict inline. These
/// tests pin the state machine and the persistence the spec's §3-§7 and §11 require.
@Suite("Checkpoint judgement UI (#191)")
struct CheckpointJudgementUITests {

    // MARK: fixtures

    static func isolatedApp(_ store: ConversationStore) -> AppState {
        AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    /// A two-milestone ladder paused at milestone 0 on an unjudged humanJudged criterion, with the
    /// judgement pause open — the state `performCheckpoint` produces after Task 3.
    @discardableResult
    static func pausedAtCheckpoint(_ app: AppState, _ id: UUID) -> (human: Criterion, other: Criterion) {
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [h, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [h.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        let eval = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, eval)
        app.recordCompletionSelfReport(for: id, statusJSON: .array([]))
        app.setCheckpointPaused(for: id)
        app.beginJudgementPause(for: id, summary: "milestone done")
        return (h, b)
    }

    static func pausedConversation() -> Conversation {
        var c = Conversation(id: UUID(), title: "paused")
        var contract = GoalContract(objective: "o", criteria: [])
        contract.checkpointStatus = .pausedForReview
        c.goalContract = contract
        c.lastGoalEvaluation = GoalEvaluation(status: .graded, criteria: [], startedAt: Date())
        c.lastGoalCompletionReport = .array([])
        return c
    }

    // MARK: §3 sanitizeLoaded

    @Test("sanitizeLoaded keeps the surfacing fields while the checkpoint is paused for review")
    func sanitizeKeepsFieldsWhenPausedForReview() {
        let out = AppState.sanitizeLoaded([Self.pausedConversation()])
        #expect(out.first?.lastGoalEvaluation != nil)
        #expect(out.first?.lastGoalCompletionReport != nil)
    }

    @Test("sanitizeLoaded keeps the surfacing fields during a terminal judgement pause")
    func sanitizeKeepsFieldsWhenAwaitingJudgement() {
        var c = Self.pausedConversation()
        c.goalContract?.checkpointStatus = .running
        c.goalContract?.awaitingHumanJudgement = true
        let out = AppState.sanitizeLoaded([c])
        #expect(out.first?.lastGoalEvaluation != nil)
    }

    @Test("sanitizeLoaded still clears the surfacing fields when nothing is paused on the user")
    func sanitizeClearsFieldsWhenRunning() {
        var c = Self.pausedConversation()
        c.goalContract?.checkpointStatus = .running
        c.goalContract?.awaitingHumanJudgement = false
        let out = AppState.sanitizeLoaded([c])
        #expect(out.first?.lastGoalEvaluation == nil && out.first?.lastGoalCompletionReport == nil)
    }

    @Test("sanitizeLoaded clears the surfacing fields when there is no contract at all")
    func sanitizeClearsFieldsWithoutContract() {
        var c = Self.pausedConversation()
        c.goalContract = nil
        let out = AppState.sanitizeLoaded([c])
        #expect(out.first?.lastGoalEvaluation == nil)
    }

    // MARK: §11 restart round trip through the store

    @Test("a checkpoint judgement pause is still answerable after a relaunch")
    func pauseSurvivesRelaunchThroughStore() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let human: Criterion
        do {
            let a = Self.isolatedApp(store)
            human = Self.pausedAtCheckpoint(a, id).human
            a.flushSave()
        }
        let b = Self.isolatedApp(store)
        let conv = try #require(b.conversations.first { $0.id == id })
        #expect(conv.goalContract?.checkpointStatus == .pausedForReview)
        #expect(conv.goalContract?.awaitingHumanJudgement == true)
        #expect(conv.lastGoalEvaluation?.criteria.first?.verdict == .humanPending, "the chip's row is back")
        #expect(conv.lastGoalCompletionReport != nil)
        #expect(b.recordHumanJudgement(for: id, criterionId: human.id, accepted: true),
                "the restored pause accepts a verdict instead of refusing it")
    }

    @Test("opening a judgement pause schedules a store write carrying the surfacing fields")
    func pauseWritesSurfacingFieldsToDisk() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let a = Self.isolatedApp(store)
        Self.pausedAtCheckpoint(a, id)
        a.flushSave()
        let row = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(row.lastGoalEvaluation != nil, "asserted on the persisted row, not the property (spec §4)")
        #expect(row.goalContract?.awaitingHumanJudgement == true)
    }

    // MARK: §9.1 clearGoal

    @Test("clearGoal nils both surfacing fields and the store row has both columns NULL")
    func clearGoalClearsFieldsOnDisk() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let a = Self.isolatedApp(store)
        Self.pausedAtCheckpoint(a, id)
        a.flushSave()
        a.clearGoal(for: id)
        a.flushSave()
        let row = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(row.goalContract == nil)
        #expect(row.lastGoalEvaluation == nil && row.lastGoalCompletionReport == nil,
                "in-memory nils are correct whether or not the write was scheduled; the row is the proof")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CheckpointJudgementUITests`
Expected: FAIL. The three "keeps" tests fail (fields nil), `pauseSurvivesRelaunchThroughStore` fails on `lastGoalEvaluation` (sanitizeLoaded still clears it) and on `recordHumanJudgement` returning false, `clearGoalClearsFieldsOnDisk` fails because `clearGoal` does not nil the fields (they persist via Task 1). `pauseWritesSurfacingFieldsToDisk` may already pass; keep it, it pins the write.

- [ ] **Step 3: Implement `sanitizeLoaded`**

Replace the loop in `sanitizeLoaded` with:

```swift
        for i in loaded.indices {
            // #191: while the run is stopped on the user, the surfacing fields are the pause's
            // inputs — `lastGoalEvaluation` is the only thing Accept/Reject act on and the only
            // thing that makes the chip render a row to click — so they must come back from the
            // v6 columns intact. Spelled as the two flags rather than `GoalContract.isPaused`,
            // whose doc comment reserves it for loop-control sites; `lockedChipHeader` sets the
            // same precedent for a surfacing question. Everywhere else they are per-session and
            // cleared as before.
            let pausedOnUser = loaded[i].goalContract.map {
                $0.checkpointStatus == .pausedForReview || $0.awaitingHumanJudgement
            } ?? false
            if !pausedOnUser {
                loaded[i].lastGoalCompletionReport = nil
                loaded[i].lastGoalEvaluation = nil
            }
            loaded[i].messages = loaded[i].messages.map(LLMErrorMessage.migrateLegacy)
        }
```

Rewrite the function's doc comment (currently ~:1620-1629, the one saying the surfacing is per-session and dropped on load unconditionally) to: "Restores load-time invariants. The completion report and evaluation are per-session surfacing state **except** while a judgement or checkpoint pause is open on the user (#191): then they are the pause's inputs and are kept so a restored pause is still answerable. The unconditional clear that used to live here was the workaround for a window-blanking render bug whose root cause was fixed in aa141d5 (invariant 8); if blanking returns at launch, this is the change to suspect (spec §3.1)."

- [ ] **Step 4: Implement `clearGoal`**

```swift
    func clearGoal(for conversationId: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].activeGoal = nil
            conversations[idx].goalContract = nil
            conversations[idx].goalIterationCount = 0
            // #191: the surfacing fields have columns now, so left alone they would outlive the
            // contract on disk and resurrect a chip for a goal that no longer exists. They must sit
            // BEFORE the markChanged below so the same row write carries them (spec §4, §9.1).
            conversations[idx].lastGoalEvaluation = nil
            conversations[idx].lastGoalCompletionReport = nil
            markChanged(conversationId, .metadata)
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CheckpointJudgementUITests`
Expected: PASS.

- [ ] **Step 6: Full suite, then commit**

Run: `swift test; echo exit=$?`. `ConversationStoreSelectionTests` and any test asserting `lastGoalEvaluation == nil` after load must still pass; if one asserts the old unconditional clear for a paused contract, it is asserting the bug: change it and say so in the commit body.

```bash
git add Sources/iris/AppState.swift Tests/irisTests/CheckpointJudgementUITests.swift
git commit -m "feat(goal): keep the pause surfacing fields across a restart; clear them with the goal (#191)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: The checkpoint asks (spec §8)

**Files:**
- Modify: `Sources/iris/iris.swift` (`performCheckpoint` pause branch ~:313-326)
- Modify: `Tests/irisTests/CheckpointAutoAdvanceTests.swift` (`testHumanJudgedPausesWithoutAsking` ~:228-254)
- Modify: `Tests/irisTests/DelegateMilestoneTests.swift`

**Interfaces:**
- Consumes: `AppState.beginJudgementPause(for:summary:)`, `evaluation: GoalEvaluation?` already in scope in `performCheckpoint`, `summary` parameter.
- Produces: a judgement pause at a checkpoint whenever the evaluation carries `.humanPending`; transcript and tool-result strings that name the pending criteria.

- [ ] **Step 1: Flip the engine test**

In `CheckpointAutoAdvanceTests.swift` rename `testHumanJudgedPausesWithoutAsking` to `testHumanJudgedAsksAtCheckpoint`, retitle `@Test("an unjudged humanJudged criterion stops the checkpoint AND opens a judgement pause (#191)")`, keep the first two expectations, and replace the trailing comment and expectation with:

```swift
        // #191: the checkpoint now ASKS. The inline Accept/Reject surface exists on the checkpoint
        // chip, and the pause survives a restart (v6 columns), so opening it is safe.
        #expect(after?.awaitingHumanJudgement == true, "the checkpoint asks for the verdict it stopped on")
        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.lastGoalEvaluation?.criteria.contains { $0.verdict == .humanPending } == true)
        let lastAgentLine = conv?.messages.last { $0.role == .agent }?.content ?? ""
        #expect(lastAgentLine.contains("output reads well"), "the transcript names the criterion waiting on the user")
```

Leave `testFutureMilestoneHumanJudgedDoesNotTrapGoal` exactly as it is; it is §8's regression guard and must keep passing.

Add to `DelegateMilestoneTests.swift`, modelled on that file's existing test that reaches a checkpoint through `delegate_milestone` (copy its client scripting and ladder setup; the only differences are the `humanJudged` criterion in the delegated milestone and the assertions):

```swift
    @Test("a delegated milestone with an unjudged humanJudged criterion opens a judgement pause too (#191 §8)")
    func delegatedCheckpointAsks() async {
        // Same fixture as the delegated-checkpoint test above, with the delegated milestone's
        // criterion made humanJudged. Nothing about handing work to a subagent makes the question
        // someone else's.
        // ... build app/id/ladder exactly as the sibling test does, but with:
        //   let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        //   in milestone 0's criterionIds
        // ... drive the delegate_milestone call exactly as the sibling test does ...
        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.checkpointStatus == .pausedForReview)
        #expect(after?.awaitingHumanJudgement == true, "the delegated path asks exactly as the direct one does")
    }
```

Fill the elided lines from the sibling test in that file (read it first; do not invent a new client).

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "CheckpointAutoAdvanceTests|DelegateMilestoneTests"`
Expected: FAIL on `awaitingHumanJudgement == true` (currently false) and on the transcript text.

- [ ] **Step 3: Implement in `performCheckpoint`**

Replace the pause branch (from `await MainActor.run { localState?.setCheckpointPaused(...)` through the `return "Checkpoint ... Paused for user review."`) with:

```swift
        // Read the condition off the EVALUATION, never the contract (spec §8): the evaluation is
        // exactly the projected criteria, and `GoalEvaluationParsing` assigns `.humanPending`
        // precisely when a criterion is humanJudged and unjudged. Scanning the contract once opened
        // a pause for a future milestone's criterion — no row, no button, no way out.
        let pendingHuman = (evaluation?.criteria ?? []).filter { $0.verdict == .humanPending }
        await MainActor.run {
            localState?.setCheckpointPaused(for: conversationId)   // leaves activeGoal set
            // #191: a checkpoint that stopped on a humanJudged criterion ASKS for the verdict.
            // The checkpoint chip renders Accept/Reject for `.humanPending` rows, the pause survives
            // a restart (v6 columns), and `resolveJudgementIfComplete`'s checkpoint branch clears
            // the flag without finishing the goal. `summary` is parked in
            // `pendingCompletionSummary`; at a checkpoint it is written and never read, and it is
            // passed anyway so a wrong summary cannot surface the day the branches merge.
            if !pendingHuman.isEmpty {
                localState?.beginJudgementPause(for: conversationId, summary: summary)
            }
        }
        if pendingHuman.isEmpty {
            await pushToUI(role: .agent,
                           text: "Reached checkpoint \(ladderPos)\(via): \(summary)\nPaused for your review — approve to continue or send me back.",
                           conversationId: conversationId)
            return "Checkpoint \(ladderPos) reached and graded. Paused for user review."
        }
        let names = pendingHuman.map(\.criterionText).joined(separator: "; ")
        await pushToUI(role: .agent,
                       text: "Reached checkpoint \(ladderPos)\(via): \(summary)\nWaiting for your judgement of: \(names). Decide each one in the checkpoint panel, then approve or send me back.",
                       conversationId: conversationId)
        // Agent-facing: a stale "paused for review" here would invite the model to keep working a
        // milestone that is waiting on a human verdict (invariant 9's worse half).
        return "Checkpoint \(ladderPos) reached and graded. Waiting on the user's judgement of: \(names). Do not continue this milestone until the user has decided."
```

Delete the old six-line comment that said the checkpoint deliberately does not ask.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "CheckpointAutoAdvanceTests|DelegateMilestoneTests|CheckpointJudgementResolutionTests"`
Expected: PASS, including `testFutureMilestoneHumanJudgedDoesNotTrapGoal` (its grade has no `.humanPending` row, so no pause opens).

- [ ] **Step 5: Full suite, then commit**

Run: `swift test; echo exit=$?`.

```bash
git add Sources/iris/iris.swift Tests/irisTests/CheckpointAutoAdvanceTests.swift Tests/irisTests/DelegateMilestoneTests.swift
git commit -m "feat(goal): a checkpoint stopped on a humanJudged criterion asks for the verdict (#191)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The approve gate and the invariants around it (spec §5, §6, §7, §11)

**Files:**
- Modify: `Sources/iris/GoalContract.swift` (add after `canAutoAdvance`, ~:450)
- Test: `Tests/irisTests/CheckpointJudgementUITests.swift`

**Interfaces:**
- Consumes: `GoalContract.currentMilestoneCriteria()`, `judgements`, `hasLadder`; `GoalEvaluation`.
- Produces: `func checkpointApproveBlockers(from evaluation: GoalEvaluation?) -> [CriterionVerdict]` on `GoalContract`; Task 5 disables Approve when it is non-empty.

- [ ] **Step 1: Write the failing tests**

Append to `CheckpointJudgementUITests`:

```swift
    // MARK: §6 the approve gate

    static func ladder(_ human: Criterion, _ other: Criterion, current: Int) -> GoalContract {
        var c = GoalContract(objective: "o", criteria: [human, other])
        c.milestones = [Milestone(title: "A", criterionIds: [human.id]),
                        Milestone(title: "B", criterionIds: [other.id])]
        c.currentMilestone = current
        return c
    }
    static func eval(_ verdicts: [CriterionVerdict]) -> GoalEvaluation {
        GoalEvaluation(status: .graded, criteria: verdicts, startedAt: Date())
    }
    static func pending(_ c: Criterion) -> CriterionVerdict {
        CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: .humanJudged, verdict: .humanPending, evidence: "", method: .human)
    }

    @Test("Approve is blocked by an unjudged humanJudged criterion of the current milestone")
    func gateBlocksUnjudged() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        let c = Self.ladder(h, b, current: 0)
        #expect(c.checkpointApproveBlockers(from: Self.eval([Self.pending(h)])).map(\.criterionId) == [h.id])
    }

    @Test("Approve is blocked by a REJECTED humanJudged criterion of the current milestone")
    func gateBlocksRejected() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 0)
        c.judgements[h.id] = false
        var v = Self.pending(h); v.verdict = .notMet
        #expect(c.checkpointApproveBlockers(from: Self.eval([v])).map(\.criterionId) == [h.id])
    }

    @Test("Approve is not blocked once the criterion is accepted")
    func gateOpensOnAcceptance() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 0)
        c.judgements[h.id] = true
        var v = Self.pending(h); v.verdict = .met
        #expect(c.checkpointApproveBlockers(from: Self.eval([v])).isEmpty)
    }

    @Test("the gate's set equals send-back's set: a rejection in an EARLIER milestone does not block Approve later (§6)")
    func gateIsScopedToCurrentMilestone() {
        // Constructed directly: §7's induction makes this unreachable in normal operation, and this
        // test exists for the day the induction stops holding.
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 1)
        c.judgements[h.id] = false
        var v = Self.pending(h); v.verdict = .notMet
        let bv = CriterionVerdict(criterionId: b.id, criterionText: b.text, kind: .qualitative, verdict: .met, evidence: "ok", method: .judge)
        #expect(c.checkpointApproveBlockers(from: Self.eval([v, bv])).isEmpty,
                "milestone 1 is current; milestone 0's rejection is not this gate's to hold")
    }

    @Test("no evaluation means nothing blocks (the chip has no rows to decide)")
    func gateWithoutEvaluation() {
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        #expect(Self.ladder(h, b, current: 0).checkpointApproveBlockers(from: nil).isEmpty)
    }

    // MARK: §7 the waiver branch is ordered before the humanJudged branch

    @Test("canAutoAdvance passes a WAIVED humanJudged criterion with no judgement recorded (§7 dependency)")
    func waiverPrecedesJudgement() {
        // Spec §7: the guarantee "every humanJudged criterion in the checkpoint is accepted" holds
        // only because checkpoint-level waivers cannot exist today. If they ever can, this ordering
        // is the single thing that decides whether §7 is still true. This test fails the day the
        // ordering changes, which is the right moment to decide which of the two §7 should say.
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired", kind: .qualitative, check: nil)
        var c = Self.ladder(h, b, current: 0)
        c.isLocked = true
        c.waivers[h.id] = "user said skip"
        var v = Self.pending(h)
        v.verdict = .humanPending
        #expect(c.judgements[h.id] == nil)
        #expect(c.canAutoAdvance(from: Self.eval([v])))
    }

    // MARK: §11 the history entry carries the post-judgement evaluation

    @Test("the humanApproved history entry carries the verdict the user gave, not the grader's humanPending")
    func historyCarriesPostJudgementEvaluation() throws {
        let store = try ConversationStore.inMemory()
        let id = UUID()
        let a = Self.isolatedApp(store)
        let (h, _) = Self.pausedAtCheckpoint(a, id)
        #expect(a.recordHumanJudgement(for: id, criterionId: h.id, accepted: true))
        a.advanceCheckpoint(for: id)
        let entry = try #require(a.conversations.first { $0.id == id }?.checkpointHistory.last)
        #expect(entry.resolution == .humanApproved)
        let verdict = try #require(entry.evaluation?.criteria.first { $0.criterionId == h.id })
        #expect(verdict.verdict == .met && verdict.method == .human)
    }
```

(If `isLocked` is not settable or `canAutoAdvance` requires other fields, look at how `AutoAdvanceRuleTests` builds a contract and copy that construction; the point of the test is the waiver-before-judgement order.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CheckpointJudgementUITests`
Expected: the five gate tests fail to compile (`checkpointApproveBlockers` undefined). Comment them out briefly if you need to confirm the other two, then restore.

- [ ] **Step 3: Implement the gate query**

In `GoalContract.swift`, immediately after `canAutoAdvance`:

```swift
    /// #191 spec §6: the humanJudged criteria that hold "Approve & continue" shut at this checkpoint —
    /// rows of the graded evaluation whose criterion is in the CURRENT milestone and is either still
    /// `.humanPending` or was rejected (`judgements[id] == false`).
    ///
    /// Read off the evaluation, never the contract: the evaluation is exactly the graded set, so this
    /// can never fire on a criterion nobody has worked yet. Scoped to `currentMilestoneCriteria()`
    /// because that is exactly the set `holdCheckpoint` consumes rejections for; a gate any wider is a
    /// trap — a rejection carried by an earlier milestone would disable Approve here, Send back would
    /// not clear it, and the goal would sit behind two buttons with no way past either. §7's
    /// induction says that cannot arise; equality by construction does not depend on it.
    func checkpointApproveBlockers(from evaluation: GoalEvaluation?) -> [CriterionVerdict] {
        guard hasLadder, let evaluation else { return [] }
        let current = Set(currentMilestoneCriteria().map(\.id))
        return evaluation.criteria.filter { v in
            v.kind == .humanJudged && current.contains(v.criterionId)
                && (v.verdict == .humanPending || judgements[v.criterionId] == false)
        }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter CheckpointJudgementUITests`
Expected: PASS. If `waiverPrecedesJudgement` fails, do not change `canAutoAdvance`: read spec §7 and report; the test is documenting the current order.

- [ ] **Step 5: Full suite, then commit**

```bash
git add Sources/iris/GoalContract.swift Tests/irisTests/CheckpointJudgementUITests.swift
git commit -m "feat(goal): approve gate scoped to the current milestone; pin the §7 waiver order and the history entry (#191)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The chip asks (spec §9, §9.1)

**Files:**
- Modify: `Sources/iris/GoalContractPanel.swift` (`CheckpointPauseChip` ~:464-560; `CompletionReportSection.judgementHandlers` ~:702-709 and its call sites ~:789-790; `DriftCriterionRow` buttons ~:934-944)

**Interfaces:**
- Consumes: Task 4's `checkpointApproveBlockers(from:)`; `AppState.recordHumanJudgement(for:criterionId:accepted:) -> Bool`.
- Produces: `fileprivate func judgementHandlers(state: AppState, conversation: Conversation, criterionId: UUID) -> (accept: () -> Void, reject: () -> Void)?`; both surfaces call it.

No unit test can drive SwiftUI here; the controller verifies on screen after this task (launch with `scripts/run-dev.sh`, drive with the CGEvent helper). Do not launch the app yourself.

- [ ] **Step 1: Extract the handler helper**

Delete `private func judgementHandlers(for:)` from `CompletionReportSection` and add at file scope (near `CheckpointPauseChip`):

```swift
/// #191: one gate in one place. Accept/Reject appear only while a judgement pause is open, on
/// BOTH surfaces that can show a `.humanPending` row — the terminal completion report and the
/// checkpoint chip — so the two cannot drift on when the buttons exist. The gate is what keeps a
/// finished goal from offering a re-judge that `recordHumanJudgement` would refuse.
fileprivate func judgementHandlers(state: AppState, conversation: Conversation,
                                   criterionId: UUID) -> (accept: () -> Void, reject: () -> Void)? {
    guard conversation.goalContract?.awaitingHumanJudgement == true else { return nil }
    return (
        accept: { _ = state.recordHumanJudgement(for: conversation.id, criterionId: criterionId, accepted: true) },
        reject: { _ = state.recordHumanJudgement(for: conversation.id, criterionId: criterionId, accepted: false) }
    )
}
```

In `CompletionReportSection`, replace the two call sites with:

```swift
                                onAccept: handlers(for: verdict.criterionId)?.accept,
                                onReject: handlers(for: verdict.criterionId)?.reject
```

and add inside the struct:

```swift
    private func handlers(for criterionId: UUID) -> (accept: () -> Void, reject: () -> Void)? {
        guard let conversation, let state else { return nil }
        return judgementHandlers(state: state, conversation: conversation, criterionId: criterionId)
    }
```

Update the struct's `conversation`/`state` doc comment and the old `judgementHandlers` comment (~:693-701), which say the checkpoint chip's use "must stay read-only": it no longer does; say both surfaces share the gate.

- [ ] **Step 2: Wire the chip**

In `CheckpointPauseChip.body`, replace the `DriftCriterionRow(` construction with:

```swift
                                DriftCriterionRow(
                                    verdict: verdict,
                                    selfReportStatus: "",
                                    evaluationStatus: evaluation.status,
                                    reportPresent: conversation.lastGoalCompletionReport != nil,
                                    onAccept: judgementHandlers(state: state, conversation: conversation, criterionId: verdict.criterionId)?.accept,
                                    onReject: judgementHandlers(state: state, conversation: conversation, criterionId: verdict.criterionId)?.reject
                                )
```

Replace the header's trailing text with:

```swift
                        Text(hasPendingJudgement ? "Awaiting your decision" : "Awaiting your approval")
```

and add to the struct:

```swift
    /// §9.1: once nothing is `.humanPending` the question has been answered; a header still asking
    /// reads as a UI that did not notice the click.
    private var hasPendingJudgement: Bool {
        conversation.lastGoalEvaluation?.criteria.contains { $0.verdict == .humanPending } == true
    }
    /// §6: the rows holding Approve shut, scoped to the current milestone.
    private var approveBlockers: [CriterionVerdict] {
        conversation.goalContract?.checkpointApproveBlockers(from: conversation.lastGoalEvaluation) ?? []
    }
```

Replace the Approve button and add the caption, keeping Approve trailing:

```swift
                        Button("Approve & continue") {
                            state.advanceCheckpoint(for: conversation.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(approveBlockers.isEmpty ? Color.irisIndigo : Color.irisIndigo.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .disabled(!approveBlockers.isEmpty)
                        .accessibilityHint(approveBlockers.isEmpty ? "" : "Decide the human-judged criteria first")
                    }
                    if !approveBlockers.isEmpty {
                        Text("Decide the human-judged criteria above before approving.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
```

(The `HStack` closes before the caption; the caption is the next child of the `VStack`.)

- [ ] **Step 3: Accessibility on the row's buttons**

In `DriftCriterionRow`, replace the two buttons with:

```swift
                    Button("Accept", action: onAccept)
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Accept: \(verdict.criterionText)")
                    Button("Reject", action: onReject)
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Reject: \(verdict.criterionText)")
```

No `.keyboardShortcut` on either (spec §9.1).

- [ ] **Step 4: Build and run the suite**

Run: `swift build 2>&1 | grep -E "error|warning: unused" ; swift test; echo exit=$?`
Expected: builds clean, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/GoalContractPanel.swift
git commit -m "feat(ui): checkpoint chip asks for humanJudged verdicts; Approve gated on the current milestone (#191)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: What this makes untrue (spec §12, invariant 9)

**Files:**
- Modify: `docs/specs/2026-09-20-checkpoint-auto-advance.md` (§2 out-of-scope bullet ~:24-43; §3 deferral paragraph ~:44-74; §6 ~:182-223; §11.1 ~:392-410)
- Modify: `docs/specs/2026-09-20-checkpoint-judgement-ui.md` (status line :3; §4 migration name :87-88; §11 first bullet's line references)
- Modify: `README.md` (:34, :37)
- Modify: `Sources/iris/AppState.swift` (`recordCheckpointOutcome` doc ~:1300-1304; the comment inside `resolveJudgementIfComplete` ~:1156-1158)

**Interfaces:** none; text only. Verify every line number by grep before editing; they move.

- [ ] **Step 1: D3 spec**

- §2: change the out-of-scope bullet "Inline judgement at a checkpoint → a future slice" to point at `2026-09-20-checkpoint-judgement-ui.md` (#191) as shipped.
- §3: rewrite the paragraph stating that nothing can record a judgement mid-ladder so auto-advance is off for the rest of a ladder with a taste criterion: that cost was removed by #191; a checkpoint now asks, and an accepted verdict restores auto-advance for the remaining checkpoints.
- §6: retitle to "`humanJudged` at a checkpoint — it stops and asks (as of #191)", rewrite "The pause does not ask for the verdict. No `beginJudgementPause` at a checkpoint" and "asked about once, at completion" and the closing note to describe the new behaviour, and replace the "Why the inline Accept/Reject is deferred" paragraph with one sentence saying it was deferred in D3 and shipped in #191 with the restart persistence that made it safe.
- §11.1: the note that `resolveJudgementIfComplete`'s checkpoint branch is unreachable becomes "reachable since #191; it is the resolution path for a checkpoint judgement pause".

- [ ] **Step 2: This slice's spec**

- Line 3: `**Status:** implemented (#191, PR <n>)`, fill in the PR number the controller gives you or leave `PR pending` for the controller to edit.
- §4: replace "`v4_pause_surfacing` migration written beside `v3_checkpoint_history`" with "`v6_pause_surfacing` migration registered after `v5_quarantine_ordinal_nullable` (main gained `v4_fts_rowid` and `v5_quarantine_ordinal_nullable` in #214 between this spec and its implementation)".

- [ ] **Step 3: README**

- Line 34: replace "That question is asked once, at the end — a checkpoint along the way stops for an undecided human-judged criterion rather than advancing past it, but leaves the verdict itself for the final gate." with "A checkpoint along the way that stops on an undecided human-judged criterion asks you for the verdict right there, on the checkpoint panel; a verdict you give at a checkpoint is never asked for again."
- Line 37: replace "a 'human-judged' criterion you have not yet decided — which stops the run for your review without putting the verdict to you there; human-judged criteria are still decided at the final gate, and a verdict you have already given is never asked for twice" with "a 'human-judged' criterion you have not yet decided, which stops the run and asks you for the verdict on the checkpoint panel (Approve stays disabled until every human-judged criterion in that milestone is accepted; Send back consumes a rejection so the agent reworks it), and a verdict you have already given is never asked for twice".

- [ ] **Step 4: Code comments**

- `recordCheckpointOutcome`'s doc: remove the sentence that after a restart the human controls "genuinely have no grade to record"; say the evaluation is persisted while a pause is open (#191) so the entry carries the grade after a relaunch too.
- Inside `resolveJudgementIfComplete`, replace the paragraph "Kept deliberately even though nothing opens a checkpoint judgement pause today ... This is the backstop for the day it lands" with "Reachable since #191: `performCheckpoint` opens a judgement pause when the graded evaluation carries a `.humanPending` row, and this branch is its resolution — judge, stay `.pausedForReview`, and leave Approve/Send-back as the next decision."
- Grep once more: `grep -rn "does not ask\|stops without asking\|must stay read-only\|no grade to record\|unreachable" Sources docs README.md | grep -i "checkpoint\|judg"` and fix anything left.

- [ ] **Step 5: Commit**

```bash
git add docs README.md Sources/iris/AppState.swift
git commit -m "docs: a checkpoint asks for humanJudged verdicts — correct D3, README and code comments (#191)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review (done while writing)

- **Spec coverage:** §3 → Task 2; §4 → Task 1 (+ Task 2 for `clearGoal` and the write-scheduled test); §5 → existing `testAdvanceCheckpointClearsJudgementFlag` / `testHoldCheckpointClearsJudgementFlag` in `CheckpointJudgementResolutionTests` already pin both clears individually (verified present; no new task); §6 → Task 4 + Task 5; §7 → Task 4 (`waiverPrecedesJudgement`); §8 → Task 3 (both call sites share `performCheckpoint`; the delegated test pins it); §9/§9.1 → Task 5 (caption, header, no undo is behaviour that falls out of `resolveJudgementIfComplete`, `clearGoal` in Task 2, mid-turn verdict needs no change, accessibility labels, no key equivalent); §10 → existing D3 tests (`testLadderedTerminalPauseCompletes`, `DurableJudgementTests`) remain; §11 → Tasks 1, 2, 3, 4 (every bullet has a named test; "a laddered goal completes through the terminal gate afterwards" is `testLadderedTerminalPauseCompletes`, existing); §12 → Task 6.
- **Placeholders:** Task 3's delegated test intentionally elides the client scripting with an instruction to copy the sibling test in the same file; everything else is complete.
- **Type consistency:** `checkpointApproveBlockers(from:) -> [CriterionVerdict]` (Task 4) is what Task 5 calls; `judgementHandlers(state:conversation:criterionId:)` is defined and called with the same labels; `isolatedApp`, `pausedAtCheckpoint`, `ladder`, `eval`, `pending` are all `static` on the test suite and called as `Self.`.
