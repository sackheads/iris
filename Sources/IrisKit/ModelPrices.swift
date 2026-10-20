import Foundation
import os

// Per-family prices for subagents on other model families (#239 3b, docs/specs/2026-10-19-multi-model-subagents.md
// Fork E). Budgets stay in weighted tokens; a delegated call on another family is converted to
// primary-equivalent weighted tokens through dollars. Every guess may only overcharge.

/// USD per token. `cacheWrite` nil is unknown, priced at `input`.
struct TokenRates: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double?
}

enum RateSource: String, Codable, Sendable {
    case litellm, snapshot, settings, settingsClamped = "settings (clamped)", openrouter
    /// The highest or lowest known rate standing in for an unknown model (Q2 a, rule 3).
    case fallback
    /// A server on this Mac: $0, its tokens counted at the primary's weights (rule 4).
    case loopback
}

struct ResolvedRate: Equatable, Sendable {
    var rates: TokenRates
    var source: RateSource
    var asOf: String?
    var estimated: Bool
    /// Why it's estimated, for the card ("set a rate for <endpoint> in Settings").
    var note: String?
}

/// Which side of the conversion a rate is on (the typed-rate and fallback directions differ).
enum PriceSide: Sendable { case delegated, primary }

struct PriceTable: Sendable {
    /// Keyed by family, then model id.
    var rows: [String: [String: TokenRates]]

    static let snapshot = PriceTable(parsing: ModelPriceSnapshot.rows)

    init(rows: [String: [String: TokenRates]]) { self.rows = rows }

    /// The generated snapshot's `family|model|input|output|cacheRead|cacheWrite` lines. A zero or
    /// empty cache-write is unknown.
    init(parsing text: String) {
        var rows: [String: [String: TokenRates]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let input = Double(f[2]), let output = Double(f[3]) else { continue }
            let read = Double(f[4]) ?? input
            let write = Double(f[5]).flatMap { $0 > 0 ? $0 : nil }
            rows[f[0], default: [:]][f[1]] = TokenRates(input: input, output: output, cacheRead: read, cacheWrite: write)
        }
        self.rows = rows
    }

    func rate(family: String, model: String) -> TokenRates? { rows[family]?[model] }
    var allRates: [TokenRates] { rows.values.flatMap(\.values) }
}

enum PriceGuards {
    /// Absolute bounds per field for a family with no snapshot rows (iris-dev-2's #677 review).
    static let absoluteFloor = 0.01 / 1_000_000
    static let absoluteCeiling = 1_000 / 1_000_000.0
    /// The band against the snapshot, either way (rule 3).
    static let band = 10.0

    /// Rule 3, per field: every rate above zero, and cache read no more than input.
    static func fieldsValid(_ r: TokenRates) -> Bool {
        r.input > 0 && r.output > 0 && r.cacheRead > 0 && r.cacheRead <= r.input && (r.cacheWrite.map { $0 > 0 } ?? true)
    }

    private static func fields(_ r: TokenRates) -> [Double] { [r.input, r.output, r.cacheRead] + (r.cacheWrite.map { [$0] } ?? []) }

    /// Within `band` of `reference`, field by field.
    static func withinBand(_ r: TokenRates, of reference: TokenRates) -> Bool {
        func ok(_ x: Double, _ ref: Double) -> Bool { x <= ref * band && x >= ref / band }
        return ok(r.input, reference.input) && ok(r.output, reference.output) && ok(r.cacheRead, reference.cacheRead)
            && (r.cacheWrite == nil || reference.cacheWrite == nil || ok(r.cacheWrite!, reference.cacheWrite!))
    }

