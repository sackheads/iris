import SwiftUI

/// One `ChatRole.event` message, drawn as a single line (#187 spec §8.2): a job run's outcome is
/// a notification, not a conversation turn, so it gets a status dot and one row of text rather
/// than a labelled "Iris" bubble.
///
/// A built-in job's card, or any outcome of more than one line, is the first exception: its outcome
/// is drawn as a body under the row (`EventCard.outcomeIsBody`), since the digest's failure and
/// paused lines come after its first line and a one-line row would hide them.
///
/// A run that stopped on a call it was not allowed to make is the other exception, and grows a second
/// half (§6): the whole call — tool, every argument, a preview of a long body — with Vibecop's
/// opinion of it and the two things a person can do about it. An approval given without sight of
/// the payload is worse than no button.
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
    /// Dispatches the blocked call as its own run. `nil` whenever the card offers no approval —
    /// there is no blocked call, or it is one no click can authorise (`approvalRefusal` says why).
    var onApprove: (() -> Void)?
    /// Marks the run seen. `nil` for a card with nothing outstanding.
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.isReflection {
                reflection
            } else {
                jobRun
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

    /// A memory reflection that ran in another conversation (5b §0.6): which one, and what it
    /// changed. No job buttons — there is no run to open, approve or acknowledge.
    @ViewBuilder
    private var reflection: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .center)
            Text("Memory reflection")
                .font(.system(.caption, design: .monospaced))
            Text(card.sourceTitle ?? card.jobName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
        Text(card.outcome ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(12)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
    }

    @ViewBuilder
    private var jobRun: some View {
        summary
        if card.outcomeIsBody {
            Text(card.outcome ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(EventCard.outcomeBodyLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
        }
        // What the catch-up dropped, on the first run of a replay burst (#187 §5). Its own
        // line rather than part of the summary: it is news about the schedule, and putting it
        // beside the outcome would push the thing the run actually did off the end.
        if let catchUpNote = card.catchUpNote, !catchUpNote.isEmpty {
            Text(catchUpNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 18)
        }
        if card.blockedCall != nil { blockedCallDetail }
    }

    private var summary: some View {
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
            // A body outcome is drawn below, so the row keeps the status word instead.
            Text(card.outcomeIsBody ? card.statusDetail
                 : card.outcome.flatMap { $0.isEmpty ? nil : $0 } ?? card.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(card.metadataLine)
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
    }

    /// The call the run stopped on, in full: what it would run, then what to do about it.
    @ViewBuilder
    private var blockedCallDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.blockedCall?.toolName ?? "")
                .font(.system(.caption, design: .monospaced).bold())
            ForEach(card.blockedArguments) { argument in
                HStack(alignment: .top, spacing: 6) {
                    Text(argument.key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Same guarantee the refusal below gets: an argument is the thing being
                    // approved, so it must lay out in full rather than be clipped to one line by
                    // the surrounding stack. `EventCard.preview` is what keeps "in full" bounded.
                    Text(argument.value)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let cwd = card.blockedCall?.cwd, !cwd.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(cwd)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let vibecopLine = card.vibecopLine {
                Text(vibecopLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let onApprove, card.offersApproval {
                    Button("Approve and run", action: onApprove)
                        .controlSize(.small)
                } else if let refusal = card.approvalRefusal {
                    // No button, and the reason in its place: a disabled button with no
                    // explanation is the same dead end with worse manners.
                    Text(refusal)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
