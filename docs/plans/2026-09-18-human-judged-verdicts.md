# Interactive Human-Judged Verdicts (slice D2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `humanJudged` criterion can finally fail a goal. When it is the only thing outstanding, the goal pauses; the user accepts or rejects inline in the completion report; accepts complete the goal, rejects send the agent back to work.

**Architecture:** A separate `awaitingHumanJudgement` flag (not a `CheckpointStatus` case) plus a computed `isPaused` that replaces the status check at exactly the two sites meaning "suppress the loop". Judgement is a UI action calling `AppState` — no new tool. Resuming re-evaluates without re-running the grader.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`). No new dependencies.

**Spec:** [docs/specs/2026-09-18-human-judged-verdicts.md](../specs/2026-09-18-human-judged-verdicts.md)

## Global Constraints

- **AGENTS.md invariant 1 — `decodeIfPresent`.** `GoalContract` has a custom `init(from:)`; add there. A missing key must not throw, or the whole `[Conversation]` decode fails and drops every conversation.
- **AGENTS.md invariant 6 — tool exposure.** This slice adds **no tool**, deliberately (spec §2). If you find yourself writing a `FunctionDeclaration`, stop: the model must not be able to record a human's judgement.
- **AGENTS.md invariant 7 — never mutate `ConfigManager.shared` in a test.** Inject an isolated `ConfigManager()` or use an injectable parameter.
- **`AppState` is `@Observable`** — no `@Published`.
- **`isPaused` replaces `checkpointStatus == .pausedForReview` at exactly TWO sites** (`iris.swift:136` resume guard, `iris.swift:929-932` reprompt guard). Every other reader is asking a ladder question and must be left alone. In particular `ChatView` suppresses the completion chip on that status, and that chip hosts this slice's buttons.
- **Swift Testing only.** Never XCTest.
- **Run `swift test` and read the result before every commit** — never chained behind a `grep` with `&&`. Baseline on `main`: **628 tests in 130 suites**, parallel, ~2.0s.
- **Conventional commits**, no emoji, co-credit the model in the trailer.

---

### Task 1: The pause flag and `isPaused`

**Files:**
- Modify: `Sources/iris/GoalContract.swift` (one stored property, memberwise init, one `decodeIfPresent` line, one computed property)
- Modify: `Sources/iris/iris.swift` (two guard sites only)
- Test: `Tests/irisTests/HumanJudgementStateTests.swift` (create)

**Interfaces:**
- Produces: `GoalContract.awaitingHumanJudgement: Bool`, `GoalContract.isPaused: Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/HumanJudgementStateTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// D2's pause state. Deliberately NOT a CheckpointStatus case: that status drives ladder UI in 13
/// places, and ChatView suppresses the completion chip while it is set — which is exactly where
/// this slice's Accept/Reject buttons live (spec §5).
@Suite("Human judgement state (D2)")
struct HumanJudgementStateTests {
    @Test("isPaused covers a checkpoint pause")
    func checkpointPauseIsPaused() {
        var c = GoalContract(objective: "ship", criteria: [])
        c.checkpointStatus = .pausedForReview
        #expect(c.isPaused)
    }

    @Test("isPaused covers a judgement pause")
    func judgementPauseIsPaused() {
        var c = GoalContract(objective: "ship", criteria: [])
        c.awaitingHumanJudgement = true
        #expect(c.isPaused)
    }

    @Test("a running goal is not paused")
    func runningIsNotPaused() {
        let c = GoalContract(objective: "ship", criteria: [])
        #expect(!c.isPaused)
        #expect(!c.awaitingHumanJudgement)
    }

    @Test("a judgement pause does NOT set the checkpoint status")
    func judgementPauseLeavesCheckpointStatusAlone() {
        var c = GoalContract(objective: "ship", criteria: [])
        c.awaitingHumanJudgement = true
        // If this ever flips, ChatView hides the completion chip and the buttons vanish.
        #expect(c.checkpointStatus == .running)
    }

    @Test("the flag round-trips, and a pre-D2 contract decodes false")
    func codable() throws {
        var c = GoalContract(objective: "ship", criteria: [])
        c.awaitingHumanJudgement = true
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(c))
        #expect(back.awaitingHumanJudgement)

