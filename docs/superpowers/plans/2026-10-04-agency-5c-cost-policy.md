# Agency 5c: Cost Policy, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settle the three settings 5a's measurements raised, for every conversation:
- State-gated tool declarations stop flapping. Once declared in a conversation they stay, and dispatch refuses them in the off state.
- Budgets count **weighted tokens**: input, cache reads, cache writes and output, each at its own weight, priced per provider from raw components the ledger now keeps.
- Anthropic cache entries use a 1-hour TTL where 5-to-60-minute gaps are the norm (Iris, and the shared background prefix when a job fires more often than hourly). OpenAI gets `prompt_cache_key`.

**Architecture:**
- A transient `StickyTools` map on `AppState` turns each state gate in `processInputBody` into `gate || sticky`, so a tool keeps its position in the list. A single hard-strip pass then removes whatever the conversation may never have, so a strip always wins.
- A pure `CostWeights` table prices `UsageComponents`. The ledger stores components and the run's provider (migration `v15_job_run_cost`). Weighted totals are computed at read time and never stored.
- A `CacheHints` value rides `GeminiRequest` in a field that is never encoded. It carries a `CacheTTLPolicy` (prefix vs history) and a cache key, and the Anthropic and OpenAI clients read it.
- The perf harness gains a cost column, per-turn pauses, background runs and experiment switches for the real-lane measurements.

**Tech Stack:** Swift 6, SwiftUI, GRDB (`ConversationStore`, `JobLedger`), Swift Testing.

**Spec:** `docs/specs/2026-10-04-agency-cost-policy.md` (PR #350; the owner has not reviewed it yet). Read its §0 before any task. "Decision N" below means §0.N. Where this plan departs from the spec, see **Plan notes**. Each departure is a proposed ruling for the owner.

## Global Constraints

- **Invariant 1, and the memory lesson that a persisted field needs both halves.**
  - A new field on a persisted type needs a lenient decode, and it needs somewhere to persist.
  - `TokenUsage.cacheWrite1hTokenCount` decodes with `decodeIfPresent`. It persists inside the existing `conversations.tokenUsage` JSON column, so it needs no new column. Say so in the commit.
  - `UsageMetadata.cacheWrite1hTokens` and `EventCard.weightedTokens` decode with `decodeIfPresent`.
  - `JobRun` isn't `Codable`; its rows decode through `RowReader`. Its invariant-1 analogue is the migration **plus** `run(from:)` reading every new column with `r.read(...)`, so NULL becomes 0 or nil. Do all three, or the field silently vanishes.
  - The migration is `v15_job_run_cost`, registered after `v14_job_action` (`ConversationStore.swift:496`). Before writing it, confirm that no `v15_*` exists on main.
- **Invariant 7: no process globals in tests.**
  - Never mutate `ConfigManager.shared`; build a `ConfigManager(store:)` over your own suite.
  - Use `ConversationStore.inMemory()`, `FactStoreManager(inMemory: true)`, `protectionEnabled: false`, the `sessionPeerCount:` override, and the new `stickyTools:` / `cacheTTLOverride:` init seams.
  - `StickyTools` lives on each `AppState`, never in a static.
- **Bounded runs.** Run every focused test as `timeout 300 scripts/test-filter.sh <TypeName>` and quote the count it ran. Run the full suite as `timeout 900 swift test`. A test that waits on anything asynchronous waits with a bound (`withTimeout(seconds:)` or a polled deadline), never on wall-clock sleeps. The perf pause is injected as a sleeper in tests (Task 20).
- **A full suite is green only on all three:** exit 0, the Swift Testing line `Test run with N tests … passed`, and XCTest's `Executed N tests, with 0 failures`.
- **UTF-8 byte caps, never `String.count`.** `prompt_cache_key` is capped at 64 UTF-8 bytes with `ConversationReader.utf8Prefix(_:maxBytes:)`. Any new string bound in this deliverable uses the same helper.
- **Sign before running.** Any binary built and then executed (perf, `iris --run-job`, a manual check) is signed first with `scripts/sign.sh .build/release/iris` (or the debug path). Otherwise the Keychain re-prompts and an unattended perf run blocks. `perf/run.sh` already signs; a hand-built binary doesn't.
- **Real-lane perf spends the owner's money.** Task 22's runs need the owner's explicit approval at execution time, with the arm list and the estimated spend in the request. Don't start one on the strength of this plan.
- **Invariant 9.** Every PR ends with a task that greps for what it made untrue, in `README.md`, `docs/`, `AGENTS.md`, comments, and agent-facing strings (tool `description`s, `SYSTEM.md`, turn-context text). Each such task lists the greps to run; run them and read every hit.
- **One branch per PR, each based on `main`, never stacked.**
  - PRs A, B and C are independent of each other.
  - PR D is cut from `main` only after A, B and C have merged.
  - Conventional commits, each ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Units.** The budget unit is spelled **weighted tokens** in every string a person or a model reads. Raw counts (`promptTokens`, `totalTokens`) keep their names: they are still raw.

## Review Focus

1. **A sticky declaration resurrected past a hard strip.** A conversation whose sticky set holds `send_to_session` and `manage_fact` becomes a read-only job run (or the engine is a `.subagent`). The peer tools and job-creation tools must not reach its tool list. The read-only allowlist must still hold. Test: Task 2, `stickyNeverSurvivesHardStrips`.
2. **A sticky tool moves in the list.** If the union appended sticky tools at the end instead of at their gated position, the tool array would reorder the turn after a gate turns off, and Anthropic's prefix would miss every time. Test: Task 5 asserts the shared entries' relative order as well as superset and byte equality.
3. **The streamed path drops the 1-hour split.** `LLMStreamAssembler.apply(.usage)` merges usage field by field (`LLMStream.swift:100-107`). A new field it doesn't merge makes every streamed Anthropic round price 1-hour writes at 1.25. Test: Task 7, `streamAssemblerCarriesOneHourSplit`.
4. **Legacy rows and legacy reason strings.** Pre-5c `job_runs` rows (NULL provider and cache columns) must load and price at r = w = 1. A job paused before 5c with `daily token budget reached …` must still read as `budget` in the briefing after the reason is renamed. So must a row closed with `budget: tokens exceeded`. Tests: Task 10 (`v15KeepsRowsAndPricesThemUnknown`) and Task 12 (`legacyBudgetReasonsStillMatch`).
5. **Cache hints leaking or vanishing.** If `cacheHints` were encoded, Gemini would get an unknown field (HTTP 400) and hooks would get a new key. If a `BeforeModel` hook rewrites the request, the decoded copy has no hints and Iris silently falls back to 5 minutes. Tests: Task 14 (`geminiBodyIsByteIdenticalWithHints`, `beforeModelRewriteKeepsHints`).

## Plan notes: where the spec and the code disagree (proposed rulings)

1. **There is no `buildRequest`.** Declaration assembly is inline in `IrisEngine.processInputBody` (`iris.swift:1476-1876`), and the "hard strips" aren't one stage:
   - job-creation tools are stripped at `:1484`, *before* most declarations are appended;
   - `set_workspace` and the peer tools are never appended for an unattended turn (`:1487`, `:1708`);
   - the read-only allowlist runs at `:1808`, the evaluator restriction at `:1826`, and the goal-complete filter at `:1873`.

   *Ruling:* stickiness is `|| sticky.contains(name)` on each existing gate, so a tool keeps its position. Then one new `hardStrip` pass, placed immediately before the read-only strip at `:1808`, removes again everything an unattended turn or a non-main principal may never have. The spec's "union before strips, strip wins" holds, at the point the code actually has.
2. **`reach_checkpoint` already has a final-milestone guard.** `iris.swift:3651-3654` refuses at the final milestone, and `:3647-3650` refuses with no ladder. `delegate_milestone` has both (`:3662-3671`), and `DelegateMilestoneTests.finalMilestoneIsRefused` (`:265`) pins one. *Ruling:* no new code for either; Task 4 adds the missing tests. New guards are needed only for the three peer tools. `manage_fact` has no dangerous off state: see below.
3. **`set_workspace` isn't state-gated.** Its only gate is `!isUnattended`, and `isBackground` is fixed for a conversation's life, so it can't flap. *Ruling:* it isn't sticky-eligible. Its off-state refusal (`:2992`) and test (`UnattendedWorkspaceTests`) already exist. Task 2's hard-strip test still seeds it, to prove that a seeded name can't get past the strip.
4. **`goal_complete` is state-gated, and the spec doesn't list it.** It's declared on `hasActiveGoal || restrictToGoalComplete` (`:1606`) and flaps off when a goal ends: the same removal flap on the longest history that decision 3 is about. *Ruling:* it's sticky-eligible. Its off-state guard already exists (`:3548-3551`, "No goal is active …"), and Task 4 tests it.
5. **The pinned-only job tools aren't sticky.** `isPinned` is identity, not state. It changes only when `/new` rotates, and the old conversation is archived then. A sticky job tool in an unarchived former Iris would widen the pinned-only surface. Dispatch refuses it, but undeclared is the half that holds without a refusal.
6. **Stickiness applies only to attended main conversations.** The spec says the main principal only. A job run is also `.main`, but it's a fresh conversation with one turn, so a sticky set can't help it, and recording one would add a map entry per fire forever. *Ruling:* record and apply only when `principal == .main && !isUnattended`.
7. **"A row with no provider is priced at r = w = 1, which is today's behaviour."** That's exactly right: a provider-less (pre-5c) row is priced at its plain `totalTokens` — every component at weight 1, output included, which is today's behaviour. There's no ×5 output weight to apply because there's no `outputTokens` component on the row to weight; `totalTokens` is the whole figure, already folding output in. *Ruling:* price a provider-less row at plain `totalTokens`, with no exceptions. Ruling 10 (below) treats an old event card's frozen `totalTokens` the same way, for the same reason.
8. **"Uncached input" and "output" aren't stored directly.** Every provider's prompt count already folds in cache reads and writes (5a). Gemini's `totalTokenCount` also includes thinking tokens, which `candidatesTokenCount` doesn't. *Ruling:*
   - uncached = `prompt − cacheRead − cacheWrite`, floored at 0;
   - output = `max(candidates, total − prompt)`, so Gemini thinking is charged as output.

   `JobLedgerPolicyTests.makeRun` sets only `totalTokens`. Under this ruling that row reads as all output, so the helper must also set `promptTokens = tokens` (Task 11).
9. **Persisted budget-reason strings are matched by text.** `Briefing.reasonWord` (`Briefing.swift:63-64`), `Briefing.pausedWord` (`:84`) and `JobRunner.budgetStopReason` (`JobRunner.swift:1777-1781`) match `daily token budget reached` (prefix) and `budget: tokens exceeded` (exact) on rows and paused jobs written before 5c. *Ruling:* rename both to the weighted unit, and keep `legacy…` constants that the three matchers also accept.
10. **An event card stores a frozen `totalTokens`** (`EventCard.swift:34`), persisted as message JSON. *Ruling:* add `weightedTokens: Int?`, decoded with `decodeIfPresent`. A new card shows "4.2k weighted tokens"; an old card keeps "4.2k tokens", which was true when it was written — the same plain-`totalTokens` pricing as ruling 7, for the same legacy rows.
11. **`GeminiRequest` has synthesized `Codable` and is encoded verbatim.** Gemini's body (`LLMClient.encodeGeminiBody`) and the hook payload (`HookManager.fireBeforeModel`) both encode it, and a hook's rewrite is decoded back (`iris.swift:1952-1955`). *Ruling:* `cacheHints` is excluded through `CodingKeys` and re-applied after a hook rewrite.
12. **The spec's r for Gemini and OpenAI is per provider, but the real ratio is per model.** *Ruling:* pin the ratio of each provider's default medium model (`gemini-3.5-flash`, `gpt-5.6-terra`, `ConfigManager.swift:429,437`), and check it against the published pricing page on the day, as Task 9 says. A per-model table is a follow-up only if the cost column (Task 19) shows the error matters.
13. **Which jobs count as firing "more often than hourly"?** Only `.schedule` triggers with `action == .prompt`, enabled and not paused. A `.poll` job ticks on its cadence but runs a model turn only when its gate says CHANGED. A watch is bursty. A built-in spends no tokens. None of those three would keep a prefix warm on a predictable cadence.
14. **`list_jobs` key names.** The model reads `tokensToday` / `tokensTodayAllJobs`. *Ruling:* rename them to `weightedTokensToday` / `weightedTokensTodayAllJobs`. A key named "tokens" holding a weighted figure is the stale agent-facing string invariant 9 is about. `JobToolsTests:171,180,226,232` move with them.
15. **AGENTS.md invariant 6 says "gate declaration on that state".** Stickiness changes that rule ("…and once declared, keep it declared for the conversation"). Task 6 updates the invariant. Flag it in the PR, because it changes a standing project rule.

---

## PR A: sticky declarations

Branch: `feat/agency-5c-sticky-tools`, based on `main`.

### Task 1: `StickyTools`, held by `AppState`

**Files:**
- Create: `Sources/iris/StickyTools.swift`.
- Modify `Sources/iris/AppState.swift`:
  - beside `activeRuns` (`:355`): add `@ObservationIgnored var stickyTools = StickyTools()`;
  - in `deleteConversation` (`:1511`): call `stickyTools.forget(id)`.
- Test: `Tests/irisTests/StickyToolsTests.swift` (new).

**Interfaces:**
- Produces:
  - `struct StickyTools: Sendable`, with `static let eligible: Set<String>`;
  - `func names(for id: UUID) -> Set<String>`;
  - `mutating func record(_ declared: some Sequence<String>, for id: UUID)`, which intersects with `eligible`;
  - `mutating func forget(_ id: UUID)`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

@Suite struct StickyToolsTests {
    @Test func recordsOnlyEligibleNames() {
        var s = StickyTools()
        let id = UUID()
        s.record(["manage_fact", "run_command", "schedule_job", "goal_complete"], for: id)
        #expect(s.names(for: id) == ["manage_fact", "goal_complete"])
    }

    @Test func onlyGrows() {
        var s = StickyTools()
        let id = UUID()
        s.record(["manage_fact"], for: id)
        s.record(["reach_checkpoint", "delegate_milestone"], for: id)
        s.record([], for: id)
        #expect(s.names(for: id) == ["manage_fact", "reach_checkpoint", "delegate_milestone"])
    }

    @Test func aNewConversationStartsEmptyAndForgetClears() {
        var s = StickyTools()
        let a = UUID(), b = UUID()
        s.record(["manage_fact"], for: a)
        #expect(s.names(for: b).isEmpty, "a new conversation (or a rotation's new Iris) starts empty")
        s.forget(a)
        #expect(s.names(for: a).isEmpty)
    }

    @Test func eligibleSetIsTheStateGatedTools() {
        #expect(StickyTools.eligible == ["manage_fact", "list_sessions", "send_to_session", "set_session_card",
                                         "amend_goal_contract", "reach_checkpoint", "delegate_milestone",
                                         "waive_criterion", "goal_complete"])
        // Never the workflow triggers (decision 1), the pinned-only job tools (plan note 5) or
        // set_workspace (plan note 3).
        for name in ["rename_conversation", "propose_goal_contract", "schedule_job", "list_jobs", "set_workspace"] {
            #expect(!StickyTools.eligible.contains(name), Comment(rawValue: name))
        }
    }

    @MainActor
    @Test func deletingAConversationForgetsItsSet() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let id = UUID()
        state.createNewConversation(id: id)
        state.stickyTools.record(["manage_fact"], for: id)
        state.deleteConversation(id)
        #expect(state.stickyTools.names(for: id).isEmpty)
    }

    @MainActor
    @Test func archivingKeepsTheSet() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let id = UUID()
        state.createNewConversation(id: id)
        state.createNewConversation(id: UUID())   // so archiving `id` is allowed
        state.stickyTools.record(["manage_fact"], for: id)
        _ = state.archiveConversation(id)
        #expect(state.stickyTools.names(for: id) == ["manage_fact"], "an archived conversation can come back")
    }
}
```

Check `AppState(store:)` against the 5b plan's `AppState(store:tier2Provisioning:tier3Provisioning:)`, and `archiveConversation`'s return type (`AppState.swift`, near `archiveRefusal`). Adjust the calls, not the assertions.

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh StickyToolsTests`. Expected: the build fails because `StickyTools` doesn't exist.

