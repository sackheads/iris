# Checkpoint Auto-Advance (slice D3) — Design

**Status:** implemented on `feat/checkpoint-auto-advance`; inline checkpoint judgement deferred (see §6)
**Issue:** #13 (inner/outer loop semantics), #9 (deterministic gates)
**Deferred here by:** B1 §2, B4 §2, D1 §10, D2 §11

## 1. Overview

A checkpoint that the grader passes cleanly no longer stops the human. `reach_checkpoint` grades
the projected contract as it does today, and then decides: an uncontested clean grade advances the
ladder and the agent keeps working; anything else pauses for review exactly as now.

**The problem this solves is checkpoint fatigue, not unattended progress.** Stopping a human on
milestones that obviously passed trains them to click "Approve & continue" without reading, which
destroys the ladder's value as surely as having no ladder. D3 spends the human's attention only
where the grade is contested. They remain in the loop — less often, and for a reason.

**Honesty boundary.** This reduces human oversight on the happy path. That is the intent, but it
has a cost: a grader false-`met` now advances unobserved, where previously a human saw the verdict.
The strict rule (§3) and the fail-safe default (§4) are the whole of what is traded on, and they
are only as good as the grader. D3 does not claim to make the grader more trustworthy. It claims
that a human who reads three contested checkpoints is worth more than one who skims twelve.

## 2. Scope

D3 touches the **checkpoint ladder only**: `reach_checkpoint`, including B4's delegated path.
The terminal `goal_complete` gate (D1/D2) is untouched — it always grades and always gates.

Out of scope, deliberately:

- **Retroactive review and send-back → slice F.** F is "a panel that reads the real contract +
  evidence, so the human steers by exception," which is exactly what reviewing a skipped checkpoint
  is. Building a second review surface here would duplicate it. D3 persists the history (§5); F
  renders it and adds send-back-to-milestone-N.
- **Checkpoint-level gate refusals.** A failed checkpoint pauses for the human, who already has
  "Send back" and "Approve & continue". D3 adds no retry loop; D1's retry ladder stays terminal-only.
- **Inline judgement at a checkpoint → a future slice.** §6 originally specified that a checkpoint
  holding an unjudged `humanJudged` criterion would ask for the verdict inline. The Accept/Reject
  UI that requires was never built, so the asking half is deferred; the blocking half ships. See
  §6 and §6.1.
- **Subagents and contract-less goals.** Unchanged.

## 3. The rule

At a checkpoint, auto-advance **only** when every one of these holds for the projected contract
(milestones 0…N):

1. The grader ran to completion and produced a `.graded` evaluation.
2. Every criterion's verdict is `met`, **or** the criterion carries a waiver, **or** the criterion
   is `humanJudged` and carries a recorded human acceptance (§6).
3. No `humanJudged` criterion in the projected set is still **unjudged**.
4. No verdict is `cannotVerify`.

Anything else pauses.

Note that §3.2–3.3 range over the **projected** contract (milestones 0…N), not the current
milestone alone, because that is what `reach_checkpoint` grades.

**Consequence of deferring inline judgement (§6).** Nothing can record a judgement mid-ladder, so
an unjudged `humanJudged` criterion in milestone 1 keeps failing §3.3 at checkpoints 2, 3, 4… —
auto-advance is effectively off for the remainder of that ladder. This is not a trapped goal: every
such checkpoint still pauses normally and "Approve & continue" still advances it. But a goal whose
early milestones carry taste criteria gets little of D3's benefit until the inline UI lands. It is
a known, accepted cost of shipping the blocking half first, not an oversight.

**On waivers.** A waived criterion counts as resolved: the user made that call explicitly and
should not be stopped for it twice. This is **inert today** — `waive_criterion` is gated on
`gateAttempts > 0`, `recordGateRefusal` is the only thing that increments it, and it is called only
from the terminal gate. Since `reach_checkpoint` is gated on `!isFinalMilestone`, every checkpoint
occurs strictly before the terminal gate has ever run, so `waivers` is always empty there. The rule
is written this way so it stays correct if checkpoint-level waivers are ever introduced; it is
specified, not exercised.

## 4. Fail-safe: uncertainty pauses

Today `performCheckpoint` calls `setCheckpointPaused` **before** the grader runs, so pausing is the
structural default and a grader that errors, times out, or never submits leaves the goal paused.
Grade-first removes that property, so it is restored explicitly:

> Any outcome that is not an affirmative clean pass under §3 results in a pause.

That includes a `.failed` evaluation, a grader crash or timeout, a missing evaluation, and an empty
criteria list. There is no path where an error advances the ladder. Tests assert this directly
rather than inferring it from the happy path.

## 5. State — the checkpoint history

New on `GoalContract`:

