# Checkpoint Delegation (slice B4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the main agent hand the current ladder milestone to a bounded subagent with `delegate_milestone`, and on success reach B1's checkpoint automatically — graded cumulatively, paused for the human.

**Architecture:** A new main-agent-only tool sits beside `reach_checkpoint` at the same toolset filter site. Its criteria are read from the locked ladder, never from the model. The subagent is bound to that contract as an oracle but **not** graded; the checkpoint runs B1's existing cumulative grade, which already covers the milestone's criteria as a subset. `reach_checkpoint` and `delegate_milestone` share one extracted `performCheckpoint` helper.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`). No new dependencies.

**Spec:** [docs/specs/2026-09-13-checkpoint-delegation.md](../specs/2026-09-13-checkpoint-delegation.md)

## Global Constraints

- **Swift Testing only.** `@Suite` / `@Test` / `#expect`. Never XCTest. Style reference: `Tests/irisTests/ReachCheckpointHandlerTests.swift`.
- **Every new field on a persisted `Codable` type must use `decodeIfPresent`** (or be Optional, which synthesizes it) — a missing key otherwise throws and drops ALL conversations on load. No task here adds a persisted field; if you find yourself adding one, stop and re-read `AGENTS.md`.
- **Every tool `Schema(type: "ARRAY")` must set `items:`.** Gemini rejects arrays without it (HTTP 400). An `assert` in `iris.swift` catches this under test.
- **`AppState` is `@Observable`, not `ObservableObject`.** Never add `@Published`.
- **`currentMilestone` advances only on the human's click.** No task in this plan advances it. That is B1 §7 and slice D's territory.
- **Run `swift test` before every commit** and confirm it passes. Baseline on `main` at plan time: **367 tests in 84 suites**.
- **Conventional commits**, no emoji in messages, co-credit the model in the trailer.

---

### Task 1: `DelegatedUnit` replaces `criteria:` on `runSubagent`

Slice B3 passes raw JSON criteria into `runSubagent` and grades any `.completed` run that had them. B4 needs a unit that is **bound but not graded**, so the parameter becomes a value type that states both halves.

**Files:**
- Modify: `Sources/iris/SubagentManager.swift` (add the type above `final class SubagentManager`; change `runSubagent` signature ~L27 and the grading branch ~L119)
- Modify: `Sources/iris/iris.swift` (the `invoke_subagent` handler, ~L890)
- Test: `Tests/irisTests/SubagentGradingTests.swift` (update 4 call sites, add 1 test)

**Interfaces:**
- Consumes: `GoalContractParsing.unitContract(task:criteriaJSON:) -> GoalContract?` (exists on main)
- Produces: `struct DelegatedUnit { var contract: GoalContract; var grade: Bool = true }` and
  `SubagentManager.runSubagent(role:task:effort:parentConversationId:unit:maxIterations:client:) async -> String`

- [ ] **Step 1: Write the failing test**

Add to `Tests/irisTests/SubagentGradingTests.swift`, inside the suite, just above `// MARK: - Persistence`:

```swift
@Test("an ungraded unit binds the contract as an oracle but runs no grader")
func ungradedUnitIsNotGraded() async {
    let (_, parentId) = freshState()
    let client = RoutingLLMClient(subagent: [goalComplete, response(nil)],
                                  graderVerdict: ("met", "should never be asked for"))
    let contract = try! #require(GoalContractParsing.unitContract(
        task: "build a widget", criteriaJSON: criteriaJSON("the widget exists")))

    let rendered = await SubagentManager.shared.runSubagent(
        role: "engineer", task: "build a widget", effort: "easy",
        parentConversationId: parentId,
        unit: DelegatedUnit(contract: contract, grade: false),
        client: client)

    // The unit was bound (the parent is told what it was held to) but nothing graded it.
    #expect(client.graderCalls == 0, "grade: false must not spin up an evaluator")
    #expect(!rendered.contains("Independent grader verdict"))
    #expect(rendered.contains("Held to 1 criterion"))
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter SubagentGradingTests`
Expected: compile failure — `extra argument 'unit' in call`, `cannot find 'DelegatedUnit' in scope`.

- [ ] **Step 3: Add the type and change the signature**

In `Sources/iris/SubagentManager.swift`, above `final class SubagentManager`:

```swift
/// A bounded unit of work handed to a subagent: the contract it runs against, and whether that
/// contract is independently graded when the run completes.
///
/// `grade: false` binds the contract as an oracle only — the subagent knows its definition of done
/// while working, and `SubagentResult.verdict` stays nil. Slice B4 delegates a ladder milestone
/// this way, because the CHECKPOINT grades it cumulatively and a second grade of the same criteria
/// would be redundant work.
struct DelegatedUnit: Sendable {
    var contract: GoalContract
    var grade: Bool = true
}
```

Change the signature (replacing the `criteria:` parameter):

```swift
    func runSubagent(role: String, task: String, effort: String, parentConversationId: UUID,
                     unit: DelegatedUnit? = nil, maxIterations: Int = 3000,
                     client: (any LLMClientProtocol)? = nil) async -> String {
```

