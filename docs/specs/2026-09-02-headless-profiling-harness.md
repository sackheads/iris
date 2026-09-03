# Headless Profiling Harness

**Status:** Implemented (feat/headless-profiling-harness)
**Date:** 2026-09-02
**Goal:** Run the iris core end-to-end without the UI, so turn/goal-loop
performance can be profiled and regression-tested without a human clicking
through the app.

## Motivation

The core is already largely decoupled from the UI:

- `IrisEngine(state:client:)` injects the LLM via `LLMClientProtocol`.
- `AppState()` constructs standalone (no window, no `@main`).
- Tests already drive full turns via `engine.processInput(...)` with a scripted
  client and inspect resulting state.
- `PerformanceProfiler` already instruments a turn end-to-end with per-category
  timing (`primaryLLM`, `toolExecution`, `vibecop`, `injectionGuard`, `hooks`,
  `contextAssembly`) via a `TaskLocal` turn ID, with no UI dependency.

What is missing is (1) a reusable driver that stands the pieces up and hands back
timing, (2) a fake client packaged in `Sources/` (the current one lives in a test
file), (3) a deterministic way to read profiler results outside the UI publish
path, and (4) a way to invoke a run from the command line.

This design adds those four pieces. It does **not** split the package into a
SwiftUI-free `IrisCore` library — that larger refactor is explicitly out of scope.

## Scope

**In scope**

- Promote a reusable fake LLM client into `Sources/`, with configurable latency.
- A `ScenarioRunner` in `Sources/` that both tests and the CLI consume.
- A JSON scenario file format (fake-scripted and real-provider modes).
- A synchronous profiler sink so results are readable deterministically headless.
- A `--bench` mode on the existing `iris` executable (no new target).
- A `ProfilingHarnessTests` suite.

**Out of scope**

- Splitting `iris` into a library + app target (the "module split" the user
  declined). The bench runs as a headless mode of the existing executable.
- Removing `import SwiftUI` from `AppState`/`iris.swift`.
- Any change to how the shipping app renders profiler results (the existing
  `@Published recentCommands` publish path is untouched).

## Design

### 1. `FakeLLMClient` (`Sources/iris/FakeLLMClient.swift`)

Promote `ScriptedLLMClient` (currently defined in
`Tests/irisTests/LoopStopEnforcementTests.swift`) into `Sources/`, generalized:

```swift
final class FakeLLMClient: LLMClientProtocol, @unchecked Sendable {
    struct Latency: Sendable { var minMs: Int; var maxMs: Int } // 0/0 = instant
    private let responses: [GeminiResponse]
    private let latency: Latency
    private(set) var callCount = 0
    private var index = 0

    init(responses: [GeminiResponse], latency: Latency = .init(minMs: 0, maxMs: 0))

    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse
}
```

- Behavior is identical to today's `ScriptedLLMClient`: return queued responses in
  order, clamp at the last one, count calls. Serialized by the engine, so no lock.
- Adds an optional latency sleep (`Task.sleep`) before returning, so a fake run
  models TTFT/generation time instead of reporting near-zero primary-LLM time.
- The existing test-target `ScriptedLLMClient` definition is **deleted**; the ~7
  test files that use it are updated to `FakeLLMClient` (they already
  `@testable import iris`). This avoids a duplicate-symbol clash and keeps one
  definition.

### 2. `Scenario` + `ScenarioRunner` (`Sources/iris/ScenarioRunner.swift`)

**Scenario** — a `Codable` value describing a headless run:

