# Subagents on other model families (#239)

**Status:** draft spec, iris-dev-3, 2026-10-19. Reviewers: iris-dev-1 first (it owns the resolver that agent profiles part 3 changes), iris-dev-2 second. The planner rules the forks; anything about Brian's money or credentials goes to Brian through the Overseer.

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

- **Option 1 (lean): the primary stays as today, with subagent providers beside it.**
  - `primaryProvider` and the nine tier fields are untouched. Nothing migrates.
  - A subagent may name any provider in the registry: the three built-in families whenever `isConfigured(provider:)` holds for them, plus **custom endpoints** the person adds. A person who already has an Anthropic key set while Gemini is primary gets Anthropic for subagents with no new setup.
  - A custom endpoint is `ProviderEndpoint { id, name, kind, baseURL, models: [String], needsKey: Bool }`.
    - `kind` is `openAICompatible` in v1. That covers DeepSeek, OpenRouter, Together, and Ollama's or LM Studio's local `/v1`.
    - Gemini and Anthropic don't need a custom kind: the built-in families cover them.
  - Persisted in the app's defaults domain as JSON under one key (`SUBAGENT_PROVIDERS`). Each field is read with `decodeIfPresent` and a default. An entry that doesn't decode is dropped on its own and reported once in Settings, never the whole list (the Invariant 1 shape).
- **Option 2: a flat list with a primary flag.**
  - Every provider would become a row, and `primaryProvider` would be derived from the flag.
  - That means migrating the single `LLMProvider` and nine tier fields into rows. It touches every reader of `primaryProvider` and `getModel(for:)`, which is exactly the resolver profiles part 3 owns.
  - It's more general, but it breaks the fence and Brian's "main tiers behave exactly as today" for no v1 gain.

## Fork B: credentials

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

- **Option 1 (lean, v1): `invoke_subagent` gets optional `provider` and `model` arguments.**
  - **Gated (Invariant 6, the credential prerequisite):** both are declared only when the registry holds at least one usable provider besides the primary. `provider`'s description lists the registry's ids, and `model`'s says "an exact model id from that provider's list".
  - **Precedence:** a per-call `provider`/`model` wins. Next comes the provider's default model, which is the provider's medium tier model for a built-in family and the first listed model for a custom endpoint. Last is today's behaviour: no `provider` means the parent's provider and the `effort` tier.
  - **`effort` is unchanged.** With `provider` given, `effort` still picks the tier on a built-in family, and `model` overrides it.
- **Option 2: named subagent definitions**, files that pin a role, prompt and model, like Hermes's `delegation:` block. That's more structure than v1 needs, and it overlaps agent profiles.
- **Option 3: a profile's tier.** Agent profiles (#669) carry a tier, not a provider, and **never apply to subagents** (profiles spec, "What a profile never touches"). So a profile can't be the channel.
- **How it composes with profiles later:** a profiled conversation's subagents still get part 2's tool intersection, whatever provider they run on. If a profile later wants a lens roster (for example, "reviewer" dispatching security to DeepSeek), it adds a `subagent_providers:` hint that pre-fills the arguments, and the arguments stay the one mechanism. **To check with iris-dev-1 in review.**

## Fork D: precedence and failure

**Refuse before spawn, never fall back.** A "security lens on DeepSeek" that quietly ran on the parent's model is the wrong review with the right label. Each of these refuses the `invoke_subagent` call before any subagent exists, with one sentence that names what *is* configured:
- **Unknown provider id:** "No provider `deepseek`. Configured for subagents: anthropic, gemini (primary), local-ollama."
- **Missing or empty key, or a built-in family that isn't configured:** "Provider `anthropic` has no key set. Add one in Settings → Models."
- **A model not in that provider's list:** "Model `deepseek` isn't in provider `deepseek-api`'s list: deepseek-v4-pro, deepseek-v4-flash. Use an exact id." That's the bare-alias pitfall: an alias that 404s and a lens that found nothing look the same downstream.
  - For a built-in family, the list is its three tier models plus any model the person adds there.
  - For a custom endpoint, the list is the `models` field.

**The Settings check.** Settings has a **Check** button per provider. For a custom endpoint it lists models through `GET /v1/models` (reusing `ModelCatalog`) and marks each configured id found or not found, so a typo shows before a dispatch.

**A failure mid-run** (a 404, a 401 or a quota error from that provider) ends that subagent with an error result naming the provider and model. The parent gets it as the subagent's failure, never a retry on another model.

**Every subagent result names its provider and model**, so the parent and the person can see which model produced which finding.

## Fork E: cost attribution

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

Vibecop and the prompt-injection guard (P1 structural, P2 classifier, P3 canary) judge a subagent's calls and tool output **exactly as now, whatever model the subagent runs on**:
- Approval is `executeFunctionCall` → `requestApprovalSource(callerRole: .agent)` in the shared dispatch.
- Output sanitising (iris.swift:5524-5561) is keyed by the tool, not the model.
- No path in either half lets a subagent's provider choice change a guard's model, threshold or verdict.

**One dependency to state:** Vibecop's **cloud** engine calls `LLMClient().generateContent(tier: .easy, …)`, which goes through the **primary** provider (CloudAuxiliaryEngine.swift:11). It stays on the primary. A subagent provider never becomes Vibecop's judge, so the primary must stay configured for a cloud Vibecop, as today.

## Half 1 (PR 1) in detail

**`ConfigManager`, new fields only:**
- `subagentProviders: [ProviderEndpoint]` (the JSON in defaults, decoded per entry);
- a pure `providerRegistry() -> [RegisteredProvider]`, which returns the built-in families that are `isConfigured` plus the custom endpoints, each with its id, kind, model list and a configured flag.

It doesn't add or change any tier or model resolver. Profiles part 3 owns those.

**`LLMClient`:**
- A new initializer, `LLMClient(route: ProviderRoute)`. A route is a resolved provider kind, base URL, credentials and model.
- With a route, every call goes to that provider and model and never reads `primaryProvider` or `getModel(for:)`.
- `LLMClient()` with no route is byte-for-byte today's behaviour.
- `OpenAIClient` takes the custom base URL and key it already takes for the built-in family.
- In PR 1, nothing in the engine constructs a routed client. Settings' **Check** is the only live caller. Half 2 wires it to subagents.

**`SettingsView`:** a **Subagent providers** section on the Models tab.
- It shows the built-in families with "configured, and usable by subagents" or "no key".
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
- **The global readers become route-aware for a routed engine:** the profiler's model name, `maxTokens` (Anthropic only, by the route's model), and the rotation summary. The main engine keeps reading the global, unchanged.
- **The subagent result** names its provider and model.
- **Cost:** per-model delegated usage (Fork E).
- **`delegate_milestone`:** no `provider` in v2. Goal milestones stay on the parent's provider, because the grader judges them and mixing families there isn't asked for.
- **Docs and agent-facing strings (Invariant 9):** `invoke_subagent`'s description and the subagent section of the system prompt.

## Out of scope

- Mixing providers in the main tiers (Brian's constraint).
- Custom endpoints of Gemini or Anthropic kind (the built-ins cover them).
- Dollar pricing.
- A per-job default subagent provider (`schedule_job`); a job's subagents follow the same arguments.
