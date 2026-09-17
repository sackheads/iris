# Performance Evaluation Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `--perf` mode on the iris binary that runs suites of scenarios against a five-rung overhead ladder, writes one JSON record per run under `perf/`, and can report and compare records, plus a `perf/run.sh` that always executes the suites the same way.

**Architecture:** Extends the existing headless harness (`ScenarioRunner`, `PerformanceProfiler`, `BenchCLI`). The profiler gains per-model-call, per-tool-call, and named sub-span records. The bench process runs against a volatile copy of the user's settings so guard toggles never persist. Rungs 1 to 3 are direct provider calls built from a captured real request; rungs 4 and 5 are ordinary engine turns with guards off and as configured. Records, statistics, report, and comparison are pure Swift value types with unit tests.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing (`@Suite`, `@Test`, `#expect`), Foundation only. No new dependencies.

**Spec:** `docs/specs/2026-09-17-performance-evaluation-suite.md`

## Global Constraints

- Never mutate `ConfigManager.shared` in a test (AGENTS.md). Guard toggling is gated on `IrisDefaults.isVolatileCopy`, which is never true under `swift test`.
- Every new field on a persisted `Codable` type is Optional or decoded with `decodeIfPresent` (AGENTS.md invariant 1). This applies to `PerfRunRecord` and everything nested in it.
- Tests use Swift Testing, never XCTest. One file per unit.
- `PerfCategory` and `DiagnosticsView` are not changed.
- No `TODO`/`FIXME`; no emoji in code or commit messages; conventional commits with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- `perf/runs/` is gitignored; `perf/baselines/` is committed.
- Run all tests with `swift test`; a focused run is `swift test --filter <SuiteStructName>`.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/iris/PerformanceProfiler.swift` (modify) | `ModelCallRecord`, `ToolCallRecord`, `spans`, recorders, `measureSpan` |
| `Sources/iris/iris.swift` (modify) | record model calls, tool calls, assembly spans |
| `Sources/iris/InjectionGuard.swift` (modify) | `guard.tier1/2/3` spans |
| `Sources/iris/VibecopService.swift` (modify) | `vibecop` span |
| `Sources/iris/IrisDefaults.swift` (modify) | volatile copy of standard defaults; sweep covers `iris-bench-*` |
| `Sources/iris/ScenarioRunner.swift` (modify) | `GuardMode`, `clientOverride`, `finalTexts` |
| `Sources/iris/CapturingLLMClient.swift` (new) | client that records requests and replies with text |
| `Sources/iris/PerfStats.swift` (new) | median, p90, percent change |
| `Sources/iris/PerfRecord.swift` (new) | run record types, load/write |
| `Sources/iris/PerfSuite.swift` (new) | suite file, validation, repo root |
| `Sources/iris/PerfEnvironment.swift` (new) | git, machine, config capture |
| `Sources/iris/PerfLadder.swift` (new) | rungs 1 to 3 |
| `Sources/iris/PerfRunner.swift` (new) | suite execution, summaries |
| `Sources/iris/PerfReport.swift` (new) | Markdown report |
| `Sources/iris/PerfCompare.swift` (new) | comparison and exit codes |
| `Sources/iris/PerfCLI.swift` (new) | `--perf run/report/compare` |
| `Sources/iris/main.swift`, `BenchCLI.swift` (modify) | dispatch; bench uses volatile copy |
| `perf/run.sh`, `perf/README.md`, `perf/suites/*.json`, `perf/prompts/**/*.json` (new) | the database and its entry point |
| `.gitignore`, `README.md` (modify) | ignore runs; pointer to perf/README.md |

---

### Task 1: Profiler records and named spans

**Files:**
- Modify: `Sources/iris/PerformanceProfiler.swift`
- Test: `Tests/irisTests/ProfilerRecordTests.swift`

**Interfaces:**
- Produces: `ModelCallRecord(round:model:latencyMs:promptTokens:outputTokens:returnedToolCalls:)`, `ToolCallRecord(name:ms:ok:)`, `CommandProfile.spans/modelCalls/toolCalls`, `PerformanceProfiler.recordSpan(turnID:name:durationMs:)`, `recordModelCall(turnID:_:)`, `recordToolCall(turnID:_:)`, free functions `measureSpan(_:_:)` and `measureSpanSync(_:_:)`. `CategoryStat` becomes `Codable` and `Equatable`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/irisTests/ProfilerRecordTests.swift
import Testing
import Foundation
@testable import iris

/// The perf suite needs more than six buckets: which model call, which tool, which guard tier.
/// These records ride on the same task-local turn id as the buckets do.
@Suite("PerformanceProfiler records")
struct ProfilerRecordTests {
    @Test("model calls, tool calls and spans attribute to the active turn")
    func attributesToTurn() {
        let p = PerformanceProfiler()
        let id = p.beginTurn(label: "t", source: "test")
        p.recordModelCall(turnID: id, ModelCallRecord(round: 0, model: "m", latencyMs: 12,
                                                      promptTokens: 100, outputTokens: 5, returnedToolCalls: false))
        p.recordToolCall(turnID: id, ToolCallRecord(name: "run_command", ms: 3, ok: true))
        p.recordSpan(turnID: id, name: "guard.tier1", durationMs: 1)
        p.recordSpan(turnID: id, name: "guard.tier1", durationMs: 2)
        let profile = p.activeProfileForTesting(id)
        #expect(profile?.modelCalls.count == 1)
        #expect(profile?.modelCalls.first?.promptTokens == 100)
        #expect(profile?.toolCalls.first?.name == "run_command")
        #expect(profile?.spans["guard.tier1"]?.ms == 3)
        #expect(profile?.spans["guard.tier1"]?.count == 2)
    }

    @Test("records outside a turn are dropped")
    func noTurnIsNoop() {
        let p = PerformanceProfiler()
        p.recordModelCall(turnID: nil, ModelCallRecord(round: 0, model: "m", latencyMs: 1,
                                                       promptTokens: nil, outputTokens: nil, returnedToolCalls: false))
        p.recordSpan(turnID: UUID(), name: "x", durationMs: 1)
        #expect(p.activeCountForTesting == 0)
    }

    @Test("records travel with the profile into the run sink")
    func recordsReachTheSink() {
        let p = PerformanceProfiler()
        let id = p.beginTurn(label: "t", source: "test")
        p.recordToolCall(turnID: id, ToolCallRecord(name: "read_file", ms: 1, ok: false))
        var finished: CommandProfile?
        PerformanceProfiler.$runSink.withValue({ finished = $0 }) {
            p.endTurn(id, totalMs: 10)
        }
        #expect(finished?.toolCalls.first?.ok == false)
    }

    @Test("measureSpan attributes to the task-local turn")
    func measureSpanUsesTaskLocal() async {
        let id = PerformanceProfiler.shared.beginTurn(label: "span", source: "test")
        defer { PerformanceProfiler.shared.endTurn(id, totalMs: 0) }
        await PerformanceProfiler.$currentTurnID.withValue(id) {
            _ = await measureSpan("assembly.test") { 42 }
            _ = measureSpanSync("assembly.sync") { 7 }
        }
        let profile = PerformanceProfiler.shared.activeProfileForTesting(id)
        #expect(profile?.spans["assembly.test"]?.count == 1)
        #expect(profile?.spans["assembly.sync"]?.count == 1)
    }

    @Test("CategoryStat round-trips through JSON")
    func categoryStatCodable() throws {
        var s = CategoryStat(); s.add(1.5); s.add(2.5)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(CategoryStat.self, from: data) == s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep error: | head`
Expected: errors such as `type 'PerformanceProfiler' has no member 'recordModelCall'`, `cannot find 'ModelCallRecord' in scope`.

- [ ] **Step 3: Implement**

In `Sources/iris/PerformanceProfiler.swift`:

Replace the `CategoryStat` declaration line with:

```swift
public struct CategoryStat: Codable, Sendable, Equatable {
```

After `CategoryStat`, add:

```swift
/// One model round within a turn. Token counts come from the provider's usage metadata and
/// are nil for the fake client.
public struct ModelCallRecord: Codable, Sendable, Equatable {
    public let round: Int
    public let model: String
    public let latencyMs: Double
    public let promptTokens: Int?
    public let outputTokens: Int?
    public let returnedToolCalls: Bool

    public init(round: Int, model: String, latencyMs: Double, promptTokens: Int?, outputTokens: Int?, returnedToolCalls: Bool) {
        self.round = round; self.model = model; self.latencyMs = latencyMs
        self.promptTokens = promptTokens; self.outputTokens = outputTokens; self.returnedToolCalls = returnedToolCalls
    }
}

/// One dispatched tool call. `ok` is false when the executor returned an error string.
public struct ToolCallRecord: Codable, Sendable, Equatable {
    public let name: String
    public let ms: Double
    public let ok: Bool

    public init(name: String, ms: Double, ok: Bool) {
        self.name = name; self.ms = ms; self.ok = ok
    }
}
```

In `CommandProfile`, after `public var categories: [PerfCategory: CategoryStat] = [:]`, add:

```swift
    /// Named sub-spans finer than the six buckets, e.g. "guard.tier2", "assembly.userProfile".
    public var spans: [String: CategoryStat] = [:]
    public var modelCalls: [ModelCallRecord] = []
    public var toolCalls: [ToolCallRecord] = []

    public mutating func addSpan(_ name: String, durationMs: Double) {
        spans[name, default: CategoryStat()].add(durationMs)
    }
```

In `PerformanceProfiler`, after `record(turnID:category:durationMs:)`, add:

```swift
    public func recordSpan(turnID: UUID?, name: String, durationMs: Double) {
        guard let turnID else { return }
        lock.lock()
        active[turnID]?.addSpan(name, durationMs: durationMs)
        lock.unlock()
    }

    public func recordModelCall(turnID: UUID?, _ call: ModelCallRecord) {
        guard let turnID else { return }
        lock.lock()
        active[turnID]?.modelCalls.append(call)
        lock.unlock()
    }

    public func recordToolCall(turnID: UUID?, _ call: ToolCallRecord) {
        guard let turnID else { return }
        lock.lock()
        active[turnID]?.toolCalls.append(call)
        lock.unlock()
    }
```

At the end of the file, add:

```swift
/// Time an async span under a free-form name and attribute it to the current turn.
@discardableResult
public func measureSpan<T>(_ name: String,
                           isolation: isolated (any Actor)? = #isolation,
                           _ work: () async throws -> T) async rethrows -> T {
    let turnID = PerformanceProfiler.currentTurnID
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        PerformanceProfiler.shared.recordSpan(turnID: turnID, name: name,
                                              durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
    }
    return try await work()
}

/// Synchronous sibling of `measureSpan`.
@discardableResult
public func measureSpanSync<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
    let turnID = PerformanceProfiler.currentTurnID
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        PerformanceProfiler.shared.recordSpan(turnID: turnID, name: name,
                                              durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000.0)
    }
    return try work()
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ProfilerRecordTests 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PerformanceProfiler.swift Tests/irisTests/ProfilerRecordTests.swift
git commit -m "feat(perf): model-call, tool-call and named-span records on CommandProfile" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Instrument the engine, injection guard, and Vibecop

**Files:**
- Modify: `Sources/iris/iris.swift` (request assembly around lines 349-375, model seam around line 670, tool dispatch around line 754)
- Modify: `Sources/iris/InjectionGuard.swift:39-70`
- Modify: `Sources/iris/VibecopService.swift:113-126`
- Test: `Tests/irisTests/EngineInstrumentationTests.swift`

**Interfaces:**
- Consumes: Task 1 recorders and `measureSpan`/`measureSpanSync`.
- Produces: profiles from any engine turn now carry `modelCalls`, `toolCalls`, and spans named `guard.tier1`, `guard.tier2`, `guard.tier3`, `vibecop`, `assembly.factSearch`, `assembly.userProfile`, `assembly.agentsMd`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/irisTests/EngineInstrumentationTests.swift
import Testing
import Foundation
@testable import iris

/// A fake scenario through the real engine loop must leave the finer records behind.
@MainActor
@Suite("Engine instrumentation")
struct EngineInstrumentationTests {
    private var oneCommandThenText: Scenario {
        Scenario(name: "instrumented", clientMode: .fake,
                 turns: [Scenario.Turn(prompt: "run it")],
                 scriptedResponses: [
                    Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                        Scenario.ScriptedCall(name: "run_command", args: ["command": .string("echo instrumented")])
                    ]),
                    Scenario.ScriptedResponse(kind: .text, text: "done", calls: nil)
                 ])
    }

    @Test("every model round is recorded with its round index and tool-call flag")
    func modelCallsRecorded() async throws {
        let result = await ScenarioRunner.run(oneCommandThenText)
        let profile = try #require(result.turnProfiles.first)
        #expect(profile.modelCalls.map(\.round) == [0, 1])
        #expect(profile.modelCalls.map(\.returnedToolCalls) == [true, false])
        #expect(profile.modelCalls.allSatisfy { $0.promptTokens == nil })
        #expect(profile.modelCalls.allSatisfy { !$0.model.isEmpty })
    }

    @Test("each dispatched tool is recorded by name")
    func toolCallsRecorded() async throws {
        let result = await ScenarioRunner.run(oneCommandThenText)
        let profile = try #require(result.turnProfiles.first)
        #expect(profile.toolCalls.map(\.name) == ["run_command"])
        #expect(profile.toolCalls.first?.ok == true)
    }

    @Test("assembly and guard tier-1 spans are present")
    func spansRecorded() async throws {
        let result = await ScenarioRunner.run(oneCommandThenText)
        let profile = try #require(result.turnProfiles.first)
        #expect(profile.spans["assembly.factSearch"] != nil)
        #expect(profile.spans["assembly.userProfile"] != nil)
        #expect((profile.spans["guard.tier1"]?.count ?? 0) >= 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EngineInstrumentationTests 2>&1 | grep -E "✘|Test run"`
Expected: the three tests fail on empty `modelCalls`, empty `toolCalls`, and nil spans.

- [ ] **Step 3: Instrument request assembly in `iris.swift`**

Replace

