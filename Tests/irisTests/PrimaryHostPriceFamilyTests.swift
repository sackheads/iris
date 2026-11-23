import Testing
import Foundation
@testable import IrisKit

/// #1355: the OpenAI provider sends its calls to `openAIBaseURL` when one is set, so it is priced by that host. A primary
/// pointed at DeepSeek was priced as OpenAI: `deepseek-chat` has no row there, so the toolbar showed the cheapest OpenAI
/// rate standing in. The readers: the toolbar estimate, a round's per-model bucket, the Settings Primary row, a built-in
/// subagent route, and `--eval`'s price check.
@MainActor
@Suite("a primary OpenAI provider is priced by the host it calls (#1355)")
struct PrimaryHostPriceFamilyTests {
    static let deepseekHost = "https://api.deepseek.com/v1"
    static let deepseekRow = PriceTable.snapshot.rate(family: "deepseek", model: "deepseek-chat")!

    @Test("the family: DeepSeek's host is deepseek; OpenAI's host, an unknown host and none stay openai; other providers are theirs")
    func family() {
        #expect(PriceFamily.of(.openai, openAIBaseURL: Self.deepseekHost) == "deepseek")
        #expect(PriceFamily.of(.openai, openAIBaseURL: "https://api.openai.com/v1") == "openai")
        #expect(PriceFamily.of(.openai, openAIBaseURL: "https://llm.example.com/v1") == "openai")
        #expect(PriceFamily.of(.openai, openAIBaseURL: "") == "openai")
        #expect(PriceFamily.of(.gemini, openAIBaseURL: Self.deepseekHost) == "gemini", "the base URL is the OpenAI provider's only")
        #expect(PriceFamily.of(providerName: "OpenAI", openAIBaseURL: Self.deepseekHost) == "deepseek")
        #expect(PriceFamily.of(providerName: "Anthropic", openAIBaseURL: Self.deepseekHost) == "anthropic")
    }

    @Test("the toolbar prices deepseek-chat from DeepSeek's row through a DeepSeek base URL; OpenAI's own host is unchanged")
    func toolbarEstimate() {
        var usage = TokenUsage()
        usage.add(UsageMetadata(promptTokenCount: 1_000_000, candidatesTokenCount: 0, totalTokenCount: 1_000_000))
        let book = PriceBook.snapshotOnly
        let deepseek = ConversationCost.estimate(usage: usage, provider: "OpenAI", model: "deepseek-chat", openAIBaseURL: Self.deepseekHost, book: book)
        #expect(deepseek.rate.rates == Self.deepseekRow && deepseek.rate.source == .snapshot && !deepseek.rate.estimated, "\(deepseek.rate)")
        let before = ConversationCost.estimate(usage: usage, provider: "OpenAI", model: "deepseek-chat", book: book)
        #expect(before.rate.source == .fallback, "with no host it is still OpenAI's family, which has no deepseek-chat row")
        let unknown = ConversationCost.estimate(usage: usage, provider: "OpenAI", model: "deepseek-chat", openAIBaseURL: "https://llm.example.com/v1", book: book)
        #expect(unknown.rate.source == .fallback, "an unknown host falls back as before")
        let openai = ConversationCost.estimate(usage: usage, provider: "OpenAI", model: "gpt-5", openAIBaseURL: "https://api.openai.com/v1", book: book)
        #expect(openai.rate.rates == PriceTable.snapshot.rate(family: "openai", model: "gpt-5") && openai.rate.source == .snapshot)
    }

    @Test("a round charged to the primary lands in a bucket at DeepSeek's rate")
    func perModelBucket() throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.priceBook = .snapshotOnly
        app.openAIBaseURL = { Self.deepseekHost }
        let id = app.createNewConversation(select: false)
        app.updateTokenUsage(for: id, usage: UsageMetadata(promptTokenCount: 10, candidatesTokenCount: 5, totalTokenCount: 15),
                             model: (provider: "OpenAI", model: "deepseek-chat"))
        let bucket = try #require(app.conversations.first { $0.id == id }?.tokenUsage.byModel.first)
        #expect(bucket.rates == Self.deepseekRow && bucket.rateSource == .snapshot, "\(bucket.rate)")
    }

    @Test("Settings' Primary row names DeepSeek's family for a DeepSeek base URL")
    func settingsPrimaryRow() throws {
        let name = "iris-1355-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store, guardedSecrets: KeychainManager(serviceSuffix: ".r1355", inMemory: true))
        config.primaryProvider = LLMProvider.openai.rawValue
        config.openAIBaseURL = Self.deepseekHost
        config.openaiModelEasy = "deepseek-chat"
        let rows = ModelRatesSection(config: config, registry: []).rows().filter { $0.label == "Primary" }
        #expect(!rows.isEmpty && rows.allSatisfy { $0.family == "deepseek" }, "\(rows.map(\.family))")
    }

    @Test("--eval's price check and a built-in subagent route resolve DeepSeek's family through the OpenAI provider")
    func evalAndRoute() {
        #expect(EvalCost.rates(provider: .openai, model: "deepseek-chat", openAIBaseURL: Self.deepseekHost) == Self.deepseekRow)
        #expect(EvalCost.rates(provider: .openai, model: "deepseek-chat", openAIBaseURL: "") == nil, "as before with no host")
        let route = ProviderRoute(providerId: "openai", target: .builtIn(.openai), model: "deepseek-chat")
        #expect(DelegatedPricing(route: route, endpoints: [], openAIBaseURL: Self.deepseekHost).family == "deepseek")
    }
}