```swift
struct Scenario: Codable, Sendable {
    enum ClientMode: String, Codable { case fake, real }

    struct Toggles: Codable, Sendable {          // all default false for clean overhead numbers
        var guards = false                        // vibecop + injection guard
        var hooks = false
        var sandbox = false
    }

    struct ScriptedResponse: Codable, Sendable {  // maps to a GeminiResponse
        enum Kind: String, Codable { case text, toolCalls }
        var kind: Kind
        var text: String?                         // kind == .text
        var calls: [ScriptedCall]?                // kind == .toolCalls
    }
    struct ScriptedCall: Codable, Sendable {
        var name: String
        var args: [String: JSONValue]             // JSONValue is already Codable
    }

    struct Turn: Codable, Sendable {
        var prompt: String
        var source: String = "User"
    }

    var name: String
    var clientMode: ClientMode = .fake
    var tier: ModelTier = .medium
    var toggles = Toggles()
    var latencyMs: FakeLLMClient.Latency? = nil   // fake mode only
    var turns: [Turn]
    var scriptedResponses: [ScriptedResponse] = [] // fake mode only; empty for real
}
```

- Scripted-response trees are expressed compactly (text or tool calls with
  `JSONValue` args) and built into `GeminiResponse` by a small mapper, rather than
  serializing the full `GeminiResponse`/`Candidate`/`Content`/`Part` nesting.
- Real mode ignores `scriptedResponses`/`latencyMs`; a real scenario is just
  `turns` (prompts) plus `tier`.

**ScenarioRunner** — the driver:

```swift
struct ScenarioResult: Sendable {
    var turnProfiles: [CommandProfile]   // one per PerformanceProfiler turn
    var wallClockMs: Double
}

@MainActor
enum ScenarioRunner {
    static func run(_ scenario: Scenario) async -> ScenarioResult
}
```

- Builds a fresh throwaway `AppState()` and sets `autoApproveTools = true` (see below),
  creates a conversation, constructs the client (`FakeLLMClient` from
  `scriptedResponses`, or `LLMClient()` for real), and an `IrisEngine(state:tier:client:)`.
- Binds the task-local profiler sink (section 3) around the turn loop, then runs each
  `Turn` via `engine.processInput(...)`, awaiting each before the next.
- Collects this run's `CommandProfile`s and total wall-clock into `ScenarioResult`.
- **Runs mutate no shared singletons.** Each run is self-contained (own `AppState`,
  task-local sink), so runs — and parallel tests — never contend. In particular it does
  NOT flip `ConfigManager` guard flags per run; doing so raced with parallel tests.

**Non-interactive approval (`AppState.autoApproveTools`).** `run_command`/`read_file`/
`write_file` normally await `requestApproval`, which consults permissions/Vibecop and then
blocks on an interactive queue — which would hang a headless run. A new transient,
non-persisted `AppState.autoApproveTools` flag makes `requestApproval` return `true`
immediately. It is instance-scoped (only the runner's throwaway `AppState` sets it; the
shipping app never does) so it cannot leak into other work.

**Guards/Keychain in headless processes (`IRIS_HEADLESS`).** A `swift run` binary is
ad-hoc-signed, so `KeychainManager` blocks on an access prompt and the aux guard models
aren't provisioned. `KeychainManager` already switches to an in-memory store under XCTest;
that seam is extended to honor `IRIS_HEADLESS`, and `InjectionGuard.sanitize` skips its
model-backed tiers (tier 2/3) under the same flag. `--bench` sets `IRIS_HEADLESS` for fake
runs; it is never set in tests. `Scenario.Toggles` remains in the schema as advisory metadata.

### 3. `PerformanceProfiler` task-local sink

`endTurn` delivers finished profiles via `DispatchQueue.main.async` onto `@Published
recentCommands` — not deterministically readable right after an awaited scenario, and
assumes a running main runloop. Add a **task-local** sink fired inline, leaving the UI
publish path untouched:

```swift
// PerformanceProfiler
@TaskLocal public static var runSink: (@Sendable (CommandProfile) -> Void)?  // nil in the app

// inside endTurn, before/independent of the main-thread publish:
Self.runSink?(finished)
```

`ScenarioRunner` binds `runSink` around its turn loop (`PerformanceProfiler.$runSink
.withValue(...) { ... }`). Because it is task-local, it captures ONLY turns produced within
that task tree — turns run by other concurrent work (parallel tests) inherit a nil sink and
are never captured. An earlier instance-property sink on the shared profiler was rejected: it
captured every turn in the process, including parallel tests' (observed as 20 profiles for a
1-turn run).