        let legacy: [String: Any] = [
            "objective": "ship",
            "criteria": [["id": UUID().uuidString, "text": "builds", "kind": "qualitative"]],
            "state": "locked"
        ]
        let old = try JSONDecoder().decode(
            GoalContract.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!old.awaitingHumanJudgement)
        #expect(old.objective == "ship")
    }

    @Test("a Conversation carrying a pre-D2 contract still decodes")
    func legacyConversationDecodes() throws {
        var conv = Conversation(title: "old")
        conv.goalContract = GoalContract(objective: "ship", criteria: [])
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.goalContract?.awaitingHumanJudgement == false)
        #expect(back.title == "old")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter HumanJudgementStateTests`
Expected: compile failure — `value of type 'GoalContract' has no member 'awaitingHumanJudgement'`.

- [ ] **Step 3: Add the field and the computed property**

In `Sources/iris/GoalContract.swift`, add a stored property beside `workspace`:

```swift
    /// Slice D2 — the goal is paused waiting for the user to judge its `humanJudged` criteria.
    /// Deliberately separate from `checkpointStatus`: that drives ladder UI in a dozen places, and
    /// `ChatView` suppresses the completion chip while it is `.pausedForReview` — which is exactly
    /// where this slice's Accept/Reject buttons live (spec §5).
    var awaitingHumanJudgement: Bool = false
```

Add it to the memberwise `init` (defaulting false) and to `init(from:)`:

```swift
        awaitingHumanJudgement = try c.decodeIfPresent(Bool.self, forKey: .awaitingHumanJudgement) ?? false
```

Add the computed property beside `isLocked`:

```swift
    /// True when the goal loop must stay quiet: a checkpoint pause (B1) or a judgement pause (D2).
    /// Only loop-control sites should use this — every UI reader of `checkpointStatus` is asking a
    /// ladder question and must keep asking it.
    var isPaused: Bool { checkpointStatus == .pausedForReview || awaitingHumanJudgement }
```

- [ ] **Step 4: Switch the two loop-control sites**

In `Sources/iris/iris.swift`, the resume-on-restart guard (~L136):

```swift
                      conv.goalContract?.isPaused != true,
```

and the auto-reprompt guard (~L929):

```swift
        let paused = await MainActor.run {
            localState?.conversations.first(where: { $0.id == conversationId })?.goalContract?.isPaused == true
        }
        if let _ = activeGoalResult.0, !paused {
```

**Change nothing else.** `grep -n "pausedForReview" Sources/iris/*.swift` should still show every UI reader untouched.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter HumanJudgementStateTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 634 tests. `ReachCheckpointHandlerTests` and `GoalCheckpointStateTests` exercise the guards you just changed and must still pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/GoalContract.swift Sources/iris/iris.swift Tests/irisTests/HumanJudgementStateTests.swift
git commit -m "feat(goal): a judgement pause, separate from the checkpoint pause

isPaused replaces the status check at the two loop-control sites only; every UI
reader of checkpointStatus is asking a ladder question and keeps asking it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Recording a judgement

**Files:**
- Modify: `Sources/iris/AppState.swift` (`recordHumanJudgement`)
- Test: `Tests/irisTests/HumanJudgementRecordingTests.swift` (create)