Replace the parse line in step 4 of the body:

```swift
        let unitContract = unit?.contract
```

Gate the grading branch on the flag — find `if termination.status == .completed, let unitContract {` and change it to:

```swift
        if termination.status == .completed, let unit, unit.grade {
```

…and inside that branch change `contract: unitContract` to `contract: unit.contract`.

- [ ] **Step 4: Update the `invoke_subagent` handler**

In `Sources/iris/iris.swift`, in the `invoke_subagent` branch, replace the `let criteria = ...` line and both `runSubagent` calls:

```swift
            // Slice B3: optional parent-authored definition-of-done. Absent ⇒ the B2 path (no
            // contract, no grade). Always graded when present — B4's ungraded units are built by
            // `delegate_milestone`, not by this tool.
            let unit = GoalContractParsing.unitContract(task: task, criteriaJSON: functionCall.args["criteria"])
                .map { DelegatedUnit(contract: $0, grade: true) }
            let subagentClient = self.client
```

Both call sites become `..., parentConversationId: conversationId, unit: unit, client: subagentClient)`.

- [ ] **Step 5: Update the 4 existing test call sites**

In `Tests/irisTests/SubagentGradingTests.swift`, add this helper next to `criteriaJSON`:

```swift
/// A graded unit built the way `invoke_subagent` builds one.
private func gradedUnit(_ text: String, task: String = "build a widget") -> DelegatedUnit {
    DelegatedUnit(contract: GoalContractParsing.unitContract(
        task: task, criteriaJSON: criteriaJSON(text))!, grade: true)
}
```

Then replace every `criteria: criteriaJSON("the widget exists")` argument with `unit: gradedUnit("the widget exists")`. There are 3 such call sites (`contractedRunIsGraded`, `timedOutContractedRunIsNotGraded`, `inheritsParentWorkspace`). The 4th usage — inside `criteriaFlowThroughTheHandler` — is a `criteria` key on a **tool-call payload**, not a `runSubagent` argument: leave it exactly as it is.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter SubagentGradingTests`
Expected: PASS, 8 tests.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 368 tests (367 baseline + 1).

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/SubagentManager.swift Sources/iris/iris.swift Tests/irisTests/SubagentGradingTests.swift
git commit -m "refactor(subagent): DelegatedUnit replaces the criteria parameter

A delegated unit is a contract plus whether it gets graded. Slice B4 binds a
milestone contract as an oracle WITHOUT grading it, because the checkpoint
grades those criteria cumulatively; encoding that as a bool beside the contract
is clearer than inferring graded-ness from whether criteria were present.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The milestone's unit contract

Pure, no I/O. Builds the contract a delegated milestone runs against, entirely from the locked ladder.

**Files:**
- Modify: `Sources/iris/GoalContract.swift` (add an extension at the end of the file)
- Test: `Tests/irisTests/MilestoneUnitContractTests.swift` (create)

**Interfaces:**
- Consumes: `GoalContract.currentMilestoneCriteria()`, `.hasLadder`, `.milestones`, `.lock()` (all exist)
- Produces: `GoalContract.currentMilestoneUnitContract() -> GoalContract?`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/MilestoneUnitContractTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Slice B4: the contract a delegated milestone runs against is derived from the locked ladder,
/// never restated by a caller — so delegation cannot reshape the gate it is measured by.
@Suite("Milestone unit contract (B4)")
struct MilestoneUnitContractTests {
    private func laddered(currentMilestone: Int = 0) -> GoalContract {
        let a = Criterion(text: "parser handles nesting", kind: .qualitative, check: nil)
        let b = Criterion(text: "parser is tested", kind: .executable, check: "swift test")
        let c = Criterion(text: "wired into the app", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "Ship the parser", criteria: [a, b, c],
                                    outOfScope: ["rewriting the lexer"],
                                    stopBefore: ["force-pushing"])
        contract.milestones = [Milestone(title: "Parser", criterionIds: [a.id, b.id]),
                               Milestone(title: "Integration", criterionIds: [c.id])]
        contract.currentMilestone = currentMilestone
        contract.lock()
        return contract
    }

    @Test("the unit's criteria are exactly the current milestone's")
    func criteriaComeFromTheLadder() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        #expect(unit.criteria.count == 2)
        #expect(unit.criteria.map(\.text) == ["parser handles nesting", "parser is tested"])
        #expect(unit.criteria[1].check == "swift test")
    }

    @Test("the second milestone yields its own criteria, not the first's")
    func tracksCurrentMilestone() throws {
        let unit = try #require(laddered(currentMilestone: 1).currentMilestoneUnitContract())
        #expect(unit.criteria.map(\.text) == ["wired into the app"])
    }

    @Test("scope boundaries are inherited, so delegation cannot launder a restriction")
    func inheritsScopeBoundaries() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        #expect(unit.outOfScope == ["rewriting the lexer"])
        #expect(unit.stopBefore == ["force-pushing"])
    }

    @Test("the unit is locked and carries no ladder of its own")
    func lockedAndFlat() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        // A ladder here would strand the run: the oracle would tell the subagent to call
        // reach_checkpoint, which is gated to the main principal.
        #expect(unit.hasLadder == false)
        #expect(unit.isLocked)
    }

    @Test("the objective carries the goal, the ladder position, and the milestone title")
    func objectiveGivesContext() throws {
        let unit = try #require(laddered().currentMilestoneUnitContract())
        #expect(unit.objective.contains("Ship the parser"))
        #expect(unit.objective.contains("1/2"))
        #expect(unit.objective.contains("Parser"))
    }

    @Test("a contract with no ladder has no milestone to delegate")
    func noLadderNoUnit() {
        let flat = GoalContract(objective: "Ship", criteria: [
            Criterion(text: "it works", kind: .qualitative, check: nil)
        ])
        #expect(flat.currentMilestoneUnitContract() == nil)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter MilestoneUnitContractTests`
