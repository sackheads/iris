# Deterministic Done-Gates (slice D1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `goal_complete` a gate: a goal with a locked contract completes only when the grader finds nothing failing, the agent waived what genuinely doesn't apply, or the retry cap is reached — in which case it completes and says so.

**Architecture:** The terminal grade moves from `Task.detached` to awaited, so the decision has evidence. Only `not_met` blocks. A refusal leaves `activeGoal` set, so the existing auto-reprompt is the retry loop — no new machinery. `waive_criterion` unlocks after a failed grade. Waivers and the gate outcome are snapshotted onto `GoalEvaluation` because `clearGoal` destroys the contract.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`). No new dependencies.

**Spec:** [docs/specs/2026-09-14-deterministic-done-gates.md](../specs/2026-09-14-deterministic-done-gates.md)

## Global Constraints

- **Every new field on a persisted `Codable` type must decode leniently.** `GoalContract` already has a custom `init(from:)` using `decodeIfPresent` — add there. **`GoalEvaluation` does NOT** (synthesized), so Task 1 gives it one. A non-optional field with a default added to a synthesized decoder throws `keyNotFound` on old data and drops **every conversation**. This has happened in this repo before.
- **Swift Testing only.** `@Suite` / `@Test` / `#expect`. Never XCTest. Style reference: `Tests/irisTests/ReachCheckpointHandlerTests.swift`.
- **Never mutate `ConfigManager.shared` in a test** (#109). Construct your own `ConfigManager()` and inject, or pass an explicit override.
- **Every tool `Schema(type: "ARRAY")` must set `items:`.** No ARRAY is added by this plan; the assert in `iris.swift` covers it regardless.
- **The gate is main-principal + locked-contract only.** Subagents, checkpoints, contract-less goals, and soft-stop (`restrictToGoalComplete`) must behave exactly as before. Every task's tests include the relevant regression.
- **Run `swift test` before every commit** and confirm it passes — not chained behind a `grep`. Baseline on `main`: **396 tests in 89 suites**, parallel, ~1.4s.
- **Conventional commits**, no emoji, co-credit the model in the trailer.

---

### Task 1: Data model

**Files:**
- Modify: `Sources/iris/GoalContract.swift` (two stored properties + two lines in the existing `init(from:)`)
- Modify: `Sources/iris/GoalEvaluation.swift` (`GateOutcome` enum, two stored properties, and a NEW custom `init(from:)`)
- Test: `Tests/irisTests/DoneGateModelTests.swift` (create)

**Interfaces:**
- Produces: `GoalContract.waivers: [UUID: String]`, `GoalContract.gateAttempts: Int`, `GoalEvaluation.gateOutcome: GateOutcome?`, `GoalEvaluation.waivers: [UUID: String]`, `enum GateOutcome`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/DoneGateModelTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Slice D1 adds persisted state in two places. The legacy-decode cases are the important ones:
/// a field that throws on a missing key takes every conversation with it.
@Suite("Done-gate model (D1)")
struct DoneGateModelTests {
    @Test("a contract round-trips its waivers and attempt count")
    func contractRoundTrip() throws {
        let c = Criterion(text: "docs published", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [c])
        contract.waivers[c.id] = "no docs site exists"
        contract.gateAttempts = 2

        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(contract))
        #expect(back.waivers[c.id] == "no docs site exists")
        #expect(back.gateAttempts == 2)
    }

    @Test("a pre-D1 contract decodes with the new fields defaulted, not a throw")
    func legacyContractDecodes() throws {
        // Exactly the keys a slice-A/B contract carried.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "objective": "ship",
            "criteria": [["id": UUID().uuidString, "text": "builds", "kind": "qualitative"]],
            "state": "locked"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let back = try JSONDecoder().decode(GoalContract.self, from: data)
        #expect(back.waivers.isEmpty)
        #expect(back.gateAttempts == 0)
        #expect(back.objective == "ship")
    }

    @Test("an evaluation round-trips its gate outcome and waiver snapshot")
    func evaluationRoundTrip() throws {
        let id = UUID()
        var eval = GoalEvaluation(status: .graded, criteria: [], startedAt: Date(), completedAt: Date())
        eval.gateOutcome = .ungatedAtCap
        eval.waivers[id] = "not applicable here"

        let back = try JSONDecoder().decode(GoalEvaluation.self, from: JSONEncoder().encode(eval))
        #expect(back.gateOutcome == .ungatedAtCap)
        #expect(back.waivers[id] == "not applicable here")
    }

    @Test("a pre-D1 evaluation decodes with the new fields defaulted, not a throw")
    func legacyEvaluationDecodes() throws {
        // GoalEvaluation had a synthesized decoder before D1, so this is the case that would have
        // thrown keyNotFound and failed the WHOLE [Conversation] decode.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "status": "graded",
            "criteria": [],
            "startedAt": 0.0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let back = try JSONDecoder().decode(GoalEvaluation.self, from: data)
        #expect(back.gateOutcome == nil)
        #expect(back.waivers.isEmpty)
        #expect(back.status == .graded)
    }

    @Test("a Conversation carrying a pre-D1 evaluation still decodes")
    func legacyConversationDecodes() throws {
        // The failure mode that matters: one bad field drops every conversation, not just one.
        var conv = Conversation(title: "old")
        conv.lastGoalEvaluation = GoalEvaluation(status: .graded, criteria: [],
                                                 startedAt: Date(), completedAt: Date())
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.lastGoalEvaluation?.gateOutcome == nil)
        #expect(back.title == "old")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter DoneGateModelTests`
Expected: compile failure — `value of type 'GoalContract' has no member 'waivers'`, `cannot find 'GateOutcome' in scope`.

- [ ] **Step 3: Add the contract fields**

In `Sources/iris/GoalContract.swift`, add to the stored properties of `GoalContract` (after `state`):

```swift
    /// Slice D1 — criteria the agent declared not-applicable, with its stated reason. The grader
    /// still grades a waived criterion; only the GATE ignores its `not_met`, so a waiver never
    /// erases evidence.
    var waivers: [UUID: String] = [:]
    /// Slice D1 — how many times the gate has refused completion for this contract. Reset when a
    /// contract is locked.
    var gateAttempts: Int = 0
```

Add both to the memberwise `init` parameter list and body, matching the existing style, and add two lines to the custom `init(from:)` beside the other `decodeIfPresent` calls:

```swift
        waivers = try c.decodeIfPresent([UUID: String].self, forKey: .waivers) ?? [:]
        gateAttempts = try c.decodeIfPresent(Int.self, forKey: .gateAttempts) ?? 0
```

- [ ] **Step 4: Add the evaluation fields and a lenient decoder**

In `Sources/iris/GoalEvaluation.swift`, add above `GoalEvaluation`:

```swift
/// How a goal got past the gate (slice D1). nil on an evaluation recorded before D1, and on a
/// checkpoint grade, which is not gated.
enum GateOutcome: String, Codable, Sendable, Equatable {
    case passed                 // nothing blocking
    case ungatedAtCap           // the retry cap was reached with criteria still not_met
    case ungatedGraderFailed    // the grader never delivered a verdict; its values are placeholders
}
```

Add the two fields to `GoalEvaluation`:

```swift
    var gateOutcome: GateOutcome?
    /// Snapshot of the contract's waivers. Copied here because `clearGoal` nils `goalContract` on
    /// completion — anything living only on the contract disappears exactly when the report needs it.
    var waivers: [UUID: String] = [:]
```

**`GoalEvaluation` has a synthesized decoder today**, which would throw `keyNotFound` on `waivers` for any evaluation persisted before D1 and fail the whole `[Conversation]` decode. Give it a custom one, mirroring `GoalContract`'s:

```swift
    /// Custom decoder so D1's fields are `decodeIfPresent`-defaulted: a synthesized `Decodable`
    /// throws `keyNotFound` on an evaluation persisted before D1, which fails the WHOLE
    /// `[Conversation]` decode and drops every conversation. Older fields are decoded leniently
    /// too, for the same forward-compat reason.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        status = try c.decode(EvaluationStatus.self, forKey: .status)
        criteria = try c.decodeIfPresent([CriterionVerdict].self, forKey: .criteria) ?? []
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        gateOutcome = try c.decodeIfPresent(GateOutcome.self, forKey: .gateOutcome)
        waivers = try c.decodeIfPresent([UUID: String].self, forKey: .waivers) ?? [:]
    }
```

Adding a custom `init(from:)` to a struct suppresses the synthesized memberwise initializer's sibling only for decoding — the memberwise `init` is still synthesized because all properties have defaults or are set at call sites. If the compiler complains about missing initializers at existing call sites, add an explicit memberwise `init` matching the current call shape (`status:criteria:startedAt:completedAt:`).

- [ ] **Step 5: Run the tests**

Run: `swift test --filter DoneGateModelTests`
Expected: PASS, 5 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 401 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/GoalContract.swift Sources/iris/GoalEvaluation.swift Tests/irisTests/DoneGateModelTests.swift
git commit -m "feat(goal): persisted state for the done-gate

GoalEvaluation gets a custom lenient decoder as part of this: it had a
synthesized one, which would throw keyNotFound on any evaluation persisted
before D1 and drop every conversation.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The blocking set (pure)

**Files:**
- Modify: `Sources/iris/GoalContract.swift` (extension at the end)
- Test: `Tests/irisTests/BlockingCriteriaTests.swift` (create)

**Interfaces:**
- Consumes: `GoalContract.waivers` (Task 1), `CriterionVerdict`, `GoalEvaluation`
- Produces: `GoalContract.blockingCriteria(from: GoalEvaluation) -> [CriterionVerdict]`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/BlockingCriteriaTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// The gate acts on evidence of failure, not absence of evidence (spec §4).
@Suite("Blocking criteria (D1)")
struct BlockingCriteriaTests {
    private func verdict(_ c: Criterion, _ v: CriterionVerdictValue) -> CriterionVerdict {
        CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: c.kind,
                         verdict: v, evidence: "because", method: .judge)
    }

    private func setup() -> (GoalContract, Criterion, Criterion, Criterion, Criterion) {
        let a = Criterion(text: "builds", kind: .qualitative, check: nil)
        let b = Criterion(text: "tested", kind: .qualitative, check: nil)
        let c = Criterion(text: "unverifiable", kind: .qualitative, check: nil)
        let d = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        return (GoalContract(objective: "ship", criteria: [a, b, c, d]), a, b, c, d)
    }

    private func evaluation(_ verdicts: [CriterionVerdict], status: EvaluationStatus = .graded) -> GoalEvaluation {
        GoalEvaluation(status: status, criteria: verdicts, startedAt: Date(), completedAt: Date())
    }

    @Test("not_met blocks")
    func notMetBlocks() {
        let (contract, a, b, _, _) = setup()
        let eval = evaluation([verdict(a, .met), verdict(b, .notMet)])
        #expect(contract.blockingCriteria(from: eval).map(\.criterionText) == ["tested"])
    }

    @Test("cannot_verify does not block — the grader could not determine it, not the agent")
    func cannotVerifyPasses() {
        let (contract, a, _, c, _) = setup()
        let eval = evaluation([verdict(a, .met), verdict(c, .cannotVerify)])
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }

    @Test("human_pending does not block — it can never be auto-graded")
    func humanPendingPasses() {
        let (contract, a, _, _, d) = setup()
        let eval = evaluation([verdict(a, .met), verdict(d, .humanPending)])
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }

    @Test("a waived not_met does not block")
    func waivedNotMetPasses() {
        var (contract, a, b, _, _) = setup()
        contract.waivers[b.id] = "no test harness in this repo"
        let eval = evaluation([verdict(a, .met), verdict(b, .notMet)])
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }

    @Test("waiving one criterion does not waive another that is also not_met")
    func waiverIsScoped() {
        var (contract, a, b, _, _) = setup()
        contract.waivers[a.id] = "n/a"
        let eval = evaluation([verdict(a, .notMet), verdict(b, .notMet)])
        #expect(contract.blockingCriteria(from: eval).map(\.criterionText) == ["tested"])
    }

    @Test("a failed grader blocks nothing — its verdicts are placeholders, not findings")
    func failedGraderBlocksNothing() {
        let (contract, a, b, _, _) = setup()
        let eval = evaluation([verdict(a, .notMet), verdict(b, .notMet)], status: .failed)
        #expect(contract.blockingCriteria(from: eval).isEmpty)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter BlockingCriteriaTests`
Expected: compile failure — `value of type 'GoalContract' has no member 'blockingCriteria'`.

- [ ] **Step 3: Implement it**

Append to `Sources/iris/GoalContract.swift`:

```swift
extension GoalContract {
    /// The criteria standing between this contract and completion (slice D1 §4).
    ///
    /// Only `not_met` blocks — positive evidence the work is not done. `cannot_verify` is a GRADER
    /// capability problem the agent cannot fix by retrying, and `human_pending` can never be
    /// auto-graded, so blocking on either would burn the retry cap or trap the goal outright. A
    /// waived criterion is excluded: the grader still graded it and the evidence is still shown,
    /// but the agent has stated why it does not apply.
    ///
    /// A `.failed` evaluation blocks nothing: the grader never delivered a verdict, so its values
    /// are placeholders rather than findings, and gating on a grader bug would trap the goal.
    func blockingCriteria(from evaluation: GoalEvaluation) -> [CriterionVerdict] {
        guard evaluation.status == .graded else { return [] }
        return evaluation.criteria.filter {
            $0.verdict == .notMet && waivers[$0.criterionId] == nil
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter BlockingCriteriaTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 407 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/GoalContract.swift Tests/irisTests/BlockingCriteriaTests.swift
git commit -m "feat(goal): compute the done-gate's blocking criteria

Only not_met blocks, and only when unwaived and the grade actually landed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Await the terminal grade

Behaviour-preserving on its own: the grade still always lets completion through. This task only moves it from `Task.detached` to awaited, so the next task has evidence to decide on.

**Files:**
- Modify: `Sources/iris/iris.swift` (the `goal_complete` handler's grade dispatch)
- Test: `Tests/irisTests/DoneGateHandlerTests.swift` (create)

**Interfaces:**
- Consumes: `GoalEvaluator.shared.evaluate(...) -> GoalEvaluation` (returns its verdict since #102)
- Produces: no new API — the grade is awaited and its result available in the handler

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/DoneGateHandlerTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Slice D1: `goal_complete` becomes a gate. These drive a real IrisEngine with a scripted client.
///
/// The grader lane synthesizes verdicts from the criterion ids in its own system prompt, because
/// `GoalEvaluationParsing` reconciles strictly by `criterion_id` and contract ids are minted per
/// test — a canned payload with a hardcoded id silently yields `cannot_verify` for everything.
@MainActor
@Suite("Done gate handler (D1)", .serialized)
struct DoneGateHandlerTests {
    /// Routes by principal: the grader is the engine whose toolset offers `submit_evaluation`.
    /// `graderVerdicts` maps criterion TEXT to the verdict the grader should return for it.
    final class GateClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let idPattern = /id ([0-9A-Fa-f-]{36}) \[[a-zA-Z]+\] ([^\n]*)/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderRuns = 0
        private let mainScript: [GeminiResponse]
        private let graderVerdicts: [String: String]
        private let graderStatus: EvaluationStatus

        init(main: [GeminiResponse], graderVerdicts: [String: String],
             graderStatus: EvaluationStatus = .graded) {
            self.mainScript = main
            self.graderVerdicts = graderVerdicts
            self.graderStatus = graderStatus
        }
        var graderRunCount: Int { lock.withLock { graderRuns } }

        private static func text(_ s: String) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model",
                parts: [Part(text: s, functionCall: nil, functionResponse: nil,
                             thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: nil)
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let offersSubmit = request.tools?.contains {
                $0.functionDeclarations.contains { $0.name == "submit_evaluation" }
            } ?? false
            let systemText = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""

            return lock.withLock {
                if offersSubmit {
                    // A `.failed` grader never submits; the evaluator's safety net records failed.
                    guard graderStatus == .graded else { return Self.text("thinking") }
                    graderRuns += 1
                    let entries = systemText.matches(of: Self.idPattern).map {
                        (id: String($0.output.1), text: String($0.output.2).trimmingCharacters(in: .whitespaces))
                    }
                    let evaluations = JSONValue.array(entries.map { entry in
                        .object(["criterion_id": .string(entry.id),
                                 "verdict": .string(graderVerdicts[entry.text] ?? "met"),
                                 "evidence": .string("grader saw: \(entry.text)")])
                    })
                    let part = Part(text: nil,
                                    functionCall: FunctionCall(name: "submit_evaluation",
                                                               args: ["evaluations": evaluations],
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

    static func goalComplete(_ summary: String = "done") -> GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string(summary)],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// A locked two-criterion contract on a fresh AppState.
    @discardableResult
    func lockContract(on app: AppState, _ id: UUID) -> (Criterion, Criterion) {
        app.createNewConversation(id: id)
        let a = Criterion(text: "builds", kind: .qualitative, check: nil)
        let b = Criterion(text: "tested", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship it", criteria: [a, b]))
        return (a, b)
    }

    @Test("the terminal grade is awaited, so the verdict is present when completion returns")
    func gradeIsAwaited() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: [:])   // everything met
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        // Detached grading left this .verifying (or nil) at this point; awaited means it is graded.
        #expect(conv?.lastGoalEvaluation?.status == .graded)
        #expect(client.graderRunCount == 1)
        #expect(conv?.activeGoal == nil, "an all-met goal still completes")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter DoneGateHandlerTests`
Expected: FAIL — `lastGoalEvaluation?.status` is `.verifying`, because the grade is still detached and has not finished when `processInput` returns.

- [ ] **Step 3: Await the grade**

In `Sources/iris/iris.swift`, in the `goal_complete` handler, replace the detached dispatch:

```swift
            if let c = contractToGrade {
                // Non-blocking: grade in the background; the verdict fills in the chip when ready.
                // ... (existing comment block)
                let graderClient = self.client
                let graderApp = localState
                if let graderApp {
                    Task.detached { await GoalEvaluator.shared.evaluate(contract: c, workspace: gradeWorkspace, originatingConversationId: conversationId, app: graderApp, client: graderClient) }
                }
            }
```

with:

```swift
            // Slice D1: AWAITED, not detached. A gate cannot be built on a verdict that arrives
            // after the decision to complete. The `.verifying` snapshot above renders a spinner
            // while this runs, so the wait is visible rather than a hang.
            if let c = contractToGrade, let graderApp = localState {
                _ = await GoalEvaluator.shared.evaluate(contract: c, workspace: gradeWorkspace,
                                                        originatingConversationId: conversationId,
                                                        app: graderApp, client: self.client)
            }
```

Leave everything else in the handler alone — this task changes *when* the grade happens, not what completion does with it.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter DoneGateHandlerTests`
Expected: PASS, 1 test.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 408 tests. Pay attention to `GoalEvaluatorTriggerTests` and `GoalCompleteTests` — they exercise this path and must still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/iris.swift Tests/irisTests/DoneGateHandlerTests.swift
git commit -m "refactor(goal): await the terminal grade instead of detaching it

A gate cannot be built on a verdict that arrives after the decision. Behaviour
is otherwise unchanged: completion still always proceeds.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The gate — refuse, retry, cap

**Files:**
- Modify: `Sources/iris/ConfigManager.swift` (`maxDoneGateRetries`, default 3)
- Modify: `Sources/iris/AppState.swift` (`recordGateRefusal`, `finishGatedGoal`)
- Modify: `Sources/iris/iris.swift` (the `goal_complete` handler)
- Test: `Tests/irisTests/DoneGateHandlerTests.swift` (add 5 tests)

**Interfaces:**
- Consumes: `blockingCriteria(from:)` (Task 2), `GateOutcome` (Task 1)
- Produces: `AppState.recordGateRefusal(for:)`, `AppState.finishGatedGoal(for:outcome:waivers:)`, `ConfigManager.maxDoneGateRetries`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/irisTests/DoneGateHandlerTests.swift`:

```swift
    @Test("a not_met criterion refuses completion and keeps the goal alive")
    func notMetRefuses() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["tested": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal != nil, "the goal must stay alive so the agent can keep working")
        #expect(conv?.goalContract != nil)
        #expect(conv?.goalContract?.gateAttempts == 1)
    }

    @Test("the refusal tells the agent which criterion failed and why")
    func refusalCarriesEvidence() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["tested": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        // The refusal goes back to the model as the tool result, which lands in the transcript.
        let conv = app.conversations.first { $0.id == id }
        let transcript = (conv?.messages.map(\.content) ?? []).joined(separator: "\n")
        #expect(transcript.contains("tested"), "the agent must be told which criterion blocked")
        #expect(transcript.contains("grader saw: tested"), "and the grader's evidence for it")
    }

    @Test("all met completes on the first attempt, gated")
    func allMetCompletes() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)], graderVerdicts: [:])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil)
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .passed)
    }

    @Test("cannot_verify completes without burning a retry")
    func cannotVerifyCompletes() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["tested": "cannot_verify"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "an unverifiable criterion must not block")
        #expect(client.graderRunCount == 1, "and must not trigger a retry")
    }

    @Test("a failed grader completes, recorded as ungated rather than blocking on a non-result")
    func failedGraderCompletes() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: [:], graderStatus: .failed)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil)
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .ungatedGraderFailed)
    }
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter DoneGateHandlerTests`
Expected: the four gating tests FAIL — the goal completes regardless of verdict, `gateAttempts` stays 0, and `gateOutcome` is nil. `gradeIsAwaited` and `allMetCompletes`' first assertion still pass.

- [ ] **Step 3: Add the config knob**

In `Sources/iris/ConfigManager.swift`, beside `maxGoalIterations`:

```swift
    var maxDoneGateRetries: Int {
        didSet { ConfigManager.store.set(maxDoneGateRetries, forKey: "MAX_DONE_GATE_RETRIES") }
    }
```

and in `init()`, beside the other saved-value reads:

```swift
        let savedGateRetries = ConfigManager.store.integer(forKey: "MAX_DONE_GATE_RETRIES")
        self.maxDoneGateRetries = savedGateRetries == 0 ? 3 : savedGateRetries
```

- [ ] **Step 4: Add the AppState transitions**

In `Sources/iris/AppState.swift`, beside `recordEvaluation`:

```swift
    /// The gate refused completion: bump the attempt count and leave everything else alone. The
    /// goal stays active on purpose, so the existing auto-reprompt carries the agent back to work —
    /// that is the entire retry loop (spec §6).
    func recordGateRefusal(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var c = conversations[idx].goalContract else { return }
        c.gateAttempts += 1
        conversations[idx].goalContract = c
        saveConversations()
    }

    /// Stamp the gate's verdict onto the recorded evaluation before the goal is cleared.
    /// `clearGoal` nils `goalContract`, so the waiver map has to be copied here or it disappears
    /// exactly when the completion report needs it (spec §5.1).
    func finishGatedGoal(for conversationId: UUID, outcome: GateOutcome, waivers: [UUID: String]) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var eval = conversations[idx].lastGoalEvaluation else { return }
        eval.gateOutcome = outcome
        eval.waivers = waivers
        conversations[idx].lastGoalEvaluation = eval
        saveConversations()
    }
```

- [ ] **Step 5: Wire the gate into the handler**

In `Sources/iris/iris.swift`, replace the awaited-grade block from Task 3 with the gate. It sits *after* `recordCompletionSelfReport` + `beginGoalEvaluation` and *before* `clearGoal` — so restructure that `MainActor.run` accordingly:

```swift
            // Snapshot the pending evaluation and the self-report BEFORE grading; the gate decides
            // whether the goal is cleared at all.
            await MainActor.run {
                localState?.recordCompletionSelfReport(for: conversationId, statusJSON: statusReport)
                if let c = contractToGrade { localState?.beginGoalEvaluation(for: conversationId, contract: c) }
            }

            // Slice D1 — the gate. Only a main-principal goal with a locked contract is gated, and
            // a soft-stop bypasses it entirely: that is an emergency termination and must be able to
            // end a goal regardless of any verdict.
            if let c = contractToGrade, !restrictToGoalComplete, let graderApp = localState {
                let evaluation = await GoalEvaluator.shared.evaluate(
                    contract: c, workspace: gradeWorkspace,
                    originatingConversationId: conversationId, app: graderApp, client: self.client)
                let blocking = c.blockingCriteria(from: evaluation)
                let cap = ConfigManager.shared.maxDoneGateRetries

                if !blocking.isEmpty, c.gateAttempts < cap {
                    await MainActor.run { localState?.recordGateRefusal(for: conversationId) }
                    // The goal is NOT cleared: activeGoal stays set and the auto-reprompt brings the
                    // agent back to work. This is the whole retry loop.
                    let lines = blocking.map { "- \($0.criterionText) — \($0.evidence)" }.joined(separator: "\n")
                    return """
                    Not done yet. An independent grader found \(blocking.count) criteri\(blocking.count == 1 ? "on" : "a") not met:
                    \(lines)

                    Keep working and call goal_complete again when they hold. If one genuinely does \
                    not apply, call `waive_criterion` with the reason — it will be shown to the user.
                    """
                }

                let outcome: GateOutcome = evaluation.status != .graded ? .ungatedGraderFailed
                                         : (blocking.isEmpty ? .passed : .ungatedAtCap)
                await MainActor.run {
                    localState?.finishGatedGoal(for: conversationId, outcome: outcome, waivers: c.waivers)
                }
            }

            await MainActor.run {
                localState?.clearGoal(for: conversationId)
                localState?.onSubagentComplete[conversationId]?(SubagentTermination(status: .completed, summary: summary, calledGoalComplete: true))
                localState?.onSubagentComplete[conversationId] = nil
            }
```

Remove the now-duplicated `recordCompletionSelfReport` / `beginGoalEvaluation` / `clearGoal` calls from the original `MainActor.run` block so each happens exactly once.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter DoneGateHandlerTests`
Expected: PASS, 6 tests.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 413 tests. `GoalCompleteTests`, `GoalCompleteStatusTests`, `GoalEvaluatorTriggerTests`, and the subagent suites all exercise `goal_complete` and must still pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/ConfigManager.swift Sources/iris/AppState.swift Sources/iris/iris.swift Tests/irisTests/DoneGateHandlerTests.swift
git commit -m "feat(goal): gate goal_complete on the grader's verdict

A not_met criterion refuses completion and leaves the goal alive, so the
existing auto-reprompt is the retry loop. At the cap the goal completes anyway,
recorded as ungated: it always terminates.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `waive_criterion`

**Files:**
- Modify: `Sources/iris/iris.swift` (declaration at the ladder-gated tool site; handler beside `amend_goal_contract`)
- Modify: `Sources/iris/AppState.swift` (`waiveCriterion`)
- Test: `Tests/irisTests/WaiveCriterionTests.swift` (create)

**Interfaces:**
- Consumes: `GoalContract.waivers` (Task 1), `gateAttempts` (Task 1)
- Produces: the `waive_criterion` tool, `AppState.waiveCriterion(for:criterionId:reason:) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/WaiveCriterionTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// The escape hatch. Unlocks only after a grade has failed, so the agent must try before declaring
/// something inapplicable (spec §5).
@MainActor
@Suite("waive_criterion (D1)")
struct WaiveCriterionTests {
    private func lockedContract(on app: AppState, _ id: UUID, attempts: Int = 0) -> Criterion {
        app.createNewConversation(id: id)
        let c = Criterion(text: "docs published", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [c]))
        if attempts > 0 {
            for _ in 0..<attempts { app.recordGateRefusal(for: id) }
        }
        return c
    }

    @Test("waiving records the reason against the criterion")
    func waiveRecordsReason() {
        let app = AppState()
        let id = UUID()
        let c = lockedContract(on: app, id, attempts: 1)

        let ok = app.waiveCriterion(for: id, criterionId: c.id, reason: "no docs site exists")

        #expect(ok)
        #expect(app.conversations.first { $0.id == id }?.goalContract?.waivers[c.id] == "no docs site exists")
    }

    @Test("waiving before any failed grade is refused — try first")
    func refusedBeforeAFailedGrade() {
        let app = AppState()
        let id = UUID()
        let c = lockedContract(on: app, id, attempts: 0)

        let ok = app.waiveCriterion(for: id, criterionId: c.id, reason: "cannot be bothered")

        #expect(!ok, "a waiver available on the first attempt is a gate that can be skipped in one move")
        #expect(app.conversations.first { $0.id == id }?.goalContract?.waivers.isEmpty == true)
    }

    @Test("an unknown criterion id is refused")
    func unknownIdRefused() {
        let app = AppState()
        let id = UUID()
        _ = lockedContract(on: app, id, attempts: 1)

        #expect(!app.waiveCriterion(for: id, criterionId: UUID(), reason: "n/a"))
    }

    @Test("a blank reason is refused — the point is the stated reason")
    func blankReasonRefused() {
        let app = AppState()
        let id = UUID()
        let c = lockedContract(on: app, id, attempts: 1)

        #expect(!app.waiveCriterion(for: id, criterionId: c.id, reason: "   "))
    }

    @Test("waiving with no contract is refused")
    func noContractRefused() {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)

        #expect(!app.waiveCriterion(for: id, criterionId: UUID(), reason: "n/a"))
    }
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter WaiveCriterionTests`
Expected: compile failure — `value of type 'AppState' has no member 'waiveCriterion'`.

- [ ] **Step 3: Implement the state transition**

In `Sources/iris/AppState.swift`, beside `recordGateRefusal`:

```swift
    /// Record the agent's `n/a — <reason>` waiver for one criterion. Returns false when the waiver
    /// is not allowed: no locked contract, no failed grade yet (the agent must try before declaring
    /// something inapplicable), an unknown criterion, or a blank reason — the stated reason is the
    /// entire point, since it is what the user sees.
    @discardableResult
    func waiveCriterion(for conversationId: UUID, criterionId: UUID, reason: String) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var c = conversations[idx].goalContract,
              c.gateAttempts > 0,
              c.criteria.contains(where: { $0.id == criterionId })
        else { return false }
        c.waivers[criterionId] = trimmed
        conversations[idx].goalContract = c
        saveConversations()
        return true
    }
