# Checkpoint Auto-Advance (slice D3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A checkpoint the grader passes cleanly advances the ladder without stopping the human; anything contested still pauses for review.

**Architecture:** `performCheckpoint` inverts from pause-then-grade to grade-then-decide. A pure predicate on `GoalContract` decides; a new `autoAdvanceCheckpoint` performs the advance without re-arming the goal loop (the turn is still live). Two new persisted fields — `checkpointHistory` (the audit trail slice F will render) and `judgements` on `GoalContract` (durable human verdicts, which a per-checkpoint re-grade would otherwise destroy).

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`).

**Spec:** `docs/specs/2026-09-20-checkpoint-auto-advance.md`

**As-shipped correction (this plan is a historical artifact; the two points below moved after it was written — see spec §11.1):** `checkpointHistory` ended up on `Conversation`, not `GoalContract` — a later fix round found the contract-scoped placement did not outlive `goal_complete`/`clearGoal`, which nils the contract and would have taken the audit trail with it. And `CheckpointOutcome.evaluation` shipped as `GoalEvaluation?`, not the non-optional type Task 1 below writes — a nil grade (nothing to record, e.g. after a restart) is stored as nil rather than synthesizing a fake `.failed` verdict nobody produced. The task bodies below are left as originally written; do not read their code blocks as the current shape of either type.

## Global Constraints

- **Tests use Swift Testing** (`@Suite`, `@Test`, `#expect`). Never XCTest for new tests.
- **Invariant 1:** every new field on a persisted `Codable` uses `decodeIfPresent(...) ?? default` in the custom `init(from:)`. A missing key must never throw — it drops ALL conversations.
- **Invariant 7:** never mutate `ConfigManager.shared` in a test. Pass the flag as an injectable parameter.
- **Invariant 2:** `AppState` is `@Observable`. Never add `@Published`.
- `GoalContract` uses **synthesized `CodingKeys`** — adding a stored property adds its case automatically. Only the decoder needs a new line.
- A grader's submitted verdict on a `humanJudged` criterion is **never** read, and a grader-submitted `human_pending` is **always** downgraded. D2's structural guarantee is not relaxed by any task here.
- House style: short comments explaining *why*, not *what*. No emoji in code or commit messages. Conventional commits.
- **Run `swift test` and READ the output before committing.** Do NOT chain it behind a `grep` with `&&` — a matching grep makes a red suite exit 0.

---

### Task 1: Persisted checkpoint state

**Files:**
- Modify: `Sources/iris/GoalContract.swift`
- Test: `Tests/irisTests/CheckpointHistoryTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `CheckpointOutcome` (with `Resolution` enum), `GoalContract.checkpointHistory: [CheckpointOutcome]`, `GoalContract.judgements: [UUID: Bool]`.

- [ ] **Step 1: Write the failing round-trip test**

Create `Tests/irisTests/CheckpointHistoryTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Slice D3 state. Both new fields are persisted, so invariant 1 applies: a contract encoded
/// before they existed must decode, not throw — a throw fails the whole [Conversation] decode
/// and drops every conversation.
@Suite("Checkpoint history (D3)")
struct CheckpointHistoryTests {

