import Testing
import Foundation
@testable import IrisKit

/// #239 3b: the per-family price rules. Pure: no fetch, no store. Every guess may only overcharge.
@Suite("Model prices (#239 3b)")
struct ModelPricesTests {
    private let fable = TokenRates(input: 1e-5, output: 5e-5, cacheRead: 2.5e-7, cacheWrite: 1.25e-5)

    @Test("the generated snapshot parses, with the checked ids at their published prices")
    func snapshot() throws {
        let table = PriceTable.snapshot
        #expect(table.rate(family: "anthropic", model: "claude-fable-5-1") == fable)
        let deepseek = try #require(table.rate(family: "deepseek", model: "deepseek-v4-pro"))
        #expect(deepseek.input == 1.32e-6 && deepseek.cacheWrite == nil, "a zero cache-write is unknown, priced at input")
        #expect(table.rate(family: "gemini", model: "gemini-3.8-flash")?.output == 3.75e-6)
        #expect(table.rows["openrouter"] == nil)
    }

    @Test("a fetched rate within its band is used; one outside it, or failing a field, falls back to the snapshot")
    func fetchedBand() {
        func resolve(_ r: TokenRates) -> ResolvedRate {
            ModelPricing.resolve(family: "anthropic", model: "claude-fable-5-1", side: .delegated,
                                 fetched: PriceTable(rows: ["anthropic": ["claude-fable-5-1": r]]), fetchedAsOf: "2026-10-20")
        }
        var cheaper = fable; cheaper.input = 5e-6
        #expect(resolve(cheaper) == ResolvedRate(rates: cheaper, source: .litellm, asOf: "2026-10-20", estimated: false))
        // 1000x low on every field, so only the band (not the cache-read rule) can catch it.
        let tiny = TokenRates(input: fable.input / 1_000, output: fable.output / 1_000, cacheRead: fable.cacheRead / 1_000,
                              cacheWrite: fable.cacheWrite.map { $0 / 1_000 })
        var zero = fable; zero.output = 0
        var readAboveInput = fable; readAboveInput.cacheRead = 2e-5
        for bad in [tiny, zero, readAboveInput] {
            let r = resolve(bad)
            #expect(r.rates == fable && r.source == .snapshot && r.estimated, "\(bad)")
        }
    }

    @Test("the primary's rate (the denominator) can't be inflated past the band either")
    func primaryBand() {
        var inflated = fable; inflated.input *= 100
        let r = ModelPricing.resolve(family: "anthropic", model: "claude-fable-5-1", side: .primary,
                                     fetched: PriceTable(rows: ["anthropic": ["claude-fable-5-1": inflated]]))
        #expect(r.rates == fable && r.estimated)
    }