**Interfaces:**
- Produces: `AppState.recordHumanJudgement(for:criterionId:accepted:) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/HumanJudgementRecordingTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Recording one accept/reject onto the stored evaluation (spec §6). `VerdictMethod.human` has
/// existed since slice C and has never been used; this is what finally uses it.
@MainActor
@Suite("Human judgement recording (D2)")
struct HumanJudgementRecordingTests {
    private func pausedGoal(on app: AppState, _ id: UUID) -> Criterion {
        app.createNewConversation(id: id)
        let judged = Criterion(text: "the design reads well", kind: .humanJudged, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [judged])
        contract.awaitingHumanJudgement = true
        app.setGoalContract(for: id, contract)
        // Mark it awaiting again: setGoalContract locks a normalized copy.
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].goalContract?.awaitingHumanJudgement = true
        }
        app.recordEvaluation(for: id, GoalEvaluation(
            status: .graded,
            criteria: [CriterionVerdict(criterionId: judged.id, criterionText: judged.text,
                                        kind: .humanJudged, verdict: .humanPending,
                                        evidence: "", method: .human)],
            startedAt: Date(), completedAt: Date()))
        return judged
    }

    @Test("accepting records met, attributed to the human")
    func acceptRecordsMet() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)

        #expect(app.recordHumanJudgement(for: id, criterionId: c.id, accepted: true))

        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .met)
        #expect(v?.method == .human, "a human accept must never look like grader-verified evidence")
    }

    @Test("rejecting records not_met, attributed to the human")
    func rejectRecordsNotMet() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)

        #expect(app.recordHumanJudgement(for: id, criterionId: c.id, accepted: false))

        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .notMet)
        #expect(v?.method == .human)
    }

    @Test("a judgement on a goal that is not paused is ignored")
    func staleJudgementIgnored() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].goalContract?.awaitingHumanJudgement = false
        }

        #expect(!app.recordHumanJudgement(for: id, criterionId: c.id, accepted: true),
                "a stale click after /stop or completion must not rewrite a verdict")
        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .humanPending)
    }

    @Test("an unknown criterion id is refused")
    func unknownIdRefused() {
        let app = AppState()
        let id = UUID()
        _ = pausedGoal(on: app, id)
        #expect(!app.recordHumanJudgement(for: id, criterionId: UUID(), accepted: true))
    }

    @Test("a criterion that is not awaiting judgement is refused")
    func alreadyJudgedIsRefused() {
        let app = AppState()
        let id = UUID()
        let c = pausedGoal(on: app, id)
        #expect(app.recordHumanJudgement(for: id, criterionId: c.id, accepted: true))
        // Second click on the same row must not flip an already-recorded judgement.
        #expect(!app.recordHumanJudgement(for: id, criterionId: c.id, accepted: false))
        let v = app.conversations.first { $0.id == id }?
            .lastGoalEvaluation?.criteria.first { $0.criterionId == c.id }
        #expect(v?.verdict == .met)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter HumanJudgementRecordingTests`
Expected: compile failure — `value of type 'AppState' has no member 'recordHumanJudgement'`.

- [ ] **Step 3: Implement**

In `Sources/iris/AppState.swift`, beside `finishGatedGoal`:

```swift
    /// Record the user's verdict on one `humanJudged` criterion (spec §6).
    ///
    /// Returns false when the judgement does not apply: the goal is not awaiting judgement (a
    /// stale click after `/stop` or completion), the criterion is unknown, or it is not actually
    /// `human_pending` — a second click must not flip a verdict already given.
    ///
    /// `method` stays `.human`, so the row can render "met — your judgement" and never be mistaken
    /// for grader-verified evidence.
    @discardableResult
    func recordHumanJudgement(for conversationId: UUID, criterionId: UUID, accepted: Bool) -> Bool {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].goalContract?.awaitingHumanJudgement == true,
              var eval = conversations[idx].lastGoalEvaluation,
              let vIdx = eval.criteria.firstIndex(where: {
                  $0.criterionId == criterionId && $0.verdict == .humanPending
              })
        else { return false }

        eval.criteria[vIdx].verdict = accepted ? .met : .notMet
        eval.criteria[vIdx].method = .human
        conversations[idx].lastGoalEvaluation = eval
        saveConversations()
        return true
    }
```

If `CriterionVerdict`'s properties are `let`, change `verdict` and `method` to `var` — they are a value type inside an array and must be mutable to record a judgement.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter HumanJudgementRecordingTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 639 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/GoalEvaluation.swift Tests/irisTests/HumanJudgementRecordingTests.swift
git commit -m "feat(goal): record a human verdict on a humanJudged criterion

Attributed with VerdictMethod.human, which has existed since slice C and has
never been used until now.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The gate pauses for judgement

**Files:**
- Modify: `Sources/iris/GoalContract.swift` (`pendingJudgement(from:)`)
- Modify: `Sources/iris/AppState.swift` (`beginJudgementPause`)
- Modify: `Sources/iris/iris.swift` (the gate block, ~L1115-1141)
- Test: `Tests/irisTests/HumanJudgementGateTests.swift` (create)

**Interfaces:**
- Consumes: `awaitingHumanJudgement` (Task 1), `blockingCriteria(from:)` (D1)
- Produces: `GoalContract.pendingJudgement(from:) -> [CriterionVerdict]`, `AppState.beginJudgementPause(for:)`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/HumanJudgementGateTests.swift`. It reuses D1's scripted-grader pattern: the grader lane is the engine whose toolset offers `submit_evaluation`, and it synthesises verdicts from the criterion ids in its own system prompt, because `GoalEvaluationParsing` reconciles strictly by id.

```swift
import Testing
import Foundation
@testable import iris

