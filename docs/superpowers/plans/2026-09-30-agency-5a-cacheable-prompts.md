# Agency 5a: Cacheable, Measurable Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every conversation's prompt byte-stable and cacheable across turns, and make cache reads and writes visible, before 5b adds a volatile briefing.

**Architecture:** Two PRs. **PR A** (Tasks 1–4) adds instrumentation only: it changes no request byte, so the baseline it measures is the current behaviour. **PR B** (Tasks 5–10) changes the request: sorted keys, a turn-context block attached per round to this turn's user entry (never persisted), and `USER.md`/`AGENTS.md` moved into the cached base. Both PRs are measured with a new `caching` perf suite.

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test`/`#expect`), the headless perf harness (`iris --perf`).

**Spec:** `docs/specs/2026-09-30-agency-cacheable-prompts.md` (PR #310). Read it first; this plan argues from it.

## Global Constraints

- Swift Testing only; no XCTest (AGENTS.md).
- Every new field on a persisted `Codable` type is decoded with `decodeIfPresent` (invariant 1). Here that means `TokenUsage` and `ModelCallRecord`.
- No test mutates `ConfigManager.shared` or other process globals (invariant 7). Engine tests use `CapturingLLMClient` and injected state.
- Cite filtered runs with their test count, using `scripts/test-filter.sh <TypeName>` (Build and test, #271).
- A cache count the provider did not report is `nil` and renders as `—`, never `0` (spec §0.4).
- Anthropic `promptTokenCount` = `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` (spec §0.4).
- The turn-context block is never written to `history` (spec §0.2).
- Behaviour changes search for what they made untrue, in README, docs and agent-facing strings (invariant 9).
- Conventional commits, with the `Co-Authored-By` trailer.

## Spec amendments (already applied to #310)

Found while writing this plan and committed to the spec's own PR, so the spec and the plan agree:

1. §3 calls the measurement "Rung 4, multi-turn caching (`PerfLadder`)". Rung 4 already exists: a full Iris turn with guards off. The measurement is a new **suite**, `perf/suites/caching.json`, run at rung 4. Replace the heading and the one sentence.
2. §3 says the baseline runs "on main before any 5a code lands". The baseline needs PR A's counters, so it runs on main **after PR A and before PR B**. PR A changes no request byte, so it measures today's behaviour.
3. §0.4 gains: **`totalTokenCount` = prompt + output whenever the provider omits it.** Anthropic sets it to nil on both paths today (`AnthropicClient.swift:229`, `AnthropicStreamMapper`), and the per-run and daily job budgets read `totalTokenCount`, so Anthropic runs have never been charged against a budget. After this fix every provider charges every token sent, cached or not. `docs/jobs.md` says so.

## Review Focus

1. **Job budgets start charging Anthropic runs.** A daily budget that "worked" only because it read 0 will now trip. Expected: the budget measures real usage. Test it in Task 1, document it in Task 1, and call it out in PR A's description.
2. **A PreCompress hook that rewrites history mid-turn.** The turn-context anchor must not attach the block to the wrong entry. Expected: the block rides the turn's own entry, or is left off, never put on another message. Test in Task 6.
3. **A turn with a mid-task steer.** The block stays on the original entry and is byte-identical across rounds, even though `history` gained entries. Test in Task 6.
4. **A conversation saved and reloaded after a turn.** The persisted history contains no `<turn_context>`. Test in Task 6.
5. **An older perf baseline passed to `--perf compare`.** It must decode and compare, with cache columns rendering `—`. Test in Task 2.

---

## PR A: instrumentation (no request byte changes)

### Task 1: Cache counts and a complete total in `UsageMetadata`

**Files:**
- Modify: `Sources/iris/Models.swift:236-240` (`UsageMetadata`)
- Modify: `Sources/iris/AnthropicClient.swift:225-231` (non-stream usage)
- Modify: `Sources/iris/AnthropicStreamMapper.swift:21-23` (`message_start`)
- Modify: `Sources/iris/OpenAIClient.swift:244-249`, `Sources/iris/OpenAIStreamMapper.swift:43-46`
- Modify: `Sources/iris/LLMStream.swift:100-105` (merge) and `:135` (response build)
- Modify: `docs/jobs.md` (budgets paragraph)
- Test: `Tests/irisTests/UsageCacheCountTests.swift` (new), plus a case in each existing `*StreamMapperTests.swift`

**Interfaces:**
- Produces: `UsageMetadata.cacheReadTokens: Int?`, `UsageMetadata.cacheWriteTokens: Int?`, and `UsageMetadata.withTotal() -> UsageMetadata`, which fills a nil `totalTokenCount` from prompt + candidates when both are known.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import iris

@Suite("Usage cache counts (5a)")
struct UsageCacheCountTests {
    @Test("Anthropic non-stream: prompt is input + read + write, and the cache fields are set")
    func anthropicNonStream() throws {
        let json: [String: Any] = ["content": [["type": "text", "text": "hi"]],
                                   "usage": ["input_tokens": 10, "cache_read_input_tokens": 900,
                                             "cache_creation_input_tokens": 50, "output_tokens": 7]]
        let r = try AnthropicClient.parseResponse(json)
        #expect(r.usageMetadata?.promptTokenCount == 960)
        #expect(r.usageMetadata?.cacheReadTokens == 900)
        #expect(r.usageMetadata?.cacheWriteTokens == 50)
        #expect(r.usageMetadata?.totalTokenCount == 967, "total filled from prompt + output: budgets read it")
    }

    @Test("a provider that reports no cache fields yields nil, not zero")
    func absentIsNil() throws {
        let json: [String: Any] = ["content": [["type": "text", "text": "hi"]],
                                   "usage": ["input_tokens": 10, "output_tokens": 7]]
        let r = try AnthropicClient.parseResponse(json)
        #expect(r.usageMetadata?.cacheReadTokens == nil)
        #expect(r.usageMetadata?.cacheWriteTokens == nil)
    }

    @Test("Gemini: cachedContentTokenCount decodes into cacheReadTokens; write stays nil")
    func gemini() throws {
        let data = #"{"promptTokenCount":1000,"cachedContentTokenCount":800,"candidatesTokenCount":5,"totalTokenCount":1005}"#.data(using: .utf8)!
        let u = try JSONDecoder().decode(UsageMetadata.self, from: data)
        #expect(u.cacheReadTokens == 800)
        #expect(u.cacheWriteTokens == nil)
    }

    @Test("OpenAI: prompt_tokens_details.cached_tokens is the read count")
    func openAI() throws {
        let json: [String: Any] = ["choices": [["message": ["role": "assistant", "content": "hi"]]],
                                   "usage": ["prompt_tokens": 1000, "completion_tokens": 5, "total_tokens": 1005,
                                             "prompt_tokens_details": ["cached_tokens": 768]]]
        let r = try OpenAIClient.parseResponse(json)
        #expect(r.usageMetadata?.cacheReadTokens == 768)
        #expect(r.usageMetadata?.promptTokenCount == 1000)
    }

    @Test("withTotal fills a missing total and leaves a reported one alone")
    func withTotal() {
        #expect(UsageMetadata(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: nil).withTotal().totalTokenCount == 7)
        #expect(UsageMetadata(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 9).withTotal().totalTokenCount == 9)
        #expect(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 4, totalTokenCount: nil).withTotal().totalTokenCount == nil)
    }
}
```

If `parseResponse` does not exist as a static on either client, Step 3 extracts it from the existing inline parsing (`AnthropicClient.swift:~190-231`, `OpenAIClient.swift:~205-250`) without changing what it does. Add to `AnthropicStreamMapperTests` a case whose `message_start` usage carries `"cache_read_input_tokens":900,"cache_creation_input_tokens":50`, expecting a `.usage` event with prompt 960, read 900 and write 50. Add to `OpenAIStreamMapperTests` a usage chunk with `prompt_tokens_details.cached_tokens`.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-filter.sh UsageCacheCountTests`
Expected: compile failure (`cacheReadTokens` does not exist).

- [ ] **Step 3: Implement**

`Models.swift`:

```swift
struct UsageMetadata: Codable, Sendable {
    var promptTokenCount: Int?
    var candidatesTokenCount: Int?
    var totalTokenCount: Int?
    /// Tokens served from the provider's prompt cache. nil means the provider did not say, which
    /// is not the same as a miss (5a §0.4).
    var cacheReadTokens: Int? = nil
    /// Tokens written to the cache this call (Anthropic only). nil when not reported.
    var cacheWriteTokens: Int? = nil

    // Gemini's own key for the read count, so its usage decodes directly.
    enum CodingKeys: String, CodingKey {
        case promptTokenCount, candidatesTokenCount, totalTokenCount
        case cacheReadTokens = "cachedContentTokenCount"
        case cacheWriteTokens
    }

    /// `totalTokenCount` as prompt + output when the provider left it out. The job budgets read
    /// the total, and Anthropic never sends one, so its runs were charged nothing (5a).
    func withTotal() -> UsageMetadata {
        guard totalTokenCount == nil, let p = promptTokenCount, let c = candidatesTokenCount else { return self }
        var u = self; u.totalTokenCount = p + c; return u
    }
}
```

The memberwise init keeps its three-argument form because the new fields have defaults. Anthropic (both paths) reads `input_tokens`, `cache_read_input_tokens` and `cache_creation_input_tokens`, sets `promptTokenCount` to their sum (treating an absent part as 0 **only** in the sum), and sets the two cache fields from the raw values, nil when absent. OpenAI (both paths) reads `(usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int`. `LLMStream`'s merge adds:

```swift
merged.cacheReadTokens = Self.maxOf(merged.cacheReadTokens, incoming.cacheReadTokens)
merged.cacheWriteTokens = Self.maxOf(merged.cacheWriteTokens, incoming.cacheWriteTokens)
```

At `:135`, build the response with `usageMetadata: usage?.withTotal()`. On Anthropic's non-stream path, apply `.withTotal()` when assigning.

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-filter.sh UsageCacheCountTests` → 5 tests pass; `scripts/test-filter.sh AnthropicStreamMapperTests`, `OpenAIStreamMapperTests` and `GeminiStreamMapperTests` → all pass, with the counts quoted.

- [ ] **Step 5: Budget test and docs**

Add to the existing job budget tests (`grep -rln "pauseBudget" Tests/irisTests`) one case: a run whose client returns Anthropic-shaped usage with no total is charged `prompt + output` to `tokensToday`. Then update `docs/jobs.md`'s budgets paragraph to say: "Budgets count every token sent, including tokens a provider served from its prompt cache; before 5a an Anthropic run was charged nothing because Anthropic reports no total."

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/Models.swift Sources/iris/AnthropicClient.swift Sources/iris/AnthropicStreamMapper.swift Sources/iris/OpenAIClient.swift Sources/iris/OpenAIStreamMapper.swift Sources/iris/LLMStream.swift docs/jobs.md Tests/irisTests/
git commit -m "feat(usage): record cache reads and writes per provider, and a total Anthropic never sends (5a)"
```

### Task 2: Cache counts in `TokenUsage`, `ModelCallRecord` and `/tokens`

**Files:**
- Modify: `Sources/iris/AppState.swift:41-61` (`TokenUsage`), `:1716-1722` (`updateTokenUsage`), `:3217-3227` (`handleTokensCommand`)
- Modify: `Sources/iris/PerformanceProfiler.swift:44-62` (`ModelCallRecord`)
- Modify: `Sources/iris/iris.swift:~1639-1650` and `Sources/iris/PerfLadder.swift:~46-50` (record the new fields)
- Test: `Tests/irisTests/UsageCacheCountTests.swift` (extend)

**Interfaces:**
- Consumes: `UsageMetadata.cacheReadTokens` and `cacheWriteTokens` (Task 1).
- Produces: `TokenUsage.cacheReadTokenCount: Int` and `cacheWriteTokenCount: Int` (default 0, summed; a nil read adds 0), plus `ModelCallRecord.cacheReadTokens: Int?` and `cacheWriteTokens: Int?` (default nil).

- [ ] **Step 1: Failing tests**

```swift
@Test("a TokenUsage saved before 5a decodes, with zero cache counts")
func oldTokenUsageDecodes() throws {
    let old = #"{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7}"#.data(using: .utf8)!
    let u = try JSONDecoder().decode(TokenUsage.self, from: old)
    #expect(u.cacheReadTokenCount == 0 && u.cacheWriteTokenCount == 0 && u.promptTokenCount == 5)
}

@Test("a ModelCallRecord written before 5a decodes, with nil cache counts")
func oldModelCallRecordDecodes() throws {
    let old = #"{"round":0,"model":"m","latencyMs":1,"promptTokens":5,"outputTokens":2,"returnedToolCalls":false}"#.data(using: .utf8)!
    let r = try JSONDecoder().decode(ModelCallRecord.self, from: old)
    #expect(r.cacheReadTokens == nil && r.cacheWriteTokens == nil)
}

@MainActor @Test("updateTokenUsage sums cache counts")
func accumulates() {
    let app = AppState()
    let id = UUID(); app.createNewConversation(id: id)
    app.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 100, candidatesTokenCount: 1, totalTokenCount: 101, cacheReadTokens: 80, cacheWriteTokens: 10))
    app.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 100, candidatesTokenCount: 1, totalTokenCount: 101, cacheReadTokens: nil, cacheWriteTokens: nil))
    let u = app.conversations.first { $0.id == id }!.tokenUsage
    #expect(u.cacheReadTokenCount == 80 && u.cacheWriteTokenCount == 10)
}
```

- [ ] **Step 2: Run to verify failure:** `scripts/test-filter.sh UsageCacheCountTests`. Expected: compile failure.

- [ ] **Step 3: Implement.**
  - `TokenUsage`: add `var cacheReadTokenCount: Int = 0` and `var cacheWriteTokenCount: Int = 0`, with `CodingKeys` cases, and in `init(from:)` decode each as `try c.decodeIfPresent(Int.self, forKey: .cacheReadTokenCount) ?? 0` (and the same for write). If `TokenUsage` has an explicit `CodingKeys`, add the cases; if it relies on synthesis, add an explicit enum with all five.
  - `updateTokenUsage`: add `+= usage.cacheReadTokens ?? 0` for read, and the same for write.
  - `ModelCallRecord`: add `public var cacheReadTokens: Int? = nil` and `public var cacheWriteTokens: Int? = nil`. Synthesized decoding of Optionals already tolerates absence, and the pre-5a test pins that. Extend `init` with defaulted parameters.
  - Both record sites pass `response.usageMetadata?.cacheReadTokens` and `cacheWriteTokens`.
  - `/tokens` adds two lines:

```swift
- **Cache Read Tokens:** \(usage.cacheReadTokenCount)
- **Cache Write Tokens:** \(usage.cacheWriteTokenCount)
```

- [ ] **Step 4: Run to verify pass:** `scripts/test-filter.sh UsageCacheCountTests`, 8 tests. Then run `--perf compare` against a committed baseline in `perf/baselines/`: `swift run -c release iris --perf compare perf/baselines/<any>.json perf/baselines/<same>.json` exits 0 (Review Focus 5).

- [ ] **Step 5: Commit:** `feat(usage): cache counts on conversations, perf records and /tokens (5a)`

### Task 3: The `caching` perf suite and a per-round cache table

**Files:**
- Modify: `Sources/iris/Scenario.swift` (add `seedFacts`)
- Modify: `Sources/iris/ScenarioRunner.swift` (seed before the first turn)
- Modify: `Sources/iris/PerfReport.swift` (cache columns plus a per-round table for multi-turn scenarios)
- Create: `perf/suites/caching.json` and `perf/prompts/caching/six-turns.json`
- Modify: `perf/README.md` (a paragraph on the suite)
- Test: `Tests/irisTests/PerfReportCacheTests.swift` (new)

**Interfaces:**
- Consumes: `ModelCallRecord.cacheReadTokens` and `cacheWriteTokens` (Task 2).
- Produces: `Scenario.seedFacts: [String]?` (decodeIfPresent; nil means none), and `PerfReport.cacheTable(_ s: PerfScenarioResult) -> [String]`.

- [ ] **Step 1: Failing test.** Build a `PerfScenarioResult` fixture with one rung-4 repetition of 3 turns: turn 1 has one round `(prompt 1000, read nil, write nil)`, turn 2 has two rounds `(1200, 900, 250)` and `(1400, 1150, 200)`, and turn 3 has one round `(1500, 1100, 300)`. Assert that `PerfReport.render` contains the header `| turn | round | prompt | cache read | cache write | uncached |` and these rows:
  - `| 1 | 0 | 1000 | — | — | 1000 |`: an unknown read counts as uncached, shown as `—`.
  - `| 2 | 1 | 1400 | 1150 | 200 | 50 |`: uncached = prompt − read − write.
- [ ] **Step 2: Run:** `scripts/test-filter.sh PerfReportCacheTests`. Expected: fail.
- [ ] **Step 3: Implement.**
  - For each scenario whose top rung has any `turns` with `modelCalls`, render the per-round table from the **first** repetition (a table per repetition would be noise; the medians stay in the existing table).
  - Add median `cache read` and `uncached` columns to the existing rung table.
  - `seedFacts`: in `ScenarioRunner`, before turn 1, call `FactStoreManager.shared.addFact(content:)` for each, and ignore errors.
- [ ] **Step 4: Suite files.**

`perf/suites/caching.json`:

```json
{ "name": "caching", "lane": "real", "repetitions": 2, "pauseMs": 2000, "rungs": [4],
  "scenarios": ["perf/prompts/caching/six-turns.json"] }
```

`perf/prompts/caching/six-turns.json`: facts that only turn 2 matches; turn 3 uses a tool; turn 4 matches nothing.

```json
{ "name": "six-turns", "clientMode": "real", "tier": "medium",
  "seedFacts": ["The perf-probe project codename is BLUEHERON.", "BLUEHERON ships on Thursdays."],
  "turns": [
    { "prompt": "Say hello in five words." },
    { "prompt": "What do you know about the BLUEHERON codename? One sentence." },
    { "prompt": "Count the files in /tmp with a shell command and tell me the number." },
    { "prompt": "Name a prime number between 20 and 30." },
    { "prompt": "Summarize this conversation in one sentence." },
    { "prompt": "Reply with the single word: done." } ] }
```

- [ ] **Step 5: Run to verify pass:** `scripts/test-filter.sh PerfReportCacheTests`. Also run `swift run iris --perf run perf/suites/caching.json --fake-only`; it must reject the suite with a clear error, since the suite is real-lane only.
- [ ] **Step 6: Commit:** `feat(perf): caching suite with seeded facts and a per-round cache table (5a)`

### Task 4: Baseline, on main after PR A

Not a code task. It runs after PR A merges and before PR B's first commit.

- [ ] **Step 1:** On main, with PR A merged: `swift build -c release && .build/release/iris --perf run perf/suites/caching.json --out perf/runs/`. Do this once per configured provider (Anthropic required; Gemini and OpenAI if configured).
- [ ] **Step 2:** `--perf report` on each run. Copy the per-round tables into spec §3.1 under "Baseline", with provider, model, commit and date.
- [ ] **Step 3:** Commit to PR B's branch as its first commit: `docs(spec): 5a baseline measurements`

---

## PR B: behaviour

### Task 5: Sorted-key request encoding

**Files:**
- Modify: `Sources/iris/AnthropicClient.swift:171` and `:114`, `Sources/iris/OpenAIClient.swift:185`, `:126` and `:53/:74`, `Sources/iris/LLMClient.swift:112`
- Test: `Tests/irisTests/RequestByteStabilityTests.swift` (new)

- [ ] **Step 1: Failing test.** For each client, build **two separate** `GeminiRequest` values from the same inputs: a tool whose `Schema.properties` has at least eight keys inserted in opposite orders, and a history containing a function call whose `args` has at least eight keys. Assert `makeURLRequest(...).httpBody` is byte-identical. A single value encoded twice can pass by luck, so the test must build two dictionaries.

```swift
@Test("Anthropic: two equal requests built separately encode to identical bytes")
func anthropicStable() throws {
    let a = try AnthropicClient.makeURLRequest(request: Self.request(order: .forward), model: "m", apiKey: "k", stream: false).httpBody
    let b = try AnthropicClient.makeURLRequest(request: Self.request(order: .reversed), model: "m", apiKey: "k", stream: false).httpBody
    #expect(a == b)
}
```

Write the same test for `OpenAIClient.makeURLRequest`, and for Gemini through its request builder in `LLMClient.swift` (build the `URLRequest` without sending it; if the builder is private, make it `static` internal).
- [ ] **Step 2: Run:** `scripts/test-filter.sh RequestByteStabilityTests`. Expected: at least one failure. Record which clients failed; that is evidence for the spec.
- [ ] **Step 3: Implement.** Every `JSONSerialization.data(withJSONObject:)` on the request path gains `options: [.sortedKeys]`, and every `JSONEncoder()` on the request path sets `outputFormatting = [.sortedKeys]`. The schema re-encode at `:114`/`:126` round-trips through JSONSerialization, so sorting the final body is sufficient, but sort both for clarity.
- [ ] **Step 4: Run to verify pass**, 3 tests, then run the full `swift test`.
- [ ] **Step 5: Commit:** `fix(llm): encode every request with sorted keys so equal requests are equal bytes (5a)`

### Task 6: The turn-context block

**Files:**
- Create: `Sources/iris/TurnContext.swift`
- Modify: `Sources/iris/iris.swift:1100-1162` (stop appending facts and the peer count to the system prompt), `:1543`, `:1600`, `:1803` (attach per round)
- Test: `Tests/irisTests/TurnContextTests.swift` (new)

**Interfaces:**
- Produces:

```swift
/// Per-turn content that must not sit in the cached prefix (5a §0.2). Built once per turn,
/// attached to the turn's own user entry in every round's request, never written to history.
struct TurnContext: Equatable, Sendable {
    struct Section: Equatable, Sendable { var heading: String; var body: String }
    var sections: [Section]
    var isEmpty: Bool { sections.isEmpty }
    /// `<turn_context>\n# heading\nbody\n\n# heading\nbody\n</turn_context>`
    func rendered() -> String
    /// `contents` with the block inserted as the leading part of `contents[anchor]`, when the
    /// anchor is in range, is a user entry, and its text still equals `anchorText`. Otherwise
    /// `contents` unchanged: a block on the wrong message is worse than none.
    func applied(to contents: [Content], anchor: Int, anchorText: String?) -> [Content]
}
```

- [ ] **Step 1: Failing tests (unit):**
  - `rendered()` output for two sections.
  - `applied` inserts at the anchor only.
  - `applied` with an anchor out of range, on a model entry, or whose text changed returns the input unchanged (Review Focus 2).
  - An empty context returns the input unchanged, byte-equal.
- [ ] **Step 2: Failing tests (engine).** Use `CapturingLLMClient` with a fact store seeded so the input matches, plus a scripted tool call so the turn has two rounds (use the existing scripted-client helper; see `grep -rln "ScriptedLLMClient\|scriptedResponses" Tests/irisTests`):
  1. Every captured request's turn entry starts with a `<turn_context>` part containing `# Mid-Term Fact Store Memory (JIT Context)`, and the system instruction does **not** contain that heading.
  2. The block is byte-identical in round 1 and round 2.
  3. A steer queued between rounds (`AppState.enqueueSteer` or the existing steer helper) leaves the block on the original entry (Review Focus 3).
  4. After the turn, `conversation.history` contains no part whose text contains `<turn_context>`. The same holds after `ConversationStore` save and reload (Review Focus 4).
  5. A turn whose input matches no fact and has no peers sends a request whose turn entry has exactly the parts that were saved.
- [ ] **Step 3: Run:** `scripts/test-filter.sh TurnContextTests`. Expected: fail.
- [ ] **Step 4: Implement.**
  - In `processInputBody`, replace the fact and peer-count appends (`iris.swift` ~1136-1141 and ~1157-1162) with sections on a local `var turnContext = TurnContext(sections: [])`, e.g. `turnContext.sections.append(.init(heading: "Mid-Term Fact Store Memory (JIT Context)", body: factString))`, using the same heading strings and body text as today.
  - After the PreCompress hook (~1536), compute `let turnAnchor = history.lastIndex { $0.role == "user" }` and `let turnAnchorText = turnAnchor.flatMap { history[$0].parts.first?.text }`.
  - Define `func requestContents(_ h: [Content]) -> [Content] { turnAnchor.map { turnContext.applied(to: h, anchor: $0, anchorText: turnAnchorText) } ?? h }` and use it at `:1543`, `:1600` and `:1803` in place of the bare `history`.
  - Subagent and evaluator turns go through the same function, so they get the same behaviour.
- [ ] **Step 5: Run to verify pass**, all 9 tests with the count quoted, then the full `swift test`.
- [ ] **Step 6: Commit:** `feat(engine): per-turn content rides this turn's entry, not the system prompt (5a)`

### Task 7: `USER.md` and `AGENTS.md` refreshed on change

**Files:**
- Modify: `Sources/iris/iris.swift:1100-1134`, and `ensureSystemPrompt` (`:248-263`)
- Test: `Tests/irisTests/TurnContextTests.swift` (extend)

**Interfaces:**
- Produces: `IrisEngine` private state `profileStamp: (path: String, modified: Date?)?` and `agentsStamp: [String: Date?]` (keyed by workspace path), plus `func invalidateUserProfile()`, called by the `update_user_profile` handler.

- [ ] **Step 1: Failing tests:**
  1. Two consecutive turns with an unchanged `USER.md` call the guard's sanitize for `user_profile` once, not twice. Count through the existing `InjectionGuard` test seam; if there is none, count through a test-only counter on `IrisEngine`.
  2. After `update_user_profile`, the next turn's system prompt contains the new profile text.
  3. Touching `AGENTS.md`'s modification date in the bound workspace causes a re-read on the next turn.
  4. Two turns with no changes send byte-identical `systemInstruction`.
- [ ] **Step 2: Run:** `scripts/test-filter.sh TurnContextTests`. Expected: fail.
- [ ] **Step 3: Implement.**
  - Keep the guarded profile and `AGENTS.md` text in engine-level caches, keyed by file path and modification date (`FileManager.attributesOfItem(atPath:)[.modificationDate]`).
  - Rebuild the section only when the key changes.
  - The composed prompt (base + profile + agents) is cached per (workspace path, stamps).
  - `invalidateUserProfile()` clears the profile stamp.
- [ ] **Step 4: Run to verify pass**, then the full `swift test`.
- [ ] **Step 5: Commit:** `perf(engine): re-read USER.md and AGENTS.md only when they change (5a)`

### Task 8: Agent-facing text and docs (invariant 9)

- [ ] **Step 1:** Search, and read every hit:

```bash
grep -rn -i "system prompt" Sources/iris/*.swift | grep -i -E "fact|jit|memory|peer|session"
grep -rn "JIT Context\|Mid-Term Fact Store" Sources docs README.md
grep -rn -i "manage_fact" Sources/iris/ToolExecutor.swift Sources/iris/iris.swift
grep -rn -i "other session.*active\|sessions are active" Sources docs README.md
grep -rn -i "system prompt" docs/markdown_memory_design.md docs/holographic_memory_design.md docs/headless_profiling.md README.md
```

- [ ] **Step 2:** Correct every sentence that places the fact block or the peer count in the system prompt so that it says "this turn's context". Leave the heading text as it is (spec §2).
- [ ] **Step 3:** `swift test` passes. Commit: `docs: fact memory and the peer count now arrive in the turn's context (5a)`

### Task 9: The `tool_result` breakpoint, only if the rounds show it

- [ ] **Step 1:** Run the `caching` suite on Anthropic on this branch (Tasks 5–8 in).
- [ ] **Step 2:** Read turn 3 in the per-round table. If round 1's cache read is **at least** round 0's prompt minus 5%, the skip costs nothing: record that in spec §3.1 and skip to Task 10.
- [ ] **Step 3 (only if Step 2 fails):**
  - Failing test in `StreamingClientTests` (or a new `AnthropicCacheBreakpointTests`): a request whose last message ends in a `tool_result` block carries `cache_control` on that block.
  - In `markLastContentBlock` (`AnthropicClient.swift:82-91`), drop the `tool_result` exclusion.
  - Rerun the suite and confirm Step 2 now passes.
  - Commit: `fix(anthropic): cache through tool-result rounds (5a)`

### Task 10: After-measurement and the tool-list experiment

- [ ] **Step 1:** Run the `caching` suite on each configured provider and add the tables to spec §3.1 under "After 5a".
- [ ] **Step 2: Check the pass criteria** (spec §3, Anthropic, turns 3–6).
  - For each turn k, compute tools + system + history up to the end of turn k−2 from the captured request, or approximate it with round-0 prompt tokens minus turn k−1 and turn k's entry.
  - Check cache read ≥ 95% of that prefix.
  - Record pass or fail per turn. **Stop and report if any turn fails**; do not tune thresholds to fit.
- [ ] **Step 3: Tool-list experiment.**
  - Temporarily declare `manage_fact` on every turn (a local, uncommitted change at `iris.swift` ~1253).
  - Run the suite on Anthropic.
  - Compare the sum of uncached plus cache-write tokens over six turns against Step 1's number.
  - Record both in §3.1, and revert the local change.
- [ ] **Step 4:** Commit the measurements: `docs(spec): 5a measurements, pass criteria and the tool-list experiment`. PR B's description quotes the before/after table and the experiment's result, and says whether invariant 6 should change in 5b.
