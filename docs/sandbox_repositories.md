# Repositories in the Sandbox

Git on your Mac runs programs named in a repository's hooks and configuration (`core.hooksPath`, `core.fsmonitor`, `diff.external`, filter drivers, and more). When a sandboxed workspace is a git repository, Iris ensures that commands running inside the VM cannot choose what git on your Mac runs (#623, #658).

Iris achieves this through four coordinated defenses: giving the VM its own isolated git directory, bringing commits back via bundles, checking worktree pointers, and judging untrusted repositories before host commands run.

## The Sandbox's Own Git Directory

The first time a repository is mounted read-write in a sandbox, Iris prepares a VM-only copy of its common directory under `sandbox-git/<key>` inside Iris's home directory (`~/.iris` or `~/.iris-dev`).

- **Isolated storage:** The copy includes repository configuration, refs, `HEAD`, and `info/exclude`, but excludes objects, hooks, and logs.
- **Read-only host mount:** Your Mac's `.git` is mounted into the VM read-only, and the VM copy reaches objects through alternates. Nothing large is copied.
- **Over-mount in the VM:** The VM's copy is mounted over `.git` (or at the path a linked worktree's `.git` file points to). Git commands in the VM read and write only this copy; your host hooks and configuration are never touched.
- **Worktree sharing:** Two workspaces sharing the same underlying repository share one sandbox copy.
- **Refusals:** A `.git` entry that is a symbolic link refuses sandboxed commands. A one-off sandboxed command without an active conversation is refused in a repository because its commits cannot be synced back.
- **Cleanup:** The VM copy is removed once no conversation's workspace uses that repository.

## Syncing Commits to Your Mac

Commits made in the sandbox reach your Mac as plain data files, never by host git reading the VM's copy:

- **Bundle transfer:** After each sandboxed command that advances a branch, Iris creates a git bundle and fetches it into `refs/iris/sandbox/<branch>` on your host repository.
- **Clean fast-forward:** If that branch is currently checked out on your Mac, the move is a clean fast-forward, your working tree matches the commit, and there are no staged changes, Iris advances your branch and index to match. No checkout is performed, no files are written, and no hooks are run. Chat reports the update: `"Moved main 1a2b3c4..5d6e7f8 (2 commits from the sandbox)"`.
- **Divergence and dirty state:** If your working tree has uncommitted modifications, staged changes exist, HEAD is detached, or the branch is checked out in another worktree, your host branch stays where it is. The commits wait on `refs/iris/sandbox/<branch>` for you to inspect or merge, and the chat explains why.
- **Host forward sync:** Before each sandboxed command, if your Mac has moved ahead on the shared checked-out branch, the sandbox copy fast-forwards to match.

## Worktree Pointer Checks

A few git files live in the shared worktree where the VM could modify them:

- **Pointer quarantine:** A submodule's `.git` pointer file or a linked worktree's `.git` file that points outside your repository's own git directory is moved aside to `<name>.iris-quarantine[-N]` before host git runs and after each sandboxed command. Iris reports the quarantined file in chat; if you trust it, you can rename it back after the session ends.
- **Notices:** If the sandbox modifies `.gitmodules` or `.lfsconfig`, Iris reports the change in chat. While these files cannot execute programs directly, commands like `git submodule sync` or `git-lfs` read their URLs.

## Mount-Time Protection for Your Repositories

When a read-write mount is created, Iris runs a capped walk (`WritingScripts.survey`, bounded at 200,000 entries or 2 seconds) to discover any git directories (`.git` directories, `.git` files, and bare repositories holding `HEAD`, `objects/`, and `refs/`):

- **Allowed read-write mounts:** A folder holding no repository, or holding only the overlaid workspace repository at the mount root (plus any submodules whose git directory sits inside `<root>/.git/modules`), goes ahead as usual.
- **Refusal on nested repositories:** If a read-write mount contains any other repository (for example, mounting `~/src` or your home folder when it holds clones), Iris refuses the mount, names the repositories it found, and suggests mounting the single repository you are working in instead. Your own repositories are never left both VM-writable and unprotected.
- **Fail-closed walk caps:** If the walk hits its entry or time cap (`200,000` entries or `2` seconds) or encounters an unreadable folder or another volume, Iris refuses the read-write mount and names the limit.

## Run-Time Quarantine of VM-Made Repositories

Repositories known when a read-write mount is created form the baseline. Any git directory found later under a read-write mount was created by the VM. Rather than trying to guess from command strings which nested repository a host shell command might enter, Iris neutralizes unsafe VM-made repositories directly on disk:

- **Allowlist check:** A newly created git directory is left alone on disk only if:
  1. Its configuration (`config`, `config.worktree`, submodule configs under `modules/**/config`, and linked worktree configs) passes the configuration allowlist (`GitConfigFile.isAllowed`, standard `git init` defaults, and exact Git LFS filter values `WorkspaceGit.lfsValues`).
  2. Its `<gitdir>/hooks` and `<gitdir>/modules/**/hooks` contain no executable file (or symlink) other than `*.sample`.
  3. It has no out-of-repo `.git` file/symlink, `commondir`, `gitdir`, or submodule gitlink pointer.
  A plain `git init` or `git clone` inside the workspace passes all three checks and stays intact.
