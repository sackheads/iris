# Headless Profiling (`--bench`)

Iris can run its core agent loop end-to-end **without the UI** so you can profile
turn/goal-loop performance and catch regressions without a human clicking through
the app. The same driver (`ScenarioRunner`) powers both the `--bench` CLI and the
profiling tests in `Tests/irisTests/ProfilingHarnessTests.swift`.

## Running a benchmark

```bash
swift run iris --bench                                # built-in default scenario
swift run iris --bench scenarios/echo-latency.json    # a scenario file
swift run iris --bench scenarios/live.json --real     # hit a real provider (needs keys)
```

- With **no path**, a tiny built-in scenario runs (one command, then finish) — a
  smoke test that the harness itself works.
- With a **path**, the JSON scenario at that path is loaded (see format below).
- `--real` forces the scenario onto a real provider regardless of what the file
  says (`clientMode` is overridden to `real`). This needs configured provider
  keys/auth and makes network calls, so it never runs in CI.

A `swift run` binary is ad-hoc-signed. For **fake** runs the harness flips the
in-process `HeadlessMode` switch, which routes the Keychain to an in-memory store
(no access prompt) and skips the model-backed injection-guard tiers (2/3).
`--real` runs keep Keychain access so provider auth resolves.

`HeadlessMode` is deliberately not an environment variable: it disables an
injection defense, so it must not be settable from outside the process.

> **Scenario files are executable input.** A run sets `autoApproveTools`, so every
> tool call in a scenario — including `run_command` — executes with no approval
> prompt and no Vibecop check. Only run scenario files you wrote or reviewed.

## Reading the output

```
Scenario: echo-latency
Turns: 1   Wall-clock: 1040.3 ms

Category              ms          calls
----------------------------------------
Primary LLM           931.6       3
Tool execution        96.5        2
  Injection guard     0.5         6
Context assembly      2.3         1
Total (turns)         1039.9
```

- **Wall-clock** — total elapsed time for the whole run, measured by the runner.
- **Turns** — number of `PerformanceProfiler` turns (one per `processInput`).
- Each **category** row aggregates that category's time and call count across all
  turns in the run. Indented rows (e.g. `Injection guard`) are sub-measures of a
  parent category.
- **Total (turns)** — the sum of per-turn profiled time. It is normally a little
  under wall-clock; the gap is un-profiled glue (setup, the runner's own overhead).

Categories come from `PerfCategory`: `primaryLLM`, `toolExecution`, `vibecop`,
`injectionGuard`, `hooks`, `contextAssembly`. `primaryLLM` is measured at the
engine's call seam, so it is attributed uniformly for **any** client — including the
fake one. In a fake run with `latencyMs`, `Primary LLM` reports the simulated sleep;
with no latency it is ~0, which isolates pure harness overhead (see the default
scenario: `Primary LLM 0.0`).

## Scenario JSON format

A scenario is a single JSON object. Only `name` and `turns` are required; every
other field defaults.

```json
{
  "name": "echo-latency",
  "clientMode": "fake",
  "tier": "medium",
  "toggles": { "guards": false, "hooks": false, "sandbox": false },
  "latencyMs": { "minMs": 150, "maxMs": 400 },
  "turns": [
    { "prompt": "Run two commands, then finish.", "source": "User" }
  ],
  "scriptedResponses": [
    { "kind": "toolCalls", "calls": [ { "name": "run_command", "args": { "command": "echo first" } } ] },
    { "kind": "toolCalls", "calls": [ { "name": "run_command", "args": { "command": "echo second" } } ] },
    { "kind": "text", "text": "Both commands ran. Done." }
  ]
}
```

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `name` | string | — (required) | Label printed in the summary header. |
| `turns` | array | — (required) | The user prompts driving the run, one entry per turn. |
| `turns[].prompt` | string | — (required) | The prompt text for that turn. |
| `turns[].source` | string | `"User"` | Provenance label for the turn. |
| `clientMode` | `"fake"` \| `"real"` | `"fake"` | `fake` replays `scriptedResponses`; `real` hits a provider. |
| `tier` | `ModelTier` | `"medium"` | Model tier the engine runs at (`easy`/`medium`/`hard`). |
| `latencyMs` | `{ "minMs", "maxMs" }` | none | Fake mode only. Simulates per-call model latency (random in range). Omit for instant (~0). |
| `scriptedResponses` | array | `[]` | Fake mode only. The model's replies, consumed in order. |
| `toggles` | `{ guards, hooks, sandbox }` | all `false` | **Advisory metadata only** today — see note below. |

### Scripted responses (fake mode)

Each entry is one model turn, mapped into the `GeminiResponse` the engine would
receive. Two kinds:

- **Text** — the model's final answer, ends the turn:
  ```json
  { "kind": "text", "text": "Both commands ran. Done." }
  ```
- **Tool calls** — the model asks to run one or more tools; the engine executes
  them and loops back for the next scripted response:
  ```json
  { "kind": "toolCalls", "calls": [
    { "name": "run_command", "args": { "command": "echo first" } }
  ] }
  ```

`args` is an arbitrary JSON object matching the tool's parameters (`run_command`
takes `command`; `read_file`/`write_file` take a `path`, etc.). Responses are
consumed in order across the whole run. If a run needs more responses than you
scripted, `FakeLLMClient` clamps and re-returns the **last** one — a stale reply is
the symptom of an under-scripted scenario. Count the model rounds a turn will drive
(one per tool-call round, plus the final text) and script exactly that many.

Tool approval is auto-granted in the harness (`AppState.autoApproveTools`), so
`run_command`/`read_file`/`write_file` don't block on an interactive prompt.

> **`toggles` caveat:** the three toggles are carried in the schema but are **not
> wired up** — per-run mutation of the global guard config raced with parallel
> tests, so guards/hooks are governed process-wide by `HeadlessMode` instead.
> Leaving them at `false` is correct; setting them `true` has no effect today.

## Adding a scenario

1. Create `scenarios/<name>.json`. Start from `scenarios/echo-latency.json`.
2. Set `name` and the `turns` you want to drive.
3. For a **fake** run, script one `scriptedResponses` entry per model round: a
   `toolCalls` entry for each tool-call round, then a final `text` entry. Add
   `latencyMs` if you want the primary-LLM time to model real generation latency
   instead of reporting ~0.
4. For a **real** run, set `"clientMode": "real"` (or pass `--real`) and drop
   `scriptedResponses`/`latencyMs` — a real scenario is just `turns` + `tier`.
5. Run it: `swift run iris --bench scenarios/<name>.json`.

To assert on a scenario in tests, build a `Scenario` in code (or `Scenario.load`
a fixture) and run it through `ScenarioRunner.run`, then inspect the returned
`ScenarioResult.turnProfiles` / `wallClockMs` — see
`Tests/irisTests/ProfilingHarnessTests.swift`.