```

- [ ] **Step 4: Declare the tool**

In `Sources/iris/iris.swift`, inside the `if principal == .main, let gc = ladderContract, ...` region is NOT correct — that block is ladder-gated. Add a separate gate just after it, so the tool appears whenever a locked contract has a failed grade:

```swift
        // Slice D1's escape hatch, offered only once a grade has actually failed — the agent must
        // try before declaring a criterion inapplicable.
        if principal == .main, let gc = ladderContract, gc.isLocked, gc.gateAttempts > 0 {
            toolsList.append(FunctionDeclaration(
                name: "waive_criterion",
                description: "Declare that one criterion of the locked goal contract genuinely does not apply, with a reason. Use this ONLY when a criterion cannot be satisfied because it was mistaken or is not applicable — not to skip work. The criterion is still graded and its verdict still shown; your reason is shown to the user beside it.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "criterion_id": Schema(type: "STRING", description: "The id of the criterion, copied from the contract."),
                        "reason": Schema(type: "STRING", description: "Why this criterion does not apply. Shown to the user.")
                    ],
                    required: ["criterion_id", "reason"]
                )
            ))
        }
```

- [ ] **Step 5: Add the handler**

In `Sources/iris/iris.swift`, immediately after the `amend_goal_contract` branch:

```swift
        } else if functionCall.name == "waive_criterion", principal == .main {
            let idString = functionCall.args["criterion_id"]?.stringValue ?? ""
            let reason = functionCall.args["reason"]?.stringValue ?? ""
            guard let criterionId = UUID(uuidString: idString) else {
                result = "That is not a valid criterion id. Copy the id exactly as it appears in the contract."
                return result
            }
            let ok = await MainActor.run {
                localState?.waiveCriterion(for: conversationId, criterionId: criterionId, reason: reason) ?? false
            }
            result = ok
                ? "Criterion waived with your stated reason. It will still be graded and shown to the user, but it will no longer block completion."
                : "Waiver rejected. A waiver needs a locked contract, a non-empty reason, a criterion id that exists in the contract, and at least one failed grade — work the criterion first and let the grader judge it."
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter WaiveCriterionTests`
Expected: PASS, 5 tests.

- [ ] **Step 7: Add the end-to-end gate test**

Add to `Tests/irisTests/DoneGateHandlerTests.swift`:

```swift
    @Test("refuse, waive, then complete — with the verdict and the waiver both on record")
    func waiveThenComplete() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        let (_, b) = lockContract(on: app, id)
        // Attempt 1 fails on "tested"; the agent waives it; attempt 2 completes.
        let client = GateClient(
            main: [Self.goalComplete(),
                   Self.response(FunctionCall(name: "waive_criterion",
                                              args: ["criterion_id": .string(b.id.uuidString),
                                                     "reason": .string("no test harness in this repo")],
                                              id: nil, thought_signature: nil, thoughtSignature: nil)),
                   Self.goalComplete(),
                   Self.response(nil)],
            graderVerdicts: ["tested": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)
        // The refusal ends the turn; drive the follow-up turns the auto-reprompt would.
        await engine.processInput("continue", source: "System", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "the waived criterion no longer blocks")
        #expect(conv?.lastGoalEvaluation?.waivers[b.id] == "no test harness in this repo",
                "the waiver must survive clearGoal destroying the contract")
        #expect(conv?.lastGoalEvaluation?.criteria.first { $0.criterionId == b.id }?.verdict == .notMet,
                "and the grader's verdict must still be on record beside it")
    }
