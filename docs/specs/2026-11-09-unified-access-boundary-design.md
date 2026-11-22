# Unified Access / Credential / Visibility Boundary — Design (#974)

**Status:** **v3 — revised after the targeted v2 re-review (2026-11-17, dev-2, verified against
origin/main).** The v2 three-layer shape (Principal / AccessProfile / Binding) and its audit-folded
invariants still hold. The targeted re-review the v2 gate required found **nine items (F1–F9) plus
code-claim corrections** that would have made the core-spine implementation plan wrong if drafted
straight off v2 — stale symbol names, invariants that overclaim or name no mechanism, and a retrofit
surface that grew since v2 shipped. This revision folds them in. Two Brian decisions fed it
(answered 2026-11-17): **2A** (= finding F1) scope invariant 1 to the non-owner binding, owner git path
a named exception; and **1B** — a *separate* finding from the live-floor safety check (NOT one of
F1–F9) — ship the #1195 guest-memory stopgap now. **The core-spine implementation plan
is written from THIS v3, not v2.** No spine code lands before the plan is approved (the epic gate is
unchanged; the re-review it gated on is now done).

**Execution state (2026-11-19):** the plan was approved and **Group A (the foundation — Tasks 1–5) is
MERGED** (#1201 + #1202). **Group B (the seam closures) is APPROVED** (Brian, option b: full Group B,
the memory-exfil tasks first; #1199 retires once they land) and in progress; **Group C (retrofit)
is not yet authorized.** Two implementation names differ from this spec's prose: the `Binding` type
shipped as **`AccessBinding`** (a `SwiftUI.Binding` collision), and the `Principal` floor shipped
**per-axis** — `AxisCap<Value> { unbounded / fixed(Value) / fromBinding }` with a cap per grant axis
(tools, credentials, memoryRead, memoryWrite, transports) rather than tools-only. Read `Binding`
below as `AccessBinding`; the per-axis floor is the shipped realization of this spec's "fail closed on
every non-owner axis" invariant.

## v3 changelog (what each finding changed)

- **F1 / 2A (Brian):** Enforcement Invariant 1 scoped to **non-owner** principals; owner `main`'s
  ambient-env `run_command` and the #966 git-credential-helper path recorded as a **named exception**
  (Brian 2026-11-15, "identity separation, not credential-hiding"). v2 stated a rule the owner path
  does not satisfy; v3 states the rule it actually enforces.
- **#1195-B (Brian):** near-term stopgap noted — strip the memory read/write tools on guest-origin
  turns now; the spine's C4/H1 data-layer enforcement subsumes it.
- **F2a:** Invariant 2 now names that `SandboxPolicy.resolve` returns `.host` for every principal
  when the master switch is off; the spine makes `resolve` ignore the master switch for non-owner and
  refuse (no host fallback).
- **F2b + broker:** the non-owner enforcement **template** is a positive allowlist + dispatch refusal
  (generalize `GuestToolset`), not the subagent/evaluator denylists; added a **`.broker` Principal**
  for the disclosure broker with a dispatch-enforced positive allowlist.
- **F3:** data-layer enforcement-point list expanded to the three memory **reads** (`search_memory`
  incl. the subagent path, `search_conversations`, `read_conversation`) and the **eight writers**, not
  just `search_memory`/`read_file`/`write_file`.
- **F4:** no-widen lattice chosen — **coarse ordered memory tiers**; FS-roots subset must define
  symlink/mount-overlap handling in the plan.
- **F6:** the new profile/mapping store and `a2a-peers` added to the protected-write set and
  `GuardedSettings.approvalWarning`.
- **F7:** the dangling `deniedHomeSubpaths` symbol (does not exist on main) replaced with the real
  mechanism and the new non-owner host-read denial set.
- **F8:** the M2 "comments-only" claim corrected — `Issues: write` reaches PR labels/state/title/body;
  sandbox test widened.
- **F9:** H4 crypto core recorded as built-but-uncalled (end-to-end untested); wiring is the A2A
  slice's job, a cross-slice dependency.
- **Corrections:** C7 cadence (30 not 10), C6 evaluator-not-subagent, C8(b) snapshot fallback,
  the ~/.iris carve-out is guest-origin not principal, the `promptCacheKey` omission.
- **Retrofit:** new section capturing that R1's "lands first, nothing to refactor" is now partly
  false (`.mcpGuest`, `ProviderTokenRegistry` roles, `A2ASeenLedger` already shipped).

**What carried from v2 unchanged:** the three-layer model, the six invariants' intent, the five
routes, the credential-registry/spend-never-possess shape, memory tiers, the H4 verifier obligations,
the disclosure-broker floor, and the goals/non-goals.

---

**Intent.** Iris is gaining several features that each need to answer the same question —
*which identity can reach which credentials, which memory/knowledge, and which transports/peers* —
and today there is no shared answer. The MCP service (#965), the A2A client both directions
(#931 + `docs/superpowers/plans/2026-11-07-a2a-client.md`), the profile edit pane (#961), the
credential registry (#966) and per-profile memory scoping (#967) are not independent: they are
consumers of one boundary. This document defines that boundary once, so each consumer consults a
single model instead of inventing its own policy. Build this before building any one consumer.

The motivating use case is teamwork: Iris acting as a real teammate — reviewing a PR under *her own*
GitHub identity when a trusted peer (homelab) asks. "Make it safe" is a *mechanism* claim, not an
*intent* claim: a detector (the injection guard) is not a boundary, and a default that leaks to owner
is not confinement.

## Current state (verified in code, re-verified 2026-11-17 on origin/main)

- `Principal` (the enum in `SandboxPolicy.swift`) is `{ main, subagent, evaluator, mcpGuest }`. **v2
  said three cases; `mcpGuest` landed since (#1066).** It is a payload-free enum with no grant/deny
  semantics — the per-principal rules are spread across call sites keyed on the case. The A2A plan
  still proposes `.a2aRemote` (not yet in code). The spine adds `.broker` (F2b).
- `KeychainManager` scopes secrets by `kSecAttrService` name only — **no** `kSecAttrAccess`, no
  per-item access lists (only generic-password class/service/account attrs). A typed-account registry
  can be built without the deprecated `SecAccessCreate` APIs. Note: `ProviderTokenRegistry` already
  keeps **guest role grants** beside the token in a separate Keychain item (`iris.mcp.provider.roles`)
  — grant data in an item, not an access list on it (retrofit item 2).
- The A2A client plan proposes `A2AInboundPolicy.decide(...) -> {autoAllow, needsApproval, hardBlock}`
  as an ordered table gated by `Principal.a2aRemote`. **Neither is in `Sources/` yet.** That ordered
  table is the closest existing shape to this boundary's per-route policy and should be generalized
  here, not duplicated per transport.
- **The existing codebase fails open in several places** (audit, re-verified). These are live escapes
  the boundary must *close*, enumerated in §Existing fail-open seams.
- **The GitHub-identity slice (#966 first consumer) shipped** (`GitHubProxyClient`,
  `GitHubIdentityMonitor`, the `github_*` proxy tools) — a working instance of spend-never-possess on
  one credential. It uses one token on `.main`; the typed-account registry generalizes it.

So this boundary is **net-new**, not a generalization of an existing grant model.

## Enforcement invariants (the spine — post-audit, re-reviewed)

A design that states a rule it does not mechanically enforce is a finding, not a boundary.

1. **Spend, never possess — for non-owner bindings (C2; scoped per F1/2A).** No credential secret is
   ever in **non-owner-reachable** state (not in a non-owner prompt, tool arg, tool result, env, or
   sandbox env). Non-owner credentials are spent only through **host-side proxy tools** (e.g.
   `github_comment(repo, pr, body)`) that read the Keychain themselves and return only non-secret
   results. **The axis is the BINDING, not the Principal:** a subagent running on the owner binding is
   owner for this purpose (it inherits owner's credentials — see default bindings); a subagent dropped
   into a named non-owner profile is bound by this invariant. **Named owner exception (Brian
   2026-11-15):** the owner binding — owner `main`, or a run that inherits it — runs `run_command` from
   the full process environment (ambient `gh`/`ssh`/etc. via `ToolExecutor.runCommand`/`hostSpawn`), and
   the #966 git path hands git the token through `GitCredentialHelperCLI.respond` on request. This is
   intentional — the goal is *identity separation*, not hiding credentials from the owner's own shell,
   which already holds them. The invariant binds every **non-owner** binding absolutely; it does not
   bind the owner binding. The injection guard is a **detector, not a boundary** (#952: ~96% of
   peer/inbox injections pass E2B) — it may alarm but never stands between an injected instruction and
   a secret.
2. **Fail closed, everywhere (C1/C5/C8/H3; mechanism named per F2a/F2b).** A missing binding, missing
   grant key, unmapped route, unclassified tool, or unreadable profile — every one denies, never
   defaults to owner or host. **Today `SandboxPolicy.resolve` returns `.host` for every principal when
   the master sandbox switch is off, and `.host(warnNoRuntime:)` when on with no runtime** (refused
   only under `refusesHostWithoutRuntime`, #678) — the guest is safe today only because it is never
   given `run_command`. Under the spine, `resolve` **ignores the master switch for non-owner
   principals and refuses rather than falling back to host.** Non-owner principals execute **only** in
   the sandbox; there is no host fallback for them. **Unclassified-tool denial has a mechanism, not a
   hope:** the template for every non-owner principal is `GuestToolset`'s **positive allowlist plus
   dispatch-side refusal** (F2b), not the subagent/evaluator denylists (`mainOnlyDeclared`,
   `unattendedNeverDeclared`, `hardStrip`), under which a newly-added tool is allowed to a subagent
   unless someone remembers to deny it.
3. **Enforce at the data layer, not at prompt assembly (C4/C5/H1; list completed per F3).** Memory
   tier, FS roots and credential scope are checked inside the tools and the store, keyed on the active
   binding. The enforcement points are **the memory READS — `search_memory` (including the subagent
   path — not in `mainOnlyDeclared` today, so a subagent gets the same unscoped `scope:all`),
   `search_conversations`, `read_conversation` (ungated today — the #1195 exfiltration surface); the
   eight memory WRITERS — `save_fact`, `manage_fact`, `update_memory`, `update_user_profile`,
   `update_soul`, `create_skill`, `update_skill`, `delete_skill` (held by human approval under the #813
   context holds on a tainted conversation today, but not *scoped by profile tier* — the spine replaces
   the approval prompt with a mechanical tier check; the H1 no-write-up surface); `read_file`,
   `write_file`; and credential selection.** A tool that reads or writes data consults the binding
   itself; it cannot be fixed by what the prompt does or does not contain.
4. **Per-axis no-widen, in code (C3; lattice chosen per F4).** "Narrower" means every axis —
   credentials, memory, transports, filesystem, tools — of the target is a subset of the source. The
   **memory axis uses coarse ordered tiers** as its lattice (namespaces deferred to "if a real case
   needs finer control"); the **FS axis** is set-subset over roots, and the plan **must define
   symlink-resolution and mount-overlap handling** for that subset test. A drop into a named profile
   is refused unless provably a sub-grant on every axis. No-widen is a code path, not a convention.
5. **Identity is authenticated and never self-asserted (confused-deputy; M4).** The profile is a
   property of the initiating authority, resolved from authenticated identity and stamped before the
   engine runs. The task/message body can never name its own profile. Identity keys on
   `(transport, issuer, id)`. **The guest door already does this** — bearer token → `clientId`, engine
   stamped at creation (`makeGuestEngine`), `principalMismatch` checked at the single `processInput`
   chokepoint (#1124) — that chokepoint is the natural place to enforce the Binding. (Gap F5: the
   shipped guest identity is only a `clientId`, not `(transport, issuer, id)` — retrofit item 3.)
6. **The owner is reachable only by `main`; policy is not model-writable (H3; hardened per F6).**
   Profiles and identity→profile mappings live in a protected directory that only the #961 UI writes;
   no model-callable tool can modify a grant or a mapping. `write_file` into `~/.iris/config/` is a
   protected write that always asks (`isProtectedWrite`), and `a2a-peers` sits under it — **but a host
   `run_command` can still write there, gated only by approval and not flagged the way
   `GuardedSettings.approvalWarning` flags commands naming Iris's own settings (F6).** The new
   profile/mapping store must be added to **both** the protected-write set and the `approvalWarning`
   set; `a2a-peers` is **already** in the protected-write set (`protectedWriteDirs` via `configDir`,
   verified on origin/main) — only the `approvalWarning` half is new for it.

## The model: three layers

### 1. Principal — the fixed code floor
A `Principal` is the *execution context* the engine tracks: `main`, `subagent`, `evaluator`,
`mcpGuest` (shipped), plus new `a2aRemote` (A2A slice) and **`broker`** (this spine, for the
disclosure broker — F2b/R4/H2). It is **not a user-configurable surface.** It carries the
non-negotiable caps true for that context regardless of profile — e.g. `a2aRemote`/`mcpGuest`/`broker`
never run in the foreground, always hard-strip, run in an isolated lane, and **execute only in the
sandbox (no host fallback, C1)**. Each non-owner Principal is defined by a **positive allowlist
enforced at dispatch** (the `GuestToolset` template), never a denylist.

Per-Principal rules are **fixed in code** (Brian: fine until it causes a problem). A blanket
per-Principal deny lives here as a floor, never as a config pane. The floor is a *cap*, never a grant.

### 2. AccessProfile — the user-configured grant
The grant type is named **`AccessProfile`** (M3) to keep it distinct from the existing `AgentProfile`
(#465, which only narrows *prompts*), `JobProfile`, and the A2A `from.profile` field. It is a named,
user-created identity — **the only thing the user configures** (the #961 pane) — granting over:

- **Credentials:** a subset of the typed accounts in the registry. A grant authorizes the *proxy
  tool* that spends the account; it never exposes the secret.
- **Memory / knowledge:** which memory tier/namespace it may read, and which it may write —
  separate axes (no-write-up, H1).
- **Transports/peers:** which MCP guests / A2A peers it may reach, inbound and outbound; whether it
  may send a disclosure-request to the owner broker.
- **Filesystem:** read/write roots — reuses the existing grant/workspace model (`PermissionManager`,
  `WritableRoots`), **de-globalized and consulted per binding** (R3).
- **Skills / library / tools:** which are available (floor still caps the Principal-forbidden ones).

**Any omitted grant key on a non-owner profile means deny-all for that axis (C8), never all-access.**
Today `AgentProfile` with `tools:` omitted means *all tools*, and the shipped reviewer/researcher/
writer profiles omit it — that exact default is a fail-open seam; `AccessProfile` inverts it.

Examples: `owner` (full; what `main` runs as), `overseer-team`, `web-researcher` (web + read-only FS,
no creds), `reviewer` (carries `Iris-github`, not `Brian-github`), `homelab-peer`, `research-guest`.

### 3. Binding — a run acts *as* an AccessProfile, capped by its Principal floor
Rights live on the AccessProfile; the Principal floor sets how low the ceiling is. The binding is
**non-optional and built at the door (H3)** — a run with no binding is refused, never run as owner.

- **The profile is a property of the initiating authority, never of the task.** Every entry point
  resolves route → profile from *authenticated identity* and stamps it before the engine starts. The
  task/message body can never name its own profile. This is the confused-deputy defense, at every
  door, not in the model.
- **No-widen, per axis, in code (C3).** A run may voluntarily drop to a narrower profile; it can never
  raise. An unmapped external route gets nothing — **fail closed.**
- **Owner only from `main` (H3).** The `owner` profile is reachable only by the `main` Principal.

Default bindings:
- `main` → `owner` profile. Unconfigured; behaves like today.
- `subagent` → **inherits the spawner's full binding ∩ Principal floor** — `SubagentManager` already
  copies the sandbox grant + workspace; the spine adds the memory/credential axes. **`evaluator`
  does NOT inherit today (C6):** `GoalEvaluator.evaluate` sets no sandbox grant, so the evaluator runs
  grant==nil (RW workspace, full network, unconfined `read_file`) and is containerized only when
  sandboxing is on — the evaluator must be changed to inherit the parent Binding. (v2 said
  "subagent/evaluator inherit"; true for the subagent, false for the evaluator — corrected.)
- `a2aRemote` / `mcpGuest` / `broker` → the named profile the route resolves to from the
  **authenticated, signature-verified** identity (§Peer identity), capped by floor.
- **Background conversations and reflection turns keep the owning binding (C7/C8)** — they do not
  reset to nil/owner. Reflection fires every **30** messages (`AppState.sendMessage`), not 10, and the
  `!isGuest` check already stops it for guests; the seam is `AppState.reflectionTools` /
  `AgentToolScope(reflecting:)`, which exempts the five memory writers from a profile's `tools:`
  narrowing — a reviewer profile on a reflection turn still gets them. A guest/remote binding never
  triggers owner-memory reflection.

## The five routes (worked)

| # | Route | Principal | Profile resolved from | Ceiling |
|---|-------|-----------|----------------------|---------|
| 1 | Iris starts it herself | subagent | her current profile, drop-to-narrower | her profile |
| 2 | Overseer session assigned a review | subagent/main | the overseer session's configured profile | that profile |
| 3 | MCP guest asks | mcpGuest | the guest's authenticated `(transport,issuer,id)` → profile | guest profile ∩ mcpGuest floor |
| 4 | homelab A2A asks | a2aRemote | `homelab-peer`, signature-verified peer id | `homelab-peer` ∩ a2aRemote floor |
| 5 | GitHub webhook asks | (new) webhook | configured `github-webhook` profile, else **reject** | that profile, or nothing |

**Route-3 recipient gap (F3b — must be in the plan):** route 3 resolves the binding of the *guest's
own engine*. But a guest's real effect is a `send_to_session` message that runs as a **`.main` turn on
a role session** — and the table never says what binding *that recipient turn* runs under. Today it is
only the `isGuestOriginTurn` flag (which gates the approval ladder + github tools, nothing else — the
#1195 hole). **The Binding stamp must carry the turn's origin** so the recipient turn is bound, not
just flagged. The #1195-B stopgap (below) closes the immediate memory-tool leak while the spine builds
the full recipient binding.

## Credential registry (#966) — spend, never possess

Credentials become **typed accounts** in a registry, replacing the flat service→blob map.

- Each account has a **type** (`github`, `google`, `openai`, …) and an **owner-class**: *owner-personal*
  or *service* (Iris's own bot identities).
- **Credentials are spent through host-side proxy tools, never handed to the model (C2, non-owner).**
  The spend surface is a typed tool with an allowlisted op set (e.g. `github_comment`, `github_approve`)
  reading the Keychain itself. The shipped `GitHubProxyClient` is the worked example; its `sanitize`
  output-scrub is **per-client only — the generalized cross-context scrub is not built** and is spine
  work.
- An `AccessProfile` is granted a **subset** of accounts; with one account per type per profile the
  grant set alone decides identity (no separate selector).
- **Least privilege at the source (backstop).** `Iris-github` is a scoped bot PAT; owner-personal
  full-access tokens never go in a guest-holdable profile.
- **The Iris-review GitHub token (M2 — corrected per F8).** The reviewer profile carries a token
  scoped **`Issues: write` + `Pull requests: read`** on the review repos. It **can** post PR
  conversation comments and **cannot** approve (approve needs `Pull requests: write`) or post inline
  diff comments. **It is likely NOT "comments-only":** `Issues: write` is believed to also reach a PR's
  **labels, state, title and body** (dev-2's reading of the API — **UNVERIFIED** until the widened
  sandbox test runs), and labels drive `hold`/the auto-merge arm hook, so a comments-scoped token may be
  able to toggle a merge gate. The planned sandbox test must be **widened to cover label, close and edit
  calls**, not just comment-vs-approve. **Backstop (partial):** the `main` ruleset requires code-owner
  review (count 1, dismiss-stale on), so a token holder cannot manufacture an approval or merge an
  *un*-approved PR. **But** removing `hold` from an **already-approved** PR re-arms it on the existing
  approval (the arm workflow reacts to label events) → it merges — so the backstop does NOT cover an
  approved-then-held PR; that case is exactly what the widened test must probe. The #1186 rename path is
  the other caveat, tracked separately and gating enablement.
- **Keychain storage (F7-adjacent):** accounts need an identity/scope dimension `KeychainManager`
  lacks; builder designs the storage (service-name-encodes-account plus a registry index), no
  deprecated `SecAccess` APIs. **The denied-path set the FS layer enforces** must include the
  credential stores — and here the v2 symbol is wrong: **`deniedHomeSubpaths` does not exist on main.**
  The nearest is `JobGrant.credentialStores` (18 entries on origin/main) which only refuses *mounting* a store into a
  job grant, lacks `~/.netrc` and `~/.git-credentials`, and **does not restrict host `read_file` at
  all** (a store is still readable via approval or an allowlist rule). The **non-owner host-read denial
  set is NEW work** (F7): add `~/.netrc` + `~/.git-credentials` + `~/.iris[-dev]`/`~/.config`/
  `~/.config/gh`/`~/.ssh`, and make it gate host `read_file` for non-owner bindings.

## Memory / knowledge scoping (#967) — enforced at the data layer

A Profile sees a **memory tier**, enforced **inside the tools and the store, keyed on the active
binding** (H1/C4) — not at context assembly.

- **Read tiers.** `owner` → full. internal named profiles → a configured slice; no personal
  `USER.md`/facts unless the task needs them. guest profiles → least: task context + at most a public
  "about Iris" blurb.
- **Enforcement points (data layer, completed per F3).** `search_memory` gates facts on
  `binding.memory.contains(.shared)` and conversations on `.contains(.conversations)` **and**
  `isPinned` — **including the subagent path** (today `search_memory` is not in `mainOnlyDeclared`, so
  a subagent gets unscoped `scope:all`; `search_conversations` and `read_conversation` read the same
  owner data and are gated the same way). The **eight memory writers** (`save_fact`, `manage_fact`,
  `update_memory`, `update_user_profile`, `update_soul`, `create_skill`, `update_skill`, `delete_skill`)
  each consult the binding (none consults a per-profile binding today; the #813 context holds gate them
  by **human approval** on a tainted conversation — not by profile tier — so the spine replaces an
  approval prompt with a mechanical tier check; the H1 no-write-up surface). `read_file`/`write_file`
  consult the binding.
- **The `~/.iris` read carve-out** in `PermissionManager.match` auto-allows any read under `~/.iris`;
  it is skipped **only for a guest-origin turn (#1150), NOT by principal.** "Removed for non-owner"
  requires the **principal passed into `PermissionManager.match`** — that is R3's de-globalization;
  size it there.
- **No write-up (H1).** A lower tier writes only to its own namespace. Reflection on a narrowed local
  binding is scoped to `profiles/<id>/memory.md` only — no `SOUL.md`/`USER.md`/skill creation/pinned
  reflection (C7).
- **System-prompt + cache leaks (W1).** All three still hold for non-guest principals (subagents and
  evaluators included): `guardedUserProfileText` appends `USER.md`, `buildBasePrompt` loads
  `SOUL.md`/rules/all skills. Strip `USER`/`SOUL`/skills/rules from non-owner prompts. **`promptCacheKey`
  hashes `principal|jobProfile|toolNames` with NO profile id or tier** — a cache entry leaks across
  tiers/peers; the fix must add the profile id and tier to the key. Isolate durable a2a-remote lane
  history per `(peerId, contextId)`.

**#1195-B stopgap (shipping now, Brian 2026-11-17; #1199).** Ahead of the full data-layer spine, **23
tools** — 11 memory (reads `search_memory`/`search_conversations`/`read_conversation` + the 8 writers;
`reflect` excluded as verified-inert), **10 Google** (`GoogleWorkspaceManager`/`GoogleTasksManager` reads
+ outbound-gated writes — dev-3 found these run with **no approval step**, so a guest-steered role
session could read owner **mail/Drive/calendar/tasks**, worse than the memory reads), and
`list_jobs`/`get_job_run` — are **stripped on guest-origin turns** via `hardStrip` **and** a dispatch-side
refusal, using a single source-of-truth `ToolExecutor.guestOriginDeniedTools` set (mirroring
`githubProxyTools`), with a test that every tool the Google managers declare is covered.
**Reconciled (#1224, 2026-11-22):** the 11 memory tools came OFF this list once `MemoryBindingGate` was shown to refuse each of them on a guest-steered `.main` turn with the tool offered (live per-tool tests with a gate-removal mutant); `list_sessions`, `describe_session`, `schedule_job` and `register_directory_watcher` went ON (#1293, #1294); the 10 Google tools and `list_jobs`/`get_job_run` stay until the binding-based tool gate (#1015 gap A) exists.
**What the strip actually closes (corrected mid-build, verified on origin/main):** the **reads** are the
real ungated exfiltration path — a granted-role guest steering a role session's
`search_memory`/`search_conversations`/`read_conversation` to pull owner memory out. The **writes** are
already held for human approval by the #813 context holds (`ContextHolds.heldTools` +
`holdContextWriteIfTainted`, on any guest/peer-touched conversation; YOLO the only bypass) — the strip
covers them for defence-in-depth and to remove the approval-fatigue surface, not because they were
unguarded. One narrow residual (a YOLO-mode reflection turn skipping the holds) is tracked as **#1197**.
**What the strip does NOT close:** it removes tool-reachable memory, but the role session's own system
prompt still carries owner context (`USER.md`, `SOUL.md`, `memory.md`, skills, rules) on any `.main`
turn, which a guest-steered reply can still recite — closed only by the spine's W1 non-owner prompt
binding plus the F3b recipient-binding of the role turn. (JIT fact retrieval does *not* run on
peer/guest messages — `retrievesFacts` requires `source == "UI"` — so no facts are injected there.) The
spine's C4/H1 data-layer enforcement (which *scopes* by tier rather than blunt-strips) subsumes the
strip. **The stopgap is a DENYLIST — bounded, not complete (F2b).** It enumerates the known-dangerous
tools; it does NOT cover MCP tools the user adds, future tools, or the already-asking tools
(`run_command`/`read_file`/`write_file`/job-creation/`invoke_subagent`). Each new finding adds a name —
exactly the F2b problem. **Only the spine's positive recipient-turn allowlist (the F3b binding of a
guest-steered `.main` turn, plan Task 15) closes it completely**; the stopgap buys bounded time until
the spine lands.

Builder defines the slice mechanism: **coarse tiers first** (the F4 lattice); namespaces only if a
real case needs finer control; read/write as separate axes.

## Peer identity (H4 — Iris verifies signatures itself)

**Brian's decision (2026-11-09): Option A.** Iris verifies each inbound peer's Ed25519 signature
itself, rather than trusting the A2A gateway. The gateway becomes a relay holding no peer private key.

**The contract is committed and shipping — romar#396 (`peer-signature-spec.md`, v2, "sign exact
bytes, verify-before-parse", no JSON canonicalization); implemented in gateway/client via romar#399,
refined through romar#407.** This doc records Iris's verifier/signer obligations at the design level
(unchanged from v2): verify-before-parse over transmitted bytes; key id = sender within the
principal's keyset; recipient binding split by direction (romar §5.1); kind↔channel binding; replay
nonce + strict RFC 3339 UTC timestamp; reject duplicate JSON object keys (explicit scan; the macOS
`JSONSerialization` recheck must cover duplicate keys); deadline-bounded replay with matched
acceptance/retention windows; full-rejects-rather-than-evicts; fail-closed on missing/invalid
signature (never coerced to `guest`); bidirectional (Iris enrolls its own keypair and signs outbound);
out-of-band enrollment keyed `(transport, issuer, id)`; no gateway-key fallback. The four build-plan
requirements stand (fail-closed seen-set surviving restart; peers pin Iris's key; interrupted →
terminal `failed: interrupted` status; outbound signing gated on romar#403).

**F9 — the crypto core is built but has NO caller.** `PeerSignatureVerifier`, `PeerSigner`,
`PeerKeyRegistry`, `IrisSigningKeyStore` and `A2ASeenLedger` (in `Sources/IrisKit/A2A/Crypto/`, wired
to `ConversationStore`'s GRDB writer and `IrisPaths`) are **referenced only by tests** — so the
persisted seen-set is never written in production and H4's end-to-end claim is untested because **no
inbound path exists.** Absent as the spec's own build-plan predicted: duplicate-ack + `failed:
interrupted` transport status, peer-pinning of Iris's key, and the enrollment UI/CLI. The
`A2ASeenLedger` fail-closed-on-bad-store behaviour is correct by reading but has **no restart test** —
"survives a restart" is inferred; the plan must add that test. **Wiring the verifier into an inbound
path + the restart test is the A2A slice's (#931) job, not the core spine's** — this is a **cross-slice
dependency**, not a spine blocker. (Spec wording nit: "key id must equal the sender" is implemented as
"a key inside the sender's own keyset," which the next sentence already says — align the prose.)

## The disclosure broker (the proxy / escalation path)

A restricted profile that lacks information may **ask** for a redacted version over the inter-agent
bus. **The invariant that makes this safe: the decider is never the requester** — the decision runs in
a **separate owner-authority run**, and the requester receives a **vetted string**, never the access.

**The broker runs under a dedicated floor (H2) — and now a dedicated Principal (F2b).** v2 said "a
per-request owner-authority engine run with zero acting tools" but named no Principal; running it as
`.main` stripped by declaration repeats the denylist gap. **Add a `.broker` Principal** whose positive
allowlist (owner memory READ only, ZERO acting tools) is **enforced at dispatch**, not by declaration
stripping. Output = string then exact-secret scrub; per-peer disclosure rate/budget limits; a question
touching a deny class is refused including its yes/no form; log question and answer.

**The envelope** (per-class, honest about mechanical enforceability — H2): exact-value secrets are
code-filtered (hard); semantic classes (raw `USER.md`, PII, financial/auth/health) are best-effort
semantic deny with a human gate, *not* "never crosses." Sensitivity dial: low → auto-disclose within
the envelope (still a live owner-authority run, R4); higher → an Inbox item Brian approves. No
auto-disclosure from a cache by a lesser authority.

## How each consumer plugs in

- **Profile pane (#961):** the editor for `AccessProfile`s; the **only** writer of the protected
  profile/mapping store (H3).
- **Credential registry (#966):** the typed-account store; enforces owner-class, least-privilege, the
  C2 proxy-tool spend surface. The shipped GitHub slice is its first instance (one token on `.main`
  today; a per-profile token needs the registry).
- **Memory scoping (#967):** resolves and enforces a profile's memory tier at the data layer, separate
  read/write axes.
- **MCP service (#965):** each guest resolves to `mcpGuest` + a guest `AccessProfile` from its
  authenticated `(transport,issuer,id)`; exposure is the profile's grant ∩ floor.
- **A2A inbound (plan Task 5):** `A2AInboundPolicy` becomes the per-route resolver for `a2aRemote`,
  signature-verified; **it must wire the already-built H4 verifier (F9).**
- **A2A / MCP outbound:** the transport axis of the grant.
- **Inbox:** the human-decision surface for disclosure approvals and the default first-grant of a new
  peer's profile + public key (M5).

## Retrofit — R1's "lands first, nothing to refactor" is now partly false

Since v2, H4-crypto and the MCP provider/guest-session track shipped standalone, *beside* the spine.
The spine plan must account for:

1. **Principal retrofit is clean.** `.mcpGuest` and its positive floor exist; the spec's guest cases
   only need to attach a Binding to an existing principal, and `principalMismatch` at the
   `processInput` chokepoint (#1124) is the door to stamp it.
2. **Two grant stores would coexist.** Shipped guest reach is `ProviderTokenRegistry.roles(forClientId:)`
   in a Keychain item (`iris.mcp.provider.roles`); the spec wants `AccessProfile`s in a protected
   directory only #961 writes. **The plan must say which store wins and how existing roles migrate.**
3. **Identity key.** Shipped guest identity is just a `clientId`; needs the `(transport, issuer, id)`
   key and the `AccessProfile` mapping (F5).
4. **Route-3 recipient binding (F3b).** The guest's real effect is a `.main` turn on a role session,
   today carried only by the `isGuestOriginTurn` flag; the Binding stamp must carry the turn's origin.
   The #1195-B stopgap bridges this until the spine lands.
5. **`A2ASeenLedger` already exists** — R1's a2a half of "nothing to refactor" is false in the other
   direction too: the library is ready; the missing parts are its caller, `A2AInboundPolicy` and
   `Principal.a2aRemote` (A2A slice). Not an obstacle.
6. **`.broker` Principal** (F2b/R4/H2) — new, positive-allowlist at dispatch.

## Existing fail-open seams this boundary must close

Live escapes in `Sources/`, re-verified. All still exist (with the corrections below). The plan must
close each; the spine owns C1/C4/C5/C6/C7/C8.

- **C1 — ambient credentials.** `run_command` uses the process env; `SandboxPolicy.resolve` returns
  `.host` for every principal when the master switch is off (and `.host(warnNoRuntime:)` when on with
  no runtime); Google built-ins use Brian's ADC; MCP spawns the full env. → non-owner executes only in
  the sandbox; `resolve` ignores the master switch for non-owner and refuses; every cred-bearing tool
  is a registry-account spend; an unclassified tool under a non-owner binding is denied by positive
  allowlist.
- **C4 — `search_memory` bypass.** No `isPinned`/tier check, and the subagent path is unscoped. → gate
  at the data layer on the binding, subagent path included.
- **C5 — file tools never containerized.** `read_file` is always a host read; the sandbox grant is
  checked only `if isBackground`; `ReadOnlyCommand` auto-approves `read_file` on any path;
  `JobGrant.resolve(mounts:[])` fails open; the credential stores are not in any host-read denial set
  (F7). → non-optional `FilesystemPolicy` enforced regardless of `isBackground`; empty grant =
  confined; the new non-owner host-read denial set (with `~/.netrc`/`~/.git-credentials`).
- **C6 — `GoalEvaluator` escape.** The evaluator sets no sandbox grant (`GoalEvaluator.evaluate`), so
  it runs grant==nil, containerized only when sandboxing is on. (Subagents **do** inherit the grant +
  workspace via `SubagentManager` — corrected.) → the evaluator inherits the parent Binding.
- **C7 — reflection-turn escape.** Every **30** messages, `AgentToolScope(reflecting:)` exempts the
  five memory writers from a profile's `tools:` narrowing and can write owner memory / post pinned
  reflection. (`!isGuest` already stops it for guests.) → never reflect on a guest/remote binding; a
  narrowed local reflection writes `profiles/<id>/memory.md` only.
- **C8 — fail-open defaults in `AgentProfile`/`AppState`.** (a) background conversations drop
  `agentProfile` → nil (full owner), still true. (b) a missing profile file falls back to the **last
  good snapshot with a notice**, failing open to nil only if no snapshot exists — rare, softened from
  v2. (c) an omitted `tools:` key means *all tools* (shipped reviewer/researcher/writer omit it), true.
  → any omitted grant key on a non-owner profile = deny-all; profiles enforced on background turns.

## Goals / non-goals / anti-goals

- **Goal:** one model every consumer consults; teamwork safe by construction (the secret is
  non-owner-unreachable, the identity is verified), not by a detector; the user configures only
  `AccessProfile`s; every non-owner default fails closed.
- **Non-goal:** per-Principal configuration UI; reworking the FS grant model (reuse, de-globalize,
  scope per profile).
- **Anti-goal:** a secret value reachable by a **non-owner** binding; the task/payload influencing
  which profile it runs as; an anonymous/unmapped route running as owner; owner-personal full-access
  tokens reachable by a guest; a non-owner default resolving to owner or host; the disclosure broker
  holding any acting tool; claiming mechanical enforcement of a best-effort control.

## Resolved after builder-check (2026-11-09; R2 clarified per re-review)

- **R1 — Sequencing vs the A2A plan.** #974 (the spine) lands first on the route→profile resolver and
  the Principal additions; A2A's Task 5 builds inbound authorization on it, contributes `a2aRemote`,
  and wires the H4 verifier (F9). **Caveat added:** "nothing to refactor" is now partly false — see
  §Retrofit (`.mcpGuest`, `ProviderTokenRegistry` roles, `A2ASeenLedger` already shipped).
- **R2 — Where the binding lives (clarified).** A **non-optional transient per-run context on the
  engine, built at the door.** The profile id is persisted on `Conversation` (`decodeIfPresent`,
  Invariant 1) for durable sessions. **A decoded nil means "no persisted profile," NOT "missing =
  owner"** — `main` gets its owner binding explicitly at the door; a missing/unreadable binding on a
  non-main principal is a refusal. **Guest conversations are ephemeral** (`isGuest`/`guestClientId` not
  in `CodingKeys`, dropped from `durableConversations`), so R2 persistence never applies to them —
  their Binding is always transient. *(planner's call)*
- **R3 — Per-profile FS vs the `.shared` `PermissionManager`.** In scope, notable-size: FS checks must
  be consulted **with the run's profile** (Invariant 7), so `PermissionManager` stops answering as a
  flat process-global; this is where C5 is closed and where the `~/.iris` carve-out is made
  principal-aware (pass the principal into `match`). Mechanism builder-left; the de-globalization is
  sized in the plan. *(planner's call; sizing flag)*
- **R4 — Disclosure-broker execution.** Async; a per-request spawned **`.broker`-Principal**
  owner-authority run (positive allowlist, zero acting tools), not a standing daemon. No owner context
  ⇒ pending (fail-closed to "later"). *(planner's call — flagged for Brian's feel-check in v2, stands.)*
- **R5 — Identity→profile routing.** The mapping lives in the protected profile store #961 owns (H3),
  keyed `(transport, issuer, id)` (M4). Every guest/peer route must resolve to an authenticated
  identity → profile or be refused. First-grant is Inbox-gated (M5). *(planner's call / scoping)*

## Open questions / flags for the plan (not resolved in this spec)

- The plan sizes the spine: Principal floor + `.broker`, non-optional Binding built at the door,
  `AccessProfile` type + protected store, the fail-closed resolver, the C1/C4/C5/C6/C7/C8 closures,
  R3's `PermissionManager` de-globalization, the generalized output scrub, the non-owner host-read
  denial set, the `promptCacheKey` fix.
- The M2 sandbox test (widened per F8: comment/approve/label/close/edit) must run before the reviewer
  token's scope claim ships.
- The ProviderTokenRegistry-roles vs AccessProfile-store migration (retrofit 2) needs a decision in
  the plan.
- Cross-slice: the A2A slice wires + e2e-tests the H4 verifier (F9); the #1186 CODEOWNERS-rename path
  gates #966 enablement (tracked separately).
- **Guest spend limits are not durable:** the guest's daily token cap and hourly bucket are in-memory
  and reset on restart (`GuestSpendLedger`) — the plan should decide whether the boundary requires
  durable per-profile budgets (cf. #1135).
- **MCP listener unverified:** the loopback binding, token compare and idle reap in
  `IrisMCPProviderServer` were not verified in the re-review — the MCP slice (#965) must verify them.

## Re-review status

The v2 gate ("no code until a targeted re-review of the v2-changed sections passes") is **satisfied by
the 2026-11-17 re-review**, which did not clean-pass: it surfaced F1–F9 + corrections, folded here as
v3. The implementation plan is written from v3. A further cold full-codebase trace is **not** required
(the one-time audit depth was spent in v2); a builder-check of v3 and the plan is.

## Left to the builder / to fine-tune later

- Keychain storage shape for typed accounts + owner-class, per-type proxy-tool op-sets, the
  **generalized** output scrub (C2).
- The non-owner host-read denial set (F7) and the `FilesystemPolicy` (C5).
- `PermissionManager` de-globalization + principal-aware `match` (R3).
- Memory-slice mechanism (coarse tiers first, F4); read/write axis representation (H1); the
  `promptCacheKey` profile-id/tier addition (W1).
- The ProviderTokenRegistry→AccessProfile migration (retrofit 2); the `(transport,issuer,id)` guest
  identity key (F5).
- Whether `AccessProfile`s are persisted `Codable` + where (a protected store, not model-writable, H3).
- The widened M2 sandbox test (F8).
- Cross-slice (not spine): the A2A inbound path + H4 wiring + restart test (F9).
- Invariant 9 sweep: new Principals (`.broker`, later `.a2aRemote`)/profiles/lanes must not contradict
  session/subagent docs or agent-facing strings.