/// The gate's judgement pause (spec §3, §4). Agent-fixable problems come first; a judgement pause
/// happens only when nothing else blocks, and it never burns a retry.
@MainActor
@Suite("Human judgement gate (D2)", .serialized)
struct HumanJudgementGateTests {
    final class GateClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let idPattern = /id ([0-9A-Fa-f-]{36}) \[[a-zA-Z]+\] ([^\n]*)/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderRuns = 0
        private let mainScript: [GeminiResponse]
        private let graderVerdicts: [String: String]

        init(main: [GeminiResponse], graderVerdicts: [String: String]) {
            self.mainScript = main
            self.graderVerdicts = graderVerdicts
        }
        var graderRunCount: Int { lock.withLock { graderRuns } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let offersSubmit = request.tools?.contains {
                $0.functionDeclarations.contains { $0.name == "submit_evaluation" }
            } ?? false
            let systemText = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            return lock.withLock {
                if offersSubmit {
                    graderRuns += 1
                    let entries = systemText.matches(of: Self.idPattern).map {
                        (id: String($0.output.1),
                         text: String($0.output.2).trimmingCharacters(in: .whitespaces))
                    }
                    // A humanJudged criterion is omitted entirely; parsing assigns human_pending.
                    let graded = entries.compactMap { e -> JSONValue? in
                        guard let v = graderVerdicts[e.text] else { return nil }
                        return .object(["criterion_id": .string(e.id), "verdict": .string(v),
                                        "evidence": .string("grader saw: \(e.text)")])
                    }
                    let part = Part(text: nil,
                                    functionCall: FunctionCall(name: "submit_evaluation",
                                                               args: ["evaluations": .array(graded)],
                                                               id: nil, thought_signature: nil,
                                                               thoughtSignature: nil),
                                    functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
                    return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                          usageMetadata: nil)
                }
                let i = mainIndex
                mainIndex += 1
                return mainScript[min(i, mainScript.count - 1)]
            }
        }
    }

    static func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "ok" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    static func goalComplete() -> GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string("done")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// A locked contract with one machine criterion and one human-judged criterion.
    @discardableResult
    func lockMixedContract(on app: AppState, _ id: UUID) -> (machine: Criterion, judged: Criterion) {
        app.createNewConversation(id: id)
        let machine = Criterion(text: "builds", kind: .qualitative, check: nil)
        let judged = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship it", criteria: [machine, judged]))
        return (machine, judged)
    }

    @Test("a human_pending criterion alone pauses, without burning a retry")
    func pausesWithoutRetrying() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockMixedContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["builds": "met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement == true)
        #expect(conv?.activeGoal != nil, "the goal stays alive while it waits for you")
        #expect(conv?.goalContract?.gateAttempts == 0,
                "a retry cap bounds an agent that might fix something; this is not that")
        #expect(client.graderRunCount == 1)
    }

    @Test("an agent-fixable failure comes first — no judgement pause while not_met is outstanding")
    func notMetTakesPriority() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockMixedContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["builds": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement != true,
                "do not ask for judgement on a goal that is about to change underneath the user")
        #expect(conv?.goalContract?.gateAttempts == 1, "this one IS the agent's to fix")
    }

    @Test("a failed grader never triggers a judgement pause")
    func failedGraderDoesNotPause() {
        // A .failed evaluation's verdicts are placeholders (#54's treatment), so a human_pending
        // among them is not a genuine request for judgement — asking the user to rule on a grade
        // that never happened would be theatre.
        let judged = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let contract = GoalContract(objective: "ship", criteria: [judged])
        let failed = GoalEvaluation(
            status: .failed,
            criteria: [CriterionVerdict(criterionId: judged.id, criterionText: judged.text,
                                        kind: .humanJudged, verdict: .humanPending,
                                        evidence: "", method: .human)],
            startedAt: Date(), completedAt: Date())
        #expect(contract.pendingJudgement(from: failed).isEmpty)
    }

    @Test("a contract with no humanJudged criteria never pauses")
    func noJudgedCriteriaNeverPauses() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        let c = Criterion(text: "builds", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [c]))
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["builds": "met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "D1's behaviour, unchanged")
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .passed)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter HumanJudgementGateTests`
Expected: `pausesWithoutRetrying` FAILS — `awaitingHumanJudgement` is nil/false because the gate completes the goal (D1 lets `human_pending` pass). The other two pass already; they are pinning behaviour that must not change.

- [ ] **Step 3: Add the pending-judgement query**

Append to the `GoalContract` extension in `Sources/iris/GoalContract.swift`:

```swift
    /// Criteria still awaiting the user's verdict (slice D2 §3).
    ///
    /// Only on a real grade: a `.failed` evaluation's values are placeholders, so a `human_pending`
    /// among them is not a genuine request for judgement.
    func pendingJudgement(from evaluation: GoalEvaluation) -> [CriterionVerdict] {
        guard evaluation.status == .graded else { return [] }
        return evaluation.criteria.filter { $0.verdict == .humanPending }
    }
