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
                                    // dev-2 review: the app's one transcript sheet lives on the
                                    // main window (`ActivityStripView`'s own `.sheet`, always
                                    // mounted there); a second `.sheet` here bound to the same
                                    // `transcriptSheetConversationId` would try to present in both
                                    // windows at once. `openTranscript` is the established opener
                                    // (Run Log uses it too): it raises the main window first, then
                                    // sets the id, so the one sheet has somewhere to appear.
                                    ActivityRowView(state: state, sessionId: run.id, isMain: false) {
                                        state.openTranscript(run.id)
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
    }
}
