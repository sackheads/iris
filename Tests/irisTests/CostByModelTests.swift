import Foundation
import Testing
@testable import IrisKit

/// #1057: usage kept per model, each priced at the rate it was spent at.
@MainActor
@Suite("Cost by model (#1057)", .timeLimit(.minutes(1)))
struct CostByModelTests {
    private let book = PriceBook.snapshotOnly
    // Snapshot: haiku-5-5 $0.10 in / $0.50 out per MTok; sonnet-5-5 $2 in / $10 out.
    private func rate(_ model: String) -> ResolvedRate { book.resolve(family: "anthropic", model: model, side: .primary) }
    private func call(_ prompt: Int, _ output: Int) -> UsageMetadata {
        UsageMetadata(promptTokenCount: prompt, candidatesTokenCount: output, totalTokenCount: prompt + output)
    }

    @Test("a call goes to its model's bucket, and the same model at the same rate merges")
    func buckets() {
        var u = TokenUsage()
        for (m, p, o) in [("claude-haiku-5-5", 100, 10), ("claude-sonnet-5-5", 200, 20), ("claude-haiku-5-5", 300, 30)] {
            let c = call(p, o)
            u.add(c)
            u.record(c, provider: "Anthropic", model: m, rate: rate(m))
        }
        #expect(u.byModel.map(\.model) == ["claude-haiku-5-5", "claude-sonnet-5-5"])
        #expect(u.byModel[0].usage.promptTokenCount == 400 && u.byModel[0].usage.candidatesTokenCount == 40)
        #expect(u.byModel[1].usage.promptTokenCount == 200)
        #expect(u.promptTokenCount == 600 && u.unattributed.totalTokenCount == 0)
    }

