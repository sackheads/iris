# Interactive Human-Judged Verdicts (slice D2) — Design

* **Issues**: [#9](https://github.com/sackheads/iris/issues/9) (deterministic gates) — the **human half**. Builds on **D1** ([2026-09-14-deterministic-done-gates.md](2026-09-14-deterministic-done-gates.md)), **C** ([2026-07-29-goal-drift-evaluator.md](2026-07-29-goal-drift-evaluator.md)), and **A** ([2026-07-28-goal-contract.md](2026-07-28-goal-contract.md)).
* **Date**: 2026-09-18
* **Status**: Implemented (2026-09-18). The design below is as-built; deviations are noted in §12.

## 1. Overview

Slice A gave contracts a `humanJudged` criterion kind: "you decide". Slice C honoured it by refusing to auto-grade one — the grader must never assign `human_pending`, and C §4.4 made that a rule rather than a convention. D1 then built the gate and deliberately let `human_pending` **pass**, because nothing in the system could resolve it and blocking would have trapped every goal carrying one.

So a whole criterion kind currently sits outside the gate. A user can write "the design reads well" into a contract, and it will never fail a goal, because no mechanism exists for them to say it did not.

D2 supplies the missing mechanism: the user accepts or rejects each `humanJudged` criterion, inline in the completion report, and the gate acts on it.

**The one-line version:** the criterion kind that says "you decide" finally lets you decide.

## 2. Scope

D2 touches the **terminal gate only**, matching D1's scope exactly: main principal, locked contract, terminal `goal_complete`. Checkpoints (D3), subagents, and contract-less goals are untouched.

**Explicitly deferred (deliberate, not silent omissions):**
- **Checkpoint judgement → D3.** A `humanJudged` criterion inside a checkpoint's milestone is still surfaced and still non-blocking there. D3 owns the ladder.
- **A cross-conversation review queue → out of scope.** A paused goal is visible in its own conversation's chip. A global "awaiting you" surface is a real feature, but it is a navigation feature, not a gating one.
- **Auto-accept or a judgement timeout → deliberately never.** A `humanJudged` criterion that nobody judges must stall, not quietly pass. `/stop` is the existing escape and remains the only one.

**No new tool, deliberately.** The obvious implementation is a `judge_criterion` tool, and it is the wrong shape: the whole point of `humanJudged` is that the *human* decides. A tool would let the model record a judgement it was never entitled to make, and would cost prompt tokens on every turn for a capability the model must not have (AGENTS.md invariant 6). Accept/Reject are UI actions that call into `AppState` directly.

## 3. Ordering — the agent's problems first

The gate already computes a blocking set (D1 §4). D2 splits what happens next into two classes, in order:

1. **Unwaived `not_met`** → D1's refuse-and-retry, unchanged. The agent can act on these.
2. **Unresolved `human_pending`, and nothing else blocking** → pause for judgement.

If both are present the agent goes back to work first. Asking for judgement on a goal that is about to change underneath the user wastes their attention and may invalidate the judgement they just gave.

## 4. Pause, do not retry

When judgement is the only thing outstanding, the goal **pauses**. `gateAttempts` is **not** incremented.

This is the heart of the slice. A retry cap exists to bound an agent that might fix something; a `humanJudged` criterion is by definition one the agent cannot fix by working. Routing it through D1's retry loop would spend a full evaluator run per attempt on an outcome the agent provably cannot change, then complete ungated at the cap — the trapped-goal failure D1 exists to prevent, wearing a different hat.

## 5. State — and why it is not a `CheckpointStatus` case

`GoalContract` gains:

```swift
var awaitingHumanJudgement: Bool = false   // decodeIfPresent-defaulted (AGENTS.md invariant 1)
var isPaused: Bool { checkpointStatus == .pausedForReview || awaitingHumanJudgement }
```

**Why a separate flag rather than a new `CheckpointStatus` case.** `checkpointStatus == .pausedForReview` is read in **13 places**, and most of them are ladder UI, not loop control: which panel to show, the lock-vs-pause header, the rung state, the pause chip's "Approve & continue" / "Send back" buttons. Those buttons are B1 ladder actions and are wrong for a judgement pause.

Decisively: `ChatView` suppresses the **completion report chip** while `checkpointStatus == .pausedForReview` — and that chip is exactly where D2's Accept/Reject buttons live. Reusing the checkpoint status would hide the UI this slice needs.

So `isPaused` replaces `checkpointStatus == .pausedForReview` at exactly **two** sites, both of which mean "suppress the loop":

- the auto-reprompt guard (`iris.swift`, the `activeGoal != nil, !paused` condition);
- the resume-on-restart guard (`iris.swift`, `shouldResume`) — so a goal paused for judgement does not silently resume itself on the next launch.

Every other reader keeps `checkpointStatus == .pausedForReview`, because every other reader is asking a ladder question.

## 6. The verdict, and its honesty

`VerdictMethod.human` **already exists** — slice C modelled it and nothing has used it until now. So a judgement is recorded on the existing `CriterionVerdict`:

| Action | `verdict` | `method` |
|---|---|---|
| Accept | `.met` | `.human` |
| Reject | `.notMet` | `.human` |

The row renders **"met — your judgement"**, never a bare ✓. A human accept is not grader-verified evidence, and the panel's whole job across this arc is keeping those apart. `method` is the field that already encodes the difference; D2 is the first slice to make it visible.

## 7. Resuming

The last judgement landing re-evaluates the gate **without re-running the grader**. The verdicts are already in hand; a second evaluator run would spend minutes re-deriving what the user just decided, and would overwrite their judgement with a fresh `human_pending`.

- **All accepted** → `awaitingHumanJudgement = false`, `gateOutcome = .passed`, the goal completes exactly as D1 completes it.
- **Any rejected** → `awaitingHumanJudgement = false`, the goal stays active, and the reprompt carries the agent back with the rejected criteria named. A rejection converts a criterion the agent could not affect into a `not_met` it can.

A rejection deliberately does **not** consume a gate attempt either: the agent has not yet had a chance to respond to it. The next `goal_complete` grades normally, and `not_met` from that point behaves as D1 specifies.

## 8. Error handling & edge cases

- **The contract has no `humanJudged` criteria** → nothing changes; the pause never triggers.
- **Judgement on a goal that is no longer paused** (a stale click after `/stop`, or after the goal completed) → ignored, returning false. The button acts on `lastGoalEvaluation`, which outlives the goal.
- **A grader wrongly returns `human_pending`** → already impossible: `GoalEvaluationParsing` downgrades a submitted `human_pending` to `cannot_verify` (C §4.3). D2 does not relax that; only the system assigns `human_pending`.
- **Grader `.failed`** → its verdicts are placeholders, so `human_pending` among them is not a real judgement request. D1 already completes with `ungatedGraderFailed` and never reaches the pause.
- **Restart while paused** → `awaitingHumanJudgement` persists on the contract and the resume guard (§5) keeps the loop quiet until the user acts.
- **Legacy contract** → no key, decodes false, behaves exactly as before.

## 9. Interaction constraints (fixed, not a blank slate)

- **`GoalEvaluator` unmodified** — D2 never re-runs it, and never asks it to judge.
- **D1's retry loop, cap, and `waive_criterion` unmodified.** A waiver remains the agent's escape hatch for a criterion that does not apply; judgement is the human's verdict on one that does.
- **B1's ladder and its pause unmodified**, including every UI reader of `checkpointStatus`.
- **No new tool** (§2), so AGENTS.md invariant 6 has nothing to gate.

## 10. Testing

**Pure:**
- `isPaused` is true for a checkpoint pause, true for a judgement pause, false otherwise.
- `awaitingHumanJudgement` Codable round-trip; a pre-D2 contract decodes false with no throw; a `Conversation` carrying one still decodes.

**Gate behaviour:**
- `not_met` + `human_pending` together → refuses and retries (agent first), and does **not** pause.
- `human_pending` alone → pauses, `gateAttempts` unchanged, goal still active, grader ran exactly once.
- Accepting the last outstanding criterion → completes, `gateOutcome == .passed`, verdict `.met` with `method == .human`, and the grader did **not** run again.
- Rejecting → goal stays active, `awaitingHumanJudgement` false, verdict `.notMet` with `method == .human`.
- A judgement recorded while not paused is ignored.

**Regression:**
- A contract with no `humanJudged` criteria behaves exactly as D1.
- A checkpoint pause still shows the checkpoint chip and still suppresses the completion chip.
- The resume-on-restart path does not resume a goal paused for judgement.

## 11. The larger arc

With D2, every criterion kind is inside the gate: `executable` and `qualitative` through the grader, `humanJudged` through the user. Remaining:
- **D3 — checkpoint gating:** auto-advance on an all-met verdict, deferred here and by B1 §2 and B4 §2.
- **E — the ratchet**, **F — ground-truth progress view** — independent, per the slice-A roadmap.

## 12. As-built notes

No deviations. The implementation across Tasks 1-6 matches this design exactly:

- `awaitingHumanJudgement` and `isPaused` on `GoalContract` are exactly as specified in §5, with the `decodeIfPresent`-defaulted decode (AGENTS.md invariant 1).
- `isPaused` replaces `checkpointStatus == .pausedForReview` at precisely the two sites named in §5 — the auto-reprompt guard and the resume-on-restart guard in `iris.swift` — and nowhere else; every ladder-UI reader (`ChatView`, `GoalContractPanel`) still reads `checkpointStatus == .pausedForReview` directly.
- `recordHumanJudgement` and `resolveJudgementIfComplete` in `AppState.swift` implement §6 and §7 verbatim: the grader is never re-run on resume, a rejection does not consume a gate attempt, and the verdict is stamped with `method == .human` so the row renders "met — your judgement" rather than a bare checkmark.
- `beginJudgementPause` leaves `gateAttempts` untouched, per §4.
- No `judge_criterion` (or any) tool was added; §2's "no new tool" holds, and `HumanJudgementScopeTests.noJudgementTool` drives a real engine turn to confirm no tool name offered to the model contains "judge".
- `HumanJudgementScopeTests.checkpointPauseIsUnchanged` confirms the two pauses stay distinct: a checkpoint pause leaves `awaitingHumanJudgement == false` while still satisfying `isPaused`.
