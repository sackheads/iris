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

    var help: String {
        var text = "Estimated cost: this conversation's tokens at \(model)'s rates"
        switch rate.source {
        case .snapshot: text += " (price list of \(rate.asOf ?? "unknown date"))"
        case .loopback: text += " (a server on this Mac: no charge)"
        default: text += " (\(rate.source.rawValue))"
        }
        text += ". The whole conversation is priced at its current model, and subagents are not included."
        if rate.estimated { text += " No exact rate is known for this model: \(rate.note ?? "a fallback rate stands in")." }
        return text
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
