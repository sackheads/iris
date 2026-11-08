---
type: design
title: Iris MCP service — local agent interface (A2A-over-MCP)
status: draft (for builder-check, then owner review)
timestamp: 2026-11-08
---

# Iris MCP service: exposing Iris to other agents (A2A-over-MCP)

## Intent and why

**Iris is a product that can expose services to other agents** — the same category as Safari
MCP, Chrome MCP, and kube-agents. This feature makes Iris a first-class, opt-in MCP service: a
running Iris instance exposes its agent-messaging fabric (and, over time, more of its
capabilities) to external agents over MCP. It is a real feature, not a debug hack.

The first and motivating consumer is the **Iris↔planner feedback loop**: a running Iris instance
(the owner's real, daily-driver app) surfaces grounded observations from live use, and a Claude
Code "planner" session triages them — verifies against the code, files issues, routes work to the
dev team, brings decisions back to the owner. Today the **owner is the manual relay**, copying
Iris's observations into the planner and the planner's questions back. That cut-and-paste
middleman step is the bottleneck.

The owner's standing goal (the year's theme — culminating in the Overseer) is to get himself
**out of the critical path without giving up oversight**: summaries, updates, approvals, a say in
decisions — just not being the socket. So Iris and its consumers transact directly, while the
owner stays the approver via mechanisms that already exist (the Overseer's summaries, approval
gates on consequential actions).

**Why every consumer connects to Iris directly (not through the planner):** routing all agent
traffic through one session to reach Iris would pollute that session's context with traffic it
has no reason to hold — e.g. the planner should not accumulate dev-agent↔Iris chatter. Iris is
the hub; each agent opens its own connection and keeps its own context clean. This is the
architectural reason the server is multi-client, not a planner-only channel.

## Direction (decided)