- **On-disk quarantine:** If a VM-made repository fails any of the three checks, Iris renames its `.git` to `.git.iris-quarantine[-N]` (or, for a bare/non-`.git` directory such as `foo/` or `.notgit/` holding `HEAD`, `objects/`, and `refs/`, renames the directory itself to `<name>.iris-quarantine[-N]`). Once renamed, neither Iris's host commands nor git run from your own terminal will discover or read it. Iris posts a notice naming the quarantined path and the setting or hook that failed.
- **When checks run:**
  - Continuously via an `FSEventStream` watching each live read-write mount (with a full capped rescan on `MustScanSubDirs` or dropped events).
  - Synchronously after each VM command returns (before its result goes back).
  - Synchronously before each host spawn (`run_command`, hooks, plugin `check_command`, and silent git reads), flushing the FSEvents stream with `FSEventStreamFlushSync`.
  - At session end (`endSession` / `reapIdle`).
- **Crash or quit recovery:** Each live read-write mount is recorded durably with `"live": true` in `config/sandbox-workspaces.json` when the mount starts, and cleared at a clean session end. If Iris crashes or quits mid-session, the next launch runs the capped scan and quarantine on every mount still marked `live` before any host command can spawn (silently dropping any mount path that no longer exists on disk).
- **Fail-closed on uncheckable mounts:** If the VM creates more than 200,000 entries inside a mount so the check cannot finish, host spawns reaching that mount are refused with a message explaining why.
- **Global and system git config:** If a mounted folder covers `~/.gitconfig`, `~/.config/git/config`, or any file they include via `include.path` or `includeIf.<cond>.path` (or if the mounted-folders list is unreadable), Iris sets `GIT_CONFIG_GLOBAL=/dev/null` on host commands so git ignores the global config without refusing ordinary commands. Similarly, if a mounted folder covers the system git config (or a file it includes), Iris sets `GIT_CONFIG_NOSYSTEM=1`.

### Virtiofs FSEvents and Walk Measurements

Measured on macOS with `apple/container` (`ubuntu:latest` over virtiofs) and a 105,000-file workspace (105 `node_modules/pkg_*` directories, `105,106` total entries):

- **Virtiofs FSEvents delivery:** Writes from inside the Linux VM to a shared virtiofs mount (`plain.txt`, `nested/.git/config`, and `bare/HEAD` + `objects/` + `refs/`) are delivered to a host `FSEventStream` both asynchronously (within ~50–250 ms) and synchronously via `FSEventStreamFlushSync` (`0.076 ms` flush time).
- **105k-file workspace initial capped walk:** `0.252 s` (`105,106` entries, under the `200,000`-entry / `2.0 s` cap).
- **Per-spawn `FSEventStreamFlushSync` cost on a 105k-file workspace:** `0.018 ms` mean (`0.040 ms` max across 50 calls), well below the 50 ms threshold.

## Unreadable Workspace Store

Iris records the folders sandboxes have mounted read-write in `config/sandbox-workspaces.json` across restarts.

If this file cannot be parsed or decoded:
- Iris moves the unreadable file aside to `sandbox-workspaces.json.corrupt` (using incremented `-N` suffixes if previous copies exist, never overwriting).
- If the file cannot be moved aside, saving is disabled to avoid overwriting.
- While a `.corrupt` copy exists, Iris **fails closed**: every repository found by the walk-up (mounted or not) is judged as untrusted unless it is a trusted sandbox-git copy.
- A notice is emitted once per launch explaining that Iris could not read its list and that deleting the `.corrupt` copies ends the fail-closed state.

## Residual Risk and Limitations

- **FSEvents delivery window in your own terminal:** Between a VM write and the next FSEvents delivery (milliseconds, unless the stream drops events), your own terminal (or a git-aware shell prompt such as oh-my-zsh, starship, or p10k) can run a planted configuration before quarantine completes. Iris's own host spawns are covered by the synchronous `FSEventStreamFlushSync` before every spawn; your terminal is not.
- **Unusual `GIT_DIR` split across folders:** The watcher recognizes a git directory by its contents (`HEAD` plus `objects/` and `refs/`), so `foo/` or `.notgit/` is quarantined just like `.git`. A git directory split across folders, or built after the check and reached only through an explicit `GIT_DIR` in a command or script, is not detected by directory shape alone. Your terminal never points `GIT_DIR` at such a folder by itself, a host command that sets `GIT_DIR` is not auto-approved as a read-only command, and silent git reads pin `GIT_DIR` to the workspace.
- **VM-written scripts run on the host:** Running a VM-written script on the host (for example, `sh ./run.sh`) is already executing arbitrary VM-written code on your Mac, with or without git. On-disk quarantine removes the git configuration/hook route through it, but cannot make an approved VM-written script safe.
- **Detached HEAD commits:** Commits made in the sandbox while in a detached HEAD state are not brought back via bundles, and will be discarded when the sandbox copy is cleaned up.
- **Alternates:** Repositories whose host objects borrow from another location (`objects/info/alternates`) cannot be safely read by the VM.
