import Foundation
import Testing
@testable import IrisKit

/// #985: the toolbar's per-conversation cost estimate.
@MainActor
@Suite("Conversation cost (#985)", .timeLimit(.minutes(1)))
struct ConversationCostTests {
    private let book = PriceBook.snapshotOnly
    // claude-haiku-5-5 in the snapshot: $0.10/MTok input, $0.50/MTok output, $0.01/MTok cache read.
    private let usage = TokenUsage(promptTokenCount: 1_000_000, candidatesTokenCount: 200_000, totalTokenCount: 1_200_000)

    @Test("tokens are priced at the model's snapshot rates")
    func prices() {
        let c = ConversationCost.estimate(usage: usage, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        #expect(abs(c.dollars - 0.2) < 1e-9)
        #expect(c.label == "~$0.20")
        #expect(!c.rate.estimated)
    }

    @Test("cache reads are priced at the cache rate, not the input rate")
    func cache() {
        var u = usage; u.cacheReadTokenCount = 500_000
        let c = ConversationCost.estimate(usage: u, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        // 500k uncached input + 500k cache read + 200k output.
        #expect(abs(c.dollars - (0.05 + 0.005 + 0.1)) < 1e-9)
    }

    @Test("a model with no known rate is flagged and the help says so")
    func unknownModel() {
        let c = ConversationCost.estimate(usage: usage, provider: "Anthropic", model: "claude-nonesuch-9", book: book)
        #expect(c.rate.estimated)
        #expect(c.help.contains("No exact rate is known"))
        #expect(c.help.contains("claude-nonesuch-9"))
    }

    @Test("labels: a zero charge, under a cent, and above")
    func labels() {
        let rate = ResolvedRate(rates: TokenRates(input: 0, output: 0, cacheRead: 0), source: .loopback, asOf: nil, estimated: false)
        #expect(ConversationCost(dollars: 0, model: "m", rate: rate).label == "$0.00")
        #expect(ConversationCost(dollars: 0.004, model: "m", rate: rate).label == "<$0.01")
        #expect(ConversationCost(dollars: 12.345, model: "m", rate: rate).label == "~$12.35")
    }

    @Test("the help names the price list date and says the whole conversation is priced at the current model")
    func helpText() {
        let c = ConversationCost.estimate(usage: usage, provider: "Anthropic", model: "claude-haiku-5-5", book: book)
        #expect(c.help.contains(ModelPriceSnapshot.asOf))
        #expect(c.help.contains("current model"))
    }

    @Test("AppState: no cost before any tokens; after, it prices the conversation's tier model")
    func appState() {
        let name = "iris-985-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)
        let app = AppState(store: try! ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.priceBook = book
        let id = app.createNewConversation(select: true)
        #expect(app.conversationCost(for: id, config: config) == nil)
        app.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 1000, candidatesTokenCount: 100, totalTokenCount: 1100))
        let cost = app.conversationCost(for: id, config: config)
        #expect(cost?.model == config.getModel(for: app.effectiveTier(for: id).tier))
        app.sendMessage("/model hard")
        #expect(app.conversationCost(for: id, config: config)?.model == config.getModel(for: .hard))
    }
}
