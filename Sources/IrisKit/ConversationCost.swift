import Foundation

/// The toolbar's cost figure for a conversation (#985): its token usage at one model's rates. An
/// estimate, always: usage is kept as conversation totals, not per turn, so the whole conversation
/// is priced at the model it runs on now, and a tier switched mid-conversation reprices it all.
/// A subagent's tokens sit in its own conversation and are not added.
struct ConversationCost: Equatable {
    var dollars: Double
    var model: String
    var rate: ResolvedRate

    /// `provider` is an `LLMProvider` raw value ("Anthropic"); the price list keys families in lower case.
    static func estimate(usage: TokenUsage, provider: String, model: String, book: PriceBook = .shared) -> ConversationCost {
        let rate = book.resolve(family: provider.lowercased(), model: model, side: .primary)
        return ConversationCost(dollars: ModelPricing.dollars(usage.components, rate.rates), model: model, rate: rate)
    }

    /// "~$0.42", or "<$0.01" below a cent. The tilde stays on every figure: it is never exact.
    var label: String {
        if dollars <= 0 { return "$0.00" }
        return dollars < 0.01 ? "<$0.01" : String(format: "~$%.2f", dollars)
    }

    /// Where the rate came from, as the hover and the breakdown both say it.
    var rateSourceNote: String {
        switch rate.source {
        case .snapshot: return "price list of \(rate.asOf ?? "unknown date")"
        case .loopback: return "a server on this Mac: no charge"
        default: return rate.source.rawValue
        }
    }

    var help: String {
        var text = "Estimated cost: this conversation's tokens at \(model)'s rates (\(rateSourceNote))"
        text += ". The whole conversation is priced at its current model, and subagents are not included."
        if rate.estimated { text += " No exact rate is known for this model: \(rate.note ?? "a fallback rate stands in")." }
        return text
    }
}

/// The toolbar figure taken apart by token type (#1011): the same four terms `ModelPricing.dollars`
/// adds, each as tokens x rate, so the lines sum to the figure and a person can set them beside an
/// invoice. It breaks down what is stored (conversation totals) and nothing finer: per-turn and
/// per-model costs need usage recorded per turn, which is not (#1011's remainder).
struct CostBreakdown: Equatable {
    struct Line: Equatable {
        enum Kind: Equatable { case input, cacheRead, cacheWrite, output }
        var kind: Kind
        var label: String
        /// nil when the provider reported no figure for this kind (not the same as zero).
        var tokens: Int?
        /// Dollars per million tokens, as billed for this line.
        var ratePerMTok: Double
        var dollars: Double
        /// Why this line's rate is not the plain one, when it is not.
        var note: String? = nil
    }

    var lines: [Line]
    var total: Double
    var model: String
    var rateSourceNote: String
    /// What the figure does not say, in the words the popover shows. Never empty: it is an estimate.
    var caveats: [String]

    static func make(usage: TokenUsage, cost: ConversationCost) -> CostBreakdown {
        let r = cost.rate.rates
        let u = usage.components
        // The same arithmetic as `ModelPricing.dollars`, term by term.
        let uncached = max(0, u.prompt - u.cacheRead - u.cacheWrite)
        let writeRate = r.cacheWrite ?? r.input
        let lines = [
            Line(kind: .input, label: "Input (not cached)", tokens: uncached, ratePerMTok: r.input * 1e6,
                 dollars: Double(uncached) * r.input),
            Line(kind: .cacheRead, label: "Cache read", tokens: usage.cacheReadTokenCount, ratePerMTok: r.cacheRead * 1e6,
                 dollars: Double(u.cacheRead) * r.cacheRead),
            Line(kind: .cacheWrite, label: "Cache write", tokens: usage.cacheWriteTokenCount, ratePerMTok: writeRate * 1e6,
                 dollars: Double(u.cacheWrite) * writeRate,
                 note: r.cacheWrite == nil ? "No cache-write rate is known, so these are priced as input." : nil),
            Line(kind: .output, label: "Output", tokens: u.output, ratePerMTok: r.output * 1e6,
                 dollars: Double(u.output) * r.output,
                 note: u.output > usage.candidatesTokenCount
                     ? "Includes \(tokens(u.output - usage.candidatesTokenCount)) thinking tokens (the provider's total minus the prompt), billed as output." : nil),
        ]
        var caveats = ["An estimate, not a bill. The whole conversation is priced at \(cost.model)'s rates, its current model: a tier switched mid-conversation reprices all of it.",
                       "Subagents' tokens sit in their own conversations and are not included."]
        if (usage.cacheWrite1hTokenCount ?? 0) > 0 {
            caveats.append("\(tokens(usage.cacheWrite1hTokenCount)) of the cache-write tokens were 1-hour writes, which bill above the rate used here.")
        }
        if cost.rate.estimated {
            caveats.append("No exact rate is known for this model: \(cost.rate.note ?? "a fallback rate stands in").")
        }
        return CostBreakdown(lines: lines, total: lines.reduce(0) { $0 + $1.dollars }, model: cost.model,
                             rateSourceNote: cost.rateSourceNote, caveats: caveats)
    }

    // Fixed formatting, so the figures read the same on every Mac and a test can pin them.
    private static func number(_ value: Double, minFraction: Int, maxFraction: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.minimumFractionDigits = minFraction
        f.maximumFractionDigits = maxFraction
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// A line's cost as shown: a dash where the provider reported no tokens for it (not the same
    /// as a reported zero), so "not reported" never sits beside a "$0.00" that reads as a measurement.
    static func cost(of line: Line) -> String { line.tokens == nil ? "\u{2014}" : money(line.dollars) }

    static func tokens(_ n: Int?) -> String { n.map { number(Double($0), minFraction: 0, maxFraction: 0) } ?? "not reported" }

    static func rate(_ perMTok: Double) -> String { "$" + number(perMTok, minFraction: 2, maxFraction: 4) + "/MTok" }

    /// Dollars to the precision a line needs: four decimals under a dollar, so a cache read worth
    /// a hundredth of a cent still shows; a zero is "$0.00".
    static func money(_ d: Double) -> String {
        if d <= 0 { return "$0.00" }
        if d < 0.0001 { return "<$0.0001" }
        return "$" + (d < 1 ? number(d, minFraction: 4, maxFraction: 4) : number(d, minFraction: 2, maxFraction: 2))
    }
}

extension AppState {
    /// The toolbar's cost for `conversationId`, at the model its tier runs on now.
    func conversationCost(for conversationId: UUID, config: ConfigManager = .shared) -> ConversationCost? {
        guard let conv = conversations.first(where: { $0.id == conversationId }), conv.tokenUsage.totalTokenCount > 0 else { return nil }
        let model = config.getModel(for: effectiveTier(for: conversationId).tier)
        return ConversationCost.estimate(usage: conv.tokenUsage, provider: config.primaryProvider, model: model, book: priceBook)
    }
}