```

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: PASS, 419 tests.

- [ ] **Step 9: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/iris.swift Tests/irisTests/
git commit -m "feat(goal): waive_criterion, the done-gate's escape hatch

Unlocks only after a grade has failed, so the agent must try before declaring a
criterion inapplicable. The criterion is still graded and its verdict still
shown; the waiver sits beside it rather than erasing it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Show the gate outcome and waivers

**Files:**
- Modify: `Sources/iris/GoalContractPanel.swift` (`CompletionReportSection` header, `DriftCriterionRow`)
- Test: `Tests/irisTests/GateOutcomeRenderingTests.swift` (create)

**Interfaces:**
- Consumes: `GoalEvaluation.gateOutcome`, `GoalEvaluation.waivers` (Task 1)
- Produces: `GateOutcome.bannerText` (testable without a view harness)

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/GateOutcomeRenderingTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// An ungated completion must say so. The panel's job across this whole arc is separating claims
/// from verified facts, and "completed without passing" is exactly such a fact.
@Suite("Gate outcome rendering (D1)")
struct GateOutcomeRenderingTests {
    @Test("a passed gate needs no banner")
    func passedIsQuiet() {
        #expect(GateOutcome.passed.bannerText(unmetCount: 0) == nil)
    }

    @Test("hitting the cap says so, with the count")
    func capIsLoud() {
        let text = GateOutcome.ungatedAtCap.bannerText(unmetCount: 2)
        #expect(text?.contains("without passing") == true)
        #expect(text?.contains("2") == true)
    }

    @Test("a failed grader is distinguished from an unmet criterion")
    func graderFailureIsItsOwnThing() {
        let text = GateOutcome.ungatedGraderFailed.bannerText(unmetCount: 0)
        #expect(text?.lowercased().contains("grader") == true)
        #expect(text?.contains("without passing") != true,
                "a grader that never ran is not the same as work that failed")
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter GateOutcomeRenderingTests`
Expected: compile failure — `value of type 'GateOutcome' has no member 'bannerText'`.

