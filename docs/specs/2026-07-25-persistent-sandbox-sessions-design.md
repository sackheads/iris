# Persistent Sandbox Sessions

## Motivation

When sandboxing is enabled, every `run_command` today shells out to
`container run --rm <image> bash -c <cmd>` — a fresh micro-VM per command. Measured cold-boot
overhead is ~0.85s each (~8–9s per 10 commands), which makes sandboxed coding sessions
painful, and every command starts stateless at `/` with nothing installed.

This spec replaces cold-boot-per-command with **one long-lived container per conversation**,
running each command via `container exec`. It removes the per-command boot tax and lets disk
state (installed packages, temp files, build artifacts) persist across commands within a
session.

This is **Piece 1** of the larger sandboxing rework. It is the execution substrate; the
per-workspace / per-principal **policy model** (main agent host-vs-sandboxed, subagents always
sandboxed, "open mode", directory anchoring) is **Piece 2** and out of scope here. Because
sessions key on `conversationId` and subagents run their own engine with their own id, this
piece already gives subagents isolated containers when sandboxing is on — which Piece 2 will
build on.

**Explicitly out of scope:** full shell-state persistence across commands (the `bash -i`-over-a-
pipe approach — deliberately deferred; see Semantics), the Piece 2 policy model, and changing
how `read_file`/`write_file` work (they stay on the host).

## Existing behavior (unchanged except where noted)

- `ConfigManager.enableSandboxing` (global bool) and `ConfigManager.sandboxImage` are reused.
- Guardrails are untouched: `PermissionManager` allowlist → `VibecopService` (APPROVE/DENY/
  ESCALATE) → user prompt, all before a command reaches `ToolExecutor`.
- The host/guest mount uses identical paths (today `-v cwd:cwd --workdir cwd`), so absolute
  paths match between host `read_file`/`write_file` and sandboxed commands. Preserved.

## Architecture

### `ContainerRuntime` (protocol)

Thin seam over the `container` CLI so the session manager is unit-testable without a real VM.