```swift
        let facts = (try? FactStoreManager.shared.search(query: input, limit: 5)) ?? []
```

with

```swift
        let facts = measureSpanSync("assembly.factSearch") {
            (try? FactStoreManager.shared.search(query: input, limit: 5)) ?? []
        }
```

Replace the two user-profile sanitize lines

```swift
        let structuralSafeUserProfile = PromptInjectionGuard.sanitizeUntrustedInput(userProfile)
        let safeUserProfile = await InjectionGuard.sanitize(structuralSafeUserProfile, contextTag: "user_profile", maxTier: .tier3_canary)
```

with

```swift
        let safeUserProfile = await measureSpan("assembly.userProfile") {
            let structural = PromptInjectionGuard.sanitizeUntrustedInput(userProfile)
            return await InjectionGuard.sanitize(structural, contextTag: "user_profile", maxTier: .tier3_canary)
        }
```

Replace the two AGENTS.md sanitize lines

```swift
                    let structuralSafeAgentsMd = PromptInjectionGuard.sanitizeUntrustedInput(agentsMdContent)
                    let safeAgentsMd = await InjectionGuard.sanitize(structuralSafeAgentsMd, contextTag: "workspace_rules", maxTier: .tier3_canary)
```

with

```swift
                    let safeAgentsMd = await measureSpan("assembly.agentsMd") {
                        let structural = PromptInjectionGuard.sanitizeUntrustedInput(agentsMdContent)
                        return await InjectionGuard.sanitize(structural, contextTag: "workspace_rules", maxTier: .tier3_canary)
                    }
```

- [ ] **Step 4: Record model calls at the seam in `iris.swift`**

Immediately before `var turnFinished = false`, add:

```swift
        var modelRound = 0
```

Replace

```swift
                let requestToSend = activeRequest
                let response = try await measure(.primaryLLM) {
```

with

```swift
                let requestToSend = activeRequest
                let modelCallStart = CFAbsoluteTimeGetCurrent()
                let response = try await measure(.primaryLLM) {
```

and immediately after the closing `}` of that `measure(.primaryLLM)` call (before `await MainActor.run { localState?.updateSubagentStatus(id: conversationId, status: "Executing...") }`), add:

```swift
                PerformanceProfiler.shared.recordModelCall(
                    turnID: PerformanceProfiler.currentTurnID,
                    ModelCallRecord(
                        round: modelRound,
                        model: ConfigManager.shared.getModel(for: modelTier),
                        latencyMs: (CFAbsoluteTimeGetCurrent() - modelCallStart) * 1000.0,
                        promptTokens: response.usageMetadata?.promptTokenCount,
                        outputTokens: response.usageMetadata?.candidatesTokenCount,
                        returnedToolCalls: response.candidates?.first?.content?.parts.contains { $0.functionCall != nil } ?? false))
                modelRound += 1
```

- [ ] **Step 5: Record tool calls in the dispatch closure in `iris.swift`**

Replace

```swift
                                    let cmdStart = Date()
                                    let result = await self.executeFunctionCall(call, conversationId: conversationId, workspacePath: workspacePath, restrictToGoalComplete: restrictToGoalComplete)
                                    if let id = timingId {
                                        let elapsed = Date().timeIntervalSince(cmdStart)
                                        await self.recordCommandDuration(id: id, elapsed: elapsed)
                                    }
```

with

```swift
                                    let cmdStart = Date()
                                    let result = await self.executeFunctionCall(call, conversationId: conversationId, workspacePath: workspacePath, restrictToGoalComplete: restrictToGoalComplete)
                                    let elapsed = Date().timeIntervalSince(cmdStart)
                                    if let id = timingId {
                                        await self.recordCommandDuration(id: id, elapsed: elapsed)
                                    }
                                    // Task-local turn id is inherited by this child task.
                                    PerformanceProfiler.shared.recordToolCall(
                                        turnID: PerformanceProfiler.currentTurnID,
                                        ToolCallRecord(name: call.name, ms: elapsed * 1000.0, ok: !result.hasPrefix("Error")))
```

- [ ] **Step 6: Guard tier spans in `InjectionGuard.swift`**

Replace `let clean = executeTier1(rawInput)` with:

```swift
        let clean = measureSpanSync("guard.tier1") { executeTier1(rawInput) }
```

Replace `let isTier2Safe = await executeTier2CoreML(clean, protectionEnabled: protectionEnabled)` with:

```swift
        let isTier2Safe = await measureSpan("guard.tier2") { await executeTier2CoreML(clean, protectionEnabled: protectionEnabled) }
```

Replace `let isTier3Safe = await executeTier3Canary(clean, protectionEnabled: protectionEnabled)` with:

```swift
        let isTier3Safe = await measureSpan("guard.tier3") { await executeTier3Canary(clean, protectionEnabled: protectionEnabled) }
```

- [ ] **Step 7: Vibecop span in `VibecopService.swift`**

After each of the three lines of the form
`PerformanceProfiler.shared.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: durationMs)`
add:

```swift
                PerformanceProfiler.shared.recordSpan(turnID: PerformanceProfiler.currentTurnID, name: "vibecop", durationMs: durationMs)
```

(indentation to match each site).

- [ ] **Step 8: Run tests**

Run: `swift test 2>&1 | grep -E "error:|✘|Test run with"`
Expected: all suites pass, including the three new tests.

- [ ] **Step 9: Commit**

```bash
git add Sources/iris/iris.swift Sources/iris/InjectionGuard.swift Sources/iris/VibecopService.swift Tests/irisTests/EngineInstrumentationTests.swift
git commit -m "feat(perf): record model rounds, tool calls, guard tiers and assembly spans" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Volatile copy of the user's settings

**Files:**
- Modify: `Sources/iris/IrisDefaults.swift`
- Modify: `Tests/irisTests/IrisDefaultsSweepTests.swift`
- Test: `Tests/irisTests/VolatileDefaultsTests.swift`

**Interfaces:**
- Produces: `IrisDefaults.store` (now computed), `IrisDefaults.isVolatileCopy: Bool`, `IrisDefaults.useVolatileCopyOfStandard()`, `IrisDefaults.makeVolatileCopy(of:suiteName:) -> UserDefaults`, `IrisDefaults.appDomain: String`. The stale sweep also matches `iris-bench-<pid>.plist`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/VolatileDefaultsTests.swift
import Testing
import Foundation
@testable import iris

/// A perf run toggles guards through ConfigManager, whose setters persist. Under --bench/--perf
/// the store is a volatile copy seeded from the user's real domain, so the run sees the real
/// provider configuration but nothing it sets can escape the process.
@Suite("IrisDefaults volatile copy")
struct VolatileDefaultsTests {
    @Test("a copy sees the seed values and its writes stay in the copy")
    func copyIsIsolated() {
        let name = "iris-volatile-test-\(UUID().uuidString)"
        let seed: [String: Any] = ["ENABLE_VIBECOP": true, "PRIMARY_PROVIDER": "Gemini"]
        let copy = IrisDefaults.makeVolatileCopy(of: seed, suiteName: name)
        defer { copy.removePersistentDomain(forName: name) }
        #expect(copy.bool(forKey: "ENABLE_VIBECOP") == true)
        #expect(copy.string(forKey: "PRIMARY_PROVIDER") == "Gemini")
        copy.set(false, forKey: "ENABLE_VIBECOP")
        #expect(copy.bool(forKey: "ENABLE_VIBECOP") == false)
        #expect(UserDefaults.standard.persistentDomain(forName: IrisDefaults.appDomain)?["ENABLE_VIBECOP"] as? Bool != false
                || UserDefaults.standard.persistentDomain(forName: IrisDefaults.appDomain) == nil,
                "the app domain must not be written by a volatile copy")
    }

    @Test("the test process is never a volatile copy")
    func notVolatileUnderTest() {
        #expect(!IrisDefaults.isVolatileCopy)
    }

    @Test("the app domain is the bundle id or the process name")
    func appDomain() {
        #expect(!IrisDefaults.appDomain.isEmpty)
        #expect(IrisDefaults.appDomain == (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName))
    }
}
```

Append to `Tests/irisTests/IrisDefaultsSweepTests.swift`, inside the struct:

```swift
    @Test("bench suites are swept too")
    func benchSuitesAreSwept() throws {
        let dir = try makeDir(["iris-bench-99999.plist", "iris-tests-99998.plist", "iris.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = IrisDefaults.staleTestSuiteFiles(in: dir, isAlive: { _ in false })
        #expect(stale.map(\.lastPathComponent) == ["iris-bench-99999.plist", "iris-tests-99998.plist"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `type 'IrisDefaults' has no member 'makeVolatileCopy'` (and `isVolatileCopy`, `appDomain`).

- [ ] **Step 3: Implement in `IrisDefaults.swift`**

Replace the whole `enum IrisDefaults { ... }` body's `store` declaration and add the new members. The resulting enum:

```swift
enum IrisDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: UserDefaults?
    nonisolated(unsafe) private static var volatileSuiteName: String?

    /// The store everything persists through. A volatile override (set by --bench/--perf before
    /// anything touches `ConfigManager.shared`) wins over the per-process default.
    static var store: UserDefaults {
        lock.withLock { override } ?? processStore
    }

    /// True only under --bench/--perf. Gates every code path that mutates ConfigManager for a run.
    static var isVolatileCopy: Bool { lock.withLock { override != nil } }

    /// The domain the shipping app persists to: the bundle id in a .app, the process name under
    /// `swift run` (which is why the dev plist is `iris.plist`).
    static var appDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    private static let processStore: UserDefaults = {
        // ... the existing initializer body, unchanged, from `guard NSClassFromString` to `return suite` ...
    }()

    /// Seed a throwaway suite from the user's real domain and route the store to it. Must be
    /// called before `ConfigManager.shared` is first touched: `ConfigManager.store` captures
    /// `IrisDefaults.store` once.
    static func useVolatileCopyOfStandard() {
        let seed = UserDefaults.standard.persistentDomain(forName: appDomain) ?? [:]
        let name = "iris-bench-\(ProcessInfo.processInfo.processIdentifier)"
        let copy = makeVolatileCopy(of: seed, suiteName: name)
        lock.withLock { override = copy; volatileSuiteName = name }
        atexit {
            if let n = IrisDefaults.volatileSuiteName {
                UserDefaults(suiteName: n)?.removePersistentDomain(forName: n)
            }
        }
    }

    static func makeVolatileCopy(of seed: [String: Any], suiteName: String) -> UserDefaults {
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName)
        suite.setPersistentDomain(seed, forName: suiteName)
        return suite
    }
```

Keep the existing `staleTestSuiteFiles`, `sweepStaleTestSuites(in:isAlive:)` and private `sweepStaleTestSuites()` members, but change the prefix check in `staleTestSuiteFiles` from

```swift
            guard name.hasPrefix("iris-tests-"), name.hasSuffix(".plist"),
                  let pid = pid_t(name.dropFirst("iris-tests-".count).dropLast(".plist".count)),
```

to

```swift
            guard let prefix = ["iris-tests-", "iris-bench-"].first(where: name.hasPrefix), name.hasSuffix(".plist"),
                  let pid = pid_t(name.dropFirst(prefix.count).dropLast(".plist".count)),
```

Move the existing body of the old `store` closure into `processStore` verbatim (it still calls `sweepStaleTestSuites()`).

- [ ] **Step 4: Run tests**

Run: `swift test --filter "VolatileDefaultsTests|IrisDefaultsSweepTests" 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 7 tests in 2 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/IrisDefaults.swift Tests/irisTests/VolatileDefaultsTests.swift Tests/irisTests/IrisDefaultsSweepTests.swift
git commit -m "feat(perf): volatile copy of the user's defaults for headless runs" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: ScenarioRunner guard mode, client override, final texts

**Files:**
- Create: `Sources/iris/CapturingLLMClient.swift`
- Modify: `Sources/iris/ScenarioRunner.swift`
- Test: `Tests/irisTests/ScenarioRunnerOptionsTests.swift`

**Interfaces:**
- Consumes: `IrisDefaults.isVolatileCopy` (Task 3).
- Produces: `enum GuardMode { case asConfigured, off }`; `ScenarioRunner.run(_:guards:clientOverride:) -> ScenarioResult`; `ScenarioResult.finalTexts: [String]`, `ScenarioResult.guardsWereOff: Bool`; `CapturingLLMClient(reply:)` with `requests: [GeminiRequest]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/ScenarioRunnerOptionsTests.swift
import Testing
import Foundation
@testable import iris

@MainActor
@Suite("ScenarioRunner options")
struct ScenarioRunnerOptionsTests {
    private var textOnly: Scenario {
        Scenario(name: "text", clientMode: .fake,
                 turns: [Scenario.Turn(prompt: "one"), Scenario.Turn(prompt: "two")],
                 scriptedResponses: [
                    Scenario.ScriptedResponse(kind: .text, text: "ack one", calls: nil),
                    Scenario.ScriptedResponse(kind: .text, text: "ack two", calls: nil)
                 ])
    }

    @Test("the final agent text of each turn is returned")
    func finalTexts() async {
        let result = await ScenarioRunner.run(textOnly)
        #expect(result.finalTexts == ["ack one", "ack two"])
    }

    @Test("guards=off is ignored outside a volatile settings copy")
    func guardsOffIsGatedOnVolatileCopy() async {
        let before = (ConfigManager.shared.enableVibecop, ConfigManager.shared.enableAdvancedPromptInjectionProtection)
        let result = await ScenarioRunner.run(textOnly, guards: .off)
        let after = (ConfigManager.shared.enableVibecop, ConfigManager.shared.enableAdvancedPromptInjectionProtection)
        #expect(result.guardsWereOff == false)
        #expect(before == after, "a test process must never see its config mutated")
    }

    @Test("a client override receives exactly what a real turn would send")
    func clientOverrideCapturesRequest() async throws {
        let capture = CapturingLLMClient(reply: "captured")
        let result = await ScenarioRunner.run(textOnly, clientOverride: capture)
        #expect(result.finalTexts == ["captured", "captured"])
        let request = try #require(capture.requests.first)
        #expect(request.systemInstruction?.parts.first?.text?.isEmpty == false)
        #expect((request.tools?.first?.functionDeclarations.count ?? 0) > 10)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `cannot find 'CapturingLLMClient' in scope`, `extra argument 'guards' in call`.

- [ ] **Step 3: Create `CapturingLLMClient.swift`**

```swift
import Foundation

