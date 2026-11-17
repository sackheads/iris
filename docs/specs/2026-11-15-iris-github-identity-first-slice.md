# First slice: Iris reviews routine PRs as herself (`iris-main`) — consumer-spec under #974

> **Update (#1184): the account is a setting, not a constant.** This spec was written around one account,
> `iris-main`, the account this repository uses. The account's username is now a guarded setting
> (`GuardedKey.githubLogin`, stored as `{"login":"<name>"}` beside the allowed-repos list, unset by default);
> read `iris-main` below as "the configured account". Unset means the feature is off: the tools are not
> declared and git is untouched. The commit name and email derive from it
> (`<login>@users.noreply.github.com`), and the pane checks the token against it with `GET /user`,
> reporting a mismatch. `docs/github-identity.md` is the current description.

> **Status:** spec by iris-planner, 2026-11-15; Iris-reviewed (+4 amendments folded), then **REVISED to
> the contributor model** (Brian, 2026-11-15): `iris-main` is a full git contributor (push/commit/PR as
> herself), the lockdown is on *approval authority* only (routine `/docs`+`/assets`, minus the `plans`/`specs` instruction folders; `CODEOWNERS`-enforced),
> and the "spend-never-possess / no-`Contents:write`" framing is dropped as over-lock on the wrong axis.
> The §3.3 approve-gate and the allowlist survive; §4 is rewritten.
> **This is a FIRST-SLICE consumer-spec, not a design.** The boundary design is
> `docs/specs/2026-11-09-unified-access-boundary-design.md` (#974 v2, audited). This doc does **not**
> redefine `Principal` / `AccessProfile` / `Binding` / the C1–C8 seam closures — 11-09 owns those. It
> scopes the **minimum wedge** that gets "Iris clears routine PRs as herself" working safely, using
> 11-09's **C2 proxy** pattern for its one credential. It **supersedes** the retired standalone draft
> `2026-11-14-profile-credential-substrate-SPEC.md`, which reinvented the boundary and was correctly
> rejected (Iris's 11-14 review: dropped C1/C2/M2/M3, wrong seam, contradicted M2).

## 1. What this slice is (and is not)

**Is:** give Iris her own GitHub identity, **`iris-main`**, as a **first-class contributor** — she
commits, pushes branches, and opens PRs **as `iris-main`** (independent of `@bnaylor`'s identity), and
she can **approve _routine_ PRs** (`/docs`, `/assets`, but not a `plans/` or `specs/` folder) as `iris-main`. `iris-main` mirrors
`sackheads-bot`'s git privileges: a real bot contributor account. Plus the `CODEOWNERS` split that lets
her routine approvals satisfy the merge gate.

**The one thing that is locked down is _approval authority_, not contribution** (Brian, 2026-11-15).
Iris contributes code freely as `iris-main`; what stays under `@bnaylor` is approval of anything that
matters — `Sources/`, `Tests/`, the ruleset, the `CODEOWNERS` file itself. `iris-main` can only ever
approve `/docs` + `/assets` (minus `plans/` and `specs/`), enforced structurally by `CODEOWNERS` (§2) and belt-and-suspendered by the
approve-gate (§3.3). The design's job is **identity separation** (Iris acts as herself, lands routine
work without a human click), **not** credential-hiding — Iris already runs from a highly privileged
place (Brian's email, his git creds), so hiding `iris-main`'s credential from the model buys nothing.

**Is not:** the full #966 credential registry, `AccessProfile`/`Binding`, memory scoping, A2A, or the
C1 closure that sandboxes non-owner principals. Those are 11-09's scope, built when their consumers
(#965/#931/#961/#967) come. This slice runs in **owner/`main` context** (Brian's own Iris).

**Explicitly no "forge" abstraction** (Brian, 2026-11-15: kube-agents' forge layer is too much).
GitHub only.

## 2. The clickhole root cause (Iris found it) — and the config fix

Iris sessions run `gh pr create` under Brian's **ambient** `gh` auth, so their PRs are authored by
`@bnaylor`. With `CODEOWNERS = * @bnaylor`, **nobody can approve them** — GitHub blocks `@bnaylor`
from approving his own PR. That is the actual clickhole on Iris-authored PRs. So the fix has two parts:

1. **Iris commits, pushes, and authors PRs as `iris-main`** (not ambient `@bnaylor`). She commits with
   `iris-main`'s git identity (verified email), pushes branches with `iris-main`'s credential, and opens
   the PR as `iris-main` (`POST /pulls` as the token's identity, or `gh` configured as `iris-main`). The
   old `gh pr create` under ambient auth authored as `@bnaylor`, which is the clickhole; a coherent
   `iris-main` contributor identity (§4) is what delivers part 1.
2. **CODEOWNERS split (fail-safe, config-only, no iris code):**
   ```
   * @bnaylor                               # default: Brian (floor)
   /docs/         @bnaylor @iris-main @sackheads-bot   # routine: any of the three may approve
   /assets/       @bnaylor @iris-main @sackheads-bot
   /docs/**/plans/ @bnaylor                            # agent instructions: a human only
   /docs/**/specs/ @bnaylor
   /.github/CODEOWNERS @bnaylor                        # the gate protects itself
   ```
   **`/Tests/` is NOT in the routine set** (Iris's finding 2): it is executable host Swift (runs under
   `swift test` outside any sandbox) and holds the security/source-scan gates — a bot pair must not be
   able to weaken a security test or merge host-executing code. Start with `/docs/` + `/assets/` only, minus the folders below.
   `Sources/` stays `@bnaylor` entirely (Iris's finding 3: it is almost all boundary code; a denylist of
   boundary files is fail-open and missed 25+ files — do not go that route).
   **Ruleset requirements:** the `main` ruleset must have **BOTH** of (or an approval rides a later push):
   - **"Dismiss stale PR approvals when new commits are pushed"**, and
   - **"Require approval of the most recent reviewable push"** (#1169 review). Stale-dismissal fires at
     *push* time, so without the second setting an approval that lands after a push isn't dismissed and a
     stale-SHA approval of an old routine-only commit could count toward merging a newer head with
     `Sources/` changes. The second setting ties the required approval to the current head.

   **`plans/` and `specs/` are NOT routine either** (Brian, 2026-11-16): `docs/plans`, `docs/specs`,
   `docs/superpowers/plans` and `docs/superpowers/specs` are instructions that sessions read and execute,
   and a docs-only PR runs no CI (`scripts/ci-changes.sh`), so a poisoned one approved by the bots would
   merge with no human and steer the next session that reads it. The `/docs/**/plans/` and
   `/docs/**/specs/` lines (later, more specific, so they win) leave those `@bnaylor`-only; `**` covers
   the nested `superpowers` folders, which a flat `/docs/plans/` would miss. `@bnaylor` is also listed on
   `/docs/` and `/assets/`: GitHub takes owners from the last matching pattern, and without him there his
   own approval would not clear a docs PR (and approval is what arms the merge queue).

   **Limit of the structural half:** CODEOWNERS patterns are case-sensitive and take no bracket classes, so
   `/docs/**/plans/` does not match `docs/Plans/` or `docs/SPECS/`; such a path falls to the `/docs/` line,
   where the bots' approval counts. On the Mac's case-insensitive checkout it is the same folder as
   `docs/plans`, so for that spelling only the `github_approve` gate (which compares case-insensitively)
   and a human reviewer stand between a bot approval and a merge. Any other bot-approval path (the
   sackheads-bot follow-up, #1170) must run the same gate, not rely on CODEOWNERS alone.

   **`CODEOWNERS` is the primary approval control.** `iris-main` is a code owner of `/docs`+`/assets`
   *only* (not their `plans/` and `specs/` folders), so its approval structurally cannot satisfy the merge gate for a PR that touches `Sources/`,
   `Tests/`, or anything else — those need `@bnaylor`. This is the real "important approvals stay under my
   id" mechanism; the §3.3 approve-gate is defence-in-depth on top of it.

## 3. The tools (Iris acting as `iris-main`)

Host-side Swift tools that act as `iris-main` against the GitHub REST API. `iris-main`'s credential is
**Iris's own** (like `sackheads-bot`'s tooling holds its credential) — the design goal is identity
separation, **not** hiding the credential from the model (Iris already holds Brian's creds + email).
Three tools:

- **`github_create_pr(repo, head, base, title, body, draft?)`** — `POST /repos/{owner}/{repo}/pulls`,
  opens a PR authored by `iris-main` (§2, part 1). The branch it references is pushed by Iris as
  `iris-main` (§4) — a normal contributor flow.
- **`github_comment(repo, pr, body)`** — `POST /issues/{n}/comments`. (`Issues: write`.)
- **`github_approve(repo, pr)`** — `POST /pulls/{n}/reviews` with `APPROVE` (`Pull requests: write`),
  bounded by the §3.3 code gate. This is the one tool whose *restriction* is load-bearing: see §3.3.

**Why `github_approve` stays a gated tool even though the credential isn't hidden.** `CODEOWNERS` is the
structural guarantee that `iris-main` can't approve non-routine code (its approval simply doesn't count
for `Sources/`/`Tests/`). The §3.3 gate adds defence-in-depth: Iris won't even *submit* an approval on a
non-routine or multi-file PR, and it binds the review to the checked commit (SHA-bind) so a later push
can't ride it. It is belt-and-suspenders on the one axis Brian locks down (approval), not the primary
control.

### 3.1 Harness integration — specify it or it collides (Iris finding 1)
Adding these tools to `ToolExecutor`/`IrisEngine` must be specified against three existing mechanisms:

- **Declare only when configured (Invariant 6).** Omit the three declarations unless a token
  is present in the Keychain, the user has set the account's login (#1184) **and** allowed at least one repo (§3.2): with any missing
  the tools can only refuse, so declaring them is dead prompt weight. All three are read once at launch
  (`ConfigManager.githubToolsConfigured`), behind an injectable `githubToolsEnabled` seam on
  `ToolExecutor.getTools` (like `workspaceToolsEnabled`); a token or list set later takes effect on the
  next launch. Otherwise an unconfigured install pays prompt tokens every turn and
  `ToolSurfaceTrimTests.plainTurn` (tool-count ≤ 20) fails.
- **Attended `.main` only.** None of the three is reachable by `.subagent`, `.evaluator`, `.mcpGuest`, or
  an unattended background job. Add them to `IrisEngine.mainOnlyDeclared` and
  `IrisEngine.unattendedNeverDeclared`, add them to `JobProfile.readOnlyDenies`, and require
  `principal == .main && !isUnattended` in `executeFunctionCall` (defence in depth: declared *and*
  dispatch-refused, per Invariant 6).
- **OutboundTools / taint.** A reviewer session reads untrusted content (`gh pr diff`, repo files, a peer
  message) before calling these, setting `hasUntrustedToolOutput`. If the three are in
  `OutboundTools.builtIn`, every review comment/approval raises a `humanOnly` card in a non-YOLO session —
  trading the GitHub clickhole for an Iris clickhole. **Decision (Brian-ratified, 2026-11-15): the
  `github_*` tools are exempt from the taint/outbound approval gate.** A reviewer always reads the PR
  diff (untrusted) before acting, so the gate would fire on every review and defeat the clickhole
  relief. They are bounded instead by the §3.2 allowlist, the §3.3 approve gate and `CODEOWNERS` (worst
  case: an unwanted routine docs/assets approval, never a code merge). The exemption is pinned by a test
  (`GitHubToolSurfaceTests`), and `OutboundTools.builtIn` does not list them.
- **Guest-origin turns (closed separately).** A turn a guest's message started is attended and `.main`,
  and these tools have no approval step, so the guest-origin guards in the approval ladder never see
  them. They are therefore neither declared to such a turn nor dispatched for one: the dispatcher refuses
  a `github_*` call when the conversation, or its delegation root, is guest-origin (#1119's marker),
  and `hardStrip` drops the declarations. Pinned through the dispatcher and a real turn.

### 3.2 The repo allowlist — user-configurable, enforced in code (Brian + Iris finding 1)
Every `github_*` tool refuses, **in Swift before any network call**, a `repo` not on an allowlist. But the
allowlist is **not hardcoded** (Brian, 2026-11-15: Iris will work on many repos, not just `sackheads/iris`):

- The allowed-repo set is a **user-configurable setting** the user edits in the #961/settings UI.
- It lives in a **protected, non-model-writable store** (H3: policy is not model-writable) — a guarded
  setting, not something a tainted session or model tool can add to. A tainted reviewer session must not
  be able to add its own exfil-target repo to the allowlist.
- **Default is empty → fail-closed** (11-09 fail-closed principle): no repo is allowed until the user adds
  one. The enforcement is in code (Iris's security point — do not rely only on the PAT's GitHub-side
  scope); the *contents* come from user config (Brian's point).

### 3.3 The `github_approve` file-check gate (Iris findings 1 + 3)
`github_approve` refuses unless **every changed file is inside the routine allowlist** (`docs/`, `assets/`, but not under a `plans/` or `specs/` folder of `docs/`, at any depth, compared case-insensitively),
bound to an exact commit — hardened against three bypasses Iris flagged:

1. **SHA-keyed, no TOCTOU.** `GET /pulls/{n}/files` is not keyed to a SHA. Resolve `head.sha` from
   `GET /pulls/{n}`, then fetch the changed files via the **SHA-keyed** `GET /compare/{base_sha}...{head_sha}`
   (or re-verify `head.sha` is unchanged both before and after the files call). Submit the review with
   `commit_id = head_sha`, so a push after the check cannot ride the approval.
2. **Pagination fail-closed.** Request `per_page=100` and **refuse if the file count hits 100** (or a
   `Link: rel="next"` is present) — never miss a 101st `Sources/` file on page 2.
3. **Renames + path prefixes.** Require **both** `filename` and `previous_filename` (when non-nil) to begin
   with `docs/` or `assets/` (GitHub API paths have no leading `/`), with no `..` segments and no `plans`/`specs` directory under `docs/` — so a
   `Sources/IrisKit/x.md` → `docs/x.md` rename can't slip a Sources change past the check.

The token value is still scrubbed from tool output as hygiene, but it is **not** the control — the
controls are `CODEOWNERS` (structural) + the §3.3 gate + the ruleset settings.

## 4. `iris-main` as a git contributor — identity, credential, and isolation

`iris-main` is a real bot contributor account, mirroring `sackheads-bot`'s git privileges (Brian,
2026-11-15). It is the precursor the #966 credential registry generalizes later; this slice builds the
single account, not the registry.

- **Git identity.** `iris-main` has a verified email on its GitHub account; Iris commits with
  `user.name`/`user.email` set from the configured login (`<login>` and its noreply address, #1184) so GitHub attributes her commits to that account, not
  `@bnaylor`. This is the identity-separation goal.
- **One credential, full contributor scope.** A single fine-grained PAT (or key) on `iris-main`:
  **`Contents: read and write`** (push branches + read PR diffs for the §3.3 `/compare` check),
  **`Pull requests: read and write`** (open/approve PRs), **`Issues: read and write`** (comments). Scoped
  to the **user-configured allowed repos** (§3.2) — no Administration, Secrets, Workflows, or Settings.
  `Contents: write` is deliberately **included** now: Iris pushes code as a contributor. The thing that
  bounds her is **not** a withheld push scope — it's branch protection (`main` needs a PR + a
  code-owner approval) plus `CODEOWNERS` (her approval only counts for `/docs`+`/assets`, minus `plans/` and `specs/`). (The earlier
  draft's "no `Contents: write` / spend-never-possess" was over-lock on the wrong axis. The credential is Iris's to use, like any contributor's tooling.)
- **Credential storage + git plumbing.** Store the credential in its own `KeychainManager` service
  (the `iris.github` item from Task 1). For git operations Iris uses it via an **isolated config** —
  an `iris-main`-scoped `GH_CONFIG_DIR` / git credential helper and a dedicated git `user.*` — so it is
  `iris-main`'s identity and never clobbers or reads `@bnaylor`'s ambient `gh`/git. The host-side
  `github_*` tools read the same credential for the API calls.
- **Dev-home seeding (Iris finding 4):** `DevHomeSeeder` copies the `iris.github` service when seeding
  `~/.iris-dev` (it copies `legacyService` + `mcpFileService` + `iris.plugin.*` today) so `run-dev.sh`
  sessions have the credential without manual re-entry.

## 5. Non-goals / anti-goals

- No forge abstraction; GitHub only.
- No `AccessProfile`/`Binding`/registry/memory-scoping/A2A (11-09's scope).
- `iris-main` **contributes code freely** (push/commit/PR) — contribution is NOT restricted.
- `/Tests/` and `/Sources/` never bot-**approvable** in this slice — the lockdown is on approval
  authority, not contribution. `CODEOWNERS` is the structural guarantee; the §3.3 gate is defence-in-depth.
- **No hardcoded repo list** — the allowed repos are a user-configurable, protected setting (§3.2); Iris
  is not iris-repo-only. Enforcement is in code, defaults fail-closed.
- The `github_*` tools are never reachable by subagent/evaluator/guest/unattended, and never author or
  approve as `@bnaylor`.
- **Not** credential-hiding: the credential is `iris-main`'s, used by Iris like any contributor's tooling
  (Iris already holds Brian's creds + email). The goal is identity separation + bounded approval.
- Does not claim to close C1 (ambient host auth for non-owner principals) — that is 11-09.

## 6. How it plugs into 11-09

- `iris-main` is the **first concrete account** the #966 credential registry generalizes later; when #966
  lands, it moves into the typed registry and the ops become account-scoped there — no rework of the
  tools' shape. (`sackheads-bot`, the peer routine-approver, is the second account — filed #1170.)
- The CODEOWNERS split and the approve code-gate are independent of the registry and ship now.
- The "decider is never the requester" hardening (approve in a separate owner-authority session from the
  one reading untrusted diffs — 11-09's broker principle) is a **future tightening**; this slice's
  approval bound is `CODEOWNERS` + the §3.3 gate, which hold Iris to routine docs/assets PRs (not plans or specs).

## 7. Slice contents / sequencing

1. **Config-only (no iris code):** create `iris-main` (write collaborator) + its credential (§4); the
   CODEOWNERS split (§2); enable **both** ruleset settings (§2). See the enablement checklist.
2. **The git-contributor plumbing + the tools + the account lookup + the approve gate (§3/§4):** the
   iris-code slice. rule-26 reviewed (it is credential + approval boundary code).
3. Everything else is 11-09.

## 8. Review focus (rule-26, for this spec then the slice)

- **Approval bound is real:** `iris-main` cannot land non-routine code. Primary = `CODEOWNERS` (its
  approval doesn't count for `Sources/`/`Tests/`); defence-in-depth = the §3.3 gate (`github_approve`
  refuses unless every changed file at the bound `headRefOid` is routine, and binds `commit_id`).
  Reproduce: a PR touching a `Sources/`/`Tests/` file can't be merged on `iris-main`'s approval; the gate
  refuses to even submit one; a push after the check does not ride the approval (SHA-bind + the second
  ruleset setting).
- **CODEOWNERS is fail-safe** (default `@bnaylor`, `/docs`+`/assets` only with `plans/` and `specs/` carved back to `@bnaylor`, `/Tests/` and `/Sources/`
  excluded, self-protected) and **both** ruleset settings are on.
- **Identity separation:** Iris commits/pushes/PRs as `iris-main` (not `@bnaylor`), via an isolated
  config that never clobbers or reads `@bnaylor`'s ambient `gh`/git.
- **No ambient `@bnaylor` on the proxy path:** `iris-main`'s token does not touch
  `~/.config/gh`/global `GH_TOKEN`.
