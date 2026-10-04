# Agency deliverable 5c: Cost policy

Status: **proposed** (2026-10-04). This is deliverable 5c of #187. It settles the three settings that 5a's measurements (`2026-09-30-agency-cacheable-prompts.md` §3.1) raised and that apply to every conversation: whether tools are declared or gated, the unit and defaults of the token budgets, and the cache TTL. The design was worked through with the `work` review session. The owner has not reviewed it yet.

## Facts this design rests on

These were checked against the code and live, 2026-10-04.

- **Budgets count every token the same.** They sum `job_runs.totalTokens`, which is input + cache read + cache write + output, all at 1×. This is `JobLedger.tokensToday`, fed by `UsageMetadata.anthropicPromptTokenCount`. A 20k prompt that is 97% cache reads counts as 20k, and an output token counts the same as an input token. Two runs with equal `totalTokens` can differ in cost by about 50×. Raising the defaults cannot fix a unit that is wrong in both directions.
- **The ledger doesn't keep cache counts.** It stores prompt, candidate and total only. `UsageMetadata` already carries cache-read and cache-write counts.
- **A flapping tool list rewrites the history.** When a state-gated tool's declaration flaps, the Anthropic cache is invalidated after the system-and-tools block and the history is rewritten. In the tool-heavy scenario, gated cost $0.097 / $0.094 and declared-every-turn cost $0.088 / $0.087.
- **Vertex accepts a 1-hour TTL** without a beta header. `cache_control: {type: "ephemeral", ttl: "1h"}` returns `usage.cache_creation = {ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`, and a later 5-minute request reads a 1-hour entry.
- **The easy tier has a minimum cacheable size.** Haiku 4.5's cacheable minimum is 4,096 tokens; Sonnet and Opus are 1,024. Easy-tier prompts under that size never cache, whatever the TTL. Examples are the rotation summary and short evaluator prompts.

## 0. Decided

1. **State-gated tools stay declared once they appear.** A state-gated tool, once declared in a conversation, stays declared for the rest of that conversation's turns. Examples: `manage_fact`, the peer tools, `amend_goal_contract`, `reach_checkpoint`, `delegate_milestone`, `set_workspace` where gated.
   - The sticky set is held in memory, keyed by conversation id. A new conversation or a rotation starts empty.
   - It applies to every provider. Gemini and OpenAI prefix caches key on the same bytes, and a few extra declarations cost far less than a history rewrite.
   - Workflow-trigger tools (`rename_conversation`, `propose_goal_contract`) stay one-turn-only. #132 showed `rename_conversation` being called eagerly, and their flap happens only on the trigger turn.
   - The set isn't persisted. A restart re-derives it from the gates, at the cost of one rewrite. Persist it on `Conversation` only if perf numbers show that matters.
   - *Cost if wrong:* a few hundred declaration tokens per turn, mostly cache reads, in conversations that ever tripped a gate.
2. **A sticky declaration is refused at dispatch when its state is off.** Declaring a tool outside its state must not widen what can be done. Every sticky tool refuses at dispatch, with a sentence, when its state doesn't hold.
   - Some already do: the job tools, `amend_goal_contract` and `waive_criterion` without a locked contract.
   - These must be checked and covered: `reach_checkpoint` and `delegate_milestone` at the final milestone, `manage_fact` with no facts, `send_to_session` with no peers, `set_workspace`.
   - Three of these have **no off-state guard today**, so 5c adds one: `reach_checkpoint` (no final-milestone check), `manage_fact` and `send_to_session`.
   - Acceptance: one test per sticky tool, showing that a call in the off state is refused.
