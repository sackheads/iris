# Checkpoint Delegation (slice B4) — Design

* **Issues**: [#13](https://github.com/sackheads/iris/issues/13) (inner/outer loop semantics) — the **B-arc capstone**. Builds on **B3** ([2026-08-25-subagent-unit-contract.md](2026-08-25-subagent-unit-contract.md)), **B2** ([2026-08-02-subagent-structured-result.md](2026-08-02-subagent-structured-result.md)), **B1** ([2026-08-01-goal-checkpoint-ladder.md](2026-08-01-goal-checkpoint-ladder.md)), **A** ([2026-07-28-goal-contract.md](2026-07-28-goal-contract.md)), and **C** ([2026-07-29-goal-drift-evaluator.md](2026-07-29-goal-drift-evaluator.md)).
* **Date**: 2026-09-13
* **Status**: Implemented (2026-09-14). The design below is as-built; deviations are noted in §11.

## 1. Overview

B1 gave a goal an ordered **ladder** of milestones, each ending at a checkpoint where the loop pauses and a fresh-context grader reports on the work so far. B3 gave delegation a **bounded unit contract**: a parent can hand a subagent a scoped definition-of-done and get back a trusted verdict.

B4 joins them. A checkpoint's milestone is *already* a bounded unit with a locked definition of done — exactly the shape B3 delegates. `delegate_milestone` hands the current milestone to a subagent and, when the subagent finishes, performs the checkpoint transition itself: cumulative grade, pause, present. The outer loop sequences and gates; the inner loop builds. That is the whole of #13's framing, and with B4 it is mechanized rather than described.

**B4 is deliberately thin.** B3 already made milestone delegation *possible* — the main agent can call `invoke_subagent` today with a milestone's criteria copied into the call. What B4 adds is that it becomes *sanctioned*: criteria are auto-sourced from the locked ladder instead of retyped by the model, the checkpoint is reached without a second round trip, and the work is graded once instead of twice. The small size of this slice is a consequence of B3 having done the heavy lifting, not a sign that something is missing.

## 2. Scope of this slice (B4)

B4 lets the main agent delegate the **current** milestone to a bounded subagent and folds the result into B1's existing checkpoint. It introduces **no new definition of done** — the milestone's criteria, already locked in the contract, are the unit contract.

**No automatic gating (unchanged from B1).** A checkpoint verdict still does not block, advance, or auto-retry anything. `currentMilestone` advances only when the human clicks through, exactly as B1 §7 specifies. Delegation changes *who does the work*, never *who decides*.

**Honesty boundary.** The pause surfaces the subagent's `SubagentResult` — an unverified self-report, per B2 — beside the trusted cumulative verdict from the fresh-context grader. As everywhere else in this arc, a self-report is never rendered as a passed gate.

**Explicitly deferred (deliberate, not silent omissions):**
- **Auto-advance on an all-met verdict → slice D.** Wiring a verdict into an automatic gate needs D's retry cap and `n/a — <reason>` escape hatch; without them it ships trapped goals. B1 §2 deferred this for the same reason and B4 does not reopen it.
- **Delegating the FINAL milestone → out of scope (see §3).**
- **Delegating several milestones in parallel → out of scope.** The ladder is ordered and the loop works one milestone at a time; concurrent milestones would need a merge story for the cumulative grade that nothing yet calls for.
- **Panel affordances for delegation → out of scope.** The pause message names the delegate. A per-rung "delegated to X" badge in `GoalContractPanel` is a possible follow-up, not part of this slice.

## 3. The tool — `delegate_milestone`

A sibling of `reach_checkpoint`, offered under exactly the same conditions and filtered out of the toolset otherwise:

```
delegate_milestone(role: STRING, effort: STRING, brief: STRING?)
```

- **Offered only when `principal == .main && hasLadder && !isFinalMilestone`** — the same filter site `reach_checkpoint` already uses (`iris.swift` ~L493), which carries the final-milestone guard in the toolset itself, with the handler guard as a second layer.
- **`role` / `effort`** mean what they mean for `invoke_subagent`.
- **`brief`** is optional *approach* context for the subagent ("start from the parser in Sources/X"), never criteria.

**There is no `criteria` parameter, deliberately.** The criteria come from `contract.currentMilestoneCriteria()`. B3 established that a subagent does not negotiate its own done-definition, because a self-authored target is the thing the C evaluator exists to distrust. B4 tightens the same screw one turn: here not even the *parent* restates the definition — the locked contract is its only source. A model that could retype the criteria into the delegation call could quietly reshape the gate it is about to be measured by.

**The final milestone is not delegable.** `reach_checkpoint` already guards it (B1 §6.1) so that terminal completion stays a single path through `goal_complete`. B4 keeps that: at the final milestone `delegate_milestone` returns guidance pointing at `invoke_subagent` + `goal_complete`, which routes the work through B3's graded delegation and then the existing terminal grade of the whole contract. Nothing is lost — only the auto-checkpoint convenience, which has no meaning at the final rung.

## 4. Data model — the unit handed down

### 4.1 `DelegatedUnit` (replaces B3's `criteria:` parameter)

B3 passes `criteria: JSONValue?` into `SubagentManager.runSubagent` and grades any `.completed` run that had them. B4 needs a unit that is bound but **not** graded (§6), so the parameter becomes explicit about both halves:

```swift
struct DelegatedUnit: Sendable {
    var contract: GoalContract
    var grade: Bool      // false ⇒ oracle only; `verdict` stays nil
}
```

- `invoke_subagent` parses its JSON criteria as today and passes `DelegatedUnit(contract:, grade: true)` — B3 behaviour, unchanged.
- `delegate_milestone` builds the contract from the milestone and passes `grade: false`.

One way to express a unit, with graded-ness visible at the call site rather than inferred from whether criteria happened to be present. `SubagentResult.unitContract` is still carried in both cases; only `verdict` is gated.

### 4.2 The milestone's unit contract

Built from the parent contract, not authored:

- **`objective`** — the goal objective plus the ladder position and milestone title, so the subagent has the "why" around its bounded "what".
- **`criteria`** — `currentMilestoneCriteria()`, verbatim.
- **`outOfScope` / `stopBefore`** — **inherited from the parent contract.** These are the goal's safety boundaries (don't force-push, stop before spending money), and a subagent running with root in a VM is precisely the context that must not lose them. Dropping them would make delegation a way to launder a restriction.
- **`milestones`** — empty. B3 already strips ladders from unit contracts, because a subagent cannot call `reach_checkpoint` (it is gated to the `.main` principal) and would loop to its iteration cap.

