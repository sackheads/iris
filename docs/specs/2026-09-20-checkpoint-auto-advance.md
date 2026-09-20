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
  is. Building a second review surface here would duplicate it. D3 persists the history — in its
  own `checkpointHistory` column on the store's `conversations` table (§5) — and F renders it and
  adds send-back-to-milestone-N.
- **Checkpoint-level gate refusals.** A failed checkpoint pauses for the human, who already has
  "Send back" and "Approve & continue". D3 adds no retry loop; D1's retry ladder stays terminal-only.
- **Inline judgement at a checkpoint → shipped in `2026-09-20-checkpoint-judgement-ui.md` (#191).**
  §6 originally specified that a checkpoint holding an unjudged `humanJudged` criterion would ask
  for the verdict inline. The Accept/Reject UI that requires was never built here, so the asking
  half was deferred and shipped as its own slice; the blocking half ships in D3. See §6 and §6.1.
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

**The mid-ladder cost of deferring inline judgement (§6) was removed by #191.** While inline
judgement was deferred, nothing could record a judgement mid-ladder, so an unjudged `humanJudged`
criterion in milestone 1 kept failing §3.3 at checkpoints 2, 3, 4… — auto-advance was effectively
off for the remainder of that ladder. `2026-09-20-checkpoint-judgement-ui.md` (#191) closed this: a
checkpoint that stops on an unjudged `humanJudged` criterion now asks for the verdict right there,
and an accepted verdict satisfies §3.3 for that criterion going forward, restoring auto-advance for
the remaining checkpoints in the ladder.

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

**Only the in-process half is restored.** `.pausedForReview` is now written *after* the grade, so
there is a window — a grader run is minutes long — in which the disk still says `.running`. Quit
inside it and the resume guard, seeing a running goal, re-kicks the loop on restart; the grade in
flight is discarded and the checkpoint is worked again rather than paused. The fail-safe holds for
every outcome the process lives to see, and for nothing else. Restoring the durable half means
writing a pre-grade marker distinct from `.pausedForReview` (so the UI does not show a review chip
for a checkpoint nobody has graded yet), which D3 does not do.

## 5. State — the checkpoint history

New on `Conversation` (the history) and `GoalContract` (the judgements):

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
    var evaluation: GoalEvaluation?   // nil when nothing was graded — never a synthesized failure
    var resolution: Resolution
    var date: Date = Date()
}

// on Conversation
var checkpointHistory: [CheckpointOutcome] = []

// on GoalContract
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

**Where it is actually persisted.** Since #197, conversations are stored in SQLite with explicit
columns (`ConversationStore`), not as a JSON blob, so a field nobody adds a column for is silently
dropped on every relaunch no matter how leniently it decodes. `checkpointHistory` therefore has its
own nullable `checkpointHistory` text column on `conversations`, added by the `v3_checkpoint_history`
migration and JSON-encoded in and out exactly like `goalContract`. An empty history is stored as
SQL NULL, and NULL — which is what every row written before v3 carries — loads as `[]`.
`ConversationStoreTests.roundTrip` is the contract test that holds this: it asserts every stored
field, `checkpointHistory` included.

**Invariant 1 applies** to the JSON codec as well, which is still reached through the legacy blob
import and through `CheckpointOutcome`'s own rows: `checkpointHistory` is decoded with
`decodeIfPresent(...) ?? []` in `Conversation.init(from:)`, and `CheckpointOutcome` has a lenient
`init(from:)` of its own so that a field added by slice F cannot make every already-stored row
undecodable and take the conversation with it. A missing key must not throw, or every conversation
is dropped.

**Why it lives on `Conversation` and not on `GoalContract`.** It has to outlive the goal it
describes. `clearGoal` nils `goalContract` on `goal_complete`, on `/stop`, and on an LLM error, so
a history kept there could only ever be read while the goal was still running — and slice F's
reason for existing is reviewing a ladder after the fact. It is the same shape as the D2 defect
§5.1 records: durable evidence parked on a field something else is designed to clear.
`lastGoalEvaluation` is not an option either, for its own reason: `sanitizeLoaded` clears it on an
ordinary load, deliberately, because that surfacing is a per-session dismissable chip whose
resurrection at startup once caused a window-blanking render bug. #191 carves out the one case
where dismissing it early would be wrong — a pause still open on the user — and keeps it there so
the pause survives a restart; it does not change the per-session lifetime this paragraph is about.

`judgements` stays on `GoalContract`, and correctly so: it is keyed by criterion id and means
nothing once the contract that defines those criteria is gone.

**An outcome's `evaluation` is optional.** `sanitizeLoaded` nilled `lastGoalEvaluation`
unconditionally on load when this was written, so after a restart the chip's Approve/Send-back
genuinely had no grade to record; #191 persists it while a pause is open on the user, so a
checkpoint outcome recorded through a restored pause carries a real evaluation too (see
`recordCheckpointOutcome`'s doc comment). The field stays optional for the case an evaluation truly
is absent — synthesizing a `.failed` stand-in would write a grader verdict nobody produced into the
audit trail, where it would be indistinguishable from a real grader failure. Nil means "not graded".

**All three resolutions are recorded**, not only auto-advances, so F inherits a complete ladder
record rather than a partial one. An entry is appended once per checkpoint resolution.

## 6. `humanJudged` at a checkpoint — it stops and asks (as of #191)

D2 §2 left a `humanJudged` criterion inside a milestone "surfaced and non-blocking — D3 owns the
ladder." D3 closed the **blocking** half of that and deferred the **asking** half; #191 shipped the
asking half:

- A milestone containing an **unjudged** `humanJudged` criterion **never** auto-advances (§3.3).
  The checkpoint pauses exactly as any contested grade does.
- The pause asks for the verdict inline. `performCheckpoint` calls `beginJudgementPause` when the
  graded evaluation carries a `.humanPending` row, and the checkpoint chip renders Accept/Reject for
  that row, the same controls the terminal gate already used. The user still resolves the stop with
  "Approve & continue" / "Send back" once every human-judged criterion in the milestone is decided.
- Judgement no longer waits for the terminal `goal_complete` gate. A `humanJudged` criterion is
  asked about at the checkpoint that raises it, and a verdict already given is never asked for
  again — the terminal gate still asks about any criterion nothing earlier stopped on.
- A criterion with a recorded judgement still reconciles to the recorded verdict (§7.1).
  `judgements` remains durable (§5.1) — it is what the terminal gate and every intervening re-grade
  read, including a judgement recorded at an earlier checkpoint.

Without the blocking rule, "all met" could advance a milestone with nobody having judged the one
criterion only a human may judge — the provenance violation D2 closed at the terminal gate, one
level down. The block is what closes it; asking inline is what makes the block resolvable without
waiting for the end of the run.

**Why the inline Accept/Reject was deferred, and what made it safe to ship.** D3 deferred inline
asking because a restart while the question was open was unrecoverable: `sanitizeLoaded` nilled
`lastGoalEvaluation` unconditionally, so `recordHumanJudgement` would always return false while
`isPaused` blocked the resume guard. `2026-09-20-checkpoint-judgement-ui.md` (#191) shipped the
Accept/Reject controls together with the restart-persistence fix that removed that failure —
`sanitizeLoaded` now keeps the surfacing fields while a pause is open on the user — which is what
made asking at the checkpoint safe.

`resolveJudgementIfComplete`'s checkpoint branch (the mid-ladder discriminator that keeps a
judgement from finishing the whole goal) is now the resolution path for a checkpoint judgement
pause, reachable since #191. `advanceCheckpoint` and `holdCheckpoint` clear
`awaitingHumanJudgement` defensively so the user's own buttons cannot leave the discriminator
half-open.

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

The same rule applies one level down. `resolveJudgementIfComplete` returns early at a checkpoint
pause (§6) and never reaches that branch, so `holdCheckpoint` consumes the current milestone's
rejected judgements itself: "Send back" is the rework trigger at a checkpoint exactly as resume is
at the terminal gate. Without it a mid-ladder rejection would be permanently sticky — the failure
this section describes, reintroduced at the checkpoint the moment inline judgement ships.

## 7. Control flow

`performCheckpoint` inverts to grade-first:

1. `recordCompletionSelfReport`
2. `beginGoalEvaluation` (evaluation enters `.verifying`)
3. **grade** — `GoalEvaluator.evaluate` on the projected contract
4. decide:
   - **clean pass (§3)** → append `.autoAdvanced` outcome, `autoAdvanceCheckpoint`, emit the
     system event (§8), return a tool result telling the agent to continue with the next milestone.
     The advance is passed the milestone index it was decided for and no-ops on a mismatch: a
     turn's tool calls run concurrently (AGENTS.md invariant 3), so two `reach_checkpoint` calls in
     one batch would otherwise both advance from the same index and skip a milestone outright.
   - **otherwise** → `setCheckpointPaused`, push today's "Paused for your review" message, return
     today's tool result. `beginJudgementPause` fires alongside it when the graded evaluation
     carries a `.humanPending` row — a checkpoint stops and asks (§6, as of #191).

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

What carries the agent forward is the ordinary auto-reprompt, **not** the multi-round turn loop:
the engine sets `turnFinished = true` whenever a batch contains `reach_checkpoint`, so the turn
ends on the tool result rather than continuing through it. The reprompt then fires because the
auto path left `checkpointStatus == .running`. Two callers, two events — the same distinction
`GoalResumeFraming` already draws between a checkpoint resume and a judgement rejection.

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

It is not exposed in Settings yet (#192); the flag is reachable only by editing defaults.

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
- **Judgement pause.** Auto-advance while `awaitingHumanJudgement == true` must be impossible, and
  so must auto-advance past an open `.pausedForReview` chip — a user who types instead of clicking
  gets an ordinary turn, and that turn must not consume the decision they were in the middle of
  making. `canAutoAdvance` refuses both flags in its first guard rather than deriving the property
  from §3.3, and a test asserts each.
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
  `checkpointStatus == .pausedForReview` **and**, as of #191, `awaitingHumanJudgement == true`, even
  when every other criterion is `met` — it stops and asks (§6, `testHumanJudgedAsksAtCheckpoint`).
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
- Round-trip: a `Conversation` encoded without `checkpointHistory` decodes with `[]` and does not
  throw (invariant 1), and an outcome with no grade round-trips as nil.
- The history survives `clearGoal`: a completed goal's checkpoint record is still readable.
- **Store round-trip:** a conversation written through `ConversationStore` and loaded back keeps
  its `checkpointHistory` (`ConversationStoreTests.roundTrip`, which asserts every stored field);
  an empty history round-trips as `[]`; and a v2-era database — written before the column existed —
  migrates and loads its rows with `[]` rather than failing.
- Two advances decided for the same milestone advance once, record one entry, and push one
  transcript announcement: the refused call returns a neutral result instead of repeating the
  winner's notice from its own pre-grade snapshot.
- `ConfigManager.checkpointAutoAdvance` defaults to `true` when the key is unset, asserted against
  an injected store (`ConfigManager(store:)`) so it cannot race the process-global defaults.
- A checkpoint already `.pausedForReview`, and a goal `awaitingHumanJudgement`, each refuse to
  auto-advance.
- A laddered goal at its final milestone still completes through the terminal gate — the
  ladder-less case cannot reach the checkpoint early return at all.
- A grader that answers in prose and never calls `submit_evaluation` pauses the checkpoint (§4),
  asserted end to end rather than only at the predicate.
- A checkpoint send-back consumes the milestone's rejected judgements (§6.1 at the ladder level);
  an acceptance survives it.

## 11.1 As-built notes

Three things worth recording, all found by review rather than by design:

- **A latent D2 defect (§5.1).** D2 stored human verdicts only in `lastGoalEvaluation`, which the
  next grade overwrites and `sanitizeLoaded` clears on load. Invisible while grading happened once;
  fatal once checkpoints grade repeatedly. `GoalContract.judgements` fixes it.
- **Judgement resolution had to be scoped to the pause that raised it.** `resolveJudgementIfComplete`
  assumed every pause was terminal, so on the last judgement it finished and cleared the goal.
  Opening a checkpoint pause without that fix would have erased a running goal because the user
  answered a question about one milestone. The checkpoint branch was kept as a backstop for the day
  inline asking shipped; it is reachable since #191, which is that day.
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
