# AGENTS.md

Guidance for AI coding agents working in this repo. Humans should read [README.md](README.md) first.

## What this project is

Iris is a native macOS SwiftUI AI assistant app — a compiled, local-first agent harness that bridges the user's machine and cloud LLMs. It manages multi-turn conversations, autonomous goal loops, tool execution (shell commands, file I/O, web search, MCP, Google Workspace), subagent sandboxing, and memory consolidation.

The primary provider abstraction supports Anthropic, Gemini, and OpenAI. Local inference (llama.cpp, MLX, Ollama) runs auxiliary models (Vibecop Guardian, Prompt Guard). `AppState` is the single source of truth; `IrisEngine` drives one turn of the agent loop per `processInput` call.

## Build and test

```sh
swift build                          # compile
swift test                           # full suite
scripts/test-filter.sh MyTestSuite   # focused run, guarded (see below)
```

**Dev builds use `~/.iris-dev`, not `~/.iris`.** `swift build`/`swift run`, `scripts/run-dev.sh`,
Xcode Debug and `swift test` are all dev builds (`BuildIdentity.current == .dev`): they read and
write `~/.iris-dev`, keep their secrets under `.dev`-suffixed Keychain services, and answer to
`Cmd+Shift+Option+Space`. Only the installed release app (bundle id `com.bnaylor.iris`) uses
`~/.iris`, its own (unsuffixed) Keychain services, and `Cmd+Shift+Space` — the two never share a
home, a Keychain item, or a hotkey. `run-dev.sh` seeds `~/.iris-dev` from `~/.iris` the first time
it runs, via `iris --seed-dev-home`: it copies the release home — everything under it except
`models/`, which is symlinked back to the release copy rather than duplicated (gigabytes,
read-only) — and the release Keychain items into their `.dev`-suffixed equivalents, rewriting the
bundled `~/.iris` spelling in the copied text to `~/.iris-dev` as it goes. It refuses outright if
the installed app currently holds the release store's GUI lock (quit it and retry) or if the dev
home already has content (remove it first to reseed). Exit codes: `0` seeded; `3` nothing to seed
— no release home yet, the normal case on a machine that has never installed the app, not a
failure; `1` anything else. `run-dev.sh` continues past `3` and stops on `1` (or any other
non-zero, non-3 exit), because launching anyway would create an empty `~/.iris-dev`, and the
seeder refuses to seed over an existing non-empty destination — so a later retry could never seed
at all.

**`--filter` takes the TYPE name, and matching nothing looks exactly like passing.** It does not
match the `@Suite`/`@Test` display string — and the display string is what the test output
*prints*, so the obvious copy-paste selects nothing and still exits 0:

```
$ swift test --filter "Vibecop under headless auto-approve"
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.   # ← ran nothing, exit 0
$ swift test --filter VibecopUnderAutoApproveTests
✔ Test run with 5 tests in 1 suite passed after 0.220 seconds.
```