Expected: compile failure — `value of type 'GoalContract' has no member 'currentMilestoneUnitContract'`.

- [ ] **Step 3: Implement it**

Append to `Sources/iris/GoalContract.swift`:

```swift
extension GoalContract {
    /// The bounded unit contract for the CURRENT milestone (slice B4).
    ///
    /// Everything comes from the locked ladder: criteria are the milestone's own, and the goal's
    /// scope boundaries are inherited so a delegated unit cannot be used to launder a restriction
    /// the parent is under. No caller supplies criteria, so delegation cannot reshape the gate the
    /// work is about to be measured by. Returns nil when there is no ladder to delegate from.
    func currentMilestoneUnitContract() -> GoalContract? {
        guard hasLadder, milestones.indices.contains(currentMilestone) else { return nil }
        let milestone = milestones[currentMilestone]
        let position = "checkpoint \(currentMilestone + 1)/\(milestones.count)"
        var unit = GoalContract(objective: "\(objective) — \(position): \(milestone.title)",
                                criteria: currentMilestoneCriteria(),
                                outOfScope: outOfScope,
                                stopBefore: stopBefore)
        // Flat and locked: a subagent cannot call `reach_checkpoint` (main-principal only), so a
        // ladder here would loop it to its iteration cap.
        unit.milestones = []
        unit.lock()
        return unit
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MilestoneUnitContractTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 374 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/GoalContract.swift Tests/irisTests/MilestoneUnitContractTests.swift
git commit -m "feat(goal): derive a delegated milestone's unit contract from the ladder

Criteria come from the locked ladder and scope boundaries are inherited, so a
delegated unit cannot reshape the gate it is measured by or escape a restriction
the parent is under.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Extract `performCheckpoint` (refactor, no behaviour change)

`delegate_milestone` needs the exact grade-pause-surface sequence `reach_checkpoint` already performs. Extract it once now, while the only caller is `reach_checkpoint` and the existing tests can prove nothing moved.

**Files:**
- Modify: `Sources/iris/iris.swift` (add the helper near `softStopWithSummary` ~L173; rewrite the `reach_checkpoint` handler body ~L966)
- Test: `Tests/irisTests/ReachCheckpointHandlerTests.swift` (unchanged — it is the regression gate)

**Interfaces:**
- Consumes: `GoalContract.projectedContract(throughMilestone:)`, `AppState.recordCompletionSelfReport`, `.beginGoalEvaluation`, `.setCheckpointPaused`, `GoalEvaluator.shared.evaluate` (all exist)
- Produces: `IrisEngine.performCheckpoint(conversationId:contract:summary:statusReport:workspacePath:via:) async -> String`

- [ ] **Step 1: Confirm the regression gate passes before you touch anything**

Run: `swift test --filter ReachCheckpointHandlerTests`
Expected: PASS, 2 tests. These two tests are the proof that this refactor changes nothing; if they are red before you start, stop and investigate.

- [ ] **Step 2: Add the helper**

In `Sources/iris/iris.swift`, immediately after the `softStopWithSummary` method:

```swift
    /// The checkpoint transition, shared by `reach_checkpoint` (the agent did the milestone itself)
    /// and `delegate_milestone` (a subagent did it).
    ///
    /// Grades the ladder CUMULATIVELY — `projectedContract` across milestones `0...current`, not
    /// just the current one — because that is what catches this milestone's work breaking an
    /// earlier milestone's criterion, which is the reason a checkpoint is a gate and not a status
    /// print. Awaited, not detached: the run is pausing anyway and the human should see the verdict
    /// before re-engaging. `currentMilestone` is deliberately NOT advanced — that is the human's
    /// click (B1 §7). `via` names the delegate when the work was handed off, and is empty otherwise.
    private func performCheckpoint(conversationId: UUID, contract: GoalContract,
                                   summary: String, statusReport: JSONValue?,
                                   workspacePath: String?, via: String = "") async -> String {
        let localState = state
        let projected = contract.projectedContract(throughMilestone: contract.currentMilestone)
        let gradeWorkspace = workspacePath ?? FileManager.default.currentDirectoryPath
        await MainActor.run {
            localState?.recordCompletionSelfReport(for: conversationId, statusJSON: statusReport)
            localState?.beginGoalEvaluation(for: conversationId, contract: projected)
            localState?.setCheckpointPaused(for: conversationId)   // leaves activeGoal set
        }
        if let graderApp = localState {
            await GoalEvaluator.shared.evaluate(contract: projected, workspace: gradeWorkspace,
                                                originatingConversationId: conversationId,
                                                app: graderApp, client: self.client)
        }
        let ladderPos = "\(contract.currentMilestone + 1) of \(contract.milestones.count)"
        await pushToUI(role: .agent,
                       text: "Reached checkpoint \(ladderPos)\(via): \(summary)\nPaused for your review — approve to continue or send me back.",
                       conversationId: conversationId)
        return "Checkpoint \(ladderPos) reached and graded. Paused for user review."
    }
