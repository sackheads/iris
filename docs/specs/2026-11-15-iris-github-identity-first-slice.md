# First slice: Iris reviews routine PRs as herself (`iris-main`) — consumer-spec under #974

> **Status:** spec by iris-planner, 2026-11-15. **This is a FIRST-SLICE consumer-spec, not a design.**
> The boundary design is `docs/specs/2026-11-09-unified-access-boundary-design.md` (#974 v2, audited).
> This doc does **not** redefine `Principal` / `AccessProfile` / `Binding` / the C1–C8 seam closures —
> 11-09 owns those. It scopes the **minimum wedge** that gets "Iris clears routine PRs as herself"
> working safely, using 11-09's **C2 proxy** pattern for its one credential. It **supersedes** the
> retired standalone draft `2026-11-14-profile-credential-substrate-SPEC.md`, which reinvented the
> boundary and was correctly rejected (Iris's review, 2026-11-14: dropped C1/C2/M2/M3, wrong seam,
> contradicted M2). Destination on sign-off: `docs/specs/2026-11-15-iris-github-identity-first-slice.md`.

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

1. **Iris authors as `iris-main`** (not ambient `@bnaylor`) — via the §4 token path.
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

## 3. The two proxy tools (C2 — spend, never possess)

Host-side Swift tools, reading `iris-main`'s token from the Keychain **themselves**; the token value
never enters a prompt, tool arg, tool result, `run_command` env, or the sandbox env.

- **`github_comment(repo, pr, body)`** — posts a PR conversation comment. Satisfied by an
  `Issues: write` token (M2).
- **`github_approve(repo, pr)`** — submits an `APPROVE` review. This is M2's **deliberate escalation**
  (approve needs `Pull requests: write`), made safe by a **code gate that runs before the API call**
  (Iris's finding 2):
  1. resolve the PR's current `headRefOid`;
  2. refuse unless **every changed file at that `headRefOid`** is inside the routine allowlist
     (`/docs/`, `/assets/`) — an injected PR touching anything else cannot be self-approved;
  3. bind the review to that exact `headRefOid` (`commit_id`), so a push after the check can't ride it.

The token value is scrubbed from any tool output as defence in depth; the primary control is that it was
never reachable.

## 4. The one account + the §8.1 interim (isolated `gh` config)

- **One account, minimal:** `iris-main` as a `github` **service** account (owner-class *service*, per
  11-09). Not the full typed registry — a single Keychain item + a lookup the proxy tools use. It is the
  precursor the #966 registry generalizes later; this slice does not build the registry.
- **Token scope (least privilege, M2 backstop):** `Pull requests: write` + `Issues: write` on
  `sackheads/iris` only — no admin, settings, secrets, or other repos. `PR: write` is the escalation
  §3's `github_approve` needs; the §3 code gate is the primary control, this scope is the backstop.
- **Interim token path (Iris's finding 5):** `iris-main`'s token must **not** go into
  `~/.config/gh/hosts.yml` or a global `GH_TOKEN` — that clobbers `@bnaylor`'s `gh` identity or leaks
  the token to every session/subagent. Hold it in the Keychain and have the proxy tools read it
  directly (they call the GitHub API, not `gh`). If a `gh`/`git` invocation is ever needed on this path,
  use an **isolated `GH_CONFIG_DIR`** scoped to the proxy, never the ambient one.

## 5. Non-goals / anti-goals

- No forge abstraction; GitHub only.
- No `AccessProfile`/`Binding`/registry/memory-scoping/A2A (11-09's scope).
- `/Tests/` and `/Sources/` never bot-approvable in this slice.
- The raw token never reachable by the model (C2); approve is never a blank check (§3 gate).
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