```swift
struct CheckpointOutcome: Codable, Equatable, Sendable {
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

var checkpointHistory: [CheckpointOutcome] = []

/// Human verdicts on `humanJudged` criteria, by criterion id. `true` = accepted.
/// Same shape and lifecycle as `waivers` — a durable record of a decision the user made.
var judgements: [UUID: Bool] = [:]
```

### 5.1 Why `judgements` must be durable (a latent D2 defect)

D2 records a human verdict by mutating `lastGoalEvaluation` in place. That is sufficient at the
terminal gate, which grades **once**. `resolveJudgementIfComplete` says so directly: the grader is
deliberately not re-run, because "a second run would … overwrite the user's judgement with a fresh
`human_pending`."

D3 grades at *every* checkpoint, cumulatively. Without a durable home, a judgement given at
checkpoint 1 is destroyed by checkpoint 2's fresh evaluation and the user is asked again — and
again at every subsequent checkpoint and once more at the terminal gate. `lastGoalEvaluation` is
also cleared by `sanitizeLoaded` on load, so a restart loses it regardless.

`judgements` therefore lives on `GoalContract`, beside `waivers`, which it mirrors exactly: a map
from criterion id to a decision the human made, persisted with the contract, consulted whenever a
verdict is reconciled. **Invariant 1 applies** — `decodeIfPresent(...) ?? [:]`.

**Judge once, at the milestone that owns the criterion.** Milestones partition the criteria
(`ladderIsValidPartition`), so a `humanJudged` criterion belongs to exactly one milestone and is
asked about at that milestone's checkpoint. Later checkpoints, and the terminal gate, read the
recorded decision instead of re-asking. This is a deliberate behaviour change to D2's terminal
gate: a criterion already judged at a checkpoint no longer prompts again at completion. For a
ladder-less goal nothing changes, because there are no checkpoints to judge at.

**Invariant 1 applies:** `checkpointHistory` is decoded with `decodeIfPresent(...) ?? []` in
`GoalContract.init(from:)`. A missing key must not throw, or every conversation is dropped.

**Why it lives on `GoalContract` and not beside `lastGoalEvaluation`.** `sanitizeLoaded` clears
`lastGoalCompletionReport` and `lastGoalEvaluation` on load, deliberately — that surfacing is a
per-session dismissable chip, and resurrecting it at startup was the trigger for a window-blanking
render bug. Durable history must not ride on a field designed to be cleared. `GoalContract` is
already persisted in full and already survives restart.

**All three resolutions are recorded**, not only auto-advances, so F inherits a complete ladder
record rather than a partial one. An entry is appended once per checkpoint resolution.

## 6. `humanJudged` at a checkpoint — it stops, it does not ask

D2 §2 left a `humanJudged` criterion inside a milestone "surfaced and non-blocking — D3 owns the
ladder." D3 closes the **blocking** half of that and defers the **asking** half:

- A milestone containing an **unjudged** `humanJudged` criterion **never** auto-advances (§3.3).
  The checkpoint pauses exactly as any contested grade does.
- The pause does **not** ask for the verdict. No `beginJudgementPause` at a checkpoint. The user
  sees the grader's verdict on the checkpoint chip and resolves the stop with the existing
  "Approve & continue" / "Send back" controls, the same two buttons every other contested
  checkpoint offers.
- Judgement itself stays where D2 put it: the terminal `goal_complete` gate. A `humanJudged`
  criterion is asked about once, at completion.
- A criterion with a recorded judgement still reconciles to the recorded verdict (§7.1).
  `judgements` remains durable (§5.1) — it is what the terminal gate and every intervening re-grade
  read. Note that with inline asking deferred, no judgement can be recorded before the terminal
  gate, so this path is currently exercised only by the terminal gate itself; it is the mechanism
  the future inline slice will rely on.

Without the blocking rule, "all met" could advance a milestone with nobody having judged the one
criterion only a human may judge — the provenance violation D2 closed at the terminal gate, one
level down. The block is what closes it; asking inline is an ergonomic improvement on top, not the
guarantee.

**Why the inline Accept/Reject is deferred to a future slice.** Asking at the checkpoint requires
an answer surface — Accept/Reject controls on `CheckpointPauseChip` over `DriftCriterionRow` — and
that view work was never built in this slice. Shipping the pause without it would stop the user
with a question that has no answer button, and a restart in that state is unrecoverable:
`sanitizeLoaded` nils `lastGoalEvaluation`, so `recordHumanJudgement` would always return false
while `isPaused` blocks the resume guard. Stopping without asking is strictly better than asking
without a way to answer, and it costs the user only the interruption's *shape* — they are stopped
either way. Checkpoint judgement (the UI, the restart-survival path, and the plumbing that routes a
mid-ladder verdict without touching the terminal gate) becomes its own slice.

