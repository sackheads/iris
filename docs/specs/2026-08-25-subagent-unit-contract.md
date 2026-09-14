# Bounded-Unit Contract for the Inner Loop (slice B3) — Design

* **Issues**: [#13](https://github.com/sackheads/iris/issues/13) (inner/outer loop semantics) — the **in-envelope half**. Builds on merged **slice B2** ([2026-08-02-subagent-structured-result.md](2026-08-02-subagent-structured-result.md)), **B1** ([2026-08-01-goal-checkpoint-ladder.md](2026-08-01-goal-checkpoint-ladder.md)), **A** ([2026-07-28-goal-contract.md](2026-07-28-goal-contract.md)), and **C** ([2026-07-29-goal-drift-evaluator.md](2026-07-29-goal-drift-evaluator.md)).
* **Date**: 2026-08-25
* **Status**: Implemented (2026-09-13). The design below is as-built; deviations are noted inline.

## 1. Overview

B2 gave a subagent's *result* structure — the **out-envelope** of the outer/inner boundary — but a subagent's completion is still self-graded: `SubagentResult.summary` is the subagent's own unverified words, and nothing checks whether the delegated unit was actually finished.

B3 adds the **in-envelope**: the parent hands the subagent a scoped **definition-of-done** — a `GoalContract` for the *unit* — and on completion the subagent is graded by the existing slice-C evaluator. `SubagentResult` gains a **trusted verdict** beside B2's unverified `summary`, exactly as B1's checkpoint pause places a self-report next to a fresh-context grade. After B3 the outer loop can *trust* whether a delegated unit landed.

This is the mirror of B2: B2 structured what comes *out* of a subagent; B3 structures what the parent sends *in* and adds the verified grade on the way back.

## 2. Scope of this slice (B3)

B3 lets the **parent** author a bounded contract for a delegated unit and grades the subagent against it. It does **not** let the subagent negotiate its own contract, and it does **not** wire the B1 ladder to delegation.

**The optional-contract seam (backwards-compat spine).** `invoke_subagent` with **no** `criteria` behaves exactly as B2 today: free-text task, no contract, no grade, byte-for-byte-identical result prose. Criteria present → contracted, graded, verdict in the result. B3 is purely additive; every existing subagent call keeps working unchanged.

**Parent-authored, not subagent-negotiated (deliberate).** The outer loop holds the contract and delegates a bounded unit (#13's framing). A subagent negotiating its own done-definition — as `/goal` does for the main agent — would reintroduce the self-authored-target problem the C evaluator exists to distrust. The parent writes the unit's criteria into the `invoke_subagent` call; the subagent runs against them, it does not define them.

**Honesty boundary.** The subagent's `summary` and its per-criterion `criteria_status` self-report remain **unverified** (its own context did the work). The new `verdict` is the only trusted signal, produced by a fresh-context grader that never saw the subagent's transcript. The two sit side by side in the prose, labeled; a subagent self-report is never rendered as a passed gate.

**Explicitly deferred (deliberate, not silent omissions):**
- **Checkpoint→milestone delegation → slice B4.** A B1 checkpoint handing its milestone to a bounded subagent (the milestone's criteria become the unit contract, the checkpoint's verdict = the subagent's verdict) is the B-arc capstone. B3 touches neither the ladder nor `reach_checkpoint`; the "parent authors the contract" mechanism generalizes directly into it.
- **Grading non-`.completed` runs → out of scope.** Only a subagent that terminates `.completed` is graded (it claimed the unit is done). A `.failed`/`.timedOut`/`.cancelled` subagent claimed nothing to grade; its status carries the story and `verdict` stays nil. Grading partial progress is a possible later extension, not B3.
- **Subagent-negotiated contracts → out of scope (see above).**

## 3. Contract input — `invoke_subagent` gains `criteria`

The `invoke_subagent` tool schema gains one optional parameter, `criteria`, an array using slice A's exact `Criterion` shape:

```
criteria: [ { text: STRING, kind: "executable" | "qualitative" | "humanJudged", check: STRING? } ]
```

- `task` becomes the contract **objective**.
- `kind` and `check` mean exactly what they mean in slice A: an `executable` criterion carries a runnable `check` (e.g. `swift test`) the grader re-runs; `qualitative` is a concrete "done looks like X" with no command; `humanJudged` is never auto-graded.
- Parsing reuses `GoalContractParsing` (the same code that builds the main agent's contract from `propose_goal_contract`). Empty/invalid criteria are skipped exactly as that parser already does.
- The tool `description` gains one sentence: criteria are optional; when provided, the run is graded by an independent evaluator and the verdict is returned to you.

## 4. Data model — `SubagentResult` additions

Two new `decodeIfPresent`-defaulted fields on `SubagentResult` (persisted on `Conversation`, same data-safety rule as B2 — a missing key must decode to nil, never wipe conversations):

```swift
var unitContract: GoalContract?   // the bounded contract the subagent ran against; nil ⇒ B2-style ungraded run
var verdict: GoalEvaluation?      // trusted C grade; present iff the subagent .completed WITH a unit contract
```

`GoalEvaluation` is already `Codable` (a `status` plus `[CriterionVerdict]`) — reused unchanged. `unitContract` is carried on the result so it is self-describing (renderers and B4 can show criteria beside verdicts without re-deriving them).

## 5. Flow

1. **Delegate.** Parent calls `invoke_subagent(role, task, effort, criteria?)`.
2. **Bind the unit.** `SubagentManager.runSubagent`: if `criteria` are present, build a **locked** `GoalContract{objective: task, criteria}` and set it on the subagent conversation via `setGoalContract` — so the slice-A **oracle** (`oracleText()`) is injected each iteration, the same mechanism the main agent uses. With no criteria, `setGoal(task)` — the B2 path, unchanged.
3. **Work.** The subagent runs against the oracle and calls `goal_complete` with its per-criterion `criteria_status` self-report (**unverified**, recorded on the subagent conversation via the existing `recordCompletionSelfReport`).
4. **Grade on completion (in `SubagentManager`, B2's single assembly point).** If the terminal status is `.completed` **and** a unit contract is present: `await GoalEvaluator.evaluate(contract:, workspace: <subagent's effective workspace>, originatingConversationId: subagentId, app:, client:)`, then read back `conversations[subagentId].lastGoalEvaluation` → `verdict`. The grade is **awaited, not detached** (like B1's checkpoint): the parent should receive the verdict *in* the result. Fold `unitContract` + `verdict` into the assembled `SubagentResult`.
5. **Render.** The prose gains a verdict block beside B2's lines:

```
Subagent 'engineer' finished — status: completed (goal_complete called).
Summary: <unverified — the subagent's own words>
Files written (2): Sources/A.swift, Tests/AT.swift
Independent grader verdict: 2/3 met
  ✓ builds — met
  ✓ tests pass — met
  ✗ verdict rendered in prose — not_met: <evidence>
```

The unverified self-report and the trusted verdict sit side by side, labeled. The struct is the programmatic artifact; the prose is the parent's branch surface.

## 6. Grader placement (resolved)

The subagent is graded **exactly the way the main agent is graded today**: `GoalEvaluator.evaluate` spins up a fresh `.evaluator`-principal conversation, sets *its* workspace to the target directory, and re-runs the executable checks in its own sandbox container mounting that workspace. B3 changes nothing in the evaluator — it only points `workspace:` at the subagent's effective workspace and `originatingConversationId:` at the subagent.

**Workspace (narrowed in review).** The verdict is only as trustworthy as the directory it is graded in. The original form of this caveat said a subagent never has a bound workspace, so executable checks grade the process cwd — the Iris source repo — and `swift test` would report `met` regardless of what the subagent did. Review identified the root cause as narrower than [#68](https://github.com/sackheads/iris/issues/68): `runSubagent` simply never copied the **parent's** workspace onto the subagent, so delegation dropped context the parent already had. It now inherits it, and the grader follows the subagent's effective workspace, so a bound parent workspace is graded correctly.

The residual is exactly #68 and no more: when the parent itself has no bound workspace, both sides fall back to the process cwd and an `executable` criterion can still be graded against the wrong tree. Qualitative criteria are unaffected either way.

**Inherited caveat (stated, not introduced):** both `.subagent` and `.evaluator` principals always intend `.sandboxed`, and each conversation gets its own container. `write_file` output lands on the host workspace (visible to the grader's mounted workspace); a `check` that depends on tools the subagent installed only inside *its own* container may read `not_met` in the fresh grader container. This is a pre-existing property of how the main agent is graded, accepted here for consistency, not a new B3 behavior.

## 7. Error handling & edge cases

- **No criteria** → no contract, no grade; `unitContract`/`verdict` nil; B2 prose unchanged.
- **`.failed` / `.timedOut` / `.cancelled` (even with a contract)** → **not graded**; `verdict` nil; the status carries the outcome.
- **Grader fails** (loop ended without `submit_evaluation`) → the evaluator's *existing* safety net records a `failed` `GoalEvaluation`; B3 surfaces it honestly (verdict present, status `failed`) rather than hiding it.
- **Legacy decode** → a `SubagentResult`/`Conversation` persisted before B3 (no `unitContract`/`verdict` keys) decodes to nil for both, no wipe.
- **Grader-container tool gap** → §6 caveat; a criterion may read `not_met`.

## 8. Interaction constraints (fixed, not a blank slate)

- **`GoalEvaluator.evaluate` reused unmodified** — B3 only supplies the subagent's workspace and awaits it.
- **B2 untouched** — the `SubagentResult` envelope, the `write_file` ledger, the four termination sites, and the prose base are unchanged; B3 only *adds* two fields and a verdict block.
- **B1 ladder & `goal_complete` semantics untouched** — subagents still terminate via `goal_complete`; the new grade-on-completion work lives in `SubagentManager`, not in the shared `goal_complete` handler, so the main-agent terminal path is unaffected.
- **`GoalContractParsing` reused** — the parent's `criteria` are parsed by the same code that parses `propose_goal_contract`.

## 9. Testing

**Parsing / binding:**
- `invoke_subagent` with `criteria` parses into a locked `GoalContract` on the subagent conversation (objective = task); with no `criteria`, the subagent gets a plain `activeGoal` and no contract.

**Handler / loop (driven by `ScriptedLLMClient` + `SubagentManager`, as B2's tests are):**
- Contracted subagent that completes → `SubagentResult.verdict` is populated and `unitContract` carried (script: subagent `goal_complete`, then grader `submit_evaluation`).
- No-criteria subagent → `verdict`/`unitContract` nil, and the returned prose is byte-for-byte the B2 output (regression).
- `.timedOut` (or `.failed`) **with** a contract → `verdict` nil (not graded).
- Prose renders the verdict block when a verdict is present and omits it when nil.

**Pure:**
- Codable round-trip of the new fields; a legacy `SubagentResult` without them decodes clean.

## 10. The larger arc (where B3 sits)

Remaining B-arc:
- **B4 — checkpoint delegation (capstone):** a B1 checkpoint may hand its milestone to a bounded subagent — the milestone's criteria become the unit contract (§3), the run produces a graded `SubagentResult` (this slice), and the checkpoint's verdict is the subagent's verdict. Depends on B1 + B2 + B3.
- **D — deterministic done-gates**, **E — the ratchet**, **F — ground-truth progress view** — independent, per the slice-A roadmap.

## 11. As-built notes (2026-09-13)

Deviations from and clarifications to the design above, recorded at implementation:

- **Milestone labels in `criteria` are stripped.** `GoalContractParsing` groups criteria into milestones when they carry a `milestone` label. B3 does not wire the ladder to delegation (§2), and a ladder here would actively strand the run: the oracle would instruct the subagent to call `reach_checkpoint`, which is gated to the `.main` principal, so the subagent would loop to its iteration cap instead of finishing. `unitContract(task:criteriaJSON:)` therefore drops any milestone grouping.
- **`unitContract` is carried for every contracted run, not only graded ones.** §4 describes it as "nil ⇒ B2-style ungraded run". As built, it is present whenever a contract was bound — including a `.timedOut`/`.failed` run — because the subagent did run against it and the parent benefits from seeing what it was held to. Only `verdict` is gated on `.completed`.
- **The self-report line is relabeled only when a verdict is present.** With a trusted grade beside it the summary renders as `Summary (UNVERIFIED self-report): …`; with no verdict there is nothing to contrast it against and the line stays byte-for-byte as slice B2 wrote it, preserving the regression guarantee in §2.
- **The grader's client is the parent engine's client**, threaded through `runSubagent(client:)` — the same pattern `goal_complete` already uses for the main agent's grade, and what makes the loop tests network-free.
- **`invoke_subagent`'s schema moved to `SubagentManager.toolDeclaration()`** so the contract-input shape is unit-testable without standing up an engine. Behaviour is unchanged; the `criteria` ARRAY declares `items` (Gemini rejects arrays without it).
