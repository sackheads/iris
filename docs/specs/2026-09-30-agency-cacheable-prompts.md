# Agency deliverable 5a: Cacheable, measurable prompts

Status: **proposed** (2026-09-30). Deliverable 5 of #187 (the main conversation) is split in two. 5a, this document, makes every conversation's prompt cacheable and makes caching measurable. 5b, the main conversation itself (pin rules, briefing, `search_conversations`/`read_conversation`, `/new`, anchoring), gets its own spec once 5a's numbers are in. The split exists because 5b's briefing is volatile per-turn content, and designing where it sits would mean designing against a prompt cache nobody can measure and that the code suggests is already failing.

## Why

A survey of the request path (2026-09-30) found four things, each of which can defeat prefix caching. The survey inferred that Iris got little or no provider-side cache reuse on any provider. **The baseline (§3.1) corrected that for Anthropic.** Within one process the tool declarations encode identically, so item 1 did not break Anthropic's cache within a conversation, and non-fact turns read 97–100% of their prompt from cache. What the measurement confirmed is item 3: a turn whose fact block changes forces a full cache re-write of the whole prompt (~20k tokens), which on Claude Opus 5.5 costs about 25× a cached turn (writes 1.25× input, reads 0.05×). Gemini's implicit cache showed no turn-to-turn reuse at all. With any-token fact matching, most real turns are fact turns, so item 3 is the cost that matters.

