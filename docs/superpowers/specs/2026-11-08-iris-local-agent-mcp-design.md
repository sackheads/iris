---
type: design
title: Iris local agent interface — A2A-over-MCP debug channel
status: draft (for builder-check, then owner review)
timestamp: 2026-11-08
---

# Iris local agent interface: a loopback A2A-over-MCP channel

## Intent and why

The Iris↔planner feedback loop has high value: a running Iris instance (the owner's real,
daily-driver app) surfaces grounded observations from live use, and a Claude Code "planner"
session triages them — verifies against the code, files issues, routes work to the dev team,
and brings decisions back to the owner. Today the **owner is the manual relay**: he copies
Iris's observations into the planner and the planner's questions back into Iris. That
cut-and-paste middleman step is the bottleneck.

The owner's standing goal (the year's theme — culminating in the Overseer) is to get himself
**out of the critical path without giving up oversight**. He still wants summaries, updates,
approvals, and a say in decisions — he just doesn't want to be the socket. So: let Iris and the
planner transact directly, while the owner stays the approver via the mechanisms that already
exist (the Overseer's summaries, and approval gates on consequential actions).

## Direction (decided)

**Iris exposes a loopback MCP server that fronts its own local agent↔agent fabric; an external
Claude Code session connects as an MCP client and appears to Iris as a guest peer.** Off by
default; opt-in via a debug toggle.

- **Transport:** a token-gated MCP server bound to `127.0.0.1:<port>` (Streamable HTTP + SSE).
  Claude Code's side is a config URL. Loopback only; the MCP SDK's server transport already does
  localhost-origin validation.
- **Tool surface (A2A-over-MCP), inspired by gke-labs/kube-agents `a2a/mcpbridge` (Apache-2.0,
  inspiration not a port):** a small toolset fronting A2A semantics — `send` (to a session/role),
  `poll` (a pull mailbox for "messages to me since X"), `discover`/`status` (who is addressable),
  and a session-identity/alias tool. SSE carries server→client push so it is not pure polling.
- **The external agent is a guest peer:** a synthetic session identity/card in `SessionDirectory`,
  with **no harness-observed liveness** (a non-Iris process has no turn engine, so Iris cannot
  verify it the way it verifies its own sessions). That is correct: the planner-peer is
  intrinsically low-trust.
- **Off by default, behind a debug toggle in the configuration pane** (the same pane #931's a2a
  config lives in). It only binds the port when enabled. **The default attack surface is
  unchanged** — this is for the subset of people doing agent-loop work (initially: the owner).

### One agent-interface, two transports
Iris's local session fabric is already A2A-shaped (its `AgentCard`s). This local
**A2A-over-MCP** channel and #931's remote **A2A-over-gateway** client are the same conceptual
model over two transports/trust-models. They can share the A2A envelope types. #931 stays parked;
this is its local sibling, not a replacement.

## What this reuses (the owner's "don't bend over backwards" test)

- **MCP protocol: free.** The MCP Swift SDK Iris already vendors ships the whole server side —
  `Server` actor, `tools/list`/`tools/call`, stdio + HTTP/SSE server transports. Zero protocol
  code. (`MCPManager` itself is client-only and not reused; the SDK beneath it is.)
- **Loopback listener precedent:** `OAuthManager` already runs a localhost `NWListener` + raw HTTP.
- **Send path:** `send` maps onto `AppState.decidePeerSend` → `IrisEngine.deliverPeerMessage` →
  `PeerLedger` — the existing peer-message plumbing, correlation and persistence.
- **A2A-shaped cards:** `SessionDirectory` / `PeerLedger` (#185/#469).
- **Trust model: reused, not rebuilt** (see below).

## What is net-new

- A loopback HTTP+SSE listener subsystem (the bulk; ~a few hundred LOC, mostly socket/HTTP glue).
- A `MCP.Server` instance with Iris's own `tools/list` and handlers (~tens of lines).
- **A pollable agent mailbox** — the one genuinely new concept. Iris's delivery today *pushes into
  a live turn* or queues to the **human** inbox; there is no per-recipient "messages since X" pull
  surface. The mailbox sits on GRDB exactly like `PeerLedger`. (kube-agents confirms this shape:
  its bridge exposes a `poll_events` tool.)
- A synthetic guest-peer identity/card for the external client.
- The debug toggle + a bridge token (Keychain), in the config pane.

## Trust and security (the crux)

The owner is dropping the *transport* role, not the *approval* role. The design must enforce that.

- **Opt-in, loopback, token-gated.** Not bound by default; localhost-only; a bridge token the
  external client must present. Off = today's surface.
- **The planner-peer is an untrusted guest.** Its messages into Iris **taint** the receiving
  conversation exactly as any peer message does (#818), and drive turns subject to Iris's existing
  guards. It has no harness-verified liveness or authority and **cannot stand in for the owner's
  approval** — consequential actions still gate on the owner's band. (This is the
  permission-laundering boundary the team already enforces: a peer cannot grant escalation.)
- **Symmetric untrust.** Iris's observations may contain content Iris read from untrusted sources.
  When they reach the planner and the planner acts (files an issue, briefs a dev), the planner
  treats them as untrusted and never auto-executes a consequential action without the owner — which
  is how the planner already operates. The loop automates the *transport*, not the *judgment*.

## Goals / non-goals / anti-goals

**Goals**
- Direct planner↔Iris messaging that removes the owner's cut-and-paste step.
- Reuse the existing peer fabric + MCP SDK + loopback-listener precedent.
- Owner stays informed and approving via existing Overseer summaries + approval gates.
- Default attack surface unchanged (opt-in debug toggle).

**Non-goals**
- Remote / cross-machine agent messaging (that is #931's gateway client).
- Replacing the human inbox or the owner's approvals.
- Full A2A spec compliance — a pragmatic local subset of the concepts.
- Running by default.

**Anti-goals**
- Any new trust machinery, or a channel where untrusted content drives consequential actions
  without the owner.
- An always-on listening port.
- A guest peer that can self-assert authority/liveness or launder an escalation.

## Open questions for the owner (the "theirs" pile — brought after builder-check)

1. **Sequencing vs #931:** build this now as an independent local channel, or wait and share the
   A2A envelope types with the (parked) #931 so they're designed together?
2. **Priority vs current work:** the dev team is loaded (inbox/guard). Where does this sit —
   after the guard/inbox work, or does it jump ahead as "primary path" infra?
3. **One peer or many:** a single well-known planner identity, or support several external agents
   (e.g. a reviewer loop + the planner) each as their own guest peer?
4. **Scope of the mesh:** Iris↔planner only first, or expose the same channel so dev sessions can
   query Iris directly too?

## What is left to the builder

- Exact tool schemas (`send`/`poll`/`discover`/`manage_identity`), the mailbox table + retention,
  the synthetic card's representation in `SessionDirectory`, SSE-push vs poll wiring, the
  config-pane toggle + token storage, and whether to factor the A2A envelope types as shared with
  #931 on day one or local-only first. These are implementation choices for the plan, once the
  owner answers the four questions above.