    @Test("a rate change on the same model opens a second bucket, so the earlier spend keeps its rate")
    func rateChange() {
        var u = TokenUsage()
        let old = rate("claude-haiku-5-5")
        var new = old
        new.rates.input *= 2
        for r in [old, new] {
            let c = call(1_000, 0)
            u.add(c)
            u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: r)
        }
        #expect(u.byModel.count == 2)
        #expect(u.byModel[0].rates.input == old.rates.input && u.byModel[1].rates.input == new.rates.input)
    }

    @Test("the ledger never grows past its cap; a call with no room stays in the totals and shows as unattributed")
    func bounded() {
        var u = TokenUsage()
        let r = rate("claude-haiku-5-5")
        for i in 0..<(TokenUsage.maxModelBuckets + 8) {
            let c = call(10, 1)
            u.add(c)
            u.record(c, provider: "Anthropic", model: "model-\(i)", rate: r)
        }
        // Many calls on one model do not grow it either.
        for _ in 0..<1_000 {
            let c = call(10, 1)
            u.add(c)
            u.record(c, provider: "Anthropic", model: "model-0", rate: r)
        }
        #expect(u.byModel.count == TokenUsage.maxModelBuckets)
        #expect(u.promptTokenCount == (TokenUsage.maxModelBuckets + 8) * 10 + 10_000)
        #expect(u.unattributed.promptTokenCount == 8 * 10)
    }

    @Test("unattributed is the totals less the buckets, and cache counts stay unknown when never reported")
    func unattributed() {
        var u = TokenUsage()
        u.add(call(500, 50))                      // before any model was recorded
        let c = UsageMetadata(promptTokenCount: 100, candidatesTokenCount: 10, totalTokenCount: 110, cacheReadTokens: 40)
        u.add(c)
        u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: rate("claude-haiku-5-5"))
        let rest = u.unattributed
        #expect(rest.promptTokenCount == 500 && rest.candidatesTokenCount == 50 && rest.totalTokenCount == 550)
        #expect(rest.cacheReadTokenCount == 0, "the total has a cache count, the bucket took all of it")
        #expect(TokenUsage().unattributed.cacheReadTokenCount == nil)
    }

    @Test("each model is priced at its own rate, the rest at the current model, and the figure is the sum")
    func pricing() {
        var u = TokenUsage()
        u.add(call(1_000_000, 0))                 // unattributed: priced at the current model
        for (m, p, o) in [("claude-haiku-5-5", 1_000_000, 200_000), ("claude-sonnet-5-5", 1_000_000, 100_000)] {
            let c = call(p, o)
            u.add(c)
            u.record(c, provider: "Anthropic", model: m, rate: rate(m))
        }
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-sonnet-5-5", book: book)
        // 1M at sonnet (2.00) + haiku (0.10 + 0.10) + sonnet (2.00 + 1.00)
        #expect(abs(cost.dollars - 5.2) < 1e-9)
        #expect(cost.hasLedger && cost.help.contains("its own rate"))
        // Not the old one-rate answer for all of it: 3M in + 300k out at sonnet is 9.0.
        #expect(abs(cost.dollars - 9.0) > 1)
    }

    @Test("a bucket keeps the rate it was spent at when the price list moves later")
    func rateAtRecordTime() {
        var u = TokenUsage()
        let spentAt = ResolvedRate(rates: TokenRates(input: 1e-6, output: 2e-6, cacheRead: 0), source: .settings, asOf: nil, estimated: false)
        let c = call(1_000_000, 0)
        u.add(c)
        u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: spentAt)
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        #expect(abs(cost.dollars - 1.0) < 1e-9, "the stored $1/MTok, not the list's $0.10")
    }

    @Test("a conversation with no ledger keeps the one-rate estimate, labelled as before")
    func noLedger() {
        let u = TokenUsage(promptTokenCount: 1_000_000, candidatesTokenCount: 200_000, totalTokenCount: 1_200_000)
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        #expect(abs(cost.dollars - 0.2) < 1e-9 && !cost.hasLedger)
        #expect(cost.help.contains("The whole conversation is priced at its current model"))
        let b = CostBreakdown.make(usage: u, cost: cost)
        #expect(b.sections.isEmpty && b.lines.count == 4)
    }

    @Test("the breakdown has a section per model plus the unattributed share, and they sum to the figure")
    func sections() {
        var u = TokenUsage()
        u.add(call(2_000_000, 0))
        for (m, p, o) in [("claude-haiku-5-5", 1_000_000, 200_000), ("claude-sonnet-5-5", 1_000_000, 100_000)] {
            let c = call(p, o)
            u.add(c)
            u.record(c, provider: "Anthropic", model: m, rate: rate(m))
        }
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        let b = CostBreakdown.make(usage: u, cost: cost)
        #expect(b.sections.map(\.title) == ["claude-haiku-5-5", "claude-sonnet-5-5", "Not attributed to a model"])
        #expect(abs(b.total - cost.dollars) < 1e-9)
        #expect(abs(b.sections.reduce(0) { $0 + $1.total } - cost.dollars) < 1e-9)
        #expect(b.sections[2].note?.contains("claude-haiku-5-5") == true)
        #expect(b.lines.isEmpty)
    }

    @Test("a ledger that covers every token has no unattributed section")
    func fullyAttributed() {
        var u = TokenUsage()
        let c = call(100, 10)
        u.add(c)
        u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: rate("claude-haiku-5-5"))
        let b = CostBreakdown.make(usage: u, cost: ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: book))
        #expect(b.sections.map(\.title) == ["claude-haiku-5-5"])
    }

    // MARK: Persistence (invariant 1)

    @Test("usage JSON from a build with no ledger decodes with an empty one, and the ledger round-trips")
    func codable() throws {
        let old = #"{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12}"#
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: Data(old.utf8))
        #expect(decoded.byModel.isEmpty && decoded.promptTokenCount == 10)

        var u = TokenUsage()
        let c = UsageMetadata(promptTokenCount: 100, candidatesTokenCount: 10, totalTokenCount: 110, cacheReadTokens: 5, cacheWriteTokens: 7)
        u.add(c)
        u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: rate("claude-haiku-5-5"))
        let back = try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(u))
        #expect(back == u && back.byModel.count == 1)
        #expect(back.byModel[0].rate == rate("claude-haiku-5-5"))
    }

    @Test("a bucket with a rate source this build does not know, or missing fields, still decodes")
    func lenientBucket() throws {
        let json = #"{"byModel":[{"provider":"Anthropic","model":"m","rateSource":"from-the-future"}]}"#
        let u = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(u.byModel.count == 1 && u.byModel[0].rateSource == .fallback && u.byModel[0].model == "m")
    }

    @Test("the ledger survives the conversation store")
    func store() throws {
        let store = try ConversationStore.inMemory()
        var conv = ConversationStoreTests.sample()
        let c = call(100, 10)
        conv.tokenUsage.add(c)
        conv.tokenUsage.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: rate("claude-haiku-5-5"))
        try store.apply([ConversationStoreTests.created(conv)])
        let back = try #require(try store.loadAll().conversations.first)
        #expect(back.tokenUsage == conv.tokenUsage && back.tokenUsage.byModel.count == 1)
    }

    // MARK: Recording through AppState

    @Test("AppState charges a named call to its model and a call with none to the totals only")
    func appState() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        state.priceBook = .snapshotOnly
        let id = state.createNewConversation(isBackground: false, select: false)
        state.updateTokenUsage(for: id, usage: call(1_000_000, 0), model: (provider: "Anthropic", model: "claude-haiku-5-5"))
        // A tier switched mid-conversation: the next round runs on another model.
        state.updateTokenUsage(for: id, usage: call(1_000_000, 0), model: (provider: "Anthropic", model: "claude-sonnet-5-5"))
        state.updateTokenUsage(for: id, usage: call(1_000_000, 0), onPrimary: true)
        let usage = try #require(state.conversations.first { $0.id == id }?.tokenUsage)
        #expect(usage.byModel.map(\.model) == ["claude-haiku-5-5", "claude-sonnet-5-5"])
        #expect(usage.promptTokenCount == 3_000_000 && usage.unattributed.promptTokenCount == 1_000_000)
        let cost = ConversationCost.estimate(usage: usage, provider: "Anthropic", model: "claude-sonnet-5-5", book: state.priceBook)
        #expect(abs(cost.dollars - (0.1 + 2.0 + 2.0)) < 1e-9, "haiku's round stays at haiku's rate after the switch")
    }

    private final class UsageClient: LLMClientProtocol, @unchecked Sendable {
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                           usageMetadata: UsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 100, totalTokenCount: 1_100))
        }
    }

    @Test("a real engine round charges the conversation's model, not only its totals")
    func engineRound() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(select: false)
        let engine = IrisEngine(state: state, client: UsageClient(), retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, provider: "Anthropic")
        await engine.processInput("hi", source: "UI", conversationId: id)
        let usage = try #require(state.conversations.first { $0.id == id }?.tokenUsage)
        #expect(usage.promptTokenCount == 1_000)
        let bucket = try #require(usage.byModel.first, "the round names the model it ran on")
        #expect(usage.byModel.count == 1 && bucket.provider == "Anthropic" && !bucket.model.isEmpty)
        #expect(bucket.usage.promptTokenCount == 1_000 && usage.unattributed.promptTokenCount == 0)
    }
}
