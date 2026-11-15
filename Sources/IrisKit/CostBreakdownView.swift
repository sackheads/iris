import SwiftUI

/// The popover behind the toolbar's cost figure (#1011): this conversation's estimated cost by
/// token type, with the rate's source and what the figure leaves out stated beside it, since the
/// person reading it is checking it against an invoice.
struct CostBreakdownView: View {
    let breakdown: CostBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Estimated cost").font(.headline)
            if breakdown.sections.isEmpty {
                lineGrid(lines: breakdown.lines, total: breakdown.total, totalLabel: "Total", bold: true)
                Text("\(breakdown.model) rates (\(breakdown.rateSourceNote)).")
                    .font(.caption)
            } else {
                ForEach(breakdown.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.subheadline).bold()
                        lineGrid(lines: section.lines, total: section.total, totalLabel: "Subtotal", bold: false)
                        Text("Rates: \(section.rateSourceNote).").font(.caption)
                        if let note = section.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Text("Total").bold()
                    Spacer()
                    Text(CostBreakdown.money(breakdown.total)).bold().monospacedDigit()
                }
            }
            ForEach(breakdown.caveats, id: \.self) { caveat in
                Text(caveat).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private func lineGrid(lines: [CostBreakdown.Line], total: Double, totalLabel: String, bold: Bool) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("Tokens"); Text("Rate"); Text("Cost")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(lines, id: \.kind) { line in
                GridRow {
                    Text(line.label).gridColumnAlignment(.leading)
                    Text(CostBreakdown.tokens(line.tokens)).monospacedDigit()
                    Text(CostBreakdown.rate(line.ratePerMTok)).monospacedDigit()
                    Text(CostBreakdown.cost(of: line)).monospacedDigit()
                }
                if let note = line.note {
                    GridRow { Text(note).font(.caption).foregroundStyle(.secondary).gridCellColumns(4).gridColumnAlignment(.leading) }
                }
            }
            Divider().gridCellColumns(4)
            GridRow {
                Text(totalLabel).bold(bold).gridColumnAlignment(.leading)
                Text(""); Text("")
                Text(CostBreakdown.money(total)).bold(bold).monospacedDigit()
            }
        }
    }
}
