# First slice: Iris reviews routine PRs as herself (`iris-main`) — consumer-spec under #974

> **Status:** spec by iris-planner, 2026-11-15; **Iris-reviewed (approve + 4 amendments, all folded)**,
> the four amendments (§3.1 harness integration, `github_create_pr`, the §3.3 approve-check hardening,
> §4 keychain naming) plus Brian's user-configurable-repo-allowlist steer (§3.2) incorporated.
> **This is a FIRST-SLICE consumer-spec, not a design.** The boundary design is
> `docs/specs/2026-11-09-unified-access-boundary-design.md` (#974 v2, audited). This doc does **not**
> redefine `Principal` / `AccessProfile` / `Binding` / the C1–C8 seam closures — 11-09 owns those. It
> scopes the **minimum wedge** that gets "Iris clears routine PRs as herself" working safely, using
> 11-09's **C2 proxy** pattern for its one credential. It **supersedes** the retired standalone draft
> `2026-11-14-profile-credential-substrate-SPEC.md`, which reinvented the boundary and was correctly
> rejected (Iris's 11-14 review: dropped C1/C2/M2/M3, wrong seam, contradicted M2).

## 1. What this slice is (and is not)

**Is:** give Iris a second GitHub identity (`iris-main`) she can **act as** — post review comments and
approve *routine* PRs — through **host-side proxy tools** that hold the token in an isolated store,
plus the `CODEOWNERS` config split that lets those approvals satisfy the merge gate. It is the first
concrete instance of 11-09's **C2 "spend, never possess"** surface.

**Is not:** the full #966 credential registry, `AccessProfile`/`Binding`, memory scoping, A2A, or the
C1 closure that sandboxes non-owner principals. Those are 11-09's scope, built when their consumers
(#965/#931/#961/#967) come. This slice runs in **owner/`main` context** (Brian's own Iris), so it does
not itself close ambient host auth for guests — it just stops Iris from acting as `@bnaylor` on GitHub
by giving her a real second identity and a token path that doesn't touch `@bnaylor`'s `gh`.

**Explicitly no "forge" abstraction** (Brian, 2026-11-15: kube-agents' forge layer is too much).
GitHub only, two tools.

## 2. The clickhole root cause (Iris found it) — and the config fix

Iris sessions run `gh pr create` under Brian's **ambient** `gh` auth, so their PRs are authored by
`@bnaylor`. With `CODEOWNERS = * @bnaylor`, **nobody can approve them** — GitHub blocks `@bnaylor`
from approving his own PR. That is the actual clickhole on Iris-authored PRs. So the fix has two parts:

1. **Iris authors as `iris-main`** (not ambient `@bnaylor`) — via the `github_create_pr` proxy tool
   (§3), which calls `POST /pulls` as the token's identity. `gh pr create` via `run_command` would
   author as `@bnaylor`, which is the clickhole; the proxy is what actually fixes §2.1.
2. **CODEOWNERS split (fail-safe, config-only, no iris code):**
   ```
   * @bnaylor                               # default: Brian (floor)
   /docs/     @iris-main @sackheads-bot      # routine: either bot may approve the other's PR
   /assets/   @iris-main @sackheads-bot
   /.github/CODEOWNERS @bnaylor              # the gate protects itself
   ```
   **`/Tests/` is NOT in the routine set** (Iris's finding 2): it is executable host Swift (runs under
   `swift test` outside any sandbox) and holds the security/source-scan gates — a bot pair must not be
   able to weaken a security test or merge host-executing code. Start with `/docs/` + `/assets/` only.
   `Sources/` stays `@bnaylor` entirely (Iris's finding 3: it is almost all boundary code; a denylist of
   boundary files is fail-open and missed 25+ files — do not go that route).
   **Ruleset requirement:** the `main` ruleset must have **"Dismiss stale PR approvals when new commits
   are pushed"** enabled, or an approval rides a later push.

## 3. The proxy tools (C2 — spend, never possess)

Host-side Swift tools that read `iris-main`'s token from the Keychain **themselves** and call the GitHub
REST API directly; the token value never enters a prompt, tool arg, tool result, `run_command` env, or
the sandbox env. Three tools (Iris's review finding 2 added the third):

- **`github_create_pr(repo, head, base, title, body, draft?)`** — `POST /repos/{owner}/{repo}/pulls`.
  **This is what makes Iris author as `iris-main` (§2.1).** `gh pr create` via `run_command` would author
  as ambient `@bnaylor`; the proxy authors as the token's identity. Code (`git push`) continues over the
  existing SSH remote, so the token never needs `Contents: write` (§4).
- **`github_comment(repo, pr, body)`** — `POST /issues/{n}/comments`. Satisfied by `Issues: write` (M2).
- **`github_approve(repo, pr)`** — `POST /pulls/{n}/reviews` with `APPROVE`. M2's deliberate escalation
  (needs `Pull requests: write`), made safe by the §3.2 code gate.

### 3.1 Harness integration — specify it or it collides (Iris finding 1)
Adding these tools to `ToolExecutor`/`IrisEngine` must be specified against three existing mechanisms:

- **Declare only when configured (Invariant 6).** Omit the three declarations when no `iris-main` token
  is present in the Keychain, behind an injectable `githubToolsEnabled: Bool` seam on
  `ToolExecutor.getTools` (like `workspaceToolsEnabled`). Otherwise an unconfigured install pays prompt
  tokens every turn and `ToolSurfaceTrimTests.plainTurn` (tool-count ≤ 20) fails.
- **Attended `.main` only.** None of the three is reachable by `.subagent`, `.evaluator`, `.mcpGuest`, or
  an unattended background job. Add them to `IrisEngine.mainOnlyDeclared` and
  `IrisEngine.unattendedNeverDeclared`, add them to `JobProfile.readOnlyDenies`, and require
  `principal == .main && !isUnattended` in `executeFunctionCall` (defence in depth: declared *and*
  dispatch-refused, per Invariant 6).
- **OutboundTools / taint.** A reviewer session reads untrusted content (`gh pr diff`, repo files, a peer
  message) before calling these, setting `hasUntrustedToolOutput`. If the three are in
  `OutboundTools.builtIn`, every review comment/approval raises a `humanOnly` card in a non-YOLO session —
  trading the GitHub clickhole for an Iris clickhole. **Decision: these three are EXEMPT from
  `OutboundTools.builtIn`** — the taint-based outbound gate is replaced here by the stronger, specific
  controls (the §3.2 repo allowlist + routine-file + SHA-bind gate, attended-`.main`-only, and the
  least-privilege token). State this exemption explicitly and pin it with a test.

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
`github_approve` refuses unless **every changed file is inside the routine allowlist** (`docs/`, `assets/`),
bound to an exact commit — hardened against three bypasses Iris flagged:

1. **SHA-keyed, no TOCTOU.** `GET /pulls/{n}/files` is not keyed to a SHA. Resolve `head.sha` from
   `GET /pulls/{n}`, then fetch the changed files via the **SHA-keyed** `GET /compare/{base_sha}...{head_sha}`
   (or re-verify `head.sha` is unchanged both before and after the files call). Submit the review with
   `commit_id = head_sha`, so a push after the check cannot ride the approval.
2. **Pagination fail-closed.** Request `per_page=100` and **refuse if the file count hits 100** (or a
   `Link: rel="next"` is present) — never miss a 101st `Sources/` file on page 2.
3. **Renames + path prefixes.** Require **both** `filename` and `previous_filename` (when non-nil) to begin
   with `docs/` or `assets/` (GitHub API paths have no leading `/`), with no `..` segments — so a
   `Sources/IrisKit/x.md` → `docs/x.md` rename can't slip a Sources change past the check.

The token value is scrubbed from any tool output as defence in depth; the primary control is that it was
never reachable.

## 4. The one account + the §8.1 interim (isolated `gh` config)

- **One account, minimal:** `iris-main` as a `github` **service** account (owner-class *service*, per
  11-09). Not the full typed registry — a single Keychain item + a lookup the proxy tools use. It is the
  precursor the #966 registry generalizes later; this slice does not build the registry.
- **Keychain service naming (Iris finding 4):** name the service constant in `KeychainManager` (or a key
  in an existing service), and note whether `DevHomeSeeder` copies it when seeding `~/.iris-dev` from
  `~/.iris` (it copies `legacyService` + `mcpFileService` + `iris.plugin.*` today) so `run-dev.sh`
  sessions have the token without manual re-entry.
- **Token scope (least privilege, M2 backstop):** `Pull requests: write` + `Issues: write` — and
  **not** `Contents: write`, since `git push` stays on the existing SSH remote and the proxy only calls
  `POST /pulls`, `POST /issues/{n}/comments`, `POST /pulls/{n}/reviews` (so the token can never push code
  to any branch). Scoped to the **user-configured allowed repos** (§3.2), not a fixed repo — no admin,
  settings, or secrets. `PR: write` is the escalation `github_approve` needs; the §3.2/§3.3 code gates are
  the primary control, this scope is the backstop. (The GitHub-side PAT scope and the in-Swift allowlist
  are two independent layers; the Swift allowlist is authoritative because it's checked before any call.)
- **Interim token path (Iris's finding 5):** `iris-main`'s token must **not** go into
  `~/.config/gh/hosts.yml` or a global `GH_TOKEN` — that clobbers `@bnaylor`'s `gh` identity or leaks
  the token to every session/subagent. Hold it in the Keychain and have the proxy tools read it
  directly (they call the GitHub API, not `gh`). If a `gh`/`git` invocation is ever needed on this path,
  use an **isolated `GH_CONFIG_DIR`** scoped to the proxy, never the ambient one.

## 5. Non-goals / anti-goals

- No forge abstraction; GitHub only.
- No `AccessProfile`/`Binding`/registry/memory-scoping/A2A (11-09's scope).
- `/Tests/` and `/Sources/` never bot-approvable in this slice.
- The raw token never reachable by the model (C2); approve is never a blank check (§3.3 gate).
- **No hardcoded repo list** — the allowed repos are a user-configurable, protected setting (§3.2); Iris
  is not iris-repo-only. But the enforcement is in code and defaults fail-closed.
- The `github_*` tools are never reachable by subagent/evaluator/guest/unattended, and never author or
  approve as `@bnaylor`.
- Does not claim to close C1 (ambient host auth for non-owner principals) — that is 11-09.

## 6. How it plugs into 11-09

- `github_comment`/`github_approve` are the **first instances of the C2 proxy surface** 11-09 §Credential
  registry specifies; when #966 lands, the `iris-main` account moves into the typed registry and the
  proxy ops become account-scoped there — no rework of the tools' shape.
- The CODEOWNERS split and the approve code-gate are independent of the registry and ship now.
- The "decider is never the requester" hardening (approve in a separate owner-authority session from the
  one reading untrusted diffs — 11-09's broker principle) is a **future tightening**; this slice's
  control is the §3 allowlist+SHA code gate, which bounds the blast radius to routine docs/assets PRs.

## 7. Slice contents / sequencing

1. **Config-only (no iris code), ships first:** create/scope `iris-main`'s token; CODEOWNERS split (§2);
   enable stale-approval dismissal on the ruleset. Lands independent of any build.
2. **The two proxy tools + the account lookup + the approve gate (§3/§4):** the iris-code slice. Small,
   contained, host-side; rule-26 reviewed (it is credential + approval boundary code).
3. Everything else is 11-09.

## 8. Review focus (rule-26, for this spec then the slice)

- **C2 honoured:** the token is never in a prompt/arg/result/env/sandbox; the proxy reads the Keychain
  itself. Mutation: a test that the token string never appears in any tool output or env.
- **The approve gate is load-bearing:** `github_approve` refuses unless every changed file at the bound
  `headRefOid` is in the routine allowlist, and binds `commit_id`. Reproduce: a PR touching a
  `Sources/`/`Tests/` file is refused; a push after the check does not ride the approval.
- **CODEOWNERS is fail-safe** (default `@bnaylor`, `/docs`+`/assets` only, `/Tests/` and `/Sources/`
  excluded, self-protected) and stale-approval dismissal is on.
- **No ambient `@bnaylor` on the proxy path:** `iris-main`'s token does not touch
  `~/.config/gh`/global `GH_TOKEN`.