```

- [ ] **Step 3: Rewrite the `reach_checkpoint` handler to call it**

Replace everything in the `reach_checkpoint` branch after the two guards (from `let projected = ...` through the `result = ...` line) with:

```swift
            result = await performCheckpoint(conversationId: conversationId, contract: contract,
                                             summary: summary, statusReport: statusReport,
                                             workspacePath: workspacePath)
```

The branch now reads: pull the contract, guard `hasLadder`, guard `isFinalMilestone`, delegate to the helper.

- [ ] **Step 4: Run the regression gate**

Run: `swift test --filter ReachCheckpointHandlerTests`
Expected: PASS, 2 tests — same as Step 1. The chat message is byte-identical because `via` defaults to `""`.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 374 tests — unchanged from Task 2, since this task adds no tests. That is the point of it.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/iris.swift
git commit -m "refactor(goal): extract performCheckpoint from the reach_checkpoint handler

delegate_milestone needs the same grade-pause-surface sequence. Extracted while
reach_checkpoint is the only caller, so its existing tests prove nothing moved.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `delegate_milestone` — tool, guards, and delegation

The tool ships and delegates. It does **not** reach the checkpoint yet — that is Task 5 — so at the end of this task it behaves like `invoke_subagent` with the milestone's criteria filled in automatically.

**Files:**
- Modify: `Sources/iris/iris.swift` (declaration inside the existing ladder-gated block ~L493; handler after the `reach_checkpoint` branch)
- Test: `Tests/irisTests/DelegateMilestoneTests.swift` (create)

**Interfaces:**
- Consumes: `GoalContract.currentMilestoneUnitContract()` (Task 2), `DelegatedUnit` (Task 1), `SubagentManager.runSubagent(role:task:effort:parentConversationId:unit:maxIterations:client:)` (Task 1)
- Produces: the `delegate_milestone` tool and its handler branch

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/DelegateMilestoneTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Slice B4: `delegate_milestone` hands the current ladder milestone to a bounded subagent.
///
/// Assertions read the PARENT conversation (owned by this test's AppState, which the engine holds
/// directly) and this suite's own client. The subagent itself is spawned through
/// `SubagentManager.shared`, whose AppState is a global another suite can swap — so nothing here
/// asserts on the subagent's conversation. Serialized for the same reason.
@MainActor
@Suite("delegate_milestone (B4)", .serialized)
struct DelegateMilestoneTests {
    /// Routes by principal: the grader offers `submit_evaluation`; the subagent carries the role
    /// prompt. The grader synthesizes verdicts from the criterion ids in its own system prompt,
    /// because `GoalEvaluationParsing` reconciles strictly by id and ladder ids are minted per test.
    final class RoutingClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let uuidPattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderCallCount = 0
        private var subagentCallCount = 0
        private let mainScript: [GeminiResponse]
        private let subagentTerminal: GeminiResponse?

        /// `subagentTerminal` nil ⇒ the subagent never calls goal_complete (it will time out).
        init(main: [GeminiResponse], subagentTerminal: GeminiResponse?) {
            self.mainScript = main
            self.subagentTerminal = subagentTerminal
        }
        var graderCalls: Int { lock.withLock { graderCallCount } }
        var subagentCalls: Int { lock.withLock { subagentCallCount } }

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
                    graderCallCount += 1
                    guard graderCallCount == 1 else { return Self.text("done") }
                    let ids = systemText.matches(of: Self.uuidPattern).map { String($0.output) }
                    let evaluations = JSONValue.array(ids.map {
                        .object(["criterion_id": .string($0), "verdict": .string("met"),
                                 "evidence": .string("verified")])
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
                if systemText.contains("specialized subagent role") {
                    subagentCallCount += 1
                    return subagentTerminal ?? Self.text("still working")
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

    static func delegateCall(role: String = "engineer") -> GeminiResponse {
        response(FunctionCall(name: "delegate_milestone",
                              args: ["role": .string(role), "effort": .string("easy")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    static var subagentDone: GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string("milestone built")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// A two-milestone locked ladder on a fresh AppState, wired into the subagent manager.
    func ladder(on app: AppState, _ id: UUID, currentMilestone: Int = 0) {
        app.createNewConversation(id: id)
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = currentMilestone
        app.setGoalContract(for: id, c)
        SubagentManager.shared.setGlobalState(app)
    }

    @Test("the tool declares no criteria parameter — the ladder is the only source")
    func schemaHasNoCriteriaParameter() {
        let decl = SubagentManager.milestoneDelegationDeclaration()
        let props = decl.parameters?.properties
        #expect(props?["criteria"] == nil, "a criteria parameter would let the model restate its own gate")
        #expect(props?["role"] != nil)
        #expect(props?["effort"] != nil)
        #expect(props?["brief"] != nil)
        #expect(decl.parameters?.required == ["role", "effort"])
        #expect([decl].arrayItemsViolations().isEmpty)
    }

    @Test("delegating spawns a subagent against the milestone, ungraded")
    func delegatesTheMilestone() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        #expect(client.subagentCalls > 0, "a subagent should have run the milestone")
    }

    @Test("with no ladder there is no milestone to delegate")
    func noLadderIsRefused() async {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, GoalContract(objective: "Ship", criteria: [
            Criterion(text: "it works", kind: .qualitative, check: nil)
        ]))
        SubagentManager.shared.setGlobalState(app)
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        #expect(client.subagentCalls == 0, "no ladder must not spawn a subagent")
        #expect(app.conversations.first { $0.id == id }?.goalContract?.checkpointStatus == .running)
    }

    @Test("the final milestone is not delegable")
    func finalMilestoneIsRefused() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id, currentMilestone: 1)
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        #expect(client.subagentCalls == 0, "the final milestone must not spawn a subagent")
        #expect(app.conversations.first { $0.id == id }?.goalContract?.checkpointStatus == .running)
    }
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter DelegateMilestoneTests`
Expected: `delegatesTheMilestone` FAILS (`subagentCalls == 0` — no such tool, so the call falls through to the generic tool path). The two refusal tests may pass vacuously for the wrong reason; that is expected at this step and Task 4's implementation makes them meaningful.

