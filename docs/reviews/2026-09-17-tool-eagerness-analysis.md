# Tool Eagerness and Turn Latency: First Measurements

* **Records**: `perf/baselines/20260917T201804Z-ladder-dcd8855.json`, `perf/baselines/20260917T202745Z-tool-eagerness-dcd8855.json`
* **Commit**: dcd8855 (release build; the records say "dirty" only because `--promote` had already written the smoke baseline into the tree, see Harness follow-ups)
* **Provider / models**: Gemini via ADC on Vertex, medium tier `gemini-3.8-flash`; Vibecop `cloud`, prompt guard `cloud`, sandbox on, main agent on host
* **Machine**: Mac16,7 (M4 Pro, 14 cores), macOS 26.6.2
* **Date**: 2026-09-17, roughly 20:18 to 20:34 UTC
* **Spec**: `docs/specs/2026-09-17-performance-evaluation-suite.md`

## Ladder results

Medians in ms over 3 repetitions unless noted. Rung 1 is a bare provider call with the prompt
alone; rung 2 adds Iris's system prompt; rung 3 adds the 30 tool declarations; rung 4 is a full
Iris turn with guards off; rung 5 is a full turn with guards as configured.

| scenario | rung 1 | rung 2 | rung 3 | rung 4 | rung 5 | overhead | harness |
|---|---|---|---|---|---|---|---|
| capital-city (model-only) | 3529 | 3713 | 3005 | 2377 | 8563 | 2.43x | 0.67x |
| explain-concept (model-only) | 5276 | 4224 | 4692 | 4409 | 4916 | 0.93x | 0.84x |
| short-writing (model-only) | 5050 | 3111 | 2045 | 5860 | 5383 | 1.07x | 1.16x |
| run-uname (tool-use) | 4009 | failed x3 | 1650 | 10490 (n=2) | 8603 | 2.15x | 2.62x |
| count-files (tool-use) | 8591 (n=1) | failed x3 | 3683 | 4047 | 4740 | 0.55x | 0.47x |

Prompt tokens per rung were stable across scenarios and are the least noisy number in the run:

| rung | prompt tokens | what was added |
|---|---|---|
| 1 | 13 to 29 | the prompt |
| 2 | about 2,010 | Iris's system prompt (SYSTEM.md 7 KB, five skills 11 KB, no SOUL.md on this machine) |
| 3 | about 5,110 | 30 tool declarations: about 3,100 tokens, 61 % of the request |
| 4 and 5 | 5,130 to 5,230 | user profile, fact-store block, and for tool turns the tool result |

### How to read the wall-clock numbers

The wall-clock medians are dominated by provider variance, not by Iris. With n = 3, single
rounds ranged from 1.3 s to 11 s for the same prompt, and the tail is severe: one 32 s round,
one 38 s round, and four rounds that hit the 60 s URLSession timeout (one in the ladder, three in
the eagerness suite, out of about 90 real calls). Rung 3 coming out faster than rung 1 in four of
five scenarios is noise, not a real effect. The ratios in the table are therefore not yet a
trustworthy headline; the span measurements below are, because they are measured directly inside
the turn rather than inferred from differences between noisy totals.

### Where the time goes, from the spans

Per full turn at rung 5, model-only prompts (ladder, summed over 3 repetitions then divided):

| span | per turn | what it is |
|---|---|---|
| `assembly.userProfile` | 650 to 930 ms | tier-3 cloud canary call on `USER.md`, a 32-byte file, every turn |
| `guard.tier3` | 630 to 710 ms | the same call (nested); tool turns add about 500 ms per tool output |
| `guard.tier2` | 18 to 20 ms warm | CoreML classifier; 650 ms once on first use |
| `assembly.factSearch` | 1 to 2 ms | SQLite fact lookup |
| `guard.tier1` | 0 ms | structural sanitization |