- [ ] **Step 3: Implement the banner text**

Append to `Sources/iris/GoalEvaluation.swift`:

```swift
extension GateOutcome {
    /// One line for the completion chip, or nil when there is nothing to warn about. Kept out of
    /// the view so it can be tested without a SwiftUI harness.
    func bannerText(unmetCount: Int) -> String? {
        switch self {
        case .passed:
            return nil
        case .ungatedAtCap:
            let plural = unmetCount == 1 ? "criterion" : "criteria"
            return "Completed without passing the gate — \(unmetCount) \(plural) still not met after the retry limit."
        case .ungatedGraderFailed:
            return "Completed ungated — the grader did not finish, so nothing was verified."
        }
    }
}
```

- [ ] **Step 4: Render it in the panel**

In `Sources/iris/GoalContractPanel.swift`, inside `CompletionReportSection`'s `body`, directly under the header `HStack`, add:

```swift
            if let outcome = evaluation?.gateOutcome,
               let banner = outcome.bannerText(unmetCount: evaluation?.criteria.filter { $0.verdict == .notMet }.count ?? 0) {
                Label(banner, systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

And in `DriftCriterionRow`, add a waiver line under the evidence. Add the stored property:

```swift
    /// The agent's stated reason for waiving this criterion, when it waived one.
    var waiverReason: String? = nil
