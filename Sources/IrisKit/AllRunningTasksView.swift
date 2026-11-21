import SwiftUI

/// #988: every run in `stripRuns`, across every session, grouped by owner — the "firehose" view,
/// reachable only from the Window menu (not the toolbar), for when the person actually wants it.
/// Reuses `ActivityRowView`'s rendering; the difference from `ActivityStripView` is scope (every
/// run, grouped) rather than focused-session-only.
struct AllRunningTasksView: View {
    var state: AppState

    private func title(for owner: UUID) -> String? {
        state.conversations.first { $0.id == owner }?.title
    }

    var body: some View {
        let groups = RunGroup.groupedByOwner(state.stripRuns, titleForOwner: title(for:))
        Group {
            if groups.isEmpty {
                VStack {
                    Spacer()
                    Text("No runs across any session.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title)
                                    .font(.headline)
                                ForEach(group.runs) { run in
                                    ActivityRowView(state: state, sessionId: run.id, isMain: false) {
                                        state.transcriptSheetConversationId = run.id
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        // Same sheet `ActivityStripView` opens a row's transcript with (#19/#187): one
        // presentation, two openers.
        .sheet(isPresented: Binding(
            get: { state.transcriptSheetConversationId != nil },
            set: { presented in if !presented { state.transcriptSheetConversationId = nil } }
        )) {
            if let id = state.transcriptSheetConversationId {
                if #available(macOS 15, *) {
                    TranscriptSheet(state: state, sessionId: id)
                        .id(id)
                        .presentationSizing(.fitted)
                } else {
                    TranscriptSheet(state: state, sessionId: id)
                        .id(id)
                }
            }
        }
    }
}
