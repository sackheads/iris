# Exposing Iris to the Iris Dev Team over MCP — Collaboration Design

**Status:** DRAFT for team review. This document decides nothing. It frames what we are
building, how it differs from the homelab A2A client we already have on the board, and the
design points where the existing machinery does not fit the new shape cleanly. The decisions
belong to the people named under each point.

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

Expose a running Iris to the Iris dev team (the Claude Code sessions that build and review
Iris) as a first-class collaborator: **messaging, file exchange, and collaboration as agents.**
A dev session should be able to ask the running app a question and get an answer, hand it a
file, and receive one back — over the same inter-agent bus Iris already speaks.

The motivating case is debugging. The attended-GUI debugging sessions (the composer
input-refusal and dark-text nights, #1055/#1052) burned hours because a human had to relay every
observation by hand, and the relay itself confounded the measurement (switching apps to report a
click deactivated the target window, so the next click never reached `mouseDown`). The agent on
the other side of that relay could have answered directly: "what is your composer's first
responder right now?" is a question the running Iris can answer about itself.

That is the shape of the value, and it is worth stating precisely because it sets the scope:

> **The target agent introspects *itself* and reports.** The dev does not reach into Iris's
> address space. It asks Iris, and Iris — which already holds its own `AppState` — answers, or
> runs a diagnostic and hands back the result.

**Explicit non-goal: a debugging/introspection port.** We are not adding a wire protocol that
exposes internal state, drives UI events, or lets a peer step the app. A real debug port is a
different-order project — a protocol, state serialization, safe event injection, keeping it
coherent while the target mutates under you — and the intelligence we need already lives in the
agent. Asking Iris to report on itself recovers most of the debugging value at a fraction of the
cost. This is a deliberate scoping decision, not a deferral.

In the unified access boundary's terms, a dev session is an **`mcpGuest`**: it reaches the
inter-agent *bus*, not the underlying access. What it can see and do is a profile intersected
with the `mcpGuest` floor, exactly as any guest.

## 2. How this differs from "Iris as homelab guest client"

We already have a design on the board for Iris talking to the homelab mesh (the A2A client
plan). It is tempting to read this work as "the same thing again," and the message/part model
and the object store genuinely are reusable. But the two deployments are mirror images along
almost every axis, and the differences are exactly where reuse needs generalizing.

| Axis | Homelab A2A client (existing) | Dev-team MCP (this doc) |
|---|---|---|
| **Iris's role** | **Client** — calls the homelab gateway, uploads/downloads against *its* object store | **Server** — hosts the loopback MCP endpoint; guests connect to *it* |
| **Who is exposed** | External homelab peers (Clomp et al.) | Internal Iris dev sessions |
| **Trust basis** | Per-frame ed25519 signature (romar#396, #974 H4); relay is not an identity authority | Static Bearer token (Claude Code's MCP client; no OAuth) |
| **Interaction shape** | Task delegation — a peer delivers a `task`, gets `status-update`/`artifact-update` back | Conversational messaging — `send`/`poll` to a live session, threaded by `contextId` |
| **Delivery target** | A fresh **isolated, confined** `a2a-remote` session (`Principal.a2aRemote`), off the foreground, that sees no live state | An **existing role-holding session's inbox** (`role:reviewer`, `role:feedback`) — the live agent, which *can* see its own state |
| **Object store** | Gateway-hosted, `PUT`/`GET /v1/objects/{taskId}/{sha256}` | Iris-hosted — Iris serves the SHA-addressed object endpoint for the first time |
| **Principal** | `a2aRemote` | `mcpGuest` |

What is genuinely shared — and should stay shared — is the access boundary and the content
model: one `(transport, issuer, id)` → profile resolution, A2A `Message`/`Part` (`text`/`data`/
`file`), the `iris-artifact://<sha256>` content-addressed store, the SHA-verify-on-read, and the
caps. The sibling framing in the unified boundary is correct. The trap is assuming that because
the *boundary* is shared, the *delivery path* is too — see design point 2.

## 3. Design points (open — this is the part to rope the players in on)

Each point names the seam, the options, and who should weigh in. None is decided here.

### 3.1 The object endpoint's scope segment (`{taskId}` vs `{contextId}`)

The homelab object path is `/v1/objects/{taskId}/{sha256}`; the `{taskId}` segment is what scopes
access. The dev-team path is messaging: threaded by `contextId`, artifacts keyed
`(conversationId, msgId)` in `artifact_refs`, with no `taskId` anywhere. "Reuse the exact
mechanism" collides at precisely the segment that does the scoping.

*Options to weigh:* (a) generalize the path's scope segment to a transport-neutral `{scopeId}`
— `taskId` in the task lane, `contextId` in the messaging lane — with the fetch ACL defined as
"is the caller a party to `{scopeId}`"; (b) keep two endpoints; (c) messaging artifacts stay
purely `iris-artifact://sha256` in-store with the `(conversationId, msgId)` ACL, and the HTTP
object endpoint is task-lane-only. Option (a) is the one generalization that makes one mechanism
serve both.

*Weigh in:* whoever owns the a2a-client object-store work, plus #964.

### 3.2 Delivery semantics: inbox vs isolated task runner

`a2aRemote` delivers a task into a fresh **isolated, confined** session that cannot see any live
state — correct for an untrusted external peer running arbitrary work. The dev-team value is the
opposite: ask a *real* role-holding session about *itself* and get a live answer. That only works
if guest messages deliver to an existing session's inbox (which #964 does), **not** the
`a2a-remote` task runner.

The risk is silent: because `mcpGuest` and `a2aRemote` are boundary siblings, an implementer who
reuses the `a2a-remote` task runner for guests would deliver dev messages into throwaway sessions
and the collaboration would evaporate with no error — the guest gets an answer, it is just an
answer from an Iris that knows nothing. The two Principals should share the boundary and the
caps; they should not share the delivery path.

*To settle:* a line in #964 (and/or the unified boundary) pinning `mcpGuest` → session-inbox
delivery, `a2aRemote` → isolated task runner, as distinct paths over one boundary.

*Weigh in:* #964 owner, whoever builds `Principal.a2aRemote`, the unified-boundary author.

### 3.3 Auth strength asymmetry, and what the `mcpGuest` floor may assume

`a2aRemote` is per-frame ed25519-signed: compromise the setup and you still need the key to forge
each frame. `mcpGuest` is a static Bearer token: leak it once and you are that guest forever, on
every message. These are different strengths of identity, and the floor has to encode the weaker
one.

*To settle:* the `mcpGuest` floor is explicitly the weaker-identity floor — short guest TTL,
cheap revoke/rotate, and nothing a guest profile can reach may lean on signed-frame provenance.
Open question: how short is the TTL, and what is the revoke path (per-token, per-session)?

*Weigh in:* the unified-boundary author, #964, security review.

### 3.4 Provenance across the bus

`artifact_refs` records the *sending session* and `(conversationId, msgId)`, not the issuing
transport and identity. A guest-origin blob delivered to a role session and later forwarded —
onward to homelab, or into a trusted local context — can read as Iris-origin. The bus should
make origin un-spoofable downstream.

*Options:* stamp messages and artifacts with issuer transport+id (`mcpGuest:<tokenid>` /
`a2aRemote:<peerid>` / `local`), carried in provenance so a later consumer cannot mistake a guest
blob for a trusted one. Where the stamp lives (part metadata, `artifact_refs`, both) is open.

*Weigh in:* whoever owns `artifact_refs`/retention, security review.

### 3.5 The cascade-depth reset escape, now externally reachable

The session-A2A spec notes (§6) that cascade depth follows causation, and "a loop could escape the
limit by starting a new `contextId`." Internally that is a soft spot; handed to an external dev
token it is a denial-of-service / amplification lever.

*Options:* guest principals get a per-token turn/token budget per time window that does **not**
reset on a new thread, layered on top of the existing §6 rate limit and #185 cascade cap.
Open: the budget values, and whether this is a guest-only rule or tightens the general case.

*Weigh in:* whoever owns the §6 rate limit and the #185 cascade budget.

## 4. What is already solid (leave alone unless a point above forces it)

- The `contextId` / `inReplyTo` "delivered-to-you" ACL for messaging.
- The §6 rate limit and #185 cascade cap as the *starting* budget (3.5 tightens, does not
  replace).
- SHA-verify-on-read for objects.
- The launch + daily retention sweep — it already gives Iris-as-server most of its GC. **One
  gap:** guest-ingested objects must write `artifact_refs` rows, or the sweep (which is driven by
  that table) never sees them and they leak.

## 5. What this doc is not, and the next step

This is not a plan and not a design of record. It is the framing for a design conversation that
pulls in the dev team, the Iris reviewers, and the overseer. The intended path: circulate →
reconcile the five points → fold the decisions into #964 as the "generalizing the A2A
file/delivery path to `mcpGuest`" section, and raise plan work only after #964 absorbs them. No
new build begins before that.
