# Sessions: Identity, Discovery, and One Message (slice 1 of #185) — Design

**Status:** approved, not yet implemented
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
scratch, deleted when their run ends, and already filtered out of persistence.

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

Ordering is most-recently-active first, so the truncated tail is the least likely to matter. A
session that needs the full set can narrow by workspace, which is the gate the card exists to
provide.

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

### 5.2 Self-sends are refused

A session messaging itself is an immediate loop. Refused outright, before the cascade accounting in
§7 is even consulted.

## 6. Cost: the tools appear only when there is someone to talk to

`list_sessions`, `send_to_session`, and `set_session_card` are declared **only when at least one
other active session exists.**

This gate is only meaningful because the peer set is bounded (§3). If archived conversations
counted, it would be true from the first day a user archived anything and never false again.

With a single conversation open — the common case — the tool surface is byte-identical to today.
#133 brought a plain turn from 30 declarations to 8 (~837 tokens); adding three unconditional
declarations would put a meaningful fraction of that back on every call and invite the unprompted
probing that #132 and #144 were about. This is AGENTS.md **invariant 6**'s lifecycle-state pattern,
the same shape the goal and ladder tools already use.

**Standing context is one line**: a bare count — `3 other sessions are active` — present only when
peers exist. Enough for the model to consider delegating; no roster, no per-peer detail, nothing
that grows with session count or churns every turn as peers update their cards. The issue's
"not to a great level of detail, poisoning context" is the requirement, and detail is available on
demand through `list_sessions`.

## 7. The cascade cap

Wake-on-delivery means one session can make another spend tokens with no human involved. Left
unbounded that is a cascade: A messages B, B messages C and D, each of those messages more.

**A depth limit alone does not cap this.** With fan-out F and depth N it still permits F^N turns.
The budget must be shared by the whole cascade, not carried per branch.

`AppState` holds, per conversation, `(cascadeId: UUID, remaining: Int)`:

- **A user-initiated turn clears the entry.** User input always begins a fresh cascade — a person
  typing is not part of the machine's budget.
- **A peer delivery into X sets X's entry** to the sender's `cascadeId` with `remaining - 1`.
- **`send_to_session` reads the sender's entry** and refuses at zero, otherwise delivers with the
  decremented value.

Because the allowance travels with the cascade rather than the branch, A→B, C, D consumes three of
the same budget. Total peer-woken turns descending from one user action is capped at N for any
shape — depth, fan-out, or any mix.

**A human typing into a woken session ends that session's cascade.** The rule in the first bullet
is stated per conversation, so if the user opens a session that a peer woke and sends a message,
that conversation's entry clears and its onward sends start fresh. That is the intended reading: a
person has entered the loop, and the budget exists to bound *unattended* machine chatter, not to
ration a conversation the user is actively steering. Sibling branches of the original cascade keep
their own remaining allowance.

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

## 10. Testing

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
- A user-initiated turn resets the budget.
- The three tools are absent with one conversation open and present with two — asserted on the
  declaration list, since this is what protects #133's win.
- `list_sessions` truncates at the cap and reports the true total, so a large peer set cannot
  silently become a large context payload.
- The standing count line appears only when peers exist.

## 11. The larger arc

With this slice sessions can find each other and talk. Remaining, each its own spec:

- **Coordination** — handoff, negotiation, wait-for-completion. The blocking primitives, and the
  place where sessions can strand one another.
- **Main-chat orchestration** — probing and inspecting peers in depth, beyond the bare count.
- **Transport** — A2A over NATS (#194) or HTTP, if sessions ever need to span processes. The schema
  here is chosen so that becomes a transport swap rather than a redesign.
