import Foundation
import Testing
@testable import IrisKit

/// #1146 (#1057 PR B, data layer): usage kept per user turn, capped, each turn priced at the rate
/// of the bucket it was charged to.
@MainActor
@Suite("Cost by turn (#1146)", .timeLimit(.minutes(1)))
struct CostByTurnTests {
    private let book = PriceBook.snapshotOnly
    // Snapshot: haiku-5-5 $0.10 in / $0.50 out per MTok; sonnet-5-5 $2 in / $10 out.
    private func rate(_ model: String) -> ResolvedRate { book.resolve(family: "anthropic", model: model, side: .primary) }
    private func call(_ prompt: Int, _ output: Int = 0) -> UsageMetadata {
        UsageMetadata(promptTokenCount: prompt, candidatesTokenCount: output, totalTokenCount: prompt + output)
    }
    private func spend(_ u: inout TokenUsage, _ c: UsageMetadata, model: String = "claude-haiku-5-5", turn: Int?) {
        u.add(c)
        u.record(c, provider: "Anthropic", model: model, rate: rate(model), turn: turn)
    }

    @Test("rounds of one turn on one model merge into one entry; a new turn or a new model opens another")
    func merging() {
        var u = TokenUsage()
        spend(&u, call(100, 10), turn: 1)
        spend(&u, call(200, 20), turn: 1)
        spend(&u, call(300, 30), model: "claude-sonnet-5-5", turn: 1)   // a tier switched mid-turn
        spend(&u, call(400, 40), turn: 2)
        #expect(u.turns.map(\.turn) == [1, 1, 2])
        #expect(u.turns[0].usage.promptTokenCount == 300 && u.turns[0].usage.candidatesTokenCount == 30)
        #expect(u.byModel[u.turns[1].bucket].model == "claude-sonnet-5-5")
        #expect(u.turns[2].usage.promptTokenCount == 400)
    }

    @Test("the list never grows past its cap and drops the oldest turns first")
    func bounded() {
        var u = TokenUsage()
        for t in 1...(TokenUsage.maxTurns + 30) { spend(&u, call(10), turn: t) }
        #expect(u.turns.count == TokenUsage.maxTurns)
        #expect(u.turns.first?.turn == 31 && u.turns.last?.turn == TokenUsage.maxTurns + 30)
        // Many rounds in the newest turn do not grow it either.
        for _ in 0..<500 { spend(&u, call(10), turn: TokenUsage.maxTurns + 30) }
        #expect(u.turns.count == TokenUsage.maxTurns)
    }

    @Test("a call that found no bucket, or named no turn, leaves no entry and stays in the totals")
    func unattributedHasNoEntry() {
        var u = TokenUsage()
        let r = rate("claude-haiku-5-5")
        for i in 0..<(TokenUsage.maxModelBuckets + 3) {
            let c = call(10)
            u.add(c)
            u.record(c, provider: "Anthropic", model: "model-\(i)", rate: r, turn: i + 1)
        }
        #expect(u.turns.count == TokenUsage.maxModelBuckets, "the three with no bucket have no entry")
        spend(&u, call(10), turn: nil)
        #expect(u.turns.count == TokenUsage.maxModelBuckets)
    }

    @Test("each turn is priced at its bucket's stored rate, and shown plus not-shown is the conversation's figure")
    func reconciles() {
        var u = TokenUsage()
        u.add(call(1_000_000))                                           // no model: unattributed
        spend(&u, call(1_000_000, 200_000), turn: 1)                     // haiku: 0.10 + 0.10
        spend(&u, call(1_000_000, 100_000), model: "claude-sonnet-5-5", turn: 2)   // sonnet: 2.00 + 1.00
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-sonnet-5-5", book: book)
        let by = CostByTurn.make(usage: u, cost: cost)
        #expect(by.rows.map(\.turn) == [1, 2] && by.rows.map(\.model) == ["claude-haiku-5-5", "claude-sonnet-5-5"])
        #expect(abs(by.rows[0].dollars - 0.2) < 1e-9 && abs(by.rows[1].dollars - 3.0) < 1e-9)
        #expect(abs(by.shown - 3.2) < 1e-9)
        #expect(abs(by.notShown - 2.0) < 1e-9, "the unattributed million input tokens at the current model")
        #expect(abs(by.shown + by.notShown - cost.dollars) < 1e-9)
    }