- [ ] **Step 3: Implement.**

```swift
import Foundation

/// 5c §0.1: a state-gated tool, once declared in a conversation, stays declared for the rest of
/// that conversation's turns. A declaration that flaps rewrites every provider's cached prefix
/// after the tools block; a few extra declarations cost far less. In memory only: a restart
/// re-derives the set from the gates at the cost of one rewrite.
struct StickyTools: Sendable {
    /// The state-gated tools. Not the workflow triggers (one turn only, #132), not the pinned-only
    /// job tools (identity, not state), not `set_workspace` (its gate is fixed per conversation).
    static let eligible: Set<String> = [
        "manage_fact", "list_sessions", "send_to_session", "set_session_card",
        "amend_goal_contract", "reach_checkpoint", "delegate_milestone", "waive_criterion",
        "goal_complete",
    ]

    private var byConversation: [UUID: Set<String>] = [:]

    func names(for id: UUID) -> Set<String> { byConversation[id] ?? [] }

    mutating func record(_ declared: some Sequence<String>, for id: UUID) {
        let added = Set(declared).intersection(Self.eligible)
        guard !added.isEmpty else { return }
        byConversation[id, default: []].formUnion(added)
    }

    /// On delete only. An archived conversation can be restored, and its prefix should still match.
    mutating func forget(_ id: UUID) { byConversation[id] = nil }
}
```

- [ ] **Step 4: Run the tests and confirm they pass.** Same command; quote the count (6).

- [ ] **Step 5: Commit** with `feat(agency): StickyTools, the per-conversation set of declared state-gated tools (#187)`.

### Task 2: Gates honour the sticky set, then one hard-strip pass

**Files:**
- Modify `Sources/iris/iris.swift`:
  - `IrisEngine.init` (`:392`): add `stickyTools: Bool = true`, stored as `private let stickyToolsEnabled: Bool`, beside `declareStateGatedTools` (`:136-140`);
  - the preamble tuple (`:1445-1449`): also read `localState?.stickyTools.names(for: conversationId) ?? []`;
  - the gates: `manage_fact` (`:1574`), `goal_complete` (`:1606`), the peer tools (`:1708`), `amend_goal_contract` (`:1753`), `reach_checkpoint` + `delegate_milestone` (`:1767`), `waive_criterion` (`:1789`);
  - new `hardStrip` pass before the read-only block (`:1808`);
  - record after the pass.
- Test: `Tests/irisTests/StickyDeclarationTests.swift` (new).

**Interfaces:**
- Produces:
  - `nonisolated static func hardStrip(_ tools: [FunctionDeclaration], isUnattended: Bool, principal: Principal) -> [FunctionDeclaration]`
  - `nonisolated static let unattendedNeverDeclared: Set<String>`, which is `jobCreationTools ∪ ["set_workspace", "list_sessions", "send_to_session", "set_session_card"]`
  - `nonisolated static let mainOnlyDeclared: Set<String>`, which is `jobCreationTools ∪ ["amend_goal_contract", "reach_checkpoint", "delegate_milestone", "waive_criterion", "list_sessions", "send_to_session", "set_session_card"]`
- Consumes: `StickyTools.names(for:)`, `StickyTools.record(_:for:)`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