```

and under the evidence `Text`:

```swift
            if let waiverReason {
                Label("WAIVED by the agent: \"\(waiverReason)\"", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

Pass it at the two `DriftCriterionRow(...)` construction sites:

```swift
                                waiverReason: evaluation.waivers[verdict.criterionId],
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter GateOutcomeRenderingTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 422 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/GoalEvaluation.swift Sources/iris/GoalContractPanel.swift Tests/irisTests/GateOutcomeRenderingTests.swift
git commit -m "feat(ui): surface the gate outcome and waivers in the completion report

An ungated completion says so, and a waiver appears beside the grader's verdict
rather than in place of it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Regression guards and documentation

The gate must not touch anything outside its stated scope. These tests are the proof.

**Files:**
- Test: `Tests/irisTests/DoneGateScopeTests.swift` (create)
- Modify: `README.md`
- Modify: `docs/specs/2026-09-14-deterministic-done-gates.md` (status + as-built notes)

- [ ] **Step 1: Write the scope tests**

Create `Tests/irisTests/DoneGateScopeTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// D1 gates terminal goal_complete for a main-principal goal with a locked contract. Everything
/// else must behave exactly as before — these are the guards for that claim (spec §2, §8).
@MainActor
@Suite("Done gate scope (D1)", .serialized)
struct DoneGateScopeTests {
    private func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "ok" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    private func goalComplete() -> GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string("done")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    @Test("a goal with no contract completes ungated, exactly as before")
    func contractlessGoalIsUngated() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.setGoal(for: id, goal: "do the thing")   // activeGoal, no contract
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "no contract means no gate")
        #expect(conv?.lastGoalEvaluation == nil)
    }

    @Test("a subagent's goal_complete is never gated")
    func subagentIsUngated() async {
        // A subagent terminates via goal_complete and its unit contract is graded by B3's own
        // machinery. Gating it here would change B2/B3/B4 semantics.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        let c = Criterion(text: "unit done", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "the unit", criteria: [c]))
        let engine = IrisEngine(state: app, tier: .easy, principal: .subagent, roleLabel: "engineer",
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("go", source: "System", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "a subagent must still terminate on goal_complete")
        #expect(conv?.goalContract?.gateAttempts == nil, "and the gate must not have run")
    }

    @Test("a soft-stop completes regardless of the verdict")
    func softStopBypassesTheGate() async {
        // restrictToGoalComplete is an emergency termination (iteration cap / loop detection). It
        // must be able to end a goal whatever the grader would have said, or a stuck loop with a
        // failing criterion could never stop.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let c = Criterion(text: "impossible", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [c]))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("summarize and stop", source: "System",
                                  conversationId: id, restrictToGoalComplete: true)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "an emergency stop must always be able to end the goal")
    }

    @Test("a non-final checkpoint still redirects to reach_checkpoint before the gate runs")
    func ladderGateStillWins() async {
        // §7's assumption: a paused checkpoint and a terminal goal_complete cannot coincide,
        // because the ladder redirect happens first. The gate's refusal depends on the
        // auto-reprompt, which is suppressed while paused — so this must stay true.
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let a = Criterion(text: "one", kind: .qualitative, check: nil)
        let b = Criterion(text: "two", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "ship", criteria: [a, b])
        contract.milestones = [Milestone(title: "One", criterionIds: [a.id]),
                               Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, contract)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [goalComplete(), response(nil)]))
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal != nil, "the ladder redirect must fire before any gating")
        #expect(conv?.goalContract?.gateAttempts == 0, "and the gate must not have run at all")
        #expect(conv?.goalContract?.checkpointStatus == .running)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter DoneGateScopeTests`