```

- [ ] **Step 4: Add the pause transition**

In `Sources/iris/AppState.swift`, beside `recordGateRefusal`:

```swift
    /// Park the goal until the user judges its `humanJudged` criteria (spec §4). Deliberately does
    /// NOT touch `gateAttempts`: the agent cannot satisfy these by working, so spending a retry on
    /// them would burn the cap on an outcome it provably cannot change.
    func beginJudgementPause(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var c = conversations[idx].goalContract else { return }
        c.awaitingHumanJudgement = true
        conversations[idx].goalContract = c
        saveConversations()
    }
```

- [ ] **Step 5: Wire it into the gate**

In `Sources/iris/iris.swift`, inside the gate block, **after** D1's refuse-and-retry branch and **before** the `let outcome: GateOutcome` line:

```swift
                // Slice D2 — judgement pause. Reached only when nothing agent-fixable is
                // outstanding (the refusal above returns first), so the user is never asked to
                // judge a goal that is about to change underneath them.
                let awaitingJudgement = c.pendingJudgement(from: evaluation)
                if blocking.isEmpty, !awaitingJudgement.isEmpty {
                    await MainActor.run { localState?.beginJudgementPause(for: conversationId) }
                    let lines = awaitingJudgement.map { "- \($0.criterionText)" }.joined(separator: "\n")
                    return """
                    Paused for the user's judgement. \(awaitingJudgement.count) criteri\(awaitingJudgement.count == 1 ? "on is" : "a are") human-judged and only they can decide:
                    \(lines)

                    Do not call goal_complete again — the run resumes on its own once they answer.
                    """
                }
```

The goal is **not** cleared and `gateAttempts` is untouched. The `isPaused` guard from Task 1 keeps the reprompt loop quiet.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter HumanJudgementGateTests`
Expected: PASS, 4 tests.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 643 tests. `DoneGateHandlerTests` and `DoneGateScopeTests` exercise the block you just edited and must still pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/GoalContract.swift Sources/iris/AppState.swift Sources/iris/iris.swift Tests/irisTests/HumanJudgementGateTests.swift
git commit -m "feat(goal): pause for human judgement instead of retrying

Agent-fixable failures come first. A judgement pause never burns a retry: the
agent cannot satisfy a humanJudged criterion by working.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Resuming after the last judgement

**Files:**
- Modify: `Sources/iris/AppState.swift` (`resolveJudgementIfComplete`, called from `recordHumanJudgement`)
- Test: `Tests/irisTests/HumanJudgementResumeTests.swift` (create)