This matters because the standard way to tell a real failure from a parallel-suite race is to run
the suite alone (Invariant 7). Filter by the printed name and the green proves nothing, while the
conclusion drawn from it — "not a race" — is the opposite of the truth. `scripts/test-filter.sh`
wraps `swift test --filter` and fails when the filter matched no tests; use it, and when citing a
filtered run as evidence, quote the test count (#271).

**Opt-in tests.** Two kinds of test are skipped unless an environment variable asks for them,
because they need something the default suite must not depend on:

- `IRIS_REAL_VM=1` runs `SandboxRealVMTests` against the installed `container` runtime (zombies in
  the session container, the in-VM kill with the pool held). It still skips without a started
  runtime and a local `ubuntu:latest`; it never pulls one. Containers are named `iristest-*` and
  deleted by the test. The stub-binary sandbox tests run by default.
- `IRIS_ONNX_TEST_BUNDLE=<dir>` runs the on-device ONNX prompt-guard tests against that bundle.

```sh
IRIS_REAL_VM=1 scripts/test-filter.sh SandboxRealVMTests
```

**Never mutate `ConfigManager.shared` in a test.** It is process-global and suites run in
parallel, so mutating it races — and its setters persist, so a bad value used to outlive the process
and poison the *next* run (#109). Two seams exist so you don't have to: construct your own
`ConfigManager(store:)` over a suite of your own and inject it (`ModelLEDBar(config:)`), or pass
`protectionEnabled:` to `InjectionGuard.sanitize` / `SkillManager.loadCustomRules`. It is the
injected store that isolates you: a bare `ConfigManager()` is a separate *object* over the same
process-global store, so its `didSet`s are still visible to every test reading that key (#193).

```swift
let name = "iris-mytest-\(UUID().uuidString)"
let store = UserDefaults(suiteName: name)!
defer {   // removePersistentDomain does not delete the plist on current macOS (#178)
    store.removePersistentDomain(forName: name)
    IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
}
let config = ConfigManager(store: store)
```

Under test the process-global store is itself a volatile per-process suite, so nothing you set can
escape the run either way.

No Makefile. No lint config beyond the Swift compiler's own checks. Keep it that way unless asked.

### GUI testing: take the lease first

Sessions from more than one project run GUI tests on the same machine, often on the unattended
work laptop at the request of a remote session. Two runs at once steal focus from each other and
both results are worthless. Before anything that launches the app or drives the screen
(`scripts/run-dev.sh`, manual UI passes, computer use, screenshots of real windows), take the
host-wide lease with the `gui-test-lease` skill:

```sh
L="python3 ~/.claude/skills/gui-test-lease/lease.py"
$L acquire --purpose "iris: <what>" --minutes N [--on-behalf-of <peer>]  # exit 1 = held; output says by whom
$L release                                                             # as soon as GUI work ends, pass or fail
```

Exit 1 means another session has the screen: message the holder named in the output, or wait with
`--wait SECS`. Never start GUI work without the lease, and never edit or delete the lease file by
hand. If the skill isn't installed, ask the user rather than skipping this.

### Worktrees: remove them when their PR merges

Every worktree builds its own `.build`, and one Swift build of iris is about 9 GB. Five finished
worktrees left behind filled the disk to under 9 GB free and failed a build with ENOSPC mid-task.
A worktree is scratch for one PR: once that PR is merged (or closed), remove it and its local branch
in the same step that reports the merge.

```sh
git -C <worktree> status --porcelain          # must be empty; if not, the files exist nowhere else
git worktree remove <worktree>                # --force only for a harness-locked tree that is clean
git branch -D <branch>                        # -D: squash merges leave the branch unmerged to git
git worktree prune
```

Check the PR is actually merged (`gh pr list --head <branch> --state all`) before deleting: a
squash merge means `git branch --merged` will not list it. Never remove a worktree with
uncommitted files without asking.

About 4 GB of each `.build` is `index-build`: SourceKit-LSP's background index, built whenever an
editor or LSP client opens the tree. `swift build` and `swift test` never need it. A worktree is
not browsed, so switch it off when you create one:

```sh
mkdir -p <worktree>/.sourcekit-lsp && echo '{"backgroundIndexing": false}' > <worktree>/.sourcekit-lsp/config.json
```

It must sit at the worktree's root: SourceKit-LSP does not read it from a parent directory (tested
2026-10-02). Add `.sourcekit-lsp/` to `.git/info/exclude` once per clone (every worktree shares that
file) so it does not make the tree look dirty. An existing `index-build` can be deleted at any time.

## Project layout

```
Sources/iris/
  AppState.swift          # @Observable god-object: conversations, messages, thinking state, timing
  iris.swift              # IrisEngine: the agent turn loop, tool dispatch, goal/reprompt logic
  ToolExecutor.swift      # run_command, read_file, write_file, search_web, skill CRUD
  ChatView.swift          # main chat UI, pill rendering, SystemGroupView, SystemMessageContent
  ConfigManager.swift     # LLMProvider enum, per-tier model names, UserDefaults persistence
  Models.swift            # JSONValue, ChatMessage, Conversation, FunctionCall, GeminiRequest, …
  ToolCallParser.swift    # parses [TOOL_CALL] system messages into ToolCallDisplay
  LLMClient.swift         # Gemini streaming client
  AnthropicClient.swift   # Anthropic streaming client
  OpenAIClient.swift      # OpenAI streaming client
  SubagentManager.swift   # spawns isolated IrisEngine instances for parallel subagent tasks
  GoalEvaluator.swift     # grades completed work against a GoalContract using a fresh engine
  SandboxSessionManager.swift  # routes run_command through apple/container VMs when enabled
  GuardTierHealth.swift        # last load/inference failure per guard tier, for the P2/P3 error LED (#218)
  MemoryManager.swift     # SOUL.md, USER.md, memory.md read/write
  MCPManager.swift        # MCP client: tool discovery and call forwarding
  HookManager.swift       # before/after agent hooks (shell scripts)
  Timeout.swift           # withTimeout(seconds:) — returns at the deadline; used by run_command and Vibecop

Tests/irisTests/          # Swift Testing suite; one file per subsystem
docs/                     # design specs, plans, reviews, roadmaps
```

## Critical invariants — do not break

1. **Every new field on a persisted `Codable` type must use `decodeIfPresent` (or be excluded via `CodingKeys`).** Adding a stored property with a default value is not enough — Swift's synthesized `Decodable` throws when a key is missing, which makes that row unreadable: since #163 a message or history entry that fails to decode is quarantined and reported at launch rather than dropping every conversation, but a quarantined row is still lost to the user until someone recovers it by hand. A forgotten `decodeIfPresent` makes *every* row of a table unreadable, and that case deliberately quarantines nothing: the rows are left exactly where they are, the conversation is dropped from that load and reported, and adding the `decodeIfPresent` brings it back intact. Do not rely on that as a safety net — it only holds until something writes over those rows. Use `decodeIfPresent(...) ?? default` in a custom `init(from:)`, or add a `CodingKeys` case that excludes the new field entirely.

2. **`AppState` is `@Observable`, not `ObservableObject`.** Do not add `@Published`. SwiftUI views that hold `AppState` as a plain `let` or `@State` get automatic re-render tracking from the `@Observable` macro. Adding `@Published` or wrapping in `@ObservedObject` will break this.

3. **Tool calls run in parallel inside a `withTaskGroup`.** In `iris.swift`, all tool calls in a single model turn are dispatched concurrently. State recorded per-tool-call (e.g. `commandStartTimes`, `commandDurations`) must be keyed by a per-call UUID, not by conversation or turn. Never assume serial ordering within a single turn's tool batch.

4. **`run_command` has a 10-minute default timeout, and stopping a command stops everything it started.** The model can override the timeout up to 3600 s via `timeout_seconds`. A host command is spawned by `ProcessGroupRunner` as the leader of its own process group (`posix_spawn` + `POSIX_SPAWN_SETPGROUP`); timeout and Stop signal the whole group — SIGTERM, then SIGKILL after a grace — because killing the shell's pid alone orphans whatever it forked (#353). The pipes are drained as the command runs, and after the leader exits a group member still holding them is SIGKILLed and the pipes are then abandoned, so no read can block on an orphan; a background job that redirected its output is left running. The leader is not reaped until the kill sequence is over, so the group id cannot be reused under it. In the container, `CLIContainerRuntime.exec` records the command's in-VM group and kills it with a second `container exec` on timeout or cancel, since killing the host-side client does not reach the VM; the session container runs with `--init`, so the processes that kill ends are reaped rather than left as zombies under a `sleep infinity` PID 1 (#365). Command hooks (`HookManager`) and a plugin's `check_command` (`PluginAuthRunner`) run through the same runner, with its `timeoutSeconds` (#364). The deadlines and kill ladders (`withTimeout`'s timer, `ProcessGroupRunner`'s grace and `timeoutSeconds`, `CLIProcessRunner`'s watchdog and ladder) run on dispatch queues, never as `Task.sleep` on the cooperative pool: a pool held by blocking work held the kill with it (#372). So does what a kill must do beyond the child's reach: the in-VM group killer is fired by `CLIProcessRunner`'s ladder (`onKill`, at its start and again at its end, for a group recorded late; the killer takes the group's note before signalling, so only one fire ever signals a group and a later one cannot hit a reused id), and a one-off `container run`'s `delete --force` by `ProcessGroupRunner`'s (`onKilled`), both spawned with `BlockingSpawn`, never from a `Task` after the call returns (#377). Only delivering the tool result still needs a pool thread; under a held pool the command dies on time and its result arrives when the pool frees, which is accepted: the turn that reads the result runs on that same pool, so nothing could act on it sooner. Do not remove any of these behaviours.

5. **`commandStartTimes` and `commandDurations` on `AppState` are transient.** They are not part of `Conversation`, not persisted, and must not be added to any `Codable` type. They exist only to drive the pill timer UI within a single app session.

6. **Gate tool exposure; never broadcast dead-weight declarations on plain turns.** Every declared tool consumes prompt tokens on every call (the perf ladder in #129 showed 30 tools consuming ~3,100 of ~5,100 prompt tokens — 61% of the payload) and invites unprompted tool eagerness (e.g. #132's `rename_conversation` unprompted calls on first messages). When adding or modifying a tool:
   - *Unconfigured prerequisites:* If a tool requires external authentication or credentials (e.g. Google refresh tokens in `ToolExecutor.getTools`), omit the declaration when unconfigured so an unconnected install does not spend prompt tokens (#133, #144). Make the prerequisite flag injectable (`workspaceToolsEnabled: Bool = ...`) so tests never touch global config.
   - *Workflow triggers:* If a tool belongs to a specific command flow (e.g. `propose_goal_contract` for `/goal`, `rename_conversation` for `/rename`), offer it **only** on the triggering turn using a dedicated system-event prefix (`IrisEngine.goalDraftTriggerPrefix`, `IrisEngine.renameTriggerPrefix`).
   - *Lifecycle state:* If a tool is valid only during an active state (e.g. `amend_goal_contract` gated on `ladderContract?.isLocked == true`, `reach_checkpoint` gated on `hasLadder && !isFinalMilestone`), gate declaration on that state. A state-gated tool, once declared in a conversation, stays declared for the rest of it (`StickyTools`, 5c), and its dispatcher refuses the call when the state is off. Workflow-trigger tools stay one-turn-only. Stickiness holds only for attended `.main` turns, keeps each tool at its gated position in the list, and never survives a hard strip (`IrisEngine.hardStrip`: unattended turns, non-main principals); a new state-gated tool joins `StickyTools.eligible` and gets an off-state dispatch refusal with a test.
   - *Reference:* See #144 for the canonical pattern (dropping 12 dead-weight tools slashed declaration tokens by 41% and whole-prompt size by 25%).

7. **Never mutate process-global state in a test.** Suites run concurrently, so a test that writes a global decides behaviour for whatever else is running at that moment. The failure is always the same shape and always misleading: a suite that passes under `--filter` and fails intermittently in the full run, with the failure pointing at innocent code. Diagnose it by running the suite alone — if it only fails in company, look for a global before you look at the code under test.
   - **`ConfigManager.shared`** — construct an isolated `ConfigManager(store:)` over your own `UserDefaults` suite and inject it, or pass injectable parameters (`protectionEnabled:`, `workspaceToolsEnabled:`). Its setters also *persist*, so a bad value used to outlive the process and poison the next run (#109). A bare `ConfigManager()` does not isolate you — it is a separate object over the same process-global store (#193).
   - **The guard tiers** — use the task-scoped seams, not the singletons: `CoreMLEvaluator.$scopedModel.withValue(.init(model))` and `AuxiliaryModelManager.$scopedEngines.withValue(["canary": engine])`. `.init(nil)` means *explicitly no model*, which is different from no scope. Before these existed, one suite's malicious-probability mock blocked another suite's content and the first diagnosis blamed `ConfigManager`, which no test touches (#237). The seams cover `InjectionGuard`'s process-wide verdict cache too: a call under either scope neither reads nor writes it, because a hijacking canary's block on shared text (the default empty USER.md) used to be served to every later engine in the process (#375). An *unscoped* call still shares that cache, so scope the tiers whenever a test asserts on what the guard decided. Nothing writes `CoreMLEvaluator.shared`'s model in a test any more; a test that needs an installed model uses `CoreMLEvaluator()` of its own.
   - **`~/.iris`** — under test `IrisPaths.default` is an empty per-process temp home, not the real one, so nothing that resolves through `IrisPaths` can write the developer's allowlist, memory or skills again (#290, #304). A tool argument spelled `~/.iris/...` expands to `IrisPaths.default`, the test home; any other `~/` path still expands to the real home. This holds for the file tools only (`read_file`/`write_file`, anything that goes through `IrisEngine.expandTilde`) — `run_command`'s shell expands `~` itself, before the argument ever reaches Iris, so a test's `run_command` call is not isolated by this and still reaches the real home. It is still one home for the whole process: a test that writes through `PermissionManager.shared` or another `.shared` manager is visible to every suite running beside it. Build your own `IrisPaths(root:)` over a temp directory and inject it (`PermissionManager(paths:)`, `AppState.permissions`). Isolation tests that check the real home use both `IrisPaths.standard` (this build's home) and `IrisPaths.release` (the installed app's).
   - **The working directory** — `FileManager.changeCurrentDirectoryPath` moves the whole process. Pass the base in instead (`BinaryResolver.resolve(relativeTo:)`), and resolve repo-relative paths from `#filePath`, not from the cwd (`PerfPaths.repoRoot`) (#242, #160).
   - **`PerformanceProfiler.shared` is not a case, and was checked (#250, #269).** Four suites read it and none is serialized. `active` is keyed by the id `beginTurn` returns, so `activeProfileForTesting(id)` only ever sees the caller's own turn. Only the unkeyed reads — `recentCommands`, `activeCountForTesting` — could race, and the suites asserting on those construct their own `PerformanceProfiler()`.

   See **Build and test** above.

8. **Every chip in the composer's `VStack` must be height-bounded.** `ChatView` stacks the goal chips — `GoalContractPanel`, `LockedContractChip`, `CheckpointPauseChip`, `CompletionReportChip` — directly above the composer. An unbounded subview there can collapse the surrounding layout and blank the entire window the instant the chip appears; the app stays responsive, which makes it read as a state bug rather than a layout one. Wrap the chip in a `ScrollView` and cap it with `.frame(maxHeight:)` (320-340 is the established range). This matters most for chips whose height grows with the contract — anything embedding a `ForEach` over criteria or verdicts. Nothing enforces this at compile time, and it has escaped twice: `aa141d5` capped the three chips that existed then (#62), and `CheckpointPauseChip` was added later without a cap, reintroducing the same bug (#164).

9. **A behaviour change must falsify its own documentation before it lands.** Describing the new thing is the easy half, and not the half that fails. The defects that actually ship are *existing* sentences the change made untrue — and they survive precisely because adding a new paragraph feels like compliance. Two places carry them, and the second matters more:
   - **`README.md`** — a stale claim misleads a human, who can at least notice it is wrong.
   - **Agent-facing strings** — `GoalContract.oracleText` (injected into *every* reprompt), the `description` fields in `ToolExecutor.getTools()` and the tool declarations in `iris.swift` / `SubagentManager.swift`, and the system prompts. A stale one steers the model wrong on every turn, silently, and no UI ever shows it.

   Slice D3 is the worked example: it made a cleanly-graded checkpoint advance without pausing, added a correct README bullet saying so — and left the neighbouring bullet still promising "pausing for your review", plus three agent-facing strings telling the model that a checkpoint always pauses. The README was fixed by a docs task; the model kept being lied to until a whole-branch review caught it.

   **Search, do not compose.** Grep for the behaviour you changed and read what comes back. "Nothing was falsified" is a legitimate and common answer; having looked is the requirement.

## Patterns and conventions

- **Tests** use Swift Testing (`@Suite`, `@Test`, `#expect`). Do not use XCTest. See `Tests/irisTests/ToolCallParserTests.swift` for style.
- **`AppState` in views.** The main `ChatView` holds `@State var state = AppState.shared`. Pass it to child views as a plain `let appState: AppState` — `@Observable` tracking does the rest. Do not inject via `@EnvironmentObject`.
- **Emitting messages from the engine.** Use `pushToUI(role:text:conversationId:)` on `IrisEngine`, which calls `appendMessage` on `AppState`. If you need a stable UUID for the message (e.g. to key timing state), pass `id:` to `pushToUI` before calling.
- **Tool schema changes.** When adding or modifying a tool parameter, update the `FunctionDeclaration` in `ToolExecutor.getTools()` AND handle the new argument in `ToolExecutor.execute()`. Both must stay in sync or the model will see a schema that doesn't match what the executor reads.
- **`IrisEngine` actor helpers.** The `group.addTask` closures in the tool dispatch loop are `@Sendable` and not actor-isolated. Access actor-isolated state (like `self.state`) through small `async` helper methods on `IrisEngine` that do the `MainActor.run` hop — not inline inside `addTask`.

## Things that have bitten us

- **Codable field without `decodeIfPresent`** drops all conversations silently on next launch. This has happened. Every new persisted field needs `decodeIfPresent` or a `CodingKeys` exclusion — no exceptions.
- **`readDataToEndOfFile()` blocking on orphan processes.** When a shell command spawns a subprocess (e.g. `docker` → `docker-buildx`), the child inherits the stdout/stderr pipes. Killing the parent doesn't close the pipes. The old fix, `pkill -9 -P <pid>` in the `terminationHandler`, ran after the parent had exited, when its children had already been reparented to launchd and matched nothing. `ProcessGroupRunner` kills the process group instead and never reads to end-of-file unbounded (#353); see Invariant 4. Hooks and the plugin `check_command` had the same `readDataToEndOfFile` pattern until #364 moved them onto it; the check's `readabilityHandler` also lost output written just before exit (#368). A new host spawner should use `ProcessGroupRunner` (`capture` gives a deadline plus cancellation) rather than `Process`; `CLIProcessRunner` still uses `Process` but drains incrementally and has its own ladder.
- **Killing the `container` CLI does not kill the command in the VM.** SIGTERM to `container exec` or `container run` fails to forward ("missing signal in xpc message"), and SIGKILL leaves the command and its children running in the container (CLI 1.1.0, measured for #353). A timeout or cancel has to act inside the VM: `CLIContainerRuntime.exec` kills the recorded group, and the ephemeral `container run` path deletes its named container. A `sleep infinity` PID 1 never reaps what that kill leaves, so each timeout left two zombies for the life of the session (#365); `--init` makes the CLI's init PID 1, which reaps them and also forwards `container stop`'s SIGTERM (stop went from about 9 s to 0.15 s, measured on CLI 1.1.0).
- **`withCheckedContinuation` ignores task cancellation.** The Stop button cancels the Swift Task, but a bare `withCheckedContinuation` never wakes up. Wrap it with `withTaskCancellationHandler` so cancellation can terminate the subprocess and resume the continuation.
- **AttributeGraph cycle from `.textSelection` on agent Markdown views.** A `.textSelection` modifier on the agent message `Markdown` view caused a heisenbug cycle (invisible under the debugger). Fixed in `0ed19c8`; don't re-add `.textSelection` to those views.
- **Unconditional tool declarations bloating prompt tokens and causing tool eagerness.** Broadcasting 30 tool declarations cost 61% of turn tokens and caused the model to rename conversations unprompted on first messages (#132, #133, #144). Gating tools by credentials and workflow triggers cut declarations from 30 to 17 (-41% tokens) with no loss of capability for the flows that use them.
- **Mutating global `ConfigManager.shared` in tests.** Leaked settings across parallel test suites, caused flaky runs, and persisted dirty state into user defaults (#109). The documented escape hatch then quietly had the same hole: `ConfigManager.store` was static, so a test's own `ConfigManager()` wrote to the process-global store anyway and `EmojiSettingsTests` passed on ordering luck (#193). The store is per-instance now — inject one.
- **Docs that describe the new behaviour while still asserting the old one.** The additive half of a docs update gets done and the falsifying half does not, so a README ends up containing both the new truth and the old lie in adjacent bullets (#195). Worse, the same staleness hides in agent-facing prompt strings, where nothing surfaces it and the model is misled on every turn. "Update the README" was a checklist line here for a long time and measurably did not work — 23 of 179 `feat` commits on main touched README. See invariant 9.
- **An unbounded chip in the composer stack blanking the window.** A goal chip with no height cap collapsed the surrounding layout the moment it rendered, emptying the sidebar and main pane while the app kept responding (#62, `aa141d5`). Fixed for the chips that existed then; a later chip arrived without the cap and did it again (#164). Bound every chip you add there (Invariant 8).
- **A transient field holding a durable decision.** D2 recorded human verdicts only in `lastGoalEvaluation`, which the next `beginGoalEvaluation` overwrites and `sanitizeLoaded` clears on load. That was invisible while grading happened once, at the terminal gate; D3's per-checkpoint grading would have destroyed a judgement and asked the user again. Durable decisions live on `GoalContract` (`waivers`, `judgements`), never on the transient surfacing fields.

## Pre-commit checklist

- [ ] `swift test` is green
- [ ] If you cite a **filtered** run as evidence: it ran a non-zero number of tests, and you say how many. `--filter` matching nothing exits 0 (Invariant 7; see Build and test, #271)
- [ ] If you added a field to a persisted `Codable` type: it uses `decodeIfPresent` (Invariant 1)
- [ ] If you added or modified a tool with a credential prerequisite, a triggering command, or a lifecycle state: its declaration is gated on it rather than exposed unconditionally on plain turns (Invariant 6; see #144)
- [ ] If you added or changed a tool parameter: `getTools()` schema and `execute()` handler are both updated
- [ ] If you added a test that configures settings: it does not mutate `ConfigManager.shared` directly; uses a `ConfigManager(store:)` over its own suite, or an injectable parameter (Invariant 7; see Build and test)
- [ ] If you added a view to the composer's `VStack` in `ChatView`: it is wrapped in a `ScrollView` and capped with `.frame(maxHeight:)` (Invariant 8)
- [ ] If you changed user-facing or agent-visible behaviour: you searched for what it made **untrue** — in `README.md` and in agent-facing strings (`oracleText`, tool `description` fields, system prompts) — and fixed what you found. Finding nothing is fine; not looking is not (Invariant 9)
- [ ] No large build artefacts committed (`.build/`, `*.o`, `*.onnx` model weights, etc.)
- [ ] After the PR merges: its worktree and local branch are removed (see Worktrees, above)

## House style

- Short comments only — for non-obvious *why*, not *what*.
- No `TODO:` / `FIXME:` left behind unless tied to a tracked issue.
- No emoji in code or commit messages.
- Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`). Co-credit the model in the trailer.

## Docs layout

- **Design specs:** `docs/specs/YYYY-MM-DD-feature-name.md`
- **Implementation plans:** `docs/plans/YYYY-MM-DD-feature-name.md` (superpowers plans go in `docs/superpowers/plans/`)
- **Reviews:** `docs/reviews/YYYY-MM-DD-feature-name-review.md`

## Where to look first

- **New here?** Read `AppState.swift` for the data model, then trace a turn: `IrisEngine.processInput` → `processInputBody` → model call → `withTaskGroup` tool dispatch → `executeFunctionCall` → `pushToUI`.
- **Adding a tool?** `ToolExecutor.getTools()` (schema with gating / `workspaceToolsEnabled`) + `ToolExecutor.execute()` (handler) + trigger gate in `IrisEngine.processInputBody` if command-specific + tests in `Tests/irisTests/ToolSurfaceTrimTests.swift`.
- **Changing the UI?** `ChatView.swift` for the message list; `SystemGroupView` / `SystemMessageContent` / `toolCallRow` for system-message pills.
- **Stuck?** `git log --oneline -- <path>` shows recent intent; commit messages are descriptive.