Expected: PASS, 4 tests. If `ladderGateStillWins` fails, the gate is running before the ladder redirect — fix the ordering in the handler rather than the test. If `softStopBypassesTheGate` fails, the `!restrictToGoalComplete` condition is missing from the gate in Task 4.

- [ ] **Step 3: Update the README**

Find the `**Graded Delegation:**` bullet and add before it:

```markdown
*   **Deterministic Done-Gates:** With a goal contract active, Iris cannot simply declare itself finished. `goal_complete` is gated on an independent grader's verdict: any criterion the grader finds unmet sends Iris back to work with the evidence attached. If a criterion genuinely does not apply, Iris must say so out loud with a reason, which is shown to you beside the grader's verdict rather than in place of it. After a configurable number of failed attempts the goal finishes anyway — and is labelled plainly as having completed without passing, so an unfinished goal can never quietly look like a finished one.
```

- [ ] **Step 4: Mark the spec as-built**

Change the status line to:

```markdown
* **Status**: Implemented (2026-09-14). The design below is as-built; deviations are noted in §11.
```

Append a §11 "As-built notes" section recording any deviation encountered during execution. If there were none, say so explicitly rather than omitting the section.

- [ ] **Step 5: Run the full suite twice**

Run: `swift test` (twice)
Expected: PASS, 426 tests, both runs.