Rung 4 confirms the guards were genuinely off: every guard span is zero there. So the
security layers cost a deterministic 0.7 to 0.9 s per model-only turn and about 1.2 s per
tool turn on this configuration, almost all of it one cloud round trip to sanitize a static file.

Tool execution itself is cheap: `uname -sr` took 540 to 800 ms end to end, of which the process
spawn is a few ms and the rest is the tier-2 and tier-3 guard on its output.

**Not in these numbers:** Vibecop. The headless runner auto-approves tools, and
`AppState.requestApproval` returns before Vibecop is consulted when `autoApproveTools` is set,
so rung 5 never paid the Vibecop cloud call that a real `run_command` in the app pays. See
Harness follow-ups.

### The failures

- Rung 2 failed 3 of 3 on both tool-use prompts and rung 1 failed 2 of 3 on `count-files`, all
  with `The data couldn't be read because it is missing.` That is a Swift decoding error, not a
  provider error: asked to run a command with no tools available, Gemini returned a candidate
  whose `content` has no `parts`, and `Content.parts` is non-optional in `Models.swift`. This is
  a client robustness bug that a user can hit too (a safety stop or an empty candidate would
  surface as a decode error instead of a clear message).
- The 60 s timeouts are `URLError.timedOut`; they are not `APIError`, so the retry added in #124
  does not cover them, and the engine shows an error pill after a full minute of silence.

## Eagerness results

Rung 5 turns only. A turn counts as eager when the prompt did not warrant a tool.

| scenario | category | turns | unprompted tool calls | tools |
|---|---|---|---|---|
| capital-city (ladder) | model-only | 3 | 1 | rename_conversation |
| capital-city | model-only | 2 | 0 | |
| explain-concept (ladder + suite) | model-only | 5 | 0 | |
| short-writing (ladder + suite) | model-only | 5 | 0 | |
| advice | model-only | 2 | 1 | rename_conversation |
| conversation-meta | model-only | 2 | 0 | |
| quick-reasoning | model-only | 2 | 0 | |
| run-uname (ladder + suite) | tool-use | 5 | 5 of 5 used run_command, nothing else | |
| count-files (ladder + suite) | tool-use | 5 | 5 of 5 used run_command, nothing else | |

Across 21 model-only turns there were 2 unprompted tool calls, a rate of about 10 %, and both
were `rename_conversation` on the very first message of a conversation. No model-only prompt
triggered `run_command`, `search_memory`, `save_fact`, or `set_workspace`. The control set is
clean: every tool prompt used exactly one `run_command` and no extra tools.

This prompt set therefore does not reproduce a broad "runs random tools" pattern; it reproduces
one specific one. The prompts that provoked the impression in daily use probably contained a
project name, a path, or a personal fact, which are exactly the triggers the imperative tool
descriptions below name. A second eagerness set should cover those.

## What in the request drives tool use

1. **`rename_conversation` is offered on every turn with an imperative description**
   (`iris.swift`, the engine-appended declarations: "Use this when instructed by a System Event
   or when the conversation topic has fundamentally changed"). On a first message the model reads
   a topic change from nothing and renames. Measured: both eager calls. The app already
   auto-titles from the first user message, so the tool has no job on a plain turn.
2. **30 declarations, 3,100 tokens, on a plain chat.** `ToolExecutor.getTools()` plus the
   engine appends `set_workspace`, `rename_conversation`, `invoke_subagent`, `schedule_job`,
   `save_fact`, `search_memory`, `reflect`, `update_soul`, `update_user_profile`,
   `update_memory`, `create_skill` / `update_skill` / `delete_skill`, `register_directory_watcher`,
   and the goal-loop set (`propose_goal_contract`, `goal_complete`, `amend_goal_contract`,
   `reach_checkpoint`, `waive_criterion`, `delegate_milestone`). Several carry "Do this when the
   user says…" / "Use this when the user asks…" phrasing (`set_workspace`,
   `register_directory_watcher`, `rename_conversation`). Measured: 61 % of every request's prompt
   tokens; not measured as an eagerness driver by this prompt set, but it is the largest surface.