    @Test("an id the snapshot lacks is banded against its family's range; a family with no rows gets the absolute bounds")
    func newIdsAndFamilies() {
        let newer = TokenRates(input: 3e-6, output: 1.5e-5, cacheRead: 3e-7, cacheWrite: nil)
        let ok = ModelPricing.resolve(family: "anthropic", model: "claude-next-6", side: .delegated,
                                      fetched: PriceTable(rows: ["anthropic": ["claude-next-6": newer]]))
        #expect(ok.rates == newer && ok.estimated, "no snapshot row to vouch for it")
        // An output rate below a tenth of the family's cheapest output, though above its cheapest cache read.
        var cheapOutput = newer; cheapOutput.output = Array(PriceTable.snapshot.rows["anthropic"]!.values).map(\.output).min()! / 20
        #expect(ModelPricing.resolve(family: "anthropic", model: "claude-next-6", side: .delegated,
                                     fetched: PriceTable(rows: ["anthropic": ["claude-next-6": cheapOutput]])).source == .fallback)
        var wild = newer; wild.output = 1.0                    // far past 10x the family's highest
        let rejected = ModelPricing.resolve(family: "anthropic", model: "claude-next-6", side: .delegated,
                                            fetched: PriceTable(rows: ["anthropic": ["claude-next-6": wild]]))
        #expect(rejected.source == .fallback && rejected.estimated)

        let router = TokenRates(input: 2e-6, output: 8e-6, cacheRead: 2e-7, cacheWrite: nil)
        #expect(ModelPricing.resolve(family: "openrouter", model: "x/y", side: .delegated, fetched: PriceTable(rows: ["openrouter": ["x/y": router]]),
                                     fetchedSource: .openrouter).source == .openrouter)
        var free = router; free.input = 1e-12                 // below $0.01/MTok
        #expect(ModelPricing.resolve(family: "openrouter", model: "x/y", side: .delegated,
                                     fetched: PriceTable(rows: ["openrouter": ["x/y": free]])).source == .fallback)
    }

    @Test("an unknown model is charged at its family's highest (delegated) or lowest (primary) rate, estimated")
    func unknownModel() {
        let family = Array(PriceTable.snapshot.rows["deepseek"]!.values)
        let high = ModelPricing.resolve(family: "deepseek", model: "deepseek-v9", side: .delegated, fetched: nil)
        let low = ModelPricing.resolve(family: "deepseek", model: "deepseek-v9", side: .primary, fetched: nil)
        #expect(high.estimated && high.source == .fallback)
        #expect(high.rates.input == family.map(\.input).max() && high.rates.output == family.map(\.output).max())
        #expect(low.rates.input == family.map(\.input).min())
    }

    @Test("a custom endpoint with no family is charged the highest known rate, and the note says how to fix it")
    func customEndpoint() {
        let r = ModelPricing.resolve(family: nil, model: "mystery", side: .delegated, fetched: nil, endpointName: "My Server")
        #expect(r.rates.input == PriceTable.snapshot.allRates.map(\.input).max())
        #expect(r.estimated && r.note == "set a rate for My Server in Settings for an accurate charge")
    }

    @Test("a loopback model costs $0 and its tokens count at the primary's weights")
    func loopback() {
        let usage = UsageComponents(prompt: 1_000, output: 100)
        let local = ModelPricing.resolve(family: nil, model: "gemma4:12b", side: .delegated, loopback: true, fetched: nil)
        let primary = ResolvedRate(rates: fable, source: .snapshot, asOf: nil, estimated: false)
        #expect(local.source == .loopback && !local.estimated)
        #expect(ModelPricing.primaryEquivalent(usage, delegated: local, primary: primary,
                                               primaryProvider: "Anthropic", primaryModel: "claude-fable-5-1")
                == CostWeights.weighted(usage, provider: "Anthropic", model: "claude-fable-5-1"))
    }

    @Test("a delegated call converts through dollars into primary-equivalent weighted tokens")
    func conversion() {
        let deepseek = ResolvedRate(rates: PriceTable.snapshot.rate(family: "deepseek", model: "deepseek-v4-pro")!,
                                    source: .snapshot, asOf: nil, estimated: false)
        let primary = ResolvedRate(rates: fable, source: .snapshot, asOf: nil, estimated: false)
        // 1M uncached input on DeepSeek is $1.32; at Fable's $10/MTok input that is 132,000 tokens.
        #expect(ModelPricing.primaryEquivalent(UsageComponents(prompt: 1_000_000), delegated: deepseek, primary: primary,
                                               primaryProvider: "Anthropic", primaryModel: "claude-fable-5-1") == 132_000)
        // Cache reads at their own rate: 1M read at 4.4e-8 is $0.044, 4,400 tokens.
        #expect(ModelPricing.primaryEquivalent(UsageComponents(prompt: 1_000_000, cacheRead: 1_000_000), delegated: deepseek,
                                               primary: primary, primaryProvider: nil, primaryModel: nil) == 4_400)
    }
}