    /// Within the family's snapshot range, field by field: at most `band` x the family's highest
    /// of that field, at least 1/`band` of its lowest (an id the snapshot lacks, planner). Per
    /// field, so an output rate is never held only to the family's cheapest cache read (#705 review).
    static func withinFamily(_ r: TokenRates, family: [TokenRates]) -> Bool {
        guard !family.isEmpty else { return true }
        func ok(_ x: Double, _ column: [Double]) -> Bool { x <= column.max()! * band && x >= column.min()! / band }
        let writes = family.compactMap(\.cacheWrite)
        return ok(r.input, family.map(\.input)) && ok(r.output, family.map(\.output)) && ok(r.cacheRead, family.map(\.cacheRead))
            && (r.cacheWrite == nil || writes.isEmpty || ok(r.cacheWrite!, writes))
    }

    static func withinAbsolute(_ r: TokenRates) -> Bool {
        fields(r).allSatisfy { $0 >= absoluteFloor && $0 <= absoluteCeiling }
    }

    /// Field-wise highest (delegated, never undercharges) or lowest (primary, the denominator).
    static func extreme(_ rates: [TokenRates], side: PriceSide) -> TokenRates? {
        guard !rates.isEmpty else { return nil }
        let pick: ([Double]) -> Double = side == .delegated ? { $0.max()! } : { $0.min()! }
        let writes = rates.compactMap(\.cacheWrite)
        return TokenRates(input: pick(rates.map(\.input)), output: pick(rates.map(\.output)),
                          cacheRead: pick(rates.map(\.cacheRead)), cacheWrite: writes.isEmpty ? nil : pick(writes))
    }
}

enum ModelPricing {
    /// The rate one model is charged at, by the rules: a fetched rate that passes the per-field
    /// check and its band; else the snapshot's; else the family's (or every family's) extreme on
    /// the overcharging side, estimated. `fetchedAsOf`/`fetchedSource` describe `fetched`.
    static func resolve(family: String?, model: String, side: PriceSide, loopback: Bool = false,
                        fetched: PriceTable?, fetchedSource: RateSource = .litellm, fetchedAsOf: String? = nil,
                        snapshot: PriceTable = .snapshot, endpointName: String? = nil) -> ResolvedRate {
        if loopback {
            return ResolvedRate(rates: TokenRates(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), source: .loopback,
                                asOf: nil, estimated: false)
        }
        let familyRows = family.map { Array((snapshot.rows[$0] ?? [:]).values) } ?? []
        let snapRow = family.flatMap { snapshot.rate(family: $0, model: model) }

        if let family, let candidate = fetched?.rate(family: family, model: model) {
            let banded: Bool
            if let snapRow { banded = PriceGuards.withinBand(candidate, of: snapRow) }
            else if !familyRows.isEmpty { banded = PriceGuards.withinFamily(candidate, family: familyRows) }
            else { banded = PriceGuards.withinAbsolute(candidate) }
            if PriceGuards.fieldsValid(candidate), banded {
                return ResolvedRate(rates: candidate, source: fetchedSource, asOf: fetchedAsOf,
                                    estimated: snapRow == nil)
            }
            // Rejected: the snapshot's, marked estimated, else fall through to the fallback.
            if let snapRow {
                return ResolvedRate(rates: snapRow, source: .snapshot, asOf: ModelPriceSnapshot.asOf, estimated: true,
                                    note: "the fetched rate for \(model) was out of bounds")
            }
        } else if let snapRow {
            return ResolvedRate(rates: snapRow, source: .snapshot, asOf: ModelPriceSnapshot.asOf, estimated: false)
        }

        // No usable rate: the family's extreme, or every family's when it has none (planner, 3b 1).
        let pool = familyRows.isEmpty ? snapshot.allRates : familyRows
        let fallback = PriceGuards.extreme(pool, side: side)
            ?? TokenRates(input: side == .delegated ? PriceGuards.absoluteCeiling : PriceGuards.absoluteFloor,
                          output: side == .delegated ? PriceGuards.absoluteCeiling : PriceGuards.absoluteFloor,
                          cacheRead: side == .delegated ? PriceGuards.absoluteCeiling : PriceGuards.absoluteFloor, cacheWrite: nil)
        let note = endpointName.map { "set a rate for \($0) in Settings for an accurate charge" }
            ?? "no known rate for \(model); charged at \(familyRows.isEmpty ? "the highest known rate" : "\(family ?? "its") family's highest")"
        return ResolvedRate(rates: fallback, source: .fallback, asOf: ModelPriceSnapshot.asOf, estimated: true,
                            note: side == .delegated ? note : "no known rate for the primary \(model); the lowest known in its family stands in")
    }