@MainActor
@Suite struct StickyDeclarationTests {
    /// One turn through a real engine against a capturing client. Returns the declared names.
    private func names(_ app: AppState, _ id: UUID, prompt: String = "carry on",
                       principal: Principal = .main, factStore: FactStoreManager,
                       sticky: Bool = true) async -> [String] {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], factStore: factStore, protectionEnabled: false,
                                sessionPeerCount: 0, stickyTools: sticky)
        await engine.processInput(prompt, source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    private func app() throws -> (AppState, UUID) {
        let app = AppState(store: try ConversationStore.inMemory())
        let id = UUID()
        app.createNewConversation(id: id)
        return (app, id)
    }

    @Test func manageFactStaysAfterFactsStopSurfacing() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")
        #expect(await names(app, id, prompt: "Where does Brian live?", factStore: facts).contains("manage_fact"))
        #expect(await names(app, id, prompt: "What is two plus two?", factStore: facts).contains("manage_fact"))
        #expect(app.stickyTools.names(for: id).contains("manage_fact"))
    }

    @Test func switchedOffItFlapsAsBefore() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")
        _ = await names(app, id, prompt: "Where does Brian live?", factStore: facts, sticky: false)
        #expect(!(await names(app, id, prompt: "What is two plus two?", factStore: facts, sticky: false)).contains("manage_fact"))
    }

    @Test func ladderToolsStayAfterTheGoalEnds() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        app.setGoalContract(for: id, c)
        let during = await names(app, id, factStore: facts)
        for n in ["amend_goal_contract", "reach_checkpoint", "delegate_milestone", "goal_complete"] {
            #expect(during.contains(n), Comment(rawValue: n))
        }
        app.clearGoal(for: id)
        let after = await names(app, id, factStore: facts)
        for n in ["amend_goal_contract", "reach_checkpoint", "delegate_milestone", "goal_complete"] {
            #expect(after.contains(n), Comment(rawValue: n))
        }
    }

    /// Review focus 1. A strip always wins over stickiness.
    @Test func stickyNeverSurvivesHardStrips() async throws {
        let all = StickyTools.eligible.union(["set_workspace", "schedule_job", "register_directory_watcher"])
        let facts = try FactStoreManager(inMemory: true)

        // Unattended: a background (job-run) conversation, read-only profile.
        let (bg, bgId) = try app()
        if let i = bg.conversations.firstIndex(where: { $0.id == bgId }) {
            bg.conversations[i].isBackground = true
            bg.conversations[i].jobProfile = .readOnly
        }
        bg.stickyTools.record(all, for: bgId)
        let unattended = await names(bg, bgId, factStore: facts)
        for n in IrisEngine.unattendedNeverDeclared { #expect(!unattended.contains(n), Comment(rawValue: n)) }
        for n in unattended {
            #expect(!JobProfile.readOnlyDenies(n, sandboxedRunCommand: false, readOnlyMCPTools: []),
                    Comment(rawValue: n))
        }

        // A subagent principal: the main-only tools never appear, whatever the set says.
        let (sub, subId) = try app()
        sub.stickyTools.record(all, for: subId)
        let subNames = await names(sub, subId, principal: .subagent, factStore: facts)
        for n in IrisEngine.mainOnlyDeclared { #expect(!subNames.contains(n), Comment(rawValue: n)) }
    }

    @Test func hardStripIsPure() {
        let decls = ["run_command", "set_workspace", "send_to_session", "schedule_job", "manage_fact", "reach_checkpoint"]
            .map { FunctionDeclaration(name: $0, description: $0, parameters: nil) }
        let unattended = IrisEngine.hardStrip(decls, isUnattended: true, principal: .main).map(\.name)
        #expect(unattended == ["run_command", "manage_fact", "reach_checkpoint"])
        let sub = IrisEngine.hardStrip(decls, isUnattended: false, principal: .subagent).map(\.name)
        // A subagent keeps set_workspace: that's today's behaviour, unchanged by hardStrip.
        #expect(sub == ["run_command", "set_workspace", "manage_fact"])
    }

    @Test func jobToolsAreNotStickyAfterUnpin() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        if let i = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[i].isPinned = true }
        #expect(await names(app, id, factStore: facts).contains("list_jobs"))
        if let i = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[i].isPinned = false }
        #expect(!(await names(app, id, factStore: facts)).contains("list_jobs"))
    }
}
```

Check:
- `FunctionDeclaration`'s init labels (`Models.swift`);
- `Conversation.jobProfile`'s exact name (`AppState.swift`, near `isBackground` at `:96`);
- `JobProfile.readOnlyDenies`'s signature (as used at `iris.swift:1815`).

Adjust the calls, not the assertions. The read-only arm holds because the `readOnlyDenies` strip runs *after* `hardStrip` and nothing re-adds a name.

- [ ] **Step 2: Run them and watch them fail.** `timeout 300 scripts/test-filter.sh StickyDeclarationTests`. Expected: the build fails (`stickyTools:` init label, `hardStrip`).

- [ ] **Step 3: Implement.**
  1. **Init:** `stickyTools: Bool = true` becomes `self.stickyToolsEnabled = stickyTools`. Doc comment: "5c §0.1; false only for perf's gated arm (`IRIS_PERF_STICKY_TOOLS=0`)."
  2. **Preamble tuple (`:1445`):** add `localState?.stickyTools.names(for: conversationId) ?? []` as a sixth element `storedSticky`. Then:
     ```swift
     // 5c §0.1 (plan note 6): attended main conversations only. A job run is one turn in a fresh
     // conversation, so a set could never help it and would leave an entry behind per fire.
     let stickyApplies = stickyToolsEnabled && principal == .main && !isUnattended
     let sticky: Set<String> = stickyApplies ? storedSticky : []
     ```
  3. **Gates.** Each gate keeps its position. Change only the condition:
     - `:1574`: `if !facts.isEmpty || declareStateGatedTools || sticky.contains("manage_fact") {`
     - `:1606`: `if hasActiveGoal || restrictToGoalComplete || sticky.contains("goal_complete") {`
     - `:1708`: `if principal == .main, peerCount > 0 || (declareStateGatedTools && !isUnattended) || sticky.contains("send_to_session") {`. The three peer tools are one gate, so they are recorded and restored together.
     - `:1753`: `if principal == .main, ladderContract?.isLocked == true || sticky.contains("amend_goal_contract") {`
     - `:1767`: split the `if let`:
       ```swift
       let ladderOpen = ladderContract.map { $0.hasLadder && !$0.isFinalMilestone } ?? false
       if principal == .main, ladderOpen || sticky.contains("reach_checkpoint") {
       ```
     - `:1789`: `let waivable = ladderContract.map { $0.isLocked && $0.gateAttempts > 0 } ?? false`, then `if principal == .main, waivable || sticky.contains("waive_criterion") {`
  4. **Hard strip**, immediately before `if jobProfile == .readOnly {` (`:1808`):
     ```swift
     // 5c §1: a strip always wins over stickiness. The gates above already skip these for an
     // unattended turn or a non-main principal; this pass is what holds when a sticky set says
     // otherwise.
     toolsList = Self.hardStrip(toolsList, isUnattended: isUnattended, principal: principal)
     if stickyApplies {
         let declared = toolsList.map(\.name)
         await MainActor.run { localState?.stickyTools.record(declared, for: conversationId) }
     }
     ```
     ```swift
     nonisolated static let unattendedNeverDeclared: Set<String> =
         jobCreationTools.union(["set_workspace", "list_sessions", "send_to_session", "set_session_card"])
     nonisolated static let mainOnlyDeclared: Set<String> =
         jobCreationTools.union(["amend_goal_contract", "reach_checkpoint", "delegate_milestone",
                                 "waive_criterion", "list_sessions", "send_to_session", "set_session_card"])

     nonisolated static func hardStrip(_ tools: [FunctionDeclaration], isUnattended: Bool,
                                       principal: Principal) -> [FunctionDeclaration] {
         var denied: Set<String> = []
         if isUnattended { denied.formUnion(unattendedNeverDeclared) }
         if principal != .main { denied.formUnion(mainOnlyDeclared) }
         return denied.isEmpty ? tools : tools.filter { !denied.contains($0.name) }
     }
     ```
     Check that `jobCreationTools` is a `Set<String>` (`iris.swift`, near `:2551`). If it's an array, wrap it in `Set(...)`.

- [ ] **Step 4: Run the tests and confirm they pass.** Quote the counts for `StickyDeclarationTests` (6), `ToolSurfaceTrimTests`, `SessionToolsTests`, `BackgroundSessionToolsTests`, `JobToolsTests`, `UnattendedWorkspaceTests` and `DelegateMilestoneTests`.

- [ ] **Step 5: Commit** with `feat(agency): state-gated declarations stay once declared, and a hard strip always wins (#187)`.

### Task 3: A goal_complete-only turn restricts by dispatch, not by declaration

**Files:**
- Modify `Sources/iris/iris.swift`:
  - delete the filter at `:1869-1875`;
  - add a turn-context line after the briefing block (`:1467-1474`, before `TurnRequest` at `:1867`);
  - keep the dispatch refusal at `:2105-2108` unchanged.
- Test: `Tests/irisTests/LoopStopEnforcementTests.swift`.

**Interfaces:**
- Produces: `nonisolated static let goalCompleteOnlyInstruction = "Only goal_complete will run on this turn; any other tool call is refused."`

- [ ] **Step 1: Write the failing test** (add it to `LoopStopEnforcementTests`).

```swift
@Test("a restricted turn keeps the previous turn's declarations and says goal_complete only")
func restrictedTurnKeepsDeclarations() async {
    let appState = AppState()
    let convId = UUID()
    appState.createNewConversation(id: convId)
    let client = CapturingLLMClient(reply: "ok")
    let engine = IrisEngine(state: appState, tier: .medium, client: client, retryDelays: [],
                            protectionEnabled: false, sessionPeerCount: 0)
    await engine.processInput("hello", source: "UI", conversationId: convId)
    await engine.processInput("You reached a stopping condition. Summarize and stop.",
                              source: "System", conversationId: convId, restrictToGoalComplete: true)
    let requests = client.requests
    #expect(requests.count == 2)
    let before = Set(requests[0].tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    let during = Set(requests[1].tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
    #expect(before.isSubset(of: during), "no removal flap on the longest history (§0.3)")
    #expect(during.contains("goal_complete") && during.contains("run_command"))
    let lastUser = requests[1].contents.last { $0.role == "user" }?.parts.compactMap(\.text).joined() ?? ""
    #expect(lastUser.contains(IrisEngine.goalCompleteOnlyInstruction))
}
```

The existing `restrictedTurnBlocksTool` must stay green unchanged. It's the dispatch half.

- [ ] **Step 2: Run it and watch it fail.** `timeout 300 scripts/test-filter.sh LoopStopEnforcementTests`. Expected: `before.isSubset(of: during)` fails.

- [ ] **Step 3: Implement.** Delete the `if restrictToGoalComplete { toolsList = toolsList.filter { … } }` block and its comment. After the briefing block:

```swift
// 5c §0.3: the soft-stop turn keeps every declaration — stripping them was a removal flap on the
// longest history there is. The dispatcher refuses anything but goal_complete (below); this line
// tells the model so before it tries.
if restrictToGoalComplete {
    turnContext.sections.append(.init(heading: "This Turn", body: Self.goalCompleteOnlyInstruction))
}
```

Rewrite the dispatch comment at `:2100-2104`. It says the schema is "only advisory" *because* tools were removed. It should now say the dispatcher is the only enforcement.

- [ ] **Step 4: Run the tests and confirm they pass.** `LoopStopEnforcementTests` (2), `DoneGateScopeTests` and `TurnContextTests`; quote the counts.

- [ ] **Step 5: Commit** with `feat(agency): goal_complete-only turns restrict by dispatch, not declaration (#187)`.

### Task 4: Every sticky tool refuses in its off state

**Files:**
- Modify `Sources/iris/iris.swift`:
  - the `list_sessions` (`:3054`), `send_to_session` (`:3076`) and `set_session_card` (`:3139`) branches.
  - `manage_fact` itself is untouched (plan note 2): it has no dangerous off state. Before 5c, `manageFact` (`:2843-2855`) already acted on any existing `fact_id`, whatever turn surfaced it, and the fact store already refuses an id it doesn't recognize (`FactStoreError.notFound`). Sticky declaration changes nothing for it to guard.
- Test: `Tests/irisTests/StickyOffStateTests.swift` (new).

**Interfaces:**
- Produces:
  - `nonisolated static let noPeersRefusal = "Not run: no other session is active, so there is nobody to list, message, or describe this session to."`

- [ ] **Step 1: Write the failing tests**, one per sticky tool. Use `SessionToolsTests.runToolCall`'s shape (`:256`, with `peerCount:`) and `DelegateMilestoneTests.ladder(on:_:currentMilestone:)` (`:100`). Copy both helpers into the new suite as private functions. Don't call across suites.

```swift
@MainActor
@Suite struct StickyOffStateTests {
    // runToolCall(_:on:as:peerCount:factStore:) — SessionToolsTests' shape, plus a factStore
    // parameter passed to IrisEngine(factStore:). Returns the last functionResponse "result".

    @Test func manageFactRefusesANonexistentId() async throws {
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        let facts = try FactStoreManager(inMemory: true)
        let staleId = UUID().uuidString
        let call = FunctionCall(name: "manage_fact",
                                args: ["action": .string("retract"), "fact_id": .string(staleId)], id: "c1")
        // No new guard here (plan note 2): the store's own id validation is the only boundary,
        // exactly as it was pre-5c. A sticky manage_fact declaration has no dangerous off state.
        let result = await runToolCall(call, on: app, as: id, peerCount: 0, factStore: facts)
        #expect(result.contains("unknown fact id"), result)
    }

    @Test func manageFactActsOnAnIdFromHistory() async throws {
        // The id was surfaced on an earlier turn, not this one ("carry on" surfaces nothing new).
        // A turn-scoped guard would refuse this and break "retract what you have about X" when
        // the fact isn't restated — manage_fact must still act on it. Expect "is now retracted".
    }

    @Test func peerToolsRefuseWithNoPeers() async {
        let app = AppState(); let me = UUID(); app.createNewConversation(id: me)
        for call in [FunctionCall(name: "list_sessions", args: [:], id: "c1"),
                     FunctionCall(name: "send_to_session", args: ["session_id": .string(UUID().uuidString),
                                                                  "message": .string("hi")], id: "c1"),
                     FunctionCall(name: "set_session_card", args: ["name": .string("x"),
                                                                   "description": .string("y")], id: "c1")] {
            #expect(await runToolCall(call, on: app, as: me, peerCount: 0) == IrisEngine.noPeersRefusal,
                    Comment(rawValue: call.name))
        }
    }

    @Test func reachCheckpointRefusesAtTheFinalMilestoneAndWithNoLadder() async {
        // ladder(on:_:currentMilestone: 1), then call reach_checkpoint: the result is
        // "This is the final checkpoint — call `goal_complete` to finish, not `reach_checkpoint`."
        // On a conversation with no contract: "No checkpoint ladder is active. Call goal_complete
        // when the goal is finished."
    }

    @Test func delegateMilestoneRefusesWithNoLadder() async {
        // Expected: the "No checkpoint ladder is active, so there is no milestone to delegate. …"
        // sentence. The final-milestone case is DelegateMilestoneTests.finalMilestoneIsRefused.
    }

    @Test func amendRefusesWithoutALockedContract() async {
        // Expected: "Amend rejected — a non-empty rationale is required to change locked criteria."
        // with a rationale given, because amendGoalContract returns false without a locked
        // contract. If the sentence then misleads (it blames the rationale), add a
        // dedicated `amendUnlockedRefusal` and assert that instead.
    }

    @Test func waiveRefusesWithoutAFailedGrade() async {
        // A locked contract with gateAttempts == 0: "Waiver rejected. …"
    }

    @Test func goalCompleteRefusesWithNoActiveGoal() async {
        // Expected prefix: "No goal is active, so there was nothing to complete"
    }
}
```

Write every body in full. The comments above say what each asserts; they are not the test. Read each existing refusal sentence from the source before asserting it. If the amend sentence blames the rationale when the real cause is an unlocked contract, that's a misleading agent-facing string (invariant 9). Fix it in this task, in the same commit.

- [ ] **Step 2: Run them and watch them fail.** `timeout 300 scripts/test-filter.sh StickyOffStateTests`. Expected: only the peer cases fail. The two `manage_fact` cases and `reach_checkpoint`/`delegate_milestone`/`amend`/`waive`/`goal_complete` already pass — that's plan note 2: the guards already exist, and `manage_fact` needed none to begin with.

- [ ] **Step 3: Implement.**
  - **`manage_fact`:** no change. Leave the branch (`:3446`) exactly as it is; `manageFact` already refuses an unrecognized `fact_id` with "unknown fact id …", and a sticky declaration doesn't change what ids are valid.
  - **Peer tools:** in each of the three branches, after the existing `!isUnattended` guard:
    ```swift
    // 5c §0.2: declared stickily now; with nobody to talk to the call has no meaning.
    guard await sessionPeerCount(excluding: conversationId) > 0 else {
        result = Self.noPeersRefusal
        return result
    }
    ```
    `sessionPeerCount` honours the test override, the same value the declaration gate reads.

- [ ] **Step 4: Run the tests and confirm they pass.** Quote the counts for `StickyOffStateTests`, `SessionToolsTests`, `PeerDeliveryTests`, `FactStoreToolTests` (or whatever suite holds the `manage_fact` handler tests; find it with `grep -rln '"manage_fact"' Tests`), `DelegateMilestoneTests` and `DoneGateScopeTests`. No existing `manage_fact` handler test changes behavior: nothing about dispatch changed for it.

- [ ] **Step 5: Commit** with `feat(agency): sticky tools refuse at dispatch when their state is off (#187)`.

### Task 5: The tool prefix only grows within a conversation

**Files:**
- Test: `Tests/irisTests/ToolPrefixGrowthTests.swift` (new).

**Interfaces:**
- Consumes everything from Tasks 2-4.

- [ ] **Step 1: Write the test.**

```swift
import Testing
import Foundation
@testable import iris

/// 5c §0.4. Several turns of one conversation, states toggling, through one engine. Each turn's
/// declared tools are a superset of the previous turn's, every shared entry encodes byte for byte
/// the same, and shared entries keep their relative order (review focus 2).
@MainActor
@Suite struct ToolPrefixGrowthTests {
    private func encoded(_ d: FunctionDeclaration) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(d)
    }

    @Test func prefixOnlyGrows() async throws {
        let app = AppState(store: try ConversationStore.inMemory())
        let id = UUID(); app.createNewConversation(id: id)
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [],
                                factStore: facts, protectionEnabled: false, sessionPeerCount: 0)

        await engine.processInput("hello", source: "UI", conversationId: id)                    // plain
        await engine.processInput("Where does Brian live?", source: "UI", conversationId: id)   // facts on
        await engine.processInput("What is two plus two?", source: "UI", conversationId: id)    // facts off
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship", criteria: [a, b])
        c.milestones = [Milestone(title: "One", criterionIds: [a.id]), Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, c)
        await engine.processInput("carry on", source: "UI", conversationId: id)                 // ladder on
        app.clearGoal(for: id)
        await engine.processInput("and now?", source: "UI", conversationId: id)                 // ladder off
        await engine.processInput("Stop and summarize.", source: "System", conversationId: id,
                                  restrictToGoalComplete: true)                                   // soft stop

        let turns = client.requests.map { $0.tools?.first?.functionDeclarations ?? [] }
        #expect(turns.count == 6)
        for n in 1..<turns.count {
            let prev = turns[n - 1], next = turns[n]
            let nextByName = Dictionary(next.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for d in prev {
                let match = try #require(nextByName[d.name], "turn \(n + 1) dropped \(d.name)")
                #expect(try encoded(match) == encoded(d), "turn \(n + 1) changed \(d.name)")
            }
            let shared = Set(prev.map(\.name))
            #expect(next.map(\.name).filter(shared.contains) == prev.map(\.name),
                    "turn \(n + 1) reordered the shared prefix")
        }
    }
}
```

If the round-trip reply "ok" leaves the soft-stop turn without a request (it should make one), assert `turns.count` against what was actually sent and say why in a comment. Don't drop the turn.

- [ ] **Step 2: Run it.** `timeout 300 scripts/test-filter.sh ToolPrefixGrowthTests`. Expected: it passes on top of Tasks 2-4 (1 test). Mutation-check it:
  1. Revert Task 2's `manage_fact` gate change locally, run the test, and see it fail on turn 3.
  2. Move the sticky union to append at the end, and see the order assertion fail.
  3. Restore both.

  Record both failures in the commit message.

- [ ] **Step 3: Commit** with `test(agency): the declared tool prefix only grows within a conversation (#187)`.

### Task 6: Invariant 9 sweep for PR A

- [ ] **Step 1: Run the greps and read every hit.**
  - `grep -rn "offered only\|only when there\|declared only\|on a turn that surfaced\|dead weight" Sources/iris/iris.swift`. Each gate comment you touched in Task 2 now has to say "…and once declared, stays declared (5c §0.1)", or it's untrue.
  - `grep -rn "restrictToGoalComplete\|ONLY goal_complete\|remove the tool from the schema\|only advisory" Sources Tests`. Covers the `:1869` comment (deleted), the `:2100` comment, the `processInput` doc near `:1345`, and the `LoopStopEnforcementTests` doc comment ("Removing the tool from the schema is NOT enough").
  - `grep -n "declareStateGatedTools" Sources/iris/iris.swift`. The `:136-140` doc says the flag declares state-gated tools "instead of only when their state holds". Add that 5c makes sticky the default and this flag remains perf's "declared every turn" arm.
  - `AGENTS.md` invariant 6, "Lifecycle state" bullet: add "A state-gated tool, once declared in a conversation, stays declared for the rest of it (`StickyTools`, 5c), and its dispatcher refuses the call when the state is off. Workflow-trigger tools stay one-turn-only." Flag this in the PR body (plan note 15).
  - `grep -n "manage_fact\|list_sessions\|send_to_session" README.md docs/*.md`, for any sentence that says these appear "only when …".
- [ ] **Step 2: Fix what you found.** Run the full suite (`timeout 900 swift test`); green means all three signals. Commit with `docs(agency): sticky declarations, swept (#187)`.
- [ ] **Step 3: Open PR A.** The body lists:
  - the Review Focus items it owns (1, 2);
  - the AGENTS.md invariant change;
  - plan notes 1-6.

---

## PR B: weighted tokens

Branch: `feat/agency-5c-weighted-budgets`, based on `main`. Independent of A and C.

### Task 7: Parse the 1-hour write split on both Anthropic paths

**Files:**
- Modify `Sources/iris/Models.swift`, `UsageMetadata` (`:236-270`): add `var cacheWrite1hTokens: Int? = nil` and its `CodingKeys` case.
- Modify `Sources/iris/AnthropicClient.swift`, `parseResponse` usage (`:329-344`).
- Modify `Sources/iris/AnthropicStreamMapper.swift`, `message_start` (`:20-33`).
- Modify `Sources/iris/LLMStream.swift`, the `.usage` merge (`:100-107`).
- Test: `Tests/irisTests/UsageCacheCountTests.swift`, `Tests/irisTests/AnthropicStreamMapperTests.swift`.

**Interfaces:**
- Produces: `UsageMetadata.cacheWrite1hTokens: Int?`, the 1-hour **share** of `cacheWriteTokens`; nil when the response had no `cache_creation` object.
- Produces: `static func anthropicOneHourWrites(_ usage: [String: Any]) -> Int?` on `UsageMetadata`, shared by both parsers.

- [ ] **Step 1: Write the failing tests.**

```swift
// UsageCacheCountTests
@Test("Anthropic non-stream: the nested cache_creation split is read")
func anthropicNonStreamOneHourSplit() throws {
    let json: [String: Any] = ["content": [["type": "text", "text": "hi"]],
                               "usage": ["input_tokens": 10, "cache_read_input_tokens": 900,
                                         "cache_creation_input_tokens": 300, "output_tokens": 7,
                                         "cache_creation": ["ephemeral_5m_input_tokens": 100,
                                                            "ephemeral_1h_input_tokens": 200]]]
    let r = try AnthropicClient.parseResponse(json)
    #expect(r.usageMetadata?.cacheWriteTokens == 300, "the total, as before")
    #expect(r.usageMetadata?.cacheWrite1hTokens == 200, "the 1-hour share")
}

@Test("no cache_creation object: the split is unknown, not zero")
func noSplitIsNil() throws {
    let json: [String: Any] = ["content": [["type": "text", "text": "hi"]],
                               "usage": ["input_tokens": 10, "cache_creation_input_tokens": 50, "output_tokens": 7]]
    #expect(try AnthropicClient.parseResponse(json).usageMetadata?.cacheWrite1hTokens == nil)
}

// AnthropicStreamMapperTests
@Test("message_start carries the 1-hour split")
func messageStartOneHourSplit() throws {
    var m = AnthropicStreamMapper()
    let data = #"{"type":"message_start","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":30}}}}"#
    let events = try m.handle(SSEEvent(event: "message_start", data: data))
    guard case .usage(let u)? = events.first else { Issue.record("no usage event"); return }
    #expect(u.cacheWriteTokens == 40 && u.cacheWrite1hTokens == 30)
}

/// Review focus 3.
@Test("the stream assembler carries the 1-hour split through the merge")
func streamAssemblerCarriesOneHourSplit() {
    var a = LLMStreamAssembler()
    a.apply(.usage(UsageMetadata(promptTokenCount: 45, candidatesTokenCount: nil, totalTokenCount: nil,
                                 cacheReadTokens: nil, cacheWriteTokens: 40, cacheWrite1hTokens: 30)), now: 0)
    a.apply(.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 9, totalTokenCount: nil)), now: 1)
    #expect(a.response().usageMetadata?.cacheWrite1hTokens == 30)
}
```

Check `SSEEvent`'s init and the assembler type's real name (`LLMStream.swift`, around `:80`). Adjust the calls, not the assertions.

- [ ] **Step 2: Run them and watch them fail.** `timeout 300 scripts/test-filter.sh 'UsageCacheCountTests|AnthropicStreamMapperTests'`.

- [ ] **Step 3: Implement.**

```swift
/// The 1-hour share of the cache writes (5c §0.6), from the nested `usage.cache_creation`
/// object. nil when the object is absent: an unknown split is not a zero one.
static func anthropicOneHourWrites(_ usage: [String: Any]) -> Int? {
    (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int
}
```

- Both parsers pass `cacheWrite1hTokens: UsageMetadata.anthropicOneHourWrites(usage)` into the `UsageMetadata` they build. The memberwise init gains the defaulted argument last.
- `LLMStream.swift`: add `merged.cacheWrite1hTokens = Self.maxOf(merged.cacheWrite1hTokens, incoming.cacheWrite1hTokens)`.
- `CodingKeys`: add `case cacheWrite1hTokens`. The key is ours, not Gemini's; Gemini never sends it.

- [ ] **Step 4: Run them and confirm they pass**, then run `StreamingClientTests` and `RequestByteStabilityTests`. Quote the counts.

- [ ] **Step 5: Commit** with `feat(usage): read Anthropic's 1-hour cache-write split on both paths (#187)`.

### Task 8: `TokenUsage` keeps the split, and exposes components

**Files:**
- Modify `Sources/iris/AppState.swift`:
  - `TokenUsage` (`:44-80`): add the field, its `CodingKeys` case, `decodeIfPresent`, and `components`;
  - `updateTokenUsage` (`:2030-2057`), both the conversation and the delegated halves;
  - `runUsage` (`:2871-2885`).
- Create: `Sources/iris/CostWeights.swift`, with only `UsageComponents` in this task (Task 9 adds the table).
- Test: `Tests/irisTests/TokenUsageComponentsTests.swift` (new).

**Interfaces:**
- Produces:
  - `struct UsageComponents: Equatable, Sendable { var prompt, output, cacheRead, cacheWrite, cacheWrite1h: Int }`. All default to 0.
  - `TokenUsage.cacheWrite1hTokenCount: Int?`
  - `var TokenUsage.components: UsageComponents`

- [ ] **Step 1: Write the failing tests.**

```swift
@Suite struct TokenUsageComponentsTests {
    @Test func preFiveCJSONDecodesWithNoSplit() throws {
        let json = #"{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12,"cacheWriteTokenCount":4}"#
        let u = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(u.cacheWrite1hTokenCount == nil && u.cacheWriteTokenCount == 4)
    }

    @Test func componentsChargeThinkingAsOutput() {
        // Gemini: total includes thinking tokens that candidates does not.
        let u = TokenUsage(promptTokenCount: 100, candidatesTokenCount: 10, totalTokenCount: 150,
                           cacheReadTokenCount: 60, cacheWriteTokenCount: nil)
        #expect(u.components == UsageComponents(prompt: 100, output: 50, cacheRead: 60, cacheWrite: 0, cacheWrite1h: 0))
    }

    @MainActor
    @Test func updateAndRunUsageAccumulateTheSplit() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        let id = UUID(); state.createNewConversation(id: id)
        for _ in 0..<2 {
            state.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 50, candidatesTokenCount: 1,
                totalTokenCount: 51, cacheReadTokens: 0, cacheWriteTokens: 40, cacheWrite1hTokens: 30))
        }
        #expect(state.runUsage(for: id).cacheWrite1hTokenCount == 60)
    }
}
```

Add a delegated case modelled on `DelegatedSpendTests`' link-then-update shape (`:84`, `:373`): a linked subagent's 1-hour writes reach `runUsage` of the run.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.**
  - In `CostWeights.swift`:
    ```swift
    /// One usage, split the way a weight table prices it (5c §0.5). `prompt` is every input token,
    /// cached or not: each provider's prompt count already folds cache reads and writes in (5a).
    /// `output` includes anything billed as output that `candidates` leaves out (Gemini thinking).
    struct UsageComponents: Equatable, Sendable {
        var prompt: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        /// Every cache write.
        var cacheWrite: Int = 0
        /// The 1-hour share of `cacheWrite`.
        var cacheWrite1h: Int = 0
    }
    ```
  - Field: `var cacheWrite1hTokenCount: Int? = nil`. Add it to `CodingKeys` and as an init parameter (defaulted). Decode: `cacheWrite1hTokenCount = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1hTokenCount)`. It persists inside the `conversations.tokenUsage` JSON column, which already exists (Global Constraints).
  - `var components: UsageComponents { UsageComponents(prompt: promptTokenCount, output: max(candidatesTokenCount, totalTokenCount - promptTokenCount), cacheRead: cacheReadTokenCount ?? 0, cacheWrite: cacheWriteTokenCount ?? 0, cacheWrite1h: cacheWrite1hTokenCount ?? 0) }`
  - `updateTokenUsage`, delegated half and `runUsage`: one more `if let` each, mirroring `cacheWriteTokens`. Unknown stays nil (5a §0.4).

- [ ] **Step 4: Run and confirm they pass.** Quote the counts for `TokenUsageComponentsTests` and `DelegatedSpendTests`.

- [ ] **Step 5: Commit** with `feat(usage): TokenUsage keeps the 1-hour write share and exposes components (#187)`.

### Task 9: `CostWeights`, the provider table

**Files:**
- Modify: `Sources/iris/CostWeights.swift`.
- Test: `Tests/irisTests/CostWeightsTests.swift` (new).

**Interfaces:**
- Produces:
  - `enum CostWeights`, with `struct Rates: Equatable, Sendable { let read, write5m, write1h: Double }`;
  - `static let outputWeight = 5.0`;
  - `static func rates(for provider: String?) -> Rates`;
  - `static func weighted(_ u: UsageComponents, provider: String?) -> Int`.
- The `provider` strings are `LLMProvider.rawValue` (`"Anthropic"`, `"Gemini"`, `"OpenAI"`). nil or anything else is unknown.

- [ ] **Step 1: Look up two ratios.** Read Google's and OpenAI's published pricing pages for `gemini-3.5-flash` and `gpt-5.6-terra` (the default medium models, `ConfigManager.swift:429,437`). Note each one's cached-input price divided by its uncached-input price, and the date. The values below (0.1 for both) are what those families published when the spec was written. If the page says otherwise, use the page's ratio and record it in the test comment.

- [ ] **Step 2: Write the failing tests.**

```swift
@Suite struct CostWeightsTests {
    @Test func anthropicWeights() {
        let u = UsageComponents(prompt: 20_000, output: 500, cacheRead: 19_400, cacheWrite: 400, cacheWrite1h: 100)
        // uncached 200×1 + read 19_400×0.1 + 5m 300×1.25 + 1h 100×2 + output 500×5
        #expect(CostWeights.weighted(u, provider: "Anthropic") == 200 + 1_940 + 375 + 200 + 2_500)
    }

    @Test func specExampleIsAboutFiveThousand() {
        // §0.5: a 20k prompt, 97% cache reads, 500 output tokens ≈ 5k weighted.
        let u = UsageComponents(prompt: 20_000, output: 500, cacheRead: 19_400, cacheWrite: 0, cacheWrite1h: 0)
        #expect((4_500...5_500).contains(CostWeights.weighted(u, provider: "Anthropic")))
    }

    /// Pinned on <DATE OF STEP 1> from <PAGE URLS OF STEP 1>.
    @Test func geminiAndOpenAIHaveNoWriteCharge() {
        #expect(CostWeights.rates(for: "Gemini") == .init(read: 0.1, write5m: 0, write1h: 0))
        #expect(CostWeights.rates(for: "OpenAI") == .init(read: 0.1, write5m: 0, write1h: 0))
    }

    @Test func unknownProviderIsOneToOne() {
        let u = UsageComponents(prompt: 1_000, output: 10, cacheRead: 600, cacheWrite: 100, cacheWrite1h: 0)
        #expect(CostWeights.weighted(u, provider: nil) == 1_000 + 50)
        #expect(CostWeights.weighted(u, provider: "Mistral") == 1_000 + 50)
    }

    @Test func inconsistentInputsNeverGoNegative() {
        let u = UsageComponents(prompt: 10, output: -3, cacheRead: 50, cacheWrite: 5, cacheWrite1h: 9)
        #expect(CostWeights.weighted(u, provider: "Anthropic") >= 0)
    }

    @Test func roundsUp() {
        #expect(CostWeights.weighted(UsageComponents(prompt: 1, cacheRead: 1), provider: "Anthropic") == 1)
    }
}
```

The `<DATE …>` / `<PAGE …>` comment is filled from Step 1 before committing. It's the record the spec asks for ("pinned with a date in a test").

- [ ] **Step 3: Run them and watch them fail.**

- [ ] **Step 4: Implement.**

```swift
/// 5c §0.5: what a run's usage weighs against a budget, in **weighted tokens**. Output counts 5×
/// on every provider (a floor; real prices run 4×-8×), cache reads and writes at the provider's
/// ratio. A table, not a bill: the budget guards against runaway spend, not billing precision,
/// and history is re-priced at read time (§0.6), so changing a figure here needs no migration.
enum CostWeights {
    struct Rates: Equatable, Sendable {
        let read: Double
        let write5m: Double
        let write1h: Double
    }

    static let outputWeight = 5.0
    static let unknown = Rates(read: 1, write5m: 1, write1h: 1)

    static func rates(for provider: String?) -> Rates {
        switch provider {
        // 0.1 is conservative: Opus 5.5 reads at 0.05.
        case LLMProvider.anthropic.rawValue: return Rates(read: 0.1, write5m: 1.25, write1h: 2.0)
        // Implicit caching: no write charge. Ratios pinned in CostWeightsTests with their date.
        case LLMProvider.gemini.rawValue: return Rates(read: 0.1, write5m: 0, write1h: 0)
        case LLMProvider.openai.rawValue: return Rates(read: 0.1, write5m: 0, write1h: 0)
        default: return unknown
        }
    }

    static func weighted(_ u: UsageComponents, provider: String?) -> Int {
        let r = rates(for: provider)
        let read = max(0, u.cacheRead)
        let write = max(0, u.cacheWrite)
        let write1h = min(max(0, u.cacheWrite1h), write)
        let uncached = max(0, u.prompt - read - write)
        let total = Double(uncached)
            + Double(read) * r.read
            + Double(write - write1h) * r.write5m
            + Double(write1h) * r.write1h
            + Double(max(0, u.output)) * outputWeight
        return Int(total.rounded(.up))
    }
}
```

- [ ] **Step 5: Run them and confirm they pass**; quote the count (6). **Commit** with `feat(budget): CostWeights, the weighted-token table (#187)`.

### Task 10: The ledger keeps components and the run's provider

**Files:**
- Modify `Sources/iris/ConversationStore.swift`: a migration after `v14_job_action` (`:496-500`).
- Modify `Sources/iris/JobRun.swift`:
  - fields after `totalTokens` (`:32`): `cacheReadTokens`, `cacheWriteTokens`, `cacheWrite1hTokens: Int` (default 0), and `provider`, `tier: String?`;
  - the init (`:60-80`);
  - `var components: UsageComponents`.
- Modify `Sources/iris/JobLedger.swift`:
  - `begin` (`:293-312`): write `provider` and `tier`;
  - `finish` (`:321-335`) and `recordUsage` (`:350-361`): write the three counts;
  - `run(from:)` (`:714-735`): read all five.
- Modify `Sources/iris/JobRunner.swift:930-939`: stamp `run.provider = config.primaryProvider` and `run.tier = await engine?.modelTier.rawValue` before `ledger.begin(run:)`. Only the model-turn run. Gate rows, built-ins, stillborn and approved-call rows spend nothing, so they stay nil.
- Test: `Tests/irisTests/JobRunCostMigrationTests.swift` (new), `Tests/irisTests/JobLedgerPolicyTests.swift`.

**Interfaces:**
- Produces:
  - migration `v15_job_run_cost`;
  - `JobRun.provider`, `JobRun.tier`, `JobRun.cacheReadTokens`, `cacheWriteTokens`, `cacheWrite1hTokens`;
  - `JobRun.components`.

- [ ] **Step 1: Write the failing tests** (`WatchMigrationTests`' shape).

```swift
import Testing
import Foundation
import GRDB
@testable import iris

@Suite struct JobRunCostMigrationTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Review focus 4.
    @Test func v15KeepsRowsAndPricesThemUnknown() throws {
        let queue = try DatabaseQueue()
        try ConversationStore.migrator.migrate(queue, upTo: "v14_job_action")
        let jobId = UUID(), runId = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO jobs (id, name, prompt, triggerKind, trigger, profile, createdAt, enabled)
                VALUES (?, 'nightly', 'p', 'schedule', ?, 'readOnly', ?, 1)
                """, arguments: [jobId.uuidString,
                                 #"{"kind":"schedule","schedule":{"kind":"interval","seconds":60}}"#, t0])
            try db.execute(sql: """
                INSERT INTO job_runs (id, jobId, jobName, triggerKind, startedAt, status,
                                      promptTokens, candidateTokens, totalTokens)
                VALUES (?, ?, 'nightly', 'schedule', ?, 'completed', 1000, 10, 1010)
                """, arguments: [runId.uuidString, jobId.uuidString, t0])
        }
        try ConversationStore.migrator.migrate(queue)

        let ledger = JobLedger(writer: queue)
        let run = try #require(try ledger.run(id: runId))
        #expect(run.provider == nil && run.tier == nil)
        #expect(run.cacheReadTokens == 0 && run.cacheWriteTokens == 0 && run.cacheWrite1hTokens == 0)
        #expect(CostWeights.weighted(run.components, provider: run.provider) == 1_000 + 50)
        let columns = try queue.read { db in try db.columns(in: "job_runs").map(\.name) }
        for c in ["cacheReadTokens", "cacheWriteTokens", "cacheWrite1hTokens", "provider", "tier"] {
            #expect(columns.contains(c), Comment(rawValue: c))
        }
    }

    @Test func beginFinishAndRecordUsageRoundTrip() throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        var run = JobRun(jobId: job.id, jobName: "j", triggerKind: "schedule", startedAt: t0,
                         transcriptConversationId: UUID())
        run.provider = "Anthropic"; run.tier = "medium"
        try store.ledger.begin(run: run)
        let mid = TokenUsage(promptTokenCount: 500, candidatesTokenCount: 5, totalTokenCount: 505,
                             cacheReadTokenCount: 300, cacheWriteTokenCount: 100, cacheWrite1hTokenCount: 80)
        try store.ledger.recordUsage(runId: run.id, tokens: mid)
        var less = mid; less.cacheReadTokenCount = 1
        try store.ledger.recordUsage(runId: run.id, tokens: less)   // never lowers
        let read = try #require(try store.ledger.run(id: run.id))
        #expect(read.provider == "Anthropic" && read.tier == "medium")
        #expect(read.cacheReadTokens == 300 && read.cacheWriteTokens == 100 && read.cacheWrite1hTokens == 80)
        try store.ledger.finish(runId: run.id, status: .completed, outcome: nil, failureReason: nil,
                                blockedTool: nil, tokens: mid, finishedAt: t0)
        #expect(try store.ledger.run(id: run.id)?.cacheWrite1hTokens == 80)
    }
}
```

Add a `JobRunnerTests` case (use the suite's existing fake-engine harness; grep `func runner(` in `JobRunnerTests.swift`). A model-turn run's row carries `provider == config.primaryProvider` from the injected `ConfigManager(store:)`, and a gate row carries nil.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.**

```swift
// 5c §0.6: the raw components a weighted total is computed from, and whose prices apply. Never a
// weighted figure: weights are a table and history is re-priced at read time. NULL reads back as
// 0 (counts) or unknown (provider, tier), which prices a pre-5c row at r = w = 1.
m.registerMigration("v15_job_run_cost") { db in
    try db.alter(table: "job_runs") { t in
        t.add(column: "cacheReadTokens", .integer)
        t.add(column: "cacheWriteTokens", .integer)
        t.add(column: "cacheWrite1hTokens", .integer)
        t.add(column: "provider", .text)
        t.add(column: "tier", .text)
    }
}
```

- **`begin`:** add `provider, tier, cacheReadTokens, cacheWriteTokens, cacheWrite1hTokens` to the column list and the matching `run.` values to the arguments: 21 placeholders become 26.
- **`finish`:** `cacheReadTokens = ?, cacheWriteTokens = ?, cacheWrite1hTokens = ?` from `tokens.cacheReadTokenCount ?? 0`, and so on.
- **`recordUsage`:** `cacheReadTokens = MAX(COALESCE(cacheReadTokens, 0), ?)` for each of the three.
- **`run(from:)`:** `run.cacheReadTokens = try r.read("cacheReadTokens", Int.self) ?? 0` for each count, and `run.provider = try r.read("provider", String.self)` for both strings.
- **`JobRun.components`:** `UsageComponents(prompt: promptTokens, output: max(candidateTokens, totalTokens - promptTokens), cacheRead: cacheReadTokens, cacheWrite: cacheWriteTokens, cacheWrite1h: cacheWrite1hTokens)`.

- [ ] **Step 4: Run them and confirm they pass.** Quote the counts for `JobRunCostMigrationTests`, `WatchMigrationTests`, `JobLedgerPolicyTests`, `JobLedgerTests` and `JobRunnerTests`.

- [ ] **Step 5: Commit** with `feat(ledger): job_runs keeps cache components and the run's provider (v15) (#187)`.

### Task 11: Budgets compare weighted tokens

**Files:**
- Modify `Sources/iris/JobLedger.swift`:
  - `tokensToday` (`:627-646`): select the component columns and sum `CostWeights.weighted` in Swift, through `RowReader`;
  - `usage` (`:654`) follows;
  - `JobUsage.tokensToday` becomes `weightedTokensToday` (`:889-892`), along with the protocol `JobUsageReading` (`:9-12`).
- Modify `Sources/iris/iris.swift`:
  - `TurnBudget` (`:14-34`): add `let provider: String?` (init default nil) and `stopReason(weightedTokens:now:)`;
  - the per-round read (`:1912-1918`) returns the run's `TokenUsage` and computes the weight with `budget.provider`.
- Modify `Sources/iris/JobRunner.swift:1003`: `TurnBudget(maxTokens: limits.perRunTokens, deadline: deadline, provider: run.provider)`.
- Test: `Tests/irisTests/TurnBudgetTests.swift`, `Tests/irisTests/JobLedgerPolicyTests.swift`, `Tests/irisTests/DelegatedSpendTests.swift`, `Tests/irisTests/JobAdmissionTests.swift`.

**Interfaces:**
- Produces:
  - `func weightedTokensToday(jobId: UUID?, calendar: Calendar, now: Date) throws -> Int`, replacing `tokensToday`;
  - `JobUsage.weightedTokensToday`;
  - `TurnBudget.init(maxTokens:deadline:provider:)`;
  - `TurnBudget.stopReason(weightedTokens:now:)`.
- Renaming `tokensToday` makes the compiler find every caller: `JobRunner.admit` (`:223-240`), `JobsCommand.usageSnapshot` (`:358-366`), `DailyDigest` (`:57`), the `list_jobs` builder (`iris.swift:4324-4337`) and the test fakes (`JobAdmissionTests:1000`).

- [ ] **Step 1: Write the failing tests.**

```swift
// JobLedgerPolicyTests
@Test("weightedTokensToday prices each row by its own provider, never the current one")
func weightedTokensTodayPerRowProvider() throws {
    let store = try ConversationStore.inMemory()
    let job = try seedJob(store, "j")
    let utc = calendar("UTC")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var a = makeRun(job, at: now, tokens: 0)
    a.provider = "Anthropic"; a.promptTokens = 10_000; a.candidateTokens = 100; a.totalTokens = 10_100
    a.cacheReadTokens = 9_000
    var legacy = makeRun(job, at: now, tokens: 0)
    legacy.promptTokens = 1_000; legacy.totalTokens = 1_000
    try store.ledger.begin(run: a)
    try store.ledger.begin(run: legacy)
    // a: 1_000 + 900 + 500 = 2_400; legacy: 1_000 at r = w = 1
    #expect(try store.ledger.weightedTokensToday(jobId: job.id, calendar: utc, now: now) == 3_400)
}

// TurnBudgetTests
@Test func stopsOnWeightedTokens() {
    let budget = TurnBudget(maxTokens: 100, deadline: .distantFuture, provider: "Anthropic")
    #expect(budget.stopReason(weightedTokens: 99, now: Date()) == nil)
    #expect(budget.stopReason(weightedTokens: 100, now: Date()) == TurnBudget.weightedTokensExceeded)
}
```

Add a `DelegatedSpendTests` case where a run whose spend is cache-heavy is *not* stopped by a budget that its raw total would have tripped. Seed a provider of `"Anthropic"` on the run's budget and report `UsageMetadata(promptTokenCount: 10_000, candidatesTokenCount: 10, totalTokenCount: 10_010, cacheReadTokens: 9_900, cacheWriteTokens: 0)` against `maxTokens: 5_000`. This one decides decision 5 end to end.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.**
  - **`weightedTokensToday`:** the same `WHERE` clauses. `SELECT provider, promptTokens, candidateTokens, totalTokens, cacheReadTokens, cacheWriteTokens, cacheWrite1hTokens`, then `rows.reduce(0) { sum, row in sum + CostWeights.weighted(components(row), provider: provider(row)) }`. Read each column with `RowReader`; a row that won't read counts as 0 and is logged, like `decodeRuns`.
  - **`TurnBudget`:** `static let weightedTokensExceeded = "budget: weighted tokens exceeded"`, and `static let legacyTokensExceeded = "budget: tokens exceeded"` for matching rows written before 5c (Task 12). `func stopReason(weightedTokens: Int, now: Date) -> String?`.
  - **Engine (`:1912`):** the tuple becomes `(TurnBudget?, TokenUsage)`. Then `let spent = budget.map { CostWeights.weighted(usage.components, provider: $0.provider) } ?? 0` and `budget.stopReason(weightedTokens: spent, now: Date())`.
  - **Update `JobLedgerPolicyTests.makeRun`:** set `run.promptTokens = tokens` alongside `totalTokens` (plan note 8), so existing expectations hold at 1× with no provider. In `DelegatedSpendTests`, where a stop threshold moves because output now weighs 5, recompute the expected figure from the formula in a comment. Don't widen the assertion.

- [ ] **Step 4: Run them and confirm they pass.** Quote the counts for `JobLedgerPolicyTests`, `TurnBudgetTests`, `DelegatedSpendTests`, `JobAdmissionTests`, `JobRunnerTests`, `JobsCommandTests`, `DailyDigestTests` and `JobToolsTests`.

- [ ] **Step 5: Commit** with `feat(budget): budgets and the per-round check compare weighted tokens (#187)`.

### Task 12: Every surface shows weighted tokens

**Files:**
- Modify `Sources/iris/JobRunner.swift`:
  - `budgetReason` (`:251-253`): `"daily weighted-token budget reached (\(scope)): \(used) / \(limit)"`;
  - add `static let legacyBudgetReasonPrefix = "daily token budget reached"`;
  - `budgetStopReason` (`:1777-1781`) also matches `TurnBudget.legacyTokensExceeded`;
  - the card (`:1135-1150`): pass `weightedTokens: CostWeights.weighted(turn.tokens.components, provider: run.provider)`.
- Modify `Sources/iris/Briefing.swift`: `:17-20`, `:63-64` and `:84` accept both the new and the legacy forms.
- Modify `Sources/iris/EventCard.swift`:
  - `weightedTokens: Int?`, in the init (`:85`, default nil), `CodingKeys` and decode (`:151`, `decodeIfPresent`);
  - `:457-470`: `"\(SessionActivity.formatTokenCount(weightedTokens)) weighted tokens"` when present, else today's `"… tokens"` from `totalTokens`. Same for the Copy Transcript head at `:470`.
- Modify `Sources/iris/DailyDigest.swift:96`: `" · \(used)/\(ceiling) weighted tokens today"`.
- Modify `Sources/iris/JobsCommand.swift`: the header at `:281` (`Weighted tokens today`), the footer at `:309` (`Weighted tokens today, all jobs:`), and the doc comments at `:330-338`. Rename `JobFigures.tokensToday` and `GlobalUsage.tokensToday` to `weightedTokensToday`.
- Modify `Sources/iris/iris.swift`:
  - the `list_jobs` keys (`:4324`, `:4337`): `weightedTokensToday`, `weightedTokensTodayAllJobs`;
  - `jobRunJSON` (`:4351-4378`): add `"cacheReadTokens"`, `"cacheWriteTokens"`, `"cacheWrite1hTokens"`, `"provider"` and `"weightedTokens": CostWeights.weighted(run.components, provider: run.provider)`;
  - the two descriptions (`:4218`, `:4222`), in Task 13.
- Modify `Sources/iris/SettingsView.swift`: `JobLimitSetting.title` (`:26-34`) and `help` (`:37-52`) for the three token rows, and the caption (`~:1005`).
- Test: `Tests/irisTests/EventCardTests.swift`, `BriefingTests.swift`, `JobsCommandTests.swift`, `DailyDigestTests.swift`, `JobToolsTests.swift`, `JobLimitSettingTests.swift` (or wherever `JobLimitSetting.title` is asserted; grep it).

**Interfaces:**
- Produces:
  - `EventCard.weightedTokens: Int?`
  - `JobRunner.legacyBudgetReasonPrefix`
  - the `list_jobs` keys `weightedTokensToday` and `weightedTokensTodayAllJobs`
  - `get_job_run`'s `weightedTokens`

- [ ] **Step 1: Write the failing tests.**

```swift
// BriefingTests. Review focus 4.
@Test func legacyBudgetReasonsStillMatch() {
    var r = JobRun(jobId: UUID(), jobName: "j", triggerKind: "schedule", startedAt: Date(), status: .failed)
    r.failureReason = TurnBudget.legacyTokensExceeded
    #expect(Briefing.section(failures: [r], paused: [], recent: [])!.body.contains("budget"))
    var job = Job(name: "k", prompt: "p", trigger: .schedule(.interval(seconds: 60)))
    job.pausedReason = "daily token budget reached (job): 1000000 / 1000000"
    #expect(Briefing.pausedWord(job.pausedReason) == "budget")
    job.pausedReason = JobRunner.budgetReason(scope: "job", used: 5, limit: 5)
    #expect(Briefing.pausedWord(job.pausedReason) == "budget")
}

// EventCardTests
@Test func newCardsSayWeightedOldCardsDoNot() throws {
    // Decode the existing fixture at :70 (totalTokens 4200, no weightedTokens): its summary line
    // still says "4.2k tokens". The same fixture with "weightedTokens":1300 says "1.3k weighted tokens".
}
```

Also:
- `JobsCommandTests`: the header and footer strings.
- `DailyDigestTests`: `weighted tokens today`.
- `JobToolsTests:171,180,226,232`: the renamed keys, plus a `get_job_run` case asserting `weightedTokens` and the three components.
- The Settings test: each token row's `title` contains "Weighted tokens".

Write every body in full.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement** the edits listed under Files.
  - **Settings titles:** "Weighted tokens one run may spend", "Weighted tokens one job may spend a day", "Weighted tokens all jobs may spend a day".
  - **One help line** (on `.perRunTokens`): "Weighted tokens count an uncached input token as 1, an output token as 5, and cache reads and writes at the provider's own ratio, so a run that mostly reads its cache spends far less than its raw token count."
  - **Caption:** "`/jobs` shows what each job has spent today in weighted tokens against these numbers."

- [ ] **Step 4: Run them and confirm they pass.** Quote the counts for every suite named above.

- [ ] **Step 5: Commit** with `feat(budget): every budget surface speaks weighted tokens (#187)`.

### Task 13: Invariant 9 sweep for PR B

- [ ] **Step 1: The nine strings that promise "tokens sent, not billed cost". Rewrite each one.**
  - `iris.swift:4218` (`list_jobs`): "…plus what each has spent today in weighted tokens (an uncached input token is 1, an output token 5, cache reads and writes at the provider's ratio; its runs' subagents included) … — `weightedTokensToday` against `dailyBudget`, … with `weightedTokensTodayAllJobs` against `globalDailyBudget` …". Also replace "how much context a job has sent" with "how much a job has spent".
  - `iris.swift:4222` (`get_job_run`): "…how many tokens it sent, raw and as `weightedTokens` (the unit its budget counts; its subagents included) …".
  - `JobsCommand.swift:335`: the doc comment says "weighted tokens spent".
  - `JobRunner.swift:1963-1965`: "since 5c a budget bounds weighted tokens (§0.5), and a person may reasonably want that unbounded …". Drop "billed weight is a later slice".
  - `README.md:20`: change `"620k / 1M (62%)" — tokens sent, not billed cost —` to `"620k / 1M (62%)", in weighted tokens —`. Change "the whole background system's tokens sent" to "weighted tokens spent". Change "per-run and per-job-daily token budgets" to "weighted-token budgets".
  - `docs/jobs.md:911`, `:978`, `:987`, `:990`, `:1005`: each "tokens sent" becomes "weighted tokens". `:978`'s "since 5a a budget bounds tokens sent, not billed weight — billed weight is a later slice" becomes "since 5c a budget bounds weighted tokens".
- [ ] **Step 2: Sentences the nine don't cover.** Each of these is false after this PR:
  - `docs/jobs.md:910-916`: "1,000,000 tokens per job … Budgets count every token sent, including tokens a provider served from its prompt cache". Rewrite it as the weighted rule, with the formula and the provider table (decision 5). Include the "about 40 rounds instead of 10" example.
  - `docs/jobs.md:938`: `budget: tokens exceeded` becomes `budget: weighted tokens exceeded`. Add that rows written before 5c still say the old words.
  - `docs/jobs.md:991-993`: the `list_jobs` field names.
  - `README.md:26` (Token Tracking): add one sentence. The job budgets count weighted tokens. An easy-tier prompt under 4,096 tokens on Haiku, or under 1,024 on OpenAI, never caches, so it is always charged as uncached (decision 10).
  - `grep -rn "tokens today\|Tokens today\|tokensToday\|token budget\|tokens sent" Sources README.md docs`: read every hit, and fix any that still names raw tokens as the budget unit.
- [ ] **Step 3: Run the full suite** (`timeout 900 swift test`, all three signals). Commit with `docs(budget): weighted tokens, swept (#187)`. Open PR B; the body names Review Focus 3 and 4 and plan notes 7-10, 12 and 14.

---

## PR C: cache TTL policy and OpenAI's cache key

Branch: `feat/agency-5c-cache-ttl`, based on `main`. Independent of A and B.

### Task 14: `CacheHints` ride the request, and are never encoded

**Files:**
- Create: `Sources/iris/CachePolicy.swift`.
- Modify `Sources/iris/Models.swift:9-13` (`GeminiRequest`): add the field and `CodingKeys`.
- Modify `Sources/iris/iris.swift:1951-1955`: re-apply the hints after a `BeforeModel` rewrite.
- Test: `Tests/irisTests/CachePolicyTests.swift` (new), `Tests/irisTests/RequestByteStabilityTests.swift`.

**Interfaces:**
- Produces:

```swift
enum CacheTTL: Int, Sendable, Comparable {
    case fiveMinutes = 300, oneHour = 3600
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Anthropic's marker TTLs, by position. The prefix (tools + system) and the history markers.
/// A longer TTL must come before a shorter one in the prompt, so history is clamped to the prefix.
struct CacheTTLPolicy: Sendable, Equatable {
    let prefix: CacheTTL
    let history: CacheTTL
    init(prefix: CacheTTL, history: CacheTTL) { self.prefix = prefix; self.history = min(history, prefix) }
    static let standard = CacheTTLPolicy(prefix: .fiveMinutes, history: .fiveMinutes)
}

struct CacheHints: Sendable, Equatable {
    var ttl: CacheTTLPolicy = .standard
    /// OpenAI's `prompt_cache_key`; capped at 64 UTF-8 bytes where it is sent.
    var promptCacheKey: String? = nil
}
```

- Also produces `GeminiRequest.cacheHints: CacheHints?`, which isn't encoded.

- [ ] **Step 1: Write the failing tests.**

```swift
@Suite struct CachePolicyTests {
    @Test func historyIsClampedToThePrefix() {
        #expect(CacheTTLPolicy(prefix: .fiveMinutes, history: .oneHour).history == .fiveMinutes)
        #expect(CacheTTLPolicy(prefix: .oneHour, history: .fiveMinutes).history == .fiveMinutes)
    }

    /// Review focus 5.
    @Test func geminiBodyIsByteIdenticalWithHints() throws {
        var request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])],
                                    systemInstruction: nil, tools: nil)
        let plain = try LLMClient.encodeGeminiBody(request)
        request.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour), promptCacheKey: "k")
        #expect(try LLMClient.encodeGeminiBody(request) == plain)
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("cacheHints"))
    }
}
```

`beforeModelRewriteKeepsHints`: install a `BeforeModel` hook that rewrites the request. Grep `fireBeforeModel` in Tests for the existing hook-test seam; `HookManager` hooks are shell scripts, so look for a test that already exercises a rewrite. Then assert the request the capturing client receives still carries `cacheHints`. If no test seam for a rewriting hook exists, extract the decode-and-reapply into `nonisolated static func applyHookRewrite(_ data: Data, to request: GeminiRequest) -> GeminiRequest` and test that function directly. Say which you did in the commit.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.**

```swift
struct GeminiRequest: Codable {
    var contents: [Content]
    var systemInstruction: Content?
    var tools: [Tool]?
    /// 5c: provider-side cache hints (TTL by position, OpenAI's cache key). Never encoded: this
    /// type's JSON is Gemini's request body and the hook payload, and neither knows the field.
    var cacheHints: CacheHints? = nil

    private enum CodingKeys: String, CodingKey { case contents, systemInstruction, tools }
}
```

At `:1952-1955`: `if var modifiedReq = try? JSONDecoder().decode(…) { modifiedReq.cacheHints = request.cacheHints; activeRequest = modifiedReq }`. Comment: "the hook never sees the hints (not encoded), so its rewrite can't carry them".

- [ ] **Step 4: Run them and confirm they pass**, plus `RequestByteStabilityTests`, `RequestDumpTests` and `HookManagerTests`. Quote the counts.

- [ ] **Step 5: Commit** with `feat(cache): CacheHints ride GeminiRequest and are never encoded (#187)`.

### Task 15: Anthropic markers take their TTL from the hints

**Files:**
- Modify `Sources/iris/AnthropicClient.swift`:
  - `:135` (`ephemeral`), with history markers (b), (c) and (d) using `hints.ttl.history`;
  - `:172-174` (the system marker) and `:214-219` (the tools-only marker), using `hints.ttl.prefix`;
  - the comment at `:116-133` gains the TTL rule.
- Test: `Tests/irisTests/AnthropicCacheBreakpointTests.swift`, `Tests/irisTests/AnthropicVertexTransportTests.swift`.

**Interfaces:**
- Produces: `static func cacheControl(_ ttl: CacheTTL) -> [String: Any]`. It returns `["type": "ephemeral"]` for 5 minutes, byte-identical to today, and `["type": "ephemeral", "ttl": "1h"]` for an hour.

- [ ] **Step 1: Write the failing tests** (add them to `AnthropicCacheBreakpointTests`, using its `body(_:)` and `toolRoundRequest()`).

```swift
@Test("no hints: every marker is exactly today's ephemeral")
func noHintsIsToday() throws {
    let text = String(data: try JSONSerialization.data(withJSONObject: try body(toolRoundRequest())), encoding: .utf8)!
    #expect(!text.contains("\"ttl\""))
}

@Test("prefix 1h, history 5m: system carries ttl 1h, messages carry none")
func prefixLongHistoryShort() throws {
    var r = toolRoundRequest()
    r.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .fiveMinutes))
    let b = try body(r)
    let system = try #require(b["system"] as? [[String: Any]])
    #expect((system.last?["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
    let messages = try #require(b["messages"] as? [[String: Any]])
    for m in messages {
        for block in (m["content"] as? [[String: Any]]) ?? [] {
            #expect((block["cache_control"] as? [String: Any])?["ttl"] == nil)
        }
    }
}

@Test("Iris: all four markers 1h, still at most four")
func allOneHour() throws {
    var r = toolRoundRequest(); r.tools = Self.tools
    r.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour))
    let text = String(data: try JSONSerialization.data(withJSONObject: try body(r)), encoding: .utf8)!
    let markers = text.components(separatedBy: "\"cache_control\"").count - 1
    #expect(markers <= 4 && text.components(separatedBy: "\"1h\"").count - 1 == markers)
}

@Test("the direct API sends no extended-cache-ttl beta header")
func noBetaHeader() throws {
    var r = toolRoundRequest()
    r.cacheHints = CacheHints(ttl: .init(prefix: .oneHour, history: .oneHour))
    let req = try AnthropicClient.makeURLRequest(request: r, model: "m", apiKey: "k", stream: false)
    #expect(req.value(forHTTPHeaderField: "anthropic-beta") == nil)
}
```

Add the same 1-hour body assertion for the Vertex transport in `AnthropicVertexTransportTests`. Vertex accepts `ttl` without a header (spec facts).

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.** `let ttl = request.cacheHints?.ttl ?? .standard`, and use `Self.cacheControl(ttl.history)` in `markLastContentBlock`. Use `Self.cacheControl(ttl.prefix)` for the system marker and the tools-only marker. Comment: "Longer TTLs must precede shorter ones; `CacheTTLPolicy` clamps history to the prefix, so this order always holds (5c §0.8)."

- [ ] **Step 4: Run them and confirm they pass.** Quote the counts for `AnthropicCacheBreakpointTests`, `AnthropicVertexTransportTests` and `RequestByteStabilityTests`.

- [ ] **Step 5: Commit** with `feat(cache): Anthropic markers take their TTL from the request's hints (#187)`.

### Task 16: The engine chooses the policy

**Files:**
- Modify: `Sources/iris/CachePolicy.swift`, adding `CacheTTLPolicy.resolve` and `JobCadence`.
- Modify `Sources/iris/iris.swift`:
  - `IrisEngine.init` (`:392`): add `cacheTTLOverride: CacheTTLPolicy? = nil`;
  - set `request.cacheHints` after `:1876`.
- Test: `Tests/irisTests/CachePolicyTests.swift`, `Tests/irisTests/TurnContextTests.swift` (engine-level).

**Interfaces:**
- Produces:
  - `static func resolve(isPinned: Bool, isUnattended: Bool, principal: Principal, backgroundFiresHourly: Bool) -> CacheTTLPolicy`
  - `enum JobCadence { static func anyFiresMoreOftenThanHourly(_ jobs: [Job], now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool }`

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func policyByConversation() {
    #expect(CacheTTLPolicy.resolve(isPinned: true, isUnattended: false, principal: .main, backgroundFiresHourly: false)
            == .init(prefix: .oneHour, history: .oneHour))
    #expect(CacheTTLPolicy.resolve(isPinned: false, isUnattended: true, principal: .main, backgroundFiresHourly: true)
            == .init(prefix: .oneHour, history: .fiveMinutes))
    #expect(CacheTTLPolicy.resolve(isPinned: false, isUnattended: true, principal: .main, backgroundFiresHourly: false)
            == .standard)
    #expect(CacheTTLPolicy.resolve(isPinned: false, isUnattended: false, principal: .main, backgroundFiresHourly: true)
            == .standard)
    // A subagent of Iris is not Iris.
    #expect(CacheTTLPolicy.resolve(isPinned: true, isUnattended: false, principal: .subagent, backgroundFiresHourly: true)
            == .standard)
}

@Test func cadence() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func job(_ t: Trigger, enabled: Bool = true, paused: String? = nil, action: JobAction = .prompt) -> Job {
        var j = Job(name: "j", prompt: "p", trigger: t)
        j.enabled = enabled; j.pausedReason = paused; j.action = action
        return j
    }
    let every15 = Trigger.schedule(.interval(seconds: 900))
    #expect(JobCadence.anyFiresMoreOftenThanHourly([job(every15)], now: now))
    #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(.schedule(.interval(seconds: 3600)))], now: now))
    #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(every15, enabled: false)], now: now))
    #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(every15, paused: "x")], now: now))
    #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(every15, action: .builtin("digest"))], now: now))
    let cron = try CronSchedule(expression: "*/20 9-17 * * 1-5", timeZone: "UTC")
    #expect(JobCadence.anyFiresMoreOftenThanHourly([job(.schedule(.cron(cron)))], now: now))
    let daily = try CronSchedule(expression: "0 10 * * *", timeZone: "UTC")
    #expect(!JobCadence.anyFiresMoreOftenThanHourly([job(.schedule(.cron(daily)))], now: now))
}
```

Check `CronSchedule`'s initializer (`CronSchedule.swift`) and whether `Job.action`, `enabled` and `pausedReason` are `var`. Adjust the helper, not the assertions.

Engine-level test in `TurnContextTests`, using its `run(...)` helper with a `CapturingLLMClient`:
- a pinned conversation's captured request has `cacheHints?.ttl == .init(prefix: .oneHour, history: .oneHour)` and `promptCacheKey == conversationId.uuidString`;
- a plain conversation has `.standard`.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.**

```swift
extension CacheTTLPolicy {
    /// 5c §0.8. Iris (the pinned conversation) holds an hour everywhere: a human-paced day stays
    /// warm for one 2× write per hour of silence. A job run holds the shared prefix for an hour
    /// only when some job comes round inside one; its own history markers stay at five minutes,
    /// because runs are short. Everything else is five minutes.
    static func resolve(isPinned: Bool, isUnattended: Bool, principal: Principal,
                        backgroundFiresHourly: Bool) -> CacheTTLPolicy {
        guard principal == .main else { return .standard }
        if isPinned { return CacheTTLPolicy(prefix: .oneHour, history: .oneHour) }
        if isUnattended, backgroundFiresHourly { return CacheTTLPolicy(prefix: .oneHour, history: .fiveMinutes) }
        return .standard
    }
}

/// Whether any job that runs a model turn on a predictable cadence comes round more often than
/// hourly (plan note 13: schedules only; polls, watches and built-ins don't keep a prefix warm).
enum JobCadence {
    static let samples = 48

    static func anyFiresMoreOftenThanHourly(_ jobs: [Job], now: Date,
                                            calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        jobs.contains { job in
            guard job.enabled, job.pausedReason == nil, case .prompt = job.action,
                  case .schedule(let schedule) = job.trigger else { return false }
            return minimumGap(schedule, after: now, calendar: calendar) < 3600
        }
    }

    static func minimumGap(_ schedule: Schedule, after now: Date, calendar: Calendar) -> TimeInterval {
        if case .interval(let seconds) = schedule { return TimeInterval(seconds) }
        var previous = schedule.next(after: now, calendar: calendar)
        var gap = TimeInterval.infinity
        for _ in 0..<samples {
            guard let p = previous, let n = schedule.next(after: p, calendar: calendar) else { break }
            gap = min(gap, n.timeIntervalSince(p))
            previous = n
        }
        return gap
    }
}
```

Engine, after `var request = GeminiRequest(…)` (`:1876`):

```swift
// 5c §0.8/§0.9. The jobs list is read only for an unattended turn, the one place it matters.
let firesHourly = isUnattended
    && JobCadence.anyFiresMoreOftenThanHourly((try? ledger?.jobs()) ?? [], now: Date())
request.cacheHints = CacheHints(
    ttl: cacheTTLOverride ?? CacheTTLPolicy.resolve(isPinned: isPinned, isUnattended: isUnattended,
                                                    principal: principal, backgroundFiresHourly: firesHourly),
    promptCacheKey: conversationId.uuidString)
```

`ledger` and `isPinned` come from the preamble tuple (`:1445`). Check that later rounds mutate `request` rather than rebuilding it. Grep `request = GeminiRequest` and `request.contents =` between `:1876` and the end of the loop. If a round rebuilds it, set the hints there too.

- [ ] **Step 4: Run them and confirm they pass.** Quote the counts for `CachePolicyTests` and `TurnContextTests`.

- [ ] **Step 5: Commit** with `feat(cache): Iris holds an hour; the background prefix does when a job fires inside one (#187)`.

### Task 17: OpenAI sends `prompt_cache_key`

**Files:**
- Modify: `Sources/iris/OpenAIClient.swift:116-119` (the `body`).
- Test: `Tests/irisTests/OpenAIClientTests.swift` (or the suite that already calls `OpenAIClient.makeURLRequest`; find it with `grep -rln "OpenAIClient.makeURLRequest" Tests`).

**Interfaces:**
- Produces: the `prompt_cache_key` body field. It's present only with hints that carry a non-empty key, and capped at 64 UTF-8 bytes.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func sendsPromptCacheKey() throws {
    var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
    let id = UUID().uuidString
    r.cacheHints = CacheHints(promptCacheKey: id)
    let req = try OpenAIClient.makeURLRequest(request: r, model: "m", apiKey: "k", stream: false)
    let body = try #require(try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any])
    #expect(body["prompt_cache_key"] as? String == id)
}

@Test func noHintsNoKeyAndLongKeysAreByteCapped() throws {
    let plain = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
    let b0 = try JSONSerialization.jsonObject(with: try OpenAIClient.makeURLRequest(request: plain, model: "m", apiKey: "k", stream: false).httpBody!) as! [String: Any]
    #expect(b0["prompt_cache_key"] == nil)
    var long = plain
    long.cacheHints = CacheHints(promptCacheKey: String(repeating: "é", count: 40))   // 80 bytes
    let b1 = try JSONSerialization.jsonObject(with: try OpenAIClient.makeURLRequest(request: long, model: "m", apiKey: "k", stream: false).httpBody!) as! [String: Any]
    #expect(((b1["prompt_cache_key"] as? String)?.utf8.count ?? 0) <= 64)
}
```

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.** After `var body`:

```swift
// 5c §0.9: one request field that routes a conversation's calls to the same cache.
if let key = request.cacheHints?.promptCacheKey, !key.isEmpty {
    body["prompt_cache_key"] = ConversationReader.utf8Prefix(key, maxBytes: 64)
}
```

- [ ] **Step 4: Run them and confirm they pass**, plus `OpenAIStreamMapperTests` and `RequestDumpTests`. Quote the counts.

- [ ] **Step 5: Commit** with `feat(cache): OpenAI requests carry prompt_cache_key (#187)`.

### Task 18: Invariant 9 sweep for PR C

- [ ] **Step 1: Run the greps and read every hit.**
  - `grep -rn "ephemeral\|5-minute\|five minutes\|5 minutes\|TTL\|ttl" Sources/iris/AnthropicClient.swift README.md docs/`. The marker comment at `AnthropicClient.swift:116-133` describes markers without TTLs; add the TTL rule.
  - `grep -rn "cache" README.md`. Line 26 (Token Tracking) gains one sentence: "Iris's own conversation, and job runs when a job fires more often than hourly, hold the Anthropic prompt cache for an hour instead of five minutes."
  - `docs/jobs.md`: wherever a job run's caching is described. Grep `cache`. Add the shared-prefix TTL rule, and the exclusion of polls, watches and built-ins (plan note 13).
  - `docs/specs/2026-09-30-agency-cacheable-prompts.md`: don't edit a merged spec. If it states "5 minutes" as current behaviour, note in the PR body that 5c §0.8 supersedes it.
- [ ] **Step 2: Fix what you found.** Run the full suite (`timeout 900 swift test`, all three signals). Commit with `docs(cache): TTL policy, swept (#187)`. Open PR C; the body names Review Focus 5 and plan notes 11 and 13.

---

## PR D: the cost column and the real-lane measurements

Branch: `feat/agency-5c-perf-cost`, cut from `main` **after A, B and C have merged**. It reads `CostWeights` (B), `cacheWrite1hTokens` (B), `stickyTools:` (A) and `cacheTTLOverride:` (C).

### Task 19: A cost column in the perf report

**Files:**
- Modify `Sources/iris/PerformanceProfiler.swift:46-67` (`ModelCallRecord`): add `public var cacheWrite1hTokens: Int? = nil`, plus an init parameter.
- Modify `Sources/iris/iris.swift:1990-2002` and `Sources/iris/PerfLadder.swift:58`: pass `usageMetadata?.cacheWrite1hTokens`.
- Modify `Sources/iris/PerfRecord.swift:84-110` (`PerfEnvironment`): add `var basePricePerMTok: Double? = nil`.
- Modify `Sources/iris/PerfEnvironment+Capture.swift`: read `IRIS_PERF_BASE_PRICE_PER_MTOK`.
- Modify `Sources/iris/PerfReport.swift`:
  - the rung table (`:23-39`) gains `weighted` and `cost` columns;
  - `cacheTable` (`:104-121`) gains a `1h write` column;
  - a per-scenario line: "weighted total (rung N, repetition M): W ≈ $X".
- Test: `Tests/irisTests/PerfReportTests.swift`.

**Interfaces:**
- Produces:
  - `static func weightedTokens(_ call: ModelCallRecord, provider: String) -> Int`, which maps the record into `UsageComponents` with output = `outputTokens ?? 0` and calls `CostWeights.weighted`;
  - `static func dollars(weighted: Int, basePricePerMTok: Double?) -> Double?`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func weightedAndCostColumns() throws {
    let call = ModelCallRecord(round: 0, model: "claude-sonnet-5", latencyMs: 1, promptTokens: 20_000,
                               outputTokens: 500, returnedToolCalls: false,
                               cacheReadTokens: 19_400, cacheWriteTokens: 400, cacheWrite1hTokens: 100)
    #expect(PerfReport.weightedTokens(call, provider: "Anthropic") == 200 + 1_940 + 375 + 200 + 2_500)
    #expect(PerfReport.dollars(weighted: 1_000_000, basePricePerMTok: 3) == 3)
    #expect(PerfReport.dollars(weighted: 1_000_000, basePricePerMTok: nil) == nil)
}

@Test func oldRecordsStillRender() throws {
    // Load a committed baseline from perf/baselines/ (resolve the path from #filePath, never the
    // cwd: invariant 7). Render it, and check the new columns print "—" rather than throwing.
}
```

- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.** The cost cell prints `"—"` when no base price was given. The report header line names the base price when one was given (`- cost: weighted × $3.00 / MTok (IRIS_PERF_BASE_PRICE_PER_MTOK)`). It's a check against a real bill, never a budget (spec §3).

- [ ] **Step 4: Run them and confirm they pass**, plus `PerfCompareTests`. Quote the counts. **Step 5: Commit** with `feat(perf): weighted and cost columns in the perf report (#187)`.

### Task 20: Scenario pauses, background runs, and experiment switches

**Files:**
- Modify `Sources/iris/Scenario.swift`:
  - `Turn` (`:70-88`): add `pauseBeforeSeconds: Int?`;
  - `Scenario`: add `background: Bool` and `freshConversationPerTurn: Bool`;
  - all three decode with `decodeIfPresent`.
- Modify `Sources/iris/ScenarioRunner.swift`:
  - `run(...)` (`:55-60`): add `experiments: PerfExperiments = .init()` and `sleep: @Sendable (Int) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0) * 1_000_000_000) }`;
  - conversation setup (`:73-84`);
  - the turn loop (`:213-246`).
- Create: `Sources/iris/PerfExperiments.swift`.
- Modify `Sources/iris/PerfCLI.swift:195-199`: read the env and replace the bare `declareStateTools` with a `PerfExperiments`. Also modify `PerfRunner.run` and `PerfLadder.capture`, which thread it down.
- Modify `Sources/iris/PerfReport.swift:17`: one EXPERIMENT line per active switch.
- Test: `Tests/irisTests/ScenarioTests.swift`, `Tests/irisTests/ScenarioRunnerTests.swift`.

**Interfaces:**
- Produces:

```swift
/// Perf-only switches, read once from the environment at `iris --perf run` and passed down.
/// Never a global (invariant 7).
struct PerfExperiments: Sendable, Equatable {
    var declareStateGatedTools = false        // IRIS_PERF_DECLARE_STATE_TOOLS=1 (5a's "declared" arm)
    var stickyTools = true                    // IRIS_PERF_STICKY_TOOLS=0 (5a's "gated" arm)
    var ttlOverride: CacheTTLPolicy? = nil    // IRIS_PERF_TTL=5m|1h|1h-prefix

    static func fromEnvironment(_ env: [String: String]) -> PerfExperiments
}
```

- `IRIS_PERF_TTL` takes three values:
  - `5m` is `.standard`;
  - `1h` is prefix 1h and history 1h;
  - `1h-prefix` is prefix 1h and history 5m.

  Anything else is ignored with a printed warning.
- `ScenarioRunner` passes `stickyTools: experiments.stickyTools` and `cacheTTLOverride: experiments.ttlOverride` to `IrisEngine`.
- PerfEnvironment gains `var experiments: [String]? = nil`, the active switch names, and records them.
- Telling the TTL arms apart after the fact: `RequestDump` won't carry it. `cacheHints` is excluded from `GeminiRequest`'s `Codable` (ruling 11), so a dumped request body has no field saying which arm built it. Don't add a sidecar field to the dump for this — the response already says which TTL actually got used, per call: Task 19's `cacheWrite1hTokens` (parsed from `cache_creation.ephemeral_5m/1h_input_tokens`) is recorded on `ModelCallRecord` in the run, so a `1h` or `1h-prefix` arm's cache writes show a nonzero `cacheWrite1hTokens` and a `5m` arm's don't. That split is sufficient on its own: it's keyed per call, already captured, and answers the only question that matters (which TTL did the provider actually apply), so this plan adds nothing further.

- [ ] **Step 1: Write the failing tests.**
  - `Scenario` decodes `pauseBeforeSeconds`, `background` and `freshConversationPerTurn`. Absent means nil, false and false; an old scenario file decodes unchanged.
  - `PerfExperiments.fromEnvironment` maps each value above, and ignores `IRIS_PERF_TTL=2h`.
  - `ScenarioRunner.run` with a fake client and a recording `sleep`:
    - a turn with `pauseBeforeSeconds: 360` calls `sleep(360)` once, before that turn;
    - `background: true` makes the conversation `isBackground`;
    - `freshConversationPerTurn: true` sends each turn to a different conversation id. Assert on the `CapturingLLMClient`'s requests having one user entry each.

  The sleeper is injected, so the test never waits (bounded-runs constraint).
- [ ] **Step 2: Run them and watch them fail.** **Step 3: Implement.**
  - For `background`, create the conversation with `isBackground = true` and `jobProfile = .readOnly`, so the run has a real job run's surface.
  - For `freshConversationPerTurn`, open a new conversation the same way before each turn, and collect profiles per turn as today.
  - Skip the pause on the fake lane unless the scenario's `clientMode` is `.real`, so the fake suite stays fast.
- [ ] **Step 4: Run them and confirm they pass**; quote the counts. **Step 5: Commit** with `feat(perf): per-turn pauses, background runs and the 5c experiment switches (#187)`.

### Task 21: The 5c scenarios and suite

**Files:**
- Create: `perf/prompts/caching/pinned-pause.json`, `perf/prompts/caching/job-cadence.json`.
- Modify: `perf/prompts/caching/tool-heavy.json` and `pinned-briefing.json` (`expectedTools`).
- Create: `perf/suites/cost-policy.json`.
- Modify: `perf/README.md`, which gains a "5c experiments" section.

- [ ] **Step 1: Write the scenarios.**

```json
{ "name": "pinned-pause", "clientMode": "real", "tier": "medium", "pinned": true,
  "seedFacts": ["QUILLBARROW keeps bees."],
  "expectedTools": [],
  "turns": [
    { "prompt": "Greet me in five words." },
    { "prompt": "Name a prime number between 20 and 30.", "pauseBeforeSeconds": 360 } ] }
```

```json
{ "name": "job-cadence", "clientMode": "real", "tier": "medium",
  "background": true, "freshConversationPerTurn": true,
  "expectedTools": [],
  "turns": [
    { "prompt": "System check: reply with the single word ok.", "source": "job:cadence" },
    { "prompt": "System check: reply with the single word ok.", "source": "job:cadence", "pauseBeforeSeconds": 900 } ] }
```

- `tool-heavy.json` gains `"expectedTools": ["run_command"]`, so `manage_fact` and the peer tools show up in its unexpected-call line (the spec's unprompted-call count).
- `pinned-briefing.json` gains `"expectedTools": ["run_command"]`.

```json
{ "name": "cost-policy", "lane": "real", "repetitions": 2, "pauseMs": 2000, "rungs": [4],
  "scenarios": ["perf/prompts/caching/pinned-pause.json", "perf/prompts/caching/job-cadence.json",
                "perf/prompts/caching/tool-heavy.json"] }
```

- [ ] **Step 2: Check that they load** without spending anything. `swift build -c release && scripts/sign.sh .build/release/iris`, then run `.build/release/iris --perf run perf/suites/cost-policy.json --fake-only`. It must print a skip for the real-lane suite and exit 0. Add the three files to the scenario-loading test that `ScenarioTests` runs over `perf/prompts` (grep `perf/prompts` in Tests); if none exists, add one test that decodes every file in `perf/prompts/caching`. Run it under `timeout 300`.

- [ ] **Step 3: perf/README.md.** Document:
  - the three switches;
  - `IRIS_PERF_BASE_PRICE_PER_MTOK`;
  - the per-turn pause;
  - that the suite takes roughly 75 minutes of wall clock, and why.

- [ ] **Step 4: Commit** with `feat(perf): the 5c cost-policy scenarios and suite (#187)`.

### Task 22: The real-lane measurements (owner approval required)

Nothing in this task runs until the owner says yes, in this session, to the arm list and the estimate below.

- [ ] **Step 1: Ask.** Send the owner:
  - the arms;
  - the provider (Anthropic, via Vertex or direct, whichever is configured);
  - the medium model;
  - the repetitions;
  - about 75 minutes of wall clock per full pass;
  - an estimated spend computed from `PerfReport`'s cost column on a previous `caching` record (`perf/runs/5a-measure2`).

  Wait for an explicit yes.

- [ ] **Step 2: Build and sign.** `swift build -c release && scripts/sign.sh .build/release/iris`. Run one quick command with the new binary first if the provider reads the Keychain (`perf/README.md`, "Keychain and unattended runs").

- [ ] **Step 3: Run the arms,** each under `timeout`. Each arm's output goes to its own directory under `perf/runs/5c-*`.

| Arm | Env | Compares |
|---|---|---|
| pinned 5m | `IRIS_PERF_TTL=5m` | the 6-minute gap at 5 minutes … |
| pinned 1h | (default for pinned) | … against 1 hour |
| cadence 5m | `IRIS_PERF_TTL=5m` | the 15-minute job pair at 5 minutes … |
| cadence 1h | `IRIS_PERF_TTL=1h-prefix` | … against a 1-hour shared prefix |
| tool-heavy sticky | (default) | sticky … |
| tool-heavy gated | `IRIS_PERF_STICKY_TOOLS=0` | … against 5a's gated ($0.097 / $0.094) … |
| tool-heavy declared | `IRIS_PERF_DECLARE_STATE_TOOLS=1` | … and declared ($0.088 / $0.087) |

  Set `IRIS_PERF_BASE_PRICE_PER_MTOK` to the medium model's published uncached-input price in every arm. The command is `timeout 7200 .build/release/iris --perf run perf/suites/cost-policy.json --out perf/runs/5c-<arm>`. Where an arm needs only one scenario, use a one-scenario suite file under `perf/suites/`, so other scenarios aren't paid for twice.

- [ ] **Step 4: Check the weights against a real bill once.** Compare the cost column's sum for one complete pass with the provider's billing console for the same window. Record both figures. If they differ by more than 2×, say which component accounts for it. The weights are a table; fixing a ratio is a one-line change (decision 5).

- [ ] **Step 5: Record the results.** Append a "§4 Measured" section to `docs/specs/2026-10-04-agency-cost-policy.md` with:
  - per arm, the median per-turn cost and the second turn's cache read/write split;
  - the bill comparison;
  - the unexpected-call counts for `manage_fact`, `list_sessions`, `send_to_session` and `set_session_card`.

  Then state the decision each number supports:
  - **1-hour TTL in Iris** stays only if the pinned 1h arm's two-turn cost is ≤ the 5m arm's. Otherwise open an issue to revert §0.8 for Iris.
  - **The 1-hour background prefix** stays only if cadence 1h ≤ cadence 5m.
  - **Stickiness** stays only if tool-heavy sticky is ≤ both 5a arms. A sticky tool with unprompted calls in two or more repetitions gets an issue to drop it from `StickyTools.eligible`.

  Real-lane tallies have been misreported before (memory: agent pass rates need re-measuring). Quote the run files' own numbers, not a summary of them.

- [ ] **Step 6: Commit** with `docs(spec): 5c measured (#187)`. Run the full suite (`timeout 900 swift test`, all three signals) and open PR D.

---

## Self-review against the spec

| Spec item | Where |
|---|---|
| §0.1 sticky, per conversation, in memory, every provider, triggers excluded, not persisted | Tasks 1-2; plan notes 3-6 |
| §0.2 off-state refusal for every sticky tool | Task 4; plan note 2 |
| §0.3 goal_complete-only by dispatch | Task 3 |
| §0.4 prefix-only-grows test | Task 5 (also order) |
| §0.5 weighted unit, table, output ×5, defaults unchanged | Tasks 9, 11; plan notes 7, 12 |
| §0.6 ledger components, provider, tier, read-time weighting, both parse paths | Tasks 7, 8, 10, 11 |
| §0.7 one unit on every listed surface, the nine strings | Tasks 11-13 |
| §0.8 TTL policy, ordering, no beta header | Tasks 14-16; plan note 13 |
| §0.9 OpenAI key; Gemini `cachedContent` excluded | Task 17; §3 (#351) untouched |
| §0.10 uncacheable prompts in docs | Task 13 Step 2 |
| §1 components (`StickyTools`, `CostWeights`, ledger, clients, docs) | Tasks 1, 9, 10, 14-17, 13 |
| §2 unit tests | each task's Step 1 |
| §2 perf: cost column, pinned pause, cadence pair, tool-heavy arms, unprompted counts | Tasks 19-22 |
| §2 full suite: exit 0 + both summaries | every PR's last task |