**Interfaces:**
- Consumes: `recordHumanJudgement` (Task 2), `beginJudgementPause` (Task 3), `finishGatedGoal` (D1)
- Produces: resume behaviour — no new public API

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/HumanJudgementResumeTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// What happens when the last judgement lands (spec §7). The grader is NOT re-run: the verdicts
/// are already in hand, and re-running would overwrite the user's decision with a fresh
/// human_pending.
@MainActor
@Suite("Human judgement resume (D2)")
struct HumanJudgementResumeTests {
    private func pausedGoal(on app: AppState, _ id: UUID, judged: Int) -> [Criterion] {
        app.createNewConversation(id: id)
        let machine = Criterion(text: "builds", kind: .qualitative, check: nil)
        let judgedCriteria = (0..<judged).map {
            Criterion(text: "human call \($0)", kind: .humanJudged, check: nil)
        }
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [machine] + judgedCriteria))
        app.beginJudgementPause(for: id)
        app.recordEvaluation(for: id, GoalEvaluation(
            status: .graded,
            criteria: [CriterionVerdict(criterionId: machine.id, criterionText: machine.text,
                                        kind: .qualitative, verdict: .met, evidence: "ok", method: .judge)]
                + judgedCriteria.map {
                    CriterionVerdict(criterionId: $0.id, criterionText: $0.text, kind: .humanJudged,
                                     verdict: .humanPending, evidence: "", method: .human)
                },
            startedAt: Date(), completedAt: Date()))
        return judgedCriteria
    }

    @Test("accepting the last outstanding criterion completes the goal")
    func lastAcceptCompletes() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 1)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "all criteria resolved — the goal is done")
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .passed)
    }

    @Test("judging one of several leaves the goal paused")
    func partialJudgementStaysPaused() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 2)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement == true)
        #expect(conv?.activeGoal != nil)
    }

    @Test("a rejection sends the agent back to work rather than completing")
    func rejectionResumesTheAgent() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 1)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: false)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement == false, "the pause is over")
        #expect(conv?.activeGoal != nil, "but the goal is not — the agent has work to do")
        #expect(conv?.goalContract?.gateAttempts == 0,
                "the agent has not yet had a chance to respond, so it has not used an attempt")
    }

    @Test("a mixed verdict resumes the agent, it does not complete")
    func mixedVerdictResumes() {
        let app = AppState()
        let id = UUID()
        let judged = pausedGoal(on: app, id, judged: 2)

        app.recordHumanJudgement(for: id, criterionId: judged[0].id, accepted: true)
        app.recordHumanJudgement(for: id, criterionId: judged[1].id, accepted: false)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal != nil, "one rejection is enough to send it back")
        #expect(conv?.goalContract?.awaitingHumanJudgement == false)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter HumanJudgementResumeTests`
Expected: `lastAcceptCompletes`, `rejectionResumesTheAgent`, and `mixedVerdictResumes` FAIL — recording a judgement currently changes a verdict and nothing else. `partialJudgementStaysPaused` passes already.

- [ ] **Step 3: Implement the resume**

In `Sources/iris/AppState.swift`, add at the end of `recordHumanJudgement`, before `return true`:

```swift
        resolveJudgementIfComplete(for: conversationId)
```

and add the helper beside it:

```swift
    /// Once nothing is `human_pending`, act on what the user decided (spec §7).
    ///
    /// The grader is deliberately NOT re-run: its verdicts are already in hand, and a second run
    /// would spend minutes re-deriving them AND overwrite the user's judgement with a fresh
    /// `human_pending`.
    private func resolveJudgementIfComplete(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].goalContract?.awaitingHumanJudgement == true,
              let eval = conversations[idx].lastGoalEvaluation,
              !eval.criteria.contains(where: { $0.verdict == .humanPending })
        else { return }

        conversations[idx].goalContract?.awaitingHumanJudgement = false
        let rejected = eval.criteria.filter { $0.verdict == .notMet }

        if rejected.isEmpty {
            // Everything the user was asked about passed, and nothing else was blocking when we
            // paused — so the gate is satisfied.
            let waivers = conversations[idx].goalContract?.waivers ?? [:]
            finishGatedGoal(for: conversationId, outcome: .passed, waivers: waivers)
            clearGoal(for: conversationId)
            appendMessage(role: .system, content: "Goal complete — your judgement resolved the last criteria.",
                          to: conversationId)
        } else {
            // A rejection is something the agent CAN act on. Hand it back with the reasons named.
            let names = rejected.map { "- \($0.criterionText)" }.joined(separator: "\n")
            saveConversations()
            resumeGoalLoop(for: conversationId,
                           steer: "You did not meet these, in the user's judgement:\n\(names)")
            return
        }
        saveConversations()
    }
```

If `resumeGoalLoop` is `private`, reuse it as-is — it is already the B1 resume path and takes a steer string. If its signature differs, adapt the call rather than duplicating the reprompt logic.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter HumanJudgementResumeTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 647 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/AppState.swift Tests/irisTests/HumanJudgementResumeTests.swift
git commit -m "feat(goal): resume once the last judgement lands

Accepts complete the goal; a rejection hands it back to the agent with the
reasons named. The grader is not re-run — that would overwrite the judgement
the user just gave.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Accept / Reject in the completion report

**Files:**
- Modify: `Sources/iris/GoalContractPanel.swift` (`DriftCriterionRow`, and the `CompletionReportSection` call site)
- Test: `Tests/irisTests/HumanJudgementRowTests.swift` (create)