    /// Dollars for usage at `rates`. Cache creation is priced at its own rate, or at input.
    static func dollars(_ u: UsageComponents, _ r: TokenRates) -> Double {
        let uncached = max(0, u.prompt - u.cacheRead - u.cacheWrite)
        return Double(uncached) * r.input + Double(u.cacheRead) * r.cacheRead
            + Double(u.cacheWrite) * (r.cacheWrite ?? r.input) + Double(u.output) * r.output
    }

    /// Rule 1: a delegated call's usage as primary-equivalent weighted tokens: its dollars at its
    /// own rate, divided by the primary's input rate (one weighted token is one uncached primary
    /// input token). A loopback call is counted at the primary's own weights (rule 4).
    static func primaryEquivalent(_ usage: UsageComponents, delegated: ResolvedRate, primary: ResolvedRate,
                                  primaryProvider: String?, primaryModel: String?) -> Int {
        if delegated.source == .loopback || primary.rates.input <= 0 {
            return CostWeights.weighted(usage, provider: primaryProvider, model: primaryModel)
        }
        return Int((dollars(usage, delegated.rates) / primary.rates.input).rounded(.up))
    }
}

/// What a routed subagent's calls are priced as, fixed when it is spawned (#239 3b).
struct DelegatedPricing: Equatable, Sendable {
    var providerId: String
    var model: String
    /// The LiteLLM family its prices come from; nil for a custom endpoint with none.
    var family: String?
    var loopback: Bool
    /// A custom endpoint's display name, for the "set a rate" note.
    var endpointName: String?

    init(providerId: String, model: String, family: String?, loopback: Bool = false, endpointName: String? = nil) {
        self.providerId = providerId
        self.model = model
        self.family = family
        self.loopback = loopback
        self.endpointName = endpointName
    }

    init(route: ProviderRoute, endpoints: [ProviderEndpoint]) {
        switch route.target {
        case .builtIn(let provider):
            self.init(providerId: route.providerId, model: route.model, family: PriceFamily.of(provider))
        case .endpoint(let baseURL, _):
            let endpoint = endpoints.first { $0.id == route.providerId }
            self.init(providerId: route.providerId, model: route.model,
                      family: endpoint?.priceFamily ?? PriceFamily.forHost(of: baseURL),
                      loopback: PriceFamily.isLoopback(baseURL), endpointName: endpoint?.name ?? route.providerId)
        }
    }
}

enum PriceFamily {
    static func of(_ provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        case .openai: "openai"
        }
    }

    /// The family of a provider's own API host, for an endpoint set up without a preset. Exact
    /// hosts only: anything else has no family and is charged the highest known rate.
    static func forHost(of baseURL: String) -> String? {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return nil }
        return [
            "api.deepseek.com": "deepseek", "api.openai.com": "openai", "api.anthropic.com": "anthropic",
            "generativelanguage.googleapis.com": "gemini", "openrouter.ai": "openrouter",
        ][host]
    }

    /// A server on this Mac (rule 4): its tokens cost nothing, and count at the primary's weights.
    static func isLoopback(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        // A dotted 127.x.y.z address only: `127.example.com` is a name anyone can point anywhere.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}

/// One routed model's spend inside a run, in its own tokens and as primary-equivalent weighted
/// tokens (rule 1). Kept per model on the run's row (`job_runs.delegatedCharges`).
struct DelegatedCharge: Codable, Equatable, Sendable {
    var providerId: String
    var model: String
    var prompt: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    /// Primary-equivalent weighted tokens, priced when charged.
    var weighted: Int = 0
    var estimated: Bool = false
    var rateSource: String = RateSource.snapshot.rawValue
    var note: String?

    init(providerId: String, model: String) {
        self.providerId = providerId
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try c.decodeIfPresent(String.self, forKey: .providerId) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        prompt = try c.decodeIfPresent(Int.self, forKey: .prompt) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        weighted = try c.decodeIfPresent(Int.self, forKey: .weighted) ?? 0
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
        rateSource = try c.decodeIfPresent(String.self, forKey: .rateSource) ?? RateSource.snapshot.rawValue
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    var components: UsageComponents { UsageComponents(prompt: prompt, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) }

    static func encode(_ charges: [DelegatedCharge]) -> String? {
        guard !charges.isEmpty, let data = try? JSONEncoder().encode(charges) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// An unreadable column reads as no charges; the row's own figures still stand.
    static func decode(_ text: String?) -> [DelegatedCharge] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DelegatedCharge].self, from: data)) ?? []
    }

    /// The one line a card or run log adds when any charge is a guess.
    static func estimatedNote(_ charges: [DelegatedCharge]) -> String? {
        let guesses = charges.filter(\.estimated)
        guard !guesses.isEmpty else { return nil }
        let notes = Array(Set(guesses.compactMap(\.note))).sorted()
        return "estimated" + (notes.isEmpty ? "" : ": " + notes.joined(separator: "; "))
    }
}