> Superseded 2026-09-21 (#187, agency runtime amendment 11): the single `mount: String?` is now
> `mounts: [String]`, rendered one `--mount` per entry instead of one `-v`, and `exec` takes a
> `timeoutSeconds: Int?` it enforces by killing the CLI child at the deadline. The signatures
> below are the shape this document shipped with, kept as the record of it.

```swift
protocol ContainerRuntime: Sendable {
    /// `container run -d --name <name> [-v <mount>] -w <workdir> <image> sleep infinity`
    func createDetached(name: String, image: String, mount: String?, workdir: String) async throws
    /// `container exec -w <workdir> <name> bash -c <command>` → (stdout+stderr, exitCode)
    func exec(name: String, workdir: String, command: String) async throws -> (output: String, exitCode: Int32)
    /// `container stop <name>` then `container delete <name>` (best-effort).
    func remove(name: String) async
    /// Names of existing containers whose name starts with `prefix` (`container ls -a --format json`).
    func list(prefix: String) async -> [String]
}
```

The production impl (`CLIContainerRuntime`) shells out to `/usr/local/bin/container`. All CLI
subcommands/flags used are confirmed present: `run -d --name -v -w`, `exec -w`, `stop`,
`delete`, `list -a --format json`.

### `SandboxSessionManager` (actor)

Owns session state and all lifecycle logic. An `actor` so concurrent tool calls (parallel
`withTaskGroup` execs) serialize safely and lazy creation happens exactly once.

```swift
actor SandboxSessionManager {
    static let shared = SandboxSessionManager(runtime: CLIContainerRuntime())

    struct Session { let name: String; var mountedWorkspace: String?; var lastUsed: Date }
    private var sessions: [UUID: Session] = [:]
    /// Conversations whose live container was lost (idle-reaped or died mid-session). The next
    /// `run` for such a conversation recreates the container AND prefixes a reset notice, then
    /// clears the flag. Distinguishes an unexpected reset from a first-ever cold creation.
    private var lostSessions: Set<UUID> = []

    /// Ensures a session exists for `conversationId` mounted at `workspace`, then execs the
    /// command. Recreates the container if the workspace changed. Returns combined output.
    func run(command: String, conversationId: UUID, workspace: String?) async -> String

    /// Tear down one conversation's container (called on conversation delete).
    func endSession(_ conversationId: UUID) async

    /// On launch: remove any orphaned `iris-` containers from a prior run.
    func reapOrphans() async

    /// Stop+remove sessions idle longer than the configured timeout (recreated on demand).
    func reapIdle(olderThan: TimeInterval) async
}
```

Container naming: `iris-<conversationId.uuidString.lowercased()>` (valid CLI container id;
the `iris-` prefix is the reaping key).

### Wiring into the tool path

- `ToolExecutor.execute` and `runCommand` gain a `conversationId: UUID?` parameter.
- `IrisEngine.executeToolWithHooks` (which already has `conversationId`) passes it down.
- `ToolExecutor.runCommand`, when `enableSandboxing`:
  - if `conversationId` present → `await SandboxSessionManager.shared.run(command:conversationId:workspace:)`
  - if absent (defensive) → fall back to today's `container run --rm` path.
- When `enableSandboxing` is off, the host `/bin/zsh -c` path is unchanged.

## Lifecycle

- **Lazy create.** On the first sandboxed command for a conversation, `run(...)` finds no
  session and calls `runtime.createDetached(name: "iris-<uuid>", image: sandboxImage,
  mount: workspace.map { "\($0):\($0)" }, workdir: workspace ?? "/")` with
  `sleep infinity` as the keep-alive process. Because `run` is on the actor, two concurrent
  first-commands can't double-create.
- **Exec.** `runtime.exec(name:, workdir: workspace ?? "/", command:)`. Update `lastUsed`.
  Exit code and combined stdout/stderr are returned; formatting matches today's output
  (stderr appended under a `Stderr:` label; empty → `"Success"`).
- **Workspace change.** If `session.mountedWorkspace != workspace`, `remove` the old container
  and create a fresh one mounted at the new workspace, then exec. (This is why per-conversation
  scope is safe despite the fixed-at-creation mount.)
- **Teardown triggers:**
  - Conversation deleted: `AppState.deleteConversation` (already calls `cancelTasks`) also calls
    `endSession(id)`.
  - Startup reap: at launch (after migration/seeding), `reapOrphans()` lists `iris-`-prefixed
    containers and removes them — the authoritative cross-run cleanup. `applicationWillTerminate`
    does `_exit(0)` (a hard synchronous exit), so async teardown cannot run there; `reapOrphans()`
    on the next launch handles containers left behind by a quit or crash. (Sessions do not survive
    a restart; a conversation reopened after relaunch creates a fresh container.)

### Idle reaper

A lightweight repeating task (started at app launch) calls `reapIdle(olderThan:
idleTimeoutMinutes * 60)` on an interval (e.g. every 5 min). A session with no command in that
window is stopped+removed; the next command for that conversation recreates it. This bounds
resource use for the expected case of many long-lived conversations.

- Config: new `ConfigManager.sandboxIdleTimeoutMinutes` (default **30**).
- Caveat, documented in-UI and in the skill: reaping loses in-container disk state (installed
  packages, temp files). Acceptable for idle sessions; the workspace on the host is untouched.

## Error handling / self-heal

- **Runtime not installed/ready:** reuse the existing `ToolExecutor.sandboxSetupHint(for:)`
  mapping so the model/user get an actionable message rather than an opaque CLI error.
- **Container missing/stopped at exec time** (e.g. reaped, or died): `exec` throws; `run` marks
  the conversation in `lostSessions`, removes the stale session entry, recreates the container
  once, and retries the exec. A second failure returns the error.
- **Creation failure:** surfaced as an actionable error string (not a crash).

### Session-reset notice (so a reap is never silent)

A reclaimed session must not surprise the agent with commands that "suddenly" fail. We do **not**
inject a message into an idle conversation (that would spuriously start a turn). Instead the loss
is surfaced **in-band on the next command**:

- When the idle reaper (or a mid-session self-heal) removes a conversation's container, the
  conversation id is added to `lostSessions`.
- The next `run` for that conversation creates a fresh container and, seeing the `lostSessions`
  flag, **prefixes the command output** with a one-line notice, then clears the flag:

  ```
  [sandbox] This session's container was reclaimed after being idle; previously installed
  packages and temp files were cleared (your workspace files on disk are untouched). Re-run any
  setup (installs/builds) before relying on them.
  ```

- A **first-ever** cold creation for a conversation sets no flag and emits no notice — nothing
  was lost. Only an *unexpected* reset is announced.
- The `sandbox-usage` skill documents this notice so the agent recognizes it and re-establishes
  setup rather than treating it as noise.

## Semantics (v1 non-goals, stated plainly)

- **Persists:** filesystem/disk state within a session — installed packages, files, build
  outputs — until the container is torn down (conversation end, app quit, workspace change, or
  idle reap).
- **Does NOT persist across separate commands:** shell working directory and environment
  variables. Each `container exec` is a fresh process. `--workdir` is set to the workspace per
  exec; within one command the agent chains (`cd sub && make`). Full shell-state persistence is
  the deferred pipe approach.

## The `sandbox-usage` skill

Ship a first-party skill so the agent uses the sandbox efficiently instead of fighting the
exec-per-command model.

- **Delivery:** a bundled asset `Sources/iris/assets/sandbox-usage-SKILL.md`, seeded by
  `ShippedSkills.seedIfNeeded` into `paths.skillsDir/sandbox-usage/SKILL.md` (same idempotent,
  non-destructive pattern as the library skills). Picked up by `SkillManager.discoverSkills()`.
- **Format:** OKF frontmatter (`type`, `title: sandbox-usage`, `description`, `tags`,
  `timestamp`) + markdown body.
- **Content (the durable guidance):**
  - Sandboxed commands run in a per-conversation Linux container; the workspace is mounted at
    the same absolute path as on the host.
  - Disk state persists within the session: install a package or build once, reuse it in later
    commands. Don't reinstall every command.
  - Shell `cd`/`export` do **not** carry across separate `run_command` calls — chain within one
    command (`cd sub && cmd`) or use absolute paths; set env inline (`FOO=bar cmd`).
  - Prefer few combined commands over many tiny ones (each exec has small overhead, but chaining
    is still cheaper and clearer).
  - An idle session may be reclaimed after inactivity, resetting in-container disk state (but
    never the host workspace). You will see a `[sandbox] ... reclaimed after being idle ...`
    notice prefixed to the next command's output when this happens — treat it as a signal to
    re-run installs/builds before relying on them.

## Configuration

- Reused: `enableSandboxing`, `sandboxImage`.
- New: `sandboxIdleTimeoutMinutes` (default 30), persisted in `UserDefaults` alongside the
  other sandbox settings, surfaced in Settings.

## Testing

- **Unit (mock `ContainerRuntime`):**
  - First command lazily creates exactly one container even under two concurrent `run` calls.
  - `exec` targets the conversation's container with `workdir` = workspace.
  - Changing `workspace` between calls removes the old container and creates a new one.
  - `endSession` removes the container and drops the session; `run` afterward recreates.
  - `reapOrphans` removes every `iris-`-prefixed name the runtime reports.
  - `reapIdle` removes only sessions past the threshold; a subsequent `run` recreates.
  - Exec throwing once triggers a single recreate+retry; throwing twice returns the error.
  - After `reapIdle`/self-heal removes a session, the next `run` output is prefixed with the
    `[sandbox] ... reclaimed ...` notice; a first-ever `run` for a new conversation is not.
- **Manual/integration:** with the real runtime, measure per-command overhead before/after
  (target: warm `exec` well under the ~0.85s cold-boot cost) and confirm disk state persists
  across commands in one conversation.

## Rollout

Additive. Sandboxing stays off by default; when on, the only behavioral change is that
commands are faster and share disk state within a conversation. `read_file`/`write_file`,
guardrails, and the host (`enableSandboxing` off) path are unchanged. Old conversations get a
fresh container on first use after upgrade.
