import Testing
import Foundation
@testable import IrisKit

/// #239 3b: a job run's subagents on other models are charged at their own price, converted to the
/// run's weighted tokens, kept per model on the run's row, and counted by the day's budget.
@MainActor
@Suite("Delegated charges (#239 3b)", .timeLimit(.minutes(1)))
struct DelegatedChargeTests {
    private struct NoSink: TurnUsageSink { func record(_ tokens: TokenUsage) async {} }

    private let deepseek = DelegatedPricing(providerId: "deepseek", model: "deepseek-v4-pro", family: "deepseek")
    private let fableBudget = TurnBudget(maxTokens: 0, seconds: 600, provider: LLMProvider.anthropic.rawValue, model: "claude-fable-5-1")

    private func runWithChild(_ pricing: DelegatedPricing?) throws -> (AppState, run: UUID, child: UUID) {
        let state = AppState(store: try ConversationStore.inMemory())
        state.priceBook = .snapshotOnly
        let run = state.createNewConversation(isBackground: true, select: false)
        state.registerRun(run, budget: fableBudget, sink: NoSink())
        let child = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(child, of: run)
        if let pricing { state.setDelegatedPricing(pricing, for: child) }
        return (state, run, child)
    }

    @Test("a subagent on another family is charged to the run at its own price, per model, not at the run's weights")
    func chargedAtItsPrice() throws {
        let (state, run, child) = try runWithChild(deepseek)
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 1_000_000, candidatesTokenCount: 0, totalTokenCount: 1_000_000))
        let usage = state.runUsage(for: run)
        #expect(usage.promptTokenCount == 0, "none of it is priced at the run's own weights")
        let charge = try #require(usage.delegatedCharges.first)
        // $1.32 at DeepSeek's input rate is 132,000 of Fable's $10/MTok input tokens.
        #expect(charge.model == "deepseek-v4-pro" && charge.weighted == 132_000 && !charge.estimated)
        #expect(usage.weighted(provider: fableBudget.provider, model: fableBudget.model) == 132_000)
    }

    @Test("a subagent on the run's own family is charged at the run's weights, as before")
    func sameFamilyUnchanged() throws {
        let (state, run, child) = try runWithChild(nil)
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 10, totalTokenCount: 1_010))
        let usage = state.runUsage(for: run)
        #expect(usage.promptTokenCount == 1_000 && usage.delegatedCharges.isEmpty)
    }

    @Test("the run's budget stops a round on the converted figure")
    func budgetStops() throws {
        let (state, run, child) = try runWithChild(DelegatedPricing(providerId: "x", model: "mystery", family: nil, endpointName: "My Server"))
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 0, totalTokenCount: 1_000))
        let usage = state.runUsage(for: run)
        let budget = TurnBudget(maxTokens: 1_000, seconds: 600, provider: fableBudget.provider, model: fableBudget.model)
        let spent = usage.weighted(provider: budget.provider, model: budget.model)
        // An unknown endpoint is charged the highest known rate, so 1,000 of its tokens cost more than 1,000 of Fable's.
        #expect(spent > 1_000 && budget.stopReason(weightedTokens: spent) == TurnBudget.weightedTokensExceeded)
        #expect(DelegatedCharge.estimatedNote(usage.delegatedCharges) == "estimated: set a rate for My Server in Settings for an accurate charge")
    }

    @Test("the engine's round check stops a run whose subagent on another family spent past its budget")
    func engineStopsOnCharges() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        state.priceBook = .snapshotOnly
        let run = state.createNewConversation(isBackground: true, select: false)
        // 132,000 weighted from the child below; the run's own spend is nothing.
        state.registerRun(run, budget: TurnBudget(maxTokens: 50_000, seconds: 600, provider: fableBudget.provider,
                                                  model: fableBudget.model), sink: NoSink())
        let child = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(child, of: run)
        state.setDelegatedPricing(deepseek, for: child)
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 1_000_000, candidatesTokenCount: 0, totalTokenCount: 1_000_000))
        let client = FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "more")]))],
                                                              usageMetadata: nil)])
        let engine = IrisEngine(state: state, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go on", source: "JobRunner", conversationId: run)
        #expect(client.callCount == 0, "the round is refused on the converted figure before any model call")
    }

    @Test("a call on the primary's provider in a routed subagent's conversation (a guard call) is charged at the run's weights")
    func guardCallAtPrimary() throws {
        let (state, run, child) = try runWithChild(deepseek)
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 0, totalTokenCount: 1_000),
                               onPrimary: true)
        let usage = state.runUsage(for: run)
        #expect(usage.promptTokenCount == 1_000 && usage.delegatedCharges.isEmpty, "not priced at DeepSeek's cheaper rate")
    }

    @Test("a guard call in a routed subagent's conversation, through the guard sink, is charged at the run's weights")
    func guardSinkAtPrimary() async throws {
        let (state, run, child) = try runWithChild(deepseek)
        let sink = GuardUsage.charging(child, in: state)
        await sink.record(UsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 0, totalTokenCount: 1_000))
        let usage = state.runUsage(for: run)
        #expect(usage.promptTokenCount == 1_000 && usage.delegatedCharges.isEmpty)
    }

    @Test("a run's subagents' pricing is dropped when the run is drained")
    func pricingDroppedWithRun() throws {
        let (state, run, child) = try runWithChild(deepseek)
        state.takeBackgroundDenials(for: run)
        // Linked to a new run, the old subagent is no longer priced as routed.
        let next = state.createNewConversation(isBackground: true, select: false)
        state.registerRun(next, budget: fableBudget, sink: NoSink())
        state.linkBackgroundDescendant(child, of: next)
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 10, candidatesTokenCount: 0, totalTokenCount: 10))
        #expect(state.runUsage(for: next).delegatedCharges.isEmpty)
    }

    @Test("only a dotted 127.x.y.z address is loopback, never a name that starts with 127")
    func loopbackIsAnAddress() {
        #expect(PriceFamily.isLoopback("http://127.0.0.1:11434/v1") && PriceFamily.isLoopback("http://localhost:1234"))
        #expect(!PriceFamily.isLoopback("https://127.evil.example/v1"))
        #expect(!PriceFamily.isLoopback("https://127.0.0.1.evil.example/v1"))
    }

    @Test("a local server's tokens cost what the primary's would, never nothing")
    func loopbackAtPrimaryWeights() throws {
        let local = DelegatedPricing(route: ProviderRoute(providerId: "ollama", target: .endpoint(baseURL: "http://127.0.0.1:11434/v1", apiKey: ""),
                                                          model: "gemma4:12b"), endpoints: [])
        #expect(local.loopback)
        let (state, run, child) = try runWithChild(local)
        state.updateTokenUsage(for: child, usage: UsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 100, totalTokenCount: 1_100))
        let charge = try #require(state.runUsage(for: run).delegatedCharges.first)
        #expect(charge.weighted == CostWeights.weighted(UsageComponents(prompt: 1_000, output: 100),
                                                        provider: fableBudget.provider, model: fableBudget.model))
    }

    @Test("an endpoint's family comes from its preset, else its host; an unknown host has none")
    func endpointFamily() {
        func pricing(_ url: String, family: String? = nil) -> DelegatedPricing {
            let endpoint = ProviderEndpoint(id: "e", name: "E", baseURL: url, models: ["m"], priceFamily: family)
            return DelegatedPricing(route: ProviderRoute(providerId: "e", target: .endpoint(baseURL: url, apiKey: ""), model: "m"),
                                    endpoints: [endpoint])
        }
        #expect(pricing("https://api.deepseek.com/v1").family == "deepseek")
        #expect(pricing("https://proxy.example/v1", family: "openai").family == "openai")
        #expect(pricing("https://api.deepseek.com.evil.example/v1").family == nil)
        #expect(pricing("https://proxy.example/v1").endpointName == "E")
        #expect(!pricing("https://api.deepseek.com/v1").loopback)
    }

    @Test("an endpoint saved before 3b decodes with no price family")
    func endpointDecodesWithoutFamily() throws {
        let json = #"{"id":"e","name":"E","baseURL":"https://x.example/v1","models":["m"],"needsKey":true}"#
        let endpoint = try JSONDecoder().decode(ProviderEndpoint.self, from: Data(json.utf8))
        #expect(endpoint.priceFamily == nil)
    }

    @Test("the charges are kept on the run's row, read back, and counted by the day's budget")
    func ledgerKeepsCharges() throws {
        let store = try ConversationStore.inMemory()
        let ledger = store.ledger
        let job = Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 60)))
        try ledger.upsert(job)
        let now = Date()
        var row = JobRun(jobId: job.id, jobName: job.name, triggerKind: "manual", startedAt: now)
        row.provider = LLMProvider.anthropic.rawValue
        row.model = "claude-fable-5-1"
        try ledger.begin(run: row)
        var charge = DelegatedCharge(providerId: "deepseek", model: "deepseek-v4-pro")
        charge.prompt = 1_000_000; charge.weighted = 132_000
        var tokens = TokenUsage(promptTokenCount: 100, candidatesTokenCount: 0, totalTokenCount: 100)
        tokens.delegatedCharges = [charge]
        try ledger.recordUsage(runId: row.id, tokens: tokens)
        var smaller = tokens; smaller.delegatedCharges[0].weighted = 10
        try ledger.recordUsage(runId: row.id, tokens: smaller)
        #expect(try ledger.run(id: row.id)?.delegatedCharges == [charge], "a mid-run write never lowers the charges")
        try ledger.finish(runId: row.id, status: .completed, outcome: "ok", failureReason: nil, blockedTool: nil,
                          tokens: tokens, finishedAt: now)
        let stored = try #require(try ledger.run(id: row.id))
        #expect(stored.delegatedCharges == [charge])
        #expect(stored.weighted == CostWeights.weighted(stored.components, provider: stored.provider, model: stored.model) + 132_000)
        #expect(try ledger.weightedTokensToday(jobId: job.id, calendar: .current, now: now) == stored.weighted)
    }

    @Test("a card whose charge is a guess says so beside its weighted tokens; one written before 3b has no note")
    func cardNote() throws {
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "j", status: .completed, startedAt: Date(), finishedAt: Date(),
                             weightedTokens: 1_500, costNote: "estimated: set a rate for My Server in Settings for an accurate charge")
        #expect(card.tokensText == "1.5k weighted tokens (estimated: set a rate for My Server in Settings for an accurate charge)")
        let plain = EventCard(runId: UUID(), jobId: UUID(), jobName: "j", status: .completed, startedAt: Date(), finishedAt: Date(),
                              weightedTokens: 1_500)
        #expect(plain.tokensText == "1.5k weighted tokens")
    }

    @Test("a routed subagent spawned for a job run is priced from its route")
    func spawnSetsPricing() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        state.priceBook = .snapshotOnly
        let run = state.createNewConversation(isBackground: true, select: false)
        state.registerRun(run, budget: fableBudget, sink: NoSink())
        let routed = FakeLLMClient(responses: [GeminiResponse(
            candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: FunctionCall(name: "goal_complete", args: ["summary": .string("done")]))]))],
            usageMetadata: UsageMetadata(promptTokenCount: 1_000_000, candidatesTokenCount: 0, totalTokenCount: 1_000_000))])
        let route = ProviderRoute(providerId: "deepseek", target: .endpoint(baseURL: "https://api.deepseek.com/v1", apiKey: ""),
                                  model: "deepseek-v4-pro")
        let outcome = await SubagentManager.shared.runSubagent(role: "r", task: "t", effort: "medium", parentConversationId: run,
                                                               client: FakeLLMClient(responses: []), route: route,
                                                               routedClient: routed, appState: state)
        #expect(outcome.status == .completed)
        let charge = try #require(state.runUsage(for: run).delegatedCharges.first)
        #expect(charge.providerId == "deepseek" && charge.weighted == 132_000)
    }
}
