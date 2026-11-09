# Unified Access / Credential / Visibility Boundary — Design (#974)

**Status:** **v2 — revised after the PR #999 security audit (2026-11-09).** The three-layer *shape*
(Principal / AccessProfile / Binding) was validated by the audit; as a *confinement model* the v1 had
holes, and the audit also found ~8 fail-open seams in the **existing** codebase that this boundary must
close. Three reviewers (Iris, rune, Clomp) raised 8 CRITICAL, 4 HIGH, 1 warning, 5 medium — **12
blocking**. This revision folds the blocking findings in as hard invariants and names the existing
seams to close. **The implementation plan is gated on this v2 plus a *targeted* re-review of the
changed sections** (not another cold trace — the first audit's full-depth pass, incl. Clomp's 31-minute
trace, was the one-time cost the spine gets once). No code until that re-review passes.

**What changed from v1 (audit map):** credentials are now *spent, never possessed* (C2); every axis of
"narrower" is enforced in code (C3); tier/FS/memory checks moved to the **data layer**, not prompt
assembly (C4/C5/H1); every default is **fail-closed** (C1/C5/C8/H3); the disclosure broker gets a
dedicated zero-acting-tools floor (H2); Iris **verifies peer signatures itself** rather than trusting
the gateway (H4, Brian's decision); the grant type is renamed `AccessProfile` to avoid colliding with
the existing `AgentProfile` (M3). Details inline, each tagged with its finding id.

**Intent.** Iris is gaining several features that each need to answer the same question —
*which identity can reach which credentials, which memory/knowledge, and which transports/peers* —
and today there is no shared answer. The MCP service (#965), the A2A client both directions
(#931 + `docs/superpowers/plans/2026-11-07-a2a-client.md`), the profile edit pane (#961), the
credential registry (#966) and per-profile memory scoping (#967) are not independent: they are
consumers of one boundary. This document defines that boundary once, so each consumer consults a
single model instead of inventing its own policy. Build this before building any one consumer.

The motivating use case is teamwork: Iris acting as a real teammate — reviewing a PR under *her own*
GitHub identity when a trusted peer (homelab) asks — not a suggestion box that hands diffs back for a
human to paste. The boundary has to make that safe, not forbid it. The audit's central lesson is that
"make it safe" is a *mechanism* claim, not an *intent* claim: a detector (the injection guard) is not
a boundary, and a default that leaks to owner is not confinement.

## Current state (verified in code, 2026-11-09)

- `Principal` (the enum in `SandboxPolicy.swift`) is `{ main, subagent, evaluator }`. No grant/deny semantics.
  The A2A plan proposes adding `.a2aRemote`; an MCP service would add a guest case.
- `KeychainManager` scopes secrets by `kSecAttrService` name only — **no** `kSecAttrAccess`, no
  per-item access lists. There is no credential-identity concept today; secrets are a flat
  service→blob map.
- The A2A client plan already proposes `A2AInboundPolicy.decide(tool:path:args:) -> {autoAllow,
  needsApproval, hardBlock}` as an explicit ordered table, gated by a new `Principal.a2aRemote`. That
  ordered-policy-table is the closest existing shape to this boundary and is a candidate for the
  per-route policy below — it should be generalized here, not duplicated per transport.
- **The existing codebase fails open in several places** (audit, verified in code). These are not
  design abstractions to add — they are live escapes the boundary must *close*. Enumerated in
  §Existing fail-open seams. This is why #974 is materially bigger than "revise a spec": the spine
  plus closing C1/C4/C5/C6/C7/C8.

So this boundary is **net-new**, not a generalization of an existing grant model.

## Enforcement invariants (the spine — post-audit)

These are the invariants every consumer and every entry point must satisfy. They are the heart of v2;
the sections below elaborate each. A design that states a rule it does not mechanically enforce is a
finding, not a boundary (audit, repeatedly).

1. **Spend, never possess (C2).** No credential secret is ever in model-reachable state (not in a
   prompt, a tool arg, a tool result, env, or the sandbox env). Credentials are spent only through
   **host-side proxy tools** (e.g. `github_comment(repo, pr, body)`) that read the Keychain themselves,
   expose a typed allowlisted op set, and return only non-secret results. The injection guard is a
   **detector, not a boundary** — #952 measured E2B passing ~96% of peer/inbox injections — so it may
   raise an alarm but is never the thing standing between an injected instruction and a secret.
2. **Fail closed, everywhere (C1/C5/C8/H3).** A missing binding, a missing grant key, an unmapped
   route, an unclassified tool, an unreadable profile file — every one denies, never defaults to owner
   or to host. Non-owner principals execute **only** in the sandbox; there is no host fallback for them.
3. **Enforce at the data layer, not at prompt assembly (C4/C5/H1).** Memory tier, FS roots and
   credential scope are checked inside the tools and the store (`search_memory`, `read_file`,
   `write_file`, credential selection), keyed on the active binding — not by shaping the prompt. A tool
   that reads data consults the binding itself; it cannot be fixed by what the prompt does or does not
   contain.
4. **Per-axis no-widen, in code (C3).** "Narrower" means every axis — credentials, memory, transports,
   filesystem, tools — of the target is a subset of the source. A drop into a named profile is refused
   unless it is provably a sub-grant on every axis. No-widen is a code path, not a convention.
5. **Identity is authenticated and never self-asserted (confused-deputy; M4).** The profile is a
   property of the initiating authority, resolved from authenticated identity and stamped before the
   engine runs. The task/message body can never name its own profile. Identity keys on
   `(transport, issuer, id)`, so an MCP guest naming itself `clomp` cannot resolve to the A2A
   `homelab-peer`.
6. **The owner is reachable only by `main`; policy is not model-writable (H3).** Profiles and
   identity→profile mappings live in a protected directory that only the #961 UI writes; no
   model-callable tool can modify a grant or a mapping. A run cannot rewrite its own authority.

## The model: three layers

### 1. Principal — the fixed code floor
A `Principal` is the *execution context* the engine already tracks: `main`, `subagent`, `evaluator`,
plus new `a2aRemote` and `mcpGuest`. It is **not a user-configurable surface.** It carries the
non-negotiable caps that are true for that context regardless of profile — e.g. `a2aRemote`/`mcpGuest`
never run in the foreground, always hard-strip, run in an isolated lane, and **execute only in the
sandbox (no host fallback, C1)**.

Per-Principal rules are **fixed in code** (Brian: fine until it causes a problem down the road). A
blanket per-Principal deny ("no subagent ever spends a credential, whatever profile it runs as")
lives here as a floor, never as a config pane. The floor is a *cap*, never a grant.

### 2. AccessProfile — the user-configured grant
The grant type is named **`AccessProfile`** (M3) to keep it distinct from the existing `AgentProfile`
(#465, which only narrows *prompts*), `JobProfile`, and the A2A `from.profile` field. Reusing the
`agentProfile` field for grants would silently turn a prompt-narrowing hint into a grant file — these
are orthogonal and must not share storage.

An `AccessProfile` is a named, user-created identity. It is **the only thing the user configures** (the
#961 pane). It grants over these axes:

- **Credentials:** a subset of the typed accounts in the registry (§Credential registry). A grant
  authorizes the *proxy tool* that spends the account; it never exposes the secret.
- **Memory / knowledge:** which memory tier/namespace it may read, and which it may write
  (§Memory scoping) — read and write are separate axes (no-write-up, H1).
- **Transports/peers:** which MCP guests / A2A peers it may reach, inbound and outbound; and whether
  it may send a disclosure-request to the owner broker (§Disclosure broker).
- **Filesystem:** read/write roots — reuses the existing grant/workspace model
  (`PermissionManager`, `WritableRoots`), **de-globalized and consulted per binding** (R3).
- **Skills / library / tools:** which are available (floor still caps the Principal-forbidden ones).

**Any omitted grant key on a non-owner profile means deny-all for that axis (C8), never all-access.**
Today `AgentProfile` with `tools:` omitted means *all tools*, and the shipped reviewer/researcher/writer
profiles omit it — that exact default is a fail-open seam; `AccessProfile` inverts it.

Examples the user builds: `owner` (full; what `main` runs as), `overseer-team` (no personal memory,
repo access, no personal creds), `web-researcher` (web + read-only FS, no creds, no write),
`reviewer` (carries `Iris-github`, not `Brian-github`), `homelab-peer` (what you grant the homelab
A2A peer), `research-guest` (a confined MCP guest).

### 3. Binding — a run acts *as* an AccessProfile, capped by its Principal floor
Rights live on the AccessProfile; the Principal floor sets how low the ceiling is. The binding is
**non-optional and built at the door (H3)** — a run with no binding is refused, never run as owner.
Rules:

- **The profile is a property of the initiating authority, never of the task.** Every entry point
  resolves route → profile from *authenticated identity* and stamps it on the run **before the
  engine starts.** The task/message body can **never** name its own profile — a payload that asks
  for a broader profile is ignored text. This is the confused-deputy defense, and it lives at every
  door, not in the model.
- **No-widen, per axis, in code (C3).** A run may voluntarily drop to a narrower profile; it can never
  raise. A drop into a *named* profile is refused unless the target is a subset of the source on
  **every** axis. An unmapped external route gets nothing — **fail closed.**
- **Owner only from `main` (H3).** The `owner` profile is reachable only by the `main` Principal. A
  missing binding on a non-main Principal is a refusal, never a silent promotion to owner.

Default bindings (so the common cases need zero config):
- `main` → `owner` profile. Unconfigured; behaves like today.
- `subagent` / `evaluator` → **inherit the spawner's full binding ∩ their Principal floor** — including
  the sandbox grant and the tool scope (C6: today `GoalEvaluator` drops the parent scope and never
  copies the sandbox grant, so the evaluator runs unconfined; the evaluator must inherit the parent
  Binding, not reset it). No per-subagent configuration. A spawner may *explicitly* drop a subagent
  into a narrower named profile, but never widen it.
- `a2aRemote` / `mcpGuest` → the named guest profile the route resolves to from the **authenticated,
  signature-verified** peer identity (§Peer identity).
- **Background conversations and reflection turns keep the owning binding (C7/C8)** — they do not
  reset to nil/owner. A background conversation whose `agentProfile` goes nil today runs as full owner;
  under v2 the binding is carried, and a guest/remote binding **never triggers reflection** that writes
  owner memory.

## The five routes (worked)

The same task ("review this PR") runs under five different profiles depending on who initiated it:

| # | Route | Principal | Profile resolved from | Ceiling |
|---|-------|-----------|----------------------|---------|
| 1 | Iris starts it herself | subagent (of her session) | her current profile, drop-to-narrower | her profile |
| 2 | Overseer session assigned a review | subagent/main of that session | the overseer session's configured profile | that profile |
| 3 | MCP guest asks | mcpGuest | the guest's authenticated `(transport,issuer,id)` → profile | guest profile ∩ mcpGuest floor |
| 4 | homelab A2A asks | a2aRemote | `homelab-peer`, from the **signature-verified** peer id | `homelab-peer` ∩ a2aRemote floor |
| 5 | GitHub webhook asks | (new) webhook | configured `github-webhook` profile, else **reject** | that profile, or nothing |

Route 5 generalizes: a new route with no established identity must map to a configured profile or be
refused. No anonymous trigger ever runs as owner.

## Credential registry (#966) — spend, never possess

Credentials become **typed accounts** in a registry, replacing the flat service→blob map. The audit's
central credential finding (C2) reshapes this section: the registry is not only *which account a
profile may use* but *how an account is spent without the secret ever being reachable*.

- Each account has a **type** (`github`, `google`, `openai`, …) and an **owner-class**: *owner-personal*
  (Brian's) or *service* (Iris's own bot identities).
- **Credentials are spent through host-side proxy tools, never handed to the model (C2).** For each
  account type, the spend surface is a typed tool with an allowlisted op set — e.g.
  `github_comment(repo, pr, body)`, `github_approve(repo, pr)` — implemented host-side, reading the
  Keychain itself. The secret value never enters a prompt, a tool argument, a tool result, the sandbox
  env, or `GH_TOKEN`. A profile's credential grant authorizes *which proxy ops it may call under which
  account*, not possession of a token.
- **Output scrubbing.** Any exact secret value is scrubbed from tool output and args that cross into a
  guest-bound context, as defence in depth (the primary defence is that the secret was never reachable).
- An `AccessProfile` is granted a **subset** of accounts. With one account per type per profile, the
  grant set alone decides which identity a call uses — no separate "active account" selector. (If a
  profile ever holds two accounts of one type, selection becomes explicit; avoid by default.)
- **Hard requirement — least privilege at the source (backstop, not the primary control).** The primary
  control is C2 (the secret is unreachable); the backstop if a proxy op is misused is the account's own
  scope. `Iris-github` is a scoped bot PAT; owner-personal full-access tokens never go in a profile a
  guest can hold. Granting a profile an account delegates that account's full op-set power to whoever
  holds the profile.
- **The Iris-review GitHub token (M2, Brian's decision).** For the review use case the reviewer profile
  carries a token scoped **`Issues: write` + `Pull requests: read`**, on the review repos only. Verified
  in the GitHub docs: that scope can post **PR conversation comments** (the issue-comment endpoint is
  satisfied by `Issues: write`) but **cannot approve** a PR (approve needs `Pull requests: write`) and
  **cannot post inline diff comments** (also `Pull requests: write`). So the default reviewer token is
  *comments-only*; enabling approve or inline comments is a deliberate escalation to `Pull requests:
  write`. To confirm with a sandbox test before shipping. This stacks with the C2 proxy
  (`github_comment` spends this token) and does **not** replace it. It also resolves M2's merge-path
  risk: a comments-only token cannot self-approve an injected PR into a merge.
- Keychain: accounts need an identity/scope dimension `KeychainManager` lacks today. Builder to
  design the storage (likely service-name-encodes-account plus a registry index); does not require
  the deprecated `SecAccessCreate` access-list APIs (zero-warnings rule forbids them). The denied-path
  set the FS layer enforces must include the credential stores themselves (C5): `~/.iris[-dev]`,
  `~/.config`, `~/.config/gh`, `~/.netrc`, `~/.git-credentials`, `~/.ssh`.

## Memory / knowledge scoping (#967) — enforced at the data layer

A Profile sees a **memory tier**, enforced **inside the tools and the store, keyed on the active
binding** — not at context assembly (H1/C4). v1 said "resolves at context assembly"; the audit showed
that misses every tool read path (the `search_memory` dispatch in `iris.swift` enforces no tier/`isPinned`
check; `scope:"all"` dumps every owner chat and background job) and ignores writes entirely.

- **Read tiers.** `owner` → full (facts, `USER.md`, all skills, library). internal named profiles
  (`overseer-team`, `reviewer`, `web-researcher`) → a configured slice; no personal `USER.md`/facts
  unless the task needs them. guest profiles → least: task context + at most a public "about Iris"
  blurb; **no** personal memory, facts, or private skills.
- **Enforcement points (data layer).** `search_memory` gates the facts branch on
  `binding.memory.contains(.shared)` and the conversations branch on `.contains(.conversations)` **and**
  `isPinned`. `read_file`/`write_file` consult the binding (see §FS). The `~/.iris` read carve-out in
  `PermissionManager.match` (auto-allows any read under `~/.iris` for any caller — the `~/.iris` carve-out) is
  **removed for non-owner** — a first-party read of Iris's own folder is no longer implicitly trusted.
- **No write-up (H1).** A lower tier writes only to its own namespace, which higher tiers never
  auto-load. A guest `save_fact`/`create_skill` must not be able to plant text that later injects into
  owner context. Reflection turns on a narrowed local binding are scoped to `profiles/<id>/memory.md`
  only — no `SOUL.md`, no `USER.md`, no skill creation, no `EventCard.reflection` into pinned Iris (C7).
- System-prompt assembly also leaks today (W1): `guardedUserProfileText` appends `USER.md` to every
  conversation incl. subagent/evaluator; `buildBasePrompt` loads `SOUL.md`/rules/all skills. Strip
  `USER`/`SOUL`/skills/rules from non-owner prompts; add the profile id and memory tier to
  `promptCacheKey` (it omits them today, so a cache entry leaks across tiers/peers); isolate durable
  a2a-remote lane history per `(peerId, contextId)`.

Builder to define the slice mechanism (namespaces/tags on memory items that a profile is granted, vs.
a coarse tier enum). Coarse tiers first; namespaces if a real case needs finer control.

## Peer identity (H4 — Iris verifies signatures itself)

**Brian's decision (2026-11-09): Option A.** Iris **verifies each inbound peer's Ed25519 signature
itself**, rather than trusting the A2A gateway's attestation of peer identity. This **reverses v1's
non-goal** ("cryptographic peer verification — the gateway does that upstream"), because the multi-user
trajectory means not every user runs the gateway, so "trust your own gateway" cannot ship. End-to-end
signature verification is the standard, generalizable answer.

- The gateway becomes a **relay**: it can drop, delay or reorder tasks, but holds no peer private key
  and can no longer impersonate a peer. The blast-radius argument that made H4 a finding (one bearer
  token → impersonate any mapped peer → inherit the union of their grants) is closed at the root.

**The contract is now committed — see romar#396 (`peer-signature-spec.md`, v2) for the byte-exact wire
format.** The earlier open item (canonical-payload shape) is retired: the reviewed design signs the
**exact transmitted bytes, verify-before-parse**, with no JSON canonicalization (stock encoders do not
agree across Python/Go/Swift). The wire frame, domain separator and codec live in romar; this doc
records only **Iris's verifier/signer obligations** at the design level.

- **Verify before parse, parse once.** Iris verifies the Ed25519 signature over the transmitted bytes
  **before** parsing the envelope, then parses once and acts only on that parsed object — never
  re-serializing a parsed tree or re-parsing for dispatch. The exact signing input is romar#396's.
- **Key bound to sender, within the principal's keyset.** The signing key id must equal the envelope's
  declared sender profile (mismatch ⇒ reject), and a key is resolved **strictly within that principal's
  registered keyset**, never a flat global key map — otherwise an enrolled peer could sign as another.
- **Iris-side verifier MUSTs** (the ones that land on our code): recipient binding (the envelope is
  addressed to `iris`); a present replay nonce and a strict RFC 3339 UTC timestamp; **reject duplicate
  JSON object keys** (whether Swift's `JSONSerialization`/`JSONDecoder` silently keep last-wins is
  **unverified** — the explicit scan is required regardless, and the macOS recheck below must cover
  duplicate-key behaviour, not just the outer frame); derive tier/permissions from Iris's **local** key/grant registry, never from the
  envelope's self-claimed authority; **fail closed** — a missing/invalid/unverifiable signature is
  hard-rejected, **never coerced to `guest`**, and relay-attested (gateway-vouched) traffic is rejected
  unless the user opted into a separate explicit "the gateway" profile. Every rejection logs a reason code.
- **Replay: deadline-bounded, not a fixed window.** The nonce goes in a **persisted, per-peer-bounded**
  seen-set, written **before** the task executes; the timestamp may not be in the future beyond a small
  skew; a required per-task deadline bounds lifetime (capped at 24 h). No `abs(now − ts)` window — a
  queued task can sit in the relay up to its deadline while the laptop sleeps, so a fixed window (correct
  for always-on peers) would reject every queued task on wake. A full seen-set rejects rather than
  evicts; a duplicate is rejected **and acked** (a nack makes the relay redeliver forever).
- **Bidirectional (new scope).** This is not verify-only: Iris must **enroll its own Ed25519 keypair and
  sign its outbound** tasks and replies (incl. disclosure answers), because the relay can forge an
  unsigned reply just as easily. The A2A client plan
  (`docs/superpowers/plans/2026-11-07-a2a-client.md`, Task 5) must be updated to add inbound verification
  **and** outbound signing, dropping its "Iris does no cryptography" assumption.
- **Enrollment.** A peer's public key is registered **out of band** in Iris's per-profile registry at the
  human-approved first grant (M5); the gateway's key distribution is explicitly **not** Iris's trust
  source. `(transport, issuer, id)` (M4) keys the mapping. CryptoKit provides Ed25519
  (`Curve25519.Signing`); the crypto is cheap — the work is the key/seen-set plumbing and outbound signing.
- **Iris-specific risks to settle in the plan:** recheck macOS `JSONSerialization` on the outer frame
  (the audit covered Linux Swift only); **vendor romar's single conformance vector** (incl. its
  negative-reason cases) by commit/CI fetch rather than hand-maintaining a drift-prone copy; accept
  **only** the new signed format from day one, no downgrade path.
- **Build-plan requirements carried from romar#399 (the H4 implementation plan must include these):**
  (1) **the seen-set fails closed on a bad store** — if the persisted seen-set exists but can't be read or
  parsed, refuse inbound frames and alert; never start empty (that silently reopens replay for everything
  still inside its deadline). Write it durably (fsync temp → rename → fsync dir). (2) **Peers pin Iris's key
  out of band** — the mirror of Iris's own enrollment rule: a peer must obtain Iris's public key out of band,
  never from the gateway's key bucket, or the relay can serve its own key as `iris` and forge Iris's replies.
  Iris's enrollment flow must produce and display its public key for that step. (3) **A duplicate after a
  crash gets a terminal status, not a re-run** — with write-before-execute, a task interrupted by a crash is
  redelivered and rejected as a duplicate; if no terminal status was ever posted for it, post
  `failed: interrupted` before acking so the caller isn't left waiting until the deadline.
- Because identity is now cryptographically verified, the earlier "Inbox-gate every credentialed action"
  sub-question becomes **optional defence-in-depth**, not a load-bearing control: forged-peer-via-gateway
  is no longer a path. Signing is identity + integrity only — a verified peer can still carry injected
  content (a PR diff), so the content/injection guards and the C2 spend-vs-possess invariant still apply
  to verified input.

## The disclosure broker (the proxy / escalation path)

A restricted profile that lacks a piece of information may **ask** for a redacted version over the
inter-agent bus, rather than being granted the underlying access. Motivating example: homelab (Clomp)
asks Iris for a flight time on a trip it cannot see; it explains its task, and Iris returns just the
time.

**The invariant that makes this safe: the decider is never the requester.** The disclosure decision
runs in a **separate owner-authority Iris session**, not under the requesting profile. The requester
receives a **vetted string as output** — never the access, never a handle, never a credential.

**The broker runs under a dedicated floor (H2).** The audit showed the broker is the most-privileged
run in the system, fed attacker-controlled task text, so it needs a *capability* floor, not just a
policy:

- **Owner memory READ only. ZERO acting tools.** The broker can read to answer; it cannot run a command,
  write a file, spend a credential, or reach a transport. Its only output channel is the returned string.
- **Output = string, then exact-secret scrub.** Before return, exact known-secret values are filtered
  from the string (mechanically enforceable). This is defence in depth on top of "no acting tools."
- **Per-peer disclosure rate/budget limits**, to bound oracle/aggregation attacks (composing many yes/no
  answers to reconstruct a denied class). A question that touches a deny class is refused **including its
  yes/no form**.
- **Log the question and the answer**, not just the answer, so an aggregation attack is auditable.

**The envelope** (honors Brian's ~70/30 functionality lean, but per-class, and *honest about what is
mechanically enforceable* — H2 flagged v1's "~100/0" as an overclaim, EPISTEMIC_HYGIENE §1):

- **Exact-value secrets are code-filtered (hard, mechanical):** credentials/tokens and other exact known
  values are removed with certainty.
- **Semantic classes are best-effort, not ~100/0:** raw `USER.md`, third-party PII, financial / auth /
  health content cannot be mechanically guaranteed un-disclosable by an LLM, so the spec says
  *best-effort semantic deny with a human gate for anything sensitive*, not "never crosses." The broker
  is instructed to refuse these classes, but the control that makes it safe is the zero-acting-tools
  floor plus the sensitivity dial, not a claim that the LLM is incorruptible.
- **Sensitivity dial:** low-sensitivity → auto-disclose within the envelope; higher → becomes an
  **Inbox item Brian approves** before it returns. Every disclosure is logged regardless. "Auto-disclose"
  means *without Brian in the loop* — it still requires a live owner-authority run to decide and read the
  source (see **R4**); with no owner context available it stays pending, never answered from a cache by a
  lesser authority.

## How each consumer plugs in

- **Profile pane (#961):** the editor for `AccessProfile`s and their grants across all axes. The one
  place the user configures the boundary. It is also the **only** writer of the protected profile/mapping
  store (H3) — no model-callable tool writes there.
- **Credential registry (#966):** the typed-account store a profile grants over; enforces owner-class,
  least-privilege, and the C2 proxy-tool spend surface. No tool ever receives a secret.
- **Memory scoping (#967):** resolves and **enforces** a profile's memory tier at the data layer
  (search_memory, the store, the file tools), with separate read and write axes.
- **MCP service (#965):** each connecting guest resolves to an `mcpGuest` Principal + a guest
  `AccessProfile` from its authenticated `(transport,issuer,id)`; tool/resource exposure is the profile's
  grant ∩ the floor. This boundary **requires** every guest connection to resolve to an authenticated
  identity → profile or be refused; it does not itself define MCP's guest-auth mechanism (that is #965's).
- **A2A inbound (plan Task 5):** `A2AInboundPolicy` becomes the per-route resolver for `a2aRemote` —
  **signature-verified** peer → profile, capped by floor. Its ordered table is this boundary's
  enforcement point for that route. Task 5 must add the signature verification (H4).
- **A2A / MCP outbound:** which peers a profile may *reach* is the transport axis of the grant.
- **Inbox:** the human-decision surface for disclosure approvals and the **default** first-grant of a
  new peer's profile + public key (M5).

## Existing fail-open seams this boundary must close

Not design abstractions — live escapes in `Sources/`, verified by the audit. The implementation plan
must close each, and the targeted re-review must confirm closure. This is the part that makes #974
larger than a spec revision.

- **C1 — ambient credentials.** `run_command` uses the process env (`gh` = `bnaylor`);
  `SandboxPolicy.resolve` returns `.host` for every principal when the sandbox switch is off
  (`SandboxPolicy.resolve` returns `.host` whenever the master switch is off); Google built-ins use Brian's ADC; MCP spawns the full env. An empty-grant
  guest still reaches most access. → non-owner executes only in the sandbox; every cred-bearing tool is a
  declared registry-account spend; an unclassified tool under a non-owner binding is denied.
- **C4 — `search_memory` bypass.** The `search_memory` dispatch in `iris.swift` enforces no `isPinned`/tier check. → gate at the
  data layer on the binding.
- **C5 — file tools never containerized.** `read_file` is always a host read (in `ToolExecutor`'s
  `read_file` execution); the sandbox grant is checked only `if isBackground` (in `AppState`); `ReadOnlyCommand`
  auto-approves `read_file` on any path; `JobGrant.resolve(mounts:[])` fails open; `deniedHomeSubpaths`
  omits the credential stores. → non-optional `FilesystemPolicy` (`.unrestrictedOwner | .confined(JobGrant)`)
  enforced regardless of `isBackground`; empty grant = confined; add the missing cred stores.
- **C6 — `GoalEvaluator` escape.** `flowTools` unconditionally allowed; `GoalEvaluator.evaluate` drops
  the parent tool scope and never copies the sandbox grant, so the evaluator runs grant==nil (RW
  workspace, full network, unconfined `read_file`), and its evidence flows back to the parent. → the
  evaluator inherits the parent's full Binding.
- **C7 — reflection-turn escape.** Every 10 messages `runReflection` grants a reviewer
  `update_soul`/`update_user_profile`/`update_memory`/`create_skill`, writes owner `~/.iris/memory`, and
  posts `EventCard.reflection` into pinned Iris (upward injection). → never reflect on a guest/remote
  binding; a narrowed local reflection is scoped to `profiles/<id>/memory.md` only.
- **C8 — three fail-open seams in `AgentProfile`/`AppState`.** background conversations drop
  `agentProfile` → nil (full owner); a missing/unreadable profile file fails open to nil; an omitted
  `tools:` key means *all tools* (and shipped reviewer/researcher/writer omit it). → any omitted grant
  key on a non-owner profile = deny-all; profiles enforced on background turns.

## Goals / non-goals / anti-goals

- **Goal:** one model every consumer consults; teamwork (credentialed inbound) safe by *construction*
  (the secret is unreachable, the identity is verified), not by a detector; the user configures only
  `AccessProfile`s; every default fails closed.
- **Non-goal:** per-Principal configuration UI; reworking the FS grant model (reuse it, de-globalize and
  scope it per profile). *(Removed from v1's non-goals: "cryptographic peer verification — the gateway
  does it." Per H4, Iris now does it.)*
- **Anti-goal:** a secret value ever reachable by the model; the task/payload influencing which profile
  it runs as; an anonymous or unmapped route running as owner; owner-personal full-access tokens
  reachable by a guest profile; a default (missing binding, omitted grant, unreadable profile) that
  resolves to owner or host; the disclosure broker holding any acting tool; claiming mechanical
  enforcement of a control that is only best-effort.

## Resolved after builder-check (2026-11-09)

A builder-check (fresh engineer reading this cold) raised five architecture questions. None required
a new decision from Brian; each resolves from decisions already made plus verified project state. **R2
is revised by the audit (H3).**

- **R1 — Sequencing vs the A2A plan.** #974 lands **first**. Verified `Principal.a2aRemote` and
  `A2AInboundPolicy` exist only in the 11-07 plan, not in `Sources/`; #931 is open and gated on the
  romar server spec. So there is no shipped code to refactor: A2A's Task 5 builds its inbound
  authorization *on* this boundary's generalized route→profile resolver, contributes the `a2aRemote`
  Principal case, and **adds signature verification (H4)**. #974 owns the resolver and the Principal
  additions; A2A owns the transport/SSE and the signed-envelope source. Matches the agreed sequence:
  inbox → boundary → MCP/A2A.
- **R2 — Where the binding lives (revised by H3).** The active binding is a **non-optional transient
  per-run context on the engine, built at the door** before the run starts. The profile id is also
  persisted on `Conversation` so a durable/named session keeps identity across reload — new field,
  `decodeIfPresent` (Invariant 1). **The audit correction:** the persisted field must **not** default
  `owner` for existing/missing rows — that is the fail-open seam H3 named. A missing/unreadable binding
  resolves **fail-closed** (non-main → refusal; the only thing that runs as owner is `main` with an
  explicit owner binding). `subagent`/`evaluator` inherit the spawner's live binding ∩ floor through
  `SubagentManager`. Every consumer reads the active binding at the data layer. *(planner's call)*
- **R3 — Per-profile FS vs the `.shared` `PermissionManager`.** In scope, and a notable-size item:
  per-profile roots mean FS checks must be consulted **with the run's profile**, so `PermissionManager`
  stops answering as a flat process-global (Invariant 7). This is also where C5 is closed (file tools
  containerized, the `isBackground`-only check removed). Mechanism (inject per-run vs. add a profile
  parameter) is builder-left, but the de-globalization is in scope and sized in the plan. *(planner's
  call; sizing flag)*
- **R4 — Disclosure-broker execution.** **Async, entailed by the sensitivity dial.** A
  disclosure-request is a bus message answered by a **per-request spawned owner-authority engine run**
  under the H2 broker floor (owner memory read, zero acting tools) — not a standing privileged daemon:
  immediately if a live owner context can take it, else it queues as an Inbox item. The requesting task
  waits within its deadline or gets a pending-ack. **Consequence, not a free choice:** on a single-machine
  install nothing answers a disclosure needing owner memory without a running owner-authority context, so
  there is **no auto-disclosure from a cache** — no owner context ⇒ pending (fail-closed to "later").
  *(planner's call — flagged for Brian's check because it sets the feel.)*
- **R5 — Identity→profile routing.** The mapping lives in the **protected profile store the #961 UI owns
  (H3)**, keyed on `(transport, issuer, id)` (M4). Each transport supplies the identity: A2A from the
  **signature-verified** peer id (H4); MCP guest from #965's own guest-auth design. This boundary
  **requires** every guest connection to resolve to an authenticated identity → profile or be refused
  (fail closed), but does not itself define MCP's auth; the GitHub-webhook route is illustrative/future
  and likewise must map or be rejected. First-grant of a new peer's profile + public key is **Inbox-gated
  by default** (M5). *(planner's call / scoping)*

## Re-review scope

The implementation plan is gated on a **targeted re-review of the sections this v2 changed** — the
enforcement invariants, credentials (C2/M2), memory (H1/C4), peer identity (H4), the broker floor (H2),
the fail-open-seams closures (C1/C5/C6/C7/C8), and the revised R2 — **not** another cold full-codebase
trace. The first audit's full depth (incl. Clomp's 31-minute trace) is the one-time cost the spine gets
once; re-review confirms the changed sections close the findings, nothing more.

## Left to the builder / to fine-tune later

- Keychain storage shape for typed accounts + owner-class, and the per-type proxy-tool op-sets (C2).
- Peer-signature verifier + outbound signer (H4) against the **committed** contract (romar#396,
  peer-signature-spec.md v2 "sign exact bytes"): the sign-exact-bytes codec, the verifier MUSTs, the
  persisted per-peer seen-set, Iris's own keypair + outbound signing, romar's vendored conformance
  vector, and the macOS `JSONSerialization` recheck on the outer frame. (The canonical-payload open item
  is retired — the contract signs exact bytes, no canonicalization.)
- Memory-slice mechanism (coarse tiers vs. granted namespaces); read/write axis representation (H1).
- The exact sensitivity-dial classification (which categories auto vs. Inbox); Brian's first cut:
  deny = creds / third-party PII / secrets; fine-tune as cases arise.
- Whether `AccessProfile`s are themselves persisted `Codable` (Invariant 1) and where (a new protected
  store vs. `ConfigManager`), given H3 requires they not be model-writable.
- The sandbox-test confirmation that `Issues: write` + `Pull requests: read` posts comments but cannot
  approve or inline-comment (M2).
- Invariant 9 sweep: new Principals/profiles/lanes must not contradict existing session/subagent docs
  or agent-facing strings.
