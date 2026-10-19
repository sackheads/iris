# Subagents on other model families (#239)

**Status:** spec, iris-dev-3, 2026-10-19, with the planner's rulings on forks A-F folded in. Brian ruled Fork E and the Always Allow fork. Reviewers: iris-dev-1 first (it owns the resolver that agent profiles part 3 changes), iris-dev-2 second. The planner rules the forks; anything about Brian's money or credentials goes to Brian through the Overseer.

## What and why

A subagent can run on a different provider and model than the conversation that called it: a security review on DeepSeek, an architecture review on Claude, a hygiene pass on Gemini. Different models fail differently, so lenses spread across families give independent findings. That's the use in #239 and in the "Lenses and a Grammar" field note it links.

**Fixed constraint (Brian, #239):** no mixing in the main easy/medium/hard tiers. The main conversation's provider and tiers behave exactly as today. Other providers serve contained subagent runs only.

## Where Iris is today

- **One dispatcher, one global provider.** `LLMClient` (LLMClient.swift:15) is a stateless struct. Each `streamContent` and `generateContent` reads `ConfigManager.shared.primaryProvider` and `getModel(for: tier)` on every call, and branches to Anthropic, OpenAI or Gemini. Every engine, subagent and the grader builds it the same way (iris.swift:524, SubagentManager:154/333, GoalEvaluator:65), and a subagent gets its parent's client (iris.swift:4783-4817). A subagent's only knob is its tier (`effort`).
- **Three built-in families.** These are `LLMProvider` (`Gemini`, `Anthropic`, `OpenAI`), each with its own key, base URL, auth mode and three tier models. `isConfigured(provider:…)` is already per provider.
- **Secrets.** These live in one Keychain item: account `all-keys`, service `com.iris.secrets` plus the build's suffix (`.dev` for dev builds), holding a JSON dict (`GEMINI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, the Google OAuth values). `--seed-dev-home` copies that whole item.
- **Global readers.** Some code reads the global provider for things that would be wrong for a subagent on another one:
  - pill labels and thinking replay (`providerOverride ?? primaryProvider`, iris.swift:2606);
  - the profiler's model name (:2778);
  - Anthropic's `maxTokens` cap (:2916);
  - a job run's ledger stamp (JobRunner.swift:1079).

## Two halves, two PRs

- **Half 1 (PR 1): Iris can hold more than one provider at once.** This means a provider registry, credentials per provider, a client that can be pointed at one provider, and the Settings pane. It stays inside the planner's file fence: ConfigManager gets new fields only, plus LLMClient/AnthropicClient/OpenAIClient internals, SettingsView, the secret store and the seeder. It never touches `iris.swift`, `SubagentManager.swift`, or the existing tier and model resolvers. Nothing in the main conversation's path changes.
- **Half 2 (PR 2, after profiles part 2 merges): a subagent runs on a named provider and model.** This covers the `invoke_subagent` arguments, the refusals before spawn, the subagent engine's provider, the global readers above, and cost attribution. It composes with part 2's subagent tool intersection.

## Fork A: registry shape

**Ruled: option 1**, with these conditions on custom endpoints:
- **Settings only:** an endpoint is set in Settings, never by a tool or the model.
- **https only,** except loopback (`localhost`, `127.0.0.1`, `::1`) for a local Ollama or LM Studio. Any other `http:` URL is refused at save, with the reason.
- **The row says where content goes:** a subagent's whole context, workspace content included, is sent to that endpoint.
- **Storage:** the URL goes in defaults, and the key goes in the secret store (Fork B).
- **The defaults domain isn't protected (iris-dev-2's review), so a key is bound to its origin.** One approved `defaults write` could add an endpoint or re-point an existing one's `baseURL`. So:
  - **Origin binding.** The secrets dict stores each endpoint's key together with the origin it was entered for (scheme, host and port, as `PROVIDER_<id>_ORIGIN`). A route whose endpoint origin no longer matches is refused: "Provider `x`'s address changed since its key was entered; re-enter the key in Settings." The key is never sent to the new origin.
  - **Keyless endpoints are loopback only.** Otherwise a written-in keyless https endpoint would receive a subagent's context with no key involved.
  - **Exact loopback match:** `URLComponents.host` must be exactly `localhost`, `127.0.0.1` or `::1`. A URL with userinfo is refused. Tests cover `localhost.evil.com`, `localhost@evil.com`, `127.0.0.1.nip.io`, `::ffff:127.0.0.1` and `0.0.0.0`.
  - **No redirects.** A routed endpoint call uses a session that follows no redirect at all. A 307 or 308 would resend the POST body (the subagent's context) to wherever it points, so it ends the call as an error instead.
  - **Not covered here:** the built-in families' base URLs (`OPENAI_BASE_URL` and its siblings) live in defaults today too, and a re-point sends the primary's own key there. That's pre-existing, and it's filed as its own issue rather than widened into this PR.


- **Option 1 (lean): the primary stays as today, with subagent providers beside it.**
  - `primaryProvider` and the nine tier fields are untouched. Nothing migrates.
  - A subagent may name any provider in the registry that is **switched on for subagents**:
    - a built-in family when `isConfigured(provider:)` holds *and* its "Usable by subagents" switch is on;
    - a custom endpoint the person adds.
  - **The switch is off by default for every non-primary built-in** (iris-dev-1's review). Having an Anthropic key set while Gemini is primary isn't consent to send a subagent's context there, or to spend on it.
  - **A custom endpoint is on when added,** because adding it is the opt-in.
  - **The primary needs no switch.** A subagent with no `provider` runs on it, as today.
  - **Ruled by the planner** (dev-1's review change; Brian gets an FYI). The switch narrows the default only. Without it, a key left over from an old setup would declare the arguments and invite the model to pick that family unprompted (#132's eagerness). Two conditions:
    1. **The Invariant 6 gate keys on usable providers:** switched on and with a key. A leftover key with its switch off declares no `provider`/`model` arguments and costs no tokens. Tested both ways.
    2. **The refusal for a family that's keyed but switched off names the switch:** "Anthropic is configured but not enabled for subagents: Settings → Models → Subagent providers." A bare "not configured" would be false.
  - A custom endpoint is `ProviderEndpoint { id, name, kind, baseURL, models: [String], needsKey: Bool }`.
    - `kind` is `openAICompatible` in v1. That covers DeepSeek, OpenRouter, Together, and Ollama's or LM Studio's local `/v1`.
    - Gemini and Anthropic don't need a custom kind: the built-in families cover them.
  - Persisted in the app's defaults domain as JSON under one key (`SUBAGENT_PROVIDERS`). Each field is read with `decodeIfPresent` and a default. An entry that doesn't decode is dropped on its own and reported once in Settings, never the whole list (the Invariant 1 shape).
- **Option 2: a flat list with a primary flag.**
  - Every provider would become a row, and `primaryProvider` would be derived from the flag.
  - That means migrating the single `LLMProvider` and nine tier fields into rows. It touches every reader of `primaryProvider` and `getModel(for:)`, which is exactly the resolver profiles part 3 owns.
  - It's more general, but it breaks the fence and Brian's "main tiers behave exactly as today" for no v1 gain.

## Fork B: credentials

**Ruled: option 1** (planner; not a question for Brian, since it adds no storage class and no prompts). Conditions:
- **Removal:** removing an endpoint deletes its key from the dict.
- **Masking:** the key field in Settings is a masked field.
- **No leaks:** no key appears in a log, an error string, a test fixture or a request dump. PR 1 checks `requestDumpSink` and the perf dumps, and adds a test for it.
- **A validated slug for `<id>`:** lowercase letters, digits and inner `-`, 1 to 32 characters. A duplicate id is refused at save. Renaming an endpoint moves its key and origin to the new id. A built-in family's id (`gemini`, `anthropic`, `openai`) is refused. The key's name comes from the slug, never from the display name, and its prefix `PROVIDER_` keeps every endpoint key apart from `GEMINI_API_KEY` and its siblings. A test adds an endpoint named "GEMINI" and checks that `GEMINI_API_KEY` is untouched.


- **Option 1 (my lean; it differs from the brief's): keys go in the existing secrets dict.**
  - A custom endpoint's key is stored in the same `com.iris.secrets` item, under `PROVIDER_<id>_API_KEY`. That's the same read-modify-write `updateSecret` that already holds three provider keys.
  - **Prompts (#578): zero new ones.**
    - A dev build already reads that item at launch, so it has already prompted for it once.
    - Writing a new key into it is a write to an item the app already holds.
    - `--seed-dev-home` copies the item as a whole, so seeded dev homes get custom-endpoint keys with no seeder change.
  - **Cost:** one item holds more keys. That's the trade the app already made for three families and the Google OAuth values.
- **Option 2 (the brief's lean): one Keychain item per provider** (`com.iris.provider.<id>` plus the suffix).
  - **For it:** each key's access is separate, and deleting a provider deletes one item.
  - **Prompts:** each new item is created by the binary that writes it. On a dev build, Iris Dev.app gets one more SecurityAgent prompt per provider, the first time it reads that item after a seed or a rebuild that changes the signature. Every GUI check needs the lease and Brian's OK, so that cost repeats.
  - **Seeder:** `storedServicesOrThrow` would have to enumerate and copy `com.iris.provider.*` too.
- **Reason for my lean:** separate items buy little, because the app reads every key into memory anyway, and they cost prompts. If the planner or Brian prefers separate items, it's a contained change in `KeychainManager` and the seeder.
- **Never:** a key in a message, a test, a log line, a tool result or an error string. Settings shows a key as set or not set, never its value. Tests use the in-memory store `KeychainManager` already uses under test, with dummy values.

## Fork C: how a subagent names its model

**Ruled: option 1, on `invoke_subagent`.** The arguments are declared only when a provider besides the primary is usable, with a test both ways. The profile hint is out of v1.


- **Option 1 (lean, v1): `invoke_subagent` gets optional `provider` and `model` arguments.**
  - **Gated (Invariant 6, the credential prerequisite):** both are declared only when the registry holds at least one usable provider besides the primary. `provider`'s description lists the registry's ids, and `model`'s says "an exact model id from that provider's list".
  - **Precedence:** a per-call `provider`/`model` wins. Next comes the provider's default model, which is the provider's medium tier model for a built-in family and the first listed model for a custom endpoint. Last is today's behaviour: no `provider` means the parent's provider and the `effort` tier.
  - **`effort` is unchanged.** With `provider` given, `effort` still picks the tier on a built-in family, and `model` overrides it.
- **Option 2: named subagent definitions**, files that pin a role, prompt and model, like Hermes's `delegation:` block. That's more structure than v1 needs, and it overlaps agent profiles.
- **Option 3: a profile's tier.** Agent profiles (#669) carry a tier, not a provider, and **never apply to subagents** (profiles spec, "What a profile never touches"). So a profile can't be the channel.
- **Dropped (iris-dev-1):** a profile's body can already steer the `provider`/`model` arguments in its own words, so no frontmatter hint is needed.
- **Profiles:** a profiled conversation's subagents still get part 2's tool intersection, whatever provider they run on.

## Fork D: precedence and failure

**Ruled as written.** Check calls only the provider the person clicked, on demand, never at launch.


**Refuse before spawn, never fall back.** A "security lens on DeepSeek" that quietly ran on the parent's model is the wrong review with the right label. Each of these refuses the `invoke_subagent` call before any subagent exists, with one sentence that names what *is* configured:
- **Unknown provider id:** "No provider `deepseek`. Configured for subagents: anthropic, gemini (primary), local-ollama."
- **Missing or empty key, or a built-in family that isn't configured:** "Provider `anthropic` has no key set. Add one in Settings → Models."
- **A model not in that provider's list:** "Model `deepseek` isn't in provider `deepseek-api`'s list: deepseek-v4-pro, deepseek-v4-flash. Use an exact id." That's the bare-alias pitfall: an alias that 404s and a lens that found nothing look the same downstream.
  - For a built-in family, the list is its three tier models plus an optional **extra subagent models** list. That list is kept beside the switch in the Subagent providers section, because the tier fields are the main tiers' and stay untouched.
  - For a custom endpoint, the list is the `models` field.
  - **Model ids are validated** (letters, digits and `. _ : / -`, up to 100 characters), because half 2 puts them in an agent-facing description. An id that fails is dropped at save and at read.

**The Settings check.** Settings has a **Check** button per provider. For a custom endpoint it lists models through `GET /v1/models` (reusing `ModelCatalog`) and marks each configured id found or not found, so a typo shows before a dispatch.

**A failure mid-run** (a 404, a 401 or a quota error from that provider) ends that subagent with an error result naming the provider and model. The parent gets it as the subagent's failure, never a retry on another model.

**Every subagent result names its provider and model**, so the parent and the person can see which model produced which finding.

## Fork E: cost attribution

**Brian ruled (b), per-family prices** (verbatim: "I would go for b, the price model, since it's kind of the point. We can look up those rates dynamically, and yes this is a generalized product that will run in various places."). This is half 2 work.

**The planner's rulings** (no money trade-off in them):
1. **Unit.** Budgets stay in today's weighted-token unit, so no existing job budget migrates. A subagent's usage on another family is converted to primary-equivalent weighted tokens: its dollars at its own rate, divided by the primary's rate. It uses the `CostWeights` split plus cache creation (iris-dev-2's review): input, output, cache read, and cache creation where the provider bills it. Anthropic bills a 5-minute write at 1.25x input and a 1-hour write at 2x, and LiteLLM has `cache_creation_input_token_cost`. A row without a cache creation rate prices those tokens at input.
2. **Ledger.** Each delegated usage row records:
   - the model and its tokens;
   - the rate used;
   - the rate's source and as-of date;
   - an `estimated` flag when it wasn't a known rate.

   `/jobs` and the run card say "estimated" when any part of the run was.
3. **Guarding the rate.** A fetched rate is data that controls a spending cap, and it sits on both sides of rule 1's division. **Every guess may only overcharge.**
   - **Per field** (planner): each rate must be greater than 0, and cache read must not exceed input. A field that fails takes the bundled snapshot's value, marked estimated.
   - **A band against the snapshot** (iris-dev-2's review): a fetched rate more than 10x above or below the snapshot's row for that model is rejected, and the snapshot's value is used, marked estimated. This holds for the primary's rate (the denominator) and for delegated rates alike. Without it, a primary rate 100x too high would make a $5 subagent cost 5 cents of budget.
   - **A model with no snapshot row** (one released after the snapshot) is banded against its family's snapshot range (planner). It may be at most 10x the family's highest rate and at least 1/10 of its lowest. Tested with a fetched row for an id the snapshot lacks.
   - **A family with no snapshot rows at all** (for example a new custom endpoint's) gets absolute bounds (iris-dev-2's review): at least $0.01/MTok and at most $1000/MTok per field. Anything outside takes the fallback, marked estimated. Within them, the file's rate is used and marked estimated, and the docs say so.
   - **An unknown primary rate** (no row, no snapshot) uses the **lowest** known rate in the primary's family, marked estimated. A small denominator overcharges.
   - **An unknown delegated rate** is charged at its family's highest known rate (Brian's Q2, below), which also only overcharges.
   - **What's left:** a rate that is wrong but nonzero, within the band, and not above input can't be caught mechanically. The docs say the caps rest on the price file's accuracy within that band.
   - A rejected rate is logged once per refresh, with the model and the rule it broke.
4. **Local loopback models** really cost $0. They still count tokens at the primary's weights for the budget, so a local runaway still stops.
5. **Caching.** Rates are cached with their as-of date, refreshed at most daily and on a Settings Check. A failed refresh keeps the last good cache.

**Brian's decisions on the two choices** (verbatim: "a for q2.  q1 (i+iii) sounds pretty good to start with"):
- **Q1, the price source: (i) plus (iii).**
  - LiteLLM's public price file supplies the defaults, with the bundled snapshot as its fallback, under rule 3's guards.
  - Rates typed in Settings override any model.
  - An OpenRouter endpoint uses OpenRouter's own `/api/v1/models` prices.
  - The ledger's source field reads `litellm`, `snapshot`, `settings`, `settings (clamped)` or `openrouter`.
- **Q2, a model with no known rate: (a).** It's charged at its family's highest known rate, marked estimated. It never overspends, and may stop early.
- **Rejected:** (ii) a table Iris publishes; (b) refusing other-family subagents in job runs; (c) the primary's rate.

**Typed rates (planner's revised ruling).** A rate kept in defaults can be set by one approved `defaults write` (#678's class), so a typed rate isn't trusted downward:
- **The safe direction depends on the rate's side of rule 1's division** (iris-dev-2's review):
  - **A delegated rate (the numerator)** may go up freely. Going down, it's held to the same floor and the same 1/10-of-snapshot limit as fetched rates, using the family range for an id missing from the snapshot.
  - **The primary's rate (the denominator)** may go down freely. Going up, it's held to 10x the snapshot, or $1000/MTok for a family with no snapshot rows. Raising it would shrink every delegated charge.
  - **The rule applies per use.** A model used both as the primary and by a subagent is bounded by whichever side it's on in that conversion.
  - Settings refuses an out-of-bounds value with a sentence naming the limit.
- **At use time** the rate is clamped to those bounds again, so a value written behind the UI's back is clamped too. The ledger marks it `settings (clamped)`.
- **Storage and clearing:** typed rates live in defaults, per provider and model id, decoded with `decodeIfPresent`. Clearing one goes back to the fetched rate.
- **Tests:** a delegated rate written straight to the store below the band is clamped at use time, and an upward delegated override is honoured. A primary rate written straight to the store at 100x its snapshot is clamped to 10x, and a downward primary override is honoured.
- **Out of scope here:** protecting the settings that guard spend and egress (base URLs, budgets, rates) is #678's job, widened by the planner to cover all three.

**The LiteLLM check (iris-dev-3, 2026-10-19).** `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json` returned HTTP 200, 2.9 MB, with 4,223 entries. Each entry gives `input_cost_per_token`, `output_cost_per_token` and `cache_read_input_token_cost` in USD per token, plus `litellm_provider`.

Lookups for the current ids:

| id | input | output | cache read | key |
| --- | --- | --- | --- | --- |
| `gemini-3.8-flash` | 7.5e-7 | 3.75e-6 | 7.5e-8 | `gemini/gemini-3.8-flash` (also bare, as `vertex_ai`) |
| `claude-fable-5-1` | 1e-5 | 5e-5 | 2.5e-7 | bare, `anthropic` |
| `deepseek-v4-pro` | 1.32e-6 | 3.96e-6 | 4.4e-8 | bare and `deepseek/` |

`claude-opus-5-5`, `claude-sonnet-5-5` and `claude-sonnet-4-6` are present too. What a lookup must handle:
- **Keys vary by host.** The same model appears under several hosts at different prices (`azure_ai/deepseek-v4-pro`, `dashscope/deepseek-v4-pro`, Bedrock's `anthropic.claude-fable-5-1`). A lookup matches the family's own `litellm_provider` (`anthropic`, `gemini`, `openai`, `deepseek`), and an endpoint names its LiteLLM provider. A bare-id match on another host's row is never used.
- **`sample_spec` has 0 for every rate**, an example of why rule 3's floor is needed.
- **Cache-read ratios differ by model, and the file has them right.** `claude-fable-5-1`'s cache read is 2.5% of input (2.5e-7 against 1e-5), not the usual 10%. Anthropic's pricing page (platform.claude.com, checked 2026-10-19) lists Claude Fable 5.1 cache hits at $0.25/MTok against $10/MTok input, "0.025x on Claude Fable 5.1". Opus 5.5 and Sonnet 5.5 are 0.05x ($0.20 and $0.10), matching their rows, and Sonnet 4.6 is 0.1x. So a fixed-ratio check would have rejected correct prices, and rule 3 doesn't use one.
- **Size.** 2.9 MB fetched at most daily is fine. The bundled snapshot keeps only the rows for the families Iris supports.

**Today everything assumes one provider:**
- `TokenUsage` has no provider field.
- `CostWeights.weighted(_:provider:model:)` (CostWeights.swift:86) prices a whole run, delegated usage included, at the run's single provider and model, and its comment says so.
- `JobRun.provider`/`tier`/`model` are stamped once from the global (JobRunner.swift:1079).
- `TurnBudget` carries one provider and model.

**What half 2 changes (under the rulings above):**
- **Ledger rows.** Delegated usage is recorded per model: a new `delegatedUsage` list on the background run's usage and on `JobRun`, each row holding the model, its tokens, the rate, its source and as-of date, and `estimated`. It's read with `decodeIfPresent`, and gets a new ledger column.
- **`weighted` and `TurnBudget`.** `weighted` converts each delegated row to primary-equivalent weighted tokens (rule 1) and prices the run's own usage as today. `TurnBudget` charges a subagent's tokens the same way, as they arrive.
- **Unchanged:** `JobRun.provider`/`model` stay the run's own engine, as today.

**Attended conversations:** `TokenUsage` on the conversation keeps its total. The subagent's own conversation row records its provider and model, so the split can be read from there. No new field on the attended path in v1.

## Fork F: the guard tiers don't change

**Ruled as written.** Half 2 states this in `docs/delegation.md` as well, when subagents can first use another provider.

**The trust change (iris-dev-2's review).** A subagent on a custom endpoint makes that endpoint both an injection source and the caller: the model behind it chooses the subagent's tool calls.
- **Unchanged:** those calls go through approval and Vibecop like any subagent's, and the subagent's result reaches the parent as tool output, sanitised by P1-P3 like any tool output.
- **Ruled (planner, half 2):** every approval dialog raised by a subagent on a non-primary family names the provider and model that asked, for example "asked by subagent on DeepSeek · deepseek-v4-pro". The person can't weigh the source if the dialog hides it.
- **Brian ruled (a)** (verbatim: "1: a"): an approval asked for by a subagent on a **custom endpoint** offers **Allow Once only**, with no Always Allow. Subagents on a **built-in family** keep today's dialog, with the source named as above. The options he didn't choose were (b), today's dialog for everyone, and (c), Allow Once only for every non-primary family. This is half 2 work, with a test that a custom-endpoint subagent's dialog has no Always Allow and a built-in family's does.


Vibecop and the prompt-injection guard (P1 structural, P2 classifier, P3 canary) judge a subagent's calls and tool output **exactly as now, whatever model the subagent runs on**:
- Approval is `executeFunctionCall` → `requestApprovalSource(callerRole: .agent)` in the shared dispatch.
- Output sanitising (iris.swift:5524-5561) is keyed by the tool, not the model.
- No path in either half lets a subagent's provider choice change a guard's model, threshold or verdict.

**One dependency to state:** Vibecop's **cloud** engine calls `LLMClient().generateContent(tier: .easy, …)`, which goes through the **primary** provider (CloudAuxiliaryEngine.swift:11). It stays on the primary. A subagent provider never becomes Vibecop's judge, and the "Usable by subagents" switch never applies to Vibecop's cloud engine. So the primary must stay configured for a cloud Vibecop, as today.

## Half 1 (PR 1) in detail

**`ConfigManager`, new fields only:**
- `subagentProviders: [ProviderEndpoint]` (the JSON in defaults, decoded per entry);
- `subagentBuiltIns: [String: BuiltInSubagentUse]`, keyed by `LLMProvider` raw value, holding `enabled` (default false) and `extraModels`, in the same JSON shape;
- a pure `providerRegistry() -> [RegisteredProvider]`, which returns the built-in families that are `isConfigured` plus the custom endpoints, each with its id, kind, model list and a configured flag.

It doesn't add or change any tier or model resolver. Profiles part 3 owns those.

**`LLMClient`:**
- A new initializer, `LLMClient(route: ProviderRoute)`. A route is a resolved provider kind, base URL, credentials and model.
- With a route, every call goes to that provider and model and never reads `primaryProvider` or `getModel(for:)`.
- `LLMClient()` with no route is byte-for-byte today's behaviour.
- `OpenAIClient` takes the custom base URL and key it already takes for the built-in family.
- In PR 1, nothing in the engine constructs a routed client. Settings' **Check** is the only live caller. Half 2 wires it to subagents.

**`SettingsView`:** a **Subagent providers** section on the Models tab.
- It shows each non-primary built-in family with its key state, a **Usable by subagents** switch (off by default), and its extra subagent models.
- It shows the custom endpoints, each with name, base URL, key (set or not set), model ids, Check and Remove.
- **Add endpoint** offers presets that fill the base URL: DeepSeek, OpenRouter, Ollama local, and Custom.
- It never shows a key's value.

**Secret store:** `PROVIDER_<id>_API_KEY` in the existing dict (Fork B option 1). Removing an endpoint removes its key.

**Seeder:** no change under Fork B option 1. The test asserts that a seeded dev home gets a custom endpoint's key along with the dict.

**Tests (Swift Testing, injected `ConfigManager(store:)` and the in-memory secret store):**
- An install with no `SUBAGENT_PROVIDERS` key has a registry of just the configured built-ins. A bad entry is dropped alone, and the rest decode.
- A routed client sends to the route's provider, base URL and model (stubbed `URLProtocol`), and `primaryProvider` changing mid-test doesn't move it.
- `LLMClient()` with no route still follows `primaryProvider`, which pins the main path.
- Adding and removing an endpoint writes and removes `PROVIDER_<id>_API_KEY`. No key text appears in any logged or displayed string the tests capture.
- Check marks found and not-found ids from a stubbed `/v1/models`.

**Docs:** a `docs/features.md` section, or `docs/subagent_providers.md` if it outgrows about 300 words, saying that subagent providers exist and how to add one. **No agent-facing string changes in PR 1**, because no tool argument appears until half 2.

## Half 2 (PR 2) in outline

- **`invoke_subagent`:** gated `provider` and `model` arguments (Fork C), with the refusals before spawn (Fork D).
  - `SubagentManager.runSubagent` takes a `route`.
  - The subagent engine gets `client: LLMClient(route:)` and `provider: route.kind`, so pills and thinking replay are right.
- **The global readers become route-aware for a routed engine,** through profiles part 3's per-turn `turnModel` seam (iris-dev-1). Part 3 adds the seam at the profiler and `maxTokens` reads (iris.swift ~2841, ~2979), and half 2 extends how it is computed, with the route winning. The two PRs then don't each patch those lines. If half 2 lands before part 3, half 2 adds the seam itself and part 3 extends it, so whichever lands second rebases onto the one seam. The readers are the profiler's model name, `maxTokens` (Anthropic only, by the route's model), and the rotation summary. The main engine keeps reading the global, unchanged.
- **The subagent result** names its provider and model.
- **Cost:** per-model delegated usage, priced as Brian rules on Fork E.
- **`delegate_milestone`:** no `provider` in v2. Goal milestones stay on the parent's provider, because the grader judges them and mixing families there isn't asked for.
- **Docs and agent-facing strings (Invariant 9):** `invoke_subagent`'s description, the subagent section of the system prompt, and `docs/delegation.md` (including Fork F's guard statement).

## Out of scope

- Mixing providers in the main tiers (Brian's constraint).
- Custom endpoints of Gemini or Anthropic kind (the built-ins cover them).
- Dollar pricing.
- A per-job default subagent provider (`schedule_job`); a job's subagents follow the same arguments.
