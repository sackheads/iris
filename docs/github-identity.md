# GitHub Identity

Iris's own GitHub contributor identity (#966, the first slice of the #974 access
boundary) is a real account, like `sackheads-bot`, that she commits, pushes and opens pull requests
as, independent of your own identity. **The account is yours to name** (#1184): create one and give its
username in Settings (or `iris --set-github-login`). This page calls it `<account>`; in the
repository this feature was built in, it is `iris-main`. Until a username is set, Iris behaves as if
no token were configured: the tools are not offered and git is untouched. This closes the actual clickhole the feature was
built for: a session running under your ambient `gh`/git auth authors its own PRs as `@bnaylor`,
and with `CODEOWNERS = * @<you>` nobody — including you — can approve your own PR. The account
fixes part one (she authors as herself); CODEOWNERS plus an approval gate fix part two for
*other* routine PRs (yours, or `sackheads-bot`'s): she can clear them without that being a blank
check. GitHub still blocks an author approving their own PR, so an account-authored PR still
needs a second code owner — see "The one open decision" below.

**The one thing locked down is approval, not contribution.** Iris pushes and opens PRs as
the account freely. What stays under you is approval of anything that matters:
`CODEOWNERS` makes the account's own approval count only for `/docs/` and `/assets/` (not their `plans/` and `specs/` folders) — a structural
guarantee for `Sources/`/`Tests/`, not a request she might ignore — and the `github_approve` tool
refuses to even submit an approval on anything else, as defence in depth on top of that. For a
rename *out of* `plans/`/`specs/` specifically, CODEOWNERS is not that guarantee (see "The three
tools" below) — `github_approve`'s own check is the only thing standing there, not a second layer.

## The tools

Two host-side tools, declared to the model only when a token, the account's username and a
non-empty allowed-repos list are all configured and GitHub confirms the token is that account's (see
"Setup" below). Every call is bound to the user-configured allowed-repos list before anything else
happens: a repo not on the list sends nothing.

- **`vcs(action, repo, …)`** (#1435): an agent's pull requests, under a policy the tool enforces
  rather than an approval prompt.
  - **Actions:**
    - `fetch`: GitHub's `main` into the workspace as `origin/main`, plus a `branch` (as `origin/<branch>`) or a
      pull request's head (`pr`, as `origin/pr/<n>`) if given. Nothing is checked out. Fetching `main` or a role's
      own `agent/<role>/…` branch leaves the conversation as it was. Fetching another session's branch (a
      reviewer fetching the author's), a PR head, or any branch on your own turn brings someone else's code, so
      it taints the conversation.
    - `push`: the workspace's `branch` to GitHub's branch of the same name. It's never `main`, and a role pushes
      only `agent/<role>/…`. With `force`, it replaces GitHub's branch under a lease on what GitHub had a moment
      before.
    - `pr_create`: a draft into `main`, from a branch already pushed. `draft` defaults to `true`.
    - `pr_comment`
    - `pr_ready`: marks a draft PR ready for review, which is a reviewer's lgtm and arms its auto-merge. A role
      may ready only another session's PR, one whose branch is under a different `agent/<other>/…`: never its own,
      and never a branch that isn't an agent's. That's rule 25, told by the head branch, since every agent's PR is
      the same account's. Your own typed turn may ready any.
    - `pr_view`: state, branches and description.
    - `pr_checks`: the CI checks on the head.
  - **Who gets it:**
    - A `.main` session with a `/role`, attended or not. It opens PRs only from branches starting
      `agent/<role>/`.
    - Your own attended conversation, from any branch but `main`.
    - Never a subagent, evaluator, MCP guest, or a turn a guest's message started or steered.
  - **Through a mirror** (#1435 slice 2): `fetch` and `push` go through a bare mirror Iris owns under
    `~/.iris/vcs/`, a protected folder. The workspace never talks to the network. The mirror fetches the branch
    out of it, and `fetch` writes refs into it with a fetch that runs in it with Iris's settings forced.
    Neither step runs the workspace's hooks, filters, diff drivers, `core.fsmonitor` or `url.insteadOf`. A
    symlinked `.git`, or one pointing into Iris's folder, is refused.
  - **`push`'s checks, in the mirror:** no protected path in any of the branch's commits (one added and then
    removed still counts), at most 300 files and 5 MB of new content, and no symbolic link pointing outside the
    repository.
  - **Protected paths:** `pr_create` first lists the branch's changed files (a rename's source
    included). It refuses one under a protected path:
    - `.github/workflows/`, `.github/actions/`, `CODEOWNERS`, `docs/plans/`, `docs/specs/` and `.gitmodules`;
    - `pr_create` checks it when the PR is opened, and `vcs push` checks it on every push. A push made some other
      way (host git, while it still holds the credential) isn't checked;
    - the list lives in `~/.iris/config/vcs-policy.json`, a protected file, and an unreadable one
      refuses every `pr_create`.
  - **The taint gate:** on a conversation that has read outside text, `push`, `pr_create`, `pr_comment` and
    `pr_ready` run only on your own attended turn, where you see the call. Unattended, or on a turn a peer
    started, they're refused and the result says it needs you. `fetch`, `pr_view` and `pr_checks` are reads
    and always run. What `pr_view` and `pr_checks` return taints the conversation, and so does a `fetch` of
    someone else's code (above).
- **`github_approve(repo, pr)`**: attended, non-guest-origin main conversation only. It submits an `APPROVE` review as the account, but only if the PR
  is open and every changed file (including a rename's source path) is under `docs/` or `assets/`
  and not inside a `plans/` or `specs/` folder of `docs/` at any depth (those are instructions that
  sessions read and execute, so a human approves them); anything else is refused outright, never submitted. The approval is bound to the exact commit
  checked (so a push after the check can't ride it), and the result says if the PR moved while it
  was being checked.

  **This is the only place a rename out of `plans/`/`specs/` is actually caught.** GitHub's own
  CODEOWNERS feature resolves ownership from the PR's current diff only — verified empirically
  (#1186): renaming a real `docs/plans/` file to a plain `docs/` path requested the broader `/docs/`
  owner set, not `@bnaylor` alone. A raw `gh pr review --approve` run directly with the account's
  or `sackheads-bot`'s credential, bypassing this tool, has no equivalent check and is **out of
  policy** for approving anything that CODEOWNERS alone would route to a bot.

The token itself is read from the Keychain only inside the client that makes these calls; it never
appears in a prompt, a tool argument, a tool result, or an error string (scrubbed as hygiene, not
as the control — see "What the credential is," below).

## The account as a git contributor

Beyond the two tools, `run_command`'s own host git commits as the account when it touches an allowed
repo. Since #1435's slice 3 it holds **no credential**: a push or fetch goes through `vcs`, whose mirror is
the one place Iris's credential helper runs.

- **Identity.** Commits attribute to the account (`user.name` is its username, `user.email` GitHub's
  `<id>+<account>@users.noreply.github.com` noreply address — no separate email to configure). The
  id comes from the same `GET /user` call that confirms the token's identity. GitHub only
  recognizes the bare `<account>@users.noreply.github.com` form for an account that enabled "Keep
  my email address private" before July 18, 2017; any account set up for this feature now gets
  only the id-based form, so that's the one used (#1188).
- **No credential on host git (#1435, Brian's F5).** Every host `run_command` runs its git with
  `credential.helper` emptied at command scope, which clears any helper from your own config (a
  keychain helper included), and with no askpass and no ssh. So neither Iris's token nor yours is
  reachable from it. `gh`, and git's remote commands (`push`, `fetch`, `pull`, `clone`, `ls-remote`,
  `remote`, `submodule`, …), git spelled as a path or run through another program, and git with `-c`,
  `--config-env`, `--exec-path` or `--git-dir`, are yours alone to approve: no rule, Vibecop or YOLO
  approves them, and Always allow isn't offered. Pushing and fetching are `vcs push` and `vcs fetch`.
  **What this stops, and what it doesn't:**
  - The strip and the person-only list stop the **direct** forms: a `git` command, a helper, `security`, or a git variable in the command itself.
  - A script, a hook or an interpreter on a turn you approved, or **any host turn under YOLO**, can still reach the credential in your login keychain. For example: `bash x.sh`, `security -i`, a hook a repository's `core.hooksPath` names, or `python -c`. No check on a command's text can be complete.
  - The full fix is containing host agents: #1435's S5, parked.

  **Until then, on your side:** in **Keychain Access**, open the `github.com` internet password, go to **Access Control**, choose **Confirm before allowing access**, and remove `git-credential-osxkeychain` from the always-allow list. Any helper read then raises a macOS prompt you can refuse, whoever asks. The same goes for any other token you keep there that an agent shouldn't read silently.
- **Isolation.** None of this touches `~/.gitconfig` or any other ambient git/`gh` state. It's
  injected per `run_command` invocation, scoped to exactly the repos on the allowlist — a remote
  for any other repo behaves exactly as it did before this feature existed.

### What the credential is

The design goal is **identity separation, not credential-hiding.** The account's PAT is Iris's own
contributor credential, the same way `sackheads-bot`'s tooling holds its credential — Iris already
runs from a highly privileged place on your Mac, so hiding this one token from the model buys
nothing. What actually bounds the account is **not** a withheld token scope: the PAT has
`Contents`, `Pull requests` and `Issues`, each read and write — a real contributor needs to push.
The bound is branch protection (a PR plus a code-owner review to merge) and CODEOWNERS (her
approval only counts for `/docs/` and `/assets/`, minus `plans/` and `specs/`), with the in-Swift allowlist and the
`github_approve` gate on top — except a rename out of `plans/`/`specs/`, where CODEOWNERS does not
see the old path and only the `github_approve` check stands (see "The tools" above).

## Setup

Set the account's username, its token and the allowed repositories in **Settings → Integrations →
GitHub**, or by command on a headless machine (step 2). The pane and the commands share one set of
checks, so each accepts the same usernames, tokens and repo lists. The tools are offered only
while GitHub confirms the token belongs to the named account (`GET /user`), since otherwise commits
would be signed as one account while the token acts as another. Three outcomes, all shown in the pane:
**match** (tools on); **mismatch**, GitHub answered with a different username (tools off, and the pane
says "This token belongs to X, expected Y"); and **unverified**, GitHub could not be asked, offline or
an error (tools off, and the pane says it couldn't verify, never that the token is wrong). The check
runs in the background after launch, so the tools appear a moment after Iris starts; it never delays
launch. Saving a token or username in the pane turns the tools off at once and re-checks; an unverified
result is retried at most once a minute, when a turn next asks whether the tools are on. A mismatch is
not retried: fix the token or username (or press Check token).

1. **On GitHub**, once, in the web UI or `gh`:
   - Ensure the account exists (you choose its name), and make it a **write collaborator** on each repo Iris
     should act on.
   - Issue it a **fine-grained PAT**, scoped to those repos only, with `Contents`, `Pull requests`
     and `Issues` each set to **read and write** — no Administration, Secrets, Workflows or
     Settings. Give the account a verified email.
   - Commit a `.github/CODEOWNERS` file:
     ```
     * @bnaylor
     /docs/          @bnaylor @<account> @sackheads-bot
     /assets/        @bnaylor @<account> @sackheads-bot
     /docs/**/plans/ @bnaylor
     /docs/**/specs/ @bnaylor
     /.github/CODEOWNERS @bnaylor
     ```
     `Sources/` and `Tests/` are deliberately absent — they fall under `* @bnaylor`, so only you
     can approve code or test changes. `@bnaylor` is listed on the `/docs/` and `/assets/` lines too:
     GitHub takes a file's owners from the last matching pattern, not every pattern that matches, so
     without you there the top `* @bnaylor` line would not apply and your own approval would not
     clear a docs PR (approval is what sends a PR to the merge queue). The bots' approvals still
     count there. The two `**` lines are later and more specific, so they win: they take
     `docs/plans`, `docs/specs`, `docs/superpowers/plans` and `docs/superpowers/specs` back to you
     alone, because those hold instructions sessions execute and a docs-only PR runs no CI. `**`
     matches zero or more folders, which is why one line covers both depths. CODEOWNERS patterns are
     case-sensitive, so `docs/Plans/` falls to the `/docs/` line; the `github_approve` gate compares
     case-insensitively and refuses it, and so must any other bot approval path.
   - On the `main` ruleset, require a pull request with review from code owners, and enable
     **both** "Dismiss stale pull request approvals when new commits are pushed" **and** "Require
     approval of the most recent reviewable push." Both matter: stale-dismissal fires at push
     time, so without the second setting a late approval of an older, routine-only commit could
     still count toward merging a newer head that added a `Sources/` change.
2. **On the Mac**, enter the account's username, paste its token and add each repository in the
   Settings pane, or run, after updating to a build with this feature:
   ```sh
   printf '%s' '<account-username>' | iris --set-github-login
   printf '%s' '<the account's PAT>' | iris --set-github-token
   printf 'owner/repo\n' | iris --set-github-repos
   ```
   All three read from stdin, never argv (argv is visible in `ps`). The repos list is one `owner/name`
   per line; the allowlist is empty — nothing is allowed — until you set it, and the setter
   refuses the whole write if any line is malformed. A username is 1 to 39 letters, digits and single hyphens (GitHub's own rule); empty input clears it.
   Then **launch Iris once**: all three settings are
   read at launch and cached for that run, so a value saved while Iris is already open, in the
   pane or by command, takes effect on the next launch, not live. The pane says so ("Restart Iris
   for the GitHub tools to change") whenever what is stored differs from what this launch offers.

**First-time setup needs all three:** the account's username, its token and at least one allowed
repository. With any missing, Iris behaves as if no token were configured and the tools are not offered. Even with
all three, they stay off until the check above confirms the token is the account's.

Once both the GitHub-side and Mac-side setup are done, Iris can already **approve other people's
routine PRs** (yours, or `sackheads-bot`'s) as the account — that's the main clickhole relief, and
it works without anything further.

### The one open decision: `sackheads-bot`

`CODEOWNERS` names `@bnaylor`, `@<account>` and `@sackheads-bot` as owners of `/docs/` and `/assets/`.
The account approving *other* routine PRs works today. Its *own* authored PRs
(`vcs`'s `pr_create`) can't be self-approved — GitHub blocks an author approving their own PR —
so an Iris-authored routine PR still needs a second code owner's approval: either you approve it
yourself (you are an owner there), or a second proxy giving `sackheads-bot` the same tooling (tracked as
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