/// #239 3b: LiteLLM's price map, fetched by the app only and cached in a protected directory.
@Suite("Model price feed (#239 3b)", .timeLimit(.minutes(1)))
struct ModelPriceFeedTests {
    private func keychain() -> KeychainManager { KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true) }

    private func home() throws -> (IrisPaths, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-pricefeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (IrisPaths(root: root), { try? FileManager.default.removeItem(at: root) })
    }

    private let sample = Data("""
        {"sample_spec": {"litellm_provider": "openai"},
         "claude-fable-5-1": {"litellm_provider": "anthropic", "mode": "chat", "input_cost_per_token": 1e-05,
            "output_cost_per_token": 5e-05, "cache_read_input_token_cost": 2.5e-07},
         "bedrock/claude-fable-5-1": {"litellm_provider": "bedrock", "input_cost_per_token": 9, "output_cost_per_token": 9},
         "deepseek/deepseek-v4-pro": {"litellm_provider": "deepseek", "input_cost_per_token": 1.32e-06,
            "output_cost_per_token": 3.96e-06, "cache_creation_input_token_cost": 0.0},
         "text-embedding-9": {"litellm_provider": "openai", "mode": "embedding", "input_cost_per_token": 1e-07, "output_cost_per_token": 1e-07}}
        """.utf8)

    @Test("parsing keeps each family's own rows, matched on litellm_provider, and drops other hosts and modes")
    func parse() throws {
        let rows = try #require(ModelPriceFeed.parse(sample))
        #expect(rows["anthropic"]?["claude-fable-5-1"]?.input == 1e-5)
        #expect(rows["deepseek"]?["deepseek-v4-pro"]?.cacheWrite == nil, "a zero cache write is unknown")
        #expect(rows["deepseek"]?["deepseek-v4-pro"]?.cacheRead == 1.32e-6, "no cache read rate prices reads at input")
        #expect(rows["bedrock"] == nil && rows["openai"]?["text-embedding-9"] == nil)
    }

    @Test("only the app fetches; a headless run gets nothing and leaves no cache")
    func appOnly() async throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        let calls = LockedCounter()
        let feed = ModelPriceFeed(paths: paths, keychain: keychain(), download: { [sample] _ in calls.bump(); return sample })
        #expect(try await feed.refresh(role: .runJob) == nil)
        #expect(try await feed.refresh(role: nil) == nil)
        #expect(calls.value == 0 && feed.cached() == nil)
        let now = Date()
        let cached = try #require(try await feed.refresh(now: now, role: .app))
        #expect(feed.cached() == cached && !feed.isStale(now: now))
        #expect(feed.isStale(now: now.addingTimeInterval(ModelPriceFeed.refreshInterval)))
    }

    /// OpenRouter's `/api/v1/models` shape: dollars per token as strings.
    static let openRouterSample = Data("""
    {"data": [
      {"id": "meta-llama/llama-4-scout", "pricing": {"prompt": "0.00000008", "completion": "0.0000003", "input_cache_read": "0.00000002"}},
      {"id": "anthropic/claude-sonnet-5-5", "pricing": {"prompt": "0.000002", "completion": "0.00001"}},
      {"id": "some/free-model", "pricing": {"prompt": "0", "completion": "0"}},
      {"id": "some/free-input", "pricing": {"prompt": "0", "completion": "0.000001"}},
      {"id": "openrouter/auto", "pricing": {"prompt": "-1", "completion": "-1"}},
      {"id": "absurd/model", "pricing": {"prompt": "0.5", "completion": "0.5"}}
    ]}
    """.utf8)

    @Test("OpenRouter's list parses to dollars per token, leaving out free and varying models (#701)")
    func parsesOpenRouter() throws {
        let rows = try #require(ModelPriceFeed.parseOpenRouter(Self.openRouterSample))
        let llama = try #require(rows["meta-llama/llama-4-scout"])
        #expect(llama.input == 8e-8 && llama.output == 3e-7 && llama.cacheRead == 2e-8)
        #expect(rows["anthropic/claude-sonnet-5-5"]?.cacheRead == 2e-6, "no cache-read price reads at input")
        #expect(rows["some/free-model"] == nil && rows["some/free-input"] == nil && rows["openrouter/auto"] == nil)
        #expect(ModelPriceFeed.parseOpenRouter(Data("{}".utf8)) == nil)
    }

    @Test("a refresh fetches OpenRouter too, and its models are charged at their own price, held to the absolute bounds (#701)")
    func openRouterRefreshAndResolve() async throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        let feed = ModelPriceFeed(paths: paths, keychain: keychain(), download: { [sample] url in
            url == ModelPriceFeed.openRouterURL ? Self.openRouterSample : sample
        })
        let cached = try #require(try await feed.refresh(role: .app))
        #expect(cached.rows["openrouter"]?.count == 3)
        let book = PriceBook(feed: feed)
        let llama = book.resolve(family: "openrouter", model: "meta-llama/llama-4-scout", side: .delegated)
        #expect(llama.source == .openrouter && !llama.estimated && llama.rates.input == 8e-8)
        // $500,000 per million tokens is past the absolute ceiling: the fallback, estimated.
        let absurd = book.resolve(family: "openrouter", model: "absurd/model", side: .delegated)
        #expect(absurd.source == .fallback && absurd.estimated)
        // The LiteLLM families are still LiteLLM's.
        #expect(book.resolve(family: "anthropic", model: "claude-fable-5-1", side: .delegated).source == .litellm)
    }

    @Test("OpenRouter failing leaves the LiteLLM fetch whole (#701)")
    func openRouterFailureIsContained() async throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        struct Down: Error {}
        let feed = ModelPriceFeed(paths: paths, keychain: keychain(), download: { [sample] url in
            if url == ModelPriceFeed.openRouterURL { throw Down() }
            return sample
        })
        let cached = try #require(try await feed.refresh(role: .app))
        #expect(cached.rows["openrouter"] == nil && cached.rows["anthropic"] != nil)
        let rate = PriceBook(feed: feed).resolve(family: "openrouter", model: "meta-llama/llama-4-scout", side: .delegated)
        #expect(rate.source == .fallback && rate.estimated, "as before #701")
    }

    @Test("a download that isn't https is refused before any request")
    func httpsOnly() async {
        await #expect(throws: ModelPriceFeed.FetchError.notHTTPS) {
            _ = try await ModelPriceFeed.boundedDownload(URL(string: "http://example.invalid/prices.json")!)
        }
    }

    @Test("a body that parses to no rows is an error, and the old cache stays")
    func unparseable() async throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        let item = keychain()
        let good = ModelPriceFeed(paths: paths, keychain: item, download: { [sample] _ in sample })
        let before = try #require(try await good.refresh(role: .app))
        let bad = ModelPriceFeed(paths: paths, keychain: item, download: { _ in Data("{}".utf8) })
        await #expect(throws: ModelPriceFeed.FetchError.unparseable) { try await bad.refresh(role: .app) }
        #expect(bad.cached() == before)
    }

    @Test("the cache is in a protected directory: a model's write_file there is never auto-allowed")
    func cacheIsProtected() throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        let feed = ModelPriceFeed(paths: paths)
        #expect(PermissionManager(paths: paths).isProtectedWrite(toolName: "write_file", path: feed.cacheURL.path))
    }

    @Test("a cache changed after its fetch is never used: the snapshot applies, and the feed asks to fetch again")
    func plantedCacheIgnored() async throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        let item = keychain()
        let feed = ModelPriceFeed(paths: paths, keychain: item, download: { [sample] _ in sample })
        let now = Date()
        _ = try #require(try await feed.refresh(now: now, role: .app))
        #expect(feed.cached() != nil && !feed.isStale(now: now))

        // A shell rewrites the file with a price 1000x lower and a fresh timestamp.
        var planted = try #require(feed.cached())
        planted.rows["anthropic"]?["claude-fable-5-1"]?.input = 1e-8
        try JSONEncoder().encode(planted).write(to: feed.cacheURL, options: .atomic)
        #expect(feed.cached() == nil, "a cache that doesn't match the stored fingerprint is ignored")
        #expect(feed.isStale(now: now), "and the next refresh replaces it")
        let book = PriceBook(feed: feed)
        let rate = book.resolve(family: "anthropic", model: "claude-fable-5-1", side: .delegated)
        #expect(rate.source == .snapshot && rate.rates.input == 1e-5, "its rates are never used")
    }

    @Test("with no fingerprint, an unreadable item, or no guarded item at all, the cache is not trusted")
    func untrustedWithoutFingerprint() async throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        let item = keychain()
        let feed = ModelPriceFeed(paths: paths, keychain: item, download: { [sample] _ in sample })
        _ = try #require(try await feed.refresh(role: .app))
        #expect(ModelPriceFeed(paths: paths, keychain: nil).cached() == nil, "legacy mode trusts no cache")
        #expect(ModelPriceFeed(paths: paths, keychain: keychain()).cached() == nil, "an item with no fingerprint")
        item.simulateReadFailure(-25293)
        #expect(feed.cached() == nil, "an unreadable item is a missing fingerprint")
    }

    @Test("a fetch whose fingerprint can't be stored keeps no trusted cache")
    func blockedItemFailsFetch() async throws {
        let (paths, cleanup) = try home(); defer { cleanup() }
        let item = keychain()
        item.blockWrites()
        let feed = ModelPriceFeed(paths: paths, keychain: item, download: { [sample] _ in sample })
        await #expect(throws: ModelPriceFeed.FetchError.cannotFingerprint) { try await feed.refresh(role: .app) }
        #expect(feed.cached() == nil)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
