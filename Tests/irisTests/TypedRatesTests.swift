import Testing
import Foundation
@testable import IrisKit

/// #239 3c: rates typed in Settings. Raising a delegated rate (or lowering the primary's) is free;
/// the other way is bounded by the snapshot row's band, or the absolute bounds for a model with
/// none. Typed rates are a guarded setting.
@Suite("Typed rates (#239 3c)", .timeLimit(.minutes(1)))
struct TypedRatesTests {
    private let fable = TokenRates(input: 1e-5, output: 5e-5, cacheRead: 2.5e-7, cacheWrite: 1.25e-5)
    private func perM(_ input: Double, _ output: Double, _ read: Double) -> TokenRates {
        TokenRates(input: input / 1e6, output: output / 1e6, cacheRead: read / 1e6, cacheWrite: nil)
    }

    private func harness() -> (ConfigManager, KeychainManager, UserDefaults, String) {
        let suite = "iris-typedrates-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        return (ConfigManager(store: store, guardedSecrets: keychain), keychain, store, suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
    }

    @Test("a delegated rate may rise freely; lowered, it's held to a tenth of its snapshot row")
    func delegatedBound() {
        let higher = TypedRates.clamp(perM(20, 100, 1), side: .delegated, snapshotRow: fable)
        #expect(higher.rates == perM(20, 100, 1) && !higher.clamped)
        let lower = TypedRates.clamp(perM(0.01, 0.01, 0.001), side: .delegated, snapshotRow: fable)
        #expect(lower.clamped)
        #expect(lower.rates.input == fable.input / 10 && lower.rates.output == fable.output / 10 && lower.rates.cacheRead == fable.cacheRead / 10)
    }

    @Test("a primary rate may fall freely; raised, it's held to ten times its snapshot row")
    func primaryBound() {
        let lower = TypedRates.clamp(perM(1, 5, 0.1), side: .primary, snapshotRow: fable)
        #expect(lower.rates == perM(1, 5, 0.1) && !lower.clamped)
        let higher = TypedRates.clamp(perM(1_000, 1_000, 1_000), side: .primary, snapshotRow: fable)
        #expect(higher.clamped && higher.rates.input == fable.input * 10 && higher.rates.output == fable.output * 10)
    }

    @Test("a model with no snapshot row (a custom endpoint) can be typed down to the absolute floor, so the note's fix works")
    func noRowFloorOnly() {
        let cheap = TypedRates.clamp(perM(0.2, 0.8, 0.05), side: .delegated, snapshotRow: nil)
        #expect(cheap.rates == perM(0.2, 0.8, 0.05) && !cheap.clamped)
        let tooCheap = TypedRates.clamp(perM(0.001, 0.8, 0.0001), side: .delegated, snapshotRow: nil)
        #expect(tooCheap.clamped && tooCheap.rates.input == PriceGuards.absoluteFloor)
    }

    @Test("a typed rate replaces the price list for that model, isn't estimated, and is charged; on loopback it's ignored")
    func bookUsesTyped() {
        let book = PriceBook.snapshotOnly
        let pricing = DelegatedPricing(providerId: "my-server", model: "mystery", family: nil, endpointName: "My Server")
        let before = book.charge(UsageComponents(prompt: 1_000_000), pricing: pricing, primaryProvider: "Anthropic",
                                 primaryModel: "claude-fable-5-1")
        #expect(before.estimated)
        book.setTyped([TypedRates.key(providerId: "my-server", model: "mystery"): perM(0.2, 0.8, 0.05)])
        let after = book.charge(UsageComponents(prompt: 1_000_000), pricing: pricing, primaryProvider: "Anthropic",
                                primaryModel: "claude-fable-5-1")
        // $0.20 of input at Fable's $10/MTok input is 20,000 weighted tokens.
        #expect(after.weighted == 20_000 && !after.estimated && after.rateSource == RateSource.settings.rawValue)

        let local = DelegatedPricing(providerId: "ollama", model: "gemma4:12b", family: nil, loopback: true)
        book.setTyped([TypedRates.key(providerId: "ollama", model: "gemma4:12b"): perM(100, 100, 1)])
        let localCharge = book.charge(UsageComponents(prompt: 1_000), pricing: local, primaryProvider: "Anthropic",
                                      primaryModel: "claude-fable-5-1")
        #expect(localCharge.weighted == CostWeights.weighted(UsageComponents(prompt: 1_000), provider: "Anthropic", model: "claude-fable-5-1"))
    }

    @Test("a typed primary rate is the conversion's denominator")
    func typedPrimary() {
        let book = PriceBook.snapshotOnly
        let deepseek = DelegatedPricing(providerId: "deepseek", model: "deepseek-v4-pro", family: "deepseek")
        book.setTyped([TypedRates.primaryKey(model: "claude-fable-5-1"): perM(5, 25, 0.5)])
        let charge = book.charge(UsageComponents(prompt: 1_000_000), pricing: deepseek, primaryProvider: "Anthropic",
                                 primaryModel: "claude-fable-5-1")
        #expect(charge.weighted == 264_000, "$1.32 over a $5/MTok primary input")
    }