- [ ] **Step 3: Declare the tool**

Add the declaration as a static on `SubagentManager`, immediately after the existing
`toolDeclaration()`. Both are subagent-spawning tools, and declaring it here makes the property
that §3 rests on — that there is no `criteria` parameter — unit-testable without standing up an
engine, exactly as B3 did for `invoke_subagent`:

```swift
    /// The `delegate_milestone` tool schema (slice B4). Note the absence of a `criteria` parameter:
    /// a delegated milestone's definition of done comes from the locked ladder, so the model cannot
    /// restate the gate it is about to be measured by.
    static func milestoneDelegationDeclaration() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "delegate_milestone",
            description: "Hand the CURRENT checkpoint's milestone to a bounded subagent that works it in its own context. Its definition of done is taken from the locked ladder — you do not restate it. When the subagent finishes the milestone, the checkpoint is reached and graded automatically and the run pauses for the user. Use reach_checkpoint instead when you did the work yourself.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "role": Schema(type: "STRING", description: "The persona (e.g. engineer, researcher, code_reviewer)."),
                    "effort": Schema(type: "STRING", description: "The reasoning effort required: easy | medium | hard."),
                    "brief": Schema(type: "STRING", description: "Optional. How to approach the work — context, starting points, gotchas. NEVER criteria: those come from the ladder.")
                ],
                    required: ["role", "effort"]
                )
            )
    }
```

Then in `Sources/iris/iris.swift`, inside the existing
`if principal == .main, let gc = ladderContract, gc.hasLadder, !gc.isFinalMilestone {` block, after
the `reach_checkpoint` declaration:

```swift
            toolsList.append(SubagentManager.milestoneDelegationDeclaration())
```

- [ ] **Step 4: Add the handler**

In `Sources/iris/iris.swift`, immediately after the `reach_checkpoint` branch closes and before `} else if functionCall.name == "submit_evaluation" {`:

