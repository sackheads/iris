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
}

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

    /// No provider means a row (or card) written before 5c: priced at its plain total, every
    /// component at 1× and output included, which is what it was charged when written (plan
    /// rulings 7 and 10). A provider string this build does not know gets `unknown` and 5× output.
    static func weighted(_ u: UsageComponents, provider: String?) -> Int {
        guard let provider else { return max(0, u.prompt) + max(0, u.output) }
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
        // Up, so a fraction never rounds a spend to nothing; less a hair, so floating-point noise
        // in an exact product (19_400 × 0.1) cannot add a whole token.
        return max(0, Int((total - 1e-6).rounded(.up)))
    }
}