**Interfaces:**
- Produces: `GoalWorkspace`-style pure helper `CriterionVerdict.humanJudgementLabel` for the row's text

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/HumanJudgementRowTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// The row's wording. Kept out of the view so it is testable without a SwiftUI harness — and
/// because the distinction it draws is the point of the slice (spec §6).
@Suite("Human judgement row (D2)")
struct HumanJudgementRowTests {
    private func verdict(_ v: CriterionVerdictValue, _ m: VerdictMethod) -> CriterionVerdict {
        CriterionVerdict(criterionId: UUID(), criterionText: "reads well", kind: .humanJudged,
                         verdict: v, evidence: "", method: m)
    }

    @Test("a human accept is labelled as the user's judgement, not as verified")
    func humanMetIsLabelled() {
        let label = verdict(.met, .human).humanJudgementLabel
        #expect(label?.lowercased().contains("judgement") == true)
    }

    @Test("a human rejection is labelled too")
    func humanNotMetIsLabelled() {
        #expect(verdict(.notMet, .human).humanJudgementLabel != nil)
    }

    @Test("a grader verdict carries no judgement label")
    func graderVerdictIsUnlabelled() {
        #expect(verdict(.met, .judge).humanJudgementLabel == nil)
        #expect(verdict(.met, .check).humanJudgementLabel == nil)
    }

