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
management. Iris's specialty in that division of labour is not just the user's machine but the
*human attached to it*: a caller reaches her local-first, native-macOS surface — and, through her,
approvals, the Inbox, and attended GUI — without being a Mac app or having that human (Iris's
framing). That reach is also the main risk: a guest-triggered turn can queue questions for the
user (`inbox_item`), so guest turns need their own attention budget or the dev team can exhaust
the user's attention by accident (§3.5). The homelab A2A client already on the board is Iris as
*consumer*. **This document is Iris as *provider*** — same bus, same peer model, the other
direction of the same relationship.

The first concrete instance, and the one that proves the surface in-house, is **the Iris dev
team**: the Claude Code sessions that build and review Iris, able to message the running app, hand
it a file, and get one back. The motivating case is debugging. The attended-GUI nights (the
composer input-refusal and dark-text bugs, #1055/#1052) burned hours because a human had to relay
every observation by hand, and the relay itself confounded the measurement (switching apps to
report a click deactivated the target window, so the next click never reached `mouseDown`). The
agent on the other side of that relay could have answered directly: "what is your composer's first
responder right now?" is a question the running Iris can answer about itself.

That is the shape of the value, but it splits across **two levels this doc keeps apart** (Iris's
framing — conflating them is what hid half the open questions):

> **The app** — its `AppState`, composer, first responder, windows — is what a *deterministic
> self-report* reads (§3.7). **A role session** — its conversational context and profile — is what
> a *conversation* reaches (messaging, files, qualitative questions; §3.2). Different providers,
> different trust stories.

The caller does not reach into Iris's address space either way. For a qualitative question it asks
a session and the session answers. For a *measurement* — "what is the composer's first responder,
and why is it disabled?" — it reads the app directly, **without starting a turn**, because starting
one changes the very state being measured (the #1055 confound again) and puts a model that can
misreport between the caller and the value (§3.7).

**Non-goal: a general-purpose debugging/introspection port.** We are not adding a wire protocol
that lets a peer drive UI events, step the app, or inspect arbitrary internal state. A real debug
port is a different-order project — a protocol, state serialization, safe event injection, keeping
it coherent while the target mutates under you — and the intelligence we need already lives in the
agent. Asking Iris to report on itself recovers most of the debugging value at a fraction of the
cost. This is a deliberate scoping decision, not a deferral.

**One accommodated exception (Brian, §3.7).** A *narrow, read-only self-report door* — a bounded,
**app-level** diagnostic read answering specific enumerated questions about the app's own state —
is a special case this environment accommodates. It is not the general port the non-goal rules
out: it drives nothing, runs no model, and exposes a defined surface, not arbitrary state. §3.7
holds its shape.

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

What *should* be shared — as design intent, not as existing code — is the access boundary and the
content model: one `(transport, issuer, id)` → profile resolution, A2A `Message`/`Part`
(`text`/`data`/`file`), the `iris-artifact://<sha256>` content-addressed store, the
SHA-verify-on-read, and the caps. Say "intent" literally: **none of the boundary is built yet.**
`Principal` on main is `main | subagent | evaluator` (`SandboxPolicy.swift:10`); `mcpGuest` and
`a2aRemote` live only in the boundary spec, and every guest floor this doc leans on is unbuilt
(Iris's check). The sibling framing is the right target; it is not a thing to reuse today. The
trap is assuming that because the *boundary* is shared in the spec, the *delivery path* is settled
— see design point 3.2.

## 3. Design points (open — this is the part to rope the players in on)

Each point names the seam, the options, and who should weigh in. None is decided here. Several
points were corrected and reshaped by two pre-circulation reviews (2026-11-11): dev-2's fact-check
and Iris's own code-grounded review (checked against `origin/main` 6d957a74). The first draft got
a number of claims about the existing machinery wrong from partial reads; those corrections — with
code/spec citations — are folded in. Iris reshaped four of these: the app-vs-session split (§1),
the app-level self-report tool (§3.7), turn-scoped authority (§3.2), and two seams nobody else
caught — the steer path (§3.2) and the reply direction (§3.8).

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

*Front-runner (Iris):* option (b). `resources/read` over the already-authenticated channel is the
only option that adds no second network surface; pick it unless someone shows a blob size MCP
can't carry.

*Weigh in:* whoever owns the a2a-client object store and `artifact_refs`, plus #964.

### 3.2 The delivery path — and which authority the receiving turn runs under

`a2aRemote` delivers a task into a fresh, isolated, off-foreground session (confined, three-tier
path/tool policy, approval-capable — it is *not* stateless; it reads files under auto-allowed
dirs, with `session_search` and raw `fact_store` hard-blocked). The dev-team value differs in
kind: ask a *real* role-holding session about *itself* — the live conversational context the
isolated lane does not carry. #964 routes guests to an existing role session's inbox, not the
`a2a-remote` task runner.

But inbox delivery opens a deeper seam (dev-2's M1, sharpened by Iris): **the guest's text is then
processed by the role session, under *that session's* binding — not an `mcpGuest` floor.** That is
a plain confused deputy, and the "confinement comes from the receiving profile, #818 taint, and the
sandbox pin" story does not hold up in the code (Iris's check):
- **Taint is noise right now.** #1026 sets it on nearly every session before any untrusted input
  arrives, so it cannot distinguish a guest-tainted turn.
- **The sandbox pin is not a floor.** `SandboxPolicy.resolve` returns `.host` for every principal
  the moment the master switch is off (`SandboxPolicy.swift:50`), verified. A guest-triggered turn
  in a `main` session with sandboxing off runs host commands that inherit the process env.

*Position to weigh (Iris):* **authority belongs to the turn, not the session.** A turn started by a
guest message runs under (receiving profile ∩ `mcpGuest` floor), with the sandbox **enforced**, not
merely preferred; the session keeps its conversational context but does not lend its full
authority.

**The steer path — a hard requirement for the designed path (Iris; verified).** When the target is
mid-turn, a peer arrival is queued (`queuePeerArrival`, `iris.swift:1000`) and can be drained into
the *running* turn as a steer (`iris.swift:798/891/1006`). The queued text keeps its own peer label
(`peerMidTaskLabel` = "Peer message (mid-task)", `iris.swift:2431`), **not** the user's
`User (mid-task):` trust label — so it does not impersonate the user. The hazard is narrower and
real: a turn-scoped principal cannot apply to text injected into a turn already running, so the
steer executes inside a turn the user started under `main` and runs under the **user's
permissions** — which for a guest-origin message would be a privilege escalation. No guest path
exists today, so this is a requirement for the path being designed, not a live hole. **Guest
arrivals must never steer:** they wait for the current turn to end and start their own
guest-principal turn. Not a trade-off — a line the build must hold.

*To settle:* confirm turn-scoped authority with an enforced sandbox for guest-started turns, and the
never-steer rule, and reconcile both with the boundary's foreground/isolation floor. Pin `mcpGuest`
→ inbox delivery vs `a2aRemote` → isolated runner as distinct paths.

*Weigh in:* #964 owner, the unified-boundary author, security review.

### 3.3 Auth strength, token lifetime, and the first grant

`a2aRemote` is per-frame ed25519-signed; compromise the setup and you still need the key to forge
each frame. `mcpGuest` is a static Bearer token — leak it once and you are that guest until the
token dies. The floor must encode the weaker identity. Two distinct lifetimes are in play and the
doc must not conflate them: the **token lifetime** (how long a bearer credential is valid — new
here) and #964's **request TTL / last-poll expiry** (which closes outstanding `expects_reply`
requests — not a token lifetime). Per the unified boundary R5, guest-auth itself is #965's design,
and the first grant of a new peer's profile and key is Inbox-gated.

**The bearer token is really a local-process identity (Iris).** A static token for a loopback
endpoint lives in plaintext in Claude Code's config, so the identity it proves is not "the dev
team" — it is "any process running as the user that can read that file," which includes Iris's own
host `run_command`. Iris could connect to her own MCP endpoint as a guest, and #964's guest→guest
ban does not catch Iris→loopback→Iris. Either bind the token to something a process can't simply
read, or state explicitly that this identity means "any local process" and set the `mcpGuest` floor
to match.

*To settle:* the token lifetime and revoke/rotate path (per-token vs per-session); what the bearer
identity actually denotes (and the floor that follows); confirmation that nothing a guest profile
reaches leans on signed-frame provenance. Defer the guest-auth mechanism to #965.

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
**key** (per token, not per session UUID). Refinements (Iris): a guest-origin message should start
at **depth ≥ 1**, not 0 — otherwise a guest gets a full cascade budget it never paid for; and
`notePeerArrival` needs a defined depth value for a guest-origin message, which the spec does not
give. The "a guest restarts the app and resets the in-memory depth counter" concern only bites if a
guest *has* a restart path — so call that out as a thing to deny, rather than designing the budget
around it.

**And the attention budget (Iris, from §1).** The richest thing a guest turn can do is not compute
— it is reach the user: a guest-triggered turn can call `inbox_item` and queue questions for the
person. Guest turns need an attention budget distinct from the compute budget, or the dev team can
exhaust the user's attention by accident.

*Weigh in:* whoever owns the §6 limiter, `maxSessionCascade`, and the Inbox.

### 3.6 Which lane's caps a guest inherits

The lanes cap files differently (dev-2's M5): the task lane is 128 KiB inline, else upload; the
messaging lane never inlines and caps at 50 MB/file, 200 MB/session/day, 2 GB total. A guest over
MCP is neither lane by default. Say which caps apply — and, since the guest token is the unit,
whether the per-session/day budgets re-key per token.

*Weigh in:* whoever owns `ArtifactLimits`, #964.

### 3.7 The self-report door — scope settled, shape open

dev-2's M2. "What is your composer's first responder right now?" has **no tool behind it today**:
nothing in the surface reads AppKit/UI or live `AppState`, and `describe_session` returns
session-card data, not that. Answering it needs a new, narrow, main-actor diagnostic tool, gated
per Invariant 6 and guest-reachable.

**Brian's call (settled, 2026-11-11):** a literal self-report / debug door is a special case this
environment accommodates — "unique to this environment." It is not the general debug port the §1
non-goal rules out (which drives events and inspects arbitrary state); this door is read-only and
bounded. So the *scope question is closed yes*; what remains open is the tool's shape.

**Iris's shape proposal — the door is an app-level MCP tool, not an agent tool.** Routing the read
through "ask Iris, Iris answers" puts an LLM turn between the caller and the measurement, which is
wrong twice over:
1. *It reintroduces the #1055 confound.* Starting a turn changes the state being measured —
   turn-in-flight, composer gating, possibly focus and the spinner. The input-refusal bug is
   exactly the class where "a turn is running" changes the answer.
2. *It inserts a model where you want a deterministic reading.* An LLM can misreport a value; a tool
   returning raw values cannot.

So the door is called directly behind the same bearer token — **no session, no turn, no profile**
(which also answers "which profile carries it": none). Shape:
- **Fixed, enumerated queries.** Key/main window; first responder class and identity; composer
  enabled state and *why*; turn-in-flight per session; app activation state. No transcript text, no
  memory, no file contents.
- **A passive event ring buffer.** The #1055 relay problem was about *events* (did `mouseDown`
  arrive, and on what), not a snapshot — a point-in-time read can't say why a click didn't land. A
  bounded ring of recent window/focus/event-routing transitions can.
- **A main-actor timeout.** The read hops to the MainActor; if the main thread is wedged — a bug
  class you'd use this for — the tool must time out and return "main actor unresponsive for N ms,"
  which is itself the diagnosis.

"Ask a role session about itself" still exists for *qualitative* questions; it just is not the
debugging path.

*Weigh in:* #964 + security review for the tool's surface and bound; main-actor review for the read.

### 3.8 The reply direction (Iris — a whole axis the other points miss)

Every point above is about what a guest can make Iris *do*. None covers what Iris *sends back*. A
role session holds memory, facts, and user context, and its reply to a guest is **outbound data** —
the same category as `gmail_send_email`. With the trusted in-house dev team that is harmless. But
this doc's own claim is that "nothing in the surface is dev-team-specific" and the floor must hold
for any granted peer — so a reply to a guest needs the same taint / outbound-egress gating as other
egress, or the "any granted agent" generalization leaks the user's context outward.

*To settle:* whether guest replies route through the egress/taint gate, and what a guest-reachable
reply may carry.

*Weigh in:* whoever owns egress/taint gating, security review.

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
pulls in the dev team, the Iris reviewers, and the overseer. Its nine points were hardened before
wider review by two pre-circulation passes (2026-11-11): dev-2's fact-check against the specs, and
Iris's own code-grounded review (which added the app-vs-session split, the app-level self-report
tool, turn-scoped authority, and the steer-path and reply-direction seams). The intended path:
circulate → reconcile the points → fold the decisions into #964 as the "generalizing the A2A
file/delivery path to `mcpGuest`" section, and raise plan work only after #964 absorbs them. No new
build begins before that.

Two things are not "open" in the same way as the rest. **§3.7's scope** is settled (Brian): a
narrow, read-only, app-level self-report door is accommodated; only its shape stays open. **The
never-steer rule in §3.2** is a hard security line, not a trade-off: guest arrivals must never be
consumed as a steer into a turn running under the user's permissions. (No guest path exists today —
it is a requirement for the path being designed, not a live hole.) Everything else is the group's
to reconcile.
