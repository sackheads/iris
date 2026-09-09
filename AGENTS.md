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

1. **Every new field on a persisted `Codable` type must use `decodeIfPresent` (or be excluded via `CodingKeys`).** Adding a stored property with a default value is not enough — Swift's synthesized `Decodable` throws when a key is missing, which causes the entire `conversations` array to fail to load and silently drops ALL conversations. Use `decodeIfPresent(...) ?? default` in a custom `init(from:)`, or add a `CodingKeys` case that excludes the new field entirely.

2. **`AppState` is `@Observable`, not `ObservableObject`.** Do not add `@Published`. SwiftUI views that hold `AppState` as a plain `let` or `@State` get automatic re-render tracking from the `@Observable` macro. Adding `@Published` or wrapping in `@ObservedObject` will break this.

3. **Tool calls run in parallel inside a `withTaskGroup`.** In `iris.swift`, all tool calls in a single model turn are dispatched concurrently. State recorded per-tool-call (e.g. `commandStartTimes`, `commandDurations`) must be keyed by a per-call UUID, not by conversation or turn. Never assume serial ordering within a single turn's tool batch.

4. **`run_command` has a 10-minute default timeout.** The model can override it up to 3600 s via `timeout_seconds`. The `terminationHandler` kills direct child processes (`pkill -9 -P <pid>`) before reading pipes to prevent orphaned subprocesses from blocking `readDataToEndOfFile()` indefinitely. Do not remove either of these behaviours.

5. **`commandStartTimes` and `commandDurations` on `AppState` are transient.** They are not part of `Conversation`, not persisted, and must not be added to any `Codable` type. They exist only to drive the pill timer UI within a single app session.

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

## Pre-commit checklist

- [ ] `swift test` is green
- [ ] If you added a field to a persisted `Codable` type: it uses `decodeIfPresent`
- [ ] If you added or changed a tool parameter: `getTools()` schema and `execute()` handler are both updated
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
- **Adding a tool?** `ToolExecutor.getTools()` (schema) + `ToolExecutor.execute()` (handler) + a test in `Tests/irisTests/`.
- **Changing the UI?** `ChatView.swift` for the message list; `SystemGroupView` / `SystemMessageContent` / `toolCallRow` for system-message pills.
- **Stuck?** `git log --oneline -- <path>` shows recent intent; commit messages are descriptive.