`resolveJudgementIfComplete`'s checkpoint branch (the mid-ladder discriminator that keeps a
judgement from finishing the whole goal) stays in place, unreachable but deliberate: it is the
backstop for the day that slice lands, and for any code that sets `awaitingHumanJudgement`
mid-ladder. `advanceCheckpoint` and `holdCheckpoint` clear the flag for the same reason.

A grader still may not produce a `humanJudged` verdict — `GoalEvaluationParsing` forces
`.humanPending` structurally, and that is not relaxed.

### 6.1 A terminal rejection is consumed, not sticky

`judgements` being durable makes a terminal **rejection** permanent, which it must not be. Before
durable judgements a rejection lived only in `lastGoalEvaluation` and the next grade overwrote it,
so after the agent reworked the criterion the user was asked again. A persisted
`judgements[id] == false` instead reconciles to `.notMet` at every later grade, lands in
`GoalContract.blockingCriteria`, and refuses the gate on every remaining attempt — running a full
grader each time until `maxDoneGateRetries` is exhausted, on a verdict the agent can never earn
and only the user can lift.

So `resolveJudgementIfComplete`'s rejection branch removes the rejected criteria from
`judgements` before it resumes the agent: the rework it is triggering is what consumes the verdict,
and the user is asked again once the work has actually changed. Acceptances still persist — nothing
about an acceptance needs re-deciding.

## 7. Control flow

`performCheckpoint` inverts to grade-first:

1. `recordCompletionSelfReport`
2. `beginGoalEvaluation` (evaluation enters `.verifying`)
3. **grade** — `GoalEvaluator.evaluate` on the projected contract
4. decide:
   - **clean pass (§3)** → append `.autoAdvanced` outcome, `autoAdvanceCheckpoint`, emit the
     system event (§8), return a tool result telling the agent to continue with the next milestone
   - **otherwise** → `setCheckpointPaused`, push today's "Paused for your review" message, return
     today's tool result. **No `beginJudgementPause`** — a checkpoint stops without asking (§6).

**`autoAdvanceCheckpoint(for:)` is a new method beside `advanceCheckpoint`, not a reuse of it.**
`advanceCheckpoint` ends with `resumeGoalLoop`, which re-arms the auto-reprompt — correct for a
human clicking "Approve & continue" after the turn has ended, wrong here. Auto-advance happens
*inside* a live tool call, so re-arming would run a second loop alongside the turn already in
flight; that is the failure #172/#173 just fixed for mid-turn steering. The auto path therefore:

- bumps `currentMilestone` (clamped, as `advanceCheckpoint` does)
- leaves `checkpointStatus == .running`
- resets `goalIterationCount`
- appends the history entry
- **does not** call `resumeGoalLoop`

The engine's multi-round turn loop carries the agent forward on the returned tool result. Two
callers, two events — the same distinction `GoalResumeFraming` already draws between a checkpoint
resume and a judgement rejection.

### 7.1 Verdict reconciliation

`GoalEvaluationParsing.verdicts(from:criteria:)` gains the contract's recorded judgements:

```swift
static func verdicts(from args: [String: JSONValue],
                     criteria: [Criterion],
                     judgements: [UUID: Bool] = [:]) -> [CriterionVerdict]
```

For a `humanJudged` criterion it now resolves to the recorded decision when one exists
(`.met`/`.notMet`, `method: .human`), and to `.humanPending` only when none does. Everything else
is unchanged, and the structural guarantee D2 established is **not** relaxed: a grader's submitted
verdict on a `humanJudged` criterion is still never read, and a grader-submitted `human_pending` is
still downgraded. The only new source of truth is a decision the human actually made.

The default argument keeps every existing call site compiling and behaving identically, which
matters because the terminal gate uses the same function.

## 8. What the user sees

Each auto-advance emits a system event into the transcript naming the milestone and the evidence
it advanced on:

```
Checkpoint 2 of 4 (Parser) auto-advanced — grader found 3/3 criteria met:
  ✓ tests pass — swift test: 214 passed
  ✓ parser handles nested arrays — ParserTests.swift:88
  ✓ no regressions — full suite green
```

The ladder must stay inspectable, not merely faster. A silent advance would be the inverse of the
arc's honesty rule: instead of presenting unverified work as verified, it would present verified
work the human never saw as though they had seen it. The transcript is the audit trail until F
renders `checkpointHistory` properly.

## 9. Setting

`ConfigManager.checkpointAutoAdvance: Bool` (default `true`), idiomatic with `maxDoneGateRetries`.

