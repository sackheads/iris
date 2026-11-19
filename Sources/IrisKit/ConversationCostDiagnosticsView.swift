import SwiftUI

/// Diagnostics' Conversation mode (#1146): one conversation's estimated cost by model and by turn,
/// each at the rate stored when it was spent. Opened from the toolbar cost popover, which names the
/// conversation; with none named it shows the one selected in the main window.
struct ConversationCostDiagnosticsView: View {
    let state: AppState
    let conversationId: UUID?

    var body: some View {
        let id = conversationId ?? state.selectedConversationId
        if let id, let conv = state.conversations.first(where: { $0.id == id }),
           let cost = state.conversationCost(for: id) {
            report(ConversationCostReport.make(usage: conv.tokenUsage, cost: cost), title: conv.title)
        } else {
            VStack {
                Spacer()
                Text("No usage to show. Open a conversation's cost figure in the toolbar and choose \"Per-turn view in Diagnostics\".")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func report(_ report: ConversationCostReport, title: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(CostBreakdown.money(report.total)).font(.headline).monospacedDigit()
                }
                if !report.models.isEmpty {
                    Text("By model").font(.subheadline).bold()
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(report.models, id: \.model) { row in
                            GridRow {
                                Text(row.model).gridColumnAlignment(.leading)
                                Text("\(CostBreakdown.tokens(row.tokens)) tokens").monospacedDigit()
                                Text(CostBreakdown.money(row.dollars)).monospacedDigit()
                            }
                        }
                    }
                }
                if !report.turns.isEmpty {
                    Text("By turn").font(.subheadline).bold()
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("Turn").gridColumnAlignment(.leading)
                            Text("When").gridColumnAlignment(.leading)
                            Text("Model").gridColumnAlignment(.leading)
                            Text("Tokens")
                            Text("Cost")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(report.turns.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text("\(row.turn)").monospacedDigit()
                                Text(row.at.formatted(date: .abbreviated, time: .shortened))
                                Text(row.model)
                                Text(CostBreakdown.tokens(row.usage.totalTokenCount)).monospacedDigit()
                                Text(CostBreakdown.money(row.dollars)).monospacedDigit()
                            }
                        }
                    }
                }
                ForEach(report.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("An estimate, not a bill. Subagents' tokens sit in their own conversations and are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
