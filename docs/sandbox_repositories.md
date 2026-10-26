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

## Untrusted Repositories

A repository created inside a sandbox (for example, with `git init` at the workspace root or in any subfolder) or cloned nested inside a mounted folder has its `.git` located in the VM-writable worktree. It does not have an isolated sandbox-git copy seeded from the host, making it untrusted.

### Walk-Up Discovery
Before each host `run_command`, Iris inspects:
1. The working directory, walking up parent directories until it finds the nearest `.git` or bare git directory (`HEAD`, `objects/`, `refs/`) without running git.
2. Paths in the command passed via `-C`, `--git-dir`, `--work-tree`, `GIT_DIR`, `GIT_WORK_TREE`, `cd`, or `pushd`, any `GIT_DIR` or `GIT_WORK_TREE` in the environment, and mounted folders reachable from the working directory or named in the command.

### Scope
A repository found by discovery is in scope for judging if its worktree or common directory sits inside any folder a sandbox has mounted read-write.

### Trust Check
A repository is **trusted** only if:
1. Its canonical common directory matches the first line of the `iris-sandbox-seed` marker file in its corresponding `sandbox-git` copy.
2. No recorded mounted folder strictly contains its worktree or common directory (a parent folder mount does not have the root `.git` overlay).
3. It was not marked `"untrusted": true` (upgraded from an earlier `blocked` or `adopted` record) in `config/sandbox-workspaces.json`. An entry upgraded from `blocked` or `adopted` stays untrusted across restarts; once you have inspected `.git/config` and confirmed the repository is clean, you can clear it by removing `"untrusted": true` (or that folder's entry) in `config/sandbox-workspaces.json`.

Everything else in scope is untrusted.

### Judging Rules
For an untrusted repository:
- **Pointer and index check:** Any `.git` pointer in a mounted worktree or submodule gitlinks in the index pointing outside the repository is quarantined (or refuses the command if it cannot be moved aside or if the index is unreadable). In fail-closed mode when the workspace store is unreadable, repositories outside recorded mounts are checked without renaming files on disk.
- **Configuration allow-list:** Iris inspects all configuration files for the repository (`config`, `config.worktree`, submodule configs under `modules/**/config`, and linked worktree configs). Allowed keys include standard `git init` defaults (`core.repositoryformatversion`, `core.filemode`, `core.bare`, `core.logallrefupdates`, `core.ignorecase`, `core.precomposeunicode`, `core.symlinks`), remotes, upstream branch settings, `user.*`, and exact Git LFS filter values.
- **Git LFS exemption:** Exact Git LFS settings (`WorkspaceGit.lfsValues`) are permitted. Any modified or custom filter value under `filter.lfs` is not exempt.
- **Global and system git config:** If a mounted folder covers `~/.gitconfig`, `~/.config/git/config`, or any file they include via `include.path` or `includeIf.<cond>.path` (or if the mounted-folders list is unreadable), Iris sets `GIT_CONFIG_GLOBAL=/dev/null` on host commands so git ignores the global config without refusing ordinary commands. Similarly, if a mounted folder covers the system git config (or a file it includes), Iris sets `GIT_CONFIG_NOSYSTEM=1`.
- **Refusal:** If any configuration file cannot be read, or sets a key outside the allow-list (such as `core.hooksPath`, `core.fsmonitor`, `diff.external`, or custom filters), the host command is refused with a message identifying the disallowed key.
- **No hooks execution:** If the repository's configuration is safe, host git runs with hooks disabled by setting `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=core.hooksPath`, `GIT_CONFIG_VALUE_0=/dev/null` (after clearing any inherited `GIT_CONFIG_*` environment variables).
- **Notice:** The first time Iris encounters an untrusted repository, it posts a notice in chat:
  `"[sandbox] A repository at <path> was created or modified in a sandbox. Git that Iris runs on your Mac there runs no hooks. Git run from your own terminal there is not protected."`

## Unreadable Workspace Store

Iris records the folders sandboxes have mounted read-write in `config/sandbox-workspaces.json` across restarts.

If this file cannot be parsed or decoded:
- Iris moves the unreadable file aside to `sandbox-workspaces.json.corrupt` (using incremented `-N` suffixes if previous copies exist, never overwriting).
- If the file cannot be moved aside, saving is disabled to avoid overwriting.
- While a `.corrupt` copy exists, Iris **fails closed**: every repository found by the walk-up (mounted or not) is judged as untrusted unless it is a trusted sandbox-git copy.
- A notice is emitted once per launch explaining that Iris could not read its list and that deleting the `.corrupt` copies ends the fail-closed state.

## Limitations

- **Your own terminal is not protected:** Git run directly from your own terminal inside an untrusted repository is not monitored or protected by Iris.
- **Mounted parent folders:** Mounting a parent folder such as `~/src` makes every repository located under it untrusted when accessed by host commands.
- **Detached HEAD commits:** Commits made in the sandbox while in a detached HEAD state are not brought back via bundles, and will be discarded when the sandbox copy is cleaned up.
- **Alternates:** Repositories whose host objects borrow from another location (`objects/info/alternates`) cannot be safely read by the VM.