```swift
        } else if functionCall.name == "delegate_milestone", principal == .main {
            let contract = await MainActor.run {
                localState?.conversations.first(where: { $0.id == conversationId })?.goalContract
            }
            guard let contract, contract.hasLadder else {
                result = "No checkpoint ladder is active, so there is no milestone to delegate. Use `invoke_subagent` for ad-hoc delegation, or `goal_complete` when the goal is finished."
                return result
            }
            if contract.isFinalMilestone {
                result = "The final checkpoint is not delegable — terminal completion stays a single path. Use `invoke_subagent` with criteria to hand out the work, then call `goal_complete` yourself."
                return result
            }
            guard let unitContract = contract.currentMilestoneUnitContract() else {
                result = "The current checkpoint has no criteria, so there is nothing to delegate."
                return result
            }
            let role = functionCall.args["role"]?.stringValue ?? "engineer"
            let effort = functionCall.args["effort"]?.stringValue ?? "medium"
            let brief = functionCall.args["brief"]?.stringValue
            // The subagent's prompt is the milestone objective plus any approach notes. Its
            // definition of done rides in the contract, not here — nothing the model wrote can
            // change what the work is measured against.
            let task = brief.map { "\(unitContract.objective)\n\nApproach notes from the parent: \($0)" }
                ?? unitContract.objective
            // grade: false — the CHECKPOINT grades these criteria cumulatively (spec §6); grading
            // the subagent too would re-grade the same criteria in a second evaluator loop.
            let rendered = await SubagentManager.shared.runSubagent(
                role: role, task: task, effort: effort, parentConversationId: conversationId,
                unit: DelegatedUnit(contract: unitContract, grade: false), client: self.client)
            result = rendered
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter DelegateMilestoneTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 378 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/iris.swift Tests/irisTests/DelegateMilestoneTests.swift
git commit -m "feat(goal): delegate_milestone hands the current milestone to a subagent

Criteria come from the locked ladder rather than the tool call, so the model
cannot restate the gate it is about to be measured by. Bound ungraded: the
checkpoint grades those criteria cumulatively in the next task.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Reach the checkpoint when the subagent completes

**Files:**
- Modify: `Sources/iris/iris.swift` (the `delegate_milestone` handler from Task 4)
- Test: `Tests/irisTests/DelegateMilestoneTests.swift` (add 2 tests)

**Interfaces:**
- Consumes: `performCheckpoint(conversationId:contract:summary:statusReport:workspacePath:via:)` (Task 3)
- Produces: no new API — completes the handler's success path

- [ ] **Step 1: Write the failing tests**

Add to `Tests/irisTests/DelegateMilestoneTests.swift`:

```swift
@Test("a completed subagent reaches the checkpoint, graded cumulatively and paused")
func completedSubagentReachesCheckpoint() async {
    let app = AppState(); let id = UUID(); ladder(on: app, id)
    let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                               subagentTerminal: Self.subagentDone)
    let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
    await engine.processInput("work", source: "User", conversationId: id)

    let conv = app.conversations.first { $0.id == id }
    #expect(conv?.goalContract?.checkpointStatus == .pausedForReview)
    #expect(conv?.activeGoal != nil, "the goal stays active at a checkpoint pause")
    #expect(conv?.goalContract?.currentMilestone == 0, "advancing is the human's click, not the loop's")
    #expect(conv?.lastGoalEvaluation != nil, "the checkpoint grade must have landed")
    #expect(client.graderCalls > 0)
}

@Test("the checkpoint grade covers earlier milestones, not just the delegated one")
func checkpointGradeIsCumulative() async {
    // Delegating the MIDDLE rung of a three-rung ladder: the projection spans milestones 0...1, so
    // the grade covers the delegated milestone AND the one before it. This is what catches a
    // delegated milestone's work breaking an earlier milestone's criterion — the reason a
    // checkpoint is a gate rather than a status print (B1 §6.3).
    let app = AppState(); let id = UUID()
    app.createNewConversation(id: id)
    let a = Criterion(text: "one", kind: .qualitative, check: nil)
    let b = Criterion(text: "two", kind: .qualitative, check: nil)
    let c = Criterion(text: "three", kind: .qualitative, check: nil)
    var contract = GoalContract(objective: "Ship", criteria: [a, b, c])
    contract.milestones = [Milestone(title: "One", criterionIds: [a.id]),
                           Milestone(title: "Two", criterionIds: [b.id]),
                           Milestone(title: "Three", criterionIds: [c.id])]
    contract.currentMilestone = 1
    app.setGoalContract(for: id, contract)
    SubagentManager.shared.setGlobalState(app)

    let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                               subagentTerminal: Self.subagentDone)
    let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
    await engine.processInput("work", source: "User", conversationId: id)

    let eval = app.conversations.first { $0.id == id }?.lastGoalEvaluation
    #expect(eval?.criteria.count == 2, "milestones 0...1 — the delegated one AND the one before it")
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter DelegateMilestoneTests`
Expected: both new tests FAIL — `checkpointStatus` is `.running` and `lastGoalEvaluation` is nil, because the handler currently returns the subagent's prose without reaching the checkpoint.

- [ ] **Step 3: Complete the success path**

In the `delegate_milestone` handler, replace the final `result = rendered` line with:

```swift
            // The subagent finished the milestone, so the checkpoint is reached: grade cumulatively,
            // pause, and surface the subagent's result beside the verdict. Task 6 adds the status
            // check that keeps a subagent which did NOT complete from getting here.
            result = await performCheckpoint(
                conversationId: conversationId, contract: contract,
                summary: rendered, statusReport: nil,
                workspacePath: workspacePath, via: " via subagent '\(role)'")
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter DelegateMilestoneTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 380 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/iris.swift Tests/irisTests/DelegateMilestoneTests.swift
git commit -m "feat(goal): a completed delegation reaches its checkpoint

The checkpoint grades cumulatively across milestones 0...current, so a delegated
milestone breaking an earlier milestone's criterion is still caught. The human
still advances the ladder.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The failure path and the turn boundary

A subagent that failed, timed out, or was cancelled claimed nothing. It must not pause a human, and the goal loop must continue with the main agent still on the same milestone.

