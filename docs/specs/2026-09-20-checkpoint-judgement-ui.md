# Checkpoint Judgement UI (D3 follow-on) — Design

**Status:** approved, not yet implemented
**Issue:** #191
**Builds on:** D3 (`2026-09-20-checkpoint-auto-advance.md`), D2 (`2026-09-18-human-judged-verdicts.md`)

## 1. Overview

A checkpoint that stops because of a `humanJudged` criterion now **asks** for the verdict, instead
of stopping and leaving the question for the terminal gate. D3 specified this in its §6 and then
cut it: the Accept/Reject controls were never built, and landing unreviewed UI that can complete or
wipe a goal inside a post-review fix wave was the wrong trade. This is that work, done properly.

D3 shipped the blocking half — a milestone holding an unjudged `humanJudged` criterion never
auto-advances. What is missing is the asking half, and its absence has a cost D3 documented in its
§3: nothing can record a judgement mid-ladder, so one unjudged criterion in milestone 1 keeps
failing the auto-advance rule at **every later checkpoint**. For any ladder containing a taste
criterion, auto-advance is effectively off for the rest of the run. This restores it.

**The control already exists.** `DriftCriterionRow` renders Accept/Reject whenever it is handed
`onAccept`/`onReject` and the verdict is `.humanPending`; `CompletionReportSection` already wires
them at the terminal gate. `CheckpointPauseChip` constructs the same row **without** them. Most of
this slice is state machine and lifetime, not new UI.

## 2. Scope

Touches the checkpoint pause only. The terminal `goal_complete` gate (D1/D2) keeps its behaviour,
with one incidental fix (§3) that also repairs it.

Out of scope: retroactive review of a *skipped* checkpoint (slice F, reading
`Conversation.checkpointHistory`); any change to what auto-advance decides (D3 §3 stands);
`checkpointHistory`'s storage shape (#205).

## 3. Surviving a restart

`AppState.sanitizeLoaded` clears `lastGoalEvaluation` and `lastGoalCompletionReport` on load.
`checkpointStatus` is persisted, so **today** a restart mid-checkpoint-pause already brings the chip
back empty — no self-report, no grader verdict, just the buttons. Cosmetic now; fatal here, because
`recordHumanJudgement` requires `lastGoalEvaluation` and would refuse every click, leaving a pause
nothing can answer.

**`sanitizeLoaded` keeps both fields when the contract `isPaused`** (`checkpointStatus ==
.pausedForReview || awaitingHumanJudgement`), and clears them otherwise exactly as now.

This also repairs the same hole one level up: a **terminal** judgement pause is equally
unanswerable across a restart today, which is a latent D2 defect of the same shape as the one D3
found in `lastGoalEvaluation`.

### 3.1 This removes a workaround — state it plainly

That clearing exists because resurrecting the chip at startup triggered a window-blanking render
bug. Two things make removing it safe, and if blanking returns **this is the change to suspect**:

- The root cause was fixed separately in `aa141d5` by bounding `CompletionReportChip`'s height.
  That is now AGENTS.md invariant 8, and `CheckpointPauseChip` was capped at 340 by #166.
- `ChatView` suppresses `CompletionReportChip` entirely while `checkpointStatus == .pausedForReview`,
  so a restored checkpoint pause resurrects only the checkpoint chip — the one we want.

The terminal-pause case (`awaitingHumanJudgement` with `checkpointStatus == .running`) *does*
restore the completion chip, which is the configuration the render bug was about. It is height-bounded
now, and an unanswerable terminal pause is a trapped goal, so the trade is worth making knowingly.

## 4. Pause scope stays derived

`resolveJudgementIfComplete` keeps distinguishing a checkpoint pause from a terminal one by
`checkpointStatus == .pausedForReview`. D3 added defensive clears of `awaitingHumanJudgement` to
`advanceCheckpoint` and `holdCheckpoint` so the user's own buttons cannot leave the discriminator
half-open; those clears become load-bearing here and **each gets a test**.

No new persisted field. This derivation produced two of D3's Criticals, so it is deliberately the
thing tests pin hardest rather than the thing a new field papers over.

## 5. The approve gate

**"Approve & continue" is disabled while the evaluation carries a `humanJudged` criterion that is
unjudged or rejected** — that is, a row whose verdict is `.humanPending`, or one whose
`judgements[id] == false`. "Send back" stays available throughout, and a caption says why the
button is disabled.

Read this off the evaluation rather than the contract's criteria, for the same reason §7 does: the
evaluation is exactly the graded set, so the gate can never fire on a criterion belonging to a
milestone nobody has worked yet. By §6 an earlier milestone can only contribute an accepted
criterion, so in practice the gate only ever concerns the current one.