/// Records every request the engine sends and answers each with a fixed text. The perf ladder
/// uses it to obtain the exact system prompt and tool list a real turn would send, without
/// calling a provider.
final class CapturingLLMClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    let reply: String

    init(reply: String = "ok") { self.reply = reply }

    var requests: [GeminiRequest] { lock.withLock { recorded } }

    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        lock.withLock { recorded.append(request) }
        let part = Part(text: reply, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }
}
```

- [ ] **Step 4: Modify `ScenarioRunner.swift`**

Replace `ScenarioResult` with:

```swift
/// Whether a run should switch the model-backed guards off. Only honoured when the settings
/// store is a volatile copy (see `IrisDefaults.isVolatileCopy`); otherwise ignored and logged.
enum GuardMode: Sendable { case asConfigured, off }

/// The timing captured for a headless scenario run.
struct ScenarioResult: Sendable {
    /// One `CommandProfile` per profiler turn (one per `processInput`), newest last.
    var turnProfiles: [CommandProfile]
    /// Wall-clock across all turns.
    var wallClockMs: Double
    /// The last agent message of each turn, in turn order ("" when a turn produced none).
    var finalTexts: [String]
    /// True when guards were actually switched off for this run.
    var guardsWereOff: Bool
}
```

Replace the signature and body of `run` with:

```swift
    static func run(_ scenario: Scenario,
                    guards: GuardMode = .asConfigured,
                    clientOverride: (any LLMClientProtocol)? = nil) async -> ScenarioResult {
        let state = AppState()
        state.autoApproveTools = true // non-interactive: never block on an approval prompt
        let conversationId = UUID()
        state.createNewConversation(id: conversationId)

        let client: any LLMClientProtocol
        if let clientOverride {
            client = clientOverride
        } else {
            switch scenario.clientMode {
            case .fake:
                let responses = scenario.scriptedResponses.map { $0.asGeminiResponse() }
                client = FakeLLMClient(responses: responses,
                                       latency: scenario.latencyMs ?? .init(minMs: 0, maxMs: 0))
            case .real:
                client = LLMClient()
            }
        }

        // Guard toggling writes through ConfigManager, whose setters persist. Only a volatile
        // copy of the store may be written to, so outside one this is a logged no-op.
        let config = ConfigManager.shared
        let savedVibecop = config.enableVibecop
        let savedGuard = config.enableAdvancedPromptInjectionProtection
        var guardsOff = false
        if guards == .off {
            if IrisDefaults.isVolatileCopy {
                config.enableVibecop = false
                config.enableAdvancedPromptInjectionProtection = false
                guardsOff = true
            } else {
                print("[ScenarioRunner] guards=off ignored: settings store is not a volatile copy")
            }
        }
        defer {
            if guardsOff {
                config.enableVibecop = savedVibecop
                config.enableAdvancedPromptInjectionProtection = savedGuard
            }
        }

        let engine = IrisEngine(state: state, tier: scenario.tier, client: client)

        // Collect this run's finished turn profiles via a task-local sink scoped to the turn loop.
        let collector = TurnCollector()
        var finalTexts: [String] = []
        let start = CFAbsoluteTimeGetCurrent()
        await PerformanceProfiler.$runSink.withValue({ collector.append($0) }) {
            for turn in scenario.turns {
                await engine.processInput(turn.prompt, source: turn.source, conversationId: conversationId)
                let last = state.conversations.first { $0.id == conversationId }?
                    .messages.last { $0.role == .agent }?.content ?? ""
                finalTexts.append(last)
            }
        }
        let wallClockMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        return ScenarioResult(turnProfiles: collector.all, wallClockMs: wallClockMs,
                              finalTexts: finalTexts, guardsWereOff: guardsOff)
    }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "ScenarioRunnerOptionsTests|ProfilingHarnessTests" 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 5 tests in 2 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/CapturingLLMClient.swift Sources/iris/ScenarioRunner.swift Tests/irisTests/ScenarioRunnerOptionsTests.swift
git commit -m "feat(perf): ScenarioRunner guard mode, client override and final texts" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: PerfStats

**Files:**
- Create: `Sources/iris/PerfStats.swift`
- Test: `Tests/irisTests/PerfStatsTests.swift`

**Interfaces:**
- Produces: `PerfStats.median([Double]) -> Double?`, `PerfStats.percentile([Double], Double) -> Double?` (nearest rank), `PerfStats.p90([Double]) -> Double?`, `PerfStats.percentChange(from:to:) -> Double?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/PerfStatsTests.swift
import Testing
@testable import iris

@Suite("PerfStats")
struct PerfStatsTests {
    @Test("median of empty is nil, of one is itself, of two is the mean")
    func medianSmall() {
        #expect(PerfStats.median([]) == nil)
        #expect(PerfStats.median([5]) == 5)
        #expect(PerfStats.median([1, 3]) == 2)
    }

    @Test("median handles odd and even lengths and unsorted input")
    func medianGeneral() {
        #expect(PerfStats.median([3, 1, 2]) == 2)
        #expect(PerfStats.median([4, 1, 3, 2]) == 2.5)
    }

    @Test("p90 is nearest-rank")
    func p90() {
        #expect(PerfStats.p90([]) == nil)
        #expect(PerfStats.p90([7]) == 7)
        #expect(PerfStats.p90([1, 2]) == 2)
        #expect(PerfStats.p90((1...10).map(Double.init)) == 9)
        #expect(PerfStats.p90((1...100).map(Double.init)) == 90)
    }

    @Test("percent change is relative to the baseline and nil for a zero baseline")
    func percentChange() {
        #expect(PerfStats.percentChange(from: 100, to: 120) == 0.2)
        #expect(PerfStats.percentChange(from: 100, to: 80) == -0.2)
        #expect(PerfStats.percentChange(from: 0, to: 5) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `cannot find 'PerfStats' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/iris/PerfStats.swift
import Foundation

