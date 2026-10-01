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

7. **Invalidators this design does not remove, named so nobody mistakes them for regressions.** `stripInlineDataFromHistory` (`iris.swift` ~1899) removes attachments from history at the end of a turn, so a turn that carried an image is re-sent next turn without it. That entry is turn k−1's, inside the window already expected to be uncached, so the k−2 guarantee holds, but an image's payload is paid for once and never cached. Changing thinking or effort settings invalidates the message cache (and on some models tools and system); the client sends neither today, and whoever adds them should know. On Claude Opus 5.5 and Fable 5.1 a history edit (including this design's turn-context block, dropped from its entry on the next turn) also invalidates every later thinking block, and on accounts created on or after 2026-08-31 replaying one is a 400. That is harmless today only because Iris discards Anthropic thinking blocks and never replays them; #314 tracks replaying them with an append-only history (an appended `clear_at` system message for the turn context on Anthropic). A `BeforeModel` hook that rewrites the request (`iris.swift` ~1609–1613) is outside Iris's control. And the cache has a TTL (5 minutes by default, measured start to start): a reply after that misses everything. Whether the system marker (which covers the tools) should use the 1-hour TTL at double the write price is a decision for 5b or later, with the measured sizes in hand.

## 1. The request path

`processInputBody` records which `history` index holds the turn's user entry (the one appended at `iris.swift` ~1095, whether typed, a system event or a goal reprompt) and builds the turn context once. Request construction (`iris.swift` ~1543) copies `history`, inserts the block as the leading text part of that one entry, and hands the copy to the client. Persistence, the steer inbox, event delivery and hooks see `history`, never the copy, except the BeforeModel hook, which already receives the request and so sees the block. A turn whose context is empty (no fact matches, no peers) adds no part at all, so its request is byte-identical to one with no block mechanism.

Subagent and evaluator engines take the same path: their per-turn additions move into the block the same way.

The fact block keeps its heading (`# Mid-Term Fact Store Memory (JIT Context)`). The peer-session count, which had no heading in the system prompt, sits under `# Active Sessions` in the turn context.

Round one sends `history` as the PreCompress hook returned it; every later request re-reads AppState's list, which the hook never touched. The engine therefore takes two anchors at the start of the turn, one per list, both validated against the bytes of the entry the turn appended, so an index from one list is never applied to the other. A PreCompress hook that drops the turn's entry but keeps an earlier byte-identical copy of it can put the block on that copy in round 1; the hook's output is opaque to Iris, so this is accepted rather than detected.

Anthropic breakpoints stay four, placed by turn rather than by position (`AnthropicClient.swift` ~78–123, `~174`): (a) system, which covers the tools that render before it, so the last tool is no longer marked separately; (b) the last message before the previous turn's entry, the end of turn k−2, which is this turn's read point; (c) the last message before this turn's entry, the end of turn k−1, which is written now and becomes the next turn's read point; (d) the last message, for rounds within a turn. A turn's entry is a `user` message with at least one block that is not a `tool_result` (typed input, a system event, a reprompt); a mid-turn steer, a mid-turn event card line and a peer's mid-task message are their own entries and qualify too. On the turn after one, marker (b) lands inside turn k−1, after the changed entry, so it misses, and the read can fall back to the lookback, possibly re-writing the whole history on that one turn; the turn after that recovers. Placing the tools under system's marker has a cost too: any change to the system prompt (a `USER.md`/`AGENTS.md` edit, a workspace switch, a skill install, or the perf harness's per-run temp-home path) now also re-writes the ~9k-token tool block, which the old separate tools marker kept (measured on six-turns' flap turn: 9006 read / 10,807 written at `ad88d84`, 0 / 19,885 at `2e53607`). Within a real conversation the system prompt rarely changes, so the trade favours (b). With fewer than two entries the missing markers are skipped, and no position is marked twice. The earlier placement (last tool, system, penultimate and last messages) left turn k−2's end reachable only through the API's 20-block lookback from the penultimate marker, and a tool-heavy turn k−1 pushed it out of reach, so the whole history was re-written. `markLastContentBlock` used to skip a message whose last block is a `tool_result`. The API accepts `cache_control` on `tool_result` blocks, so the skip was an artifact, and its cost followed from how the breakpoints work: a round ending in tool results wrote its cache entry at the assistant's `tool_use`, so the tool results were re-sent uncached on the next round and again on the next turn. The exclusion is gone, with its own test.

The turn-context part is its own text block on Anthropic (`AnthropicClient.swift` ~24–26), so the entry becomes `[text(block), text(user)]` and the message breakpoint lands on the user's text, keeping the block inside the cached range of the next round.

## 2. Agent-facing text

The fact-store heading and anything else telling the model where its memory appears (`# Mid-Term Fact Store Memory (JIT Context)`, the `manage_fact` description, the SYSTEM.md or memory docs if they name the system prompt as its location) is searched and updated to say "this turn's context" (invariant 9). `docs/markdown_memory_design.md`, `docs/headless_profiling.md` and README's memory section are searched for the same claim. The heading text inside the block stays as it is, so the model's existing guidance still names it. Dated plans and reviews (`docs/superpowers/plans/2026-09-17-performance-evaluation-suite.md`, `docs/reviews/2026-09-17-tool-eagerness-analysis.md`) describe the system prompt as it was and are left as history.

The perf ladder's rungs 2 and 3 replay the first request's captured system prompt (`PerfLadder.swift` ~22–38). From 5a on that prompt no longer holds the fact block or the peer count, so those rungs measure the stable prefix only and are not comparable with pre-5a baselines; `perf/README.md` says so. Anthropic's recorded prompt tokens also jump across the 5a boundary (they now include cached tokens). `--perf compare` still gates on prompt tokens, the size metric a regression inside the cached prefix shows up in. A pair that straddles the boundary (one record carries cache counts, the other does not) keeps the prompt-token row but marks it informational and prints a note saying why. When both records carry cache counts, compare adds an uncached-prompt-token row, informational only, because it swings with cache warmth rather than with what was sent. A pair where only one side ran the tool-list experiment (§0.6) gets the same treatment: a note, and an informational prompt-token row.

## 3. Verification

**The `caching` suite** (`perf/suites/caching.json`, run at rung 4, a full Iris turn with guards off): scripted multi-turn conversations on the real lane, run once per configured provider. Scenarios gain `seedFacts` so the fact-store turns are deterministic, and `PerfSuiteFilesTests` pins each one's match schedule. `six-turns`: turn 2 matches the fact store and turn 4 does not, so the block appears, changes and disappears; turn 3 calls a tool, so it has more than one round. `every-turn-facts`: each of six turns matches its own seed, so the block changes every turn. `tool-heavy`: five turns, where turns 1, 2 and 3 each match their own seed and turn 2 runs a dozen commands one at a time. Turn 2's entry changes at turn 3 and turn 2 spans more than the API's 20-block lookback, so turn 3 can read past the system prompt only through the end of turn 1, which §1's marker (b) makes explicit. Each round records prompt, cache read, cache write and uncached tokens.

**Baseline first.** The suite runs on main after 5a's instrumentation PR (which changes no request byte) and before any behaviour change lands, and the spec records the numbers in §3.1 below. That turns the "Why" section's inference into a measurement.

**Why k−2.** At turn k's first round the request differs from turn k−1's at exactly one place before the new entry: turn k−1's user entry, which carried the block then and is sent plain now. Everything before it hits, and exactly there, because every request of turn k−1 marked the end of turn k−2 (marker (c) of §1), and turn k marks the same block as its read point (marker (b)). The read point is an explicit marker, not the API's 20-block lookback, so it holds however many tool rounds turn k−1 ran. So a turn's read is the prefix through the end of turn k−2 as a floor. When turn k−1's block was empty, its entry is byte-identical in both requests and the read extends further. In the suite that is turn 5, since turn 4 matches no fact, so turn 5 reading *more* is expected, not an anomaly. All criteria assume the next turn arrives within the cache TTL, which a scripted suite does.

**Pass criteria, Anthropic, turns 3–6.** Pass or fail is decided by checks that need only usage fields:
- at each turn's first round, cache read ≥ the previous turn's first-round cache read (the prefix never collapses);
- within a turn, each round's read ≥ the previous round's read + write;
- at each turn's first round, cache write + uncached tokens ≤ turn k−1's output tokens plus the tool results it read plus a fixed allowance for two entries, bounded generously. Uncached alone is no test: with a marker on the last message, it is the few tokens after that marker by construction (2–4 in every run), and what turn k−1 left uncached shows up as this turn's write.

The 95% figure is reported alongside them from exact sizes: the suite writes each round's request body, and the prefix through turn k−2 is counted with the provider's token-counting endpoint. Read ≥ 95% of that prefix is the target. The dumps are also what gets diffed to find a miss. Gemini and OpenAI: the same rung reports their automatic-cache counts; they are recorded, not graded, because Iris does not control those caches.

**Tool-list experiment:** the suite runs twice more on Anthropic, once as shipped and once with the state-gated tools (`manage_fact` and the peer tools) declared on every turn (`IRIS_PERF_DECLARE_STATE_TOOLS=1`). Perf pins the peer count to 0, so the peer tools never flap in either run; under the switch they are declared on every turn, with no `# Active Sessions` block. The report compares total uncached plus cache-write tokens across each conversation. That is cost evidence only: if always-declared is cheaper, the plan for 5b weighs amending invariant 6 with the numbers; if not, invariant 6 stands with this measurement cited. Tool eagerness (#132), the other half of invariant 6, is not measured here.

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

`perf/prompts/caching/every-turn-facts.json`: six turns, each matching exactly its own seeded fact (pinned by `PerfSuiteFilesTests`), so the fact block changes on every turn as it does with a real fact store. Anthropic, `claude-opus-5-5`, 2026-10-01. Read / write / uncached per round. The baseline record is `gitDirty: true` at `61c83d6`: the scenario file did not exist at that commit, so the run carried it as an uncommitted file; nothing else in the tree differed.

| | rep | t1 | t2 | t3.0 | t3.1+ | t4 | t5 | t6 |
|---|---|---|---|---|---|---|---|---|
| baseline `61c83d6` | 1 | 0/19691/4 | 9006/10771/4 | 9006/10889/4 | 19895/141/63 | 9006/11244/4 | 9006/11354/4 | 9006/11626/4 |
| after `ad88d84` | 1 | 19456/216/4 | 19456/303/4 | 19610/275/4 | 19885/149/2, 20034/199/2 | 19724/707/4 | 20277/268/4 | 20391/321/4 |
| after the marker fix `2e53607` | 1 | 19529/211/4 | 19529/302/4 | 19683/278/4 | 19961/149/2 | 19799/458/4 | 20107/336/4 | 20292/340/4 |

Input cost of the six-turn conversation at the pricing above: **baseline $0.392 / $0.358 (two repetitions), after 5a (`ad88d84`) $0.044 / $0.044: about 88% less.** After the marker fix (`2e53607`): **$0.038 / $0.038, about 90% less.** Before, every turn re-wrote ~11k tokens behind the changed system prompt; after, each turn writes only its tail.

Behaviour, one repetition each, so weak evidence: in the baseline run, turn 6 was confused by the changing fact block in the system prompt ("My last correction needs a correction of its own…"), while the after run used each turn's fact correctly. That is consistent with §0.2's move of the block to the user role not hurting, and no more than that.

#### Scenario: a tool-heavy turn between two fact turns

`perf/prompts/caching/tool-heavy.json`, first version: turn 1 and turn 3 matched different seeds, turn 2 ran twelve commands one at a time and matched none, turns 4–5 plain. **That version could not test §1's marker placement**: turn 2 never carried a block, so its entry was unchanged at turn 3, and turn 3 read through turn 2's own last-round marker under either placement. Its numbers below are kept as a cost record only. Anthropic, `claude-opus-5-5`, `2e53607`, 2026-10-01 (baseline at `61c83d6`, `gitDirty: true` for the same reason as above). Read / write / uncached per first round, gated arm (as shipped):

| rep | t1 | t2 (first / last round) | t3 | t4 | t5 |
|---|---|---|---|---|---|
| 1 | 19529/213/4 | 19186/292/4 … 21096/125/2 (13 rounds) | 19529/2570/4 | 21221/559/4 | 21780/142/4 |
| 2 | 19529/213/4 | 19478/0/4 … 21106/125/2 (13 rounds) | 19683/2326/4 | 21231/486/4 | 21717/138/4 |
| baseline `61c83d6`, rep 1 (rep 2 ran turn 2 in 2 rounds, not 13, so it is not like-for-like) | 0/19661/4 | 0/19407/4 … 20961/124/51 (13 rounds) | 9006/**12960**/4 | 21085/583/4 | 21668/188/4 |
| declared every turn, rep 1 | 20151/217/4 | 20151/292/4 … 22058/125/2 (13 rounds) | **22183**/479/4 | 22508/190/4 | 22698/161/4 |

Reading: the baseline's 12,960-token re-write at turn 3 came from the fact block living in the system prompt at `61c83d6`, not from marker placement. In the declared arm, turn 3 read 22,183 through turn 2's own last-round marker, which either placement reaches. In the gated arm, repetition 1's turn 3 read 19529, which is tools and system only; repetition 2's 19683 reached the end of turn 1. Both stop short of turn 2 because `manage_fact` is declared on turns 1 and 3 but not turn 2, so turn 2's cached entries carry a different tool list.

#### Marker placement, measured (old vs new)

`tool-heavy.json` revised so turns 1, 2 and 3 each match their own seed (`fba2e45`). Turn 2's entry now changes at turn 3, and turn 3's only read point past the system prompt is the end of turn 1, more than 20 blocks back. Both arms ran with `IRIS_PERF_DECLARE_STATE_TOOLS=1` so the tool list is stable and only the markers differ: old placement `ad88d84` vs new `fba2e45`, alternated old, new, old, new, 2 repetitions each, `claude-opus-5-5`, 2026-10-01.

| arm | turn 1 prompt | turn 3 first-round read | what turn 3 reached |
|---|---|---|---|
| old (`ad88d84`), 4 conversations | 19,667–19,685 | 19,449 / 19,449 / 19,463 / 19,463 | tools + system only (equal to turn 1's own read): the lookback failed past turn 2 |
| new (`fba2e45`), 4 conversations | 20,374–20,385 | 20,319 / 20,319 / 20,312 / 20,312 | through the end of turn 1 (turn 1's entry and answer): marker (b) |

The mechanism holds in all eight conversations: the old placement loses all history before a long turn that carried a block, and the new one keeps it. Here that history is only turn 1 (~150 tokens), so the dollar difference is within noise ($0.190–0.097 old vs $0.195–0.097 new per repetition; the new arm's prompt is larger because the switch now declares the peer tools too). The saving grows with the history before such a turn: on a long conversation the old placement re-writes all of it each time.

Input cost of the first version's five-turn conversation: baseline $0.335 / $0.158, gated $0.097 / $0.094, declared $0.088 / $0.087.

#### After 5a: pass criteria (§3), Anthropic, turns 3–6

First run at `ad88d84` (`six-turns`, `every-turn-facts`), before the marker fix (§1); re-checked at `2e53607` on all three scenarios, 2 repetitions each. The verdicts below hold at both commits; numbers are from `2e53607` unless marked.

- **First-round read never falls turn over turn:** holds in every-turn-facts. It **fails wherever the tool list changes**: six-turns repetition 2, turn 3 (19529 → 19314), and tool-heavy turn 3 (turn 2's last round 21096 → 19529). The cause is `manage_fact` appearing and disappearing with the fact match. A changed tool list invalidates everything after the tools under either placement; at `2e53607` six-turns' turn 2 wrote 19,885 because the system prompt had also changed between runs (the per-run temp-home path), which the old separate tools marker would have absorbed (§1). In the declared arm, first-round reads rise on every turn.
- **Within a turn, each round's read ≥ the previous round's read + write:** holds on every multi-round turn (e.g. at `2e53607` 19683+278 → 19961; at `ad88d84` 19610+275 → 19885, 19885+149 → 20034). The baseline already met this, so it is not evidence for the `tool_result` marker. That evidence is round 3.1's uncached tokens: 311 and 53 in the baseline's two repetitions, 2 after, because the tool results now sit inside the marked prefix instead of after it.
- **First-round write + uncached ≤ the allowance:** holds on every turn 3–6 that kept its tool list. every-turn-facts 282/462/340/344, six-turns 244/214/193/144, and tool-heavy turn 3 2,574, which is turn 2's thirteen rounds of tool calls and results plus the new entry. Uncached alone is 2–4 tokens by construction (the last message is always marked), so it is no longer read as evidence (§3).
- **The read reaches turn k−2:** the evidence is the first-round read rising turn over turn as history grows, e.g. every-turn-facts at `2e53607` 19529 (t2) → 19683 (t3) → 19799 (t4) (at `ad88d84`: 19456 → 19610 → 19724): each turn reads what the turn before it added. The earlier claim here, that every first round reads ≥ 96% of its whole prompt, was true but proved nothing: history is about 5% of a ~20k prompt, so the tools and system alone clear 95%. The prefix-through-k−2 counts from the token-counting endpoint were **not counted**. The rising-read evidence and the old-vs-new marker measurement above stand in for them.

#### Tool-list experiment (§0.6)

`IRIS_PERF_DECLARE_STATE_TOOLS=1`, `ad88d84`, `six-turns`. At that commit the switch covered `manage_fact` only. From the marker-fix commit on it also declares the peer tools (§0.6); perf pins the peer count to 0, so the peer tools are never exercised as flapping, but they are declared on every turn under the switch and add to its prompt. Re-run at `2e53607` with the declared arm first and the gated arm second (the reverse of the first run's order), so each run's first scenario (six-turns) ran turn 1 cold in both arms; the two scenarios compared below had warm turn 1s in both arms. Anthropic returned `529 overloaded` partway through the declared arm's six-turns repetitions, so the six-turns arm comparison at `2e53607` is incomplete; every-turn-facts and tool-heavy completed in both arms.

| six-turns, rep 1 | t1 | t2 (fact) | t3 | t4–t6 first-round reads |
|---|---|---|---|---|
| gated (as shipped) | 0/19241/4 | 9006/**10807**/4 | 19241/240/4 | 20151, 20423, 20498 |
| declared every turn | 9006/10564/4 | 19570/**226**/4 | 19590/234/4 | 20436, 20741, 20821 |

The declared arm's turn 1 read 9006, not 0: its tool set (the shipped list plus `manage_fact`) was already cached by the gated arm's fact turn, so the tools were warm. The system prompt missed because the perf harness puts a per-run temp-home path into the skills' `**Path:**` lines, so every run's system prompt differs from the last run's. Every run's turn 1 therefore re-writes the system prompt, whichever arm it is in.

Six-turn totals, uncached + write: repetition 1, gated **31,505** vs declared **12,205**; repetition 2, gated **1,378** vs declared **1,284**. Most of repetition 1's gap is turn 1, which the gated arm ran cold because it ran first (19,241 written vs 10,564), so run order inflates that headline; the rest is the fact turn's re-write (10,807 vs 226). In repetition 2 the arms nearly tie, consistent with the gated arm's fact-turn tool set still being cached from repetition 1, within the TTL. Neither repetition isolates the flap cost from run order; the rerun should alternate or warm both arms first. After the marker fix (`2e53607`), uncached + write per repetition, gated vs declared: every-turn-facts **2,100 / 2,038 vs 2,531 / 2,651**; tool-heavy **5,563 / 4,960 vs 3,123 / 2,881**. Where the gated tool would have flapped (tool-heavy), declaring it every turn cuts uncached + write by about 42% (ratios 0.56 and 0.58), which is about 9% of input dollars ($0.088 vs $0.097), because reads dominate. Where it would not have flapped (every-turn-facts, where `manage_fact` is declared on every turn in both arms), the declared arm's uncached + write is 21% and 30% higher. That gap is model behaviour, not schema cost: the peer schemas sit in the cached prefix (turn 1 wrote 217 vs 211), while the declared arm's turn 3 ran 3 rounds instead of 2 and its turn 4 wrote more. At two repetitions per arm the two are indistinguishable.

With the declaration stable, first-round reads never fall and the fact turn writes 226 tokens instead of 10,807. A state-gated tool costs one ~10k-token cache write each time the tool list changes to a combination not already cached, about $0.05 at the pricing above. Declaring it every turn costs its schema on every request, mostly as cached reads at 0.05×. **On Anthropic, at these sizes, stable declarations cost less than gating whenever the gated tool would flap; where it would not, this suite cannot tell the two apart.** That is cost evidence for 5b's decision on invariant 6, which #314's append-only work needs anyway; it says nothing about tool eagerness (#132), which this suite does not measure.

Gemini after 5a: not run. The plan's Gemini after-measurement step was skipped because these runs used Anthropic as the primary provider; Gemini has only its baseline above, and OpenAI has none.

#### Budget defaults (§0.4)

A turn of this suite counts about 20k prompt tokens per round, cached or not. The run budget (200k) therefore allows roughly ten such rounds per job run, and the per-job daily budget (1M) roughly fifty. Those figures were never exercised by Anthropic traffic before 5a. Whether to raise them, or to count billed weight instead of tokens sent, is 5b's decision with these numbers in hand.

## 4. Not in this deliverable

- The briefing, the pinned-conversation rules, the new tools, `/new` and anchoring: 5b.
- Gemini explicit `cachedContent` and OpenAI `prompt_cache_key`: automatic caching is measured first; explicit caching is a later slice if the numbers justify it.
- Changing invariant 6: only on the §3 experiment's evidence, in 5b's plan.
