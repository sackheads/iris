# Design: the Inbox — a decision surface for the human

Status: design, no code. From the 2026-11-07 use-case brainstorm (`docs/use_case_tuning.md`);
sibling epic #919 (the Director / ambient-awareness model) is deliberately out of scope here.

## Intent and the why

Iris runs agents — an Overseer-style squad, generic one-off conversations, and custom profiles —
and some of their work produces a decision only Brian can make. Today, when he's been away, those
decisions reach him as a terse chat residue behind diff scrollback: *"your 6 items remain
unchanged."* Getting one decision out of an agent's head and into his costs three typed rounds —
*"what are my items"* → a one-line list → *"more detail on #1"* → the page he actually needed — and
across several items it's easy to lose track of which answer settled which question.

The Overseer's **curation** is not the problem; Brian likes it and it works. The **last mile** is the
problem. The Inbox replaces that last mile: a mail-like surface where every pending decision is
already expanded and readable in one place, and answerable in place — pick an option or type a
reply — with the answer routed straight back to the agents that need it. (Prior art: the Inbox /
Director in Grain, https://github.com/ai-on-gke/grain.)

This matters for a Brian who uses Iris daily as his majordomo (the current assumption; do **not**
design for an empty app).

## Goals

- Collect every pending human-decision item in one durable, readable place, reachable in one click.
- Each item is fully self-describing: the situation, the decision, options with pros/cons, and a way
  to answer — no follow-up typing to get the detail.
- Answering in place routes the reply to the right agents without Brian composing a relay message.
- A follow-up on a decision **reopens the same item and appends**, so the earlier answer stays as
  context (email threading). This is the direct fix for "which did I say A to."
- Any agent can put an item in the inbox, not only the Overseer chain.

## Non-goals

- The Director / ambient-awareness model (Iris-on-top seeing all status, the pub/sub cap and `ack`
  changes). That is epic #919, specced separately.
- Cross-machine. The Inbox is local to one Mac, like pub/sub today.
- A general chat or messaging surface. The Inbox is for items that need a decision or an
  acknowledgement, not conversation.
- Replacing the Overseer's curation. The chain stays; the Inbox is its delivery surface.

## Anti-goals (how this fails even if it "works")

- It becomes an **uncurated firehose** — three agents' overlapping questions arrive as three items,
  or one chatty agent floods it. If that happens, we've rebuilt the terse-list problem with nicer
  fonts.
- It **taxes the pinned Iris** conversation (the second-brain-must-not-be-taxed invariant,
  `iris-two-use-cases`). The Inbox is its own surface; reading it must not re-evaluate or load Iris.
- A tainted/injected agent uses an item to **mislead Brian** into a decision.

## The model

### One item, four response shapes

An item has a single anatomy regardless of what kind of answer it wants:

- **Title** — one line.
- **Source** — who raised it and the chain it came through (e.g. `dev-2 → planner → overseer`, or a
  standalone agent's name).
- **Situation** — the full context, written once, completely.
- **The decision** — zero or more **options**, each with its own pros and cons.
- **Response area** — the only thing that varies:
  - *options + free-form:* pick one option, or answer "in your words";
  - *free-form only:* open-ended direction, no options (e.g. "what to do about Tony");
  - *timed veto:* Approve now / Veto, with a deadline; **at expiry it auto-approves the default,
    except it auto-holds (goes overdue, waits) when the emitter carries the taint marker** (decided;
    see resolutions);
  - *notification:* Dismiss / acknowledge, no decision owed.
- **Route-back footer** — which agents receive the answer, and who is merely notified.

There are no separate item *types*; the response area is a property of the item. (Mockup:
`.superpowers/brainstorm/.../inbox-layout.html`, validated with Brian.)

### Threading and lifecycle

An item is a **thread**, keyed by a stable item id. States: `open` (needs attention) → `answered`
→ may reopen. A follow-up from an agent references the item id (email's `In-Reply-To`); the inbox
**appends** it under the thread and flips the item back to `open`, surfacing it with the prior
answer still shown as context. A thread **closes** when the originating agent marks it resolved
(decision consumed, PR merged) or Brian archives it. Referencing-by-id is also the dedup mechanism:
a re-ask threads instead of spawning a twin.

### Emit is open; curation is a team convention

Any agent/session may emit an item (parity with pub/sub's open publish). Curation is **not** enforced
at the inbox — it is a convention of the team's roles: devs feed the chain, the Overseer/planner emit
the curated item. A standalone agent (a research session, a one-off profile, Iris herself) emits
directly, with route-back set to itself. This keeps the chain's value for the squad while letting
non-team agents reach Brian.

Because un-curated emitters have no chain to filter them, the inbox carries its own light
protections:

- **Per-emitter rate limit** (reuse the shape of `PeerRateLimiter`), so one agent can't flood.
- **Dedup by thread id**, as above.
- **Source shown in the list**, so Brian sees at a glance what came through a curator versus what an
  agent dropped in raw.

### Reply routing

Each item carries a **route-back set** (the agents that get the answer) and a **notify set** (cc'd
for awareness).
An emitter chooses which *chain* gets the answer, never an arbitrary session: an entry is the emitter
itself or a role (`role:<name>`, the session holding it when the answer goes out). The emit tool
refuses any other entry (a session id or name, the pinned conversation), and an answer drops one
that a stored row carries. Otherwise Brian's click, or a veto timer, would push a message into any
session the emitter named, without the peer gates (Brian, 2026-11-07: "agreed, a)"). On Submit, Brian's response — the chosen option id and/or free text — is delivered to
each route-back agent under its own label, "inbox answer", not as a peer message: it wakes an idle
agent and queues behind a busy one, expects no reply and is not declinable as a peer's request would
be (Brian's decision is user authority). Only submitting an answer in the inbox can produce that
label; no tool or peer message can. The message keeps Brian's decision (his choice by position and
plain id, and his words) apart from the original item (title, situation, options), which is the
emitter's text, echoed so a cold recipient can act, and which carries the emitter's #813 taint and
is stated not to be an instruction. The notify set gets a lighter awareness ping, once. The answer is
recorded on the thread so it survives and shows as context on any reopen.

### Trust

An item's displayed content is **agent-authored text**, shown to a human — it is never executed, and
it must not be treated as an instruction to Iris. An item from an emitter that had read outside
content carries the "(the sender had read outside content)" marker (#813), shown on the item, so a
tainted agent can't quietly dress up a misleading decision. Brian's reply is trusted human input
going back out to the agents.

## Persistence and UI

- A new **durable store** for items and their thread entries — a SQLite table + migration, in the
  style of the peer ledger / conversation store (not an ephemeral pub/sub topic; pub/sub's role here
  is at most to *notify* that an item exists). Any persisted `Codable` added for this uses
  `decodeIfPresent` (Invariant 1).
- **Entry point:** a row under the pinned **Iris** conversation in the sidebar, with an unread
  **badge count**, opening the mailbox view (list + detail). Validated in the mockup.
- Reading the Inbox must not re-evaluate the chat window or load the pinned Iris conversation
  (Invariant-style separation; cf. the streaming-read lesson in AGENTS.md).
- Optional: a macOS notification on a new or reopened item, and a visible countdown on a timed-veto
  item.

## Agent-facing surface (emit contract)

A way for an agent to create or append-to an item. Fields: `title`, `situation`, `options`
(each `{label, pros, cons}`), `response_mode`, `route_back` (`role:<name>` entries, or omitted for the emitter itself), `notify` (`role:<name>` entries), `thread_id`
(omitted = new thread; present = append), and for a veto `deadline` + `default`. A matching way to
mark a thread resolved. The emit tool's declaration must be **gated** per Invariant 6 (not broadcast
on every plain turn) and its description swept per Invariant 9; the exact gate is a builder call
(see below).

## What's left to the builder

- Whether emit is a new tool or an extension of `send_to_session`'s address space (a `to: "inbox"`
  form), and exactly when its declaration is gated on (Invariant 6).
- The per-emitter rate-limit numbers, and whether the inbox badge/notification is on by default.
- The SQLite schema specifics and migration id.
- Whether the "notify set" reuses pub/sub or is a direct lighter send.
- The timed-veto clock source: decided in Task 4 (planner, 2026-11-07). A veto deadline is a
  wall-clock schedule ("by 5pm"), which AGENTS.md gives to `Date()`, so the stored absolute deadline
  decides; a dispatch timer, a wake notification and the launch check only decide when to look
  (never `Task.sleep`).

## Calls I made (Brian to sanity-check while reading)

- The Inbox is its **own durable store**, not built on pub/sub (his doc said "publish to the inbox's
  input topic"; I read that as the notification, not the storage).
- **Emit is open to any agent**, with curation as a team convention and inbox-side anti-flood —
  reconciling "the chain has value" with "non-Overseer agents might want to publish too."
- Follow-ups **reopen and append** to the same item (his slight preference), not new linked items.
- The timed-veto expiry behaviour was left open for Brian and is resolved below (auto-approve, auto-hold when tainted).

## Builder-check resolutions (planner calls, 2026-11-07)

A reviewer-agent read the doc as a builder and found six gaps. Five have an obvious-correct answer
given the async premise and the trust model; I've settled those as planner calls. One is Brian's.

- **Replies outlive dead emitters (the load-bearing async case).** The emitters that raise most
  items — a one-off research session, a dev whose PR already merged, a finished `--run-job` — are
  usually gone by the time Brian answers hours later, and `send_to_session` delivery *fails* for an
  inactive session. So the Inbox does **not** fire-and-forget. A reply is **persisted on the thread**
  and delivery is best-effort and durable: the `route_back` set is resolved **at answer time**, a
  **role** target goes to whoever holds it now, a dead emitter (the only bare session an entry may name) falls back to its
  role/chain, and if no live recipient exists the thread stays *answered — awaiting delivery* and the
  reply is handed over when a matching session/role next appears. **A reply is never silently
  dropped.** The delivered payload **re-includes the item's situation and Brian's answer**, so a cold
  or replacement recipient can act without having seen the original (resolves reviewer gaps 1 and 6).
- **Thread ownership (trust).** `thread_id` is **namespaced to and owned by the originating
  emitter/chain**; only that chain may append-and-reopen a thread. A foreign agent cannot append to
  another's thread, so an injected agent can't reopen a decision Brian already trusts to slip in
  misleading "context," and id collisions can't corrupt dedup (reviewer gap 4; serves anti-goal #3).
- **Item lifecycle and the list.** `answered` items **stay visible** in the list (mail style) until
  Brian archives them; archived items move to an Archive view; nothing is silently deleted. An
  **open** item whose emitter is gone with no activity for N days is marked **stale** and Brian can
  archive it — that is the GC story for zombie decisions (reviewer gap 5).
- **The firehose, precisely.** The inbox-side defenses (per-emitter rate limit, dedup-by-thread,
  source label) stop **one** agent flooding — not three independent agents raising overlapping
  items. For the **team**, that collision is handled where it already is: the curation chain merges
  overlapping dev questions **before** emit (the thing we kept). For **un-curated standalone**
  emitters there is no merge; v1 **tolerates** those duplicates and shows their raw source.
  Cross-agent auto-merge of genuinely independent items is **out of scope for v1** (a later
  aggregation feature) (reviewer gap 3).
- **Emit is guard-judged.** An emit is agent text reaching a Brian-facing surface, so it is
  guard-judged like a peer-topic publish (tier-3, charged to the emitter), fail-closed, with the
  `#813` "sender had read outside content" marker shown on the item (reviewer's lower-ranked note).

### Timed-veto expiry (resolved 2026-11-07, Brian)

**Auto-approve the default at the deadline, except auto-hold when the emitter carries the taint
marker** (read outside content, #813). A clean internal decision proceeds if Brian is away; anything
an injection could have shaped never auto-approves and instead goes overdue and waits. When a
tainted item's deadline passes, the store records a `"held"` thread entry once for that ask and
notifies the emitter's own chain once (with no user-authority framing) that the default was held for
Brian's review (#1095).

When the Mac was asleep or Iris wasn't running at the deadline, an auto-approve fires on next launch
or at the wake, flagged "decided while you were away," and routes the default through the
durable-reply path above. The stored wall-clock deadline decides; it is checked at launch, on a
dispatch timer and at wake, and fires once.

**An auto-approved default is not Brian's decision.** The default is the emitter's own proposal, so
the message the route-back targets receive says that nobody answered by the deadline, that the
default the session itself proposed took effect, and that Brian did not choose it: none of the
words of a decision by Brian (`InboxAnswer.automatic`, thread author `veto-timer`). Otherwise an
agent could obtain user-authority framing for its own proposal by raising a veto and waiting. An automatic
answer also goes only to the emitter or its owner chain (its role's current holder when the emitter
is gone), never to another session the emitter named in `route_back`, and tells no `notify` target:
with no human in the loop the inbox must not become a way for an agent to send a message into a
third session without the peer gates (planner ruling, dev-2's #941 review). A veto
whose default names no option is held, not fired.

Rationale (Brian): the short-deadline "silent approval" worry is not much of a *new* risk, because an
agent is never forced to raise a decision in the first place — the veto grants a malicious agent no
capability it didn't already have. The taint-hold is cheap insurance, not a fix for a real hole.
