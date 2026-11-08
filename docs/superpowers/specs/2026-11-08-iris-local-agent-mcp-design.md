---
type: design
title: Iris MCP service + agent confinement (A2A-over-MCP, co-designed with #961/#966/#967)
status: draft (rev 5 — folds Iris's five reviews incl. the rev-4 review)
timestamp: 2026-11-08
component_issues: ["964", "961", "966", "967", "965"]
---

# Iris MCP service + agent confinement

**Iris is a product that exposes services to other agents** (the Safari/Chrome-MCP, kube-agents
category). This design makes Iris a first-class, opt-in **MCP service**, and — because the first
real consumers are *untrusted, credentialed, public-posting* agents — it co-designs the
**confinement model** that makes that safe. Iris's own reviews (#964/#966/#961 review docs on
this branch, and #967) reshaped it: the four reviews found two blocker-class holes and corrected
reuse claims that didn't survive the code. This rev folds them.

## The arc, at a glance

One coupled design across the component issues:

- **#964 — the MCP service** (this doc's spine): a loopback Streamable-HTTP MCP server, off by
  default, that external agents connect to. The transport/entry.
- **#961 — profile editor**: the UI for agent profiles, which become the confinement unit.
- **#966 — credential registry + per-profile access**: typed credentials bound to profiles,
  *enforced*.
- **#967 — per-profile memory scoping**: the confidentiality half of profile confinement.
- **#965 — Iris reviews as herself**: the first use case, which needs all of the above.

The through-line: **a guest connects (per-token) → routes to an owner-created, role-holding,
profiled session → whose credentials pin it to the sandbox and whose memory is scoped → and
whose consequential actions are taint-gated and reach the owner for approval.**

## Direction — the MCP service

- **Transport: Streamable HTTP** (SDK `StatefulHTTPServerTransport`) over an **HTTP-server
  library** (Hummingbird/SwiftNIO — not hand-rolled), token-gated, bound to `127.0.0.1:<port>/mcp`.
  Verified against Claude Code's MCP client: a URL server with a static `Authorization: Bearer`
  header, no OAuth; the deprecated separate-SSE endpoint is not built. Caveats: 5-min idle timeout
  (the poll-mailbox request/response model sidesteps it); a 401 reads as a connection failure.
  Loopback only this increment; network exposure is #931's remote story, separately gated.
- **Tool surface (A2A-over-MCP)**, inspired by gke-labs/kube-agents `a2a/mcpbridge` (Apache-2.0):
  `send` (to a session/role), `poll` (a per-recipient pull mailbox), `discover`/`status`.
- **Off by default, opt-in feature setting** in the config pane (shared with #931's a2a config) —
  a real feature, not a debug flag. Binding the port is the only thing the toggle does; default
  attack surface unchanged.
- **Co-designed with #931**: one shared A2A envelope/adapter across the local-MCP and
  remote-gateway transports.

## Guest identity, routing, and lifecycle (revised per the #964 review)

- **Per-token identity — not one shared token + self-naming.** The rev-1 "a bridge token +
  `manage_identity` alias" let anything holding the token claim to be "planner" and read its
  mailbox (review #1; violates our own anti-goal). **Each client gets its own token; the harness
  binds identity and mailbox to the token** (as it assigns `session_id` today). Mailbox keyed by
  token, not `Mcp-Session-Id`, so reconnects/idle-timeout churn don't lose messages (review #5).
- **Guests route to role-holding sessions, never the pinned `iris` conversation.** Defaulting to
  `iris` would permanently taint (#818) the session the owner uses most → approval fatigue
  (review #2). Guests address `role:reviewer` / `role:feedback`; the pinned `iris` is forbidden as
  a guest target in this increment.
- **Owner-only session creation.** If a guest addresses an unheld role, it gets a distinct
  "role unheld" signal (#955 F4 — now *required*, not polish) and Iris raises an **inbox item**
  asking the owner to start the session from the menu. A guest **cannot** spawn a profiled
  session — that would let a guest create one holding the `iris` credential, an escalation
  (#964-routing review). Pre-authorized guest spawn is allowed *only* for profiles with **no
  credential grants** (`spawnable_by_guests: true` in the protected profile dir).
- **Lifecycle:** a role-holding session already survives the idle sweep (`sweepIdleSessions`
  never archives a role-holder), so no new keep-alive flag. But a guest has no liveness, so an
  `expects_reply` to a departed guest stays open forever (review #6): give guests a **TTL /
  last-poll expiry** that closes outstanding requests and notifies the sender (as #881 does for
  archived sessions).
- **Rate limit / stop condition:** a guest↔Iris turn exchange can ping-pong unattended (review #4;
  the direct-send loop the topic restriction doesn't cover). Enforce a **per-guest rate/turn
  budget + a harness stop condition** — not either model's judgment.
- **Provenance (review #8):** **both** — forbid guest→guest in this increment **and** stamp every
  message's origin as Iris-native vs guest (stamping is near-free and #931's remote story needs
  it), so a dev guest can't hand the planner something shaped like an Iris observation.
- **Wake contract (review #3):** a Claude Code consumer only polls when it has a turn — specify
  what drives the planner's poll (a `/loop`, with its cost/latency) vs. whether a connected client
  is woken by the stream. Partly a client-side concern; the design must state the contract.

## The confinement model (co-designed with #961/#966/#967)

**Corrected reuse reality (the #966/#961 reviews caught my error):** there is **no**
KeychainManager access-list and **no** `Principal` grant/deny model to reuse — KeychainManager
scopes by service name only; `Principal` is `{main, subagent, evaluator}`. Enforcement is
**new** dispatcher-side code. Do not size this as "reuse existing."

- **Credentials (#966).** A typed credential registry (GitHub today, extensible — `type + id`),
  N accounts, each `{identity metadata + creds}`; for GitHub `{username, API token, git author
  name/email}` (both the API actor and the git author switch). A **dispatcher-side credential
  broker** checks the conversation's profile allowlist before handing out a credential.
  - **BLOCKER — sandbox pin:** the broker only gates what Iris *hands out*; a host `run_command`
    already has the owner's `gh auth token`, git credential helper, and ssh-agent. So **assigning
    any credential to a profile pins its `run_command` to the sandbox VM** (no home mount, no
    ssh-agent, HTTPS remotes) and **fails closed** if no runtime. Without this, confinement is
    theater.
  - **BLOCKER — fail-closed grants:** a credential allowlist *is* a grant, which breaks #465's
    "a profile grants nothing." Credential grants must come only from a live, cleanly-parsed
    profile file — **no snapshot-fallback** (which fails *open*: breaking the file to revoke
    leaves the grant live). Keep the allowlist in the protected `config/agent-profiles/` dir.
  - **Taint-gates use, not just access:** credentialed actions are outbound+consequential (class
    of `gmail_send_email`). After #818 taint they need approval unless an explicit exemption
    covers them — else #965 becomes "any guest posts as Iris."
  - **GitHub-side scoping (second layer):** the `iris` account gets a fine-grained PAT, triage/
    write without bypass, branch protection, minimum repos/scopes. Treat the token as one that
    will eventually leak.
  - **Token exposure / git identity:** redact registry secrets from tool output (reuse Iris's
    output filter) and/or a per-call credential helper in the VM; set `GIT_AUTHOR_*`/
    `GIT_COMMITTER_*` via per-command env, never `git config` writes (no #832 collision).
- **Profiles & the editor (#961).** The editor is independently landable. For credentials:
  validate with `AgentProfileStore.parse()` before save (refuse broken writes); field-level
  rewrite preserving unknown keys + body; `contentHash` concurrent-edit check; atomic write. UI:
  a **Tools/skills** section labelled *focus/narrowing* (AgentProfile.swift:219: "not security")
  kept distinct from a **Credentials** section labelled an *enforced boundary*, shown only once
  the broker ships. Before saving a credential grant, show its blast radius ("N open
  conversations use this profile, M tainted"). The #965 reviewer profile ships with a **narrow
  `tools:` list as defence-in-depth** (no `gmail_send_email`, calendar/tasks, `schedule_job`,
  `update_soul`/`update_user_profile`/`update_memory`, `invoke_subagent`, …) — narrowing is
  focus, not a boundary, but it's near-free; enforcement stays broker + sandbox-pin + taint.
- **Memory (#967).** Profiles confine tools and (soon) credentials but **not memory** — a
  confined credentialed reviewer reads the owner's full fact store/USER.md and could be asked to
  post it publicly. #813 holds *writes* from tainted conversations (integrity) but nothing
  protects *reads* (confidentiality). Investigate per-profile memory scoping (namespace, or a
  `memory: none|shared-readonly|shared` frontmatter key with a fact-store scope filter). Also a
  likely **current** gap, separable from profiles: `ContextHolds` gates `write_file` by path but
  not `run_command`'s shell, so a tainted host `echo >> ~/.iris/memory/...` may be unheld —
  verify and, if so, harden #813 independently.
- **The #965 reviewer is a standing session, not a job.** Profiles never apply to the pinned
  Iris, a subagent, or a job run (#611) — so "Iris reviews PRs" is a long-lived, owner-created
  session holding `role:reviewer` with the `iris`-account profile; #964 guests route there.

## Reuse vs net-new (corrected)

- **Genuine reuse:** the MCP SDK server side (zero protocol code); the `decidePeerSend` upstream
  divert for the outbound mailbox leg (leaves `deliverPeerMessage` untouched); the #818 taint
  model; `sweepIdleSessions`' role-holder protection; the protected profile dir.
- **Net-new (do not undersize):** the library-backed loopback HTTP server; the `MCP.Server` +
  tools; the per-token guest mailbox; the **dispatcher-side credential broker**; **sandbox-pin
  enforcement** for credentialed profiles; per-profile memory scoping; guest TTL + rate limits.

## Trust & security (the layered model)

Opt-in, loopback, per-token. Guests are untrusted and taint. A guest cannot self-assert
authority, spawn a credentialed session, or stand in for owner approval. **"Owner stays approver"
holds only if gate prompts actually reach him** — so **inbox *delivery* (not just recording) is a
hard prerequisite** (review #7; the inbox is currently write-only). Layers: taint-gate →
sandbox-pin → fail-closed grants → GitHub-side scoping → memory scoping. Each is defence the
others don't provide.

## Sequencing & dependency graph (revised)

Hard prerequisites for the credentialed/guest increment, beyond "inbox/guard lands":
1. **Inbox approval *delivery*** (not just recording).
2. **Role-addressable sessions** + #955 F4 (unheld-role signal).
3. The **credential broker + sandbox-pin** enforcement.

**The plain increment is not credential-free of obligations (review of rev 4).** Several guest
controls apply whether or not credentials are involved and must gate the *plain* MCP service, not
just the credentialed one: **per-guest rate/turn budget + stop condition** (an uncredentialed
guest can still loop a role session's tokens), **guest TTL / last-poll expiry** (else departed-
guest `expects_reply` stays open forever), and **provenance stamping** (needed the moment there
are two guests). Inbox *delivery* is also required for the plain increment — a guest taints the
role session, so its gated actions need approval — **or** the plain increment ships with guest-
driven sessions **refusing gated actions outright rather than asking into a void**.

Build order: profile-editor base (#961, independent) lands first. The **plain MCP service**
(loopback, guests → roles, no credentials) requires rate-limit+stop, TTL, provenance stamping,
and either inbox delivery or fail-closed gating. **Credentialed** guests additionally wait on the
broker + sandbox-pin + role-addressable sessions (prereqs 1–3 above). Memory scoping (#967) and
the standalone #813 `run_command` hardening proceed in parallel as investigation/fix.

## Goals / non-goals / anti-goals

**Goals:** Iris as an opt-in MCP service; direct multi-client agent↔Iris messaging (each client's
context stays clean — no hub session); confined, credentialed, memory-scoped guest-facing
sessions; owner informed/approving via Overseer + *delivered* gates; default surface unchanged.
**Non-goals:** remote/cross-machine (#931); replacing the human inbox or owner approval; running
by default; full A2A compliance.
**Anti-goals:** a guest that self-asserts authority, spawns a credentialed session, launders an
escalation, or reaches the owner's creds/memory/token; an always-on port; credential confinement
that is UI-only (unenforced); a credentialed job or pinned-Iris reviewer.

## Owner decisions (2026-11-08)
Co-design with #931; sequence after inbox/guard; multi-client agnostic; HTTP-server library;
feature-not-debug; dedicated reviewer profile holding the `iris` GitHub creds (not the owner's),
as a standing owner-created `role:reviewer` session.

## Review provenance
Folds five Iris reviews (session A2A970FB). Durable records (the review files are **not** all
committed — publishing the #964 review file was declined by the sandbox classifier, so it lives
untracked in the `iris-design-mcp` worktree and can be committed on request):
- #964 design review: untracked worktree file `…-iris-local-agent-mcp-design-review.md`.
- #966 review: issue #966 `issuecomment-6726664075` (+ planner response `-6726701535`).
- #961 review: issue #961 `issuecomment-6726762078` (+ planner response `-6726821145`).
- #967 (memory scoping): issue #967 (+ planner note `issuecomment-6726872414`).
- #964 rev-4 review (this one): guest-safety-for-the-plain-increment, narrow reviewer tools,
  both-provenance-options, and this provenance fix.
The #966/#961 reviews corrected the KeychainManager/`Principal` reuse errors and found the
sandbox-pin and fail-closed blockers.

## Left to the builder
Exact tool/mailbox schemas; the credential-broker interface (`type + id`); the sandbox-pin
mechanism in `resolve()`; memory-scoping mechanism (namespace vs read-filter — #967 investigates);
the shared A2A envelope with #931. No open owner questions remain for the MCP service itself.
