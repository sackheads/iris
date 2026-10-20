import AppKit
import SwiftUI

/// Opens the Run Log scene from a surface with no SwiftUI environment of its own, through the
/// best-ranked `openWindow` action handed to `MainWindow` (D6 decision 15).
/// `Window` is single-instance, so opening it again brings the open one forward.
@MainActor
enum RunLogWindow {
    static let sceneId = "run-log"

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.open(scene: sceneId)
    }
}

/// The Run Log window (D6 decision 15): every ledger row, newest first, with the transcript one
/// click away. Acknowledge is offered where a run still waits on someone. Approve is never
/// offered: the call and its verdict live on the card, which a blocked row links to.
///
/// It never carries `MainWindowTracker`: only the chat window is tracked, so a raise or the
/// hotkey never mistakes this window for the chat.
struct RunLogView: View {
    let state: AppState
    @State private var model: RunLogModel

    /// Acknowledge, Show card and Transcript side by side at the small control size.
    static let actionsWidth: CGFloat = 280
    /// The window's first-open size: every column at its ideal width (1240 measured on #481).
    static let defaultWidth: CGFloat = 1240
    static let defaultHeight: CGFloat = 480


    init(state: AppState) {
        self.state = state
        _model = State(initialValue: RunLogModel(ledger: state.store.ledger,
                                                 transcriptExists: { [weak state] in
                                                     state?.transcriptExists($0) ?? false
                                                 }))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Table(model.rows) {
                TableColumn("Started") { row in
                    Text(row.started, format: .dateTime.month().day().hour().minute().second())
                }
                .width(min: 90, ideal: 130)
                TableColumn("Duration") { row in Text(verbatim: Self.durationText(row.duration)) }
                    .width(min: 45, ideal: 80)
                TableColumn("Job") { row in Text(verbatim: row.jobName) }
                    .width(min: 60, ideal: 120)
                TableColumn("Trigger") { row in Text(verbatim: row.triggerKind) }
                    .width(min: 45, ideal: 70)
                TableColumn("Status") { row in Text(verbatim: row.statusText) }
                    .width(min: 60, ideal: 120)
                TableColumn("Tokens") { row in Text(verbatim: "\(row.weightedTokens)") }
                    .width(min: 40, ideal: 60)
                // Ahead of Outcome and wide enough for all three actions on one line, so they stay
                // visible at the minimum width (the GUI passes on #481 saw them wrap, then clip).
                TableColumn("") { row in actions(row) }
                    .width(min: Self.actionsWidth, ideal: Self.actionsWidth)
                // Last and flexible: it takes the squeeze, truncating with the full text on hover.
                TableColumn("Outcome") { row in
                    Text(verbatim: row.outcome ?? "").lineLimit(1).truncationMode(.tail)
                        .help(row.outcome ?? "")
                }
                .width(min: 100, ideal: 220)
            }
            if model.hasMore {
                Button("Load more") { model.loadMore() }.padding(8)
            }
        }
        .frame(minWidth: 860, minHeight: 360)
        // The filters reload themselves (`RunLogModel`'s didSets); these are decision 15's
        // refreshes plus plan note 15's: a completed run moves neither the snapshot nor anything
        // else, so the running count is watched too.
        // A refresh keeps the depth "Load more" reached; a filter change starts at one page.
        .onAppear { model.reload(keepingDepth: true) }
        .onChange(of: state.ledgerAttention) { _, _ in model.reload(keepingDepth: true) }
        .onChange(of: state.runningJobs.count) { _, _ in model.reload(keepingDepth: true) }
        // A run's +1 above lands before its row is written; this moves once the row exists.
        .onChange(of: state.runLogRevision) { _, _ in model.reload(keepingDepth: true) }
    }

    private var controls: some View {
        HStack {
            Picker("Job", selection: $model.jobFilter) {
                Text("All jobs").tag(UUID?.none)
                ForEach(model.jobChoices) { job in Text(verbatim: job.name).tag(UUID?.some(job.id)) }
            }
            .frame(maxWidth: 240)
            Picker("Status", selection: $model.statusFilter) {
                Text("Any status").tag(JobLedger.RunLogStatus?.none)
                ForEach(JobLedger.RunLogStatus.allCases, id: \.self) { status in
                    Text(verbatim: status.text).tag(JobLedger.RunLogStatus?.some(status))
                }
            }
            .frame(maxWidth: 220)
            Toggle("Show gate checks", isOn: $model.showGateChecks)
            Spacer()
            Button("Refresh") { model.reload(keepingDepth: true) }
        }
        .padding(8)
    }

    @ViewBuilder
    private func actions(_ row: RunLogRow) -> some View {
        HStack(spacing: 6) {
            actionButtons(row)
        }
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func actionButtons(_ row: RunLogRow) -> some View {
        if row.canAcknowledge {
            // Reloads itself once the write lands, rather than trusting the snapshot to move.
            Button("Acknowledge") {
                let ack = state.acknowledgeRun(row.id)
                Task { await ack.value; model.reload(keepingDepth: true) }
            }
        }
        if row.opensCard {
            Button("Show card") { Task { await state.revealCard(runId: row.id, jobId: row.jobId) } }
        }
        switch row.transcript {
        case .live(let id): Button("Transcript") { state.openTranscript(id) }
        case .pruned: Text("transcript pruned").foregroundStyle(.secondary)
        case RunLogRow.Transcript.none: EmptyView()
        }
    }

    private static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "running" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        return "\(Int(seconds / 60)) min \(Int(seconds) % 60) s"
    }
}