3. **`goal_complete`-only turns restrict by dispatch, not by declaration.** A turn with `restrictToGoalComplete` used to strip every tool but `goal_complete`. That is a removal flap on the longest history, the most expensive rewrite there is. Now the declarations stay the same, a one-line instruction in the turn context asks for `goal_complete`, and the dispatcher refuses every other tool on such a turn. The dispatcher already does this; keep that check. *Cost if wrong:* the model sees tools it may not use on one turn, and calling one is refused.
4. **The tool prefix only grows within a conversation.** A regression test runs several turns of one conversation through `CapturingLLMClient`, with states toggling, and checks two things:
   - turn N+1's declared tool names are a superset of turn N's;
   - every shared entry's description is byte-identical.
5. **Budgets count weighted tokens.** The unit is named **weighted tokens**, never "tokens".
   - Weight = uncached input × 1 + cache read × r + cache write × w + output × 5.
   - r and w come from a per-provider table:

     | Provider | r (cache read) | w (cache write) |
     |---|---|---|
     | Anthropic, direct and Vertex | 0.1, conservative (Opus 5.5 is 0.05) | 1.25 for 5-minute entries, 2.0 for 1-hour entries, from the response's per-TTL split |
     | Gemini | its published cached-token ratio, pinned with a date in a test | 0 (implicit caching has no write charge) |
     | OpenAI | its published cached-input ratio | 0 |
     | Unknown | 1 | 1 |

   - Output × 5 is a floor across providers; actual output prices range from 4× to 8× input. On an 8× provider this under-charges output-heavy runs by up to 1.6×. That's accepted, because the budget guards against runaway spend, not billing precision.
   - The 200k per run, 1M per job per day and 3M global defaults stay. At a 20k prompt that is 97% cache reads with 500 output tokens, a round costs about 5k weighted, so a run gets about 40 rounds instead of 10. A cold first round costs about 25k.
   - *Cost if wrong:* weights are a table, and history is re-priced at read time (decision 6), so changing a weight needs no migration.
6. **The ledger stores the raw usage components.** `job_runs` gains these columns, each with NULL meaning 0 or unknown (invariant 1):
   - `cacheReadTokens`;
   - `cacheWriteTokens`, which is the **total** of cache writes;
   - `cacheWrite1hTokens`, which is the 1-hour **share** of that total;
   - `provider` and `tier`, written at `begin(run:)`.

   Weighted totals are computed from the components and the run's own provider wherever they are needed, never from the current provider, and they are never stored. A row with no provider (written before 5c) is priced as its plain `totalTokens`, every component at 1× and output included. That is today's behaviour, and old event cards are treated the same way.

   The 1-hour split arrives as a nested `usage.cache_creation` object (`ephemeral_5m_input_tokens`, `ephemeral_1h_input_tokens`). Today neither the non-streaming parse nor the SSE `message_start` path reads it. Both must.
7. **One unit everywhere a budget is compared or shown:**
   - `TurnBudget.stopReason`, per round;
   - `JobLimits` admission;
   - the delegated-subagent charge from #326;
   - the digest's per-job line;
   - `/jobs`;
   - `list_jobs`;
   - the Settings → Job Limits steppers;
   - a job's event card, which shows its run's weighted total;
   - the README and docs.

   Nine strings currently promise "tokens sent, not billed cost": two in iris.swift, one in JobsCommand, one in JobRunner, one in the README, and five in docs/jobs.md. Each is rewritten (invariant 9).
