import Foundation

/// What the conversation-scoped Diagnostics view shows (#1146): the figure by model and by turn.
/// Built from the stored ledger and turn list, so every dollar is at the rate in force when it was
/// spent (#1057), and both lists add up to `total` (the toolbar's figure), with whatever a list
/// leaves out named in `notes`.
struct ConversationCostReport: Equatable {
    struct ModelRow: Equatable {
        var model: String
        var tokens: Int
        var dollars: Double
    }
    /// Per model, then what no model was recorded for. Empty for a conversation with no ledger.
    var models: [ModelRow]
    var turns: [CostByTurn.Row]
    var total: Double
    /// The part of `total` not on a listed turn: turns the cap dropped, and what no model was recorded for.
    var notShown: Double
    var notes: [String]

    static func make(usage: TokenUsage, cost: ConversationCost) -> ConversationCostReport {
        let breakdown = CostBreakdown.make(usage: usage, cost: cost)
        let models = breakdown.sections.map { section in
            ModelRow(model: section.title, tokens: section.lines.reduce(0) { $0 + ($1.tokens ?? 0) }, dollars: section.total)
        }
        let byTurn = CostByTurn.make(usage: usage, cost: cost)
        var notes: [String] = []
        if usage.byModel.isEmpty {
            notes.append("This conversation has no per-model record, so its whole figure is priced at \(cost.model)'s rates and no turn can be shown.")
        } else if byTurn.rows.isEmpty {
            notes.append("This usage was not recorded per turn, so no turn can be shown; the model rows above hold all of it.")
        } else if byTurn.notShown >= 0.00005 {
            notes.append("Not on a listed turn: \(CostBreakdown.money(byTurn.notShown)), from turns older than the last \(TokenUsage.maxTurns) and usage not attributed to a model. The model rows hold it.")
        }
        return ConversationCostReport(models: models, turns: byTurn.rows, total: cost.dollars, notShown: byTurn.notShown, notes: notes)
    }
}