/// Where prices come from at charge time: the app's fetched cache when there is one, else the
/// bundled snapshot. Read once per process and on `reload()`.
final class PriceBook: Sendable {
    static let shared = PriceBook(feed: ModelPriceFeed(paths: .default, keychain: KeychainManager.shared))

    private let feed: ModelPriceFeed?
    private let state: OSAllocatedUnfairLock<ModelPriceFeed.Cached?>

    init(feed: ModelPriceFeed?) {
        self.feed = feed
        state = OSAllocatedUnfairLock(initialState: feed?.cached())
    }

    /// The snapshot alone, for tests.
    static var snapshotOnly: PriceBook { PriceBook(feed: nil) }

    func reload() { let fresh = feed?.cached(); state.withLock { $0 = fresh } }

    func resolve(family: String?, model: String, side: PriceSide, loopback: Bool = false, endpointName: String? = nil) -> ResolvedRate {
        let cached = state.withLock { $0 }
        return ModelPricing.resolve(family: family, model: model, side: side, loopback: loopback,
                                    fetched: cached.map { PriceTable(rows: $0.rows) }, fetchedAsOf: cached?.asOf,
                                    endpointName: endpointName)
    }

    /// `usage` on `pricing`'s model, as primary-equivalent weighted tokens for a run whose primary
    /// is `primaryProvider`/`primaryModel` (an `LLMProvider` raw value and a model id).
    func charge(_ usage: UsageComponents, pricing: DelegatedPricing, primaryProvider: String?, primaryModel: String?) -> DelegatedCharge {
        let delegated = resolve(family: pricing.family, model: pricing.model, side: .delegated, loopback: pricing.loopback,
                                endpointName: pricing.family == nil ? pricing.endpointName : nil)
        let primaryFamily = primaryProvider.flatMap(LLMProvider.init(rawValue:)).map(PriceFamily.of)
        let primary = resolve(family: primaryFamily, model: primaryModel ?? "", side: .primary)
        var charge = DelegatedCharge(providerId: pricing.providerId, model: pricing.model)
        charge.prompt = usage.prompt
        charge.output = usage.output
        charge.cacheRead = usage.cacheRead
        charge.cacheWrite = usage.cacheWrite
        charge.weighted = ModelPricing.primaryEquivalent(usage, delegated: delegated, primary: primary,
                                                         primaryProvider: primaryProvider, primaryModel: primaryModel)
        // The primary side is a guess too when its own rate is: the conversion divides by it.
        charge.estimated = delegated.estimated || (primary.estimated && !pricing.loopback)
        charge.rateSource = delegated.source.rawValue
        charge.note = delegated.note ?? (charge.estimated && !pricing.loopback ? primary.note : nil)
        return charge
    }
}