Two distinct reasons, both necessary:

- **Unjudged.** The checkpoint stopped *because* of this criterion. Letting the user advance past it
  leaves it undecided, which keeps failing the auto-advance rule at every later checkpoint — the
  user is then re-interrupted at each one for a question they have already declined. Requiring the
  verdict once is what actually restores auto-advance for the rest of the ladder.
- **Rejected.** Once rejected the criterion *is* judged, so an unjudged-only gate would re-enable
  Approve and let the user advance a milestone they just said is not met. Worse, rejections are
  consumed by `holdCheckpoint` (send-back) and **not** by `advanceCheckpoint`, so the `.notMet`
  verdict would persist, block the terminal gate, and leave the user waiving away their own
  judgement to finish. Reject means not done; Send back is the correct action and already consumes
  the rejection.

## 6. What this buys: the rule becomes self-consistent

With §5 you can never advance past a `humanJudged` criterion that is unjudged *or* rejected — and
send-back consumes a rejection, returning the criterion to unjudged. So the only way past a
checkpoint is an **accepted** verdict on every `humanJudged` criterion in it.

By the time a later checkpoint grades, every earlier milestone's `humanJudged` criteria are
therefore accepted, and the projected evaluation can only ever carry current-milestone criteria as
`.humanPending`.

D3 §3 justified this with a partition argument that was true of the criteria but not of the
*timing* — nothing then forced the judgement to happen at its own checkpoint. Now something does.

## 7. Control flow

At a checkpoint that does not auto-advance, `performCheckpoint`:

1. `setCheckpointPaused` (unchanged), then
2. `beginJudgementPause` **when the evaluation carries a `.humanPending` verdict.**

Read the condition off the **evaluation**, never the contract. The evaluation contains exactly the
projected criteria, and `GoalEvaluationParsing` assigns `.humanPending` precisely when a criterion is
`humanJudged` and unjudged. D3 originally scanned the whole contract, which opened a judgement pause
for a criterion belonging to a *future* milestone — one with no row in the evaluation, no button to
click, and no way to clear the flag. That was a trapped goal, caught in review; the evaluation-based
condition is the fix and must not regress.

Resolution reuses D2 unchanged, via the checkpoint branch of `resolveJudgementIfComplete` that D3
added as a backstop and left unreachable. It clears `awaitingHumanJudgement`, leaves the checkpoint
`.pausedForReview`, and returns **without** finishing or clearing the goal. That branch becomes
reachable for the first time here; it was written for exactly this.

## 8. UI

`CheckpointPauseChip` passes `onAccept`/`onReject` into `DriftCriterionRow`, reusing
`GoalContractPanel`'s existing `judgementHandlers(for:)` helper, which already gates on
`awaitingHumanJudgement`. The rows render as they do at the terminal gate, so a human verdict is
still labelled as the user's and never as grader-verified evidence (D2 §6).

The chip's Approve button takes the §5 disabled state and its caption. No new views.

## 9. Interaction constraints

- A rejected criterion is consumed by send-back (`holdCheckpoint`), so re-work re-asks. Unchanged
  from D3; it is what makes §5's rejected-gate coherent.
- Auto-advance must remain impossible while `awaitingHumanJudgement` — `canAutoAdvance` already
  guards on it (D3), and that guard is now reachable in earnest.
- A laddered goal still completes through the terminal gate after all its checkpoints resolve.
- Judgements recorded at a checkpoint are not re-asked at completion (D3 §5.1, `judgements` is
  durable and reconciliation reads it).

## 10. Testing

- **Restart round-trip through `ConversationStore`**, not the JSON codec. D3 shipped a field that
  round-tripped in JSON and was never persisted, because post-#197 the store enumerates columns by
  hand. A pause must be answerable after a real store load.
- Accept at a checkpoint resolves the criterion and leaves the goal running and `.pausedForReview`.
- Reject likewise, and does **not** finish the goal.
- Approve is disabled for an unjudged criterion, and for a rejected one; Send back is enabled in
  both.
- Both defensive clears (`advanceCheckpoint`, `holdCheckpoint`) pinned individually (§4).
- A judgement pause opens only for a criterion in the graded set — a `humanJudged` criterion in a
  *future* milestone must not open one (§7's regression).
- `sanitizeLoaded` keeps the surfacing fields when paused and still clears them when not.
- A laddered goal completes through the terminal gate afterwards.

## 11. The larger arc

With this, every criterion kind is decidable at the checkpoint that raises it, and D3's
auto-advance works for ladders containing taste criteria. Remaining: **E — the ratchet**, and
**F — ground-truth progress view**, which renders `checkpointHistory` and adds retroactive
send-back.
