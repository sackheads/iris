# Checkpoint Judgement UI (D3 follow-on) — Design

**Status:** implemented (#191, PR #224)
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
with one incidental fix (§3–§4) that also repairs it.

Out of scope: retroactive review of a *skipped* checkpoint (slice F, reading
`Conversation.checkpointHistory`); any change to what auto-advance decides (D3 §3 stands);
`checkpointHistory`'s storage shape (#205).

## 3. Surviving a restart

`recordHumanJudgement` refuses unless `lastGoalEvaluation` is present (`AppState.swift:1124-1131`):
that evaluation is the only thing Accept and Reject act on, and it is also what makes the chip
render a row to click. A checkpoint pause that comes back from disk without it is a pause nothing
can answer — buttons that do nothing, and a resume guard that keeps the loop quiet because the
contract is paused. Today that costs only appearances, since the restored chip is merely empty.
Here it is the whole slice.

Two separate things destroy those fields on the way back, and both have to be fixed.

**Nothing wrote them to disk at all.** Before this slice, `lastGoalEvaluation` and
`lastGoalCompletionReport` had no column on `conversations`: `upsertMetadata` did not write them,
`loadAll` did not read them, and the store's own round-trip test asserted they came back nil. §4
gives them columns; `upsertMetadata` writes both today (`ConversationStore.swift:522-553`), `loadAll`
reads both (`:688-689`) and decodes them (`:745-752`), and the round-trip test now asserts a real
value for both (`ConversationStoreTests.swift:85-86`). They used to survive only through
`Conversation`'s synthesized `Codable` conformance over its stored properties
(`AppState.swift:74-75`), which since #197 is the legacy-import path and nothing else.

**And `sanitizeLoaded` clears whatever does arrive** (`AppState.swift:1638-1664`), running over the
store's output inside `loadConversations` (`:1835`). Left alone it would throw away the columns §4
adds, so the two fixes are both necessary and neither is sufficient.

**`sanitizeLoaded` keeps both fields when the run is stopped on the user** — `checkpointStatus ==
.pausedForReview` or `awaitingHumanJudgement` — and clears them otherwise exactly as now. The two
flags are spelled out rather than routed through `GoalContract.isPaused`, whose doc comment
restricts it to loop-control sites because every UI reader is really asking a ladder question
(`GoalContract.swift:213-216`). This is a surfacing question, and `lockedChipHeader` already sets
the precedent of reading the two flags directly for one (`:218-235`).

This also repairs the same hole one level up: a **terminal** judgement pause was equally
unanswerable across a restart before this fix, a latent D2 defect of the same shape as the one D3
found in `lastGoalEvaluation`. The same `sanitizeLoaded` change closes both.

### 3.1 This removes a workaround — state it plainly

That clearing exists because resurrecting the chip at startup triggered a window-blanking render
bug. Two things make removing it safe, and if blanking returns **this is the change to suspect**:

- The root cause was fixed separately in `aa141d5` by bounding `CompletionReportChip`'s height.
  That is now AGENTS.md invariant 8, and `CheckpointPauseChip` was capped at 340 by #166
  (`GoalContractPanel.swift:507-511`, `:594`).
- `ChatView` suppresses `CompletionReportChip` entirely while `checkpointStatus == .pausedForReview`
  (`ChatView.swift:314-318`), so a restored checkpoint pause resurrects only the checkpoint chip —
  the one we want.

The terminal-pause case (`awaitingHumanJudgement` with `checkpointStatus == .running`) *does*
restore the completion chip, which is the configuration the render bug was about. It is height-bounded
now, and an unanswerable terminal pause is a trapped goal, so the trade is worth making knowingly.

## 4. Persisting the surfacing fields

Two new nullable TEXT columns on `conversations`, `lastGoalEvaluation` and
`lastGoalCompletionReport`, JSON-encoded in and out exactly as `goalContract` and
`checkpointHistory` are, added by a `v6_pause_surfacing` migration registered after
`v5_quarantine_ordinal_nullable` (main gained `v4_fts_rowid` and `v5_quarantine_ordinal_nullable`
in #214 between this spec and its implementation) (`ConversationStore.swift:325-330`). `upsertMetadata` writes both on the
UPDATE and the INSERT (`:522-553`); `loadAll` reads both (`:688-689`) and decodes them beside
`checkpointHistory` (`:745-752`). A nil value is stored as SQL NULL rather than a JSON `null`,
following the `checkpointHistory` precedent at `:527-529`, because the overwhelming majority of rows will never have carried either field. NULL —
which is what every row written before v6 carries — loads as nil, which is precisely the value
those fields have on load today, so the migration changes nothing for an existing store.

**A corrupt value degrades to nil; it does not drop the conversation.** `loadAll` already has both
policies. `goalContract` and `tokenUsage` decode inside the block whose `catch` skips the whole
conversation (`:704-730`); `checkpointHistory` decodes after it, records a `SkippedRow`, and leaves
the conversation intact (`:737-740`). These two fields follow `checkpointHistory` (`:745-752`). They
are surfacing state, not the contract: an undecodable `goalContract` means nobody knows what the goal
was measured against and there is nothing honest to show, whereas an undecodable
`lastGoalEvaluation` means one chip is empty. Losing a conversation's messages, contract and
workspace because a transient grader snapshot would not parse is the larger harm by a wide margin.
The cost is worth saying out loud: in that case the pause is unanswerable exactly as it is today,
and the user's route out is `/stop`. The `SkippedRow` is what makes it visible — it reaches the
launch notice rather than failing silently.

**This policy is narrower than "corrupt" suggests: it covers undecodable JSON, not an unreadable
column.** `loadAll` reads every metadata text column, these two included, through the same `text(_:)`
helper as `goalContract` and `checkpointHistory` (`:671-679`); a non-UTF8 blob in either column is
`.invalid` there, marks the column unreadable, and skips the whole conversation before any
JSON-specific handling runs (`:698-701`) — the same fate as a non-UTF8 `goalContract` or
`checkpointHistory`, not the softer nil-and-continue path. Only a column that reads as valid text but
fails to parse as JSON degrades to nil for these two fields; that is the only case this paragraph's
"corrupt value degrades to nil" is actually about.

**Every write must mark the conversation changed.** Nothing reaches the store that
`markChanged(id, .metadata)` did not schedule, so a field assigned without it persists only by
luck, whenever some later mutation happens to flush the same row. Every site that assigns either
field does so today: `recordCompletionSelfReport` (`AppState.swift:1023-1027`), `beginGoalEvaluation`
(`:1051-1064`), `recordEvaluation` (`:1067-1071`), `finishGatedGoal` (`:1106-1113`),
`recordHumanJudgement` (`:1124-1148`), and the clears in `dismissCompletionReport` (`:1039-1045`) and
`setDraftContract` (`:1252-1263`). `clearGoal` (`:999-1014`) joins this list, but only when the
contract being cleared had a pause open on the user (`checkpointStatus == .pausedForReview ||
awaitingHumanJudgement`, §9.1): an ordinary completion — the terminal gate's `finishGatedGoal` →
`clearGoal` with no pause open — keeps both fields so the completion-report chip still has
something to show. When the nils do apply they sit **before** `clearGoal`'s existing `markChanged`
call so the same row write carries them; a nil assigned after that call persists only by luck, which
is the exact failure this paragraph exists to rule out. `sanitizeLoaded` is the exception and needs
nothing: it runs
before `AppState` owns the rows. `beginJudgementPause` (`:1241-1248`), `setCheckpointPaused`
(`:1305-1311`), `advanceCheckpoint` (`:1368-1386`) and `holdCheckpoint` (`:1389-1417`) mark changed
too, which is what makes the pause flags and the surfacing fields land in the same row write.

That property is to be preserved, not added. It is unobservable while the fields are not persisted
and load-bearing the moment they are, which is exactly the kind of invariant that rots, so §11
asserts a store write rather than only an in-memory value.

Note what this does **not** change: nothing here makes a judgement durable. `GoalContract.judgements`
already does that (D3 §5.1), and it is still the thing every re-grade reads. These columns keep the
*chip* answerable across a restart; the verdict itself was never the thing at risk.

**D2's terminal judgement pause is repaired by the same change and needs no separate work**, because
it is unanswerable for the same reason and reads the same two fields.

## 5. Pause scope stays derived

`resolveJudgementIfComplete` keeps distinguishing a checkpoint pause from a terminal one by
`checkpointStatus == .pausedForReview` (`AppState.swift:1155-1177`). D3 added defensive clears of
`awaitingHumanJudgement` to `advanceCheckpoint` (`:1381`) and `holdCheckpoint` (`:1412`) so the
user's own buttons cannot leave the discriminator half-open; those clears become load-bearing here
and **each gets a test**.

§4 adds two persisted fields, so this spec no longer claims to add none. What it still refuses to
add is a persisted *pause scope*: which kind of pause is open stays derived from the two flags the
pause already sets. That derivation produced two of D3's Criticals, so it is deliberately the thing
tests pin hardest rather than the thing a third flag papers over. The new columns are the opposite
kind of change — they store a value that already exists in memory, and nothing computes anything
from them.

## 6. The approve gate

**"Approve & continue" is disabled while a `humanJudged` criterion of the current milestone is
unjudged or rejected** — a row of the evaluation whose criterion is in
`contract.currentMilestoneCriteria()` and whose verdict is `.humanPending`, or whose
`judgements[id] == false`. "Send back" stays available throughout, and a caption says why the
button is disabled.

Read the verdicts off the evaluation rather than the contract's criteria, for the same reason §8
does: the evaluation is exactly the graded set, so the gate can never fire on a criterion belonging
to a milestone nobody has worked yet. Intersecting that with the current milestone buys the other
half, and it is the half that matters: **the set the gate reads is the set send-back clears.**
`holdCheckpoint` consumes rejections only for `currentMilestoneCriteria()`, and only when
`hasLadder` (`AppState.swift:1404-1408`). A gate scoped any wider is a trap — a rejection carried by
an earlier milestone would disable Approve at a later one, Send back would not clear it, and the
goal would sit behind two buttons with no way past either.

§7's induction says that cannot arise: by the time a later checkpoint grades, every earlier
milestone's `humanJudged` criteria are accepted, so the projected set and the current-milestone set
carry the same pending-or-rejected rows. That is true today and it is not enough to rely on. It is
a property of the whole ladder holding a single `if` upright, and §7 itself has a caveat (waivers)
whose inertness is an accident of where `gateAttempts` is incremented. Scoping the gate directly
makes the two sets equal by construction instead of by induction, and §11 pins it with a rejection
in an earlier milestone that must not disable Approve at a later one.

Two distinct reasons to gate, both necessary:

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

## 7. What this buys: the rule becomes self-consistent

With §6 you can never advance past a `humanJudged` criterion that is unjudged *or* rejected — and
send-back consumes a rejection, returning the criterion to unjudged. So the only way past a
checkpoint is an **accepted** verdict on every `humanJudged` criterion in it.

**Except a waived one, and that caveat has to be carried forward rather than quietly dropped.**
`canAutoAdvance` tests the waiver before the `humanJudged` branch
(`GoalContract.swift:436-450`, the waiver at `:444` and the judgement at `:447`), so a waived
`humanJudged` criterion auto-advances with nobody having judged it. D3 §3 carried the argument that
this is inert: `waiveCriterion` refuses unless `gateAttempts > 0` (`AppState.swift:1089-1101`), only
`recordGateRefusal` increments that (`:1076-1082`), and its sole caller is the terminal gate
(`iris.swift:1462`) — which every checkpoint, gated on `!isFinalMilestone`, strictly precedes.
So `waivers` is empty at every checkpoint today.

The guarantee therefore reads: **every `humanJudged` criterion in the checkpoint is either accepted
or — not reachable today — waived.** If checkpoint-level waivers ever land, the branch ordering is
the single thing that decides whether this section is still true, so §11 pins the ordering rather
than the consequence. A test that only asserts "an unjudged criterion blocks" passes just as
happily on the day the guarantee breaks.

By the time a later checkpoint grades, every earlier milestone's `humanJudged` criteria are
therefore accepted, and the projected evaluation can only ever carry current-milestone criteria as
`.humanPending`.

D3 §3 justified this with a partition argument that was true of the criteria but not of the
*timing* — nothing then forced the judgement to happen at its own checkpoint. Now something does.

## 8. Control flow

At a checkpoint that does not auto-advance, `performCheckpoint` (`iris.swift:235-343`):

1. `setCheckpointPaused` (unchanged), then
2. `beginJudgementPause` **when the evaluation carries a `.humanPending` verdict.**

**Both callers get this.** `performCheckpoint` is reached from the `reach_checkpoint` handler
(`iris.swift:1523`) and from `delegate_milestone` (`:1570`). A delegated milestone whose
taste criterion nobody has judged must stop and ask exactly as a directly-worked one does; nothing
about handing the work to a subagent makes the question someone else's. The pause is raised inside
`performCheckpoint`, so this costs nothing beyond saying it — and saying it is what stops a planner
from special-casing the delegated path.

**The summary argument.** Pass `performCheckpoint`'s own `summary` — the agent's
`milestone_summary`, or the subagent's rendered outcome. `beginJudgementPause` parks it in
`pendingCompletionSummary` so a terminal accept can push it (`AppState.swift:1241-1248`), and the
checkpoint branch of `resolveJudgementIfComplete` returns before any such push, so at a checkpoint
the value is written and never read. Pass it anyway rather than `""`: a wrong summary surfacing the
day those branches are merged is a worse failure than a redundant write.

Read the condition off the **evaluation**, never the contract. The evaluation contains exactly the
projected criteria, and `GoalEvaluationParsing` assigns `.humanPending` precisely when a criterion is
`humanJudged` and unjudged (`GoalEvaluationParsing.swift:38-45`). D3 originally scanned the whole
contract, which opened a judgement pause for a criterion belonging to a *future* milestone — one
with no row in the evaluation, no button to click, and no way to clear the flag. That was a trapped
goal, caught in review; the evaluation-based condition is the fix and must not regress.

Resolution reuses D2 unchanged, via the checkpoint branch of `resolveJudgementIfComplete` that D3
added as a backstop and left unreachable (`AppState.swift:1155-1177`). It clears
`awaitingHumanJudgement`, leaves the checkpoint `.pausedForReview`, and returns **without**
finishing or clearing the goal. That branch becomes reachable for the first time here; it was
written for exactly this.

**The strings the pause emits change with it.** Before this slice the transcript line and the tool
result both described an ordinary review stop regardless of why the checkpoint paused — "Paused for
your review", "Checkpoint N reached and graded. Paused for user review." Today those two strings
still cover the ordinary case (`iris.swift:330-334`), but a `.humanPending` pause gets its own pair
naming the criteria waiting on the user (`:336-342`), and the comment above the branch explains why
(`:320-325`). The tool result is agent-facing, so a stale one is invariant 9's worse half: it
invites the model to keep working a milestone that is waiting on a human verdict. §12 lists the
pre-#191 wording with everything else the slice falsifies.

## 9. UI

`CheckpointPauseChip` (`GoalContractPanel.swift:478-605`) passes `onAccept`/`onReject` into
`DriftCriterionRow`, which already renders Accept/Reject for a `.humanPending` verdict when handed
both (`:976-989`). The chip constructs the row with them, sourced from the shared
`judgementHandlers` helper (`:538-546`). The rows render as they do at the terminal gate, so a
human verdict is still labelled as the user's and never as grader-verified evidence (D2 §6).

**The handler helper is a file-private function, not a method on either view.**
`judgementHandlers(state:conversation:criterionId:)` (`GoalContractPanel.swift:464-472`) takes
`(AppState, Conversation, UUID)` and returns an optional `(accept, reject)` pair, gated on
`awaitingHumanJudgement`; both `CompletionReportSection` and `CheckpointPauseChip` call it. One gate
in one place, so the two surfaces cannot drift on when the buttons appear — which is the failure
mode worth spending an extraction on, since the gate is what
keeps a finished goal from offering a re-judge that `recordHumanJudgement` would refuse.

The chip's Approve button takes the §6 disabled state and its caption. No new views.

**What the on-screen check found.** `Conversation.==` compares by `id` only, so a `CheckpointPauseChip`
that took a `Conversation` value would compare equal before and after a judgement was recorded — the
id never changes — and SwiftUI's diffing could then skip re-running the chip's `body` even though
`state.conversations` had mutated underneath it, leaving Accept/Reject and the header stuck on stale
state until something unrelated forced a redraw. This is not visible to any unit test, which drives
`AppState` directly and never goes through a `View`'s diffing; it surfaced only on screen, clicking
Accept against a running app. The fix: `CheckpointPauseChip` takes `conversationId: UUID`, not a
`Conversation`, and reads the live conversation out of `state.conversations` inside its own `body`,
so `@Observable` tracks the chip's dependency on that array directly and any mutation re-renders it
regardless of how the parent diffed its inputs. The same hazard applies to any other chip that takes
a `Conversation` by value rather than an id; see #223 for the sibling chips this was not fixed in.

### 9.1 Decisions a planner would otherwise have to invent

- **Caption and Approve placement.** The caption sits under the Send-back/Approve row, `.caption`
  and secondary: "Decide the human-judged criteria above before approving." Approve stays trailing,
  where it is on every other checkpoint (`GoalContractPanel.swift:573-584`); moving it for the one
  case that asks a question costs the muscle memory of all the others.
- **Header after a verdict.** The chip's trailing header text is "Awaiting your decision"
  (`GoalContractPanel.swift:523`). It becomes "Awaiting your approval" once nothing in the
  evaluation is `.humanPending`. The pause is still the user's to resolve, but the question it asked
  has been answered, and a header still asking reads as a UI that did not notice the click.
- **What a judged row shows.** The recorded verdict, read-only: `met` / `not met` with
  `method == .human`, which `DriftCriterionRow` already renders as the user's judgement rather than
  as evidence. The buttons are gone, because the row only draws them for `.humanPending`.
- **There is no undo, and that is the design.** After a verdict `resolveJudgementIfComplete` clears
  `awaitingHumanJudgement` (`AppState.swift:1162`), so the extracted helper returns nil, the
  handlers go nil and the buttons vanish; the verdict is also in `judgements` and outlives the
  evaluation. A mis-click's only recovery is Send back — which consumes the rejection and re-asks
  once the agent has actually reworked the criterion — so correcting a click costs a full rework
  round trip. We take that over an undo: a verdict the user can retract is a verdict the ladder
  cannot build an induction on, and the terminal gate has been one-way since D2. It is written down
  here so nobody has to discover it.
- **Goal cleared while the pause is open.** `clearGoal` nils `goalContract`
  (`AppState.swift:999-1014`), so the chip's `if let contract` guard drops it and there is nothing
  left to judge. It also nils `lastGoalEvaluation` and `lastGoalCompletionReport`, but **only when
  the contract being cleared had a pause open on the user**
  (`checkpointStatus == .pausedForReview || awaitingHumanJudgement`): without that scope, with §4's
  columns those fields would outlive the contract on disk and resurrect a chip for a goal that no
  longer exists. `/stop` and the terminal gate both route through `clearGoal`, so one change covers
  both. An **ordinary** completion — the terminal gate finishing with no pause open — must keep both
  fields: they are the completion-report chip's inputs, and nilling them unconditionally removed
  that chip after every normal finish. `sanitizeLoaded`'s no-contract rule already clears them on a
  restart regardless, so the restart case does not need `clearGoal` to nil anything. Both nils, when
  they apply, go before `clearGoal`'s existing `markChanged` (§4); §11 asserts the columns for the
  pause-open case, and `clearGoalKeepsFieldsAfterOrdinaryCompletion` pins the ordinary case.
- **A verdict landing mid-turn.** Nothing stops a user clicking Accept while a turn is in flight,
  and nothing should. `performCheckpoint` re-reads the contract after grading (`iris.swift:263-267`)
  precisely so a judgement recorded during the grade is seen, and `autoAdvanceCheckpoint` no-ops
  when the milestone it was decided for has moved (`AppState.swift:1354-1356`). So a verdict is
  applied at the next checkpoint decision and never inside one. No new locking, and no attempt to
  block the buttons during a turn — that would make the chip dead exactly when the grader run makes
  it slowest to come back.
- **Accessibility.** Each Accept/Reject button carries `.buttonStyle(.plain)` plus an
  `.accessibilityLabel` naming its criterion — `"Accept: \(verdict.criterionText)"` /
  `"Reject: \(verdict.criterionText)"` (`GoalContractPanel.swift:976-989`) — so VoiceOver does not
  read a column of identical "Accept" buttons, and each stays in the tab order and activates from
  the keyboard when focused. Deliberately **no chip-wide key equivalent** on Accept/Reject: there are as
  many pairs as there are pending criteria, so a single shortcut has no unambiguous target, and a
  keystroke that records an irreversible verdict on a chip that appears while the user is typing is
  the wrong default. Approve and Send back keep the keyboard behaviour they have.
- **Approve leaves a completion-report chip showing mid-ladder, and that is fine.** `advanceCheckpoint`
  clears neither `lastGoalEvaluation` nor `lastGoalCompletionReport`, so once the checkpoint chip
  disappears (`checkpointStatus` back to `.running`), `ChatView`'s standalone-chip condition is now
  satisfied and `CompletionReportChip` renders with the milestone just approved's grade
  (`ChatView.swift:317-318`). This is not new: it already happened in-session before this slice;
  §4's columns just mean it can also happen right after a restart. It is dismissible
  (`dismissCompletionReport`) and does not block anything — it is a receipt, not a pause.

## 10. Interaction constraints

- A rejected criterion is consumed by send-back (`holdCheckpoint`), so re-work re-asks. Unchanged
  from D3; it is what makes §6's rejected-gate coherent.
- Auto-advance must remain impossible while `awaitingHumanJudgement` — `canAutoAdvance` already
  guards on it (D3, `GoalContract.swift:436-438`), and that guard is now reachable in earnest.
- A laddered goal still completes through the terminal gate after all its checkpoints resolve.
- Judgements recorded at a checkpoint are not re-asked at completion (D3 §5.1, `judgements` is
  durable and reconciliation reads it).

## 11. Testing

- **Restart round-trip through `ConversationStore`**, not the JSON codec. D3 shipped a field that
  round-tripped in JSON and was never persisted, because post-#197 the store enumerates columns by
  hand. Build an `AppState(store:)` over an in-memory store (`AppState.swift:288`), open a
  checkpoint judgement pause, drop the `AppState`, construct a new one over the same store, and
  assert the chip's inputs are back — `lastGoalEvaluation` present with its `.humanPending` row —
  and that `recordHumanJudgement` accepts a verdict rather than refusing it.
- **Store round-trip for both new columns** in `ConversationStoreTests.roundTrip`, which asserts
  every stored field and now carries a non-nil value for both (`:85-86`). Nil round-trips as SQL
  NULL, not JSON `null` (`surfacingFieldsNilRoundTrip`, `:97-109`); a v5-era database migrates and
  loads its rows with both nil (`preV6RowLoadsNil`, `:111-127`).
- **An undecodable column value yields nil and keeps the conversation**, with a `SkippedRow`
  recorded — the `checkpointHistory` policy, not the `goalContract` one (§4).
- **A store write is scheduled** when a judgement pause opens: the fields are unobservably correct
  in memory whether or not `markChanged` fired, so assert the persisted row, not the property (§4).
- Accept at a checkpoint resolves the criterion and leaves the goal running and `.pausedForReview`.
- Reject likewise, and does **not** finish the goal.
- Approve is disabled for an unjudged criterion, and for a rejected one; Send back is enabled in
  both.
- **The gate's set equals send-back's set** (§6): a rejected `humanJudged` criterion in an *earlier*
  milestone does not disable Approve at a later checkpoint. Construct it directly rather than
  reaching it through the ladder — §7's induction is what makes it unreachable in normal operation,
  and this test exists for the day the induction stops holding.
- **The waiver branch is ordered before the `humanJudged` branch** in `canAutoAdvance` (§7): a
  waived `humanJudged` criterion auto-advances with no judgement recorded. Assert the behaviour
  rather than the source order, and name §7 in the test so the dependency is written down in the one
  place someone adding checkpoint-level waivers is guaranteed to read. The test fails the day the
  ordering changes, which is the right moment to decide which of the two §7 should say.
- Both defensive clears (`advanceCheckpoint`, `holdCheckpoint`) pinned individually (§5).
- A judgement pause opens only for a criterion in the graded set — a `humanJudged` criterion in a
  *future* milestone must not open one (§8's regression).
- A judgement pause opens on the **delegated** path too (`delegate_milestone`), not only on
  `reach_checkpoint` (§8).
- `sanitizeLoaded` keeps the surfacing fields when the run is paused on the user and still clears
  them when it is not.
- `clearGoal` nils both surfacing fields **and the store row has both columns NULL afterwards**
  when the contract being cleared had a pause open on the user: open a checkpoint judgement pause,
  clear the goal (simulating `/stop`), flush, load a fresh `AppState` from the same store, and
  assert the columns. The in-memory nils are correct whether or not the write was scheduled, so a
  property assertion proves nothing here (§4, §9.1).
- `clearGoal` **keeps** both surfacing fields, in memory and on disk, after an ordinary
  completion — no pause ever opened, `finishGatedGoal` → `clearGoal` — so the completion-report
  chip still has something to show and dismiss (`clearGoalKeepsFieldsAfterOrdinaryCompletion`,
  §9.1).
- The `.humanApproved` / `.humanSentBack` history entry carries the **post**-judgement evaluation —
  the verdict the user gave, not the grader's `.humanPending`. It does today by construction
  (`recordHumanJudgement` mutates in place and `recordCheckpointOutcome` is passed
  `lastGoalEvaluation`, `AppState.swift:1124-1148`, `:1371-1372`, `:1391-1392`); pin it, because
  nothing else would notice if it stopped.
- A laddered goal completes through the terminal gate afterwards.
- **Not unit-testable: `CheckpointPauseChip` re-rendering in place after a judgement.** No unit test
  drives SwiftUI's diffing, so the stale-chip hazard (§9, "What the on-screen check found") cannot
  be pinned by one. Verified on screen instead: seeded a fixture conversation paused at a checkpoint
  with a `.humanPending` criterion, ran the app, clicked Accept, and confirmed the chip's row and
  header updated in place without switching conversations or otherwise forcing a redraw.

## 12. What this makes untrue

Invariant 9: the falsifying half of the documentation change, enumerated so the plan has a task for
it rather than a good intention. Everything below asserts that a checkpoint stops without asking.
**Line numbers in this section are as they were before #191 and are not maintained** — this is a
record of what was falsified, not a current index; use the corresponding section elsewhere in this
document (or the D3 spec) for a citation that still resolves.

- **D3 §6 in full** — its title ("it stops, it does not ask"), "The pause does **not** ask for the
  verdict. No `beginJudgementPause` at a checkpoint", "A `humanJudged` criterion is asked about
  once, at completion", and the closing note that no judgement can be recorded before the terminal
  gate. Also D3 §6's "Why the inline Accept/Reject is deferred" paragraph and its §11.1 note that
  `resolveJudgementIfComplete`'s checkpoint branch is unreachable. D3 §2's out-of-scope bullet
  ("Inline judgement at a checkpoint → a future slice") should point here.
- **D3 §3's deferral consequence** — the paragraph stating that nothing can record a judgement
  mid-ladder, so auto-advance is off for the remainder of a ladder carrying a taste criterion. That
  is the cost this slice removes.
- **`README.md:34`** — "That question is asked once, at the end — a checkpoint along the way stops
  for an undecided human-judged criterion rather than advancing past it, but leaves the verdict
  itself for the final gate."
- **`README.md:37`** — "a 'human-judged' criterion you have not yet decided — which stops the run
  for your review without putting the verdict to you there; human-judged criteria are still decided
  at the final gate".
- **`AppState.swift:1531-1539`** — `sanitizeLoaded`'s doc comment, which says the surfacing is
  per-session and dropped on load unconditionally.
- **`AppState.swift:1212-1214`** — `recordCheckpointOutcome`'s doc comment, that after a restart the
  human controls "genuinely have no grade to record".
- **`AppState.swift:1066-1068`** — the comment inside `resolveJudgementIfComplete` saying nothing
  opens a checkpoint judgement pause today and the branch is a backstop.
- **`GoalContractPanel.swift:693-701`** — `CompletionReportSection`'s `conversation`/`state` doc and
  the `judgementHandlers` comment, both of which say the checkpoint pause chip's use "must stay
  read-only".
- **`iris.swift:298-303`** — the comment in `performCheckpoint` explaining that the checkpoint
  deliberately does not ask because the surface was never built.
- **`iris.swift:305-308`** — the transcript line and the tool result, agent-facing (§8).

Not falsified, checked: `GoalContract.oracleText`'s checkpoint line (`GoalContract.swift:278`) and
the `reach_checkpoint` declaration (`iris.swift:724`) both say only that anything contested "pauses
for the user", which stays true. `README.md:36` (Checkpoint Delegation) says the same. Leave them.

## 13. The larger arc

With this, every criterion kind is decidable at the checkpoint that raises it, and D3's
auto-advance works for ladders containing taste criteria. Remaining: **E — the ratchet**, and
**F — ground-truth progress view**, which renders `checkpointHistory` and adds retroactive
send-back.
