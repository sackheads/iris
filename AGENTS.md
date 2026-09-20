# AGENTS.md

Guidance for AI coding agents working in this repo. Humans should read [README.md](README.md) first.

## What this project is

Iris is a native macOS SwiftUI AI assistant app — a compiled, local-first agent harness that bridges the user's machine and cloud LLMs. It manages multi-turn conversations, autonomous goal loops, tool execution (shell commands, file I/O, web search, MCP, Google Workspace), subagent sandboxing, and memory consolidation.

The primary provider abstraction supports Anthropic, Gemini, and OpenAI. Local inference (llama.cpp, MLX, Ollama) runs auxiliary models (Vibecop Guardian, Prompt Guard). `AppState` is the single source of truth; `IrisEngine` drives one turn of the agent loop per `processInput` call.

## Build and test

```sh
swift build                          # compile
swift test                           # full suite
swift test --filter MyTestSuite      # focused run
```

**Never mutate `ConfigManager.shared` in a test.** It is process-global and suites run in
parallel, so mutating it races — and its setters persist, so a bad value used to outlive the process
and poison the *next* run (#109). Two seams exist so you don't have to: construct your own
`ConfigManager()` and inject it (`ModelLEDBar(config:)`), or pass `protectionEnabled:` to
`InjectionGuard.sanitize` / `SkillManager.loadCustomRules`. Under test `ConfigManager` reads and
writes a volatile per-process store, so nothing you set can escape the run.

No Makefile. No lint config beyond the Swift compiler's own checks. Keep it that way unless asked.

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
  MemoryManager.swift     # SOUL.md, USER.md, memory.md read/write
  MCPManager.swift        # MCP client: tool discovery and call forwarding
  HookManager.swift       # before/after agent hooks (shell scripts)
  Timeout.swift           # withTimeout(seconds:) — used by run_command

Tests/irisTests/          # Swift Testing suite; one file per subsystem
docs/                     # design specs, plans, reviews, roadmaps
```

## Critical invariants — do not break

1. **Every new field on a persisted `Codable` type must use `decodeIfPresent` (or be excluded via `CodingKeys`).** Adding a stored property with a default value is not enough — Swift's synthesized `Decodable` throws when a key is missing, which makes that row unreadable: since #163 a message or history entry that fails to decode is quarantined and reported at launch rather than dropping every conversation, but a quarantined row is still lost to the user until someone recovers it by hand. Use `decodeIfPresent(...) ?? default` in a custom `init(from:)`, or add a `CodingKeys` case that excludes the new field entirely.

2. **`AppState` is `@Observable`, not `ObservableObject`.** Do not add `@Published`. SwiftUI views that hold `AppState` as a plain `let` or `@State` get automatic re-render tracking from the `@Observable` macro. Adding `@Published` or wrapping in `@ObservedObject` will break this.

3. **Tool calls run in parallel inside a `withTaskGroup`.** In `iris.swift`, all tool calls in a single model turn are dispatched concurrently. State recorded per-tool-call (e.g. `commandStartTimes`, `commandDurations`) must be keyed by a per-call UUID, not by conversation or turn. Never assume serial ordering within a single turn's tool batch.

4. **`run_command` has a 10-minute default timeout.** The model can override it up to 3600 s via `timeout_seconds`. The `terminationHandler` kills direct child processes (`pkill -9 -P <pid>`) before reading pipes to prevent orphaned subprocesses from blocking `readDataToEndOfFile()` indefinitely. Do not remove either of these behaviours.

5. **`commandStartTimes` and `commandDurations` on `AppState` are transient.** They are not part of `Conversation`, not persisted, and must not be added to any `Codable` type. They exist only to drive the pill timer UI within a single app session.

6. **Gate tool exposure; never broadcast dead-weight declarations on plain turns.** Every declared tool consumes prompt tokens on every call (the perf ladder in #129 showed 30 tools consuming ~3,100 of ~5,100 prompt tokens — 61% of the payload) and invites unprompted tool eagerness (e.g. #132's `rename_conversation` unprompted calls on first messages). When adding or modifying a tool:
   - *Unconfigured prerequisites:* If a tool requires external authentication or credentials (e.g. Google refresh tokens in `ToolExecutor.getTools`), omit the declaration when unconfigured so an unconnected install does not spend prompt tokens (#133, #144). Make the prerequisite flag injectable (`workspaceToolsEnabled: Bool = ...`) so tests never touch global config.
   - *Workflow triggers:* If a tool belongs to a specific command flow (e.g. `propose_goal_contract` for `/goal`, `rename_conversation` for `/rename`), offer it **only** on the triggering turn using a dedicated system-event prefix (`IrisEngine.goalDraftTriggerPrefix`, `IrisEngine.renameTriggerPrefix`).
   - *Lifecycle state:* If a tool is valid only during an active state (e.g. `amend_goal_contract` gated on `ladderContract?.isLocked == true`, `reach_checkpoint` gated on `hasLadder && !isFinalMilestone`), gate declaration on that state.
   - *Reference:* See #144 for the canonical pattern (dropping 12 dead-weight tools slashed declaration tokens by 41% and whole-prompt size by 25%).

7. **Never mutate `ConfigManager.shared` in a test.** It is process-global and suites run concurrently, so mutating it races. Use the existing seams instead: construct an isolated `ConfigManager()` and inject it, or pass injectable parameters (`protectionEnabled:`, `workspaceToolsEnabled:`). See **Build and test** above.

8. **Every chip in the composer's `VStack` must be height-bounded.** `ChatView` stacks the goal chips — `GoalContractPanel`, `LockedContractChip`, `CheckpointPauseChip`, `CompletionReportChip` — directly above the composer. An unbounded subview there can collapse the surrounding layout and blank the entire window the instant the chip appears; the app stays responsive, which makes it read as a state bug rather than a layout one. Wrap the chip in a `ScrollView` and cap it with `.frame(maxHeight:)` (320-340 is the established range). This matters most for chips whose height grows with the contract — anything embedding a `ForEach` over criteria or verdicts. Nothing enforces this at compile time, and it has escaped twice: `aa141d5` capped the three chips that existed then (#62), and `CheckpointPauseChip` was added later without a cap, reintroducing the same bug (#164).

## Patterns and conventions

- **Tests** use Swift Testing (`@Suite`, `@Test`, `#expect`). Do not use XCTest. See `Tests/irisTests/ToolCallParserTests.swift` for style.
- **`AppState` in views.** The main `ChatView` holds `@State var state = AppState.shared`. Pass it to child views as a plain `let appState: AppState` — `@Observable` tracking does the rest. Do not inject via `@EnvironmentObject`.
- **Emitting messages from the engine.** Use `pushToUI(role:text:conversationId:)` on `IrisEngine`, which calls `appendMessage` on `AppState`. If you need a stable UUID for the message (e.g. to key timing state), pass `id:` to `pushToUI` before calling.
- **Tool schema changes.** When adding or modifying a tool parameter, update the `FunctionDeclaration` in `ToolExecutor.getTools()` AND handle the new argument in `ToolExecutor.execute()`. Both must stay in sync or the model will see a schema that doesn't match what the executor reads.
- **`IrisEngine` actor helpers.** The `group.addTask` closures in the tool dispatch loop are `@Sendable` and not actor-isolated. Access actor-isolated state (like `self.state`) through small `async` helper methods on `IrisEngine` that do the `MainActor.run` hop — not inline inside `addTask`.

## Things that have bitten us

- **Codable field without `decodeIfPresent`** drops all conversations silently on next launch. This has happened. Every new persisted field needs `decodeIfPresent` or a `CodingKeys` exclusion — no exceptions.
- **`readDataToEndOfFile()` blocking on orphan processes.** When a shell command spawns a subprocess (e.g. `docker` → `docker-buildx`), the child inherits the stdout/stderr pipes. Killing the parent doesn't close the pipes. The `terminationHandler` must kill children first; see `ToolExecutor.runCommand`.
- **`withCheckedContinuation` ignores task cancellation.** The Stop button cancels the Swift Task, but a bare `withCheckedContinuation` never wakes up. Wrap it with `withTaskCancellationHandler` so cancellation can terminate the subprocess and resume the continuation.
- **AttributeGraph cycle from `.textSelection` on agent Markdown views.** A `.textSelection` modifier on the agent message `Markdown` view caused a heisenbug cycle (invisible under the debugger). Fixed in `0ed19c8`; don't re-add `.textSelection` to those views.
- **Unconditional tool declarations bloating prompt tokens and causing tool eagerness.** Broadcasting 30 tool declarations cost 61% of turn tokens and caused the model to rename conversations unprompted on first messages (#132, #133, #144). Gating tools by credentials and workflow triggers cut declarations from 30 to 17 (-41% tokens) with no loss of capability for the flows that use them.
- **Mutating global `ConfigManager.shared` in tests.** Leaked settings across parallel test suites, caused flaky runs, and persisted dirty state into user defaults (#109).
- **An unbounded chip in the composer stack blanking the window.** A goal chip with no height cap collapsed the surrounding layout the moment it rendered, emptying the sidebar and main pane while the app kept responding (#62, `aa141d5`). Fixed for the chips that existed then; a later chip arrived without the cap and did it again (#164). Bound every chip you add there (Invariant 8).

## Pre-commit checklist

- [ ] `swift test` is green
- [ ] If you added a field to a persisted `Codable` type: it uses `decodeIfPresent` (Invariant 1)
- [ ] If you added or modified a tool with a credential prerequisite, a triggering command, or a lifecycle state: its declaration is gated on it rather than exposed unconditionally on plain turns (Invariant 6; see #144)
- [ ] If you added or changed a tool parameter: `getTools()` schema and `execute()` handler are both updated
- [ ] If you added a test that configures settings: it does not mutate `ConfigManager.shared` directly; uses an injected instance or parameter (Invariant 7; see Build and test)
- [ ] If you added a view to the composer's `VStack` in `ChatView`: it is wrapped in a `ScrollView` and capped with `.frame(maxHeight:)` (Invariant 8)
- [ ] If you changed user-facing behaviour: `README.md` is updated in the same commit
- [ ] No large build artefacts committed (`.build/`, `*.o`, `*.onnx` model weights, etc.)

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
