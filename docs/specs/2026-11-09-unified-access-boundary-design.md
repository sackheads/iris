# Unified Access / Credential / Visibility Boundary — Design (#974)

**Status:** **approved by Brian 2026-11-09**, builder-checked. Spine agreed in the same session.
Next step is the implementation plan (boundary core first, then consumer plans) — no code until that
plan exists and is reviewed.

**Intent.** Iris is gaining several features that each need to answer the same question —
*which identity can reach which credentials, which memory/knowledge, and which transports/peers* —
and today there is no shared answer. The MCP service (#965), the A2A client both directions
(#931 + `docs/superpowers/plans/2026-11-07-a2a-client.md`), the profile edit pane (#961), the
credential registry (#966) and per-profile memory scoping (#967) are not independent: they are
consumers of one boundary. This document defines that boundary once, so each consumer consults a
single model instead of inventing its own policy. Build this before building any one consumer.

The motivating use case is teamwork: Iris acting as a real teammate — reviewing a PR under *her own*
GitHub identity when a trusted peer (homelab) asks — not a suggestion box that hands diffs back for a
human to paste. The boundary has to make that safe, not forbid it.

## Current state (verified in code, 2026-11-09)

- `Principal` (`SandboxPolicy.swift:10`) is `{ main, subagent, evaluator }`. No grant/deny semantics.
  The A2A plan proposes adding `.a2aRemote`; an MCP service would add a guest case.
- `KeychainManager` scopes secrets by `kSecAttrService` name only — **no** `kSecAttrAccess`, no
  per-item access lists. There is no credential-identity concept today; secrets are a flat
  service→blob map.
- The A2A client plan already proposes `A2AInboundPolicy.decide(tool:path:args:) -> {autoAllow,
  needsApproval, hardBlock}` as an explicit ordered table, gated by a new `Principal.a2aRemote`. That
  ordered-policy-table is the closest existing shape to this boundary and is a candidate for the
  per-route policy below — it should be generalized here, not duplicated per transport.

So this boundary is **net-new**, not a generalization of an existing grant model.

## The model: three layers

### 1. Principal — the fixed code floor
A `Principal` is the *execution context* the engine already tracks: `main`, `subagent`, `evaluator`,
plus new `a2aRemote` and `mcpGuest`. It is **not a user-configurable surface.** It carries the
non-negotiable caps that are true for that context regardless of profile — e.g. `a2aRemote`/`mcpGuest`
never run in the foreground, always hard-strip, run in an isolated lane; `subagent` cannot do X.

Per-Principal rules are **fixed in code** (Brian: fine until it causes a problem down the road). A
blanket per-Principal deny ("no subagent ever spends a credential, whatever profile it runs as")
lives here as a floor, never as a config pane. The floor is a *cap*, never a grant.

### 2. Profile — the user-configured grant
A Profile is a named, user-created identity. It is **the only thing the user configures** (the #961
pane). A Profile grants over these axes:

- **Credentials:** a subset of the typed accounts in the registry (§Credential registry).
- **Memory / knowledge:** which memory tier it sees (§Memory scoping).
- **Transports/peers:** which MCP guests / A2A peers it may reach, inbound and outbound; and whether
  it may send a disclosure-request to the owner broker (§Disclosure broker).
- **Filesystem:** read/write roots — reuses the existing grant/workspace model
  (`PermissionManager`, `WritableRoots`), scoped by profile rather than global.
- **Skills / library / tools:** which are available (floor still caps the Principal-forbidden ones).

Examples the user builds: `owner` (full; what `main` runs as), `overseer-team` (no personal memory,
repo access, no personal creds), `web-researcher` (web + read-only FS, no creds, no write),
`reviewer` (carries `Iris-github`, not `Brian-github`), `homelab-peer` (what you grant the homelab
A2A peer), `research-guest` (a confined MCP guest).

### 3. Binding — a run acts *as* a Profile, capped by its Principal floor
Rights live on the Profile; the Principal floor sets how low the ceiling is. Two rules:

- **The profile is a property of the initiating authority, never of the task.** Every entry point
  resolves route → profile from *authenticated identity* and stamps it on the run **before the
  engine starts.** The task/message body can **never** name its own profile — a payload that asks
  for a broader profile is ignored text. This is the confused-deputy defense, and it lives at every
  door, not in the model.
- **No-widen.** A run may voluntarily drop to a narrower profile; it can never raise. An unmapped
  external route gets nothing — **fail closed.**

Default bindings (so the common cases need zero config):
- `main` → `owner` profile. Unconfigured; behaves like today.
- `subagent` / `evaluator` → **inherit the spawner's profile ∩ their Principal floor.** No
  per-subagent configuration, ever. A spawner may *explicitly* drop a subagent into a narrower named
  profile (run this research under `web-researcher`), but never widen it.
- `a2aRemote` / `mcpGuest` → the named guest profile the route resolves to from the authenticated
  peer identity.

## The five routes (worked)

The same task ("review this PR") runs under five different profiles depending on who initiated it:

| # | Route | Principal | Profile resolved from | Ceiling |
|---|-------|-----------|----------------------|---------|
| 1 | Iris starts it herself | subagent (of her session) | her current profile, drop-to-narrower | her profile |
| 2 | Overseer session assigned a review | subagent/main of that session | the overseer session's configured profile | that profile |
| 3 | MCP guest asks | mcpGuest | the guest's configured profile | guest profile ∩ mcpGuest floor |
| 4 | homelab A2A asks | a2aRemote | `homelab-peer` (from authenticated peer id) | `homelab-peer` ∩ a2aRemote floor |
| 5 | GitHub webhook asks | (new) webhook | configured `github-webhook` profile, else **reject** | that profile, or nothing |

Route 5 generalizes: a new route with no established identity must map to a configured profile or be
refused. No anonymous trigger ever runs as owner.

## Credential registry (#966)

Credentials become **typed accounts** in a registry, replacing the flat service→blob map:

- Each account has a **type** (`github`, `google`, `openai`, …) and an **owner-class**: *owner-personal*
  (Brian's) or *service* (Iris's own bot identities).
- A Profile is granted a **subset** of accounts. With one account per type per profile, the grant set
  alone decides which identity a call uses — no separate "active account" selector. (If a profile
  ever holds two accounts of one type, selection becomes explicit; avoid by default.)
- **Hard requirement — least privilege at the source.** The backstop against a hijacked inbound
  request is the account's own scope, not the boundary. `Iris-github` is a scoped bot PAT (comment +
  approve on the repos reviews touch; no force-push to protected branches; no admin). **Owner-personal
  full-access tokens never go in a profile a guest can hold.** Granting a profile an account delegates
  that account's full power to whoever holds the profile.
- Inbound guests **may** be granted owner/service creds (Brian: homelab should 100% review under Iris'
  account). There is **no** "inbound can't touch creds" floor; the mitigation is account scope +
  the a2aRemote/mcpGuest guard (hard-strip, injection guard with an external `contextTag`), because
  the reviewed diff is untrusted content that may carry an injection aimed at those very creds.
- Keychain: accounts need an identity/scope dimension `KeychainManager` lacks today. Builder to
  design the storage (likely service-name-encodes-account plus a registry index); does not require
  the deprecated `SecAccessCreate` access-list APIs (zero-warnings rule forbids them).

## Memory / knowledge scoping (#967)

A Profile sees a **memory tier**, not the whole store:

- `owner` → full (facts, `USER.md`, all skills, library).
- internal named profiles (`overseer-team`, `reviewer`, `web-researcher`) → a configured slice; no
  personal `USER.md`/facts unless the task needs them.
- guest profiles → least: task context + at most a public "about Iris" blurb; **no** personal memory,
  facts, or private skills.

Builder to define the slice mechanism (namespaces/tags on memory items that a profile is granted, vs.
a coarse tier enum). Coarse tiers first; namespaces if a real case needs finer control.

## The disclosure broker (the proxy / escalation path)

A restricted profile that lacks a piece of information may **ask** for a redacted version over the
inter-agent bus, rather than being granted the underlying access. Motivating example: homelab (Clomp)
asks Iris for a flight time on a trip it cannot see; it explains its task, and Iris returns just the
time.

**The invariant that makes this safe: the decider is never the requester.** The disclosure decision
runs in a **separate owner-authority Iris session**, not under the requesting profile. The requester
receives a **vetted string as output** — never the access, never a handle, never a credential. If the
decision ran under the requester's profile it would be either useless (can't see the info) or a
fiction (the profile already has the access). This is not a new trust path: it is the inter-agent bus
plus a broker endpoint plus a disclosure policy. A guest profile's transport grant includes "may send
a disclosure-request to the owner broker"; the broker is an `owner`-profile run that answers.

**The envelope** (honors Brian's ~70/30 functionality lean, but per-class, not flat):

- **Hard deny-list the LLM can never cross, whatever it is argued into (~100/0):** credentials/tokens,
  raw `USER.md`, third-party PII, anything financial / auth / health. Not disclosable by judgment.
- **Within the envelope, the broker LLM has latitude** — the flight time, a schedule window, a
  yes/no.
- **Sensitivity dial:** low-sensitivity → auto-disclose within the envelope; higher → becomes an
  **Inbox item Brian approves** before it returns. Every disclosure is logged regardless. This is the
  convergence with the just-shipped Inbox: a proxied disclosure to a guest is exactly a human-decision
  surface. "Auto-disclose" means *without Brian in the loop* — it still requires a live owner-authority
  run to decide and read the source (see **R4**); with no owner context available it does not fall back
  to a cache, it stays pending.

The broker runs the requester's task text under the injection guard (external `contextTag`) even
though the broker itself is high-privilege — the request explaining the task is untrusted.

## How each consumer plugs in

- **Profile pane (#961):** the editor for Profiles and their grants across all axes. The one place
  the user configures the boundary.
- **Credential registry (#966):** the typed-account store a Profile grants over; enforces owner-class
  and least-privilege.
- **Memory scoping (#967):** resolves a Profile's memory tier/slice at context assembly.
- **MCP service (#965):** each connecting guest resolves to a `mcpGuest` Principal + a guest Profile;
  tool/resource exposure is the Profile's grant ∩ the floor.
- **A2A inbound (plan Task 5):** `A2AInboundPolicy` becomes the per-route resolver for `a2aRemote` —
  authenticated peer → Profile, capped by floor. Its ordered table is this boundary's enforcement
  point for that route, not a transport-local policy.
- **A2A / MCP outbound:** which peers a Profile may *reach* is the transport axis of the grant.
- **Inbox:** the human-decision surface for disclosure approvals and (optionally) first-grant of a
  new peer's Profile.

## Goals / non-goals / anti-goals

- **Goal:** one model every consumer consults; teamwork (credentialed inbound) safe by construction;
  the user configures only Profiles.
- **Non-goal:** per-Principal configuration UI; cryptographic peer verification (the A2A gateway does
  that upstream); reworking the FS grant model (reuse it, scope it per profile).
- **Anti-goal:** the task/payload influencing which profile it runs as; an anonymous route running as
  owner; owner-personal full-access tokens reachable by a guest profile; the disclosure broker
  trusting its own judgment on the hard-deny classes.

## Resolved after builder-check (2026-11-09)

A builder-check (fresh engineer reading this cold) raised five architecture questions. None required
a new decision from Brian; each resolves from decisions already made plus verified project state.

- **R1 — Sequencing vs the A2A plan.** #974 lands **first**. Verified `Principal.a2aRemote` and
  `A2AInboundPolicy` exist only in the 11-07 plan, not in `Sources/`; #931 is open and gated on the
  romar server spec. So there is no shipped code to refactor: A2A's Task 5 builds its inbound
  authorization *on* this boundary's generalized route→profile resolver and contributes the
  `a2aRemote` Principal case. #974 owns the resolver and the Principal additions; A2A owns the
  transport/SSE and the peer-id source. Matches the agreed sequence: inbox → boundary → MCP/A2A.
- **R2 — Where the binding lives.** The active binding is a **transient per-run context on the
  engine**, resolved and stamped before the run starts. The profile id is **also persisted on
  `Conversation`** so a durable/named session (owner, overseer-team, an a2a-remote lane) keeps its
  identity across reload — new field, `decodeIfPresent`, default `owner` for existing rows
  (Invariant 1). `subagent`/`evaluator` runs inherit the spawner's live binding ∩ floor through
  `SubagentManager`; no extra persisted field. Every consumer (memory assembly, cred selection, FS,
  tool gating) reads the active binding. *(planner's call)*
- **R3 — Per-profile FS vs the `.shared` `PermissionManager`.** In scope, and a notable-size item:
  per-profile roots mean FS checks must be consulted **with the run's profile**, so `PermissionManager`
  stops answering as a flat process-global (Invariant 7). Mechanism (inject per-run vs. add a profile
  parameter to its checks) is builder-left, but the de-globalization itself is in scope and should be
  sized in the plan. *(planner's call; sizing flag)*
- **R4 — Disclosure-broker execution.** **Async, entailed by the sensitivity dial.** A
  disclosure-request is a bus message answered by a **per-request spawned owner-authority engine run**
  (not a standing privileged daemon — minimizes attack surface): immediately if a live owner context
  can take it, else it queues as an Inbox item (already the high-sensitivity path). The requesting
  task waits within its deadline or gets a pending-ack and resumes. **Consequence, not a free choice:**
  on a single-machine install nothing can answer a disclosure needing owner memory without a running
  owner-authority context, so there is **no auto-disclosure from a cache** — no available owner
  context ⇒ the request stays pending (fail-closed to "later," never answered by a lesser authority).
  This is what bounds the "auto-disclose within the envelope" path in the broker section above: even
  the no-Brian-in-the-loop case needs a live owner-authority run; it is "auto" w.r.t. Brian, never
  w.r.t. an owner process. Feature feel: guest disclosures are answered when your Iris is around, not
  instantly 24/7. *(planner's call — flagged for Brian's check because it sets the feel.)*
- **R5 — Identity→profile routing.** The mapping lives **on the Profile** (a Profile declares which
  authenticated identities resolve to it) — one place, stays "configure profiles only." Each transport
  supplies the identity: A2A from the gateway's verified peer id; MCP guest from #965's own guest-auth
  design — this boundary **requires** every guest connection to resolve to an authenticated identity →
  profile or be refused (fail closed), but does not itself define MCP's auth; the GitHub-webhook route
  is illustrative/future and likewise must map to a configured profile or be rejected. *(planner's call /
  scoping)*

## Left to the builder / to fine-tune later

- Keychain storage shape for typed accounts + owner-class.
- Memory-slice mechanism (coarse tiers vs. granted namespaces).
- The exact sensitivity-dial classification (which categories auto vs. Inbox); Brian's first cut:
  deny = creds/third-party PII/secrets; fine-tune as cases arise.
- Whether Profiles are themselves persisted `Codable` (Invariant 1: `decodeIfPresent` on every new
  field) and where (a new store vs. `ConfigManager`).
- Invariant 9 sweep: new Principals/profiles/lanes must not contradict existing session/subagent docs
  or agent-facing strings.
