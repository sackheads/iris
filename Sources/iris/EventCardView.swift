import SwiftUI

/// One `ChatRole.event` message, drawn as a single line (#187 spec §8.2): a job run's outcome is
/// a notification, not a conversation turn, so it gets a status dot and one row of text rather
/// than a labelled "Iris" bubble.
///
/// Everything it renders comes from `EventCard`'s pure helpers, so the formatting is tested
/// without standing up a view (AGENTS.md: no SwiftUI unit tests).
struct EventCardView: View {
    let card: EventCard
    /// Opens the run's transcript. `nil` means there is nothing to open — either the run recorded
    /// no transcript conversation, or the one it recorded has since been pruned. `MessageView`
    /// tells those two apart; this view only has to distinguish "button" from "no button", and
    /// falls back to `transcriptConversationId` to decide whether to explain the absence.
    var onViewRun: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(statusColor)
                .frame(width: 10, alignment: .center)
            Text(card.jobName)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            // The outcome is the interesting half of the line; the status word only takes its
            // place when there is no outcome, since the dot already carries the status.
            Text(card.outcome.flatMap { $0.isEmpty ? nil : $0 } ?? card.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(card.elapsedText) · \(SessionActivity.formatTokenCount(card.totalTokens)) tokens")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let onViewRun {
                Button("View run", action: onViewRun)
                    .buttonStyle(.link)
                    .font(.caption)
            } else if card.transcriptConversationId != nil {
                // The run had a transcript and retention has since dropped it — say so, rather
                // than offering a button that would open an empty sheet.
                Text("transcript pruned")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // The dot's colour is the only place the status lives when an outcome crowds it out, and
        // colour alone is not an accessible signal — the tooltip and the label spell it out.
        .help(card.headline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.transcriptLine)
    }

    private var statusColor: Color {
        switch card.status {
        case .completed: return .green
        case .failed: return .red
        case .blockedOnApproval: return .orange
        case .interrupted, .running: return .gray
        }
    }
}