**Files:**
- Modify: `Sources/iris/SubagentManager.swift` (expose the terminal status to the caller)
- Modify: `Sources/iris/iris.swift` (status check in the handler; turn-ending set ~L735)
- Test: `Tests/irisTests/DelegateMilestoneTests.swift` (add 1 test)

**Interfaces:**
- Consumes: `SubagentTerminalStatus` (exists)
- Produces: `SubagentManager.runSubagent(...) async -> (rendered: String, status: SubagentTerminalStatus)`

- [ ] **Step 1: Write the failing test**

Add to `Tests/irisTests/DelegateMilestoneTests.swift`:

```swift
@Test("a subagent that never completes does not pause the human")
func failedSubagentDoesNotCheckpoint() async {
    let app = AppState(); let id = UUID(); ladder(on: app, id)
    // subagentTerminal nil ⇒ the subagent never calls goal_complete and hits its iteration cap.
    let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                               subagentTerminal: nil)
    let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
    await engine.processInput("work", source: "User", conversationId: id)

    let conv = app.conversations.first { $0.id == id }
    #expect(conv?.goalContract?.checkpointStatus == .running, "a milestone nobody claimed done must not pause a human")
    #expect(conv?.lastGoalEvaluation == nil, "nothing claimed done, so nothing to grade")
    #expect(client.graderCalls == 0)
    #expect(conv?.goalContract?.currentMilestone == 0)
}
```