**Iris exposes a loopback MCP server that fronts its own local agent↔agent fabric; external MCP
clients connect and appear to Iris as guest peers.** It is an ordinary multi-client MCP server
(owner decision: don't assume a single client), off by default, enabled by an **opt-in feature
setting** (a real feature, not a debug flag).

- **Transport: Streamable HTTP** (the SDK's `StatefulHTTPServerTransport`) over an **HTTP-server
  library** (owner decision — Hummingbird, on SwiftNIO, is the likely pick; final choice is the
  plan's, but hand-rolling the server is ruled out), token-gated, bound to
  `127.0.0.1:<port>/mcp`. Verified: Claude Code consumes a URL-based Streamable-HTTP server with a
  static `Authorization: Bearer` header — **no OAuth** (`claude mcp add --transport http … --header`,
  token via `${ENV_VAR}`). The deprecated *separate*-SSE endpoint is **not** built — Claude Code
  won't use it; Streamable HTTP carries server→client streaming on its own one endpoint. Loopback
  only; the SDK transport already does localhost-origin validation. Caveats to design around: a
  5-minute MCP idle timeout (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`) — the poll-mailbox model
  (request/response) sidesteps long-lived-stream idling; a 401 surfaces as a connection failure,
  not an auth prompt; don't name the bridge-token env var one of Claude Code's reserved names
  (`ANTHROPIC_API_KEY` etc., which expand empty).
- **Tool surface (A2A-over-MCP), inspired by gke-labs/kube-agents `a2a/mcpbridge` (Apache-2.0,
  inspiration not a port):** a small toolset fronting A2A semantics — `send` (to a session/role),
  `poll` (a pull mailbox for "messages to me since X"), `discover`/`status` (who is addressable),
  and a session-identity/alias tool.
- **Connecting clients are guest peers (multi-client by default — owner decision):** the server is
  an ordinary MCP server and does not assume a single client. Each authorized client gets a
  synthetic session identity/card in `SessionDirectory`, with **no harness-observed liveness** (a
  non-Iris process has no turn engine, so Iris cannot verify it the way it verifies its own
  sessions). That is correct — a guest peer is intrinsically low-trust. Any number connect (the
  planner, a reviewer loop, a dev session, antigravity); none is special-cased.
- **Off by default, enabled by an opt-in feature setting in the configuration pane** (the same pane
  #931's a2a config lives in) — a real, documented feature, not a hidden debug flag. It only binds
  the port when enabled, so **the default attack surface is unchanged**. Loopback-only for this
  increment; exposing the service beyond the local machine is a separate, later, separately-gated
  step (and overlaps #931's remote story), not part of turning the feature on.

### One agent-interface, co-designed with #931 (owner decision)
Iris's local session fabric is already A2A-shaped (its `AgentCard`s). This local
**A2A-over-MCP** channel and #931's remote **A2A-over-gateway** client are the same conceptual
model over two transports/trust-models. **Owner decision: don't build two a2a adapters.** #931
unparks far enough to co-design one shared A2A envelope + adapter layer now, so the remote
transport isn't retrofitted onto an incompatible local one later. **Implementation of this
channel sequences *after* the current inbox/guard work lands (owner decision)** — this is design
now, build later.

## What this reuses (the owner's "don't bend over backwards" test)

- **MCP protocol: free.** The MCP Swift SDK Iris already vendors ships the whole server side —
  `Server` actor, `tools/list`/`tools/call`, `StatefulHTTPServerTransport` + `OriginValidator.localhost()`.
  Zero protocol code. (`MCPManager` itself is client-only and not reused; the SDK beneath it is.
  Supply-chain note: the SDK is pinned to branch `main`, not a tagged release — pin a tag before shipping.)
- **Inbound send path (planner→Iris) reuses existing plumbing:** the `send` tool targeting the
  pinned `iris` conversation (or a named session/role) maps onto `AppState.decidePeerSend` →
  `IrisEngine.deliverPeerMessage` → run-a-turn/queue, with `PeerLedger` correlation. This leg is
  reuse. **(The *outbound* Iris→planner leg is NOT this path — see net-new, it's the mailbox.)**
- **A2A-shaped cards:** `SessionDirectory` / `PeerLedger` (#185/#469).
- **Trust model: reused, not rebuilt** (see below).

## What is net-new

- A loopback **Streamable-HTTP** listener subsystem. **Correction to an earlier estimate:** the
  `OAuthManager` precedent is a *single-shot* `NWListener` (one request, one `200`, close) — it is
  precedent for *binding loopback*, not for a persistent HTTP server with POST-bodies, streaming
  responses, and `Mcp-Session-Id`. This is the bulk of the work and its size depends on the
  dependency decision below (**owner question**): hand-roll HTTP/1.1 over `NWConnection`, or take an
  HTTP-server library (SwiftNIO/Hummingbird — the SDK transport is bring-your-own-framework). The
  multi-client decision pushes toward a real library (concurrent clients over raw sockets is a lot
  of fragile glue, against a zero-warnings bar), but it adds a dependency to a repo that keeps them
  lean — so it's the owner's call.
- A `MCP.Server` instance with Iris's own `tools/list` and handlers (~tens of lines).
- **The outbound (Iris→planner) delivery path.** `deliverPeerMessage` only delivers into a real
  Iris `Conversation` (runs a turn / queues a transcript); a guest peer has none, so this leg
  cannot reuse it. Decision: `send_to_session` *may* address a guest (uniform agent UX), and the
  divert happens upstream in `decidePeerSend` — a guest-target branch writes to the mailbox and
  returns, so `deliverPeerMessage` (turn execution) is **left untouched**. The routing branch is
  the only core-code change.
- **A pollable agent mailbox** — the one genuinely new concept, and the sink for the branch above.
  Iris's delivery today *pushes into a live turn* or queues to the **human** inbox; there is no
  per-recipient "messages since X" pull surface (`PeerLedger` stores only `firstLine`, not bodies,
  so it can't back this). Per-client mailbox on GRDB like `PeerLedger`. (kube-agents confirms the
  shape: its bridge exposes a `poll_events` tool.)
- A synthetic guest-peer identity/card per connected client.
- The debug toggle + a bridge token (Keychain / `${ENV_VAR}` on the client), in the config pane.

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
- Make Iris a first-class, opt-in **MCP service** that exposes its agent-messaging fabric (and,
  later, more capabilities) to external agents — the Safari/Chrome-MCP / kube-agents category.
- Its first consumer: direct planner↔Iris messaging that removes the owner's cut-and-paste step.
- Every consumer connects to Iris directly, keeping each session's context clean (no hub session).
- Reuse the existing peer fabric + MCP SDK; owner stays informed/approving via Overseer + gates.
- Default attack surface unchanged (off until the feature setting is turned on).

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

## Owner decisions (2026-11-08)

1. **Co-design with #931** — one A2A adapter/envelope shared across the local-MCP and
   remote-gateway transports; #931 unparks to co-design the shared layer.
2. **Sequencing** — build this *after* the current inbox/guard work lands. Design now, build later.
3 & 4. **Multi-client agnostic** — a standard MCP server; no single-peer assumption; each
   connecting client is its own guest peer.

4. **HTTP-server dependency** — take a library (Hummingbird/SwiftNIO), don't hand-roll the server.
5. **It's a feature, not debug** — frame and ship it as a first-class opt-in MCP service (peer to
   Safari/Chrome MCP, kube-agents), not a hidden debug flag; every consumer connects to Iris
   directly so no session's context is polluted by traffic it doesn't need.

All open questions are resolved; client-compat (static bearer header, no OAuth; Streamable HTTP,
no separate SSE) was verified against Claude Code's MCP docs. The design is ready for a
builder-check pass, then it waits behind inbox/guard before planning.

### Multi-peer use cases (asked by the owner)
- The **planner** — the primary triage/routing loop.
- A dedicated **reviewer loop** (the owner already runs a separate romar reviewer loop; an Iris
  reviewer is the same pattern).
- **Dev sessions** querying Iris directly — "repro this in the live app", "what does the mailbox
  show now" — without going through the planner.
- The **Overseer** pulling Iris status for the dashboard.
- **antigravity / other Claude surfaces**, and later non-Claude agents.
Multi-client agnosticism covers all of these without special-casing any; the guest-peer + taint
model applies uniformly.

## What is left to the builder

- Exact tool schemas (`send`/`poll`/`discover`/`manage_identity`), the mailbox table + retention,
  the synthetic card's representation in `SessionDirectory`, the config-pane toggle + token
  storage, and the concrete shape of the shared A2A envelope/adapter layer co-designed with #931.
  These are implementation choices for the plan. (Resolved above, not builder's choice: transport
  is Streamable HTTP; the envelope is shared with #931; multi-client; the outbound leg is a
  `decidePeerSend` guest-branch to the mailbox.) The HTTP-server dependency question is the one
  item still needing the owner before the plan can size the listener.