8. **The 1-hour TTL is used where gaps of 5 to 60 minutes are the norm.**
   - **In Iris (the pinned conversation)**, all four Anthropic markers use the 1-hour TTL. Reads refresh the TTL, so a human-paced day stays warm at the price of one 2× write per hour of silence.
   - **The shared background prefix** (system plus tools, common to all job runs since #321) uses 1 hour whenever any enabled scheduled job fires more often than hourly, and 5 minutes otherwise. Per-run history markers stay at 5 minutes, because runs are short.
   - **Everything else** stays at 5 minutes.
   - Ordering constraint: longer-TTL breakpoints must come before shorter ones in the prompt. Tools and system at 1 hour with history at 5 minutes satisfies this; the reverse does not.
   - Break-even: the 1-hour premium is 0.75× of the prefix per write, and an avoided miss saves about 1.15×. So 1 hour pays off when more than about two thirds of cache lifetimes would otherwise contain a 5–60-minute gap.
   - The direct API sends `ttl` without the old `extended-cache-ttl` beta header, and the test asserts on the per-TTL breakdown. The header is added only if the API returns a 400 without it.
   - *Cost if wrong:* every write in Iris is a 1-hour write, so each turn's tail write and every hourly re-write costs 2× instead of 1.25×. The perf run in §2 measures whether the avoided misses cover that.
9. **Other providers' explicit caching:**
   - **OpenAI: yes, in 5c.** Send `prompt_cache_key` set to the conversation id. It is one request field that improves cache routing.
   - **Gemini `cachedContent`: no.** Explicit caches need lifecycle management (create, TTL, delete, storage cost). Implicit caching with 5a's stable prefix is the baseline. Tracked as a follow-up issue.
10. **Some prompts can't be cached.** Easy-tier prompts under 4,096 tokens never cache on Haiku, and OpenAI's minimum is 1,024 tokens. Perf criteria don't expect reads there, and the docs say so.

## 1. Components

- **`StickyTools`** (new, AppState-held, transient): `[UUID: Set<String>]` per conversation, written when a state-gated tool is first declared and read by `buildRequest` / `processInputBody`'s declaration assembly. It applies to the **main principal only**. It is cleared when a conversation is deleted, not when it is archived: an archived conversation can come back, and its prefix should still match.
  - **Order in `buildRequest`.** The sticky union runs *before* the hard strips: unattended job-tool removal, `set_workspace` for unattended turns, the principal filter, and the read-only profile allowlist. A strip always wins over stickiness.
- **`CostWeights`** (new, pure): the provider table, plus `weighted(_ usage: UsageComponents, provider:) -> Int`.
- **Ledger:** a migration adding the three columns, `recordUsage` writing them, and `tokensToday` / `usage` computing weighted totals.
- **Clients:** the Anthropic transport takes a per-request TTL policy for markers (system and tools vs. history). `UsageMetadata` gains the 1-hour write split. The OpenAI client sends `prompt_cache_key`.
- **Docs and strings:** the "weighted tokens" sweep (decision 7).

## 2. Verification

- **Unit tests:**
  - the sticky set and its reset on rotation and new conversations;
  - a sticky tool never survives a hard strip (unattended, principal, read-only profile, `set_workspace`);
  - an off-state refusal for every sticky tool;
  - the prefix-only-grows test;
  - the weights table and re-pricing;
  - the ledger columns (pre-5c rows load as zeros and are priced as plain `totalTokens`);
  - the nested `cache_creation` split on both the non-streaming and the SSE parse;
  - admission and `TurnBudget` in weighted units;
  - the TTL marker policy and ordering;
  - `prompt_cache_key`.
- **Perf (real lane, Anthropic):**
  - a new **cost column** in the perf report, computed from the weight table times a base price, to check the weights against a real bill once;
  - `pinned-briefing` with a 6-minute pause between two turns, at 5-minute vs 1-hour TTL;
  - a 15-minute-cadence pair of job runs, at 5-minute vs 1-hour on the shared prefix;
  - `tool-heavy` with sticky declarations, compared with 5a's gated and declared arms;
  - an unprompted-call count for `manage_fact` and the peer tools, so stickiness can be reverted on evidence.
- **Full suite:** exit 0, the Swift Testing summary, and XCTest's "Executed N tests, with 0 failures".

## 3. Not in this deliverable

- Gemini explicit `cachedContent` (decision 9; #351).
- Persisting the sticky set across restarts (decision 1; only on evidence).
- Billing in dollars. Rejected: price tables go stale, and one owner runs an unlimited Vertex budget. The perf cost column is a check, not a budget.
- Anthropic thinking replay (#314).