    @Test("a contract with no checkpointHistory or judgements key decodes to empty")
    func testLegacyContractDecodes() throws {
        // A contract as slice B1 would have persisted it: no D3 fields at all.
        let legacy = """
        {"id":"\(UUID().uuidString)","objective":"ship it","criteria":[],"state":"locked"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GoalContract.self, from: legacy)

        #expect(decoded.checkpointHistory.isEmpty)
        #expect(decoded.judgements.isEmpty)
    }

    @Test("checkpoint outcomes survive an encode/decode round trip")
    func testOutcomeRoundTrip() throws {
        let criterion = Criterion(text: "tests pass", kind: .executable, check: "swift test")
        var contract = GoalContract(objective: "ship it", criteria: [criterion])
        let eval = GoalEvaluation(
            status: .graded,
            criteria: [CriterionVerdict(criterionId: criterion.id, criterionText: criterion.text,
                                        kind: .executable, verdict: .met, evidence: "214 passed",
                                        method: .check)],
            startedAt: Date())
        contract.checkpointHistory = [
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "Parser",
                              evaluation: eval, resolution: .autoAdvanced)
        ]
        contract.judgements[criterion.id] = true

        let data = try JSONEncoder().encode(contract)
        let back = try JSONDecoder().decode(GoalContract.self, from: data)

        #expect(back.checkpointHistory.count == 1)
        #expect(back.checkpointHistory[0].resolution == .autoAdvanced)
        #expect(back.checkpointHistory[0].milestoneTitle == "Parser")
        #expect(back.checkpointHistory[0].evaluation.criteria.first?.verdict == .met)
        #expect(back.judgements[criterion.id] == true)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CheckpointHistoryTests`
Expected: FAIL to compile — `cannot find 'CheckpointOutcome' in scope`.

- [ ] **Step 3: Add the type and the fields**

In `Sources/iris/GoalContract.swift`, add above `struct GoalContract`:

```swift
/// Slice D3 — how one checkpoint was resolved, kept for the life of the contract.
/// All three resolutions are recorded, not only auto-advances, so slice F inherits a complete
/// ladder record rather than a partial one.
struct CheckpointOutcome: Codable, Identifiable, Equatable, Sendable {
    enum Resolution: String, Codable, Sendable, Equatable {
        case autoAdvanced     // D3 advanced it; no human saw the verdict
        case humanApproved    // "Approve & continue"
        case humanSentBack    // "Send back"
    }
    var id = UUID()
    var milestoneIndex: Int
    var milestoneTitle: String
    var evaluation: GoalEvaluation
    var resolution: Resolution
    var date: Date = Date()
}
```

Then add the two stored properties to `GoalContract`, next to `waivers`:

```swift
    /// Slice D3 — one entry per resolved checkpoint. The durable audit trail: slice F renders it
    /// and adds retroactive send-back. Lives here rather than beside `lastGoalEvaluation` because
    /// `sanitizeLoaded` deliberately clears that field on load.
    var checkpointHistory: [CheckpointOutcome] = []
    /// Slice D3 — human verdicts on `humanJudged` criteria, by criterion id. `true` = accepted.
    /// Mirrors `waivers`: a durable record of a decision the user made. D2 kept these only in
    /// `lastGoalEvaluation`, which the next grade overwrites — fine when grading happens once at
    /// the terminal gate, fatal once checkpoints grade cumulatively.
    var judgements: [UUID: Bool] = [:]
```

- [ ] **Step 4: Decode them leniently**

In `GoalContract.init(from:)`, after the `waivers` line:

```swift
        checkpointHistory = try c.decodeIfPresent([CheckpointOutcome].self, forKey: .checkpointHistory) ?? []
        judgements = try c.decodeIfPresent([UUID: Bool].self, forKey: .judgements) ?? [:]
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter CheckpointHistoryTests`
Expected: PASS, both tests.

Then run the whole suite and READ the output: `swift test`
Expected: all green. A failure here means a persisted-decode regression — fix before committing.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/GoalContract.swift Tests/irisTests/CheckpointHistoryTests.swift
git commit -m "feat(goal): persist checkpoint outcomes and human judgements (D3)"
```

---

### Task 2: The auto-advance rule

**Files:**
- Modify: `Sources/iris/GoalContract.swift`
- Test: `Tests/irisTests/AutoAdvanceRuleTests.swift` (create)

**Interfaces:**
- Consumes: `GoalContract.judgements`, `GoalContract.checkpointHistory` (Task 1).
- Produces: `GoalContract.canAutoAdvance(from evaluation: GoalEvaluation?) -> Bool`.

This is a pure predicate with no I/O, which is why it gets its own task: every fail-safe branch in spec §4 is testable here without an engine, a grader, or a conversation.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/AutoAdvanceRuleTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Slice D3 §3 and §4. Auto-advance requires an affirmative clean grade; everything else pauses.
@Suite("Auto-advance rule (D3)")
struct AutoAdvanceRuleTests {

    /// A two-milestone ladder sitting on milestone 0, so `isFinalMilestone` is false.
    private func ladder(_ criteria: [Criterion]) -> GoalContract {
        var c = GoalContract(objective: "ship it", criteria: criteria)
        c.milestones = [Milestone(title: "First", criterionIds: criteria.map { $0.id }),
                        Milestone(title: "Last", criterionIds: [])]
        c.currentMilestone = 0
        c.lock()
        return c
    }

    private func eval(_ status: EvaluationStatus,
                      _ verdicts: [CriterionVerdict]) -> GoalEvaluation {
        GoalEvaluation(status: status, criteria: verdicts, startedAt: Date())
    }

    private func verdict(_ c: Criterion, _ v: CriterionVerdictValue,
                         method: VerdictMethod = .judge) -> CriterionVerdict {
        CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                         verdict: v, evidence: "e", method: method)
    }

    @Test("an all-met clean grade advances")
    func testCleanPassAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let contract = ladder([a])
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .met)])) == true)
    }

    @Test("one not_met pauses")
    func testNotMetPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let b = Criterion(text: "b", kind: .qualitative, check: nil)
        let contract = ladder([a, b])
        #expect(contract.canAutoAdvance(
            from: eval(.graded, [verdict(a, .met), verdict(b, .notMet)])) == false)
    }

    @Test("cannot_verify pauses")
    func testCannotVerifyPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let contract = ladder([a])
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .cannotVerify)])) == false)
    }

    @Test("a failed evaluation pauses (fail-safe)")
    func testFailedEvaluationPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let contract = ladder([a])
        #expect(contract.canAutoAdvance(from: eval(.failed, [verdict(a, .met)])) == false)
    }

    @Test("a missing evaluation pauses (fail-safe)")
    func testMissingEvaluationPauses() {
        let contract = ladder([Criterion(text: "a", kind: .qualitative, check: nil)])
        #expect(contract.canAutoAdvance(from: nil) == false)
    }

    @Test("an empty criteria list pauses (fail-safe)")
    func testEmptyCriteriaPauses() {
        let contract = ladder([])
        #expect(contract.canAutoAdvance(from: eval(.graded, [])) == false)
    }

    @Test("an unjudged humanJudged criterion pauses even when everything else is met")
    func testUnjudgedHumanCriterionPauses() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        let contract = ladder([a, h])
        let e = eval(.graded, [verdict(a, .met), verdict(h, .humanPending, method: .human)])
        #expect(contract.canAutoAdvance(from: e) == false)
    }

    @Test("an accepted humanJudged criterion advances")
    func testAcceptedHumanCriterionAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        var contract = ladder([a, h])
        contract.judgements[h.id] = true
        let e = eval(.graded, [verdict(a, .met), verdict(h, .met, method: .human)])
        #expect(contract.canAutoAdvance(from: e) == true)
    }

    @Test("a rejected humanJudged criterion pauses")
    func testRejectedHumanCriterionPauses() {
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        var contract = ladder([h])
        contract.judgements[h.id] = false
        let e = eval(.graded, [verdict(h, .notMet, method: .human)])
        #expect(contract.canAutoAdvance(from: e) == false)
    }

    @Test("a waived criterion counts as resolved")
    func testWaivedCriterionAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        var contract = ladder([a])
        contract.waivers[a.id] = "not applicable on macOS"
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .notMet)])) == true)
    }

    @Test("the final milestone never auto-advances")
    func testFinalMilestoneNeverAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        var contract = ladder([a])
        contract.currentMilestone = 1   // the last index
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .met)])) == false)
    }

    @Test("a contract with no ladder never auto-advances")
    func testNoLadderNeverAdvances() {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship it", criteria: [a])
        contract.lock()
        #expect(contract.canAutoAdvance(from: eval(.graded, [verdict(a, .met)])) == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter AutoAdvanceRuleTests`
Expected: FAIL to compile — `value of type 'GoalContract' has no member 'canAutoAdvance'`.

- [ ] **Step 3: Implement the predicate**

In `Sources/iris/GoalContract.swift`, inside the `GoalContract` extension that holds `blockingCriteria`/`isFinalMilestone`:

```swift
    /// Slice D3 §3 — may this checkpoint advance without stopping the human?
    ///
    /// Affirmative-only: every branch that is not a clean, uncontested grade returns false, so a
    /// grader that errored, timed out, or produced nothing pauses (§4). That fail-safe used to be
    /// structural — `performCheckpoint` paused BEFORE grading — and grading first removes it, so
    /// it is restored here explicitly.
    func canAutoAdvance(from evaluation: GoalEvaluation?) -> Bool {
        guard hasLadder, !isFinalMilestone else { return false }
        guard let evaluation, evaluation.status == .graded, !evaluation.criteria.isEmpty else {
            return false
        }
        return evaluation.criteria.allSatisfy { v in
            // A waiver is an explicit human decision; do not stop them for it twice.
            if waivers[v.criterionId] != nil { return true }
            // Only the user may settle a humanJudged criterion, and only an acceptance clears it.
            // An unjudged one (nil) and a rejected one (false) both block.
            if v.kind == .humanJudged { return judgements[v.criterionId] == true }
            return v.verdict == .met
        }
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter AutoAdvanceRuleTests`
Expected: PASS, all twelve.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/GoalContract.swift Tests/irisTests/AutoAdvanceRuleTests.swift
git commit -m "feat(goal): add the D3 auto-advance predicate with fail-safe defaults"
```

---

### Task 3: Verdict reconciliation reads recorded judgements

**Files:**
- Modify: `Sources/iris/GoalEvaluationParsing.swift`
- Modify: `Sources/iris/GoalEvaluator.swift` (3 call sites: lines ~59, ~61, ~96)
- Test: `Tests/irisTests/GoalEvaluationParsingTests.swift` (add to existing suite)

**Interfaces:**
- Consumes: `GoalContract.judgements` (Task 1).
- Produces: `GoalEvaluationParsing.verdicts(from:criteria:judgements:)` — third parameter defaults to `[:]`, so existing callers are unchanged.

- [ ] **Step 1: Write the failing tests**

Append to the existing suite in `Tests/irisTests/GoalEvaluationParsingTests.swift`:

```swift
    @Test("a recorded acceptance resolves a humanJudged criterion instead of human_pending")
    func testRecordedAcceptanceIsUsed() {
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        let out = GoalEvaluationParsing.verdicts(from: [:], criteria: [h],
                                                 judgements: [h.id: true])
        #expect(out.count == 1)
        #expect(out[0].verdict == .met)
        #expect(out[0].method == .human)
    }

    @Test("a recorded rejection resolves to not_met")
    func testRecordedRejectionIsUsed() {
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        let out = GoalEvaluationParsing.verdicts(from: [:], criteria: [h],
                                                 judgements: [h.id: false])
        #expect(out[0].verdict == .notMet)
        #expect(out[0].method == .human)
    }

    @Test("with no recorded judgement a humanJudged criterion is still human_pending")
    func testUnjudgedStaysPending() {
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        let out = GoalEvaluationParsing.verdicts(from: [:], criteria: [h])
        #expect(out[0].verdict == .humanPending)
        #expect(out[0].method == .human)
    }

    @Test("a grader's verdict on a humanJudged criterion is still ignored when a judgement exists")
    func testGraderCannotOverrideRecordedJudgement() {
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        let args: [String: JSONValue] = ["evaluations": .array([
            .object(["criterion_id": .string(h.id.uuidString),
                     "verdict": .string("not_met"),
                     "evidence": .string("grader says no")])
        ])]
        let out = GoalEvaluationParsing.verdicts(from: args, criteria: [h],
                                                 judgements: [h.id: true])
        #expect(out[0].verdict == .met, "the human accepted it; the grader does not get a vote")
        #expect(out[0].evidence == "", "grader evidence must not attach to a human verdict")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GoalEvaluationParsingTests`
Expected: FAIL to compile — extra argument `judgements` in call.

- [ ] **Step 3: Add the parameter**

In `Sources/iris/GoalEvaluationParsing.swift`, change the signature and the `humanJudged` branch:

```swift
    static func verdicts(from args: [String: JSONValue],
                         criteria: [Criterion],
                         judgements: [UUID: Bool] = [:]) -> [CriterionVerdict] {
```

Replace the `guard c.kind != .humanJudged else { ... }` block with:

```swift
            // A `humanJudged` criterion is the user's to decide, so the grader's answer is not
            // merely unused — it must not be read at all. Taking it would complete the goal
            // `.passed` with nobody having judged (the exact hole D2 closes), and it would then be
            // stamped `method == .human`, announcing a grader's verdict as "your judgement". The
            // prompt forbids grading one twice; this makes it structural, the same way a submitted
            // `human_pending` is downgraded above (spec §4.4, §6).
            //
            // D3: a decision the user already made IS read, from the contract's durable
            // `judgements`. Without that, every checkpoint re-grade would reset the criterion to
            // `human_pending` and ask again for a verdict already given.
            guard c.kind != .humanJudged else {
                let recorded = judgements[c.id]
                let value: CriterionVerdictValue = recorded == nil
                    ? .humanPending
                    : (recorded == true ? .met : .notMet)
                return CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                                        verdict: value, evidence: "", method: .human)
            }
```

- [ ] **Step 4: Pass the contract's judgements at the three call sites**

In `Sources/iris/GoalEvaluator.swift`, all three uses become:

```swift
                    verdicts = GoalEvaluationParsing.verdicts(from: obj, criteria: contract.criteria,
                                                              judgements: contract.judgements)
```

```swift
                    verdicts = GoalEvaluationParsing.verdicts(from: [:], criteria: contract.criteria,
                                                              judgements: contract.judgements)
```

```swift
        let fallback = GoalEvaluationParsing.verdicts(from: [:], criteria: contract.criteria,
                                                      judgements: contract.judgements)
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter GoalEvaluationParsingTests`
Expected: PASS, including the four pre-existing tests (the default argument keeps them behaving identically).

Then `swift test` and READ it. Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/GoalEvaluationParsing.swift Sources/iris/GoalEvaluator.swift Tests/irisTests/GoalEvaluationParsingTests.swift
git commit -m "feat(goal): reconcile humanJudged verdicts from durable judgements (D3)"
```

---

### Task 4: Human judgements write through to the contract

**Files:**
- Modify: `Sources/iris/AppState.swift` (`recordHumanJudgement`)
- Test: `Tests/irisTests/DurableJudgementTests.swift` (create)

**Interfaces:**
- Consumes: `GoalContract.judgements` (Task 1), `verdicts(from:criteria:judgements:)` (Task 3).
- Produces: no new API — `recordHumanJudgement(for:criterionId:accepted:) -> Bool` keeps its signature and additionally persists the decision on the contract.

This is the regression Task 1's field exists to prevent, so it is tested end-to-end through a real re-grade rather than by reading the field back.

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/DurableJudgementTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// D2 recorded a human verdict only in `lastGoalEvaluation`, which the next `beginGoalEvaluation`
/// overwrites and `sanitizeLoaded` clears on load. That is invisible while grading happens once,
/// at the terminal gate. D3 grades at every checkpoint, so the decision has to live on the
/// contract or the user is asked again at every later checkpoint (spec §5.1).
@MainActor
@Suite("Durable judgements (D3)")
struct DurableJudgementTests {

    private func lockedContract(_ app: AppState, _ id: UUID) -> (Criterion, Criterion) {
        let a = Criterion(text: "tests pass", kind: .qualitative, check: nil)
        let h = Criterion(text: "looks right", kind: .humanJudged, check: nil)
        var c = GoalContract(objective: "ship it", criteria: [a, h])
        c.milestones = [Milestone(title: "First", criterionIds: [a.id, h.id]),
                        Milestone(title: "Last", criterionIds: [])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        return (a, h)
    }

    @Test("accepting a criterion records it on the contract, not only the evaluation")
    func testAcceptancePersistsOnContract() {
        let app = AppState(); let id = UUID()
        let (a, h) = lockedContract(app, id)

        let pending = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: a.id, criterionText: a.text, kind: .qualitative,
                             verdict: .met, evidence: "green", method: .judge),
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, pending)
        app.beginJudgementPause(for: id, summary: "done")

        #expect(app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true) == true)

        let contract = app.conversations.first { $0.id == id }?.goalContract
        #expect(contract?.judgements[h.id] == true, "the decision must outlive lastGoalEvaluation")
    }

    @Test("a recorded judgement survives a later re-grade")
    func testJudgementSurvivesRegrade() {
        let app = AppState(); let id = UUID()
        let (a, h) = lockedContract(app, id)

        let pending = GoalEvaluation(status: .graded, criteria: [
            CriterionVerdict(criterionId: h.id, criterionText: h.text, kind: .humanJudged,
                             verdict: .humanPending, evidence: "", method: .human)
        ], startedAt: Date())
        app.recordEvaluation(for: id, pending)
        app.beginJudgementPause(for: id, summary: "done")
        _ = app.recordHumanJudgement(for: id, criterionId: h.id, accepted: true)

        // A later checkpoint grades the projected contract from scratch. Before D3 this reset the
        // criterion to human_pending and asked again.
        let contract = app.conversations.first { $0.id == id }!.goalContract!
        let regraded = GoalEvaluationParsing.verdicts(from: [:], criteria: [a, h],
                                                      judgements: contract.judgements)

        let hv = regraded.first { $0.criterionId == h.id }
        #expect(hv?.verdict == .met, "the re-grade must not discard the user's decision")
        #expect(hv?.method == .human)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DurableJudgementTests`
Expected: FAIL — `contract?.judgements[h.id]` is nil; the re-grade returns `.humanPending`.

- [ ] **Step 3: Write through in `recordHumanJudgement`**

In `Sources/iris/AppState.swift`, inside `recordHumanJudgement`, after mutating `eval.criteria[vIdx]` and before `resolveJudgementIfComplete`:

```swift
        conversations[idx].lastGoalEvaluation = eval
        // D3: also record it on the contract. `lastGoalEvaluation` is transient — the next
        // `beginGoalEvaluation` overwrites it and `sanitizeLoaded` clears it on load — so a
        // checkpoint re-grade would otherwise reset this criterion to `human_pending` and ask the
        // user for a verdict they already gave (spec §5.1).
        conversations[idx].goalContract?.judgements[criterionId] = accepted
        saveConversations()
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter DurableJudgementTests`
Expected: PASS, both.

Then `swift test` and READ it. Expected: all green — in particular the existing D2 suites, which must be unaffected.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/AppState.swift Tests/irisTests/DurableJudgementTests.swift
git commit -m "fix(goal): persist human judgements on the contract so a re-grade cannot discard them"
```

---

### Task 5: Checkpoint state transitions and history recording

**Files:**
- Modify: `Sources/iris/AppState.swift` (`advanceCheckpoint`, `holdCheckpoint`, plus a new method)
- Test: `Tests/irisTests/AutoAdvanceTransitionTests.swift` (create)

**Interfaces:**
- Consumes: `CheckpointOutcome` (Task 1).
- Produces: `AppState.autoAdvanceCheckpoint(for conversationId: UUID)`, and history recording inside `advanceCheckpoint` / `holdCheckpoint`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/AutoAdvanceTransitionTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// The auto path must NOT reuse `advanceCheckpoint`: that ends in `resumeGoalLoop`, which re-arms
/// the auto-reprompt. Auto-advance fires inside a live tool call, so re-arming would run a second
/// loop beside the turn already in flight — the failure #172/#173 fixed for mid-turn steering.
@MainActor
@Suite("Auto-advance transitions (D3)")
struct AutoAdvanceTransitionTests {

    private func laddered(_ app: AppState, _ id: UUID) -> GoalContract {
        let a = Criterion(text: "a", kind: .qualitative, check: nil)
        let b = Criterion(text: "b", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "ship it", criteria: [a, b])
        c.milestones = [Milestone(title: "First", criterionIds: [a.id]),
                        Milestone(title: "Second", criterionIds: [b.id])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
        return app.conversations.first { $0.id == id }!.goalContract!
    }

    private func gradedEval() -> GoalEvaluation {
        GoalEvaluation(status: .graded, criteria: [], startedAt: Date())
    }

    @Test("auto-advance bumps the milestone and leaves the loop running")
    func testAutoAdvanceBumpsAndStaysRunning() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1)
        #expect(c?.checkpointStatus == .running)
    }

    @Test("auto-advance appends an autoAdvanced outcome naming the milestone it left")
    func testAutoAdvanceRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointHistory.count == 1)
        #expect(c?.checkpointHistory.first?.resolution == .autoAdvanced)
        #expect(c?.checkpointHistory.first?.milestoneIndex == 0)
        #expect(c?.checkpointHistory.first?.milestoneTitle == "First")
    }

    @Test("auto-advance does not re-arm the goal loop")
    func testAutoAdvanceDoesNotResume() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        // resumeGoalLoop sets isThinking by starting a turn. The auto path must not.
        #expect(app.isThinking == false, "auto-advance must not start a second loop mid-turn")
    }

    @Test("the human approve path records humanApproved")
    func testApproveRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)
        app.recordEvaluation(for: id, gradedEval())

        app.advanceCheckpoint(for: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointHistory.first?.resolution == .humanApproved)
    }

    @Test("the human send-back path records humanSentBack and does not advance")
    func testSendBackRecordsHistory() {
        let app = AppState(); let id = UUID()
        _ = laddered(app, id)
        app.recordEvaluation(for: id, gradedEval())

        app.holdCheckpoint(for: id, feedback: "not quite")

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointHistory.first?.resolution == .humanSentBack)
        #expect(c?.currentMilestone == 0, "send back keeps working the same milestone")
    }

    @Test("auto-advance on a contract with no ladder does nothing")
    func testNoLadderIsANoOp() {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        var c = GoalContract(objective: "ship it",
                             criteria: [Criterion(text: "a", kind: .qualitative, check: nil)])
        c.milestones = []
        app.setGoalContract(for: id, c)

        app.autoAdvanceCheckpoint(for: id, evaluation: gradedEval())

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.currentMilestone == 0)
        #expect(after?.checkpointHistory.isEmpty == true)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter AutoAdvanceTransitionTests`
Expected: FAIL to compile — `AppState` has no member `autoAdvanceCheckpoint`.

- [ ] **Step 3: Add a shared history recorder and the auto path**

In `Sources/iris/AppState.swift`, directly above `advanceCheckpoint`:

```swift
    /// Appends one entry to the contract's checkpoint history. All three resolutions are recorded,
    /// so slice F inherits a complete ladder record rather than only the skipped checkpoints.
    /// Caller must already hold a valid index; this does not save (its callers do).
    private func recordCheckpointOutcome(at idx: Int, _ resolution: CheckpointOutcome.Resolution,
                                         evaluation: GoalEvaluation?) {
        guard var c = conversations[idx].goalContract, c.hasLadder,
              c.currentMilestone < c.milestones.count else { return }
        // No evaluation means nothing was graded; record the resolution with an empty one rather
        // than dropping the entry, so the ladder record has no silent gaps.
        let eval = evaluation
            ?? GoalEvaluation(status: .failed, criteria: [], startedAt: Date(), completedAt: Date())
        c.checkpointHistory.append(CheckpointOutcome(
            milestoneIndex: c.currentMilestone,
            milestoneTitle: c.milestones[c.currentMilestone].title,
            evaluation: eval,
            resolution: resolution))
        conversations[idx].goalContract = c
    }

    /// Slice D3 — the grader passed this checkpoint cleanly, so advance without stopping the human.
    ///
    /// Deliberately NOT `advanceCheckpoint`: that one ends in `resumeGoalLoop`, which is right for
    /// a human clicking "Approve & continue" after the turn has ended and wrong here. This runs
    /// inside a live `reach_checkpoint` tool call, so re-arming the reprompt would start a second
    /// loop alongside the turn in flight. The engine's multi-round turn carries the agent forward
    /// on the tool result instead.
    func autoAdvanceCheckpoint(for conversationId: UUID, evaluation: GoalEvaluation?) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              let existing = conversations[idx].goalContract, existing.hasLadder else { return }
        recordCheckpointOutcome(at: idx, .autoAdvanced, evaluation: evaluation)
        guard var c = conversations[idx].goalContract else { return }
        c.currentMilestone = min(c.currentMilestone + 1, c.milestones.count - 1)
        c.checkpointStatus = .running
        conversations[idx].goalContract = c
        conversations[idx].goalIterationCount = 0
        saveConversations()
    }
```

- [ ] **Step 4: Record the two human resolutions**

In `advanceCheckpoint`, immediately after the existing `guard`:

```swift
        recordCheckpointOutcome(at: idx, .humanApproved,
                                evaluation: conversations[idx].lastGoalEvaluation)
        guard var c = conversations[idx].goalContract else { return }
```

and delete the `var c` binding from the original guard so it reads the post-record contract. Do the same in `holdCheckpoint` with `.humanSentBack`.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter AutoAdvanceTransitionTests`
Expected: PASS, all six.

Then `swift test` and READ it. Expected: all green, including the existing checkpoint-ladder and B4 suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/AppState.swift Tests/irisTests/AutoAdvanceTransitionTests.swift
git commit -m "feat(goal): add autoAdvanceCheckpoint and record every checkpoint resolution (D3)"
```

---

### Task 6: The `checkpointAutoAdvance` setting

**Files:**
- Modify: `Sources/iris/ConfigManager.swift`
- Test: `Tests/irisTests/CheckpointAutoAdvanceSettingTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `ConfigManager.checkpointAutoAdvance: Bool` (default `true`, key `CHECKPOINT_AUTO_ADVANCE`).

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/CheckpointAutoAdvanceSettingTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Invariant 7: construct an isolated ConfigManager, never mutate ConfigManager.shared.
@Suite("checkpointAutoAdvance setting (D3)")
struct CheckpointAutoAdvanceSettingTests {

    @Test("defaults to true when nothing is stored")
    func testDefaultsOn() {
        let config = ConfigManager()
        #expect(config.checkpointAutoAdvance == true)
    }

    @Test("a stored false is honoured")
    func testStoredFalseHonoured() {
        let config = ConfigManager()
        config.checkpointAutoAdvance = false
        #expect(config.checkpointAutoAdvance == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CheckpointAutoAdvanceSettingTests`
Expected: FAIL to compile — no member `checkpointAutoAdvance`.

- [ ] **Step 3: Add the setting**

In `Sources/iris/ConfigManager.swift`, beside `streamResponses`:

```swift
    /// Slice D3 — when true (the default), a checkpoint the grader passes cleanly advances without
    /// stopping the human. False forces every checkpoint to pause, which is pre-D3 behaviour.
    var checkpointAutoAdvance: Bool {
        didSet { ConfigManager.store.set(checkpointAutoAdvance, forKey: "CHECKPOINT_AUTO_ADVANCE") }
    }
```

and in `init`, following the `STREAM_RESPONSES` pattern exactly:

```swift
        if ConfigManager.store.object(forKey: "CHECKPOINT_AUTO_ADVANCE") != nil {
            self.checkpointAutoAdvance = ConfigManager.store.bool(forKey: "CHECKPOINT_AUTO_ADVANCE")
        } else {
            self.checkpointAutoAdvance = true
        }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter CheckpointAutoAdvanceSettingTests`
Expected: PASS, both.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/ConfigManager.swift Tests/irisTests/CheckpointAutoAdvanceSettingTests.swift
git commit -m "feat(config): add checkpointAutoAdvance, default on (D3)"
```

---

### Task 7: Grade-first `performCheckpoint`

**Files:**
- Modify: `Sources/iris/iris.swift` (`performCheckpoint`)
- Test: `Tests/irisTests/CheckpointAutoAdvanceTests.swift` (create)

**Interfaces:**
- Consumes: `canAutoAdvance(from:)` (Task 2), `autoAdvanceCheckpoint(for:evaluation:)` (Task 5), `ConfigManager.checkpointAutoAdvance` (Task 6), `beginJudgementPause` (existing).
- Produces: the wired behaviour. `performCheckpoint` gains `autoAdvanceEnabled: Bool = ConfigManager.shared.checkpointAutoAdvance` so tests inject it (invariant 7).

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/CheckpointAutoAdvanceTests.swift`. Use the `RoutingClient` pattern from `Tests/irisTests/DelegateMilestoneTests.swift` — read that file first for the fake-client helpers (`delegateCall()`, `response(_:)`, `subagentDone`) and mirror them.

```swift
import Testing
import Foundation
@testable import iris

/// End-to-end D3: reach_checkpoint grades first, then decides.
@MainActor
@Suite("Checkpoint auto-advance (D3)")
struct CheckpointAutoAdvanceTests {

    /// Two-milestone ladder on milestone 0, locked, with one qualitative criterion per milestone.
    private func ladder(on app: AppState, _ id: UUID) {
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
    }

    @Test("a clean grade advances the ladder and does not pause")
    func testCleanGradeAdvances() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1, "a clean checkpoint should advance")
        #expect(c?.checkpointStatus == .running, "a clean checkpoint should not pause")
        #expect(c?.checkpointHistory.first?.resolution == .autoAdvanced)
    }

    @Test("a not_met grade pauses exactly as before")
    func testFailedGradePauses() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("not_met", "parser crashes on nested input"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 0)
        #expect(c?.checkpointStatus == .pausedForReview)
    }

    @Test("the setting off pauses on a grade that would otherwise advance")
    func testSettingOffPauses() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: client, checkpointAutoAdvance: false)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 0)
        #expect(c?.checkpointStatus == .pausedForReview)
    }

    @Test("an unjudged humanJudged criterion pauses and asks for the verdict")
    func testHumanJudgedPausesAndAsks() async {
        let app = AppState(); let id = UUID()
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, h, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id, h.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)

        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.currentMilestone == 0, "an unjudged human criterion must not be skipped")
        #expect(after?.awaitingHumanJudgement == true, "the pause must ask, not just stop")
    }

    @Test("an auto-advance announces itself in the transcript")
    func testAutoAdvanceIsAnnounced() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let messages = app.conversations.first { $0.id == id }?.messages ?? []
        #expect(messages.contains { $0.content.contains("auto-advanced") },
                "a skipped checkpoint must leave an audit trail the user can read")
    }
}
```

Add the `reachCheckpointCall()` helper alongside the `RoutingClient` copy, emitting a
`reach_checkpoint` function call with a `summary` argument.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CheckpointAutoAdvanceTests`
Expected: FAIL — the ladder stays on milestone 0 and `checkpointStatus == .pausedForReview`, because `performCheckpoint` still pauses unconditionally.

- [ ] **Step 3: Thread the setting through the engine**

In `Sources/iris/iris.swift`, add a stored property and init parameter on `IrisEngine`, following `streamResponses`:

```swift
    private let checkpointAutoAdvance: Bool
```

with `checkpointAutoAdvance: Bool = ConfigManager.shared.checkpointAutoAdvance` in the initializer's parameter list and `self.checkpointAutoAdvance = checkpointAutoAdvance` in its body.

- [ ] **Step 4: Invert `performCheckpoint`**

Replace the body of `performCheckpoint` with:

```swift
        let localState = state
        let projected = contract.projectedContract(throughMilestone: contract.currentMilestone)
        let gradeWorkspace = workspacePath ?? FileManager.default.currentDirectoryPath
        await MainActor.run {
            localState?.recordCompletionSelfReport(for: conversationId, statusJSON: statusReport)
            localState?.beginGoalEvaluation(for: conversationId, contract: projected)
        }

        // Grade BEFORE deciding. Until D3 this method paused first, which made pausing the
        // structural default; `canAutoAdvance` is affirmative-only so that default survives the
        // inversion (spec §4).
        var evaluation: GoalEvaluation? = nil
        if let graderApp = localState {
            evaluation = await GoalEvaluator.shared.evaluate(
                contract: projected, workspace: gradeWorkspace,
                originatingConversationId: conversationId, app: graderApp, client: self.client)
        }

        let ladderPos = "\(contract.currentMilestone + 1) of \(contract.milestones.count)"
        let milestoneTitle = contract.milestones[contract.currentMilestone].title

        // Re-read the contract: the grade landed via recordEvaluation, and a judgement may have
        // been recorded since this turn began.
        let current = await MainActor.run {
            localState?.conversations.first(where: { $0.id == conversationId })?.goalContract
        }

        if checkpointAutoAdvance, let current, current.canAutoAdvance(from: evaluation) {
            await MainActor.run {
                localState?.autoAdvanceCheckpoint(for: conversationId, evaluation: evaluation)
            }
            let met = evaluation?.criteria.count ?? 0
            let lines = (evaluation?.criteria ?? [])
                .map { "  \($0.criterionText) — \($0.evidence)" }
                .joined(separator: "\n")
            await pushToUI(role: .system,
                           text: "Checkpoint \(ladderPos) (\(milestoneTitle)) auto-advanced — grader found \(met)/\(met) criteria met:\n\(lines)",
                           conversationId: conversationId)
            return "Checkpoint \(ladderPos) passed cleanly and advanced. Continue with the next milestone."
        }

        await MainActor.run {
            localState?.setCheckpointPaused(for: conversationId)   // leaves activeGoal set
            // An unjudged humanJudged criterion is why this stopped, so the pause must ASK.
            // A stop that requests nothing is the rubber-stamp pattern D3 exists to remove.
            if let c = current,
               c.criteria.contains(where: { $0.kind == .humanJudged && c.judgements[$0.id] == nil }) {
                localState?.beginJudgementPause(for: conversationId, summary: summary)
            }
        }
        await pushToUI(role: .agent,
                       text: "Reached checkpoint \(ladderPos)\(via): \(summary)\nPaused for your review — approve to continue or send me back.",
                       conversationId: conversationId)
        return "Checkpoint \(ladderPos) reached and graded. Paused for user review."
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter CheckpointAutoAdvanceTests`
Expected: PASS, all five.

- [ ] **Step 6: Run the whole suite and READ the output**

Run: `swift test`
Expected: all green. Pay attention to `DelegateMilestoneTests` — B4 reaches `performCheckpoint` through `delegate_milestone`, and `completedSubagentReachesCheckpoint` asserts `checkpointStatus == .pausedForReview`. Under D3 a clean grade now advances instead, so that test's contract must be adjusted to a contested grade (keeping its original intent: a completed subagent reaches the checkpoint) or a sibling test added for the clean case. Do NOT simply delete the assertion — state in the commit which you did and why.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/iris.swift Tests/irisTests/CheckpointAutoAdvanceTests.swift Tests/irisTests/DelegateMilestoneTests.swift
git commit -m "feat(goal): grade checkpoints first and auto-advance a clean pass (D3)"
```

---

### Task 8: README and AGENTS.md

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: everything above. No code.

- [ ] **Step 1: Document the behaviour in README.md**

Find the goal/checkpoint section and add: a checkpoint the grader passes cleanly now advances on its own; anything contested — a failed or unverifiable criterion, or a `humanJudged` one you have not decided — still pauses. Mention the Settings toggle and that turning it off restores a pause at every checkpoint.

- [ ] **Step 2: Add the durable-judgement note to AGENTS.md**

Under "Things that have bitten us":

```markdown
- **A transient field holding a durable decision.** D2 recorded human verdicts only in `lastGoalEvaluation`, which the next `beginGoalEvaluation` overwrites and `sanitizeLoaded` clears on load. That was invisible while grading happened once, at the terminal gate; D3's per-checkpoint grading would have destroyed a judgement and asked the user again. Durable decisions live on `GoalContract` (`waivers`, `judgements`), never on the transient surfacing fields.
```

- [ ] **Step 3: Verify and commit**

Run: `swift test`
Expected: all green (docs-only change; this is a guard against an accidental edit).

```bash
git add README.md AGENTS.md
git commit -m "docs: record checkpoint auto-advance and the durable-decision rule (D3)"
```

---

## Self-Review

**1. Spec coverage**

| Spec section | Task |
|---|---|
| §3 the rule | Task 2 |
| §4 fail-safe | Task 2 (tests), Task 7 (inversion) |
| §5 checkpointHistory | Tasks 1, 5 |
| §5.1 durable judgements | Tasks 1, 3, 4 |
| §6 humanJudged at a checkpoint | Tasks 2, 4, 7 |
| §7 control flow | Task 7 |
| §7.1 reconciliation | Task 3 |
| §8 system event | Task 7 |
| §9 setting | Tasks 6, 7 |
| §10 interaction constraints | Task 2 (final milestone, no ladder), Task 7 (B4, judgement pause) |
| §11 testing | Tasks 1-7 |

No gaps.

**2. Placeholder scan** — every code step carries real code. Task 7 Step 1 points at `DelegateMilestoneTests` for the `RoutingClient` helpers rather than reproducing ~60 lines of fake-client scaffolding; that is a pointer to a concrete file to copy, not a "figure it out".

**3. Type consistency** — `canAutoAdvance(from:)` takes `GoalEvaluation?` in Tasks 2 and 7. `autoAdvanceCheckpoint(for:evaluation:)` takes the same optional in Tasks 5 and 7. `verdicts(from:criteria:judgements:)` is consistent across Tasks 3 and 4. `CheckpointOutcome.Resolution` cases are `.autoAdvanced` / `.humanApproved` / `.humanSentBack` throughout.

**One known-flagged consequence:** Task 7 Step 6 changes an existing B4 test. That is a real behaviour change, not a test fix — a delegated milestone that grades clean now advances instead of pausing — and the plan requires the implementer to say which way they resolved it rather than quietly dropping the assertion.
