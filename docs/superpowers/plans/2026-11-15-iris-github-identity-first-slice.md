# Iris GitHub Identity First Slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Iris a second GitHub identity (`iris-main`) she acts as — opening PRs, commenting, and approving *routine* (docs/assets) PRs — through three host-side proxy tools that hold the token in the Keychain so the model never sees it.

**Architecture:** Three new tools (`github_create_pr`, `github_comment`, `github_approve`) in `ToolExecutor`, backed by a new `GitHubProxyClient` that reads the token from a dedicated Keychain service and calls the GitHub REST API via `URLSession`. A user-configured, model-unwritable allowed-repos list (guarded-settings `.blob`) is enforced in Swift before any network call; `github_approve` additionally refuses unless every changed file is under `docs/`/`assets/`, bound to an exact commit SHA. The tools are credential-gated in declaration (Invariant 6), attended-`.main`-only, and exempt from the outbound-taint gate (the specific controls replace it).

**Tech Stack:** Swift / IrisKit, Swift Testing, `URLSession` (new to `ToolExecutor`'s neighborhood; pattern from `LLMClient`), the guarded-settings system (`GuardedSettings.swift`), `KeychainManager`.

**Spec:** `docs/specs/2026-11-15-iris-github-identity-first-slice.md` (consumer-spec under `docs/specs/2026-11-09-unified-access-boundary-design.md`).

## Global Constraints

- **C2 "spend, never possess":** the token value never enters a prompt, tool arg, tool result, error string, `run_command` env, or the sandbox env. The proxy reads the Keychain itself. (Spec §3.)
- **Invariant 6:** the three tools are declared only when a token is present, behind an injectable `githubToolsEnabled: Bool` seam on `ToolExecutor.getTools`. A plain no-credential turn must not carry them (`ToolSurfaceTrimTests.plainTurn` asserts tool-count ≤ 20).
- **Attended `.main` only:** never reachable by `.subagent`, `.evaluator`, `.mcpGuest`, or an unattended background job — declaration-stripped AND dispatch-refused (defence in depth).
- **Allowlist is enforced in code, user-configured, model-unwritable, default empty (fail-closed).** No repo is allowed until the user adds one via Settings. (Spec §3.2.)
- **Token scope backstop:** `Pull requests: write` + `Issues: write`, never `Contents: write`. The in-Swift allowlist + §3.3 gate are the primary control; the PAT scope is the backstop.
- **No warnings** in `Sources/`/`Tests/` (`scripts/check-warnings.sh` exits 0). Swift Testing only (`@Suite`/`@Test`/`#expect`).
- **Any new persisted field** uses `decodeIfPresent` (Invariant 1). **No `ConfigManager.shared` mutation in tests** (Invariant 7) — inject a `ConfigManager(store:)`.
- This is credential + approval boundary code → **rule-26** (two dev reviewers) on every PR.

## Review Focus

The input/failure classes the spec implies that are most likely to bite, each pinned to the task that owns it:

- **Token leaks into a tool result or error string** — a failed API call (401, network error, malformed JSON) must never surface the token in the string returned to the model. → Task 3.
- **Approve gate bypass via a non-routine file** — a PR touching `Sources/` or `Tests/` (directly, or via a rename from a routine path, or hidden on files page 2) gets self-approved. → Task 4.
- **Approve rides a later push** — the approval is submitted without binding `commit_id` to the checked head, so a push after the file-check inherits the approval. → Task 4.
- **Allowlist bypass** — a `repo` string not in the user's configured list reaches a network call (empty/default list must deny everything). → Task 2 + Task 3.
- **Off-principal reachability** — a subagent, guest, evaluator, or unattended job calls any `github_*` tool and it executes. → Task 5.

---

## File Structure

- **Create** `Sources/IrisKit/GitHubProxyClient.swift` — the token-reading REST client (create-PR, comment, approve + the §3.3 file-check gate). One responsibility: talk to GitHub as `iris-main`.
- **Modify** `Sources/IrisKit/KeychainManager.swift` — add the `iris.github` service constant.
- **Modify** `Sources/IrisKit/DevHomeSeeder.swift` — add the new service to the seed-copy list.
- **Modify** `Sources/IrisKit/GuardedSettings.swift` — add the `githubAllowedRepos` guarded `.blob` key + an `isGitHubRepoAllowed(_:)` helper.
- **Modify** `Sources/IrisKit/ToolExecutor.swift` — `githubToolsEnabled` seam + three `FunctionDeclaration`s + three `execute()` dispatch cases.
- **Modify** `Sources/IrisKit/iris.swift` — add the three names to `mainOnlyDeclared` + `unattendedNeverDeclared`; add a dispatch refusal branch in `executeFunctionCall`.
- **Modify** `Sources/IrisKit/OutboundTools.swift` — **no change** (the tools stay out of `builtIn`); a test pins the exemption.
- **Modify** `Sources/IrisKit/Job.swift` — **no change to `readOnlyAllowed`** (mutating tools denied by default); a test pins it.
- **Tests:** `Tests/irisTests/GitHubProxyClientTests.swift` (new), additions to `Tests/irisTests/ToolSurfaceTrimTests.swift`, `Tests/irisTests/GuardedSettingsTests.swift` (if present; else new).

## Prerequisites (config — Brian/manual, not code; gate ENABLING the feature, not building it)

These are the spec's Part-1 config steps. The code tasks below are buildable and testable without them (tests inject stubs). The feature only does real work once these exist.

**No Settings UI in this slice (Brian, 2026-11-15):** the token and allowed-repos are entered via a minimal **headless setter** (Task 6), not a GUI. The real token/repos/profile UI is deferred to the **#961 profile pane**, so this slice doesn't build settings fields #961 will redo. Config-by-command is the dogfood path.

- Create the `iris-main` GitHub service account; issue a fine-grained PAT with `Pull requests: write` + `Issues: write` (no `Contents: write`), scoped to the intended repos. Store it into the `iris.github` Keychain service via `iris --set-github-token` (Task 6).
- Set the allowed repos via `iris --set-github-repos` (Task 6); default empty → the tools refuse everything until set.
- `CODEOWNERS` split on `sackheads/iris` (§2): `* @bnaylor`, `/docs/` + `/assets/` → `@iris-main @sackheads-bot`, `/.github/CODEOWNERS @bnaylor`.
- Enable "Dismiss stale PR approvals when new commits are pushed" on the `main` ruleset.

---

### Task 1: Keychain service + `githubToolsEnabled` predicate + dev-home seeding

**Files:**
- Modify: `Sources/IrisKit/KeychainManager.swift` (add service constant near line 20)
- Modify: `Sources/IrisKit/DevHomeSeeder.swift` (copy list around line 86)
- Test: `Tests/irisTests/GitHubProxyClientTests.swift` (new)

**Interfaces:**
- Produces: `KeychainManager.githubService` (`public static let githubService = "iris.github"`); a read helper `GitHubProxyClient.hasToken(keychain:) -> Bool` and `GitHubProxyClient.token(keychain:) -> String?` reading `keychain.secrets(service: KeychainManager.githubService)["token"]`. `.dev` suffixing is automatic via `resolvedService`; callers pass the bare base name.
- Produces: a **cached presence flag** `ConfigManager.hasGitHubToken: Bool` — set once when the token is read at launch and updated when the token is written via Settings. **Task 5's `githubToolsEnabled` default reads THIS cached flag, never the Keychain per turn** (dev-3 review): `getTools` runs every turn, and a per-turn Keychain read is both slow and risks re-triggering the `.dev` SecurityAgent prompt on every turn (#578). Mirror how `workspaceToolsEnabled`'s default reads a cached `ConfigManager.shared.googleRefreshToken`, not a live credential probe.
- Note: adding `githubService` to `DevHomeSeeder`'s copy list is **deliberate** (the dev home needs the token to function) — state it in the diff so a reviewer doesn't flag the token copy as a leak.

- [ ] **Step 1: Write the failing test** — `@Test` that `GitHubProxyClient.hasToken` is `false` for a `KeychainManager` over an empty injected store and `true` after a token is written to `KeychainManager.githubService`; `ConfigManager.hasGitHubToken` reflects presence without a per-call Keychain read; and a `DevHomeSeeder` unit asserting the seed-copy `services` array contains `KeychainManager.githubService`.
- [ ] **Step 2: Run tests, verify they fail** (`scripts/test-filter.sh GitHubProxyClientTests`, quote the count — Invariant 7).
- [ ] **Step 3: Add `KeychainManager.githubService`**, add it to `DevHomeSeeder`'s `services` array (so the token seeds into `~/.iris-dev`), and implement `hasToken`/`token` on `GitHubProxyClient`.
- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit** (`feat: add iris.github keychain service and token lookup`).

### Task 2: Guarded allowed-repos setting (model-unwritable, fail-closed)

**Files:**
- Modify: `Sources/IrisKit/GuardedSettings.swift` (new `GuardedKey` case ~line 33; `kind` mapping ~line 68)
- Test: `Tests/irisTests/GuardedSettingsTests.swift` (add, or new file)

**Interfaces:**
- Produces: `GuardedKey.githubAllowedRepos` (raw `"GITHUB_ALLOWED_REPOS"`, kind `.blob`, a JSON array of `"owner/name"` strings); `ConfigManager.isGitHubRepoAllowed(_ repo: String) -> Bool` reading `guardedBlob(.githubAllowedRepos)`, parsing the JSON array, returning `false` for empty/absent/malformed (fail-closed) and for any `repo` not exactly in the list. The Settings-UI write path is the existing `setGuardedBlob(.githubAllowedRepos, _:)`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test** — over an injected `ConfigManager(store:)`: default (unset) → `isGitHubRepoAllowed("sackheads/iris") == false`; after `setGuardedBlob(.githubAllowedRepos, "[\"sackheads/iris\"]")` → `true` for `"sackheads/iris"`, `false` for `"evil/repo"`; malformed blob → `false` (fail-closed). Assert the value is reachable only through the guarded accessors (no model-tool writer).
- [ ] **Step 2: Run tests, verify fail** (quote count).
- [ ] **Step 3: Add the `GuardedKey` case + `.blob` kind mapping + `isGitHubRepoAllowed`.**
- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit** (`feat: add guarded githubAllowedRepos allowlist, fail-closed`).

### Task 3: `GitHubProxyClient` core — create-PR + comment, token never surfaced, allowlist-gated

**Files:**
- Create: `Sources/IrisKit/GitHubProxyClient.swift`
- Test: `Tests/irisTests/GitHubProxyClientTests.swift`

**Interfaces:**
- Consumes: Task 1 (`token`/`hasToken`), Task 2 (`isGitHubRepoAllowed`).
- Produces:
  - `struct GitHubProxyClient` with an injectable transport seam (a `protocol GitHubTransport { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`, default `URLSession.shared`, a stub in tests — so no test hits the network).
  - `func createPR(repo:head:base:title:body:draft:) async -> String` → `POST /repos/{repo}/pulls`.
  - `func comment(repo:pr:body:) async -> String` → `POST /repos/{repo}/issues/{pr}/comments`.
  - Each returns a model-facing result string (success summary or a sanitized error). All entry points **first** call `isGitHubRepoAllowed(repo)` and return a refusal before building any request if false. The `Authorization` header is set from the Keychain token inside `send`; the token is never placed in a returned string, and any error path scrubs it.

- [ ] **Step 1: Write the failing tests** (stub transport): (a) `createPR`/`comment` on an allowed repo issue the right method+path and return a success string containing the PR/comment URL; (b) a repo NOT in the allowlist returns a refusal and the stub transport is **never called** (allowlist enforced before network); (c) a transport error whose body echoes the token returns a string that does **not** contain the token (C2 scrub — Review Focus).
- [ ] **Step 2: Run tests, verify fail** (quote count).
- [ ] **Step 3: Implement `GitHubProxyClient` core** — the transport seam, token read, allowlist pre-check, `createPR`, `comment`, and a `sanitize(_:)` that strips the token from any outgoing string. Follow `LLMClient`'s `URLSession` usage for the real transport.
- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit** (`feat: GitHubProxyClient create-PR + comment, allowlist-gated, token-scrubbed`).

### Task 4: `github_approve` + the §3.3 file-check gate (the load-bearing security logic)

**Files:**
- Modify: `Sources/IrisKit/GitHubProxyClient.swift`
- Test: `Tests/irisTests/GitHubProxyClientTests.swift`

**Interfaces:**
- Consumes: Task 3 (client + transport seam + allowlist).
- Produces: `func approve(repo:pr:) async -> String` → refuses unless every changed file is routine, then `POST /repos/{repo}/pulls/{pr}/reviews` with `event: "APPROVE"` and `commit_id: <head_sha>`. Internals: `resolveHead(repo:pr:)` (`GET /pulls/{pr}` → `head.sha`); changed files fetched SHA-keyed via `GET /compare/{base}...{head}` (or `GET /pulls/{pr}/files` with a before/after `head.sha` re-verify); `isRoutineFile(_:)` requiring both `filename` and `previous_filename` (when present) to start with `docs/`/`assets/` (no leading `/`, no `..`).

- [ ] **Step 1: Write the failing tests** (stub transport returning canned PR/compare payloads), one per Review-Focus case:
  - a PR whose files are all under `docs/`/`assets/` → `APPROVE` submitted with `commit_id == head.sha`;
  - a PR touching `Sources/IrisKit/x.swift` → refused, no review POST;
  - a rename `Sources/IrisKit/x.md` → `docs/x.md` (routine `filename`, non-routine `previous_filename`) → refused;
  - a files response at the 100-item cap / with `Link: rel="next"` → refused (pagination fail-closed);
  - `head.sha` changes between resolve and files fetch → refused (TOCTOU);
  - a `..` segment in a path → refused.
- [ ] **Step 2: Run tests, verify fail** (quote count).
- [ ] **Step 3: Implement `approve` + `isRoutineFile` + the SHA-bind/pagination/rename guards.**
- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit** (`feat: github_approve with routine-file + SHA-bind + pagination/rename gate`).

### Task 5: Tool surface — declarations, credential gating, principal gating, dispatch, exemptions

**Files:**
- Modify: `Sources/IrisKit/ToolExecutor.swift` (`getTools` ~line 90/203; `execute` switch ~line 230)
- Modify: `Sources/IrisKit/iris.swift` (`mainOnlyDeclared` line 5193, `unattendedNeverDeclared` line 5164; dispatch refusal in `executeFunctionCall` ~line 5798 alongside the `jobCreationTools` branches)
- Test: `Tests/irisTests/ToolSurfaceTrimTests.swift` + `Tests/irisTests/GitHubProxyClientTests.swift`

**Interfaces:**
- Consumes: Tasks 3 + 4 (the client the dispatch cases call).
- Produces: `ToolExecutor.getTools(workspaceToolsEnabled:githubToolsEnabled:)` — a new parameter defaulting to the **cached** `ConfigManager.shared.hasGitHubToken` flag from Task 1 (NOT a per-turn Keychain read — dev-3 review); three `FunctionDeclaration`s appended only under `if githubToolsEnabled`; three `execute()` cases dispatching to the `GitHubProxyClient`. A static `githubProxyTools: Set<String>` (the three names) for the gating sets and the dispatch refusal.
- **`pr` parameter is `Int`** (the PR number), not a model-supplied string, wherever it reaches a URL path (Tasks 3/4 tool schemas + handlers).
- **No human approval card.** These three are outbound-exempt (§3.1) and attended-`.main`-only; on an allowed repo (and, for approve, a passing §3.3 gate) they **execute without raising an approval prompt** — that is the point (Iris clears routine PRs without a Brian click; the §3.2/§3.3 code gates are the control, not a modal). State this explicitly so a reviewer doesn't expect an approval path.

- [ ] **Step 1: Write the failing tests:**
  - `githubToolsGatedOnCredentials` (copy `googleToolsGatedOnCredentials`): the three names absent when `githubToolsEnabled: false`, present when `true`, `run_command` present in both.
  - `plainTurn` still ≤ 20 with no token (the three must not appear on a plain no-credential turn).
  - the three names are in `mainOnlyDeclared` **and** `unattendedNeverDeclared`, and `hardStrip` removes them for `principal != .main` and for `isUnattended`.
  - a dispatch-level `executeFunctionCall` call to `github_approve` under `.subagent` / `.mcpGuest` / unattended returns the refusal (not the client result).
  - **outbound exemption:** `OutboundTools.isOutbound("github_approve", readOnlyMCPTools: [])` is `false` (pins the §3.1 decision to keep them out of `builtIn`).
  - **read-only job denial:** `JobProfile.readOnlyDenies("github_approve", sandboxedRunCommand:false, readOnlyMCPTools:[])` is `true` (mutating → denied by default).
  - update the `allDeclaredToolNames` / `inlineDeclaredToolNames` coverage lists to include the three.
- [ ] **Step 2: Run tests, verify fail** (quote count).
- [ ] **Step 3: Implement** the `githubToolsEnabled` seam + declarations + dispatch cases; add the three names to `mainOnlyDeclared` + `unattendedNeverDeclared`; add the explicit dispatch refusal branch mirroring the `jobCreationTools` checks. Leave `OutboundTools.builtIn` and `JobProfile.readOnlyAllowed` unchanged.
- [ ] **Step 4: Run tests, verify pass**; run `scripts/check-warnings.sh` (exit 0) and the full `swift test`.
- [ ] **Step 5: Commit** (`feat: wire github_* proxy tools — credential+principal gated, outbound-exempt`).

### Task 6: Headless config setter (no GUI — Brian deferred UI to #961)

**Files:**
- Modify: `Sources/IrisKit/IrisMain.swift` (add two headless modes alongside `--seed-dev-home` etc.)
- Test: `Tests/irisTests/GitHubProxyClientTests.swift` (or a new `GitHubConfigSetterTests.swift`)

**Interfaces:**
- Consumes: Task 1 (`KeychainManager.githubService`, the cached-flag update path), Task 2 (`GuardedKey.githubAllowedRepos` + `setGuardedBlob`).
- Produces: `iris --set-github-token` (reads the token from **stdin**, never argv — argv leaks into process listings; writes it to the `iris.github` Keychain service and refreshes `ConfigManager.hasGitHubToken`); `iris --set-github-repos` (reads a comma- or newline-separated repo list from stdin, validates each as `owner/name`, writes the JSON array via `setGuardedBlob(.githubAllowedRepos, …)`). Both print a confirmation that does **not** echo the token. This is the dogfood entry path; the real UI is #961.

- [ ] **Step 1: Write the failing tests** — `--set-github-token` from a stubbed stdin writes the token to the injected Keychain and flips `hasGitHubToken`; the confirmation string does **not** contain the token; `--set-github-repos` writes a valid JSON array and rejects a malformed entry (`not-a-repo`) without writing.
- [ ] **Step 2: Run tests, verify fail** (quote count).
- [ ] **Step 3: Implement the two headless modes** (stdin read, validation, Keychain/guarded-blob write, token-free confirmation).
- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit** (`feat: iris --set-github-token / --set-github-repos headless config entry`).

### Task 7: Docs — falsify what changed (Invariant 9)

**Files:**
- Modify: `docs/features.md` (or a `docs/github-identity.md` page linked from the README if it outgrows a screen)
- Modify: the spec's status note if needed

- [ ] **Step 1:** Grep for agent-facing strings and docs the new tools make stale (`oracleText`, tool `description` fields, system prompts, README/`docs/`). Add the feature's doc entry (including the `--set-github-token`/`--set-github-repos` config path and that the real UI is deferred to #961). Fix any sentence the new behavior made untrue. "Nothing was falsified" is a legitimate answer — having looked is the requirement.
- [ ] **Step 2: Commit** (`docs: document the iris-main GitHub proxy tools + headless config`).

---

## Self-Review notes

- **Spec coverage:** §2 CODEOWNERS = Prerequisites (config). §3 three tools = Tasks 3–5. §3.1 harness integration = Task 5. §3.2 allowlist = Task 2 + enforced in Task 3. §3.3 approve gate = Task 4. §4 account/keychain/scope = Task 1 (+ token scope is config). §8 review focus = the Review Focus section, each pinned. Config entry (no UI, deferred to #961) = Task 6.
- **Type consistency:** `githubProxyTools` set, `GuardedKey.githubAllowedRepos`, `KeychainManager.githubService`, `ConfigManager.hasGitHubToken`, `GitHubProxyClient` + `GitHubTransport` used consistently across tasks.
- **Dependency order:** 1 & 2 are independent foundations; 3 consumes 1+2; 4 consumes 3; 5 consumes 3+4; 6 (headless setter) consumes 1+2 and can run parallel to 3; 7 (docs) last. Tasks depend on each other's Produces blocks — subagent-driven execution (fresh reviewer per task) fits because each is boundary code worth an independent gate.
