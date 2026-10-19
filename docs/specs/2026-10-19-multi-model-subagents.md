# Subagents on other model families (#239)

**Status:** spec, iris-dev-3, 2026-10-19, with the planner's rulings on forks A-F folded in. Fork E's option goes to Brian. Reviewers: iris-dev-1 first (it owns the resolver that agent profiles part 3 changes), iris-dev-2 second. The planner rules the forks; anything about Brian's money or credentials goes to Brian through the Overseer.

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

**For Brian (the planner is asking him now; it's half 2's question).** The options:
- **(a)** Count delegated tokens from another family at the run's own weights. A budget then caps weighted tokens, not dollars, and the docs say so. The ledger still shows tokens per model. *(Planner's recommendation.)*
- **(b)** Per-family weights, which need a price table someone keeps current.
- **(c)** Refuse other-family subagents inside job runs in v1.

The analysis below stands whichever is ruled.


**Today everything assumes one provider:**
- `TokenUsage` has no provider field.
- `CostWeights.weighted(_:provider:model:)` (CostWeights.swift:86) prices a whole run, delegated usage included, at the run's single provider and model, and its comment says so.
- `JobRun.provider`/`tier`/`model` are stamped once from the global (JobRunner.swift:1079).
- `TurnBudget` carries one provider and model.

**Half 2, lean:**
- Delegated usage is recorded per provider and model. A new `delegatedUsageByModel: [String: TokenUsage]` on the background run's usage and on `JobRun`, with `decodeIfPresent` and a new ledger column.
- `weighted` prices each delegated entry at its own provider's rates and the run's own usage at the run's.
- `TurnBudget` charges a subagent's tokens at the subagent's provider weights.
- `JobRun.provider`/`model` stay the run's own engine, as today.

**Open for the planner:** weighted-token budgets (`CostWeights`) are relative, not dollars. A cheap provider's tokens weigh less, so a budget stretches further on it. That's correct, but it means a budget doesn't cap dollars across families. Pricing in dollars is out of scope here.

**Attended conversations:** `TokenUsage` on the conversation keeps its total. The subagent's own conversation row records its provider and model, so the split can be read from there. No new field on the attended path in v1.

## Fork F: the guard tiers don't change

**Ruled as written.** Half 2 states this in `docs/delegation.md` as well, when subagents can first use another provider.

**The trust change (iris-dev-2's review).** A subagent on a custom endpoint makes that endpoint both an injection source and the caller: the model behind it chooses the subagent's tool calls.
- **Unchanged:** those calls go through approval and Vibecop like any subagent's, and the subagent's result reaches the parent as tool output, sanitised by P1-P3 like any tool output.
- **Ruled (planner, half 2):** every approval dialog raised by a subagent on a non-primary family names the provider and model that asked, for example "asked by subagent on DeepSeek · deepseek-v4-pro". The person can't weigh the source if the dialog hides it.
- **Open fork, for Brian** (it changes the approval ladder and its prompt cost, as #652 did):
  - **(a)** Custom endpoints offer Allow Once only; built-in families keep today's dialog. *(The planner's recommendation and my lean.)*
  - **(b)** Today's dialog for everyone, with the source named.
  - **(c)** Allow Once only for every non-primary family.
  - Half 2 builds neither until he answers.


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
