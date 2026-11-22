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

**v3.1 (2026-11-22, #1015):** the five v2-review gaps A–E are resolved in §"v3.1 — resolutions of the v2 gaps A–E"
below, each checked against `main` (0c939be7), with what is built, what is not, and the decisions that are the owner's.
Gap D (the inter-session routes) gates the A2A inbound lane (#931 Task 5).

**Execution state (2026-11-19):** the plan was approved and **Group A (the foundation — Tasks 1–5) is
MERGED** (#1201 + #1202). **Group B (the seam closures) is APPROVED** (Brian, option b: full Group B,
the memory-exfil tasks first; #1199 retires once they land) and in progress; **Group C (retrofit)
was authorized by Brian and landed 2026-11-22 (Task 16: the shipped guest's binding, the roles move into the store).** Two implementation names differ from this spec's prose: the `Binding` type
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
| 6 | A session with a non-owner binding sends on the session bus (`send_to_session`, a topic) | the receiving session's own (`.main`) | the receiving session's binding **met with the sender's** (gap D) | sender's binding ∩ receiver's |
| 7 | A job or directory watcher fires | background `.main`/subagent | the binding **stamped on the job at creation**; creation from a non-owner turn that has no profile id is refused (gap D) | that profile, or nothing |
| 8 | An `iris://run-job` link or `--run-job` fires a job | as route 7 | the job's own stamp: a trigger never changes the binding (gap D) | the job's profile |

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

## v3.1 — resolutions of the v2 gaps A–E (#1015)

Brian's decision on #999 (option 2): let it merge, close A, C and E here before the consumer plans
(#931/#965/#966/#967) build from the spec, and settle D before #931 Task 5. Written from the spine as it
stands on `main` (Task 16 complete); every "today" below was read in code or reproduced through a real
`processInput` turn, not taken from the spec. **Decisions that are Brian's are marked OWNER, each with a
recommendation; everything else is settled by the code and is a builder instruction.**

### A. The tool-classification table has a mechanism

**Today.** Non-owner tool gating is a set of per-principal name lists (`GuestToolset.allowedNames`,
`PrincipalFloor.brokerTools`, `memoryWriteTools`/`writerTiers`, `githubProxyTools`, `googleWorkspaceTools`,
`guestOriginDeniedTools`) and the #811 offered-tools check. **`AccessProfile.tools` (the `ToolGrant`) is
never consulted at dispatch** (no call site reads it outside the type, the resolver and the floor), and
`PrincipalFloor.isAllowed` exists but had no caller until #1203 (#1300), which wires it for the two fixed-floor principals (`.mcpGuest`, `.broker`) only: a turn a guest steered is `.main` with an unbounded floor and never reaches it.

**Resolution.** One static table, `ToolClassification.table: [String: ToolClass]`, keyed by tool name and
covering every declared tool (`IrisEngine.allDeclaredToolNames`, the job tools, memory, Google, GitHub,
`search_web`; about 60). A tool absent from the table is `.ownerOnly`. The check is one function called at
the **one** dispatcher chokepoint beside the #811 `offeredToolNames` refusal, at the declaration pass (it
replaces `hardStrip`'s denylist for non-owner turns), and on **every other route a tool call can take**:
`executeApprovedCall` (card replay), `applyHeldWrite` (held writes), and the subagent, job and evaluator
dispatch. Each leaked a gate before (#1217/#1222: a gate on the live route that a parallel route skipped).

*Why class-based, not grant-based.* A turn a guest steered is `.main` with a stamped non-owner binding that is
the **guest's**: its `tools` are `{list_sessions, send_to_session}` (floor-fixed). Checking `binding.profile.tools`
on that turn would take `run_command` and `read_file` from a reviewer role a guest messaged (it uses them, with
per-call approvals), and would **allow** `list_sessions` because the guest's own grant contains it, which is the
#1293 hole. The steered turn runs with the owner's authority at a guest's direction, so the question per tool
is "does it act, with no human in the loop, on owner data or credentials?".

*Classes.* `.approvalGated` (it already asks the person on a guest-origin turn: `run_command`, `write_file`,
`read_file` outside the workspace, the git proxy; unchanged), `.ownerOnly` (no approval step, owner data or
authority: the Google, job and session tools, `schedule_job`, `register_directory_watcher`, `set_workspace`
(it re-points which `AGENTS.md` reaches the prompt), and MCP tools by default), `.tierGated` (the memory tools:
not refused by class but delegated to `MemoryBindingGate`, which checks the binding's memory tier, so a
profile-bound session with the tier still searches its facts and a guest-steered turn, whose tier is the
guest floor's, is refused; a test pins that a profile-bound `.shared` session still reads), `.noCred` (pure
or local: `search_web`, `reflect`), `.spends(type)`.

*The gate.* For a binding that is not the owner's: refuse `.ownerOnly`; ask `MemoryBindingGate` for `.tierGated`; refuse `.spends(t)` unless
`binding.profile.credentials` holds an account of type `t`; leave `.approvalGated` and `.noCred` to their own
paths. A binding that carries a persisted profile (a profile-bound session or a job run) also applies the
profile's positive tool grant. `ToolGrant` gets `permits(name)`: `.set(S)` is `S.contains(name)` and `.allTools`
is "no name restriction", so the `.allTools` grant a subagent of the owner inherits never needs converting to a
`Set` (the type mismatch that kept #1203 to the fixed-floor principals), and the class gate **still** applies to
a non-owner binding. An owner binding, including a subagent whose `childBinding` stays `isOwner`, is allowed
everything. A job run's `JobProfile` and the profile's `ToolGrant` are intersected (fail closed); `JobProfile`
is unchanged.

*Build.* Two PRs, each rule-26 dual: (a) the table, its completeness test (a new tool fails the build until it
is classified, the `writerTiers` pattern), and the declaration, dispatch and parallel-route gates for a
stamped non-owner `.main` turn, replacing the #1199 denylist (closes #1293 and #1294's interim); (b) the
persisted-profile `ToolGrant.permits` application. Every route gets a live `processInput` test with the tool
**offered** and a gate-removal mutant on the gate itself; a refusal by the gate and a refusal as "not offered"
read alike (#811), so a test asserts the gate's own text.

**OWNER decisions (batched with the five at the end of this section):**
- **A1. MCP tools on a turn a guest steered.** Default `.ownerOnly` (recommended): they are the person's own
  servers with their credentials and no approval step, so a role session loses them for that turn only. The
  alternative is `.approvalGated` per server, which keeps a reviewer's GitHub MCP working at the cost of one
  click per call.
- **A2. `run_command` on a turn a guest steered.** (i) Stay `.approvalGated` (recommended): today's ladder (no YOLO,
  no saved rule, Vibecop never answers for it, the `~/.iris` carve-out off) asks the person each time, and a
  reviewer role legitimately runs tests this way. (ii) `.ownerOnly`: a guest can never drive a host command,
  even through a click. Honest case for (ii): #1294 showed a person approving a job a guest had crafted, so a
  click is not a reliable boundary against a social-engineered prompt; the cost of (ii) is that a role session
  cannot run commands on any turn a guest steered. Brian picks; the table makes either a one-line change.

### B. The owner stays ambient-credentialed, by design

The owner (`main`, owner binding) keeps the host's credentials: that is what Iris is today (invariant 1's
named exception, Brian 2A). The consequence, stated as a rule: **no content that came from a lower binding
may drive an owner-binding turn that has acting tools.** It is enforced where lower-binding content enters
an owner session: the recipient stamp for a guest's `send_to_session` (Task 15, shipped), and gap D for
every other lower binding. Until D lands the rule holds for guest senders only.

### C. The owner-data gate list is complete

**Today.** `search_memory`, `search_conversations`, `read_conversation` and the eight memory writers are
spine-gated (`MemoryBindingGate`) and reproduced as refused through a real guest-origin turn with the
#1199 denylist disabled. **Not gated:** `list_jobs`/`get_job_run` (the pinned-conversation check is the only
guard; the denylist is the sole protection on a guest-steered turn, which blocks removing it, #1224), and
**`list_sessions`/`describe_session`** (reproduced: a stamped guest-origin `.main` turn gets the full roster
row, session id, role, name, workspace and description, and the turn's reply goes to the guest; #1293).
**Resolution.** Classify all four `.ownerOnly` in the table (A); they then refuse for any non-owner
binding. A guest's own `list_sessions` is a separate floor tool (granted roles, three fields) and is unchanged.
The #1199 denylist is then reconciled to the spine's real coverage in one change (#1224): remove the 11 memory tools it duplicates, add `list_sessions`/`describe_session` until #1203's table gates them.

### D. The inter-session routes (gates #931 Task 5)

**Today, verified.**
- *Session bus.* A guest sender stamps the recipient turn with its binding and marks it (Task 15,
  `deliverPeerMessage`). Any other sender does not: `guestOrigin = guestClientId != nil ||
  senderTurnIsGuestOrigin`, and a sender whose conversation carries a non-owner profile (`accessProfileId`)
  is never consulted. A profile-bound attended session can message an owner session and the recipient runs
  as owner. Latent today (few entry points set a persisted profile), real for #961 and the A2A lane.
- *Jobs and watchers.* A job is stamped at creation with `persistedAccessProfileId(for: conversation)`, the
  conversation's own persisted profile id. A guest-**steered** `.main` turn has a stamped binding but no
  persisted id, so a job it creates is stamped nil and **fires as the owner**, running the guest's prompt on a
  schedule, confined by nothing the turn was bound to (#1294). The creation approval is requested only when
  the profile is not read-only, the conversation is the pinned one, `hasUnattendedInput` is set, or an
  outbound exemption is asked for. On the real route a guest's message arrives through the peer-delivery
  path, which sets `hasUnattendedInput` on the target (`queuePeerArrival`), so the owner **is** asked
  (human-only) and sees the job's details; the gap is what the approval buys: the approved job is still
  stamped nil and runs as the owner, with the guest-authored prompt, rather than confined to the binding of
  the turn that proposed it. (A direct stamp without that delivery, as a test can make, is created with no
  prompt at all, so the stamp, not the prompt, is what must carry the binding.)
- *Links and the CLI.* `iris://run-job` and `--run-job` fire an existing job under that job's own stamp.

**Resolution.**
1. **Bus:** a receiving turn's binding is the meet of its own and the sender's binding, for **any** sender
   whose `bindingForCall` is non-owner, not only a guest; the receiver is marked as having received
   lower-binding input (today's `hasGuestInput`, generalised) so outbound gating and the #1246 reflection
   gate apply. A non-owner session's bus **access** is the `peerRoles` axis (shipped in Task 16 for guests):
   direct `role:<name>` sends to granted roles only; no topics, names, `iris` or session ids. Owner sends
   are unrestricted. **OWNER (recommend yes):** generalise the guest addressing rule to every non-owner
   binding.
2. **Jobs and watchers:** `schedule_job` and `register_directory_watcher` are `.ownerOnly` in the table
   (A), so a guest-steered turn cannot create one (refusal, not a synthetic profile). A profile-bound turn
   keeps stamping its own profile id, and an update never changes a stamp. **OWNER (recommend refuse):**
   the alternative is a synthetic deny-all profile, which makes a durable job from guest text possible.
3. **Links and the CLI:** a trigger never changes the binding; the job's stamp does. The link's token is
   the authority (owner-issued, per job). A future webhook trigger (route 5) follows the same rule.
4. **A2A lane sessions** (#931): the receiving session's binding is the meet of its own and the verified
   peer's profile (route 4); the lane never runs a turn as owner on a peer's text.

### E. Kill switch, budget, guest network

- **Kill switch.** Add one entry point, `AppState.dropAllGuests()`: close every guest session
  (`GuestSessionRegistry.closeAll`, exists), cancel in-flight guest-steered turns and clear their stamps
  (`guestSteeredBindings`, `guestOriginTurnConversations`), and refuse new guest turns until the owner
  re-enables. A Settings button is the #961 pane's. **OWNER:** whether it also revokes tokens (clients must
  re-register); recommend no: revocation is the existing per-client control, and an emergency stop should
  be reversible.
- **Budget.** Shipped per client: 12 turns an hour, 500,000 tokens a UTC day, 30,000 per turn
  (`GuestSessionDriver`); the ledger is in memory and resets on restart. Recommend: persist the daily counts
  (a restart must not refill a day's allowance), keep the budget per authenticated identity in v1 (a
  per-profile budget is the follow-up if profiles are shared). **OWNER:** confirm or change the numbers.
- **Guest network.** A guest has no `run_command` (its floor tools are `list_sessions` and
  `send_to_session`), so it never reaches a container. The rule matters for the other sandboxed non-owner
  runs: `SandboxSessionManager` creates a container with `NetworkMode.default` (network on) unless a
  job grant says otherwise. Under the spine a sandboxed non-owner run defaults to network off, and the
  `transports` axis, not the sandbox default, grants it. Builder instruction; no owner decision.

### Decisions for Brian, in order (cheapest first)

1. Plugin tools default `.ownerOnly` (A): yes/no. Recommend yes.
2. Non-owner bus access is the `peerRoles` role-send rule for every non-owner binding (D1): yes/no. Recommend yes.
3. A guest-steered turn may not create a job or watcher (D2): refuse or synthetic deny-all. Recommend refuse.
4. Kill switch also revokes tokens (E): recommend no.
5. Guest budget numbers and durability (E): recommend durable, numbers unchanged.
6. MCP tools on a guest-steered turn (A1): default owner-only, or approval-gated per server. Recommend owner-only.
7. `run_command` on a guest-steered turn (A2): stay approval-gated, or owner-only. Both cases are stated above; no recommendation beyond approval-gated preserving the reviewer-runs-tests case.

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
