# Performance Evaluation Suite — Design

* **Builds on**: [#97](https://github.com/bnaylor/iris/pull/97) — headless profiling harness (`--bench`, `ScenarioRunner`, `PerformanceProfiler`)
* **Date**: 2026-09-17
* **Status**: Approved

## Motivation

Iris feels slow next to vendor harnesses. Some of that is the layered security model (Vibecop,
the multi-tier injection guard) and some is the harness itself, but today there is no way to say
how much is which. `--bench` prints a six-bucket breakdown for one scenario and throws it away;
nothing is compared to a raw provider call, nothing is persisted, and nothing can be re-run
months later against the same yardstick.

This spec adds three things:

1. **Attribution.** Finer measurement (per model call, per tool call, named sub-spans) and a
   five-rung *ladder* that isolates what each layer of Iris adds on top of a bare provider call.
2. **A tracked database.** One JSON record per suite run under `perf/`, with a comparison
   command that flags regressions against a promoted baseline.
3. **Tool-eagerness evaluation.** A measured rate of unprompted tool use, plus a written analysis
   of what in the request drives it.

The headline metric is **overhead ratio**: median Iris turn wall-clock divided by median
wall-clock of a bare provider call for the same prompt. It separates what Iris adds from what the
model costs, so a model-side slowdown does not read as a harness regression.

## Findings that shape the design (from reading the code, before measuring)

- **No provider client streams.** Every turn waits for the whole response; time-to-first-token
  equals full generation time. Vendor harnesses stream. Streaming is out of scope here but the
  ladder will quantify what it would buy (rung 1 latency is the floor).
- **Cloud guard calls layer onto every turn.** With Vibecop and the prompt guard on the `cloud`
  engine, each `run_command` costs a Vibecop model call, each tool output can cost a tier-3 guard
  call, and `USER.md` and `AGENTS.md` are re-sanitized through tier 3 on every turn although they
  rarely change (`iris.swift` request assembly).
- **Large tool surface on every call.** ~13 declarations plus MCP tools, several worded as
  "do this when the user says…". Inflates prompt tokens and is a plausible eagerness driver.
- **Per-turn assembly** appends a fact-store search, the user profile, and workspace rules.

## Non-goals

- No change to provider clients, prompts, tool descriptions, or guard behaviour. This work
  measures; fixes are follow-ups with a baseline to compare against.
- No changes to `DiagnosticsView`. Profiler additions are additive and the UI keeps its six
  buckets.
- No CI timing gate. The fake smoke suite runs under `swift test` as a harness *correctness*
  check only.
- No comparison against third-party harnesses by driving them. The bare provider call is the
  floor every harness shares.

## Design

### 1. `perf/` layout

```
perf/
  README.md                 how to run, how to read a record, what to commit
  run.sh                    the one way to execute the suites (release build, fixed args)
  suites/
    smoke.json              fake client, CI-safe, proves the harness works
    ladder.json             real provider, five-rung overhead ladder
    tool-eagerness.json     real provider, no-tool-warranted prompts + a should-use-tool control set
  prompts/
    model-only/*.json       scenarios that should not induce tools
    tool-use/*.json         scenarios that explicitly require tools
  runs/                     one JSON per suite run (gitignored)
  baselines/                hand-promoted run records later runs compare against (committed)
```

Scenario files keep today's `Scenario` schema. A **suite** file lists scenarios and how to run
them:

```json
{
  "name": "ladder",
  "lane": "real",
  "repetitions": 3,
  "pauseMs": 1500,
  "rungs": [1, 2, 3, 4, 5],
  "scenarios": [
    "perf/prompts/model-only/capital-city.json",
    "perf/prompts/tool-use/read-one-file.json"
  ]
}
```

| Field | Default | Notes |
|---|---|---|
| `lane` | `"fake"` | `fake` needs no network and forces `HeadlessMode`; `real` drives the configured provider. |
| `repetitions` | 3 | Per scenario per rung. |
| `pauseMs` | 0 | Sleep between real calls so a suite does not trip 429s. |
| `rungs` | `[5]` | Which ladder rungs to run (see §3). `[5]` is "a normal Iris turn". |
| `scenarios` | required | Paths relative to the repo root. |

`perf/runs/` is gitignored while the effort is young. Promoting a record to `perf/baselines/` is
a deliberate `git add`; that is what regular regression runs compare against.

### 2. Profiler additions (additive)

`CommandProfile` gains three collections. `PerformanceProfiler` gains a recorder for each, keyed
by the task-local turn id exactly like `record(turnID:category:durationMs:)`.

```swift
struct ModelCallRecord: Codable, Sendable {
    let round: Int            // 0-based round within the turn
    let model: String
    let latencyMs: Double
    let promptTokens: Int?    // from UsageMetadata; nil for the fake client
    let outputTokens: Int?
    let returnedToolCalls: Bool
}
struct ToolCallRecord: Codable, Sendable {
    let name: String
    let ms: Double
    let ok: Bool
}
// Named sub-spans: "guard.tier1" / "guard.tier2" / "guard.tier3" / "vibecop" /
// "assembly.systemPrompt" / "assembly.userProfile" / "assembly.agentsMd" / "assembly.factSearch"
var spans: [String: CategoryStat]
```

Instrumentation points:

| Record | Where |
|---|---|
| model call | engine seam in `processInputBody` (already inside `measure(.primaryLLM)`); tokens from `response.usageMetadata` |
| tool call | around `executeFunctionCall` in the `withTaskGroup` dispatch |
| `guard.tierN` | `InjectionGuard.sanitize`, one span per tier actually executed |
| `vibecop` | existing Vibecop span, mirrored into `spans` |
| `assembly.*` | the four assembly steps in request building |

`measureSpan(_ name: String, …)` is a sibling of `measure(_:)` that writes to `spans` instead of
a category. The six `PerfCategory` buckets and `derivedOtherMs` are unchanged.

### 3. The ladder

For a prompt `P` at tier `T`, each rung is timed `repetitions` times:

| Rung | What runs | Delta from previous rung isolates |
|---|---|---|
| 1 | `LLMClient().generateContent` with `contents=[P]`, no `systemInstruction`, no `tools` | the model itself (the denominator) |
| 2 | rung 1 + Iris's assembled system prompt as `systemInstruction` | prompt size |
| 3 | rung 2 + the full tool declaration list | tool schema cost and its effect on the reply |
| 4 | full `ScenarioRunner` turn with guards off | harness overhead |
| 5 | full `ScenarioRunner` turn with guards as configured | the security layers |

Rungs 1–3 are direct client calls, so they reuse the provider clients and ADC auth; they record a
`ModelCallRecord` each. The system prompt for rung 2 is obtained by asking a throwaway
`IrisEngine` for its assembled prompt through a small `nonisolated` accessor added for this
purpose; the tool list for rung 3 comes from `ToolExecutor.getTools()` plus the engine-appended
declarations, exposed through the same accessor so the two rungs see exactly what a real turn
sends.

**Overhead ratio** = median(rung 5 wall-clock) / median(rung 1 latency). Rung 4 / rung 1 is
reported alongside as the *harness-only* ratio.

In the fake lane only rungs 4 and 5 are meaningful (rungs 1–3 would time a sleep); the suite
loader rejects `rungs` containing 1–3 with `lane: fake`.

### 4. Volatile settings for the bench process

Rung 4 needs Vibecop and the advanced injection guard **off**, and `ConfigManager` setters
persist. `IrisDefaults` gains a second in-process switch, sibling to the test suite:

```swift
/// Called by BenchCLI / PerfCLI before ConfigManager.shared is first touched. The store becomes
/// a volatile suite seeded from the user's persistent domain, so a run sees the real provider
/// configuration but nothing it sets can escape the process.
static func useVolatileCopyOfStandard()
```

Implementation: `UserDefaults(suiteName: "iris-bench-<pid>")`, `removePersistentDomain`, then
`setPersistentDomain(standard.persistentDomain(forName: <app domain>) ?? [:])`. The suite file is
removed again on exit (and swept by the same stale-file sweep the tests use, since it matches
the `iris-tests-*`/`iris-bench-*` pattern the sweep is widened to).

With that in place `Scenario.toggles.guards` is finally wired: the runner sets
`enableVibecop` and `enableAdvancedPromptInjectionProtection` in the volatile copy per rung
(`false` for rung 4, as-seeded for rung 5). `toggles.hooks` and `toggles.sandbox` remain
advisory in this slice; the record captures their effective values so results are interpretable.
The wiring is guarded: outside a volatile store the runner refuses to touch guard settings and
logs why, so a test or the app can never trip it.

### 5. Run record

One `PerfRunRecord` per suite run, `Codable`, written to
`perf/runs/<ISO8601 UTC>-<suite>-<short sha>.json`. `schemaVersion` starts at 1 and every field
added later is `decodeIfPresent` (the same rule as persisted conversations).

```swift
struct PerfRunRecord: Codable {
    var schemaVersion: Int
    var suite: String
    var startedAt: Date
    var finishedAt: Date
    var environment: PerfEnvironment
    var scenarios: [PerfScenarioResult]
}
struct PerfEnvironment: Codable {
    var gitSha: String; var gitDirty: Bool
    var machineModel: String; var osVersion: String; var cpuCount: Int
    var buildConfiguration: String            // "release" / "debug" — debug runs are flagged in reports
    var provider: String; var models: [String: String]   // tier -> model name
    var vibecopEnabled: Bool; var vibecopEngine: String
    var injectionGuardEnabled: Bool; var promptGuardEngine: String
    var sandboxEnabled: Bool; var headless: Bool
    var toolDeclarationCount: Int             // built-ins + MCP at run time; a changed MCP setup shows up here
}
struct PerfScenarioResult: Codable {
    var name: String; var path: String
    var category: String                       // parent directory of the scenario file, e.g. "model-only"
    var lane: String                           // fake / real
    var rungs: [PerfRungResult]
    var summary: PerfScenarioSummary
}
struct PerfRungResult: Codable {
    var rung: Int
    var repetitions: [PerfRepetition]
    var medianMs: Double; var p90Ms: Double
}
struct PerfRepetition: Codable {
    var index: Int
    var coldStart: Bool                        // first repetition in the process
    var wallClockMs: Double
    var turns: [PerfTurn]                      // empty for rungs 1–3 (single model call instead)
    var modelCalls: [ModelCallRecord]          // rungs 1–3 put their one call here
    var error: String?                         // a failed repetition is recorded, not fatal
}
struct PerfTurn: Codable {
    var totalMs: Double
    var categories: [String: CategoryStat]
    var spans: [String: CategoryStat]
    var modelCalls: [ModelCallRecord]
    var toolCalls: [ToolCallRecord]
    var finalTextLength: Int
}
struct PerfScenarioSummary: Codable {
    var medianMs: Double; var p90Ms: Double    // of the highest rung run
    var overheadRatio: Double?                 // rung 5 / rung 1 when both present
    var harnessRatio: Double?                  // rung 4 / rung 1 when both present
    var toolCallRate: Double                   // fraction of rung-5 turns with >= 1 tool call
    var toolCallsByName: [String: Int]
}
```

`CategoryStat` becomes `Codable`. Statistics (`median`, `p90`) live in a small `PerfStats` enum
with exact behaviour for n = 1 and n = 2 so tests are unambiguous.

### 6. CLI

`main.swift` gains `--perf` next to `--bench`:

```
iris --perf run     <suite.json> [--reps N] [--out DIR] [--fake-only]
iris --perf report  <run.json>
iris --perf compare <baseline.json> <run.json> [--threshold 0.20]
```

- **run** executes scenarios sequentially, prints the report, writes the record. A repetition
  that fails (including a 429 that outlives the client retry) is recorded with `error` and the
  suite continues. `--fake-only` skips real-lane suites, for machines without credentials.
- **report** renders a record as Markdown: per scenario a row per rung (median, p90), the two
  ratios, the top five `spans`, tool calls by name, and a "debug build" or "dirty tree" warning
  line when applicable.
- **compare** joins two records by scenario name and rung. It refuses (exit 2) when provider or
  any model name differs. It prints percent change for median wall-clock, overhead ratio, and
  prompt tokens, flags anything past `--threshold` (default 20 %), and exits 1 if anything is
  flagged so a scheduled run can gate on it.

`--bench` is unchanged from the outside; internally it builds a one-scenario fake suite and
prints the existing `BenchSummary`.

### 7. `perf/run.sh`

The single sanctioned way to execute the suites, so every run is comparable:

```sh
perf/run.sh                 # release build, smoke + ladder + tool-eagerness, compare to baselines
perf/run.sh --fake-only     # smoke only (no credentials needed)
perf/run.sh --promote       # additionally copy this run's records into perf/baselines/
```

It always: builds `-c release` (debug timings are not comparable and the record flags them),
runs each suite with the suite file's own repetitions, writes to `perf/runs/`, and, when a
baseline exists for a suite, runs `compare` and surfaces the exit code. It prints the git sha and
a reminder if the tree is dirty.

### 8. Tool-eagerness evaluation

**Measured.** `perf/suites/tool-eagerness.json` runs rung 5 over `perf/prompts/model-only/`
(factual questions, advice, short writing, questions about the conversation) and a control set
from `perf/prompts/tool-use/` (prompts that clearly need `read_file` / `run_command`). The report
shows eagerness rate per category and `toolCallsByName`; the control set shows the rate a fix
must not push below 1.0.

**Read.** `docs/reviews/2026-09-17-tool-eagerness-analysis.md`, written after the first real
run: what in the request pushes the model toward tools (tool-declaration size and imperative
descriptions, the per-turn fact-store block, SOUL.md / shipped steering, skills list), the
measured rates, and concrete candidate changes ranked by expected effect. Changing the prompt is
a follow-up PR measured against this baseline.

### 9. Testing

Swift Testing, one file per unit:

- `PerfStatsTests` — median/p90 for n = 1, 2, odd, even; empty input.
- `PerfRecordTests` — encode/decode round trip; a v1 record with missing optional fields still
  decodes (`decodeIfPresent`).
- `PerfSuiteTests` — loader defaults; rejects rungs 1–3 in the fake lane; relative paths resolve
  against the repo root.
- `PerfCompareTests` — percent change; flagging at threshold; refusal on provider/model
  mismatch; exit codes.
- `VolatileDefaultsTests` — a value set through the volatile copy is visible to
  `ConfigManager` in-process and absent from the seeded domain afterwards.
- `PerfRunnerTests` — the smoke suite (fake lane, rungs 4–5) yields a record with one
  `PerfScenarioResult` per scenario, `toolCalls` populated for the tool scenario, and
  `modelCalls` with `promptTokens == nil`.
- `ProfilerRecordTests` — `recordModelCall` / `recordToolCall` / `measureSpan` attribute to the
  task-local turn and are no-ops outside one.

### 10. Delivery order

1. Profiler additions and `IrisDefaults.useVolatileCopyOfStandard()` (with the guard-toggle wiring).
2. Run record, stats, suite loader, `--perf run` (fake lane end to end, smoke suite, `perf/run.sh --fake-only`).
3. Ladder rungs 1–3 and the real lane; `report`; `compare`.
4. Prompt sets and the three suite files; `perf/README.md`; README pointer.
5. First real ladder and eagerness runs on this machine; promote a baseline; write the eagerness analysis.

## Open risks

- **Quota.** Real suites make dozens of provider calls; `pauseMs` and small `repetitions` keep a
  run under the 429 budget seen on this account. The record tolerates failed repetitions.
- **Noise.** Real-lane numbers vary with provider load. Medians over ≥ 3 repetitions and the
  ratio (both numerator and denominator measured in the same window) are the mitigation; the
  README says to run on a quiet machine and to compare like builds only.
- **MCP tools.** Rung 3 sends whatever tools are configured at run time; the record stores the
  tool count so a changed MCP setup is visible in a comparison.
