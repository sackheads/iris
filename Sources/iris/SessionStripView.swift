import SwiftUI

/// #217 (compact per-session activity strip) + #19 (browse subagent/evaluator transcripts without
/// sidebar clutter): one line per session — the main conversation plus any subagent/evaluator
/// conversations currently running or recently finished — placed directly below the composer.
/// Replaces `SubagentPopoverView`; the toolbar "cpu" badge now toggles `isExpanded` in place of
/// opening a popover.
struct SessionStripView: View {
    var state: AppState
    @Binding var isExpanded: Bool
    @State private var transcriptSessionId: UUID?

    /// Rough single-row height at `.caption` sizing; six of these bounds the expanded strip so it
    /// scrolls instead of growing without limit (invariant 8's spirit — nothing unbounded in the
    /// composer stack).
    private static let rowHeight: CGFloat = 22

    private var sessions: [SessionSummary] { state.visibleSessions }
    private var mainSession: SessionSummary? { sessions.first { $0.kind == .main } }
    private var otherSessions: [SessionSummary] { sessions.filter { $0.kind != .main } }

    /// Hidden entirely when there is nothing to show — the common case — so the strip doesn't
    /// permanently occupy space below the composer.
    private var isHidden: Bool {
        otherSessions.isEmpty && (mainSession?.phase ?? .idle) == .idle
    }

    var body: some View {
        if !isHidden {
            VStack(alignment: .leading, spacing: 2) {
                if isExpanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(sessions) { session in
                                SessionRowView(state: state, sessionId: session.id, isMain: session.kind == .main) {
                                    transcriptSessionId = session.id
                                }
                            }
                        }
                    }
                    .frame(maxHeight: Self.rowHeight * 6)
                } else if let main = mainSession {
                    SessionRowView(state: state, sessionId: main.id, isMain: true, onTap: {})
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .sheet(isPresented: Binding(
                get: { transcriptSessionId != nil },
                set: { presented in if !presented { transcriptSessionId = nil } }
            )) {
                if let id = transcriptSessionId {
                    SubagentTranscriptSheet(state: state, sessionId: id)
                }
            }
        }
    }
}

/// One row. Takes `sessionId`, not a `SessionSummary` value, and reads the live summary + token
/// count from `state` inside `body` — the #223/#224 lesson (`Conversation ==` compares by id
/// only, so a struct value captured at construction time goes stale under SwiftUI's diffing).
private struct SessionRowView: View {
    var state: AppState
    let sessionId: UUID
    let isMain: Bool
    var onTap: () -> Void

    var body: some View {
        if let session = state.visibleSessions.first(where: { $0.id == sessionId }) {
            let tokens = state.conversations.first(where: { $0.id == sessionId })?.tokenUsage.totalTokenCount ?? 0
            HStack(spacing: 8) {
                statusGlyph(session.phase)
                    .frame(width: 10, alignment: .center)
                Text(session.role)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .frame(minWidth: 56, alignment: .leading)
                Text(activityText(session.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                elapsedView(session)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("· \(SessionActivity.formatTokenCount(tokens)) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture { if !isMain { onTap() } }
            .help(isMain ? "" : "Click to view this session's transcript")
        }
    }

    @ViewBuilder
    private func statusGlyph(_ phase: SessionSummary.Phase) -> some View {
        switch phase {
        case .executing:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        case .finished:
            Image(systemName: "circle")
                .font(.system(size: 6))
                .foregroundStyle(.secondary)
        case .idle, .thinking, .responding:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.green)
        }
    }

    private func activityText(_ phase: SessionSummary.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .responding: return "responding"
        case .executing(let tool, let detail):
            guard let detail, !detail.isEmpty else { return tool }
            return "\(tool) \(detail)"
        case .finished(let status, _): return "finished · \(status)"
        }
    }

    @ViewBuilder
    private func elapsedView(_ session: SessionSummary) -> some View {
        if case .finished(_, let at) = session.phase {
            // A fixed duration: `Text(timerInterval:)` keeps ticking, which would be wrong for a
            // row that finished in the past.
            Text(SessionActivity.formatElapsed(at.timeIntervalSince(session.startTime)))
        } else {
            Text(timerInterval: session.startTime...Date.distantFuture)
        }
    }
}

/// #19's "dedicated way to browse subagent logs": a read-only transcript for one subagent/
/// evaluator conversation. Never shown for the main row (`SessionStripView` never sets
/// `transcriptSessionId` for it).
private struct SubagentTranscriptSheet: View {
    var state: AppState
    let sessionId: UUID
    @Environment(\.dismiss) private var dismiss

    private var conversation: Conversation? { state.conversations.first { $0.id == sessionId } }
    private var role: String {
        state.sessions.first { $0.id == sessionId }?.role ?? conversation?.title ?? "Session"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(role)
                    .font(.headline)
                Spacer()
                Button("Copy Transcript") { copyTranscript() }
                    .disabled(conversation?.messages.isEmpty ?? true)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if let conversation, !conversation.messages.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(conversation.messages) { message in
                            MessageView(message: message)
                        }
                    }
                    .padding()
                }
            } else {
                Spacer()
                Text(conversation == nil
                     ? "This session's conversation is no longer available."
                     : "No messages yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 480)
    }

    private func copyTranscript() {
        guard let conversation else { return }
        let text = conversation.messages.map { message -> String in
            let roleName = message.role == .user ? "You" : (message.role == .system ? "System" : "Iris")
            return "\(roleName):\n\(message.content)"
        }.joined(separator: "\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