3. **Skill-creation steering in `SYSTEM.md`** (lines 87 to 95) instructs the model to create
   skills after multi-step work and error recovery. Not triggered by single-turn prompts; a
   plausible driver in longer sessions.
4. **The per-turn fact-store block and `save_fact`.** Every turn appends "Mid-Term Fact Store
   Memory (JIT Context)" when any fact matches and offers `save_fact`; prompts containing
   personal statements are the natural trigger. Not exercised by this set.
5. **No persona.** `~/.iris/memory/SOUL.md` does not exist on this machine, so the persona is the
   one-line default; it is not a contributor here.

## Candidate changes, ranked by expected effect

1. **Cache the tier-3 sanitization of static context by content hash** (`USER.md`, `AGENTS.md`)
   in the request assembly in `iris.swift`. Saves 0.7 to 0.9 s on every turn on this
   configuration, the only deterministic overhead the harness adds. Verify: `assembly.userProfile`
   and `guard.tier3` spans at rung 5 drop to about 0 for model-only prompts; rung 5 median
   approaches rung 4.
2. **Stream responses and handle timeouts.** No client streams, so a 38 s generation is 38 s of
   nothing on screen, and a 60 s timeout is a minute of nothing followed by an error. Streaming
   does not change wall-clock but changes what the user experiences; treating `URLError.timedOut`
   like a 503 in `LLMRetry` and raising the per-request timeout for long generations turns four
   of about ninety turns from hard failures into slow successes. Verify: time-to-first-token as a
   new model-call field; failed-repetition count in the eagerness suite.
3. **Stop offering `rename_conversation` on plain turns** (or reword it to System Event only).
   Directly removes the only measured eagerness. Verify: eagerness suite rate goes to 0 on the
   current prompt set.
4. **Trim the plain-chat tool surface.** Offer goal-loop tools only when a goal is active
   (several already are conditional; `propose_goal_contract` and `goal_complete` are not),
   and move `register_directory_watcher`, `schedule_job`, `update_soul`, and the skill CRUD behind
   a lighter "capabilities" mention or on demand. Verify: rung 3 minus rung 2 prompt tokens
   (target under 1,500 tokens of declarations) and the eagerness rate on a widened prompt set.
5. **Raise repetitions to 5 and report medians only** in `perf/suites/ladder.json` once the
   timeout handling lands; with this provider's tail, n = 3 cannot separate a 20 % regression
   from noise.

## Harness follow-ups

- `PerfEnvironment.git(["status","--porcelain"])` should pass `--untracked-files=no`; a promoted
  baseline written earlier in the same `perf/run.sh` run currently flags later suites as dirty.
- Add a way to run Vibecop in headless mode without blocking (auto-approve after Vibecop's
  verdict rather than before it), so rung 5 includes it.
- Make `Content.parts` tolerant of absence when decoding a Gemini response, so a parts-less
  candidate becomes "No candidate returned" rather than a decode error.
- The `PerfScenarioSummary.toolCallRate` denominator includes turns from failed repetitions
  (the `advice` row above shows 50 % from a turn that then timed out). Decide whether failed
  turns should count; today they do.
- Add a second eagerness prompt set: prompts that mention a project directory, a personal fact,
  a recurring task, and a request to "remember" something, to exercise `set_workspace`,
  `save_fact`, `schedule_job`, and the memory tools.

## Not measured here

- Streaming and time-to-first-token (no client streams; rung 1 latency is the floor a streaming
  UI would start showing at).
- Vibecop (bypassed under headless auto-approve, see above).
- Cold start beyond the first repetition in the process (the first `guard.tier2` call paid
  650 ms to load the CoreML model; everything else was warm).
- Sandboxed command execution (main agent runs on the host in this configuration).
