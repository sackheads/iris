# GitHub Identity (`iris-main`)

`iris-main` is Iris's own GitHub contributor identity (#966, the first slice of the #974 access
boundary) — a real account, like `sackheads-bot`, that she commits, pushes and opens pull requests
as, independent of `@bnaylor`'s own identity. This closes the actual clickhole the feature was
built for: a session running under your ambient `gh`/git auth authors its own PRs as `@bnaylor`,
and with `CODEOWNERS = * @bnaylor` nobody — including you — can approve your own PR. `iris-main`
fixes part one (she authors as herself); CODEOWNERS plus an approval gate fix part two for
*other* routine PRs (yours, or `sackheads-bot`'s): she can clear them without that being a blank
check. GitHub still blocks an author approving their own PR, so an `iris-main`-authored PR still
needs a second code owner — see "The one open decision" below.

**The one thing locked down is approval, not contribution.** Iris pushes and opens PRs as
`iris-main` freely. What stays under `@bnaylor` is approval of anything that matters:
`CODEOWNERS` makes `iris-main`'s own approval count only for `/docs/` and `/assets/` — a structural
guarantee, not a request she might ignore — and the `github_approve` tool refuses to even submit an
approval on anything else, as defence in depth on top of that.

## The three tools

Three host-side tools, declared to the model only when both a token and a non-empty allowed-repos
list are configured (see "Setup" below), and only on an attended, non-guest-origin main
conversation — a subagent, evaluator, MCP guest, unattended job run, or a turn a guest's message
started or steered loses them even if one somehow reaches the dispatcher. Every call is bound to
the user-configured allowed-repos list before anything else happens — a repo not on the list sends
nothing.

- **`github_create_pr(repo, head, base, title, body, draft?)`** — opens a pull request as
  `iris-main`, from a branch already pushed. `draft` defaults to `true` unless the model says
  otherwise.
- **`github_comment(repo, pr, body)`** — posts a PR comment as `iris-main`.
- **`github_approve(repo, pr)`** — submits an `APPROVE` review as `iris-main`, but only if the PR
  is open and every changed file (including a rename's source path) is under `docs/` or `assets/`;
  anything else is refused outright, never submitted. The approval is bound to the exact commit
  checked (so a push after the check can't ride it), and the result says if the PR moved while it
  was being checked.

The token itself is read from the Keychain only inside the client that makes these calls; it never
appears in a prompt, a tool argument, a tool result, or an error string (scrubbed as hygiene, not
as the control — see "What the credential is," below).

## `iris-main` as a git contributor

Beyond the three tools, `run_command`'s own host git also acts as `iris-main` when it touches an
allowed repo — this is what lets Iris push the branch `github_create_pr` then opens a PR from.

- **Identity.** Commits attribute to `iris-main` (`user.name`/`user.email`, the latter GitHub's own
  `iris-main@users.noreply.github.com` noreply address — no separate email to configure).
- **Credential.** A git credential helper (`iris --git-credential-helper`, invoked by git itself,
  never by the model) hands out the same Keychain token for a push or fetch to an allowed repo,
  checked against the live allowlist on every request.
- **Isolation.** None of this touches `~/.gitconfig` or any other ambient git/`gh` state. It's
  injected per `run_command` invocation, scoped to exactly the repos on the allowlist — a remote
  for any other repo behaves exactly as it did before this feature existed.

### What the credential is

The design goal is **identity separation, not credential-hiding.** `iris-main`'s PAT is Iris's own
contributor credential, the same way `sackheads-bot`'s tooling holds its credential — Iris already
runs from a highly privileged place on your Mac, so hiding this one token from the model buys
nothing. What actually bounds `iris-main` is **not** a withheld token scope: the PAT has
`Contents`, `Pull requests` and `Issues`, each read and write — a real contributor needs to push.
The bound is branch protection (a PR plus a code-owner review to merge) and CODEOWNERS (her
approval only counts for `/docs/` and `/assets/`), with the in-Swift allowlist and the
`github_approve` gate on top.

## Setup

**No Settings UI in this slice** — deferred to the planned profile pane (#961). Configure by
command instead:

1. **On GitHub**, once, in the web UI or `gh`:
   - Ensure the `iris-main` account exists, and make it a **write collaborator** on each repo Iris
     should act on.
   - Issue it a **fine-grained PAT**, scoped to those repos only, with `Contents`, `Pull requests`
     and `Issues` each set to **read and write** — no Administration, Secrets, Workflows or
     Settings. Give the account a verified email.
   - Commit a `.github/CODEOWNERS` file:
     ```
     * @bnaylor
     /docs/     @iris-main @sackheads-bot
     /assets/   @iris-main @sackheads-bot
     /.github/CODEOWNERS @bnaylor
     ```
     `Sources/` and `Tests/` are deliberately absent — they fall under `* @bnaylor`, so only you
     can approve code or test changes. `@bnaylor` is also deliberately absent from the `/docs/`
     and `/assets/` lines themselves: GitHub takes a file's owners from the last matching
     pattern, not every pattern that matches, so once a line names `/docs/` or `/assets/` the top
     `* @bnaylor` line no longer applies there. Leaving you off those two lines on purpose is what
     keeps them routine and bot-to-bot: adding yourself back would let your own review satisfy
     "review from code owners" on them, undoing the point of the split.
   - On the `main` ruleset, require a pull request with review from code owners, and enable
     **both** "Dismiss stale pull request approvals when new commits are pushed" **and** "Require
     approval of the most recent reviewable push." Both matter: stale-dismissal fires at push
     time, so without the second setting a late approval of an older, routine-only commit could
     still count toward merging a newer head that added a `Sources/` change.
2. **On the Mac**, after updating to a build with this feature:
   ```sh
   printf '%s' '<the iris-main PAT>' | iris --set-github-token
   printf 'owner/repo\n' | iris --set-github-repos
   ```
   Both read from stdin, never argv (argv is visible in `ps`). The repos list is one `owner/name`
   per line; the allowlist is empty — nothing is allowed — until you set it, and the setter
   refuses the whole write if any line is malformed. Then **launch Iris once**: both settings are
   read at launch and cached for that run, so a value written while Iris is already open takes
   effect on the next launch, not live.

Once both the GitHub-side and Mac-side setup are done, Iris can already **approve other people's
routine PRs** (yours, or `sackheads-bot`'s) as `iris-main` — that's the main clickhole relief, and
it works without anything further.

### The one open decision: `sackheads-bot`

`CODEOWNERS` names both `@iris-main` and `@sackheads-bot` as owners of `/docs/` and `/assets/`.
`iris-main` approving *other* routine PRs works today. `iris-main`'s *own* authored PRs
(`github_create_pr`) can't be self-approved — GitHub blocks an author approving their own PR —
so an Iris-authored routine PR still needs a second code owner's approval: either you approve it
manually as `sackheads-bot`, or a second proxy giving `sackheads-bot` the same tooling (tracked as
a follow-up, #1170, not part of this slice).

## Known limitations

- **A second remote in the same checkout, named as an extension of an allowed repo, fails loudly
  rather than silently.** The `includeIf` git config that scopes the identity and credential to an
  allowed repo is per-*repository* (so an unrelated repository, or a repository elsewhere on disk,
  is never affected) but not per-*remote*: once any remote in a checkout matches an allowed repo
  and loads the routing config, that config's rewrite rules apply to every remote resolved in that
  same checkout. A second remote whose name is a literal string extension of the allowed one (for
  example `owner/iris` allowed, a second remote pointing at `owner/iris-fork`) gets its URL mangled
  and the push or fetch fails outright. This is the accepted trade: the alternative — not rewriting
  at all — is exactly the silent fall-back to your own ambient SSH key that this feature exists to
  prevent. In practice this only bites a checkout that deliberately keeps a second, unrelated
  remote whose name happens to extend an allowed one.
- **Iris-authored routine PRs need a second approver** until the `sackheads-bot` follow-up lands
  (see above).

## Review focus

The input classes a reviewer of this feature's code should check: a PR touching `Sources/` or
`Tests/` (directly, by rename, or on a later page of changed files) is refused by `github_approve`;
a push landing after the approve check does not ride the approval; a repo not on the allowlist
reaches neither the tools nor `run_command`'s git identity; a guest-origin or unattended turn never
sees the tools even if a call is forged; the credential never appears in a tool result or error
string; the git-identity environment never changes behavior for a repo that isn't on the
allowlist.