When `false`, every checkpoint pauses — byte-identical to today's behaviour. Cutting low-value
stops only helps if it is the default, so it is; a user who wants the full ladder discipline on a
delicate goal has one switch. Per AGENTS.md invariant 7, tests must not mutate
`ConfigManager.shared`; the flag is injectable at the call site the way `protectionEnabled` and
`workspaceToolsEnabled` are.

## 10. Interaction constraints (fixed, not a blank slate)

- **Final milestone.** Never auto-advanced. `reach_checkpoint` is already gated on
  `!isFinalMilestone`; terminal completion stays the single D1/D2 path.
- **B4 delegated milestones.** `performCheckpoint` is reached via `delegate_milestone` too, with
  `grade: false` on the unit because the checkpoint grades cumulatively. That path must
  auto-advance on a clean grade and must not double-resume the loop.
- **Judgement pause.** Auto-advance while `awaitingHumanJudgement == true` must be impossible;
  §3.3 makes it unreachable, and a test asserts it rather than trusting the derivation.
- **Restart.** A goal paused for judgement at a checkpoint is not auto-resumed on restart, matching
  D2 §7. `isPaused` already covers both `pausedForReview` and `awaitingHumanJudgement`.
- **Contract-less goals and subagents.** Unchanged; neither has a ladder.

## 11. Testing

- A clean grade advances the milestone, appends an `.autoAdvanced` outcome, and leaves
  `checkpointStatus == .running`.
- A clean grade does **not** call `resumeGoalLoop` — no second loop while the turn is live.
- One `not_met` pauses; one `cannot_verify` pauses.
- A `.failed` evaluation pauses (fail-safe, §4).
- A milestone containing an unjudged `humanJudged` criterion pauses with
  `checkpointStatus == .pausedForReview` **and** `awaitingHumanJudgement == false`, even when every
  other criterion is `met` — it stops, it does not ask (§6).
- `advanceCheckpoint` and `holdCheckpoint` each clear `awaitingHumanJudgement`, so the human
  controls can never leave the terminal/checkpoint discriminator half-flipped (§6).
- **A judgement survives the next grade.** Accept a `humanJudged` criterion; a later evaluation
  reconciles it to `.met` with `method == .human` rather than `.humanPending`, and the checkpoint
  auto-advances. This is the regression the durable `judgements` map exists to prevent (§5.1) —
  assert it directly, not via the happy path.
- A recorded rejection reconciles to `.notMet` and blocks auto-advance while it stands.
- **A terminal rejection is consumed** (§6.1): the rejected criterion is removed from `judgements`
  on the reject-resume path, so a later re-grade returns it to `.humanPending` rather than
  re-refusing the gate and burning the retry cap.
- A grader's submitted verdict on a `humanJudged` criterion is still ignored, and a
  grader-submitted `human_pending` is still downgraded (D2's guarantees, unrelaxed).
- Round-trip: a `GoalContract` encoded without `judgements` decodes with `[:]` and does not throw
  (invariant 1).
- `checkpointAutoAdvance == false` pauses on a grade that would otherwise advance.
- A delegated (B4) milestone auto-advances on a clean grade without double-resuming.
- The final milestone is never auto-advanced.
- `humanApproved` and `humanSentBack` both append history entries.
- Round-trip: a `GoalContract` encoded without `checkpointHistory` decodes with `[]` and does not
  throw (invariant 1).

## 11.1 As-built notes

Three things worth recording, all found by review rather than by design:

- **A latent D2 defect (§5.1).** D2 stored human verdicts only in `lastGoalEvaluation`, which the
  next grade overwrites and `sanitizeLoaded` clears on load. Invisible while grading happened once;
  fatal once checkpoints grade repeatedly. `GoalContract.judgements` fixes it.
- **Judgement resolution had to be scoped to the pause that raised it.** `resolveJudgementIfComplete`
  assumed every pause was terminal, so on the last judgement it finished and cleared the goal.
  Opening a checkpoint pause without that fix would have erased a running goal because the user
  answered a question about one milestone. The checkpoint branch remains as a backstop even though
  inline asking is deferred and it is currently unreachable.
- **Durable rejections had to be consumable.** Persisting `judgements` made a terminal REJECTION
  sticky: it reconciled to `.notMet` at every later grade, landed in `blockingCriteria`, and burned
  the gate's whole retry budget on a verdict the agent could never clear. A rejection is now removed
  from `judgements` when the rework it triggers resumes; acceptances persist. One consequence: a
  reject/rework/regrade cycle is bounded by the user's clicks rather than by `gateAttempts`, since
  the judgement pause deliberately does not spend a retry.

## 12. The larger arc

With D3, the ladder spends human attention by exception. Remaining:

- **E — the ratchet:** per-goal learnings → memory → promoted rules → hooks.
- **F — ground-truth progress view:** a panel reading contract + evidence, rendering
  `checkpointHistory` and adding retroactive send-back to milestone N.