    @Test("typed rates are a guarded setting: saved in the secrets item, never in defaults, and a defaults write changes nothing")
    func guarded() {
        let (config, keychain, store, suite) = harness(); defer { teardown(suite) }
        let key = TypedRates.key(providerId: "deepseek", model: "deepseek-v4-pro")
        config.subagentRates = [key: perM(2, 4, 0.1), "bad|row": perM(1, 1, 5)]
        #expect(config.subagentRates == [key: perM(2, 4, 0.1)], "a row breaking a field rule isn't kept")
        #expect(keychain.loadSecrets()[GuardedKey.subagentRates.rawValue] != nil)
        #expect(store.object(forKey: GuardedKey.subagentRates.rawValue) == nil)

        store.set(TypedRates.encode([key: perM(0.0001, 0.0001, 0.00001)]), forKey: GuardedKey.subagentRates.rawValue)
        let next = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(next.subagentRates == [key: perM(2, 4, 0.1)])
    }

    @Test("with the Keychain item unreadable, a typed rate isn't kept, and reading it back says so (#733 review)")
    func unreadableItemKeepsNothing() {
        let (store, keychain, suite) = { () -> (UserDefaults, KeychainManager, String) in
            let suite = "iris-typedrates-\(UUID().uuidString)"
            let store = UserDefaults(suiteName: suite)!
            return (store, KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true), suite)
        }()
        defer { teardown(suite) }
        keychain.saveSecrets([GuardedSettings.markerKey: "1"])
        keychain.simulateReadFailure(-25293)
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        let key = TypedRates.key(providerId: "deepseek", model: "deepseek-v4-pro")
        config.subagentRates = [key: perM(2, 4, 0.1)]
        #expect(config.subagentRates[key] == nil, "what the editor reads back, and refuses on")
        #expect(ModelRatesSection.notSaved.hasPrefix("Not saved"))
    }

    @Test("Settings warns when a typed rate is under a tenth of its family's lowest")
    func warning() {
        #expect(TypedRates.lowersBudgetUse(perM(0.0001, 0.0001, 0.00001), family: "anthropic"))
        #expect(!TypedRates.lowersBudgetUse(perM(3, 15, 0.3), family: "anthropic"))
        #expect(!TypedRates.lowersBudgetUse(perM(0.0001, 0.0001, 0.00001), family: nil), "no family to compare with")
    }

    @Test("the rate editor takes $ per million tokens and refuses a figure that breaks a field rule")
    func editorParse() {
        let row = ModelRatesSection.Row(key: "k", label: "DeepSeek", model: "deepseek-v4-pro", family: "deepseek",
                                        side: .delegated, loopback: false)
        var draft = RateDraft(row: row, current: perM(1, 2, 0.1))
        #expect(draft.input == "1" && draft.rates == perM(1, 2, 0.1))
        draft.cacheRead = "5"
        #expect(draft.rates == nil, "cache read above input")
        draft.cacheRead = "$0.1"; draft.input = "abc"
        #expect(draft.rates == nil)
    }
}

/// #702: a saved key is shown as its last four characters, never more.
@Suite("Key hint (#702)")
struct KeyHintTests {
    @Test("the last four of a key, 'set' for a short one, 'not set' for none")
    func hint() {
        #expect(KeyHint.text("sk-abcdefgh1234") == "\u{2022}\u{2022}\u{2022}\u{2022}1234")
        #expect(KeyHint.text("short") == "set")
        #expect(KeyHint.text("") == "not set" && KeyHint.text(nil) == "not set")
    }

    @Test("the presets set an endpoint's price family, and an edit keeps it")
    func presets() {
        #expect(EndpointDraft(preset: .deepseek).endpoint.priceFamily == "deepseek")
        #expect(EndpointDraft(preset: .openRouter).endpoint.priceFamily == "openrouter")
        #expect(EndpointDraft(preset: .custom).endpoint.priceFamily == nil)
        let saved = ProviderEndpoint(id: "x", name: "X", baseURL: "https://x.example/v1", models: ["m"], priceFamily: "openai")
        #expect(EndpointDraft(saved).endpoint.priceFamily == "openai")
    }
}

/// #239 3c: the app's daily refresh.
@Suite("Model price refresher (#239 3c)", .timeLimit(.minutes(1)))
struct ModelPriceRefresherTests {
    private let sample = Data("""
        {"claude-fable-5-1": {"litellm_provider": "anthropic", "input_cost_per_token": 1.1e-05,
            "output_cost_per_token": 5e-05, "cache_read_input_token_cost": 2.5e-07}}
        """.utf8)

    @Test("Check prices now fetches, and the book takes the new prices; a headless role never fetches")
    func refreshNow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-refresher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let feed = ModelPriceFeed(paths: IrisPaths(root: root), keychain: keychain, download: { [sample] _ in sample })
        let book = PriceBook(feed: feed)
        let refresher = ModelPriceRefresher(feed: feed, book: book)
        #expect(await refresher.refreshNow(role: .runJob) == .failed("Only the app fetches prices."))
        #expect(book.resolve(family: "anthropic", model: "claude-fable-5-1", side: .delegated).source == .snapshot)
        guard case .fetched = await refresher.refreshNow(role: .app) else { Issue.record("an app fetch succeeds"); return }
        let rate = book.resolve(family: "anthropic", model: "claude-fable-5-1", side: .delegated)
        #expect(rate.source == .litellm && rate.rates.input == 1.1e-5)
    }

    @Test("a failed fetch says why in words, never the error's internals")
    func describe() {
        #expect(ModelPriceRefresher.describe(ModelPriceFeed.FetchError.status(503)) == "The price list answered HTTP 503.")
        #expect(ModelPriceRefresher.describe(TimeoutError()) == "The price list didn't arrive in time.")
    }
}
