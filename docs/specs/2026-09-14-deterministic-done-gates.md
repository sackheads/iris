# Deterministic Done-Gates (slice D1) — Design

* **Issues**: [#9](https://github.com/sackheads/iris/issues/9) (deterministic gates) — the **gate loop**. Consumes **C** ([2026-07-29-goal-drift-evaluator.md](2026-07-29-goal-drift-evaluator.md)) and **A** ([2026-07-28-goal-contract.md](2026-07-28-goal-contract.md)).
* **Date**: 2026-09-14
* **Status**: Approved (design)

## 1. Overview

Slice A locked a definition of done. Slice C made it independently gradeable and produced a trusted per-criterion verdict. Every slice since has *presented* that verdict and deliberately refused to act on it — A §7, C §2, B1 §2, and B4 §2 all defer automatic gating to D, each for the same stated reason: acting on a verdict without a retry cap and an escape hatch ships **trapped goals**.

D1 acts on it. `goal_complete` stops being advisory: a goal with a locked contract completes only when the grader finds nothing failing, the agent has waived what genuinely does not apply, or the retry cap is reached — in which case it completes and says so plainly.

**The one-line version:** the contract stops being a document the agent is asked to respect and becomes a gate it has to get past.

## 2. Scope of this slice (D1)

D1 gates **terminal `goal_complete`, for the main agent, with a locked contract**. Everything else is untouched.

- **No contract ⇒ no gate.** A contract-less goal completes exactly as today. (And since [#84](https://github.com/sackheads/iris/issues/84), a chat with no goal at all is not offered the tool.)
- **Main principal only.** `contractToGrade` is already `principal == .main`, so the boundary exists; subagent termination (B2/B3) is unchanged.
- **Checkpoints unchanged.** `reach_checkpoint` still pauses for a human and never auto-advances. That is D3.

**Explicitly deferred (deliberate, not silent omissions):**
- **Interactive `humanJudged` verdicts → D2.** A human accept/reject that feeds the gate. Until it exists, `human_pending` must not block (§4), or every goal carrying a `humanJudged` criterion would exhaust its retries by construction — precisely the trapped goal this slice exists to prevent.
- **Checkpoint gating / auto-advance → D3.** B1 §2 and B4 §2 both deferred it here; it changes the ladder's human-in-the-loop guarantee and deserves its own argument rather than riding along with this one.
- **Changing `GoalEvaluator` → out of scope.** Every slice since C has consumed the evaluator unmodified, and D1 does too.

## 3. The central change: the terminal grade is awaited

Today `goal_complete` fires the grade in a `Task.detached` and returns immediately; the verdict lands later and fills in a chip. A gate cannot be built on that — the decision to complete happens before the evidence exists.

So the terminal grade becomes **awaited**. `reach_checkpoint` (B1) and subagent unit grading (B3) already await, so the pattern is established; D1 is the first time the *terminal* path pays for it.

**What this costs, stated plainly.** Completion now blocks on a full evaluator run: a fresh-context LLM loop with its own tool calls, taking seconds to minutes. A goal that fails twice before passing pays for three evaluator runs plus two extra rounds of agent work. That is real latency and real money on every goal that does not pass first time. The mitigations are the cap (§6) and the pass rule (§4) — `cannot_verify` not blocking means the common environmental failure does not burn retries. If the cost is still wrong for a given setup, the lever is the cap default, not the design.

The existing `.verifying` snapshot (`beginGoalEvaluation`) already renders a spinner in the panel, so the wait is visible rather than a hang.

## 4. The pass rule

`CriterionVerdictValue` has four values. Only one blocks:

| Verdict | Gate | Why |
|---|---|---|
| `met` | pass | — |
| `not_met` | **BLOCK** | Positive evidence the work is not done. |
| `cannot_verify` | pass, recorded | The **grader** could not determine this. Retrying the agent does not change a grader capability problem, so blocking would burn the cap on something the agent cannot fix. Often environmental — [#68](https://github.com/sackheads/iris/issues/68) produces exactly this verdict. |
| `human_pending` | pass, recorded | A `humanJudged` criterion is never auto-graded (C §4.4). Blocking traps every goal that has one until D2. |

**The gate acts on evidence of failure, not on absence of evidence.** Non-blocking verdicts are still recorded and rendered — the honesty lives in the report, not in the block.

The obvious objection: an agent could make criteria unverifiable to slip through. That is bounded by A's design — criteria are locked *before* the work starts, and changing them requires `amend_goal_contract` with a mandatory rationale that is change-logged and shown to the user.

## 5. `waive_criterion` — the escape hatch

```
waive_criterion(criterion_id: STRING, reason: STRING)
```

**Offered only when a locked contract exists AND at least one grade has already failed** (`gateAttempts > 0`). The agent must actually try before declaring something inapplicable; a waiver available on the first attempt would be a gate that can be skipped in one move.

Stored on the contract as `waivers: [UUID: String]` — criterion id to reason. `decodeIfPresent`-defaulted, or a contract persisted before D1 fails to decode and takes **every conversation** with it.

**The grader still grades a waived criterion.** The contract handed to `GoalEvaluator` is unchanged; only the *gate* ignores a waived criterion's `not_met`. The report then shows the verdict and the waiver side by side:

```
✗ docs published — not_met: no docs/ directory found
  WAIVED by the agent: "this repo has no docs site; nothing to publish"
```

A waiver never erases evidence, and it is never rendered as `met`. This also keeps `GoalEvaluator` untouched (§2).

## 5.1 Data model — and where it has to live

Two pieces of state, in two places, for a reason worth spelling out.

**On `GoalContract` — live state for the run in progress:**

```swift
var waivers: [UUID: String] = [:]   // criterion id → reason
var gateAttempts: Int = 0           // refusals so far; reset when a contract locks
```

Both `decodeIfPresent`-defaulted. A contract persisted before D1 has neither key, and a synthesized decoder would throw and take **every conversation** with it.

**On `GoalEvaluation` — what survives completion:**

```swift
var gateOutcome: GateOutcome?       // .passed | .ungatedAtCap | .ungatedGraderFailed
var waivers: [UUID: String] = [:]   // snapshot of what was waived, and why
```

This is not duplication. `clearGoal` sets `goalContract = nil` on completion, so anything living only on the contract disappears **at exactly the moment the report needs it** — the user would see a completion with no trace of what was waived or that the gate was never passed. `lastGoalEvaluation` is not cleared, so it is the artifact that outlives the run, and the honest record has to ride on it.

Both new fields are `decodeIfPresent`-defaulted for the same reason as above. `gateOutcome` is Optional so a pre-D1 evaluation decodes to nil and simply renders as it always did.

## 6. State, the cap, and the loop

`gateAttempts: Int` on `GoalContract` (`decodeIfPresent`-defaulted, same data-safety rule as `waivers`), incremented on each refusal and reset to 0 when a contract is locked.

**The cap defaults to 3**, configurable through `ConfigManager` beside `maxGoalIterations`.

The retry loop needs **no new machinery**. On a refusal the handler simply does not clear the goal, so `activeGoal` stays set and the existing auto-reprompt carries the agent back to work — the same mechanism that drives every goal iteration today.

**Flow:**

1. `goal_complete` with a locked contract → snapshot `.verifying`, await the grade.
2. Blocking set = criteria with `not_met` that are **not** waived.
3. **Empty** → complete: clear the goal, record the report, fire the skill-check reflection, return normally.
4. **Non-empty, `gateAttempts < cap`** → refuse. Increment `gateAttempts`. Do **not** clear the goal. Return a tool result naming each blocking criterion with the grader's evidence, and noting `waive_criterion` is available for anything that genuinely does not apply.
5. **Non-empty, `gateAttempts >= cap`** → complete with `gateOutcome = .ungatedAtCap`, where N is the size of the blocking set: *"completed without passing: N criteria not met"*. Surfaced in the completion report and the chip. The goal always terminates.

On every path that completes, the waiver map is copied from the contract onto the recorded evaluation (§5.1) before `clearGoal` runs, so the report survives the contract's destruction.

## 7. Error handling & edge cases

- **Grader `.failed`** (crashed, hit its cap, never submitted) → its verdicts are placeholders, not findings (see #54's `.failed` treatment). A failed grade **does not block**: blocking on a non-result would trap a goal on a grader bug. Completion proceeds with `gateOutcome = .ungatedGraderFailed`, and the panel's existing `.failed` treatment already distinguishes this from a real grade.
- **`waive_criterion` before any failed grade** → not offered; if called anyway, returns guidance explaining it unlocks after a grade fails.
- **`waive_criterion` with an unknown id** → returns guidance listing the contract's criterion ids.
- **All criteria waived** → completes, with every waiver shown. Loud in the report by construction, and the human sees a completion that passed nothing.
- **Amend during the gate loop** → `amend_goal_contract` still works. A criterion removed by an amendment leaves the blocking set naturally; its waiver entry, if any, becomes inert (keyed by an id no longer present) and is ignored when rendering.
- **Legacy contract** → no `waivers`/`gateAttempts` keys; both default, and a pre-D1 goal behaves exactly as before.
- **Paused at a checkpoint** → cannot coincide with terminal `goal_complete`: the B1 ladder gate redirects a non-final `goal_complete` to `reach_checkpoint` before any of this runs. Asserted in a test rather than assumed, because §6.4's refusal depends on the auto-reprompt, which is suppressed while paused.

## 8. Interaction constraints (fixed, not a blank slate)

- **`GoalEvaluator.evaluate` reused unmodified** — D1 only awaits it instead of detaching it.
- **Subagent and checkpoint semantics untouched** — B2/B3/B4 termination and the B1 ladder behave exactly as before.
- **The #16 soft-stop machinery is unchanged.** A soft-stop turn sets `restrictToGoalComplete`, which must bypass the gate entirely: it is an emergency termination and must be able to end a goal regardless of any verdict. Same carve-out the ladder gate already makes.
- **No contract ⇒ no behaviour change**, including the #84 path.

## 9. Testing

**Pure:**
- `waivers` / `gateAttempts` Codable round-trip on `GoalContract`, and `gateOutcome` / `waivers` on `GoalEvaluation`; a pre-D1 contract and a pre-D1 evaluation each decode with every new field defaulted (no wipe).
- The waiver map reaches the recorded evaluation, so it still renders after `clearGoal` has destroyed the contract.
- Blocking-set computation: `not_met` blocks; `cannot_verify`, `human_pending`, and waived `not_met` do not.

**Handler / loop (scripted clients, as B3/B4's tests are):**
- All met → completes first time, one evaluator run, goal cleared.
- One `not_met` → refused, goal NOT cleared, `gateAttempts == 1`, and the refusal text names the criterion and its evidence.
- Refuse → agent waives → next attempt completes, and the report carries both the `not_met` verdict and the waiver reason.
- Cap reached → completes, recorded as ungated with the count of unmet criteria.
- `cannot_verify` only → completes first time (does not block, does not retry).
- Grader `.failed` → completes, recorded as ungated, does not retry.
- `waive_criterion` is not offered before a failed grade, and returns guidance if called.
- **Regressions:** a contract-less goal completes unchanged; a subagent's `goal_complete` is ungated; `reach_checkpoint` is unaffected; a soft-stop (`restrictToGoalComplete`) completes regardless of verdict.

## 10. The larger arc

With D1, a verdict finally *does* something. Remaining:
- **D2 — interactive `humanJudged` verdicts:** a human accept/reject feeding the gate, which lets `human_pending` become blocking.
- **D3 — checkpoint gating:** auto-advance a checkpoint on an all-met verdict; deferred here by B1 §2 and B4 §2.
- **E — the ratchet**, **F — ground-truth progress view** — independent, per the slice-A roadmap.
