import Foundation

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
    /// The share of `cacheRead` a run's delegated subagents read (#370). They may run a model
    /// cheaper to read from than the run's, so these never read below the provider's ratio.
    var delegatedCacheRead: Int = 0
}

/// 5c §0.5: what a run's usage weighs against a budget, in **weighted tokens**. Output counts 5×
/// on every provider (a floor; real prices run 4×-8×), cache writes at the provider's ratio, and
/// cache reads at the model's ratio where `modelReadRatios` knows it, else the provider's (#370).
/// A table, not a bill: the budget guards against runaway spend, not billing precision, and
/// history is re-priced at read time (§0.6), so changing a figure here needs no migration.
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
        case LLMProvider.anthropic.rawValue: return Rates(read: 0.1, write5m: 1.25, write1h: 2.0)
        // Implicit caching: no write charge. Ratios pinned in CostWeightsTests with their date.
        case LLMProvider.gemini.rawValue: return Rates(read: 0.1, write5m: 0, write1h: 0)
        case LLMProvider.openai.rawValue: return Rates(read: 0.1, write5m: 0, write1h: 0)
        default: return unknown
        }
    }

    /// Published cache-read price over uncached-input price, per model id prefix: first-party
    /// Anthropic API ratios, pinned with their date and source in CostWeightsTests. The Vertex
    /// route records provider "Anthropic" too, and partner pricing may differ; that is unverified. A key matches an id equal to it or continuing with `-`
    /// (`claude-opus-5-5` matches `claude-opus-5-5-20261001`), and the longest key wins, so
    /// `claude-opus-5-5` is not read as `claude-opus-5`. Write ratios stay per provider: no model
    /// listed here changes them.
    static let modelReadRatios: [String: Double] = [
        "claude-opus-5-5": 0.05,
        "claude-opus-5": 0.1,
        "claude-fable-5-1": 0.025,
        "claude-mythos-5-1": 0.025,
        "claude-fable-5": 0.1,
        "claude-sonnet": 0.1,
        "claude-haiku": 0.1,
    ]

    /// The read ratio `modelReadRatios` gives `model`, or nil for a model it does not list. Takes
    /// the id as Vertex (`claude-haiku-4-5@20251001`) and Bedrock (`us.anthropic.claude-…`) spell it.
    static func modelReadRatio(for model: String?) -> Double? {
        guard var id = model?.lowercased(), !id.isEmpty else { return nil }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let r = id.range(of: "anthropic.") { id = String(id[r.upperBound...]) }
        return modelReadRatios
            .filter { id == $0.key || id.hasPrefix($0.key + "-") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// The provider's rates with the read ratio replaced by the model's, when the table knows it.
    static func rates(provider: String?, model: String?) -> Rates {
        let base = rates(for: provider)
        guard let read = modelReadRatio(for: model) else { return base }
        return Rates(read: read, write5m: base.write5m, write1h: base.write1h)
    }

    /// No provider means a row (or card) written before 5c: priced at its plain total, every
    /// component at 1× and output included, which is what it was charged when written (plan
    /// rulings 7 and 10), whatever its model. A provider string this build does not know gets
    /// `unknown` and 5× output. No model, or one the table does not list, reads at the provider's
    /// ratio, which is how every row written before #370 is priced. Delegated reads price at the
    /// higher of the model's and the provider's ratio: a subagent may be on another tier, and the
    /// run's model is all the row records, so they never read cheaper than the provider's figure.
    static func weighted(_ u: UsageComponents, provider: String?, model: String?) -> Int {
        guard let provider else { return max(0, u.prompt) + max(0, u.output) }
        let r = rates(provider: provider, model: model)
        let read = max(0, u.cacheRead)
        let delegatedRead = min(max(0, u.delegatedCacheRead), read)
        let delegatedRatio = max(r.read, rates(for: provider).read)
        let write = max(0, u.cacheWrite)
        let write1h = min(max(0, u.cacheWrite1h), write)
        let uncached = max(0, u.prompt - read - write)
        let total = Double(uncached)
            + Double(read - delegatedRead) * r.read
            + Double(delegatedRead) * delegatedRatio
            + Double(write - write1h) * r.write5m
            + Double(write1h) * r.write1h
            + Double(max(0, u.output)) * outputWeight
        // Up, so a fraction never rounds a spend to nothing; less a hair, so floating-point noise
        // in an exact product (19_400 × 0.1) cannot add a whole token.
        return max(0, Int((total - 1e-6).rounded(.up)))
    }
}
