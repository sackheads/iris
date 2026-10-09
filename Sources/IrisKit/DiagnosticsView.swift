import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject private var metrics = MetricsManager.shared
    @ObservedObject private var profiler = PerformanceProfiler.shared
    @State private var mode: Mode = .byCommand

    enum Mode: String, CaseIterable, Identifiable {
        case byCommand = "By Command"
        case aggregate = "Aggregate"
        var id: String { rawValue }
    }

    var body: some View {
        VStack {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            switch mode {
            case .byCommand: byCommand
            case .aggregate: aggregate
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - By Command

    private var byCommand: some View {
        Group {
            if profiler.recentCommands.isEmpty {
                Spacer()
                Text("No commands recorded yet. Run a command to see where its time goes.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    // Newest first.
                    ForEach(profiler.recentCommands.reversed()) { profile in
                        DisclosureGroup {
                            CommandBreakdownView(profile: profile)
                        } label: {
                            HStack {
                                Text(profile.label).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.0f ms", profile.totalMs))
                                    .foregroundColor(profile.totalMs > 5000 ? .orange : .secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                Text("Vibecop and Injection guard run inside Tool execution (shown indented). With parallel tool calls their sub-totals can exceed the tool-phase time.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding([.horizontal, .bottom])
            }
        }
    }

    // MARK: - Aggregate (unchanged from prior behavior)

    private var aggregate: some View {
        Table(metrics.aggregatedMetrics) {
            TableColumn("Operation") { Text($0.operation.rawValue) }
            TableColumn("Model") { Text($0.modelName) }
            TableColumn("Count") { Text("\($0.count)") }
            TableColumn("Min") { Text(String(format: "%.0f ms", $0.minMs)) }
            TableColumn("Avg") { Text(String(format: "%.0f ms", $0.avgMs)) }
            TableColumn("Max") { metric in
                Text(String(format: "%.0f ms", metric.maxMs))
                    .foregroundColor(metric.maxMs > 5000 ? .orange : .primary)
            }
            TableColumn("StdDev") { Text(String(format: "%.0f ms", $0.stddevMs)) }
        }
    }
}

/// Category rows for one command, with guard layers indented under tool execution.
private struct CommandBreakdownView: View {
    let profile: CommandProfile

    // Top-level order; guards are rendered indented under toolExecution.
    private let topLevel: [PerfCategory] = [.primaryLLM, .toolExecution, .hooks, .contextAssembly]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(topLevel, id: \.self) { cat in
                if let stat = profile.categories[cat] {
                    row(name: cat.displayName, ms: stat.ms, count: stat.count, indent: 0)
                    if cat == .toolExecution {
                        ForEach([PerfCategory.vibecop, .injectionGuard], id: \.self) { g in
                            if let gstat = profile.categories[g] {
                                row(name: g.displayName, ms: gstat.ms, count: gstat.count, indent: 1)
                            }
                        }
                    }
                }
            }
            row(name: "Other/overhead", ms: profile.derivedOtherMs, count: 0, indent: 0)
        }
        .padding(.vertical, 4)
    }

    private func row(name: String, ms: Double, count: Int, indent: Int) -> some View {
        let fraction = profile.totalMs > 0 ? min(1.0, ms / profile.totalMs) : 0
        return HStack(spacing: 8) {
            Text(name)
                .padding(.leading, CGFloat(indent) * 16)
                .frame(width: 180, alignment: .leading)
                .foregroundColor(indent > 0 ? .secondary : .primary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Rectangle().fill(indent > 0 ? Color.orange.opacity(0.5) : Color.accentColor.opacity(0.6))
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
                .cornerRadius(3)
            }
            .frame(height: 12)
            Text(String(format: "%.0f ms", ms))
                .frame(width: 70, alignment: .trailing)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .font(.caption)
    }
}