/// Small, exact statistics for perf records. Behaviour for n = 1 and n = 2 is pinned by tests
/// so reports are unambiguous.
enum PerfStats {
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Nearest-rank percentile: the value at rank ceil(p * n), 1-based.
    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[max(0, min(s.count - 1, rank - 1))]
    }

    static func p90(_ xs: [Double]) -> Double? { percentile(xs, 0.90) }

    /// (to - from) / from; nil when the baseline is zero.
    static func percentChange(from a: Double, to b: Double) -> Double? {
        guard a != 0 else { return nil }
        return (b - a) / a
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PerfStatsTests 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PerfStats.swift Tests/irisTests/PerfStatsTests.swift
git commit -m "feat(perf): PerfStats median, p90 and percent change" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Run record types and suite file

**Files:**
- Create: `Sources/iris/PerfRecord.swift`
- Create: `Sources/iris/PerfSuite.swift`
- Test: `Tests/irisTests/PerfRecordTests.swift`, `Tests/irisTests/PerfSuiteTests.swift`

**Interfaces:**
- Produces the types below verbatim. Later tasks construct them with these member names.

```swift
struct PerfRunRecord: Codable { schemaVersion, suite, startedAt, finishedAt, environment, scenarios }
struct PerfEnvironment: Codable { gitSha, gitDirty, machineModel, osVersion, cpuCount, buildConfiguration, provider, models, vibecopEnabled, vibecopEngine, injectionGuardEnabled, promptGuardEngine, sandboxEnabled, headless, toolDeclarationCount: Int? }
struct PerfScenarioResult: Codable { name, path, category, lane, rungs: [PerfRungResult], summary }
struct PerfRungResult: Codable { rung, repetitions: [PerfRepetition], medianMs, p90Ms }
struct PerfRepetition: Codable { index, coldStart, wallClockMs, turns: [PerfTurn], modelCalls: [ModelCallRecord], error: String? }
struct PerfTurn: Codable { totalMs, categories: [String: CategoryStat], spans, modelCalls, toolCalls, finalTextLength }
struct PerfScenarioSummary: Codable { medianMs, p90Ms, overheadRatio: Double?, harnessRatio: Double?, toolCallRate, toolCallsByName: [String: Int] }
PerfRunRecord.decode(from:), .load(at:), .encoded() -> Data, .write(toDirectory:) -> URL, .fileName: String
PerfTurn.init(_ profile: CommandProfile)
struct PerfSuite: Codable { name, lane: Lane, repetitions, pauseMs, rungs, scenarios }  // Lane: fake | real
PerfSuite.decode(from:), .load(at:), .validate(), .scenarioURLs(relativeTo:)
enum PerfSuiteError: Error, Equatable { emptyScenarios, invalidRung(Int), fakeLaneNeedsFullTurn([Int]), invalidRepetitions(Int) }
enum PerfPaths { static func repoRoot(from: URL = cwd) -> URL }
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/PerfRecordTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfRunRecord")
struct PerfRecordTests {
    static func sampleRecord() -> PerfRunRecord {
        let env = PerfEnvironment(gitSha: "abc1234", gitDirty: false, machineModel: "Mac16,7", osVersion: "26.0",
                                  cpuCount: 12, buildConfiguration: "release", provider: "Gemini",
                                  models: ["medium": "gemini-3.8-flash"], vibecopEnabled: true, vibecopEngine: "cloud",
                                  injectionGuardEnabled: true, promptGuardEngine: "cloud", sandboxEnabled: true,
                                  headless: false, toolDeclarationCount: 14)
        let call = ModelCallRecord(round: 0, model: "gemini-3.8-flash", latencyMs: 800, promptTokens: 3000, outputTokens: 40, returnedToolCalls: false)
        let turn = PerfTurn(totalMs: 850, categories: ["primaryLLM": CategoryStat(ms: 800, count: 1)], spans: ["guard.tier1": CategoryStat(ms: 1, count: 2)],
                            modelCalls: [call], toolCalls: [], finalTextLength: 120)
        let rep = PerfRepetition(index: 0, coldStart: true, wallClockMs: 860, turns: [turn], modelCalls: [], error: nil)
        let rung = PerfRungResult(rung: 5, repetitions: [rep], medianMs: 860, p90Ms: 860)
        let summary = PerfScenarioSummary(medianMs: 860, p90Ms: 860, overheadRatio: nil, harnessRatio: nil, toolCallRate: 0, toolCallsByName: [:])
        let scenario = PerfScenarioResult(name: "capital-city", path: "perf/prompts/model-only/capital-city.json", category: "model-only",
                                          lane: "real", rungs: [rung], summary: summary)
        return PerfRunRecord(schemaVersion: 1, suite: "ladder", startedAt: Date(timeIntervalSince1970: 1_000), finishedAt: Date(timeIntervalSince1970: 1_060),
                             environment: env, scenarios: [scenario])
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let record = Self.sampleRecord()
        let decoded = try PerfRunRecord.decode(from: record.encoded())
        #expect(decoded.suite == "ladder")
        #expect(decoded.scenarios.first?.rungs.first?.repetitions.first?.turns.first?.modelCalls.first?.promptTokens == 3000)
        #expect(decoded.environment.toolDeclarationCount == 14)
        #expect(decoded.startedAt == record.startedAt)
    }

    @Test("a record missing optional fields still decodes")
    func tolerantDecode() throws {
        let json = """
        {"schemaVersion":1,"suite":"s","startedAt":"2026-09-17T10:00:00Z","finishedAt":"2026-09-17T10:01:00Z",
         "environment":{"gitSha":"x","gitDirty":false,"machineModel":"m","osVersion":"o","cpuCount":1,"buildConfiguration":"debug",
           "provider":"Gemini","models":{},"vibecopEnabled":false,"vibecopEngine":"cloud","injectionGuardEnabled":false,
           "promptGuardEngine":"cloud","sandboxEnabled":false,"headless":true},
         "scenarios":[{"name":"n","path":"p","category":"c","lane":"fake","rungs":[],
           "summary":{"medianMs":0,"p90Ms":0,"toolCallRate":0,"toolCallsByName":{}}}]}
        """
        let record = try PerfRunRecord.decode(from: Data(json.utf8))
        #expect(record.environment.toolDeclarationCount == nil)
        #expect(record.scenarios.first?.summary.overheadRatio == nil)
    }

    @Test("file name is timestamp, suite and sha")
    func fileName() {
        #expect(Self.sampleRecord().fileName == "19700101T001640Z-ladder-abc1234.json")
    }

    @Test("write creates the directory and the file")
    func writeCreatesFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)/runs")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let url = try Self.sampleRecord().write(toDirectory: dir)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try PerfRunRecord.load(at: url.path).suite == "ladder")
    }

    @Test("PerfTurn is built from a CommandProfile")
    func fromProfile() {
        var profile = CommandProfile(id: UUID(), label: "l", source: "s", startedAt: Date())
        profile.totalMs = 12
        profile.add(.primaryLLM, durationMs: 10)
        profile.addSpan("guard.tier1", durationMs: 1)
        profile.toolCalls.append(ToolCallRecord(name: "read_file", ms: 2, ok: true))
        let turn = PerfTurn(profile, finalTextLength: 5)
        #expect(turn.totalMs == 12)
        #expect(turn.categories["primaryLLM"]?.ms == 10)
        #expect(turn.spans["guard.tier1"]?.count == 1)
        #expect(turn.toolCalls.first?.name == "read_file")
        #expect(turn.finalTextLength == 5)
    }
}
```

```swift
// Tests/irisTests/PerfSuiteTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfSuite")
struct PerfSuiteTests {
    @Test("defaults: fake lane, 3 repetitions, no pause, rung 5 only")
    func defaults() throws {
        let suite = try PerfSuite.decode(from: Data(#"{"name":"s","scenarios":["scenarios/echo-latency.json"]}"#.utf8))
        #expect(suite.lane == .fake)
        #expect(suite.repetitions == 3)
        #expect(suite.pauseMs == 0)
        #expect(suite.rungs == [5])
    }

    @Test("fake lane rejects rungs that would time a sleep")
    func fakeLaneRejectsLadderRungs() {
        let json = #"{"name":"s","lane":"fake","rungs":[1,5],"scenarios":["a.json"]}"#
        #expect(throws: PerfSuiteError.fakeLaneNeedsFullTurn([1])) { try PerfSuite.decode(from: Data(json.utf8)) }
    }

    @Test("rungs outside 1...5, empty scenarios and zero repetitions are rejected")
    func validation() {
        #expect(throws: PerfSuiteError.invalidRung(7)) {
            try PerfSuite.decode(from: Data(#"{"name":"s","lane":"real","rungs":[7],"scenarios":["a.json"]}"#.utf8))
        }
        #expect(throws: PerfSuiteError.emptyScenarios) {
            try PerfSuite.decode(from: Data(#"{"name":"s","scenarios":[]}"#.utf8))
        }
        #expect(throws: PerfSuiteError.invalidRepetitions(0)) {
            try PerfSuite.decode(from: Data(#"{"name":"s","repetitions":0,"scenarios":["a.json"]}"#.utf8))
        }
    }

    @Test("scenario paths resolve against the repo root")
    func resolvesPaths() throws {
        let suite = try PerfSuite.decode(from: Data(#"{"name":"s","scenarios":["scenarios/echo-latency.json"]}"#.utf8))
        let root = PerfPaths.repoRoot()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
        #expect(suite.scenarioURLs(relativeTo: root).first?.path == root.appendingPathComponent("scenarios/echo-latency.json").path)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -3`
Expected: `cannot find 'PerfRunRecord' in scope`, `cannot find 'PerfSuite' in scope`.

- [ ] **Step 3: Create `PerfRecord.swift`**

```swift
import Foundation

/// One perf suite run, persisted as JSON under perf/runs/ (and perf/baselines/ when promoted).
/// Every field added after schemaVersion 1 must be Optional so old records keep decoding.
struct PerfRunRecord: Codable {
    var schemaVersion: Int
    var suite: String
    var startedAt: Date
    var finishedAt: Date
    var environment: PerfEnvironment
    var scenarios: [PerfScenarioResult]

    static let currentSchemaVersion = 1

    private static let coder: (JSONEncoder, JSONDecoder) = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (e, d)
    }()

    static func decode(from data: Data) throws -> PerfRunRecord {
        try coder.1.decode(PerfRunRecord.self, from: data)
    }

    static func load(at path: String) throws -> PerfRunRecord {
        try decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func encoded() throws -> Data { try Self.coder.0.encode(self) }

    /// `<yyyyMMdd'T'HHmmss'Z'>-<suite>-<sha>.json`, sortable by time.
    var fileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(f.string(from: startedAt))-\(suite)-\(environment.gitSha).json"
    }

    @discardableResult
    func write(toDirectory dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try encoded().write(to: url, options: .atomic)
        return url
    }
}

struct PerfEnvironment: Codable {
    var gitSha: String
    var gitDirty: Bool
    var machineModel: String
    var osVersion: String
    var cpuCount: Int
    var buildConfiguration: String
    var provider: String
    var models: [String: String]
    var vibecopEnabled: Bool
    var vibecopEngine: String
    var injectionGuardEnabled: Bool
    var promptGuardEngine: String
    var sandboxEnabled: Bool
    var headless: Bool
    var toolDeclarationCount: Int?
}

struct PerfScenarioResult: Codable {
    var name: String
    var path: String
    var category: String
    var lane: String
    var rungs: [PerfRungResult]
    var summary: PerfScenarioSummary
}

struct PerfRungResult: Codable {
    var rung: Int
    var repetitions: [PerfRepetition]
    var medianMs: Double
    var p90Ms: Double
}

struct PerfRepetition: Codable {
    var index: Int
    var coldStart: Bool
    var wallClockMs: Double
    var turns: [PerfTurn]
    var modelCalls: [ModelCallRecord]
    var error: String?
}

struct PerfTurn: Codable {
    var totalMs: Double
    var categories: [String: CategoryStat]
    var spans: [String: CategoryStat]
    var modelCalls: [ModelCallRecord]
    var toolCalls: [ToolCallRecord]
    var finalTextLength: Int

    init(totalMs: Double, categories: [String: CategoryStat], spans: [String: CategoryStat],
         modelCalls: [ModelCallRecord], toolCalls: [ToolCallRecord], finalTextLength: Int) {
        self.totalMs = totalMs; self.categories = categories; self.spans = spans
        self.modelCalls = modelCalls; self.toolCalls = toolCalls; self.finalTextLength = finalTextLength
    }

    init(_ profile: CommandProfile, finalTextLength: Int) {
        self.init(totalMs: profile.totalMs,
                  categories: Dictionary(uniqueKeysWithValues: profile.categories.map { ($0.key.rawValue, $0.value) }),
                  spans: profile.spans, modelCalls: profile.modelCalls, toolCalls: profile.toolCalls,
                  finalTextLength: finalTextLength)
    }
}

struct PerfScenarioSummary: Codable {
    var medianMs: Double
    var p90Ms: Double
    var overheadRatio: Double?
    var harnessRatio: Double?
    var toolCallRate: Double
    var toolCallsByName: [String: Int]
}
```

`CategoryStat` needs a memberwise initializer with both fields: add to `PerformanceProfiler.swift` inside `CategoryStat`:

```swift
    public init(ms: Double = 0, count: Int = 0) { self.ms = ms; self.count = count }
```

- [ ] **Step 4: Create `PerfSuite.swift`**

```swift
import Foundation

enum PerfSuiteError: Error, Equatable, LocalizedError {
    case emptyScenarios
    case invalidRung(Int)
    case fakeLaneNeedsFullTurn([Int])
    case invalidRepetitions(Int)

    var errorDescription: String? {
        switch self {
        case .emptyScenarios: return "suite lists no scenarios"
        case .invalidRung(let r): return "rung \(r) is outside 1...5"
        case .fakeLaneNeedsFullTurn(let rs): return "fake lane cannot run rungs \(rs); only 4 and 5 are meaningful without a provider"
        case .invalidRepetitions(let n): return "repetitions must be >= 1, got \(n)"
        }
    }
}

/// A perf suite: which scenarios to run, in which lane, how many times, at which ladder rungs.
struct PerfSuite: Codable, Sendable {
    enum Lane: String, Codable, Sendable { case fake, real }

    var name: String
    var lane: Lane
    var repetitions: Int
    var pauseMs: Int
    var rungs: [Int]
    var scenarios: [String]

    init(name: String, lane: Lane = .fake, repetitions: Int = 3, pauseMs: Int = 0, rungs: [Int] = [5], scenarios: [String]) {
        self.name = name; self.lane = lane; self.repetitions = repetitions
        self.pauseMs = pauseMs; self.rungs = rungs; self.scenarios = scenarios
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        lane = try c.decodeIfPresent(Lane.self, forKey: .lane) ?? .fake
        repetitions = try c.decodeIfPresent(Int.self, forKey: .repetitions) ?? 3
        pauseMs = try c.decodeIfPresent(Int.self, forKey: .pauseMs) ?? 0
        rungs = try c.decodeIfPresent([Int].self, forKey: .rungs) ?? [5]
        scenarios = try c.decodeIfPresent([String].self, forKey: .scenarios) ?? []
    }

    func validate() throws {
        if scenarios.isEmpty { throw PerfSuiteError.emptyScenarios }
        if repetitions < 1 { throw PerfSuiteError.invalidRepetitions(repetitions) }
        if let bad = rungs.first(where: { !(1...5).contains($0) }) { throw PerfSuiteError.invalidRung(bad) }
        let ladderOnly = rungs.filter { $0 < 4 }
        if lane == .fake, !ladderOnly.isEmpty { throw PerfSuiteError.fakeLaneNeedsFullTurn(ladderOnly) }
    }

    static func decode(from data: Data) throws -> PerfSuite {
        let suite = try JSONDecoder().decode(PerfSuite.self, from: data)
        try suite.validate()
        return suite
    }

    static func load(at path: String) throws -> PerfSuite {
        try decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func scenarioURLs(relativeTo root: URL) -> [URL] {
        scenarios.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0) }
    }
}

enum PerfPaths {
    /// Walk up from `start` to the first directory holding Package.swift; falls back to `start`.
    static func repoRoot(from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL {
        var dir = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return start }
            dir = parent
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "PerfRecordTests|PerfSuiteTests" 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 9 tests in 2 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/PerfRecord.swift Sources/iris/PerfSuite.swift Sources/iris/PerformanceProfiler.swift Tests/irisTests/PerfRecordTests.swift Tests/irisTests/PerfSuiteTests.swift
git commit -m "feat(perf): run record types and suite file" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Environment capture

**Files:**
- Create: `Sources/iris/PerfEnvironment+Capture.swift`
- Test: `Tests/irisTests/PerfEnvironmentTests.swift`

**Interfaces:**
- Consumes: `PerfEnvironment` (Task 6), `PerfPaths.repoRoot()`.
- Produces: `PerfEnvironment.capture(headless:toolDeclarationCount:repoRoot:) -> PerfEnvironment` (`@MainActor`), `PerfEnvironment.git(_:in:) -> String?`, `PerfEnvironment.machineModel() -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/PerfEnvironmentTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfEnvironment capture")
struct PerfEnvironmentTests {
    @Test("git sha comes from the repo")
    func gitSha() {
        let sha = PerfEnvironment.git(["rev-parse", "--short", "HEAD"], in: PerfPaths.repoRoot())
        #expect((sha?.count ?? 0) >= 7)
        #expect(sha?.allSatisfy(\.isHexDigit) == true)
    }

    @Test("machine model is non-empty")
    func machine() {
        #expect(!PerfEnvironment.machineModel().isEmpty)
    }

    @MainActor
    @Test("capture reflects the running configuration without mutating it")
    func capture() {
        let env = PerfEnvironment.capture(headless: true, toolDeclarationCount: 3, repoRoot: PerfPaths.repoRoot())
        #expect(env.provider == ConfigManager.shared.primaryProvider)
        #expect(env.models["medium"] == ConfigManager.shared.getModel(for: .medium))
        #expect(env.headless == true)
        #expect(env.toolDeclarationCount == 3)
        #expect(env.cpuCount == ProcessInfo.processInfo.activeProcessorCount)
        #expect(["debug", "release"].contains(env.buildConfiguration))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `type 'PerfEnvironment' has no member 'git'`.

- [ ] **Step 3: Implement**

```swift
// Sources/iris/PerfEnvironment+Capture.swift
import Foundation

extension PerfEnvironment {
    @MainActor
    static func capture(headless: Bool, toolDeclarationCount: Int?, repoRoot: URL) -> PerfEnvironment {
        let config = ConfigManager.shared
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return PerfEnvironment(
            gitSha: git(["rev-parse", "--short", "HEAD"], in: repoRoot) ?? "unknown",
            gitDirty: !(git(["status", "--porcelain"], in: repoRoot) ?? "").isEmpty,
            machineModel: machineModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            buildConfiguration: build,
            provider: config.primaryProvider,
            models: Dictionary(uniqueKeysWithValues: ModelTier.allCases.map { ($0.rawValue, config.getModel(for: $0)) }),
            vibecopEnabled: config.enableVibecop,
            vibecopEngine: config.vibecopEngine,
            injectionGuardEnabled: config.enableAdvancedPromptInjectionProtection,
            promptGuardEngine: config.promptGuardEngine,
            sandboxEnabled: config.enableSandboxing,
            headless: headless,
            toolDeclarationCount: toolDeclarationCount)
    }

    /// Run git in `root` and return trimmed stdout; nil if git is missing or exits non-zero.
    static func git(_ args: [String], in root: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
```

`ModelTier` (in `Sources/iris/Models.swift:3`) is `enum ModelTier: String, Codable`; add `CaseIterable` to that declaration so `ModelTier.allCases` compiles.

- [ ] **Step 4: Run tests**

Run: `swift test --filter PerfEnvironmentTests 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 3 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PerfEnvironment+Capture.swift Tests/irisTests/PerfEnvironmentTests.swift Sources/iris/Models.swift
git commit -m "feat(perf): capture git, machine and configuration into the run record" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Ladder rungs 1 to 3

**Files:**
- Create: `Sources/iris/PerfLadder.swift`
- Test: `Tests/irisTests/PerfLadderTests.swift`

**Interfaces:**
- Consumes: `CapturingLLMClient`, `ScenarioRunner.run(_:guards:clientOverride:)` (Task 4), `ModelCallRecord` (Task 1).
- Produces:

```swift
struct LadderCapture: Sendable { let systemInstruction: Content?; let tools: [Tool]?; var toolCount: Int }
struct LadderSample: Sendable { let wallClockMs: Double; let modelCall: ModelCallRecord?; let error: String? }
enum PerfLadder {
    @MainActor static func capture(for scenario: Scenario) async -> LadderCapture
    static func request(rung: Int, prompt: String, capture: LadderCapture) -> GeminiRequest
    static func sample(rung: Int, prompt: String, tier: ModelTier, capture: LadderCapture, client: any LLMClientProtocol) async -> LadderSample
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/PerfLadderTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfLadder rungs 1-3")
struct PerfLadderTests {
    private let sys = Content(role: "system", parts: [Part(text: "You are Iris.", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
    private var capture: LadderCapture {
        LadderCapture(systemInstruction: sys,
                      tools: [Tool(functionDeclarations: [FunctionDeclaration(name: "read_file", description: "d", parameters: Schema(type: "OBJECT", properties: [:], required: []))])],
                      toolCount: 1)
    }

    @Test("rung 1 sends the prompt alone")
    func rung1() {
        let r = PerfLadder.request(rung: 1, prompt: "hi", capture: capture)
        #expect(r.systemInstruction == nil)
        #expect(r.tools == nil)
        #expect(r.contents.first?.parts.first?.text == "hi")
    }

    @Test("rung 2 adds the system prompt, rung 3 adds the tools")
    func rung2and3() {
        #expect(PerfLadder.request(rung: 2, prompt: "hi", capture: capture).systemInstruction?.parts.first?.text == "You are Iris.")
        #expect(PerfLadder.request(rung: 2, prompt: "hi", capture: capture).tools == nil)
        #expect(PerfLadder.request(rung: 3, prompt: "hi", capture: capture).tools?.first?.functionDeclarations.count == 1)
    }

    @Test("a sample records latency and tokens from the reply")
    func sampleRecordsCall() async {
        let usage = UsageMetadata(promptTokenCount: 12, candidatesTokenCount: 3, totalTokenCount: 15)
        let reply = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: usage)
        let client = FakeLLMClient(responses: [reply])
        let s = await PerfLadder.sample(rung: 1, prompt: "hi", tier: .medium, capture: capture, client: client)
        #expect(s.error == nil)
        #expect(s.modelCall?.promptTokens == 12)
        #expect(s.modelCall?.outputTokens == 3)
        #expect(s.wallClockMs >= 0)
    }

    @Test("a failing call is a recorded error, not a crash")
    func sampleRecordsError() async {
        struct Failing: LLMClientProtocol {
            func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
                throw APIError(message: "boom")
            }
        }
        let s = await PerfLadder.sample(rung: 2, prompt: "hi", tier: .medium, capture: capture, client: Failing())
        #expect(s.error == "boom")
        #expect(s.modelCall == nil)
    }

    @MainActor
    @Test("capture assembles what a real turn would send, without a provider")
    func captureFromEngine() async {
        let scenario = Scenario(name: "cap", clientMode: .real, turns: [Scenario.Turn(prompt: "hello")])
        let c = await PerfLadder.capture(for: scenario)
        #expect(c.systemInstruction?.parts.first?.text?.isEmpty == false)
        #expect(c.toolCount > 10)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `cannot find 'PerfLadder' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/iris/PerfLadder.swift
import Foundation

/// What a real turn sends besides the prompt, captured once per scenario.
struct LadderCapture: Sendable {
    let systemInstruction: Content?
    let tools: [Tool]?
    var toolCount: Int
}

/// One timed ladder call.
struct LadderSample: Sendable {
    let wallClockMs: Double
    let modelCall: ModelCallRecord?
    let error: String?
}

/// Rungs 1 to 3 of the overhead ladder: direct provider calls with progressively more of what
/// Iris adds. Rungs 4 and 5 are ordinary `ScenarioRunner` turns and live in `PerfRunner`.
enum PerfLadder {
    /// Run one engine turn against a capturing client with guards off, and keep the request it
    /// built. This is exactly the system prompt and tool list a real turn sends.
    @MainActor
    static func capture(for scenario: Scenario) async -> LadderCapture {
        let client = CapturingLLMClient(reply: "ok")
        var one = scenario
        one.turns = Array(scenario.turns.prefix(1))
        _ = await ScenarioRunner.run(one, guards: .off, clientOverride: client)
        let request = client.requests.first
        let count = request?.tools?.reduce(0) { $0 + $1.functionDeclarations.count } ?? 0
        return LadderCapture(systemInstruction: request?.systemInstruction, tools: request?.tools, toolCount: count)
    }

    static func request(rung: Int, prompt: String, capture: LadderCapture) -> GeminiRequest {
        let user = Content(role: "user", parts: [Part(text: prompt, functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)])
        switch rung {
        case 1: return GeminiRequest(contents: [user], systemInstruction: nil, tools: nil)
        case 2: return GeminiRequest(contents: [user], systemInstruction: capture.systemInstruction, tools: nil)
        default: return GeminiRequest(contents: [user], systemInstruction: capture.systemInstruction, tools: capture.tools)
        }
    }

    static func sample(rung: Int, prompt: String, tier: ModelTier, capture: LadderCapture,
                       client: any LLMClientProtocol) async -> LadderSample {
        let req = request(rung: rung, prompt: prompt, capture: capture)
        let model = await MainActor.run { ConfigManager.shared.getModel(for: tier) }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let response = try await client.generateContent(request: req, tier: tier)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let call = ModelCallRecord(round: 0, model: model, latencyMs: ms,
                                       promptTokens: response.usageMetadata?.promptTokenCount,
                                       outputTokens: response.usageMetadata?.candidatesTokenCount,
                                       returnedToolCalls: response.candidates?.first?.content?.parts.contains { $0.functionCall != nil } ?? false)
            return LadderSample(wallClockMs: ms, modelCall: call, error: nil)
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return LadderSample(wallClockMs: ms, modelCall: nil, error: LLMErrorMessage.display(for: error).headline)
        }
    }
}
```

If `Content` or `Tool` is not `Sendable`, mark `LadderCapture` as `@unchecked Sendable` rather than changing model types.

- [ ] **Step 4: Run tests**

Run: `swift test --filter PerfLadderTests 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PerfLadder.swift Tests/irisTests/PerfLadderTests.swift
git commit -m "feat(perf): ladder rungs 1-3 from a captured real request" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: PerfRunner and summaries

**Files:**
- Create: `Sources/iris/PerfRunner.swift`
- Create: `perf/prompts/fake/text-only.json`, `perf/prompts/fake/one-command.json`
- Test: `Tests/irisTests/PerfRunnerTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:

```swift
@MainActor enum PerfRunner {
    static func run(suite: PerfSuite, repetitionsOverride: Int? = nil, repoRoot: URL,
                    client: (any LLMClientProtocol)? = nil, headless: Bool) async throws -> PerfRunRecord
    static func category(forScenarioAt url: URL) -> String
}
enum PerfSummarizer { static func summarize(_ rungs: [PerfRungResult]) -> PerfScenarioSummary }
```

- [ ] **Step 1: Create the fake prompt files**

`perf/prompts/fake/text-only.json`:

```json
{
  "name": "fake-text-only",
  "clientMode": "fake",
  "turns": [ { "prompt": "What is the capital of Australia?" } ],
  "scriptedResponses": [ { "kind": "text", "text": "Canberra." } ]
}
```

`perf/prompts/fake/one-command.json`:

```json
{
  "name": "fake-one-command",
  "clientMode": "fake",
  "turns": [ { "prompt": "Run uname and tell me the OS." } ],
  "scriptedResponses": [
    { "kind": "toolCalls", "calls": [ { "name": "run_command", "args": { "command": "uname -s" } } ] },
    { "kind": "text", "text": "Darwin." }
  ]
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/irisTests/PerfRunnerTests.swift
import Testing
import Foundation
@testable import iris

@MainActor
@Suite("PerfRunner")
struct PerfRunnerTests {
    private let root = PerfPaths.repoRoot()

    @Test("a fake suite yields one scenario result per scenario with turns, tool calls and nil tokens")
    func fakeSuite() async throws {
        let suite = PerfSuite(name: "smoke-test", lane: .fake, repetitions: 2, rungs: [5],
                              scenarios: ["perf/prompts/fake/text-only.json", "perf/prompts/fake/one-command.json"])
        let record = try await PerfRunner.run(suite: suite, repoRoot: root, headless: true)
        #expect(record.suite == "smoke-test")
        #expect(record.scenarios.map(\.name) == ["fake-text-only", "fake-one-command"])
        #expect(record.scenarios.map(\.category) == ["fake", "fake"])
        let cmd = try #require(record.scenarios.last)
        #expect(cmd.rungs.first?.repetitions.count == 2)
        #expect(cmd.rungs.first?.repetitions.first?.coldStart == true)
        #expect(cmd.rungs.first?.repetitions.last?.coldStart == false)
        #expect(cmd.summary.toolCallsByName["run_command"] == 2)
        #expect(cmd.summary.toolCallRate == 1.0)
        #expect(cmd.rungs.first?.repetitions.first?.turns.first?.modelCalls.allSatisfy { $0.promptTokens == nil } == true)
        #expect(record.environment.headless == true)
    }

    @Test("a real-lane suite with an injected client runs the ladder rungs and computes ratios")
    func ladderWithInjectedClient() async throws {
        let usage = UsageMetadata(promptTokenCount: 10, candidatesTokenCount: 2, totalTokenCount: 12)
        let text = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "Canberra.", functionCall: nil, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: usage)
        let client = FakeLLMClient(responses: [text])
        let suite = PerfSuite(name: "ladder-test", lane: .real, repetitions: 1, rungs: [1, 2, 3, 4, 5],
                              scenarios: ["perf/prompts/fake/text-only.json"])
        let record = try await PerfRunner.run(suite: suite, repoRoot: root, client: client, headless: false)
        let s = try #require(record.scenarios.first)
        #expect(s.rungs.map(\.rung) == [1, 2, 3, 4, 5])
        #expect(s.rungs[0].repetitions.first?.modelCalls.first?.promptTokens == 10)
        #expect(s.rungs[4].repetitions.first?.turns.count == 1)
        #expect(s.summary.overheadRatio != nil)
        #expect(s.summary.harnessRatio != nil)
        #expect((record.environment.toolDeclarationCount ?? 0) > 10)
    }

    @Test("repetitions override wins over the suite file")
    func repetitionsOverride() async throws {
        let suite = PerfSuite(name: "o", lane: .fake, repetitions: 5, scenarios: ["perf/prompts/fake/text-only.json"])
        let record = try await PerfRunner.run(suite: suite, repetitionsOverride: 1, repoRoot: root, headless: true)
        #expect(record.scenarios.first?.rungs.first?.repetitions.count == 1)
    }

    @Test("a missing scenario file is a thrown error")
    func missingScenario() async {
        let suite = PerfSuite(name: "m", scenarios: ["perf/prompts/fake/does-not-exist.json"])
        await #expect(throws: (any Error).self) { try await PerfRunner.run(suite: suite, repoRoot: root, headless: true) }
    }
}

@Suite("PerfSummarizer")
struct PerfSummarizerTests {
    private func rung(_ n: Int, _ ms: [Double], tools: [[String]] = []) -> PerfRungResult {
        let reps = ms.enumerated().map { i, v in
            let turn = PerfTurn(totalMs: v, categories: [:], spans: [:], modelCalls: [],
                                toolCalls: (i < tools.count ? tools[i] : []).map { ToolCallRecord(name: $0, ms: 1, ok: true) },
                                finalTextLength: 0)
            return PerfRepetition(index: i, coldStart: i == 0, wallClockMs: v, turns: n >= 4 ? [turn] : [],
                                  modelCalls: n < 4 ? [ModelCallRecord(round: 0, model: "m", latencyMs: v, promptTokens: nil, outputTokens: nil, returnedToolCalls: false)] : [],
                                  error: nil)
        }
        return PerfRungResult(rung: n, repetitions: reps, medianMs: PerfStats.median(ms) ?? 0, p90Ms: PerfStats.p90(ms) ?? 0)
    }

    @Test("ratios divide rung 5 and rung 4 medians by the rung 1 median")
    func ratios() {
        let s = PerfSummarizer.summarize([rung(1, [100, 110, 120]), rung(4, [200, 220, 240]), rung(5, [300, 330, 360])])
        #expect(s.overheadRatio == 3.0)
        #expect(s.harnessRatio == 2.0)
        #expect(s.medianMs == 330)
    }

    @Test("without rung 1 the ratios are nil and the summary uses the highest rung")
    func noDenominator() {
        let s = PerfSummarizer.summarize([rung(5, [300, 330, 360])])
        #expect(s.overheadRatio == nil)
        #expect(s.harnessRatio == nil)
        #expect(s.p90Ms == 360)
    }

    @Test("tool call rate and histogram come from rung-5 turns")
    func toolCalls() {
        let s = PerfSummarizer.summarize([rung(5, [1, 2, 3, 4], tools: [["run_command"], [], ["run_command", "read_file"], []])])
        #expect(s.toolCallRate == 0.5)
        #expect(s.toolCallsByName == ["run_command": 2, "read_file": 1])
    }

    @Test("failed repetitions are excluded from medians")
    func failuresExcluded() {
        var r = rung(5, [100, 900])
        r.repetitions[1].error = "HTTP 429"
        let s = PerfSummarizer.summarize([r])
        #expect(s.medianMs == 100)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `cannot find 'PerfRunner' in scope`.

- [ ] **Step 4: Implement**

```swift
// Sources/iris/PerfRunner.swift
import Foundation

/// Executes a suite: for each scenario, for each rung, `repetitions` samples; then summarizes and
/// packages everything into a `PerfRunRecord`. Rungs 1-3 go through `PerfLadder`; 4 and 5 are
/// `ScenarioRunner` turns with guards off / as configured. In the fake lane guards are always off
/// (a fake run must not reach the network) and `HeadlessMode` is expected to be enabled by the CLI.
@MainActor
enum PerfRunner {
    /// Process-wide: the first repetition of the first scenario is the cold start.
    private static var repetitionsCompleted = 0

    static func run(suite: PerfSuite, repetitionsOverride: Int? = nil, repoRoot: URL,
                    client: (any LLMClientProtocol)? = nil, headless: Bool) async throws -> PerfRunRecord {
        try suite.validate()
        let reps = repetitionsOverride ?? suite.repetitions
        let startedAt = Date()
        var results: [PerfScenarioResult] = []
        var toolCount: Int?

        for url in suite.scenarioURLs(relativeTo: repoRoot) {
            let scenario = try Scenario.load(at: url.path)
            let prompt = scenario.turns.first?.prompt ?? ""
            var capture: LadderCapture?
            var rungResults: [PerfRungResult] = []

            for rung in suite.rungs.sorted() {
                var repetitions: [PerfRepetition] = []
                for i in 0..<reps {
                    let cold = repetitionsCompleted == 0
                    let rep: PerfRepetition
                    if rung <= 3 {
                        if capture == nil {
                            capture = await PerfLadder.capture(for: scenario)
                            toolCount = capture?.toolCount
                        }
                        let s = await PerfLadder.sample(rung: rung, prompt: prompt, tier: scenario.tier,
                                                        capture: capture!, client: client ?? LLMClient())
                        rep = PerfRepetition(index: i, coldStart: cold, wallClockMs: s.wallClockMs, turns: [],
                                             modelCalls: s.modelCall.map { [$0] } ?? [], error: s.error)
                    } else {
                        let guards: GuardMode = (rung == 4 || suite.lane == .fake) ? .off : .asConfigured
                        var effective = scenario
                        if suite.lane == .fake { effective.clientMode = .fake }
                        let result = await ScenarioRunner.run(effective, guards: guards, clientOverride: client)
                        let turns = zip(result.turnProfiles, result.finalTexts + Array(repeating: "", count: max(0, result.turnProfiles.count - result.finalTexts.count)))
                            .map { PerfTurn($0, finalTextLength: $1.count) }
                        let failed = result.turnProfiles.isEmpty ? "turn produced no profile" : nil
                        rep = PerfRepetition(index: i, coldStart: cold, wallClockMs: result.wallClockMs, turns: turns,
                                             modelCalls: [], error: failed)
                    }
                    repetitions.append(rep)
                    repetitionsCompleted += 1
                    if suite.lane == .real, suite.pauseMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(suite.pauseMs) * 1_000_000)
                    }
                }
                let ok = repetitions.filter { $0.error == nil }.map(\.wallClockMs)
                rungResults.append(PerfRungResult(rung: rung, repetitions: repetitions,
                                                  medianMs: PerfStats.median(ok) ?? 0, p90Ms: PerfStats.p90(ok) ?? 0))
            }
            if capture == nil, toolCount == nil {
                // No ladder rung ran; still record the tool surface a real turn would send.
                let c = await PerfLadder.capture(for: scenario)
                toolCount = c.toolCount
            }
            results.append(PerfScenarioResult(name: scenario.name, path: relativePath(url, root: repoRoot),
                                              category: category(forScenarioAt: url), lane: suite.lane.rawValue,
                                              rungs: rungResults, summary: PerfSummarizer.summarize(rungResults)))
        }

        return PerfRunRecord(schemaVersion: PerfRunRecord.currentSchemaVersion, suite: suite.name,
                             startedAt: startedAt, finishedAt: Date(),
                             environment: PerfEnvironment.capture(headless: headless, toolDeclarationCount: toolCount, repoRoot: repoRoot),
                             scenarios: results)
    }

    /// The parent directory name: "model-only", "tool-use", "fake".
    static func category(forScenarioAt url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path + "/"
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : p
    }
}

enum PerfSummarizer {
    static func summarize(_ rungs: [PerfRungResult]) -> PerfScenarioSummary {
        func median(of rung: Int) -> Double? {
            guard let r = rungs.first(where: { $0.rung == rung }) else { return nil }
            return PerfStats.median(r.repetitions.filter { $0.error == nil }.map(\.wallClockMs))
        }
        let top = rungs.max { $0.rung < $1.rung }
        let topOk = top?.repetitions.filter { $0.error == nil }.map(\.wallClockMs) ?? []
        let r1 = median(of: 1)
        let ratio: (Int) -> Double? = { rung in
            guard let d = r1, d > 0, let n = median(of: rung) else { return nil }
            return n / d
        }
        let fullTurns = rungs.first { $0.rung == 5 }?.repetitions.flatMap(\.turns) ?? []
        let withTools = fullTurns.filter { !$0.toolCalls.isEmpty }.count
        var byName: [String: Int] = [:]
        for call in fullTurns.flatMap(\.toolCalls) { byName[call.name, default: 0] += 1 }
        return PerfScenarioSummary(medianMs: PerfStats.median(topOk) ?? 0, p90Ms: PerfStats.p90(topOk) ?? 0,
                                   overheadRatio: ratio(5), harnessRatio: ratio(4),
                                   toolCallRate: fullTurns.isEmpty ? 0 : Double(withTools) / Double(fullTurns.count),
                                   toolCallsByName: byName)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "PerfRunnerTests|PerfSummarizerTests" 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 8 tests in 2 suites passed`. If `Scenario.clientMode` is `let`, change it to `var` in `Scenario.swift` (BenchCLI already mutates it, so it should be `var`).

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/PerfRunner.swift perf/prompts/fake Tests/irisTests/PerfRunnerTests.swift
git commit -m "feat(perf): PerfRunner executes suites and summarizes rungs" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Markdown report

**Files:**
- Create: `Sources/iris/PerfReport.swift`
- Test: `Tests/irisTests/PerfReportTests.swift`

**Interfaces:**
- Produces: `PerfReport.render(_ record: PerfRunRecord) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/PerfReportTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfReport")
struct PerfReportTests {
    @Test("report names the suite, sha, provider and each scenario rung")
    func basics() {
        let text = PerfReport.render(PerfRecordTests.sampleRecord())
        #expect(text.contains("# perf: ladder"))
        #expect(text.contains("abc1234"))
        #expect(text.contains("Gemini"))
        #expect(text.contains("capital-city"))
        #expect(text.contains("| 5 |"))
        #expect(text.contains("guard.tier1"))
    }

    @Test("a debug build and a dirty tree are called out")
    func warnings() {
        var r = PerfRecordTests.sampleRecord()
        r.environment.buildConfiguration = "debug"
        r.environment.gitDirty = true
        let text = PerfReport.render(r)
        #expect(text.contains("WARNING: debug build"))
        #expect(text.contains("WARNING: dirty tree"))
        #expect(!PerfReport.render(PerfRecordTests.sampleRecord()).contains("WARNING"))
    }

    @Test("ratios and tool calls are shown when present")
    func ratiosAndTools() {
        var r = PerfRecordTests.sampleRecord()
        r.scenarios[0].summary.overheadRatio = 3.25
        r.scenarios[0].summary.harnessRatio = 1.5
        r.scenarios[0].summary.toolCallsByName = ["run_command": 2]
        r.scenarios[0].summary.toolCallRate = 0.5
        let text = PerfReport.render(r)
        #expect(text.contains("overhead 3.25x"))
        #expect(text.contains("harness 1.50x"))
        #expect(text.contains("run_command: 2"))
        #expect(text.contains("tool-call rate 50%"))
    }

    @Test("failed repetitions are counted")
    func errors() {
        var r = PerfRecordTests.sampleRecord()
        r.scenarios[0].rungs[0].repetitions[0].error = "Gemini HTTP 429"
        #expect(PerfReport.render(r).contains("1 failed"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `cannot find 'PerfReport' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/iris/PerfReport.swift
import Foundation

/// Renders a run record as Markdown for the terminal and for pasting into a review.
enum PerfReport {
    static func render(_ r: PerfRunRecord) -> String {
        var out: [String] = []
        let env = r.environment
        out.append("# perf: \(r.suite)")
        out.append("")
        out.append("- when: \(iso(r.startedAt)) (\(fmt((r.finishedAt.timeIntervalSince(r.startedAt)) * 1000)) ms total)")
        out.append("- commit: \(env.gitSha)\(env.gitDirty ? " (dirty)" : "")  build: \(env.buildConfiguration)")
        out.append("- machine: \(env.machineModel), macOS \(env.osVersion), \(env.cpuCount) cores")
        out.append("- provider: \(env.provider)  models: " + env.models.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        out.append("- guards: vibecop \(env.vibecopEnabled ? "on (\(env.vibecopEngine))" : "off"), injection guard \(env.injectionGuardEnabled ? "on (\(env.promptGuardEngine))" : "off"), sandbox \(env.sandboxEnabled ? "on" : "off"), headless \(env.headless)")
        if let n = env.toolDeclarationCount { out.append("- tool declarations sent per call: \(n)") }
        if env.buildConfiguration == "debug" { out.append("- WARNING: debug build; timings are not comparable to release runs") }
        if env.gitDirty { out.append("- WARNING: dirty tree; the sha does not describe this code") }
        out.append("")

        for s in r.scenarios {
            out.append("## \(s.name)  (\(s.category), \(s.lane))")
            out.append("")
            out.append("| rung | n | median ms | p90 ms | prompt tokens | failed |")
            out.append("|---|---|---|---|---|---|")
            for rung in s.rungs {
                let ok = rung.repetitions.filter { $0.error == nil }
                let failed = rung.repetitions.count - ok.count
                let tokens = PerfStats.median(ok.flatMap { rep in (rep.modelCalls + rep.turns.flatMap(\.modelCalls)).compactMap { $0.promptTokens }.map(Double.init) })
                out.append("| \(rung.rung) | \(ok.count) | \(fmt(rung.medianMs)) | \(fmt(rung.p90Ms)) | \(tokens.map { String(Int($0)) } ?? "-") | \(failed > 0 ? "\(failed) failed" : "-") |")
            }
            out.append("")
            var ratios: [String] = []
            if let o = s.summary.overheadRatio { ratios.append("overhead \(String(format: "%.2f", o))x") }
            if let h = s.summary.harnessRatio { ratios.append("harness \(String(format: "%.2f", h))x") }
            if !ratios.isEmpty { out.append("- ratios vs bare call: " + ratios.joined(separator: ", ")) }
            let spans = topSpans(s)
            if !spans.isEmpty { out.append("- top spans (rung \(s.rungs.last?.rung ?? 0), summed): " + spans.map { "\($0.0) \(fmt($0.1)) ms" }.joined(separator: ", ")) }
            if !s.summary.toolCallsByName.isEmpty || s.summary.toolCallRate > 0 {
                out.append("- tool-call rate \(Int((s.summary.toolCallRate * 100).rounded()))%: " + s.summary.toolCallsByName.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func topSpans(_ s: PerfScenarioResult) -> [(String, Double)] {
        guard let top = s.rungs.last else { return [] }
        var sum: [String: Double] = [:]
        for span in top.repetitions.flatMap(\.turns).flatMap({ $0.spans }) { sum[span.key, default: 0] += span.value.ms }
        return sum.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    private static func fmt(_ ms: Double) -> String { String(format: "%.1f", ms) }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); return f.string(from: d)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PerfReportTests 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 4 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PerfReport.swift Tests/irisTests/PerfReportTests.swift
git commit -m "feat(perf): Markdown report for a run record" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Compare two records

**Files:**
- Create: `Sources/iris/PerfCompare.swift`
- Test: `Tests/irisTests/PerfCompareTests.swift`

**Interfaces:**
- Produces:

```swift
struct PerfComparison { var refusal: String?; var rows: [Row]; var flagged: [Row] { rows.filter(\.flagged) }
    struct Row: Equatable { var scenario: String; var rung: Int?; var metric: String; var before: Double; var after: Double; var change: Double?; var flagged: Bool } }
enum PerfCompare {
    static func compare(baseline: PerfRunRecord, current: PerfRunRecord, threshold: Double) -> PerfComparison
    static func render(_ c: PerfComparison, threshold: Double) -> String
    static func exitCode(_ c: PerfComparison) -> Int32   // 2 refusal, 1 flagged, 0 clean
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/PerfCompareTests.swift
import Testing
import Foundation
@testable import iris

@Suite("PerfCompare")
struct PerfCompareTests {
    private func record(medianMs: Double, ratio: Double? = nil, provider: String = "Gemini", model: String = "gemini-3.8-flash", scenario: String = "capital-city") -> PerfRunRecord {
        var r = PerfRecordTests.sampleRecord()
        r.environment.provider = provider
        r.environment.models = ["medium": model]
        r.scenarios[0].name = scenario
        r.scenarios[0].rungs[0].medianMs = medianMs
        r.scenarios[0].summary.medianMs = medianMs
        r.scenarios[0].summary.overheadRatio = ratio
        return r
    }

    @Test("a 25% slower median is flagged at the default threshold; 10% is not")
    func flagging() {
        let slow = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 125), threshold: 0.2)
        #expect(slow.flagged.count == 1)
        #expect(slow.flagged.first?.metric == "median ms")
        #expect(slow.flagged.first?.rung == 5)
        #expect(PerfCompare.exitCode(slow) == 1)
        let fine = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 110), threshold: 0.2)
        #expect(fine.flagged.isEmpty)
        #expect(PerfCompare.exitCode(fine) == 0)
    }

    @Test("faster is never flagged")
    func fasterIsFine() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 50), threshold: 0.2)
        #expect(c.flagged.isEmpty)
        #expect(c.rows.first?.change == -0.5)
    }

    @Test("overhead ratio is compared when both records have it")
    func ratioCompared() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100, ratio: 2.0), current: record(medianMs: 100, ratio: 2.6), threshold: 0.2)
        #expect(c.flagged.map(\.metric) == ["overhead ratio"])
    }

    @Test("mismatched provider or model is refused with exit 2")
    func refusal() {
        let p = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 100, provider: "Anthropic"), threshold: 0.2)
        #expect(p.refusal?.contains("provider") == true)
        #expect(PerfCompare.exitCode(p) == 2)
        let m = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 100, model: "gemini-4"), threshold: 0.2)
        #expect(m.refusal?.contains("model") == true)
    }

    @Test("scenarios present in only one record are skipped")
    func unmatchedSkipped() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 300, scenario: "other"), threshold: 0.2)
        #expect(c.rows.isEmpty)
        #expect(PerfCompare.exitCode(c) == 0)
    }

    @Test("render shows percent change and marks flagged rows")
    func render() {
        let c = PerfCompare.compare(baseline: record(medianMs: 100), current: record(medianMs: 125), threshold: 0.2)
        let text = PerfCompare.render(c, threshold: 0.2)
        #expect(text.contains("+25.0%"))
        #expect(text.contains("REGRESSION"))
        #expect(text.contains("threshold 20%"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `cannot find 'PerfCompare' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/iris/PerfCompare.swift
import Foundation

struct PerfComparison {
    struct Row: Equatable {
        var scenario: String
        var rung: Int?
        var metric: String
        var before: Double
        var after: Double
        var change: Double?
        var flagged: Bool
    }
    var refusal: String?
    var rows: [Row]
    var flagged: [Row] { rows.filter(\.flagged) }
}

/// Joins two records by scenario name and rung and flags regressions past a threshold.
/// Only like-for-like is compared: a provider or model change is a refusal, not a regression.
enum PerfCompare {
    static func compare(baseline: PerfRunRecord, current: PerfRunRecord, threshold: Double) -> PerfComparison {
        if baseline.environment.provider != current.environment.provider {
            return PerfComparison(refusal: "provider differs: \(baseline.environment.provider) vs \(current.environment.provider)", rows: [])
        }
        if baseline.environment.models != current.environment.models {
            return PerfComparison(refusal: "model names differ: \(baseline.environment.models) vs \(current.environment.models)", rows: [])
        }
        var rows: [PerfComparison.Row] = []
        func row(_ scenario: String, _ rung: Int?, _ metric: String, _ a: Double, _ b: Double) {
            let change = PerfStats.percentChange(from: a, to: b)
            rows.append(.init(scenario: scenario, rung: rung, metric: metric, before: a, after: b,
                              change: change, flagged: (change ?? 0) > threshold))
        }
        for cur in current.scenarios {
            guard let base = baseline.scenarios.first(where: { $0.name == cur.name }) else { continue }
            for r in cur.rungs {
                guard let br = base.rungs.first(where: { $0.rung == r.rung }) else { continue }
                row(cur.name, r.rung, "median ms", br.medianMs, r.medianMs)
                if let bt = medianPromptTokens(br), let ct = medianPromptTokens(r) {
                    row(cur.name, r.rung, "prompt tokens", bt, ct)
                }
            }
            if let a = base.summary.overheadRatio, let b = cur.summary.overheadRatio {
                row(cur.name, nil, "overhead ratio", a, b)
            }
        }
        return PerfComparison(refusal: nil, rows: rows)
    }

    static func render(_ c: PerfComparison, threshold: Double) -> String {
        if let refusal = c.refusal { return "cannot compare: \(refusal)" }
        var out = ["| scenario | rung | metric | before | after | change |", "|---|---|---|---|---|---|"]
        for r in c.rows {
            let change = r.change.map { String(format: "%+.1f%%", $0 * 100) } ?? "n/a"
            out.append("| \(r.scenario) | \(r.rung.map(String.init) ?? "-") | \(r.metric) | \(short(r.before)) | \(short(r.after)) | \(change)\(r.flagged ? " REGRESSION" : "") |")
        }
        out.append("")
        out.append(c.flagged.isEmpty ? "no regressions past threshold \(Int(threshold * 100))%"
                                     : "\(c.flagged.count) regression(s) past threshold \(Int(threshold * 100))%")
        return out.joined(separator: "\n")
    }

    static func exitCode(_ c: PerfComparison) -> Int32 {
        if c.refusal != nil { return 2 }
        return c.flagged.isEmpty ? 0 : 1
    }

    private static func medianPromptTokens(_ r: PerfRungResult) -> Double? {
        let tokens = r.repetitions.filter { $0.error == nil }
            .flatMap { rep in (rep.modelCalls + rep.turns.flatMap(\.modelCalls)).compactMap(\.promptTokens) }
            .map(Double.init)
        return PerfStats.median(tokens)
    }

    private static func short(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PerfCompareTests 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 6 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/PerfCompare.swift Tests/irisTests/PerfCompareTests.swift
git commit -m "feat(perf): compare two run records and flag regressions" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: `--perf` CLI, main dispatch, run.sh, smoke suite, README

**Files:**
- Create: `Sources/iris/PerfCLI.swift`, `perf/run.sh`, `perf/README.md`, `perf/suites/smoke.json`, `perf/baselines/.gitkeep`
- Modify: `Sources/iris/main.swift`, `Sources/iris/BenchCLI.swift`, `.gitignore`
- Test: `Tests/irisTests/PerfCLITests.swift`

**Interfaces:**
- Produces:

```swift
enum PerfCommand: Equatable {
    case run(suite: String, reps: Int?, out: String, fakeOnly: Bool)
    case report(path: String)
    case compare(baseline: String, current: String, threshold: Double)
}
enum PerfCLIError: Error, Equatable { case usage(String) }
enum PerfCLI {
    static func parse(_ args: [String]) -> Result<PerfCommand, PerfCLIError>?   // nil when --perf absent
    @MainActor static func execute(_ cmd: PerfCommand) async -> Int32
    static let usage: String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/irisTests/PerfCLITests.swift
import Testing
@testable import iris

@Suite("PerfCLI parsing")
struct PerfCLITests {
    @Test("absent --perf is nil")
    func absent() {
        #expect(PerfCLI.parse(["iris"]) == nil)
        #expect(PerfCLI.parse(["iris", "--bench"]) == nil)
    }

    @Test("run with defaults and with every flag")
    func run() {
        #expect(PerfCLI.parse(["iris", "--perf", "run", "perf/suites/smoke.json"]) ==
                .success(.run(suite: "perf/suites/smoke.json", reps: nil, out: "perf/runs", fakeOnly: false)))
        #expect(PerfCLI.parse(["iris", "--perf", "run", "s.json", "--reps", "5", "--out", "/tmp/x", "--fake-only"]) ==
                .success(.run(suite: "s.json", reps: 5, out: "/tmp/x", fakeOnly: true)))
    }

    @Test("report and compare")
    func reportAndCompare() {
        #expect(PerfCLI.parse(["iris", "--perf", "report", "a.json"]) == .success(.report(path: "a.json")))
        #expect(PerfCLI.parse(["iris", "--perf", "compare", "a.json", "b.json"]) == .success(.compare(baseline: "a.json", current: "b.json", threshold: 0.2)))
        #expect(PerfCLI.parse(["iris", "--perf", "compare", "a.json", "b.json", "--threshold", "0.5"]) == .success(.compare(baseline: "a.json", current: "b.json", threshold: 0.5)))
    }

    @Test("bad invocations are usage errors")
    func usageErrors() {
        #expect(PerfCLI.parse(["iris", "--perf"]) == .failure(.usage("missing subcommand")))
        #expect(PerfCLI.parse(["iris", "--perf", "run"]) == .failure(.usage("run needs a suite path")))
        #expect(PerfCLI.parse(["iris", "--perf", "compare", "a.json"]) == .failure(.usage("compare needs a baseline and a current record")))
        #expect(PerfCLI.parse(["iris", "--perf", "run", "s.json", "--reps", "x"]) == .failure(.usage("--reps needs an integer")))
        #expect(PerfCLI.parse(["iris", "--perf", "frobnicate"]) == .failure(.usage("unknown subcommand frobnicate")))
    }
}
```

Make `PerfCommand` and `PerfCLIError` `Equatable` so `Result` equality works.

- [ ] **Step 2: Run to verify failure**

Run: `swift build --build-tests 2>&1 | grep error: | head -2`
Expected: `cannot find 'PerfCLI' in scope`.

- [ ] **Step 3: Create `PerfCLI.swift`**

```swift
import Foundation

enum PerfCommand: Equatable {
    case run(suite: String, reps: Int?, out: String, fakeOnly: Bool)
    case report(path: String)
    case compare(baseline: String, current: String, threshold: Double)
}

enum PerfCLIError: Error, Equatable, LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let m) = self { return m } ; return nil }
}

/// `iris --perf run|report|compare`. Parsed before SwiftUI starts (see main.swift).
enum PerfCLI {
    static let usage = """
    usage:
      iris --perf run     <suite.json> [--reps N] [--out DIR] [--fake-only]
      iris --perf report  <run.json>
      iris --perf compare <baseline.json> <run.json> [--threshold 0.20]
    """

    static func parse(_ args: [String]) -> Result<PerfCommand, PerfCLIError>? {
        guard let i = args.firstIndex(of: "--perf") else { return nil }
        var rest = Array(args[(i + 1)...])
        guard !rest.isEmpty else { return .failure(.usage("missing subcommand")) }
        let sub = rest.removeFirst()
        func flag(_ name: String) -> Bool {
            if let j = rest.firstIndex(of: name) { rest.remove(at: j); return true }
            return false
        }
        func value(_ name: String) -> String?? {   // .some(nil) means flag present without value
            guard let j = rest.firstIndex(of: name) else { return nil }
            rest.remove(at: j)
            guard j < rest.count, !rest[j].hasPrefix("--") else { return .some(nil) }
            return .some(rest.remove(at: j))
        }
        switch sub {
        case "run":
            let fakeOnly = flag("--fake-only")
            var reps: Int?
            if let v = value("--reps") {
                guard let s = v, let n = Int(s) else { return .failure(.usage("--reps needs an integer")) }
                reps = n
            }
            var out = "perf/runs"
            if let v = value("--out") {
                guard let s = v else { return .failure(.usage("--out needs a directory")) }
                out = s
            }
            guard let suite = rest.first, !suite.hasPrefix("--") else { return .failure(.usage("run needs a suite path")) }
            return .success(.run(suite: suite, reps: reps, out: out, fakeOnly: fakeOnly))
        case "report":
            guard let path = rest.first else { return .failure(.usage("report needs a run record path")) }
            return .success(.report(path: path))
        case "compare":
            var threshold = 0.2
            if let v = value("--threshold") {
                guard let s = v, let t = Double(s) else { return .failure(.usage("--threshold needs a number")) }
                threshold = t
            }
            guard rest.count >= 2 else { return .failure(.usage("compare needs a baseline and a current record")) }
            return .success(.compare(baseline: rest[0], current: rest[1], threshold: threshold))
        default:
            return .failure(.usage("unknown subcommand \(sub)"))
        }
    }

    @MainActor
    static func execute(_ cmd: PerfCommand) async -> Int32 {
        do {
            switch cmd {
            case .run(let suitePath, let reps, let out, let fakeOnly):
                let suite = try PerfSuite.load(at: suitePath)
                if fakeOnly, suite.lane == .real {
                    print("perf: skipping real-lane suite \(suite.name) (--fake-only)")
                    return 0
                }
                // Settings come from a volatile copy so guard toggles never persist. Must precede
                // the first touch of ConfigManager.shared (inside the runner).
                IrisDefaults.useVolatileCopyOfStandard()
                if suite.lane == .fake { HeadlessMode.enable() }
                let root = PerfPaths.repoRoot()
                let record = try await PerfRunner.run(suite: suite, repetitionsOverride: reps, repoRoot: root, headless: suite.lane == .fake)
                print(PerfReport.render(record))
                let dir = out.hasPrefix("/") ? URL(fileURLWithPath: out) : root.appendingPathComponent(out)
                let url = try record.write(toDirectory: dir)
                print("perf: wrote \(url.path)")
                return 0
            case .report(let path):
                print(PerfReport.render(try PerfRunRecord.load(at: path)))
                return 0
            case .compare(let a, let b, let threshold):
                let c = PerfCompare.compare(baseline: try PerfRunRecord.load(at: a), current: try PerfRunRecord.load(at: b), threshold: threshold)
                print(PerfCompare.render(c, threshold: threshold))
                return PerfCompare.exitCode(c)
            }
        } catch {
            FileHandle.standardError.write(Data("iris --perf: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
```

- [ ] **Step 4: Dispatch in `main.swift`; volatile copy in `BenchCLI`**

Replace `main.swift` with:

```swift
import Foundation

// Headless modes run before any SwiftUI window is created and exit. Top-level `await` runs this
// on the main actor, so the @MainActor entry points can execute directly.
if let perf = PerfCLI.parse(CommandLine.arguments) {
    switch perf {
    case .success(let cmd):
        exit(await PerfCLI.execute(cmd))
    case .failure(let err):
        FileHandle.standardError.write(Data("iris --perf: \(err.localizedDescription)\n\(PerfCLI.usage)\n".utf8))
        exit(64)
    }
} else if let benchOptions = BenchCLI.parse(CommandLine.arguments) {
    await BenchCLI.run(benchOptions)
    exit(0)
} else {
    IrisApp.main()
}
```

In `BenchCLI.run`, replace

```swift
        if scenario.clientMode == .fake {
            HeadlessMode.enable()
        }
```

with

```swift
        // Bench runs never write to the user's real preferences.
        IrisDefaults.useVolatileCopyOfStandard()
        if scenario.clientMode == .fake {
            HeadlessMode.enable()
        }
```

- [ ] **Step 5: Smoke suite, gitignore, baselines dir**

`perf/suites/smoke.json`:

```json
{
  "name": "smoke",
  "lane": "fake",
  "repetitions": 3,
  "rungs": [5],
  "scenarios": [
    "perf/prompts/fake/text-only.json",
    "perf/prompts/fake/one-command.json",
    "scenarios/echo-latency.json"
  ]
}
```

Append to `.gitignore`:

```
# Perf run records are local until promoted to perf/baselines/
perf/runs/
```

Create an empty `perf/baselines/.gitkeep`.

- [ ] **Step 6: `perf/run.sh`**

```zsh
#!/bin/zsh
# The one sanctioned way to execute the perf suites, so every run is comparable:
# release build, the suite files' own repetitions, records under perf/runs/, and a comparison
# against the newest promoted baseline for each suite when one exists.
set -euo pipefail
cd "$(dirname "$0")/.."

FAKE_ONLY=0
PROMOTE=0
for arg in "$@"; do
  case "$arg" in
    --fake-only) FAKE_ONLY=1 ;;
    --promote)   PROMOTE=1 ;;
    *) echo "usage: perf/run.sh [--fake-only] [--promote]" >&2; exit 64 ;;
  esac
done

sha=$(git rev-parse --short HEAD)
dirty=""
git diff --quiet && git diff --cached --quiet || dirty=" (dirty tree: results will be flagged)"
echo "perf: building release at ${sha}${dirty}"
swift build -c release 2>&1 | tail -1
BIN=.build/release/iris

suites=(perf/suites/smoke.json)
if (( ! FAKE_ONLY )); then
  suites+=(perf/suites/ladder.json perf/suites/tool-eagerness.json)
fi

mkdir -p perf/runs perf/baselines
status=0
for suite in "${suites[@]}"; do
  name=$(basename "$suite" .json)
  echo ""
  echo "perf: running suite ${name}"
  "$BIN" --perf run "$suite" --out perf/runs
  latest=$(ls -t perf/runs/*-"${name}"-*.json | head -1)
  baseline=$(ls -t perf/baselines/*-"${name}"-*.json 2>/dev/null | head -1 || true)
  if [[ -n "$baseline" ]]; then
    echo "perf: comparing ${name} against $(basename "$baseline")"
    "$BIN" --perf compare "$baseline" "$latest" || status=$?
  else
    echo "perf: no baseline for ${name}; run with --promote to create one"
  fi
  if (( PROMOTE )); then
    cp "$latest" perf/baselines/
    echo "perf: promoted $(basename "$latest")"
  fi
done
exit $status
```

Then: `chmod +x perf/run.sh`.

- [ ] **Step 7: `perf/README.md`**

```markdown
# perf/ — the tracked performance database

Iris runs a headless suite of scenarios and records where each turn's time goes. Records are
compared over time against a promoted baseline. The design is in
`docs/specs/2026-09-17-performance-evaluation-suite.md`.

## Run it

    perf/run.sh                 # release build; smoke + ladder + tool-eagerness; compare to baselines
    perf/run.sh --fake-only     # smoke only, no credentials or network
    perf/run.sh --promote       # also copy this run's records into perf/baselines/

Real-lane suites need a configured provider (the ladder was first run with Gemini via ADC).
Run on a quiet machine; timings from a debug build or a dirty tree are flagged in the report.

## Layout

    suites/      what to run: scenarios, lane (fake/real), repetitions, pause, ladder rungs
    prompts/     scenario files grouped by category (model-only, tool-use, fake)
    runs/        one JSON record per suite run (gitignored)
    baselines/   promoted records that later runs compare against (committed)

## The ladder

Each real-lane prompt is timed at up to five rungs; each delta isolates one layer:

| rung | what runs | delta isolates |
|---|---|---|
| 1 | bare provider call, prompt only | the model (the denominator) |
| 2 | + Iris's assembled system prompt | prompt size |
| 3 | + the tool declarations | tool schema |
| 4 | full Iris turn, guards off | harness overhead |
| 5 | full Iris turn, guards as configured | the security layers |

**Overhead ratio** = median rung 5 / median rung 1. **Harness ratio** = rung 4 / rung 1.

## Reading a record

`iris --perf report <run.json>` renders the Markdown summary. Per scenario: a row per rung with
median and p90 wall-clock and median prompt tokens, the two ratios, the top five named spans
(`guard.tier3`, `vibecop`, `assembly.userProfile`, ...), and the tool-call rate with a histogram.

`iris --perf compare <baseline.json> <run.json>` prints percent change per metric and flags any
increase past 20% (`--threshold` to change). Exit 1 means a regression was flagged; exit 2 means
the records are not comparable (different provider or model names).

## Promoting a baseline

A baseline is a record you trust as the reference. `perf/run.sh --promote` copies the run's
records into `perf/baselines/`; commit them. Later runs compare against the newest baseline for
the same suite.
```

- [ ] **Step 8: Build, run tests, and run the smoke suite for real**

Run: `swift test 2>&1 | grep -E "error:|✘|Test run with"`
Expected: all suites pass.

Run: `swift build && .build/debug/iris --perf run perf/suites/smoke.json --out /tmp/perf-smoke && ls /tmp/perf-smoke`
Expected: a Markdown report on stdout with three scenarios, then `perf: wrote /tmp/perf-smoke/<timestamp>-smoke-<sha>.json`, and the file listed. The report must contain `WARNING: debug build`.

Run: `perf/run.sh --fake-only`
Expected: builds release, runs smoke, prints `perf: no baseline for smoke`, exits 0, and a record appears in `perf/runs/`.

Run: `.build/debug/iris --perf compare perf/runs/<the smoke record> /tmp/perf-smoke/<the debug record>; echo exit=$?`
Expected: a comparison table and `exit=0` or `exit=1` (fake timings are noisy); the point is that both paths work.

Run: `ls ~/Library/Preferences | grep iris-bench`
Expected: nothing, proving the volatile suite was removed at exit.

- [ ] **Step 9: Commit**

```bash
git add Sources/iris/PerfCLI.swift Sources/iris/main.swift Sources/iris/BenchCLI.swift Tests/irisTests/PerfCLITests.swift perf/run.sh perf/README.md perf/suites/smoke.json perf/baselines/.gitkeep .gitignore
git commit -m "feat(perf): --perf run/report/compare, perf/run.sh and the smoke suite" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Prompt sets, real suites, README pointer

**Files:**
- Create: `perf/prompts/model-only/*.json` (six), `perf/prompts/tool-use/*.json` (two), `perf/suites/ladder.json`, `perf/suites/tool-eagerness.json`
- Modify: `README.md` (Headless Profiling section)
- Test: `Tests/irisTests/PerfSuiteFilesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/irisTests/PerfSuiteFilesTests.swift
import Testing
import Foundation
@testable import iris

/// The committed suite and prompt files must load, or perf/run.sh fails at the worst moment.
@Suite("perf/ suite files")
struct PerfSuiteFilesTests {
    private let root = PerfPaths.repoRoot()

    @Test("every committed suite loads and every scenario it lists exists and decodes",
          arguments: ["smoke", "ladder", "tool-eagerness"])
    func suitesLoad(name: String) throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/\(name).json").path)
        #expect(suite.name == name)
        for url in suite.scenarioURLs(relativeTo: root) {
            #expect(FileManager.default.fileExists(atPath: url.path), url.path)
            let scenario = try Scenario.load(at: url.path)
            #expect(scenario.turns.count == 1, "perf scenarios are single-turn so rungs 1-3 have one prompt")
            if suite.lane == .real { #expect(scenario.clientMode == .real, url.path) }
        }
    }

    @Test("the real suites are paced and keep repetitions small")
    func realSuitesArePaced() throws {
        for name in ["ladder", "tool-eagerness"] {
            let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/\(name).json").path)
            #expect(suite.lane == .real)
            #expect(suite.pauseMs >= 1000)
            #expect(suite.repetitions <= 3)
        }
    }

    @Test("the eagerness suite covers both categories")
    func eagernessCategories() throws {
        let suite = try PerfSuite.load(at: root.appendingPathComponent("perf/suites/tool-eagerness.json").path)
        let categories = Set(suite.scenarioURLs(relativeTo: root).map(PerfRunner.category(forScenarioAt:)))
        #expect(categories == ["model-only", "tool-use"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PerfSuiteFilesTests 2>&1 | grep -E "✘|Test run"`
Expected: failures for the missing `ladder` and `tool-eagerness` files.

- [ ] **Step 3: Create the prompt files**

Each is a one-turn real scenario. `perf/prompts/model-only/`:

`capital-city.json`
```json
{ "name": "capital-city", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "What is the capital of Australia, and why isn't it Sydney? Two or three sentences." } ] }
```

`explain-concept.json`
```json
{ "name": "explain-concept", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "Explain the difference between a mutex and a semaphore in three sentences." } ] }
```

`advice.json`
```json
{ "name": "advice", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "I have two job offers: one pays 15% more, the other has a team I already know and like. What factors should I weigh? Keep it short." } ] }
```

`short-writing.json`
```json
{ "name": "short-writing", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "Write a two-sentence release note for a fix that stops the app crashing on launch when the settings file is empty." } ] }
```

`conversation-meta.json`
```json
{ "name": "conversation-meta", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "In one paragraph, what kinds of tasks are you good at and what should I not ask you to do?" } ] }
```

`quick-reasoning.json`
```json
{ "name": "quick-reasoning", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "A train leaves at 9:40 and the trip takes 2 hours 35 minutes. When does it arrive? Just the time and one line of working." } ] }
```

`perf/prompts/tool-use/`:

`run-uname.json`
```json
{ "name": "run-uname", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "Run `uname -sr` and tell me exactly what it printed." } ] }
```

`count-files.json`
```json
{ "name": "count-files", "clientMode": "real", "tier": "medium",
  "turns": [ { "prompt": "How many .swift files are directly inside the Sources/iris directory of the current working directory? Use a shell command and give me the number." } ] }
```

- [ ] **Step 4: Create the real suites**

`perf/suites/ladder.json`:

```json
{
  "name": "ladder",
  "lane": "real",
  "repetitions": 3,
  "pauseMs": 1500,
  "rungs": [1, 2, 3, 4, 5],
  "scenarios": [
    "perf/prompts/model-only/capital-city.json",
    "perf/prompts/model-only/explain-concept.json",
    "perf/prompts/model-only/short-writing.json",
    "perf/prompts/tool-use/run-uname.json",
    "perf/prompts/tool-use/count-files.json"
  ]
}
```

`perf/suites/tool-eagerness.json`:

```json
{
  "name": "tool-eagerness",
  "lane": "real",
  "repetitions": 2,
  "pauseMs": 1500,
  "rungs": [5],
  "scenarios": [
    "perf/prompts/model-only/capital-city.json",
    "perf/prompts/model-only/explain-concept.json",
    "perf/prompts/model-only/advice.json",
    "perf/prompts/model-only/short-writing.json",
    "perf/prompts/model-only/conversation-meta.json",
    "perf/prompts/model-only/quick-reasoning.json",
    "perf/prompts/tool-use/run-uname.json",
    "perf/prompts/tool-use/count-files.json"
  ]
}
```

- [ ] **Step 5: README pointer**

In `README.md`, at the end of the "Headless Profiling (`--bench`)" section (after the paragraph that mentions `docs/headless_profiling.md`), add:

```markdown
For repeatable performance tracking over time, run `perf/run.sh`: it executes the suites under
`perf/suites/` at a release build, records where each turn's time goes (including a five-rung
comparison against a bare provider call), and compares against promoted baselines. See
[perf/README.md](perf/README.md).
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter PerfSuiteFilesTests 2>&1 | grep -E "error:|✘|Test run"`
Expected: `Test run with 5 tests in 1 suite passed` (three parameterized cases plus two).

- [ ] **Step 7: Commit**

```bash
git add perf/prompts perf/suites/ladder.json perf/suites/tool-eagerness.json README.md Tests/irisTests/PerfSuiteFilesTests.swift
git commit -m "feat(perf): model-only and tool-use prompt sets, ladder and eagerness suites" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: First real runs, baseline, and the eagerness analysis

This task produces findings, not code. It needs the configured provider on this machine (Gemini via ADC) and makes roughly 120 provider calls with 1.5 s pauses; expect 10 to 15 minutes.

**Files:**
- Create: `perf/baselines/<timestamp>-ladder-<sha>.json`, `perf/baselines/<timestamp>-tool-eagerness-<sha>.json`, `perf/baselines/<timestamp>-smoke-<sha>.json`
- Create: `docs/reviews/2026-09-17-tool-eagerness-analysis.md`

- [ ] **Step 1: Run the full suite and promote**

Run: `git status --short` and confirm the tree is clean (a dirty tree is flagged in the record and should not become a baseline).

Run: `perf/run.sh --promote 2>&1 | tee /tmp/perf-first-run.log`
Expected: three reports, three `perf: promoted ...` lines, exit 0. If a real suite fails outright (auth), fix the environment and rerun; if individual repetitions fail with 429, they are recorded as `failed` and the run is still valid.

- [ ] **Step 2: Read the ladder report**

From the ladder report, for each scenario write down rung medians 1 to 5 and the two ratios. Compute the deltas rung 2 - 1 (prompt size), 3 - 2 (tools), 4 - 3 (harness), 5 - 4 (guards). Note the median prompt tokens at rungs 1, 2, 3 and the top spans at rung 5.

- [ ] **Step 3: Read the eagerness report**

For each `model-only` scenario note `tool-call rate` and the histogram; for each `tool-use` scenario confirm the rate is 100% and which tool fired.

- [ ] **Step 4: Static read of the request**

Run: `.build/release/iris --bench 2>/dev/null | head -1` is not needed; instead read these and note anything that steers the model toward tools:
- `Sources/iris/assets/SYSTEM.md` (shipped steering)
- `~/.iris/memory/SOUL.md` and the skills list (`~/.iris/memory/skills/`)
- tool descriptions in `Sources/iris/ToolExecutor.swift` `getTools()` and the engine-appended declarations in `Sources/iris/iris.swift` lines 376 to 600 (look for imperative "Do this when..." / "Use this when..." phrasing and for tools offered in a plain chat that only make sense in goal mode)
- the per-turn "Mid-Term Fact Store Memory (JIT Context)" block and the `save_fact` declaration

- [ ] **Step 5: Write the analysis**

Create `docs/reviews/2026-09-17-tool-eagerness-analysis.md` with these sections, filled from steps 2 to 4:

```markdown
# Tool Eagerness and Turn Latency: First Measurements

* **Records**: perf/baselines/<ladder file>, perf/baselines/<eagerness file>
* **Commit**: <sha>  **Provider/models**: <from the report>
* **Date**: 2026-09-17

## Ladder results

| scenario | rung 1 | rung 2 | rung 3 | rung 4 | rung 5 | overhead | harness |
|---|---|---|---|---|---|---|---|
(one row per scenario, medians in ms, ratios with two decimals)

### Where the time goes
- prompt size (2 - 1): ... ms median, ... prompt tokens at rung 2 vs ... at rung 1
- tool schema (3 - 2): ...
- harness (4 - 3): ...; top spans at rung 4: ...
- guards (5 - 4): ...; top spans at rung 5: guard.tier3 ..., vibecop ..., assembly.userProfile ...

## Eagerness results

| scenario | category | tool-call rate | tools |
|---|---|---|---|

## What in the request drives tool use
(numbered list; each item cites the file and the wording, and says whether the measurement supports it)

## Candidate changes, ranked by expected effect
(each: the change, which rung/metric it should move, how to verify with perf/run.sh)

## Not measured here
- streaming (no client streams; rung 1 latency is the floor a streaming UI would start showing at)
- cold start beyond the first repetition
```

- [ ] **Step 6: Commit**

```bash
git add perf/baselines docs/reviews/2026-09-17-tool-eagerness-analysis.md
git commit -m "perf: first ladder and eagerness baselines with analysis" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 7: Finish the branch**

Run: `swift test 2>&1 | grep -E "✘|Test run with"` and confirm green, then push `feat/perf-suite` and open a PR against `main` (repo `sackheads/iris`) using the spec's motivation as the summary and the analysis's ladder table as the headline.
