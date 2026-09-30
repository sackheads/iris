# Agency deliverable 5a: Cacheable, measurable prompts

Status: **proposed** (2026-09-30). Deliverable 5 of #187 (the main conversation) is split in two. 5a, this document, makes every conversation's prompt cacheable and makes caching measurable. 5b, the main conversation itself (pin rules, briefing, `search_conversations`/`read_conversation`, `/new`, anchoring), gets its own spec once 5a's numbers are in. The split exists because 5b's briefing is volatile per-turn content, and designing where it sits would mean designing against a prompt cache nobody can measure and that the code suggests is already failing.

## Why

A survey of the request path (2026-09-30) found four things. Each alone defeats prefix caching, and together they suggest that Iris gets little or no provider-side cache reuse on any provider. That is inference from code: nothing records cache counts today, which is item 4.

1. **Tool declarations are not byte-stable.** Tool schemas carry Swift dictionaries (`Schema.properties`) and no client encodes with sorted keys. Measured: one dictionary's contents, encoded 200 times in one process, produced 5–7 distinct byte sequences. Anthropic caches in the order tools → system → messages, so a tool block that changes bytes invalidates everything after it.
2. **The tool list changes membership per turn.** `manage_fact` is declared only when the fact store matched the input (`iris.swift` ~1253), the peer tools only when peers exist, and the goal and ladder tools by state. Invariant 6 gates these for token cost, a rule measured (#129, #144) with no working cache.
3. **The system prompt changes almost every turn.** The cached base (SOUL, skills, SYSTEM.md, rules; `ensureSystemPrompt`, `iris.swift` ~248) is copied, and then per-turn content is appended (`iris.swift` ~1100–1162): `USER.md` re-read, workspace `AGENTS.md`, the fact-store block (`# Mid-Term Fact Store Memory (JIT Context)`, selected by `factStore.search(query: input)`), and the peer-session count. On Anthropic a changed system block misses the whole history.
4. **Nothing is measured, and one number is wrong.** `UsageMetadata` (`Models.swift` ~236) has prompt, candidates and total only. Anthropic's `input_tokens` excludes cache reads and writes, so the prompt tokens Iris records for Anthropic under-report whenever caching works. Gemini's `cachedContentTokenCount` and OpenAI's `prompt_tokens_details.cached_tokens` are dropped.

## 0. Decided

Each decision names its default and why; the cost of being wrong is what a reviewer should weigh.

1. **Every request is encoded with sorted keys.** `JSONEncoder.outputFormatting` gains `.sortedKeys` in all three clients, and any `JSONSerialization` on the request path passes `.sortedKeys`. *Why:* byte-stable declarations are the precondition for any prefix cache; the order the model sees keys in carries no meaning. *Cost if wrong:* none found; sorting a few hundred keys per request is noise.
2. **Per-turn content leaves the system prompt for a turn-context block on this turn's user entry, in the request only.** The block is a separate leading text part, `<turn_context>…</turn_context>`, on the user entry that started the turn. It is built once per turn, sent unchanged on every model round of that turn (including rounds after mid-task steers), and never written to `history`. On the next turn that entry is sent plain. In 5a it carries the fact-store block and the peer-session count; 5b adds the briefing. *Why:* the prefix before it (tools, system, all older history) is then stable across turns. The cost is bounded: last turn's user entry and its rounds are re-sent without the block, so one turn's worth is uncached per turn, and that does not grow with history. The alternatives were weighed with the owner: persisting the block into history is fully cache-stable but grows history by a stale fact dump per turn and shows the model outdated copies; keeping it in the system prompt is the status quo that misses everything. *Cost if wrong:* the fact block now arrives in the user role, not the system role. That is lower authority, which is the safer direction for model-selected memory, but a model may weigh it differently; the rung in §3 runs the existing fact scenarios to catch a behaviour change.
3. **`USER.md` and workspace `AGENTS.md` stay in the system prompt but stop being re-read every turn.** Both are cached with the base and refreshed when they change: `USER.md` on `update_user_profile` or when its modification date moves, `AGENTS.md` when the conversation's workspace changes or its modification date moves. The guard pass runs on refresh, not per turn. *Why:* they change when someone edits them, not per turn. Re-reading and re-guarding each turn buys nothing and, where the guard's output is not deterministic, would itself change bytes. *Cost if wrong:* an edit made outside Iris is picked up at the next turn's date check, as today.
4. **Cache counts are recorded per provider, and unknown is not zero.** `UsageMetadata` gains `cacheReadTokens: Int?` and `cacheWriteTokens: Int?`. Anthropic: read = `cache_read_input_tokens`, write = `cache_creation_input_tokens`, and `promptTokenCount` becomes input + read + write, so it means the same thing on every provider. Gemini: read = `cachedContentTokenCount`, write nil. OpenAI: read = `prompt_tokens_details.cached_tokens`, write nil. A field the provider did not report is nil and renders as `—`. `totalTokenCount` is filled as prompt + output whenever the provider omits it: Anthropic sends no total, and the job budgets read the total, so until now an Anthropic run was charged nothing against any budget. After 5a every provider charges every token sent, cached or not. *Why:* a zero would read as a miss, and a budget that reads nil never trips. *Cost if wrong:* none; an older record simply has no cache columns.
5. **The counts reach the places tokens are already read.** `ModelCallRecord` (perf run JSON) and the conversation's `tokenUsage` gain the two fields, both decoded with `decodeIfPresent` (invariant 1: old run files and old conversations must still load, and `--perf compare` must accept a baseline written before this change). `/tokens` shows cache read and write beside prompt tokens; `--perf report` adds columns for cache read, cache write and uncached prompt tokens, where uncached = prompt − read − write.
6. **The tool list is measured, not changed, in 5a.** Declaration order is already fixed by construction; only membership varies. Whether a gated tool (e.g. `manage_fact`) should instead be declared on every turn is decided by the §3 experiment, and invariant 6 is amended only if the numbers say so. *Why:* invariant 6 was measured without a cache; with one, a stable declaration costs a cache read while a flapping one costs a full miss. Which one wins depends on sizes this deliverable is the first to measure. *Cost if wrong:* 5a lands with tool flapping still costing misses; the experiment's report says how much.

## 1. The request path

`processInputBody` records which `history` index holds the turn's user entry (the one appended at `iris.swift` ~1095, whether typed, a system event or a goal reprompt) and builds the turn context once. Request construction (`iris.swift` ~1543) copies `history`, inserts the block as the leading text part of that one entry, and hands the copy to the client. Persistence, the steer inbox, event delivery and hooks see `history`, never the copy, except the BeforeModel hook, which already receives the request and so sees the block. A turn whose context is empty (no fact matches, no peers) adds no part at all, so its request is byte-identical to one with no block mechanism.

Subagent and evaluator engines take the same path: their per-turn additions move into the block the same way.

Anthropic breakpoints stay four: last tool, system, and the last block of the penultimate and last messages (`AnthropicClient.swift` ~78–146). The survey found that a message breakpoint is skipped when that block is a `tool_result`. The suite reports per round, not only per turn, so a turn with tool calls shows whether that skip leaves the rounds inside it uncached. If it does, the fix is in scope here, with its own test.

## 2. Agent-facing text

The fact-store heading and anything else telling the model where its memory appears (`# Mid-Term Fact Store Memory (JIT Context)`, the `manage_fact` description, the SYSTEM.md or memory docs if they name the system prompt as its location) is searched and updated to say "this turn's context" (invariant 9). `docs/markdown_memory_design.md`, `docs/headless_profiling.md` and README's memory section are searched for the same claim. The heading text inside the block stays as it is, so the model's existing guidance still names it.

## 3. Verification

**The `caching` suite** (`perf/suites/caching.json`, run at rung 4, a full Iris turn with guards off): a scripted conversation of six user turns on the real lane, run once per configured provider. Scenarios gain `seedFacts` so the fact-store turns are deterministic. Turn 2 matches the fact store and turn 4 does not, so the block appears, changes and disappears. Turn 3 calls a tool, so it has more than one round. Each round records prompt, cache read, cache write and uncached tokens.

**Baseline first.** The suite runs on main after 5a's instrumentation PR (which changes no request byte) and before any behaviour change lands, and the spec records the numbers in §3.1 below. That turns the "Why" section's inference into a measurement.

**Pass criteria, Anthropic, turns 3–6:** on each turn's first round, cache read ≥ 95% of the tokens in tools + system + history up to the end of turn k−2's last round (the prefix this design says is stable), and uncached tokens ≤ the tokens of turn k−1 plus turn k's new entry plus 5%. Within a multi-round turn, each round after the first reads at least the previous round's full prompt from cache. Gemini and OpenAI: the same rung reports their automatic-cache counts; they are recorded, not graded, because Iris does not control those caches.

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

## 4. Not in this deliverable

- The briefing, the pinned-conversation rules, the new tools, `/new` and anchoring: 5b.
- Gemini explicit `cachedContent` and OpenAI `prompt_cache_key`: automatic caching is measured first; explicit caching is a later slice if the numbers justify it.
- Changing invariant 6: only on the §3 experiment's evidence, in 5b's plan.