    @Test("an unjudged criterion carries no label — the buttons speak for it")
    func pendingIsUnlabelled() {
        #expect(verdict(.humanPending, .human).humanJudgementLabel == nil)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter HumanJudgementRowTests`
Expected: compile failure — `value of type 'CriterionVerdict' has no member 'humanJudgementLabel'`.

- [ ] **Step 3: Implement the label**

Append to `Sources/iris/GoalEvaluation.swift`:

```swift
extension CriterionVerdict {
    /// How to mark a verdict the USER gave, so it is never mistaken for grader-verified evidence
    /// (spec §6). nil for anything the grader decided, and for one still awaiting judgement — the
    /// buttons speak for that.
    var humanJudgementLabel: String? {
        guard method == .human else { return nil }
        switch verdict {
        case .met:    return "met — your judgement"
        case .notMet: return "not met — your judgement"
        default:      return nil
        }
    }
}
```

- [ ] **Step 4: Render the buttons and the label**

In `Sources/iris/GoalContractPanel.swift`, `DriftCriterionRow` gains two optional closures so the row stays reusable and the checkpoint pause view (which passes neither) is unaffected:

```swift
    /// Slice D2 — supplied only by the completion report while the goal awaits judgement.
    var onAccept: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil
```

Under the evidence line, add:

```swift
            if let label = verdict.humanJudgementLabel {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if verdict.verdict == .humanPending, let onAccept, let onReject {
                HStack(spacing: 8) {
                    Button("Accept", action: onAccept)
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                    Button("Reject", action: onReject)
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                }
                .font(.caption.bold())
                .padding(.top, 2)
            }
```

At the `CompletionReportSection` construction site, pass the handlers **only when the goal is awaiting judgement**, so a finished goal's report is read-only:

```swift
                                waiverReason: evaluation.waivers[verdict.criterionId],
                                onAccept: conversation.goalContract?.awaitingHumanJudgement == true
                                    ? { state.recordHumanJudgement(for: conversation.id,
                                                                   criterionId: verdict.criterionId,
                                                                   accepted: true) } : nil,
                                onReject: conversation.goalContract?.awaitingHumanJudgement == true
                                    ? { state.recordHumanJudgement(for: conversation.id,
                                                                   criterionId: verdict.criterionId,
                                                                   accepted: false) } : nil
```

`CompletionReportSection` will need `conversation` and `state` in scope; if it currently takes only `report`/`evaluation`, add them as properties and pass them at its own call site.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter HumanJudgementRowTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 651 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/GoalEvaluation.swift Sources/iris/GoalContractPanel.swift Tests/irisTests/HumanJudgementRowTests.swift
git commit -m "feat(ui): accept/reject a human-judged criterion in the completion report

The verdict renders as 'met — your judgement', never a bare checkmark: a human
accept is not grader-verified evidence.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Scope guards and documentation

**Files:**
- Test: `Tests/irisTests/HumanJudgementScopeTests.swift` (create)
- Modify: `README.md`, `docs/specs/2026-09-18-human-judged-verdicts.md`

- [ ] **Step 1: Write the scope guards**

Create `Tests/irisTests/HumanJudgementScopeTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// D2 must not disturb the ladder, the loop guards, or D1's paths (spec §9).
@MainActor
@Suite("Human judgement scope (D2)", .serialized)
struct HumanJudgementScopeTests {
    @Test("a checkpoint pause is still a checkpoint pause, not a judgement pause")
    func checkpointPauseIsUnchanged() {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let a = Criterion(text: "one", kind: .qualitative, check: nil)
        let b = Criterion(text: "two", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [a, b])
        contract.milestones = [Milestone(title: "One", criterionIds: [a.id]),
                               Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, contract)
        app.setCheckpointPaused(for: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.checkpointStatus == .pausedForReview)
        #expect(c?.awaitingHumanJudgement == false,
                "the two pauses must stay distinct — ChatView shows different panels for them")
        #expect(c?.isPaused == true, "but both suppress the loop")
    }

    @Test("no tool named judge_criterion exists — the model must not judge")
    func noJudgementTool() async {
        // AGENTS.md invariant 6, and the point of the humanJudged kind. If a future change adds a
        // tool for this, it hands the model a verdict it is not entitled to give.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let recorder = ToolNameRecorder()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: recorder)
        await engine.processInput("hello", source: "User", conversationId: id)

        #expect(!recorder.seenToolNames.contains("judge_criterion"))
        #expect(!recorder.seenToolNames.contains { $0.contains("judge") })
    }

    /// Captures the tool names offered on a plain turn.
    final class ToolNameRecorder: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        var seenToolNames: Set<String> { lock.withLock { names } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock {
                for tool in request.tools ?? [] {
                    for d in tool.functionDeclarations { names.insert(d.name) }
                }
            }
            let part = Part(text: "ok", functionCall: nil, functionResponse: nil,
                            thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                  usageMetadata: nil)
        }
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter HumanJudgementScopeTests`
Expected: PASS, 2 tests.

- [ ] **Step 3: Update the README**

Find the `**Deterministic Done-Gates:**` bullet and append this sentence to it:

```markdown
Criteria marked "human-judged" are never graded by a machine: when they are all that stands between a goal and completion, the run pauses and asks you, and your verdict is labelled as yours rather than presented as verified.
```

- [ ] **Step 4: Mark the spec as-built**

Change the status line to:

```markdown
* **Status**: Implemented (2026-09-18). The design below is as-built; deviations are noted in §12.
```

Append a §12 recording any deviation found during execution. If there were none, say so explicitly rather than omitting the section.

- [ ] **Step 5: Run the full suite twice**

Run: `swift test` (twice)
Expected: PASS, 653 tests, both runs.

- [ ] **Step 6: Commit**

```bash
git add Tests/irisTests/HumanJudgementScopeTests.swift README.md docs/specs/2026-09-18-human-judged-verdicts.md
git commit -m "test(goal): scope guards for human-judged verdicts, plus docs

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes for the implementer

**The two-site rule is the fragile part.** `isPaused` replaces `checkpointStatus == .pausedForReview` at the resume guard and the reprompt guard, and **nowhere else**. Every other reader — `ChatView`'s panel switch, the locked chip's header, `rungState`, the pause chip — is asking a ladder question. Crucially, `ChatView` *suppresses the completion report chip* while the checkpoint status is set, and that chip hosts this slice's buttons: a find-and-replace would hide the UI the slice needs. After Task 1, `grep -n "pausedForReview" Sources/iris/*.swift` should still show every UI reader untouched.

**The resume-on-restart regression is covered indirectly, and that is a known limit.** Spec §10 asks that a goal paused for judgement does not silently resume on next launch. The guard reads `isPaused`, and Task 1 pins `isPaused == true` for a judgement pause — but no test drives actual app startup, because that path runs at engine init. If you can reach it cheaply, add the direct test; otherwise leave the indirect coverage and do not claim more than it proves.

**Never re-run the grader on resume.** It costs minutes and, worse, overwrites the user's judgement with a fresh `human_pending` — an infinite pause. Task 4's helper reads the verdicts already stored.

**A judgement pause must not touch `gateAttempts`.** The cap bounds an agent that might fix something. If you find yourself incrementing it here, re-read spec §4.

**No tool.** If any task tempts you to add a `FunctionDeclaration`, that is the wrong branch — the human judges, not the model. Task 6 has a test that fails if one appears.
