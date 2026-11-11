# Iris as an MCP Provider: Dev-Team Collaboration on the Agent Mesh — Design

**Status:** DRAFT for team review. This document decides nothing. It frames what we are building
— Iris as a *provider* on the agent mesh, with the dev team as the first concrete peer — how the
provider direction differs from the consumer direction we already have on the board (the homelab
A2A client), and the design points where the existing machinery does not fit the new shape
cleanly. The decisions belong to the people named under each point.

**Neighbours (normative — this doc references, it does not re-specify them):**
- `#964` — Iris MCP service + agent confinement (the service this rides on).
- `docs/specs/2026-10-10-sessions-a2a-messaging.md` — session↔session A2A: `Message`/`Part`,
  `attachments`, `iris-artifact://`, `artifact_refs`, retention, the §6 rate limit and #185
  cascade budget.
- `docs/superpowers/plans/2026-11-07-a2a-client.md` — the homelab A2A **client** (Iris as
  client to the homelab gateway), incl. Task 3 file transfer and `Principal.a2aRemote`.
- `docs/specs/2026-11-09-unified-access-boundary-design.md` — the one access boundary that
  already names `mcpGuest` and `a2aRemote` as sibling Principals.

---

## 1. What we are trying to accomplish

In agentic development, work increasingly flows **agent to agent**: a session delegates to a
specialist agent rather than absorbing that specialist's complexity itself. Iris is just another
agent on that mesh. She both **provides** services — the thing that lives on the user's Mac, with
their context, memory, local models, and GUI — and **consumes** them. Those are two directions of
traffic on one bus, not two architectures.