## 5. Flow

1. **Guards.** No ladder → guidance to use `goal_complete`. Final milestone → guidance (§3). Neither spawns a subagent.
2. **Build the unit** (§4.2) from the current milestone.
3. **Run it.** `runSubagent(unit: DelegatedUnit(contract:, grade: false), client: <this engine's client>)`, awaited, exactly as a blocking `invoke_subagent` is.
4. **Not `.completed`** → return the rendered `SubagentResult` plus an explicit "the milestone is NOT complete" line. **No checkpoint, no pause.** The goal loop continues and the main agent decides whether to delegate again, work the milestone itself, or reach the checkpoint on its own. A milestone nobody claimed done must not interrupt a human, and B3 already establishes that a run which claimed nothing is not graded. Repeated failures are bounded by the existing iteration cap.
5. **`.completed`** → the checkpoint transition:
   - Grade **cumulatively**: `projectedContract(throughMilestone: currentMilestone)` → `await GoalEvaluator.evaluate(...)`. Awaited, not detached — the loop is pausing anyway and the human should see the verdict before re-engaging (B1 §6.3).
   - `setCheckpointPaused` — `activeGoal` stays set; the reprompt guard keeps the loop quiet.
   - Surface the subagent's result beside the verdict, naming the delegate and the ladder position.
   - `currentMilestone` does **not** advance. That is the human's click (B1 §7).