- [ ] **Step 6: Commit**

```bash
git add Tests/irisTests/DoneGateScopeTests.swift README.md docs/specs/2026-09-14-deterministic-done-gates.md
git commit -m "test(goal): scope guards for the done-gate, plus docs

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes for the implementer

**The data-safety invariant is the one that bites.** `GoalEvaluation` had a synthesized decoder before Task 1. A non-optional field with a default added to a synthesized decoder throws `keyNotFound` on old data, which fails the whole `[Conversation]` decode and drops **every conversation the user has**. Task 1's legacy-decode tests are not ceremony.

**The grader reconciles by id, not text.** `GoalEvaluationParsing` matches submitted verdicts strictly by `criterion_id`, and contract ids are minted per test. The scripted grader in `DoneGateHandlerTests` reads ids out of its own system prompt for that reason; a canned payload with a hardcoded id silently yields `cannot_verify` for everything — a green-looking test that asserts nothing.

**Order matters in the handler.** The ladder redirect must run before the gate, `beginGoalEvaluation` before grading, and `finishGatedGoal` before `clearGoal`. Task 7's `ladderGateStillWins` and Task 5's `waiveThenComplete` are the guards for the first and last of those.

**Expect the suite to slow slightly.** Each gated completion test drives a real evaluator loop. The existing suite runs ~1.4s; budget a few hundred ms more, not seconds. If a test takes tens of seconds, something is looping — check the grader lane is actually matching and submitting.