1. **Tool declarations are not byte-stable.** Tool schemas carry Swift dictionaries (`Schema.properties`) and no client encodes with sorted keys. Measured: one dictionary's contents, encoded 200 times in one process, produced 5–7 distinct byte sequences. Anthropic caches in the order tools → system → messages, so a tool block that changes bytes invalidates everything after it.
2. **The tool list changes membership per turn.** `manage_fact` is declared only when the fact store matched the input (`iris.swift` ~1253), the peer tools only when peers exist, and the goal and ladder tools by state. Invariant 6 gates these for token cost, a rule measured (#129, #144) with no working cache.
3. **The system prompt changes almost every turn.** The cached base (SOUL, skills, SYSTEM.md, rules; `ensureSystemPrompt`, `iris.swift` ~248) is copied, and then per-turn content is appended (`iris.swift` ~1100–1162): `USER.md` re-read, workspace `AGENTS.md`, the fact-store block (`# Mid-Term Fact Store Memory (JIT Context)`, selected by `factStore.search(query: input)`), and the peer-session count. On Anthropic a changed system block misses the whole history.
4. **Nothing is measured, and one number is wrong.** `UsageMetadata` (`Models.swift` ~236) has prompt, candidates and total only. Anthropic's `input_tokens` excludes cache reads and writes, so the prompt tokens Iris records for Anthropic under-report whenever caching works. Gemini's `cachedContentTokenCount` and OpenAI's `prompt_tokens_details.cached_tokens` are dropped.

## 0. Decided

Each decision names its default and why; the cost of being wrong is what a reviewer should weigh.

1. **Every request is encoded with sorted keys.** `JSONEncoder.outputFormatting` gains `.sortedKeys` in all three clients, and any `JSONSerialization` on the request path passes `.sortedKeys`. The one that matters most is the final serialisation of the body: `AnthropicClient` round-trips each schema through `JSONEncoder` → `JSONSerialization` → dictionary mutation, so sorting the encoder alone is not enough. The test builds the body the way the client does (`makeURLRequest`), never by encoding a `GeminiRequest`. *Why:* byte-stable declarations are the precondition for any prefix cache; the order the model sees keys in carries no meaning. *Cost if wrong:* none found; sorting a few hundred keys per request is noise.
2. **Per-turn content leaves the system prompt for a turn-context block on this turn's user entry, in the request only.** The block is a separate leading text part, `<turn_context>…</turn_context>`, on the user entry that started the turn. It is built once per turn, sent unchanged on every model round of that turn (including rounds after mid-task steers), and never written to `history`. On the next turn that entry is sent plain. In 5a it carries the fact-store block and the peer-session count; 5b adds the briefing. *Why:* the prefix before it (tools, system, all older history) is then stable across turns. The cost is bounded: last turn's user entry and its rounds are re-sent without the block, so one turn's worth is uncached per turn, and that does not grow with history. The alternatives were weighed with the owner: persisting the block into history is fully cache-stable but grows history by a stale fact dump per turn and shows the model outdated copies; keeping it in the system prompt is the status quo that misses everything. *Cost if wrong:* the fact block now arrives in the user role, not the system role. That is lower authority, which is the safer direction for model-selected memory, but a model may weigh it differently; the suite in §3 runs the seeded fact turns to catch a behaviour change.
3. **`USER.md` and workspace `AGENTS.md` stay in the system prompt but stop being re-read every turn.** Both are cached with the base and refreshed when they change: `USER.md` on `update_user_profile` or when its modification date moves, `AGENTS.md` when the conversation's workspace changes or its modification date moves. The guard pass runs on refresh, not per turn. *Why:* they change when someone edits them, not per turn. Re-reading and re-guarding each turn buys nothing and, where the guard's output is not deterministic, would itself change bytes. *Cost if wrong:* an edit made outside Iris is picked up at the next turn's date check, as today.
4. **Cache counts are recorded per provider, and unknown is not zero.** `UsageMetadata` gains `cacheReadTokens: Int?` and `cacheWriteTokens: Int?`. Anthropic: read = `cache_read_input_tokens`, write = `cache_creation_input_tokens`, and `promptTokenCount` becomes input + read + write, so it means the same thing on every provider. Gemini: read = `cachedContentTokenCount`, write nil. OpenAI: read = `prompt_tokens_details.cached_tokens`, write nil. A field the provider did not report is nil and renders as `—`. `totalTokenCount` is filled as prompt + output whenever the provider omits it: Anthropic sends no total, and the job budgets read the total, so until now an Anthropic run was charged nothing against any budget. After 5a every provider charges every token sent, cached or not. *Why:* a zero would read as a miss, and a budget that reads nil never trips. Gemini and OpenAI budgets already counted cached tokens, because their prompt counts include them; Anthropic was the outlier twice over. **Consequences:** the default limits (200k per run, 1M per job per day, 3M global) were sized without Anthropic traffic, and after 5a a turn that re-reads a 40k prefix five times counts 200k, so they are re-checked against the suite's figures before 5b. "Tokens today" in `/jobs` and `docs/jobs.md` now means tokens *sent*, not billed, and `JobLimits`' comment calling a budget a bound on spend is corrected to say so. A billed-weight figure (reads at 0.1×, writes at 1.25×) is a later slice. The sidebar and `/tokens` start showing real Anthropic figures where they showed 0, and the README's token section says so. *Cost if wrong:* none; an older record simply has no cache columns.
5. **The counts reach the places tokens are already read.** `ModelCallRecord` (perf run JSON) and the conversation's `tokenUsage` gain the two fields, both decoded with `decodeIfPresent` (invariant 1: old run files and old conversations must still load, and `--perf compare` must accept a baseline written before this change). `/tokens` shows cache read and write beside prompt tokens; `--perf report` adds columns for cache read, cache write and uncached prompt tokens, where uncached = prompt − read − write.
6. **The tool list is measured, not changed, in 5a.** Declaration order is already fixed by construction; only membership varies, and not only `manage_fact`: the peer tools appear and disappear whenever another session starts or ends. The experiment declares every state-gated tool (`manage_fact` and the peer tools) on every turn, and its conclusion is meant to generalise to state-gated declarations. Whether a gated tool (e.g. `manage_fact`) should instead be declared on every turn is decided by the §3 experiment, and invariant 6 is amended only if the numbers say so. *Why:* invariant 6 was measured without a cache; with one, a stable declaration costs a cache read while a flapping one costs a full miss. Which one wins depends on sizes this deliverable is the first to measure. *Cost if wrong:* 5a lands with tool flapping still costing misses; the experiment's report says how much.

7. **Invalidators this design does not remove, named so nobody mistakes them for regressions.** `stripInlineDataFromHistory` (`iris.swift` ~1899) removes attachments from history at the end of a turn, so a turn that carried an image is re-sent next turn without it. That entry is turn k−1's, inside the window already expected to be uncached, so the k−2 guarantee holds, but an image's payload is paid for once and never cached. Changing thinking or effort settings invalidates the message cache (and on some models tools and system); the client sends neither today, and whoever adds them should know. On Claude Opus 5.5 and Fable 5.1 a history edit (including this design's turn-context block, dropped from its entry on the next turn) also invalidates every later thinking block, and on accounts created on or after 2026-08-31 replaying one is a 400. That is harmless today only because Iris discards Anthropic thinking blocks and never replays them; #314 tracks replaying them with an append-only history (an appended `clear_at` system message for the turn context on Anthropic). A `BeforeModel` hook that rewrites the request (`iris.swift` ~1609–1613) is outside Iris's control. And the cache has a TTL (5 minutes by default, measured start to start): a reply after that misses everything. Whether the system and tools markers should use the 1-hour TTL at double the write price is a decision for 5b or later, with the measured sizes in hand.

## 1. The request path

`processInputBody` records which `history` index holds the turn's user entry (the one appended at `iris.swift` ~1095, whether typed, a system event or a goal reprompt) and builds the turn context once. Request construction (`iris.swift` ~1543) copies `history`, inserts the block as the leading text part of that one entry, and hands the copy to the client. Persistence, the steer inbox, event delivery and hooks see `history`, never the copy, except the BeforeModel hook, which already receives the request and so sees the block. A turn whose context is empty (no fact matches, no peers) adds no part at all, so its request is byte-identical to one with no block mechanism.

Subagent and evaluator engines take the same path: their per-turn additions move into the block the same way.

Anthropic breakpoints stay four: last tool, system, and the last block of the penultimate and last messages (`AnthropicClient.swift` ~78–146). `markLastContentBlock` skips a message whose last block is a `tool_result` (`AnthropicClient.swift` ~85). The API accepts `cache_control` on `tool_result` blocks, so the skip is an artifact, and its cost follows from how the breakpoints work: a round ending in tool results writes its cache entry at the assistant's `tool_use`, so the tool results are re-sent uncached on the next round and again on the next turn. The fix (drop the exclusion) is in scope unconditionally, with its own test; the suite confirms it.

The turn-context part is its own text block on Anthropic (`AnthropicClient.swift` ~24–26), so the entry becomes `[text(block), text(user)]` and the message breakpoint lands on the user's text, keeping the block inside the cached range of the next round.

## 2. Agent-facing text

The fact-store heading and anything else telling the model where its memory appears (`# Mid-Term Fact Store Memory (JIT Context)`, the `manage_fact` description, the SYSTEM.md or memory docs if they name the system prompt as its location) is searched and updated to say "this turn's context" (invariant 9). `docs/markdown_memory_design.md`, `docs/headless_profiling.md` and README's memory section are searched for the same claim. The heading text inside the block stays as it is, so the model's existing guidance still names it. Dated plans and reviews (`docs/superpowers/plans/2026-09-17-performance-evaluation-suite.md`, `docs/reviews/2026-09-17-tool-eagerness-analysis.md`) describe the system prompt as it was and are left as history.

The perf ladder's rungs 2 and 3 replay the first request's captured system prompt (`PerfLadder.swift` ~22–38). From 5a on that prompt no longer holds the fact block or the peer count, so those rungs measure the stable prefix only and are not comparable with pre-5a baselines; `perf/README.md` says so. Anthropic's recorded prompt tokens also jump across the 5a boundary (they now include cached tokens), so `--perf compare` across it compares uncached tokens, and the report says why.

## 3. Verification

**The `caching` suite** (`perf/suites/caching.json`, run at rung 4, a full Iris turn with guards off): a scripted conversation of six user turns on the real lane, run once per configured provider. Scenarios gain `seedFacts` so the fact-store turns are deterministic. Turn 2 matches the fact store and turn 4 does not, so the block appears, changes and disappears. Turn 3 calls a tool, so it has more than one round. Each round records prompt, cache read, cache write and uncached tokens.

**Baseline first.** The suite runs on main after 5a's instrumentation PR (which changes no request byte) and before any behaviour change lands, and the spec records the numbers in §3.1 below. That turns the "Why" section's inference into a measurement.

**Why k−2.** At turn k's first round the request differs from turn k−1's at exactly one place before the new entry: turn k−1's user entry, which carried the block then and is sent plain now. Everything before it hits, and exactly there, because turn k−1's first round put its penultimate-message breakpoint on turn k−2's final assistant message. So a turn's read is the prefix through the end of turn k−2 as a floor. When turn k−1's block was empty, its entry is byte-identical in both requests and the read extends further. In the suite that is turn 5, since turn 4 matches no fact, so turn 5 reading *more* is expected, not an anomaly. All criteria assume the next turn arrives within the cache TTL, which a scripted suite does.

**Pass criteria, Anthropic, turns 3–6.** Pass or fail is decided by checks that need only usage fields:
- at each turn's first round, cache read ≥ the previous turn's first-round cache read (the prefix never collapses);
- within a turn, each round's read ≥ the previous round's read + write;
- at each turn's first round, uncached tokens ≤ turn k−1's output tokens plus the tool results it read plus a fixed allowance for two entries, bounded generously.

The 95% figure is reported alongside them from exact sizes: the suite writes each round's request body, and the prefix through turn k−2 is counted with the provider's token-counting endpoint. Read ≥ 95% of that prefix is the target. The dumps are also what gets diffed to find a miss. Gemini and OpenAI: the same rung reports their automatic-cache counts; they are recorded, not graded, because Iris does not control those caches.

**Tool-list experiment:** the suite runs twice more on Anthropic, once as shipped and once with `manage_fact` declared on every turn. The report compares total uncached plus cache-write tokens across the six turns. If always-declared is cheaper, the plan for 5b amends invariant 6 with the numbers; if not, invariant 6 stands with this measurement cited.

**Unit tests:**
1. Two encodings of the same request (built separately, not the same value twice) are byte-identical, for each client.
2. The block appears in the request copy on the turn's entry and never in `history`, including after a save/load round trip.
3. The block is identical across every round of a turn, including a round after a mid-task steer.
4. A turn with no facts and no peers adds no part; its request bytes equal those of the same history without the mechanism.
5. `USER.md` is not re-read on a turn where its modification date is unchanged, and is re-read after `update_user_profile`.
6. Cache fields: an Anthropic response with read/write set produces `promptTokenCount` = input + read + write; a response without them yields nil, not 0. A pre-5a `ModelCallRecord` JSON and a pre-5a conversation decode.

### 3.1 Measurements

Filled in by the implementation: baseline on main, the result after 5a, and the tool-list experiment, each with provider, model, commit and date.

#### Baseline: Gemini, before the request change

`gemini-3.8-flash` (medium tier), main at `61c83d6` (PR A merged, no request change), 2026-10-01, `perf/suites/caching.json`, 2 repetitions, request bodies dumped. Gemini's caching is implicit (automatic); recorded, not graded.

| repetition | turn.round | prompt | cache read |
|---|---|---|---|
| 1 | 1.0 | 12967 | — |
| 1 | 2.0 | 13709 | — |
| 1 | 3.0 / 3.1 | 13641 / 14060 | — / — |
| 1 | 4.0 | 14138 | — |
| 1 | 5.0 | 14228 | — |
| 1 | 6.0 | 14445 | — |
| 2 | 1.0 | 12967 | 8102 (62%) |
| 2 | 2.0 | 13750 | — |
| 2 | 3.0 / 3.1 / 3.2 | 13714 / 14091 / 14266 | — / — / — |
| 2 | 4.0 | 14366 | — |
| 2 | 5.0 | 14436 | — |
| 2 | 6.0 | 14696 | 12103 (82%) |

Reading (Gemini): no turn reused the previous turn's prefix. Every round from turn 2 to turn 5 re-sent its whole prompt uncached. The two hits match an earlier request rather than the same conversation's previous turn. Repetition 2's turn 1 matched repetition 1's turn 1 for only 8.1k of 13k tokens, although nothing in that prefix should differ between runs, which is consistent with the unsorted key order of "Why" item 1.

#### Baseline: Anthropic, before the request change

`claude-opus-5-5` (medium tier), main at `61c83d6`, 2026-10-01, same suite, 2 repetitions, request bodies dumped. Pricing at measurement (announcement): input $4/MTok, cache read $0.20 (0.05×), cache write $5 (1.25×, 5-minute TTL).

| turn.round | rep 1: read / write / uncached | rep 2: read / write / uncached |
|---|---|---|
| 1.0 | 0 / 19248 / 4 | 19248 / 0 / 4 |
| 2.0 (fact) | 0 / 19813 / 4 | 9006 / 10800 / 4 |
| 3.0 | 19248 / 242 / 4 | 19248 / 244 / 4 |
| 3.1 | 19490 / 276 / 311 | 19492 / 115 / 53 |
| 4.0 | 19766 / 639 / 4 | 19607 / 238 / 4 |
| 5.0 | 20405 / 74 / 4 | 19845 / 76 / 4 |
| 6.0 | 20479 / 146 / 4 | 19921 / 150 / 4 |

Reading (Anthropic): every non-fact turn read 97–100% of its prompt. The fact turn (2) re-wrote the whole prompt because the fact block sits in the system prompt, and turn 3 could then read only turn 1's prefix. The tool round (3.1) read the previous round's prompt despite the skipped `tool_result` breakpoint (§1), which the suite still fixes for the next turn's read. The cost this design removes is the fact turn's full re-write; the suite has one fact turn in six, so the second scenario below measures the realistic case.

#### Scenario: every turn matches a different fact

Added with the after-measurement: a second caching scenario whose seeded facts make every turn match a different fact, so the block changes on every turn as it does with a real fact store. Measured on the baseline commit and after 5a, with the same pricing note.

## 4. Not in this deliverable

- The briefing, the pinned-conversation rules, the new tools, `/new` and anchoring: 5b.
- Gemini explicit `cachedContent` and OpenAI `prompt_cache_key`: automatic caching is measured first; explicit caching is a later slice if the numbers justify it.
- Changing invariant 6: only on the §3 experiment's evidence, in 5b's plan.