This is already the dominant shape elsewhere. `kube-agents` both calls MCP services from other
agents *and* exposes its own; a Claude Code, Antigravity, Gemini Enterprise, or a bespoke agent
(Spotify's `honk`/`zero`, say) can farm GKE work out to `kube-agents` and never touch cluster
management. Iris's specialty in that division of labour is the user's machine: a caller gets
Iris's local-first, native-macOS surface without having to be a Mac app. The homelab A2A client
already on the board is Iris as *consumer*. **This document is Iris as *provider*** — same bus,
same peer model, the other direction of the same relationship.

The first concrete instance, and the one that proves the surface in-house, is **the Iris dev
team**: the Claude Code sessions that build and review Iris, able to message the running app, hand
it a file, and get one back. The motivating case is debugging. The attended-GUI nights (the
composer input-refusal and dark-text bugs, #1055/#1052) burned hours because a human had to relay
every observation by hand, and the relay itself confounded the measurement (switching apps to
report a click deactivated the target window, so the next click never reached `mouseDown`). The
agent on the other side of that relay could have answered directly: "what is your composer's first
responder right now?" is a question the running Iris can answer about itself.

That is the shape of the value, and it sets the scope:

> **The target agent introspects *itself* and reports.** The caller does not reach into Iris's
> address space. It asks Iris, and Iris — which already holds its own `AppState` — answers, or
> runs a diagnostic and hands back the result.

**Explicit non-goal: a debugging/introspection port.** We are not adding a wire protocol that
exposes internal state, drives UI events, or lets a peer step the app. A real debug port is a
different-order project — a protocol, state serialization, safe event injection, keeping it
coherent while the target mutates under you — and the intelligence we need already lives in the
agent. Asking Iris to report on itself recovers most of the debugging value at a fraction of the
cost. This is a deliberate scoping decision, not a deferral.

The dev team is the first peer because it is trusted and in-house, but nothing in the surface is
dev-team-specific. Any agent that speaks MCP/A2A could, with the right grant, be a peer; the
confinement and access-boundary design is precisely what makes that safe to open past the dev team
later. In the unified access boundary's terms, such a peer is an **`mcpGuest`**: the intent is
that it reaches the inter-agent *bus*, not the underlying access. How that confinement actually
binds once a role session processes the guest's text under its own authority is itself an open
question — see design point 3.2.

## 2. Iris as a symmetric mesh peer (what carries over, what must generalize)

We already have a design on the board for Iris *consuming* mesh services (the homelab A2A client
plan). It is tempting to read the provider direction as "the same thing again," and the
message/part model and the object store genuinely are reusable. But a peer that *provides* differs
from one that *consumes* along axes that drive the design — not because provider and consumer are
separate systems (they are the same peer, and a real deployment is usually both at once), but
because traffic direction and trust context change what the machinery has to do. The table below
is those axes, with the existing homelab-consumer design in one column and the dev-team-provider
case in the other; most rows generalize beyond those two specific peers.

| Axis | Iris consuming (homelab A2A, existing) | Iris providing (dev team, this doc) |
|---|---|---|
| **Traffic direction** | Iris calls out — uploads/downloads against the peer's object store | Iris is called — it hosts the loopback MCP endpoint peers connect to |
| **Peer in the first instance** | External homelab agents (Clomp et al.) | Internal Iris dev sessions (generalizes to any granted agent) |
| **Trust basis** | Per-frame ed25519 signature (romar#396, #974 H4); relay is not an identity authority | Static Bearer token (Claude Code's MCP client; no OAuth) |
| **Interaction shape** | Task delegation — a peer delivers a `task`, gets `status-update`/`artifact-update` back | Conversational messaging — `send`/`poll` to a live session, threaded by `contextId` |
| **Delivery target** | A fresh, isolated, off-foreground `a2a-remote` session (`Principal.a2aRemote`), confined and approval-capable, without the role session's conversational context | An **existing role-holding session's inbox** (`role:reviewer`, `role:feedback`) — the live agent with its own ongoing context, but it runs under *its* binding, not a guest floor (§3.2) |
| **Object store** | Peer-hosted, `PUT`/`GET /v1/objects/{taskId}/{sha256}` | Iris-hosted — Iris serves the SHA-addressed object endpoint for the first time |
| **Principal** | `a2aRemote` | `mcpGuest` |

What is genuinely shared — and should stay shared — is the access boundary and the content
model: one `(transport, issuer, id)` → profile resolution, A2A `Message`/`Part` (`text`/`data`/
`file`), the `iris-artifact://<sha256>` content-addressed store, the SHA-verify-on-read, and the
caps. The sibling framing in the unified boundary is correct. The trap is assuming that because
the *boundary* is shared, the *delivery path* is too — see design point 3.2.

## 3. Design points (open — this is the part to rope the players in on)

Each point names the seam, the options, and who should weigh in. None is decided here. Several
points below were corrected against the specs by dev-2's pre-circulation fact-check
(2026-11-11): this doc's first draft got a number of claims about the existing machinery wrong
from partial reads, and those corrections — with spec citations — are folded in.

### 3.1 How a guest addresses and reads an artifact

*Scope segment.* The homelab object path is `PUT /v1/objects/{taskId}/{sha256}`. The plan gives
only the PUT path and is silent on the GET-side ACL, so "the `{taskId}` segment is what scopes
access" is this doc's inference, not the plan's text. The messaging lane has no `taskId` — it
threads by `contextId`, artifacts keyed `(sha256, conversationId, msgId)` in `artifact_refs`.

*The read ACL is a conversation row, and a guest is not a conversation.* Messaging §7.6 B: only a
conversation holding an `artifact_refs` row may read an artifact, and "a forwarded message that
carries a hash grants nothing" — the hash is deliberately not a capability. A guest has no
conversation row, so any guest read needs a guest-shaped `artifact_refs` row (or equivalent ACL);
a hash-only HTTP endpoint would break §7.6 B outright.

*Options:* (a) generalize the object path's scope segment to a transport-neutral `{scopeId}`
(taskId in the task lane, a guest row in the messaging lane) with the read ACL gated on the guest
holding the matching row; (b) **add no second HTTP surface at all** — serve `iris-artifact://`
as an MCP `resources/read` over the already-authenticated loopback channel, same row-based ACL
(dev-2's M4). Note #964 today specifies *no* file transfer, and the messaging spec says artifacts
never cross the network in v1, so any object surface is net-new regardless; (c) messaging
artifacts stay in-store only — guests get data parts and small inline files, not large blobs.

*Weigh in:* whoever owns the a2a-client object store and `artifact_refs`, plus #964.

### 3.2 The delivery path — and which authority the receiving turn runs under

`a2aRemote` delivers a task into a fresh, isolated, off-foreground session (confined, three-tier
path/tool policy, approval-capable — it is *not* stateless; it reads files under auto-allowed
dirs, with `session_search` and raw `fact_store` hard-blocked). The dev-team value differs in
kind: ask a *real* role-holding session about *itself* — the live conversational context the
isolated lane does not carry. #964 routes guests to an existing role session's inbox, not the
`a2a-remote` task runner.

But inbox delivery opens a deeper seam (dev-2's M1): **the guest's text is then processed by the
role session, under *that session's* binding — not an `mcpGuest` floor.** So §1's phrasing "what a
guest can do is a profile ∩ the `mcpGuest` floor" is not true for the delivery path #964 wants;
confinement there comes from the receiving profile, #818 taint, and the sandbox pin (#964's
layers), not a floor on the guest. The unified boundary's own confused-deputy rule is that a
profile is a property of the *initiating* authority — which the inbox path inverts. And the
boundary §1 says `a2aRemote`/`mcpGuest` "never run in the foreground, always hard-strip, run in an
isolated lane, execute only in the sandbox," which a standing role session does not satisfy. These
must be reconciled before 3.2 is settled.

*To settle:* name the Principal and binding the receiving turn runs under when a guest message
lands in a role session's inbox, and reconcile it with the boundary's foreground/isolation floor.
Pin `mcpGuest` → inbox delivery vs `a2aRemote` → isolated runner as distinct paths.

*Weigh in:* #964 owner, the unified-boundary author, security review.

### 3.3 Auth strength, token lifetime, and the first grant

`a2aRemote` is per-frame ed25519-signed; compromise the setup and you still need the key to forge
each frame. `mcpGuest` is a static Bearer token — leak it once and you are that guest until the
token dies. The floor must encode the weaker identity. Two distinct lifetimes are in play and the
doc must not conflate them: the **token lifetime** (how long a bearer credential is valid — new
here) and #964's **request TTL / last-poll expiry** (which closes outstanding `expects_reply`
requests — not a token lifetime). Per the unified boundary R5, guest-auth itself is #965's design,
and the first grant of a new peer's profile and key is Inbox-gated.

*To settle:* the token lifetime and revoke/rotate path (per-token vs per-session); confirmation
that nothing a guest profile reaches leans on signed-frame provenance. Defer the guest-auth
mechanism to #965.

*Weigh in:* #965/#964 owners, the unified-boundary author, security review.

### 3.4 Provenance granularity

#964 already requires stamping each message's origin as Iris-native vs guest and forbids
guest→guest, so the principle is not new. The open delta is granularity and reach: a finer issuer
stamp (`mcpGuest:<tokenid>` / `a2aRemote:<peerid>` / `local`), and whether it also lands on
`artifact_refs`, so a guest-origin blob forwarded onward can't later read as Iris-origin.

*Weigh in:* whoever owns `artifact_refs`/retention, security review.

### 3.5 A guest's rate and turn budget

This doc first claimed a "new-`contextId` resets cascade depth" escape; that is wrong (dev-2).
Messaging §6: depth follows causation, *not* `contextId`, and the new-thread escape belongs to the
per-thread design the spec rejected — there is no `contextId` reset today. #185's global budget
has been *replaced* by two limits; `maxSessionCascade` is the hop-depth limit.

The real guest gap: both the hop-depth counter and the token bucket are keyed by a **session
UUID** (`peerDepth(for: sender)`, `peerRateLimiter.take(for: sender)`, capacity 20, one send /
15 s). A guest has no conversation, so a guest send bypasses both unless a per-guest budget is
built. #964 already lists "a per-guest rate/turn budget + a harness stop condition" as required
even for the plain increment, so the principle is settled; what is open is the **values** and the
**key** (per token, not per session UUID). *Also (dev-2's M6):* the depth counter is in-memory and
cleared on restart, so a guest that can restart the app resets it; and `notePeerArrival` needs a
defined depth value for a guest-origin message, which the spec does not give.

*Weigh in:* whoever owns the §6 limiter and `maxSessionCascade`.

### 3.6 Which lane's caps a guest inherits

The lanes cap files differently (dev-2's M5): the task lane is 128 KiB inline, else upload; the
messaging lane never inlines and caps at 50 MB/file, 200 MB/session/day, 2 GB total. A guest over
MCP is neither lane by default. Say which caps apply — and, since the guest token is the unit,
whether the per-session/day budgets re-key per token.

*Weigh in:* whoever owns `ArtifactLimits`, #964.

### 3.7 The motivating case needs a self-report tool — a small introspection surface (Brian's call)

dev-2's M2, and the one point that touches the stated non-goal directly. "What is your composer's
first responder right now?" has **no tool behind it today**: nothing in the surface reads AppKit/UI
or live `AppState`, and `describe_session` returns session-card data, not that. Answering it needs
a new, narrow, main-actor diagnostic tool, gated per Invariant 6 and guest-reachable. That is a
*small introspection surface* — in tension with this doc's own "no debugging/introspection port"
non-goal. The tension is real and it is a scoping decision, not an implementation detail: the line
between "the agent reports on itself" and "a narrow introspection port" sits exactly here. The
natural target is also not the `reviewer` profile, whose tool list #964 deliberately narrows.

*To settle (Brian):* whether the self-report value justifies a narrow, read-only, explicitly
bounded diagnostic tool, and if so where its line sits relative to the non-goal.

*Weigh in:* Brian (scope), then #964 + security review for the tool's shape.

## 4. What is already solid (leave alone unless a point above forces it)

- The `contextId` / `inReplyTo` "delivered-to-you" ACL for messaging, and the §7.6 B rule that a
  bare hash grants no read.
- The §6 token bucket (capacity 20, one send / 15 s) and the hop-depth limit (`maxSessionCascade`)
  as the *starting* budget — §3.5 re-keys them per guest token, it does not replace them.
- SHA-verify-on-read for objects.
- The launch + daily retention sweep — it already gives Iris-as-server most of its GC. **One
  gap (confirmed by dev-2):** guest-ingested objects must write `artifact_refs` rows, or the sweep
  (which is driven by that table) never sees them and they leak.

## 5. What this doc is not, and the next step

This is not a plan and not a design of record. It is the framing for a design conversation that
pulls in the dev team, the Iris reviewers, and the overseer. The seven points were hardened by a
pre-circulation fact-check (dev-2, 2026-11-11) against the actual specs before this reached wider
review. The intended path: circulate → reconcile the points → fold the decisions into #964 as the
"generalizing the A2A file/delivery path to `mcpGuest`" section, and raise plan work only after
#964 absorbs them. No new build begins before that.

One point is Brian's before the rest can proceed: §3.7 (does the motivating self-report case
justify a narrow introspection tool, given the stated non-goal). It sits on the scope line he
drew, so it is surfaced to him directly rather than left to the group.