**Turn lifecycle.** `delegate_milestone` joins `goal_complete` / `reach_checkpoint` / `submit_evaluation` in the turn-ending set (`iris.swift` ~L722): on the success path the turn *must* end, because the run is now paused. On the failure path ending the turn is also correct — the auto-reprompt re-arms the loop (the goal is active and not paused), so the main agent continues on the same milestone at the cost of one extra model call rather than continuing in-turn. Making it unconditional is simpler than branching and behaves correctly either way.

**Shared checkpoint path.** Step 5 is `reach_checkpoint`'s handler body almost verbatim. Both handlers call one extracted `performCheckpoint(...)` helper rather than maintaining two copies of the grade-pause-surface sequence — the targeted refactor this slice pays for, and a regression-test target proving `reach_checkpoint` behaviour is unchanged.

## 6. Grading (resolved) — why the checkpoint grades, not the subagent

B3 §10 sketched B4 as "the milestone's criteria become the unit contract, the run produces a graded `SubagentResult`, and the checkpoint's verdict = the subagent's verdict." **Taken literally that conflicts with B1** and is not what this slice builds.

B1 §6.3 grades a checkpoint on the **cumulative** projection across milestones `0...N`, and states the reason: *"Cumulative grading catches regressions — milestone N's work breaking an earlier milestone's criterion — which is the entire reason a checkpoint is a gate and not just a status print."* A subagent's B3 verdict covers only its own milestone's criteria. Adopting it as the checkpoint verdict would mean a **delegated checkpoint silently stops catching regressions** — the gate would mean something weaker exactly where work was handed to a less-supervised context.

Resolution: **the subagent is bound to its unit contract but not graded; the checkpoint runs B1's cumulative grade, unchanged.**