### 3a. `primaryLLM` measured at the seam

Primary-LLM timing was recorded *inside* `LLMClient`, so it was invisible for any other
client (the fake) and excluded engine-side overhead around the call. Moved to the engine's
call seam — `measure(.primaryLLM) { try await client.generateContent(...) }` — and removed
the duplicate recording in `LLMClient` (provider `MetricsManager` latency tracking stays).
Now every client is attributed uniformly.

### 4. `--bench` mode (`iris.swift`)

Replace the synthesized `@main` on `IrisApp` with an explicit entry that inspects
the command line before touching SwiftUI:

```swift
extension IrisApp {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--bench") {
            let path = args[safe: i + 1].flatMap { $0.hasPrefix("--") ? nil : $0 }
            runBenchAndExit(scenarioPath: path, real: args.contains("--real"))
            // never returns
        }
        // normal SwiftUI launch
        // (synthesized App.main() equivalent)
    }
}
```

- `runBenchAndExit` loads the scenario (JSON path, or a built-in default when
  omitted), runs `ScenarioRunner` on the main actor, prints a per-category timing
  table + wall-clock, and calls `exit(0)`. The `WindowGroup` is never created.
- `--real` forces `clientMode = .real` regardless of the file; requires configured
  provider/keys and never runs in CI.
- Usage: `swift run iris --bench scenarios/goal-loop.json`,
  `swift run iris --bench scenarios/live.json --real`.

### 5. Tests (`Tests/irisTests/ProfilingHarnessTests.swift`)

- Build a multi-turn `Scenario` in code (or load a fixture JSON), run it through
  `ScenarioRunner` with `FakeLLMClient`, and assert:
  - the run completes headlessly and returns one `CommandProfile` per turn,
  - primary-LLM and tool-execution categories receive attributed time,
  - `FakeLLMClient.callCount` matches the expected number of model rounds.
- Serves as a regression guard that the harness keeps working.

## Data flow

```
Scenario (JSON or code)
  -> ScenarioRunner.run
       -> AppState()  + createNewConversation
       -> apply Toggles (guards/hooks/sandbox off)
       -> client = FakeLLMClient(scriptedResponses, latency)  | LLMClient()
       -> IrisEngine(state:tier:client:)
       -> PerformanceProfiler.onTurnComplete = collect
       -> for each Turn: await engine.processInput(...)
       -> ScenarioResult { turnProfiles, wallClockMs }
  -> tests: assert   |   --bench: print table + exit(0)
```

## Error handling

- `loadScenario` throws on missing file / malformed JSON; `--bench` prints the
  error and `exit(1)`.
- Empty `scriptedResponses` in fake mode with a scenario that drives model rounds:
  `FakeLLMClient` clamps at the last response (today's behavior); the harness test
  covers the well-formed case. A fake run that exhausts responses is a scenario
  authoring error, surfaced by the clamp returning a stale response (documented).
- Real mode surfaces provider errors as engine system messages (unchanged); the
  bench prints whatever the turn produced.

## Resolved during implementation

- **Toggles mechanism.** Rather than mutate global `ConfigManager` per run (which raced
  with parallel tests), guards are governed process-wide by `IRIS_HEADLESS`; the approval/
  Vibecop path is bypassed by the instance-scoped `AppState.autoApproveTools`. `Toggles`
  stays in the schema as advisory metadata.
- **Example scenarios** live at repo root under `scenarios/` (e.g. `scenarios/echo-latency.json`).
- **Keychain block.** A `swift run` bench binary is ad-hoc-signed and would block on a
  Keychain prompt; `IRIS_HEADLESS` routes `KeychainManager` to its in-memory store.
- **Async entry.** `@main` was removed from `IrisApp`; a `main.swift` uses top-level `await`
  to run the bench on the main actor, then `exit(0)` — `dispatchMain()` deadlocked the
  MainActor task and was abandoned.
```