This test relies on the subagent hitting its iteration cap. To keep it fast, Step 3 threads a small `maxIterations` through for this path.

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter DelegateMilestoneTests`
Expected: FAIL — `checkpointStatus` is `.pausedForReview`, because the handler currently checkpoints regardless of how the subagent terminated.

- [ ] **Step 3: Return the terminal status from `runSubagent`**

In `Sources/iris/SubagentManager.swift`, change the return type and the final line:

```swift
    func runSubagent(role: String, task: String, effort: String, parentConversationId: UUID,
                     unit: DelegatedUnit? = nil, maxIterations: Int = 3000,
                     client: (any LLMClientProtocol)? = nil) async -> (rendered: String, status: SubagentTerminalStatus) {
```

The early guard becomes:

```swift
        guard let appState = self.state else {
            return ("Error: AppState not available for subagent execution.", .failed)
        }
```

and the final line becomes:

```swift
        return (result.renderedForParent(), termination.status)
```

Update the two `invoke_subagent` call sites in `iris.swift` to take `.rendered`:

```swift
                    let rendered = await SubagentManager.shared.runSubagent(...).rendered
```
```swift
                result = await SubagentManager.shared.runSubagent(...).rendered
```

Update the existing XCTest call sites in `Tests/irisTests/SubagentManagerTests.swift` — every `let summary = await SubagentManager.shared.runSubagent(...)` becomes `...runSubagent(...).rendered`. There are 5.

Update the Swift Testing call sites in `Tests/irisTests/SubagentGradingTests.swift` the same way — `let rendered = await ...runSubagent(...).rendered`, and `_ = await ...` stays as-is. There are 5.

- [ ] **Step 4: Branch the handler on the status**

In the `delegate_milestone` handler, replace the `let rendered = await SubagentManager.shared.runSubagent(...)` call and the `performCheckpoint` call with:

```swift
            let outcome = await SubagentManager.shared.runSubagent(
                role: role, task: task, effort: effort, parentConversationId: conversationId,
                unit: DelegatedUnit(contract: unitContract, grade: false), client: self.client)

            // Only a `.completed` subagent reaches the checkpoint — it is the run that claimed the
            // milestone is done. Anything else claimed nothing: hand the outcome back to the loop
            // and let the main agent decide whether to delegate again, work the milestone itself,
            // or reach the checkpoint on its own. A milestone nobody claimed done must not
            // interrupt a human.
            guard outcome.status == .completed else {
                result = "\(outcome.rendered)\n\nThe milestone is NOT complete — no checkpoint was reached. Work it yourself, or delegate again."
                return result
            }
            result = await performCheckpoint(
                conversationId: conversationId, contract: contract,
                summary: outcome.rendered, statusReport: nil,
                workspacePath: workspacePath, via: " via subagent '\(role)'")
```

- [ ] **Step 5: Add `delegate_milestone` to the turn-ending set**

In `Sources/iris/iris.swift` (~L735), add one line to the `toolCalls.contains(where:)` predicate:

```swift
                    if toolCalls.contains(where: {
                        $0.name == "goal_complete" ||
                        $0.name == "reach_checkpoint" ||
                        $0.name == "delegate_milestone" ||
                        $0.name == "submit_evaluation"
                    }) {
                        turnFinished = true
                    }
```

On the success path the turn MUST end — the run is paused. On the failure path ending the turn is also correct: the auto-reprompt re-arms the loop (the goal is active and not paused), so the main agent continues on the same milestone at the cost of one extra model call. Unconditional is simpler than branching and behaves correctly either way. Add that reasoning as a comment above the predicate.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter DelegateMilestoneTests`
Expected: PASS, 7 tests. The failure-path test takes a few seconds (the subagent runs to its iteration cap).

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 381 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/SubagentManager.swift Sources/iris/iris.swift Tests/irisTests/
git commit -m "feat(goal): a failed delegation returns to the loop instead of pausing

Only a completed subagent reaches the checkpoint. A run that claimed nothing
hands its outcome back to the main agent, which decides whether to retry,
delegate again, or work the milestone itself.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` (the feature list, beside the Graded Delegation bullet added by B3)
- Modify: `docs/specs/2026-09-13-checkpoint-delegation.md` (status line + as-built notes)

- [ ] **Step 1: Update the README feature list**

Find the `**Graded Delegation:**` bullet and add immediately after it:

```markdown
*   **Checkpoint Delegation:** When a goal has a checkpoint ladder, Iris can hand the current milestone to a subagent that works it in its own context. The milestone's criteria come straight from the locked contract — the agent cannot restate what it is about to be measured against — and when the subagent finishes, the checkpoint is reached and graded automatically, pausing for your review. The grade spans every milestone so far, so work that quietly breaks an earlier milestone is still caught.
```

- [ ] **Step 2: Mark the spec as-built**

Change the status line to:

```markdown
* **Status**: Implemented (2026-09-13). The design below is as-built; deviations are noted in §11.
```

Append:

```markdown
## 11. As-built notes

- **`runSubagent` returns `(rendered:status:)`.** The handler needs the terminal status to decide whether to checkpoint, and B2's prose alone cannot carry it unambiguously. Call sites that only render take `.rendered`.
- **`DelegatedUnit` carries `grade`** (§4.1) and defaults to `true`, so `invoke_subagent`'s graded B3 path reads unchanged at the call site.
- **`performCheckpoint` takes a `via:` string** that names the delegate. It defaults to `""`, which keeps `reach_checkpoint`'s chat message byte-identical.
- **No `criteria_status` self-report on a delegated checkpoint.** `reach_checkpoint` records the agent's per-criterion self-report; a delegated milestone has no equivalent, since the subagent's `SubagentResult` prose is the self-report and it is surfaced in the pause message. `performCheckpoint` is passed `statusReport: nil`.
```

- [ ] **Step 3: Run the full suite one more time**

Run: `swift test`
Expected: PASS, 381 tests.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/specs/2026-09-13-checkpoint-delegation.md
git commit -m "docs: checkpoint delegation in the README and spec as-built notes

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes for the implementer

**The singleton hazard in tests.** `SubagentManager.shared` holds its `AppState` in a global, and suites run in parallel. Assert on the parent conversation (your own `AppState`, which the engine holds directly) and on your own injected client — never on the subagent's conversation, which may have been created in another suite's `AppState`. Mark any suite that calls `runSubagent` `.serialized`.

**The grader reconciles by id, not text.** `GoalEvaluationParsing` matches submitted verdicts to criteria strictly by `criterion_id` UUID, and ladder criterion ids are minted per test. A scripted grader must read the ids out of its own system prompt (the `RoutingClient` in Task 4 does this). A canned payload with a hardcoded id silently yields `cannot_verify` for everything — a green-looking test that asserts nothing.

**Tool calls do not end a turn.** `processInput` runs a `while !turnFinished` loop; only a terminal tool, a text reply, loop detection, or the iteration cap ends it. This is why a subagent or grader gets as many model rounds as it needs inside one call. `EvaluatorTurnLoopTests` pins this.

---

## Execution notes (2026-09-14)

Recorded after the fact, because a plan that reads as a clean run when it wasn't is
misleading to the next person using it as a template.

**Two deviations from the plan as written:**

- **Task 6 grew a fix the plan did not anticipate.** The failure-path test took **83 seconds**,
  because `runSubagent`'s poll loop exited only on `goal_complete` or the iteration cap — so a
  subagent whose engine loop ended *without* terminating held the awaiting parent for the full cap
  (3000 × 100ms, five minutes). The plan's Step 3 hand-waved this as "threads a small
  `maxIterations` through for this path", which would have papered over a real stall. Fixed
  properly instead: the manager now observes the engine task finishing and terminates `.failed`
  after a short grace for an in-flight `goal_complete`. Test went to 0.8s. B4's "a failed
  delegation returns to the loop" behaviour would have been unusable without it.
- **Task 4's tool declaration moved to `SubagentManager.milestoneDelegationDeclaration()`.** The
  plan originally declared it inline in `iris.swift`, where nothing can reach it — which left the
  spec's §9 requirement (assert the schema declares no `criteria` property) untestable. Caught in
  the plan's own self-review, before execution.

**One unrelated blocker, resolved separately:** the test suite turned out to fail most *parallel*
runs on `main` — several suites mutate the `ConfigManager` singleton, whose setters persist to
`UserDefaults`, and the save/mutate/restore idiom cannot be correct under concurrency. See
[#109](https://github.com/sackheads/iris/issues/109); [#108](https://github.com/sackheads/iris/pull/108)
made `--no-parallel` the documented default. Verify B4 with `swift test --no-parallel`.

**Test counts landed where the plan predicted:** 367 baseline → 381 after Task 7.