    @Test("turns dropped by the cap move into not-shown, so the sum still matches the figure")
    func reconcilesAfterCap() {
        var u = TokenUsage()
        for t in 1...(TokenUsage.maxTurns + 5) { spend(&u, call(1_000_000), turn: t) }
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        let by = CostByTurn.make(usage: u, cost: cost)
        #expect(by.rows.count == TokenUsage.maxTurns && abs(by.notShown - 0.5) < 1e-9)
        #expect(by.shown <= cost.dollars && abs(by.shown + by.notShown - cost.dollars) < 1e-9)
    }

    @Test("a stored rate is kept when the price list moves, per turn as per bucket")
    func rateAtRecordTime() {
        var u = TokenUsage()
        let spentAt = ResolvedRate(rates: TokenRates(input: 1e-6, output: 2e-6, cacheRead: 0), source: .settings, asOf: nil, estimated: false)
        let c = call(1_000_000)
        u.add(c)
        u.record(c, provider: "Anthropic", model: "claude-haiku-5-5", rate: spentAt, turn: 1)
        let cost = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        #expect(abs(CostByTurn.make(usage: u, cost: cost).rows[0].dollars - 1.0) < 1e-9)
    }

    @Test("JSON from before the list existed decodes with none, entries do not carry empty ledgers, and it round-trips")
    func codable() throws {
        let old = #"{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12,"byModel":[{"provider":"Anthropic","model":"m"}]}"#
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: Data(old.utf8))
        #expect(decoded.turns.isEmpty && decoded.turnCount == 0 && decoded.byModel.count == 1)

        var u = TokenUsage()
        spend(&u, call(100, 10), turn: 1)
        u.turnCount = 1
        let data = try JSONEncoder().encode(u)
        let back = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(back == u && back.turns.count == 1 && back.turnCount == 1)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.components(separatedBy: "\"turns\"").count == 2, "only the conversation's own list: entries carry no nested one")
        #expect(json.components(separatedBy: "\"byModel\"").count == 2, "nor a nested ledger, in an entry or a bucket")
    }

    @Test("a malformed entry or a missing field still decodes")
    func lenient() throws {
        let json = #"{"turns":[{"turn":4},{"bucket":2,"usage":{"promptTokenCount":3}}],"turnCount":9}"#
        let u = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(u.turns.count == 2 && u.turns[0].turn == 4 && u.turns[1].usage.promptTokenCount == 3 && u.turnCount == 9)
    }

    @Test("the list survives the conversation store")
    func store() throws {
        let store = try ConversationStore.inMemory()
        var conv = ConversationStoreTests.sample()
        spend(&conv.tokenUsage, call(100, 10), turn: 1)
        try store.apply([ConversationStoreTests.created(conv)])
        let back = try #require(try store.loadAll().conversations.first)
        #expect(back.tokenUsage == conv.tokenUsage && back.tokenUsage.turns.count == 1)
    }

    // MARK: Recording through AppState

    @Test("AppState numbers a user turn once however many rounds it runs, and the next turn gets the next number")
    func appState() throws {
        let state = AppState(store: try ConversationStore.inMemory())
        state.priceBook = .snapshotOnly
        let id = state.createNewConversation(isBackground: false, select: false)
        let (t1, t2) = (UUID(), UUID())
        let haiku = (provider: "Anthropic", model: "claude-haiku-5-5")
        state.updateTokenUsage(for: id, usage: call(100), model: haiku, turn: t1)
        state.updateTokenUsage(for: id, usage: call(200), model: haiku, turn: t1)
        state.updateTokenUsage(for: id, usage: call(300), model: haiku, turn: t2)
        state.updateTokenUsage(for: id, usage: call(50), onPrimary: true)   // a guard call: no model, no turn
        let usage = try #require(state.conversations.first { $0.id == id }?.tokenUsage)
        #expect(usage.turns.map(\.turn) == [1, 2] && usage.turnCount == 2)
        #expect(usage.turns.map(\.usage.promptTokenCount) == [300, 300])
        #expect(usage.promptTokenCount == 650)
    }

    @Test("a real engine round records a turn")
    func engineRound() async throws {
        final class Client: LLMClientProtocol, @unchecked Sendable {
            func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
                GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                               usageMetadata: UsageMetadata(promptTokenCount: 1_000, candidatesTokenCount: 100, totalTokenCount: 1_100))
            }
        }
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(select: false)
        let engine = IrisEngine(state: state, client: Client(), retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, provider: "Anthropic")
        await engine.processInput("one", source: "UI", conversationId: id)
        await engine.processInput("two", source: "UI", conversationId: id)
        let usage = try #require(state.conversations.first { $0.id == id }?.tokenUsage)
        #expect(usage.turns.map(\.turn) == [1, 2] && usage.turns.allSatisfy { $0.usage.promptTokenCount == 1_000 })
    }
}
