# Sessions: Identity, Discovery, and One Message (slice 1 of #185) — Design

**Status:** implemented — all seven tasks complete on `feat/185-sessions-slice1` (#185); not yet
merged to `main`, no PR opened yet.
**Issue:** #185
**Builds on:** #182 (archiving), #163 (conversation store), #144/#133 (tool-surface gating)

## 1. Overview

An active conversation becomes a **session**: it advertises who it is and what it is doing, it can
see its peers, and one session can send another a message that wakes it.

That is the whole of this slice. Handing work off, negotiating, and waiting for another session to
finish are deliberately not here (§11) — those are blocking primitives between autonomous agents,
and they deserve their own argument.

**A2A for schema, not transport.** The vocabulary is A2A's — an agent card for identity, a message
for delivery — but everything is in-process Swift types. There is no network boundary between two
conversations in one app, so a wire protocol would be pure overhead today. Keeping the *shape*
means a later transport (NATS per #194, or HTTP) slots under it without redesigning the concepts.

**The two constraints that shape everything below**, both named in the issue:

- **Context must not be poisoned.** A session that knows too much about its peers pays for that
  knowledge on every turn. §6 holds the standing cost at one line.
- **Sessions do not stay awake.** Delivery wakes the target; the harness does not keep sessions
  running. §5.

## 2. Scope

In: the session card, discovery, one message primitive, the wake, the tool gating, and the cascade
cap.

Out, deliberately:

- **Handoff, negotiation, and wait-for-completion → their own spec.** A session blocking on a reply
  that never comes is this codebase's recurring trapped-state failure in a new costume. It needs a
  spec that answers what happens when the peer is archived, crashes, or simply never answers.
- **Multi-user trust boundaries.** Every session today belongs to the same user, so all peers are
  equally trusted. When that changes, the sanitization in §5 is the seam that already exists.
- **Subagents as sessions.** Subagent conversations are ephemeral scratch and are excluded (§3).

## 3. What is a session

A conversation is a session when it is **active**: not archived, not a subagent.

Archiving already means *idle* in two senses (#182 §1): a conversation doing work cannot be
archived, and one receiving work is un-archived. This adds a third that follows from the same rule
— **an archived conversation is not discoverable and cannot be addressed**. No new mechanism; the
same predicate.

**Archiving is the only thing that bounds the peer set, and everything below depends on that.**
A user accumulates conversations without limit; without the active predicate, every conversation
they have ever had stays addressable forever. Three things in this spec fail at once if that
happens:

- `list_sessions` returns hundreds of entries — precisely the context poisoning the issue warns
  against, at a scale no summarisation fixes.
- The peer-exists gate (§6) becomes permanently true, so the three tools are declared on every turn
  of every conversation. #133's win is simply gone.
- The cascade cap (§7) weakens sharply, because a bounded budget spread over an unbounded set of
  reachable targets is a much weaker guarantee than the same budget over a handful.

So the active predicate is not merely a tidy definition of "session". It is the mechanism that
keeps the peer set small enough for the cost model and the safety model to hold.

**That mechanism is currently manual**, which is its weak point: it works only as well as the user
archives. A TTL-based auto-archive — a conversation untouched for long enough becomes archived on
its own — would make the bound hold without depending on anyone's habits, and is the natural
complement to this slice. It is deliberately not here: auto-archiving is a behaviour change to
#182 that deserves its own argument about what "untouched" means and what it does to a paused goal.
Tracked separately. §4's listing cap is what holds the line until then.

Subagent conversations are excluded for the reason they are excluded everywhere else: they are
scratch, deleted when their run ends, and already filtered out of persistence. The drift
evaluator's scratch conversation is excluded by the same `isSubagent` flag — worth noting because
#217 treats "evaluator" as a session kind for display, where this spec does not treat it as a peer.

## 4. The card

New on `Conversation`:

```swift
/// A2A-shaped identity a session advertises to its peers (#185). Distinct from `title`, which is
/// the user's name for the chat: the card is what the agent is doing *now* and changes as the work
/// changes, where a title the user set should not.
struct SessionCard: Codable, Equatable, Sendable {
    var name: String          // short, stable handle — "spec-writer", "iris-review"
    var description: String   // what this session is doing right now
    var updatedAt: Date
}

var sessionCard: SessionCard?
```

**Invariant 1 applies twice over.** `decodeIfPresent(...) ?? nil` in `Conversation.init(from:)`
**and** a real column (`v8_session_card`, assign the number against `main` at implementation time —
two migrations have already collided on this branch pattern). Post-#197 the store hand-enumerates
its columns; a field absent from them is dropped on every load while its JSON round-trip test
passes. `ConversationStoreTests.roundTrip` is the test that proves persistence.

**Why not reuse the title.** The title and the card have different lifetimes. A title the user set
deliberately must not be overwritten by the agent advertising its current task, and an advertised
description that says "drafting the D3 spec" is useful to a peer and wrong as a permanent title.
Conflating them means one of the two is always stale.

**The listing is capped, not merely expected to be small.** `list_sessions` returns at most
**20** peers and says so when it truncates — `showing 20 of 34`. §3's bound keeps the realistic
count low, but that bound rests on the user archiving things, which is a habit rather than a
guarantee. A cap makes the context cost of a listing bounded by construction: the worst case is a
known number of rows, not a function of how diligent the user has been.

Ordering is most-recently-active first, keyed on the conversation's `updatedAt` — not
`card.updatedAt`, which records when the session last *described* itself and would rank a chatty
self-describer above a busy one. The truncated tail is therefore the least recently active. A
session needing the full set narrows by workspace, which is the gate the card exists to provide.

**`updatedAt` has to be advanced in memory for any of that to be true.** The store column has been
written on every upsert since v1, but nothing wrote the value back onto the live `Conversation`, so
the in-memory field meant "when this was loaded or created" and the ordering above froze at launch:
a session working all day never moved up, and any conversation created later in the run outranked
every one loaded at startup. It is therefore stamped at `AppState.markChanged` — the single point
every persisted mutation already passes through, which is what makes it the right signal for
"touched" — set directly on the element rather than routed back through `markChanged`, which would
not terminate. `.deleted` is excluded: there is nothing left to stamp. `ConversationStore` writes
the conversation's own `updatedAt` into the column rather than the write clock, so a batch of dirty
conversations flushed together comes back from a restart ordered by activity and not by flush order.
A test that assigns `updatedAt` by hand cannot see any of this; the ordering test must drive real
activity through the public API.

`card.updatedAt` exists so a reader can judge staleness: a description written an hour ago may no
longer be what the session is doing. Nothing acts on it automatically — liveness comes from the
harness (§6.1), not from the card's age.

**Workspace is part of the advertised identity, and costs nothing.** `Conversation.workspacePath`
is already persisted, so `list_sessions` reports it without new state. It is the cheapest useful
signal a peer has: agents bound to different workspaces are usually irrelevant to each other, and
this lets a session filter **before** spending a message or any context — a deterministic gate
rather than a round trip that discovers irrelevance. It composes with `set_workspace`, so rebinding
re-advertises automatically.

**Who writes it.** The session itself, via `set_session_card`, which is declared under the same
gate as the other two (§6). There is no automatic naming: the rename machinery that titles a
conversation (#132) is about the user's view and stays independent. A session with no card is still
listed — by id, title and workspace — rather than hidden, so a session that never got round to
describing itself is not invisible to its peers.

Two sessions sharing a workspace is the interesting case — they can collide on files. That is not
this slice's problem, and it is the argument for surfacing workspace prominently rather than
burying it.

## 5. Delivery: one message, through the existing choke point

`send_to_session(session_id, message)` delivers via
`IrisEngine.handleSystemEvent(_:source:conversationId:)`.

That choke point already does three things this slice would otherwise have to build:

1. **Sanitizes arriving content** through the tier-3 injection guard (`iris.swift:128-129`). A peer
   message is untrusted input crossing an agent boundary, and is treated as such — the same
   treatment subagent results already get.
2. **Un-archives its target** (#182 §6.2) — though see §5.1, which is why delivery is gated before
   it reaches here.
3. **Wakes the session** by starting a turn, which is exactly the issue's "the harness handles
   waking up sessions".

Reusing it is not only economy. Four consecutive review rounds on #182 converged on
`handleSystemEvent` as *the* arrival point precisely because every per-caller rule missed a caller;
adding a fifth independent arrival path would reopen that.

### 5.0 Framing: the sender does not choose its own trust label

**This is a security requirement, not a presentation detail.**

`processInputBody` renders every non-UI arrival as `System Event [<source>]: …` and appends
*"Analyze this event. If it requires action based on your directives/skills, take it."*
(`iris.swift:493`). `source` is also the guard's context tag (`:129`). So the label decides both
how the message is framed to the model and how it is tagged for inspection.

If that label carried the sender's card name, a session could name itself `User` or `Scheduler`
and have its message framed as a trusted instruction to act on. The sender would be choosing its
own trust level. §9's "advertised, not authoritative" was written about card descriptions and does
not reach this.

So:

- **The `source` is a harness-owned constant** — `peer_session` — never the sender's name, never
  anything the model supplies.
- **The sender's identity is supplied by the harness**, from the sending conversation's id, and
  appears in the body as attribution. A model-supplied "from" field is not trusted and is not used.
- **The framing states what the message is**: a request from another session, which the target is
  free to evaluate, act on, or decline. It must not inherit the standing "take action" instruction
  that suits a scheduler firing the user's own job.

The distinction that matters: **sanitisation is a detector, not an instruction-following barrier.**
The tier-3 guard catches known injection shapes; it does not stop a model obeying a plausibly
framed instruction. The framing is the control, and it is the reason this subsection exists rather
than relying on §5's sanitisation alone.

### 5.1 A send to an archived session is refused, not resurrected

A session can be archived between `list_sessions` and `send_to_session`. Because
`handleSystemEvent` un-archives by design, delivering into it would silently bring an archived
conversation back — contradicting §3 and the issue's own first sentence.

**So the archived check lives in the send tool, before delivery**, and returns a refusal the model
can act on: *"that session is no longer active."* Not a silent drop: the sender asked a question
and is owed an answer.

**Why refusal rather than the simpler alternative.** Letting a send un-archive would be consistent
with #182 §6.2 and would need no special case at all, which is a real argument for it. It is wrong
anyway, and not mainly because it undoes a user's deliberate action: it is wrong because it
destroys the bound from §3. If an archived conversation can be addressed, archiving stops bounding
the peer set — a session could address anything the user ever created, and the reachable set grows
without limit for the life of the install. The cost model in §6 and the cap in §7 both rest on that
set staying small.

The asymmetry this creates is deliberate and worth stating plainly: a **human** sending into an
archived conversation un-archives it (#182 §6.2), while a **peer** is refused. That is not an
inconsistency to be tidied away later. The human is choosing to reopen one specific conversation;
a peer doing the same would be re-expanding the address space on its own initiative.

### 5.2 Delivery into a busy target

`handleSystemEvent` calls `processInput` unconditionally. `sendMessage` does not: when a turn is
already running it enqueues through the #172 inbox rather than starting a second, interleaved turn
on one history (`AppState.swift:937-940`), because two turns on one history produce empty or
rejected provider responses.

Today reaching that hazard needs a scheduler or watcher coincidence. **Peer messaging makes it
agent-triggerable at will, and this slice introduced a partial form of that risk** — the correction
below states what actually holds, in place of the guarantee this paragraph originally claimed.

**Closed (#240): the busy decision and the turn it authorises are now atomic.**
`deliverPeerMessage` used to read `AppState.hasTurnInFlight(for: targetId)` and then hand off — a
check followed by an act. Two concurrent `send_to_session` calls targeting one idle session both
passed the check, because the winner's turn is handed to a detached task and has not registered
yet, and both landed a turn on the same history. That was the exact hazard this section describes,
reachable by an agent choosing to send twice rather than only by scheduler/watcher coincidence.

Review round 3 narrowed it with a second `hasTurnInFlight` check after `sanitizeArrival` — the
dominant term in the gap, since tier-2 CoreML and tier-3 auxiliary-model inference can hold it open
for hundreds of milliseconds. That narrowed the window without closing it, and the remainder was
filed as #240.

It is closed now, and without the lock the earlier note assumed it would need.
`AppState.claimPeerDelivery(for:)` decides and reserves in a single synchronous `MainActor` body,
so no moment exists between the two for a second claimant to occupy. The reservation *is* a turn
count: `hasTurnInFlight` already reads `engineTurnCounts`, so claiming through `beginEngineTurn`
makes a concurrent claimant see the target as busy immediately, with no second piece of state to
keep in step. The loser takes the #172 inbox — which is what it would have done had the winner's
turn already been running. The claim is released once the turn it authorised finishes, so the count
never reaches zero mid-turn and the inbox drain still fires exactly once.

So the inbox routing described below now holds under genuine concurrency, not only for sends spaced
further apart than `sanitizeArrival` takes.

**A peer message to a busy session is enqueued through the same #172 inbox**, delivered as a steer
at the target's next model round. Not refused: the sender has no way to know the target is busy,
refusal would make delivery depend on timing the sender cannot observe, and the inbox already
exists for exactly this.

The send therefore reports *accepted* rather than *delivered* — see §5.3 — because at the moment of
sending, those are genuinely different claims.

### 5.3 What a send returns

Four outcomes, all reported to the sender rather than failing silently:

- **accepted** — queued or delivered; the target will see it.
- **refused: no such session** — unknown id.
- **refused: not active** — the target is archived (§5.1).
- **refused: budget exhausted** — the cascade cap (§7).

A self-send is refused before any of these (§5.4).

### 5.4 Self-sends are refused

A session messaging itself is an immediate loop. Refused outright, before the cascade accounting in
§7 is even consulted.

## 6. Cost: the tools appear only when there is someone to talk to

`list_sessions`, `send_to_session`, and `set_session_card` are declared **only when at least one
other active session exists.**

This gate is only meaningful because the peer set is bounded (§3). If archived conversations
counted, it would be true from the first day a user archived anything and never false again.

With a single conversation open — the common case — the tool surface is byte-identical to today.
#144 and #155 (tracked under #133) brought a plain turn from 30 declarations to 8 — measured at
~3,350 bytes of declaration JSON, roughly 840 tokens; adding three unconditional
declarations would put a meaningful fraction of that back on every call and invite the unprompted
probing that #132 and #144 were about. This is AGENTS.md **invariant 6**'s lifecycle-state pattern,
the same shape the goal and ladder tools already use.

**Main principal only.** All three tools are declared for `principal == .main`, matching every
other state-gated tool (`iris.swift:771, :785, :807`). A subagent is not a session (§3) and does not
get them; if one somehow attempted a send it is refused as "not a session", so a subagent can
neither originate nor extend a cascade.

**The peer count is injectable**, the way `workspaceToolsEnabled` already is. Read from global
state it would break the perf harness: `ScenarioRunner.run` builds `AppState()` over
`ConversationStore.makeDefault()` — the developer's real store — so on any machine with a second
active conversation the three declarations would appear and the #129/#144 baselines would shift
under measurement. §10's declaration test needs the same seam.

**Standing context is one line**: a bare count — `3 other sessions are active` — present only when
peers exist. Enough for the model to consider delegating; no roster, no per-peer detail, nothing
that grows with session count or churns every turn as peers update their cards. The issue's
"not to a great level of detail, poisoning context" is the requirement, and detail is available on
demand through `list_sessions`.

## 6.1 The three tools

- **`list_sessions()`** — no parameters. Returns, per peer: `session_id`, `name` and `description`
  (empty when no card), `workspace`, and `busy` / `idle`. Capped and ordered per §4. Busy/idle is
  **derived by the harness**, never read from a card: a model-written "what I am doing" string is
  advertised, not authoritative (§9), and liveness is exactly the field a peer must not be able to
  misreport. See §12 on where that derived state comes from.
- **`send_to_session(session_id, message)`** — outcomes in §5.3.
- **`set_session_card(name, description)`** — writes the calling session's own card; it cannot
  write another's. Rejects an empty name, and truncates each field to the render cap before storing
  it (#246), so a card cannot be an unbounded row in the `sessionCard` column.

Their `description` strings are agent-facing text and fall under invariant 9: they must say when to
call, per #155, and must not imply a peer is obliged to act on a request.

**Every session-authored field is hardened before it is rendered.** `list_sessions` returns a
`\n`-separated, `|`-delimited list, and three of its five fields — `name`, `description`,
`workspace` — are bytes another session wrote through `set_session_card` / `set_workspace`. The
card's two fields are length-bounded at the write since #246, but nothing flattens at the write and
`workspace` is bounded only here, so the renderer still treats all three as unbounded and hostile. Rendered raw they are a cross-agent
injection channel: a card can embed newlines and pipes to close its own row and open forged ones,
naming a `session_id` of its choosing or announcing itself as `User`. §5.0's "the sender never
chooses its own trust label" has to hold on the *list* path as well as the message path. So each
such field goes through the same flattener `peerLabel` uses (`IrisEngine.flattenCardField`): every
line break removed (Unicode separators included), `|` replaced, `"` replaced, and a per-field cap —
64 for a name, 200 for a description, 160 for a workspace. Session-authored values are additionally
rendered **quoted**, harness-owned ones (`session_id`, `busy`/`idle`) unquoted, so a peer's claims
about ids are visibly the peer's own string. One flattener, not two: a second copy is how the
message path and the list path came to disagree in the first place.

**The card column decodes defensively**: unreadable → `nil`, with a warning, never a dropped
conversation. The *policy* matches `checkpointHistory`'s: a JSON decode failure on either field
(`ConversationStore.swift` ~771-773 for `checkpointHistory`, ~814-821 for `sessionCard`) is recorded
as a skipped row and leaves the field absent, never the conversation.

The *mechanism* used to differ, and no longer does (#233). `checkpointHistory` was read through the
shared `text(_:)` closure in `loadAll`, whose `.invalid` case — bytes that are not valid UTF-8 — set
`unreadableColumn` and quarantined the **entire conversation**, while `sessionCard` bypassed that
closure and read through `readTextValue` directly. So the card was strictly more defensive than the
precedent it cited: a bad byte cost the card, but the same bad byte in an audit trail cost the
messages, the contract and the workspace with it.

#233 moved `checkpointHistory`, `lastGoalEvaluation`, `lastGoalCompletionReport` and
`subagentResult` onto the card's behaviour — on *both* paths, so a column never disagrees with
itself about whether a bad byte and bad JSON cost the same thing. The sentence above is now simply
true for all of them. The line it drew instead is between what a conversation *is* and what happened in it:
`title`, `workspacePath`, `activeGoal` and `position` are identity; `mainAgentSandbox` governs
whether commands are contained; `tokenUsage` is what per-run budgets compare against, so reading it
as zero hands a job an unbounded one; `goalContract` is the goal. Those still take the conversation
with them, deliberately. Everything else loses only itself, and says so in `skipped`.

## 7. The cascade cap

Wake-on-delivery means one session can make another spend tokens with no human involved. Left
unbounded that is a cascade: A messages B, B messages C and D, each of those messages more.

**A depth limit alone does not cap this.** With fan-out F and depth N it still permits F^N turns.
The budget must be shared by the whole cascade, not carried per branch.

`AppState` holds two maps: `cascadeOf` (conversation -> the cascade it is in) and `cascadeBudget`
(cascade -> what is left of its allowance). **Two maps, not one `(cascadeId, remaining)` per
conversation** — that shape looks equivalent and is not. It has no way to share a counter: a
delivery has to copy `remaining - 1` into both sender and target, after which the two drift
independently and every branch effectively holds its own allowance. At the default 8 and binary
fan-out that is 2^8 - 1 = 255 peer-woken turns from one user action: the F^N this section exists to
forbid, at base 2. The rules below are therefore stated against the shared counter:

- **A user-initiated turn clears the entry**, at `AppState.startTurn` (`:945`) specifically — not
  `runThinkingTask`. §5 argues for choke points, so this one is named: `runThinkingTask` also
  carries the `/goal` draft kickoff and every goal resume, which are machine-initiated
  continuations rather than a person typing, and clearing there would hand a cascade a fresh
  budget every time a goal resumed. `startTurn` is the tightest point that means "the user sent
  something".
- **A peer delivery resolves the sender's cascade** (minting one on its first send), checks that
  cascade's single counter, decrements it **once**, and maps both sender and target into it.
- **`send_to_session` reads the sender's cascade through `cascadeOf`** and refuses at zero.
- **Clearing is per conversation and never touches the counter.** `clearCascade` drops that
  conversation's membership only; the budget entry is removed only once no conversation maps to it
  any more, so it neither refunds siblings nor leaks an entry per cascade the session ever ran.
  Deleting a conversation clears it the same way.

Because the allowance travels with the cascade rather than the branch, A→B, C, D consumes three of
the same budget. Total peer-woken turns descending from one user action is capped at N for any
shape — depth, fan-out, or any mix.

The shape that *proves* this is neither a ping-pong nor a fan-out: in a ping-pong the sender is
always the most recent target, and in a fan-out the sender never changes, so a copied allowance and
a shared one produce identical numbers in both. The discriminating shape is a chain that walks away
from the original sender — x→y, y→z, z→a — until the budget is spent, and then one more send **from
x**. Shared, it is refused; copied, x is still holding the count it was handed at step one.

**A human typing into a woken session ends that session's cascade.** The rule in the first bullet
is stated per conversation, so if the user opens a session that a peer woke and sends a message,
that conversation's entry clears and its onward sends start fresh. That is the intended reading: a
person has entered the loop, and the budget exists to bound *unattended* machine chatter, not to
ration a conversation the user is actively steering. Sibling branches of the original cascade keep
their own remaining allowance.

**A drained peer message does not reset the budget — this is deliberate, not an oversight.**
`AppState.startTurn` only clears the cascade entry when `isPeer` is false (`AppState.swift`
~1034-1040): a person typing clears it, a peer message finally drained from the #172 inbox and run
as a turn does not. Round 3 fixed a path where draining a queued peer entry cleared the cascade
unconditionally — handing the target a fresh budget on every drained message regardless of how much
the cascade had already spent, a cap bypass by timing rather than by count. So when a cascade's
budget is exhausted, it **stays** exhausted until a human types into that conversation; no machine-
initiated continuation, drained peer message included, may hand it a new one.

`N` starts at **8** and is a `ConfigManager` setting, because the right number is empirical and
guessing it permanently would be worse than making it adjustable.

The refusal surfaces **at the sender**, with the reason, rather than failing silently at the
target: a model that knows it is out of budget can say so; one whose message vanished cannot.

This mechanism needs no plumbing through `processInput` — it is `AppState` state keyed by
conversation, which is already the coordination point.

## 8. Concurrency: already satisfied

The issue asks whether sessions "should probably run in their own threads so they can execute
concurrently." They already do, and this slice builds nothing for it:

- `AppState.runThinkingTask` spawns an independent `Task` per call; `thinkingCount` is a reference
  count, not a lock, so several conversations can have turns in flight at once.
- `IrisEngine` is a single actor, but Swift actors are **reentrant**: at every `await` another
  conversation's turn may enter. Its only mutable state (`repromptTasks`, `loopDetectors`,
  `warnedNoRuntime`) is already keyed by conversation id.

Turns therefore interleave today. They are concurrent, not parallel — one actor executes one thing
at a time between suspension points — but the work is network-bound, so interleaving captures
nearly all of the benefit. True parallelism would mean an engine per session and would collide with
`AppState` being `@MainActor`, for a gain that does not exist while the bottleneck is the provider.

Recorded here so the question is answered rather than re-asked.

## 9. Interaction constraints

- **Archived**: not discoverable, not addressable (§3, §5.1). A delivery never resurrects.
- **Subagents**: never sessions, never listed.
- **The card is advertised, not authoritative.** A session describes itself; nothing verifies the
  description. Peers must treat it as a hint, the same way a self-report is not a grade (slice A's
  honesty rule).
- **`/stop` and the LED bar** remain the human's controls over a running cascade; §7 bounds it, it
  does not replace them.
- **A target with an active goal or paused at a checkpoint is still addressable.** `archiveRefusal`
  treats an active goal as busy for *archiving*, but a peer message to a working session is the
  normal case, and §5.2's inbox handles the in-flight part. A session paused awaiting a human
  decision receives the message and will see it when it resumes — it is not woken past its pause,
  because the pause suppresses the loop rather than the inbox.
- **`set_session_card` is gated on a peer existing** (§6), so a lone session cannot describe itself
  until there is someone to describe itself to. Deliberate: the card has no reader before then, and
  ungating it would put a declaration on every single-conversation turn for no benefit.

## 10. Documentation

Invariant 9: this changes user-facing behaviour, so it fixes what it makes untrue rather than only
describing what it adds.

- **`README.md:40`** currently says sending anything to an archived conversation brings it back
  automatically. §5.1 makes "anything" false — a *peer* send is refused. Correct it to distinguish
  the human case from the peer case, since that asymmetry is deliberate (§5.1).
- **`README.md:119`** ("Session Control") — no slash commands are added by this slice; sessions are
  reached through tools, not commands. Say so if the section would otherwise imply otherwise.
- **A feature bullet** for sessions: what a session is, that peers can list and message each other,
  that archived conversations are not reachable, and that a peer message is treated as a request
  rather than an instruction (§5.0) — the honesty point, in the README's voice.

## 11. Testing

- Store round trip through `ConversationStore` — the card survives a real load. A JSON-only test
  would pass while the column did not exist.
- A conversation with no `sessionCard` key decodes as nil (invariant 1).
- `list_sessions` excludes archived conversations and subagents, and reports workspace.
- `send_to_session` to an archived session refuses and does **not** un-archive it — asserted on the
  flag, not only on the error string.
- A self-send is refused.
- **The cascade cap holds under fan-out, not just depth**: a cascade that branches must exhaust the
  same budget as one that chains. This is the assertion that would have caught the design error the
  first draft of §7 contained.
- **The cap holds for a sender the chain has moved on from** (§7's discriminating shape): spend the
  budget along a chain, then send once more from the original sender and expect a refusal. Fan-out
  and ping-pong cannot see the difference between a shared counter and a copied one; this can.
- A user-initiated turn resets the budget **for that conversation only** — siblings still in the
  cascade keep their remaining allowance, and the counter is not refunded.
- A self-send is refused, and the refusal does not debit the budget.
- The budget-exhausted refusal reaches the sender with its reason, and delivers nothing.
- Both acceptance strings are asserted: the idle path reports a background delivery, the busy path
  reports that the target will see it at its next turn.
- `set_session_card` writes the calling session's card, refuses an empty name, and refuses a
  subagent — the last asserted at the handler, not only at declaration.
- **A card cannot forge a row or a `session_id` in `list_sessions`** (§6.1): a card carrying
  newlines and pipes still produces exactly one row, advertising exactly the real peer's id, and an
  over-long field is capped rather than becoming the bulk of the reader's turn.
- **The peer listing's ordering responds to real activity** (§4): driven through the public API,
  never by assigning `updatedAt`. A test that hand-sets the field passes against a frozen signal.
- **A peer message queued behind a busy turn is visible to the user**: the busy path appends the
  same transcript notice the idle path does, so a steer the user did not issue is never invisible
  to them.
- The three tools are absent with one conversation open and present with two — asserted on the
  declaration list, since this is what protects #133's win.
- `list_sessions` truncates at the cap and reports the true total, so a large peer set cannot
  silently become a large context payload.
- **A peer message to a busy session is enqueued, not interleaved** (§5.2): with a turn in flight,
  the send is accepted and no second turn starts; the message is delivered at the next model round.
  This is the assertion that keeps peer messaging from making the #172 hazard agent-triggerable.
- **The arrival is framed as a peer request, not a system instruction** (§5.0): the rendered event
  carries the constant source, not the sender's card name, and a session whose card name is `User`
  or `Scheduler` produces byte-identical framing to any other. Asserted on the rendered text.
- **The sender's identity comes from the harness**: a model-supplied "from" in the message body
  does not change the attribution the target sees.
- A send to an unknown id is refused rather than silently dropped.
- A subagent has none of the three tools declared, and a subagent send is refused (§6).
- The declaration test drives the **injected** peer count, not global state, so it cannot pass or
  fail based on what is in the developer's store.
- The standing count line appears only when peers exist.
- **Known gap: the round-3 late busy re-check (§5.2) has no test.** Constructing that window
  deterministically — a target that is idle at `deliverPeerMessage`'s first check but busy by its
  second — needs a blockable delay inside `sanitizeArrival`, whose only seam is
  `CoreMLEvaluator.shared` / `AuxiliaryModelManager.shared`. Those are shared, global mocks, which is
  itself a known test-isolation hazard (**#237**) that makes suites order-dependent and flaky. The
  test is blocked on a real bug, not merely unwritten — do not treat this as covered.

## 12. Relationship to #217's session summary

#217 (in flight) adds `SessionSummary`: transient, harness-derived, covering main, subagent and
evaluator conversations, with activity deliberately never model-written. This spec adds
`SessionCard`: persisted, model-written, subagents excluded. Two things called "session" with
opposite properties.

**Resolve by role, not by renaming.** They are different kinds of claim and both are needed:

| | `SessionCard` (this spec) | `SessionSummary` (#217) |
|---|---|---|
| Written by | the session's own model | the harness |
| Trust | advertised, not authoritative | derived, trusted |
| Lifetime | persisted | transient |
| Covers | active conversations | main, subagent, evaluator |
| Answers | "who am I and what am I doing" | "what is actually happening right now" |

`list_sessions` therefore takes **identity from the card and liveness from the summary** (§6.1).
A peer must not be able to claim it is idle, and a model-written description is exactly the wrong
source for a field another agent will act on. Whichever lands second wires the two together; neither
needs to block on the other, because the card is inert without the tools and the summary is already
useful on its own.

**UI**: whether #217's strip shows peer arrivals is that PR's call, not this one's. Worth deciding
deliberately — a session woken by a peer is the case where a user most wants to know something
happened without being switched to it.

## 13. The larger arc

With this slice sessions can find each other and talk. Remaining, each its own spec:

- **Coordination** — handoff, negotiation, wait-for-completion. The blocking primitives, and the
  place where sessions can strand one another.
- **Main-chat orchestration** — probing and inspecting peers in depth, beyond the bare count.
- **Transport** — A2A over NATS (#194) or HTTP, if sessions ever need to span processes. The schema
  here is chosen so that becomes a transport swap rather than a redesign.