- The milestone's criteria are a **subset** of the cumulative projection, so grading the subagent separately re-grades criteria the checkpoint is about to grade anyway — two full evaluator loops (each an LLM run with its own tool calls) for one answer.
- **No signal is lost.** Verdicts are per-criterion and every criterion belongs to exactly one milestone (B1's partition invariant), so "did the delegated unit land?" is read directly off the cumulative verdict by looking at the current milestone's criteria; a `not_met` on an earlier milestone's criterion is a regression, and the two are distinguishable without a second grade.
- The subagent still gets its **oracle** each iteration, so it knows its definition of done while working. That is what the unit contract is for; the verdict was always the parent's artifact, and here the parent is pausing for a human rather than branching on it.

**Consequence for the workspace caveat.** Because the grade happens at the checkpoint through the main agent's effective workspace — B1's existing path — B4 adds no new workspace hazard. B3's sharpened [#68](https://github.com/sackheads/iris/issues/68) concern (a subagent has no bound workspace, so its executable checks grade the process cwd) does not apply to a `grade: false` unit, since no grader runs against the subagent's workspace at all. The pre-existing #68 issue with the main agent's own grading stands unchanged.

## 7. Error handling & edge cases

- **No ladder** → tool not offered; if somehow called, guidance to use `goal_complete`. No subagent spawned.
- **Final milestone** → guidance (§3). No subagent spawned.
- **Subagent `.failed` / `.timedOut` / `.cancelled`** → §5.4: result returned to the loop, no checkpoint, no pause.
- **Grader fails at the checkpoint** (loop ended without `submit_evaluation`) → B1's existing safety net records a `failed` `GoalEvaluation`; the pause presents it honestly rather than hiding it. The human decides.
- **Nested delegation is impossible by construction, not by a guard.** A subagent conversation has no `goalContract`, so `hasLadder` is false and neither `reach_checkpoint` nor `delegate_milestone` is ever offered to it — the same structural argument B1 §2 makes for checkpoints.
- **Called while paused** → cannot occur; the reprompt guard suppresses the loop at a pause. Guidance returned if it somehow does.
- **Amend during a delegated milestone** → `amend_goal_contract` is the main agent's tool and the main agent is blocked awaiting the subagent; the unit contract was snapshotted at spawn, so an amendment cannot retarget a running subagent mid-flight. The next checkpoint grades the amended contract.

## 8. Interaction constraints (fixed, not a blank slate)

- **`GoalEvaluator.evaluate` reused unmodified.** B4 supplies the same projected contract B1 already hands it.
- **B1 ladder semantics untouched** — `currentMilestone` advances only on the human's approve; `checkpointStatus`, the reprompt guard, and the resume affordances are unchanged. `reach_checkpoint` behaviour is byte-for-byte identical after the `performCheckpoint` extraction.
- **`goal_complete` untouched** — still the single terminal path, still the whole-contract grade.
- **B3's grading rule untouched** — only `.completed` runs are graded, and `grade: false` simply means no grade was asked for.
- **No new criteria anywhere.** B4 adds no sub-objectives, no per-delegation targets, nothing self-authored.

## 9. Testing

**Tool surface:**
- `delegate_milestone` is offered when a ladder is active and the current milestone is not final; absent with no ladder; absent at the final milestone.
- Its schema declares no `criteria` property (the gate cannot be restated by the model) and every ARRAY declares `items`.

**Unit construction (pure):**
- The unit contract's criteria are exactly `currentMilestoneCriteria()`; `outOfScope`/`stopBefore` are inherited from the parent; `milestones` is empty; the objective carries the goal objective, the ladder position, and the milestone title.

**Handler / loop (driven by scripted clients, as B3's tests are):**
- Completed subagent → checkpoint paused, a cumulative evaluation recorded on the conversation, `currentMilestone` unchanged, and the grader ran exactly once.
- Non-completed subagent → no pause (`checkpointStatus` still `.running`), no grade, the loop continues, and the tool result says the milestone is not complete.
- Final milestone → guidance returned and no subagent spawned.
- A `grade: false` unit binds the contract (oracle present) and produces `verdict == nil` with `unitContract` carried.

**Regression:**
- `reach_checkpoint` behaviour is unchanged after the `performCheckpoint` extraction (pause, cumulative grade, ladder position, self-report recording).
- `invoke_subagent` with criteria still grades (B3 path) after the `DelegatedUnit` signature change.

## 10. The larger arc (where B4 sits)

B4 closes the B arc: A locked a definition of done, C made it independently gradeable, B1 sequenced it into human re-engagement points, B2 structured what comes out of a subagent, B3 structured what goes in and graded it, and B4 lets a checkpoint hand its milestone to a bounded inner loop.

Remaining, all independent of this arc:
- **D — deterministic done-gates:** the retry cap and `n/a — <reason>` escape hatch that make it safe to *act* on a verdict instead of only presenting it. The natural consumer of everything above.
- **E — the ratchet.**
- **F — ground-truth progress view.**

## 11. As-built notes

- **`runSubagent` returns `(rendered:status:)`.** The handler needs the terminal status to decide whether to checkpoint, and B2's prose alone cannot carry it unambiguously. Call sites that only render take `.rendered`.
- **`DelegatedUnit` carries `grade`** (§4.1) and defaults to `true`, so `invoke_subagent`'s graded B3 path reads unchanged at the call site.
- **`performCheckpoint` takes a `via:` string** naming the delegate. It defaults to `""`, which keeps `reach_checkpoint`'s chat message byte-identical — the regression its existing tests check.
- **No `criteria_status` self-report on a delegated checkpoint.** `reach_checkpoint` records the agent's per-criterion self-report; a delegated milestone has no equivalent, since the subagent's `SubagentResult` prose *is* the self-report and it is surfaced in the pause message. `performCheckpoint` is passed `statusReport: nil`.
- **Unplanned fix: `runSubagent` no longer stalls on a subagent that stops without terminating.** Its poll loop previously exited only on `goal_complete` or the iteration cap, so a subagent whose engine loop ended without calling it — soft-stopped on its own cap, a plain text reply, a thrown turn — held the awaiting parent for 3000 × 100ms, five minutes. It now observes the engine task finishing and terminates `.failed` after a short grace for an in-flight `goal_complete`. This slice's failure path made it visible (an 83-second test), and B4's "return to the loop" behaviour would have been unusable without it.
- **`--no-parallel` is required to verify this work**, per [#109](https://github.com/sackheads/iris/issues/109) — unrelated to delegation, discovered while executing this plan.
