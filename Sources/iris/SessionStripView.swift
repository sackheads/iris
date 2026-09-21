import SwiftUI

/// #217 (compact per-session activity strip) + #19 (browse subagent/evaluator transcripts without
/// sidebar clutter): one line per session — the main conversation plus any subagent/evaluator
/// conversations currently running or recently finished — placed directly below the composer.
/// Replaces `SubagentPopoverView`; the toolbar "cpu" badge toggles `isExpanded` in place of
/// opening a popover.
///
/// Fix round 1 (#217/#19): expansion is no longer purely manual. Whenever a subagent/evaluator
/// session exists, the strip defaults to expanded — the badge count used to be the ONLY visible
/// sign of background work while collapsed, which is exactly the clutter-vs-visibility gap #19
/// asked to close. `isExpanded` now means "the user has not manually collapsed it *this time*":
/// collapsing is remembered only while at least one non-main session exists, and resets back to
/// expanded once the strip has nothing but the main row left (`onChange` below).
struct SessionStripView: View {
    var state: AppState
    @Binding var isExpanded: Bool
    @State private var transcriptSessionId: UUID?

    /// Rough single-row height at `.caption` sizing; six of these bounds the expanded strip so it
    /// scrolls instead of growing without limit (invariant 8's spirit — nothing unbounded in the
    /// composer stack).
    private static let rowHeight: CGFloat = 22

    var body: some View {
        // Fix round 1, item 8: `state.visibleSessions` rebuilds the synthesised main row (a couple
        // of dictionary lookups plus an array filter) on every access; read it once per body
        // evaluation rather than through several computed properties that each called it again.
        let sessions = state.visibleSessions
        let mainSession = sessions.first { $0.kind == .main }
        let otherSessions = sessions.filter { $0.kind != .main }
        // Hidden entirely when there is nothing to show — the common case — so the strip doesn't
        // permanently occupy space below the composer. Fix round 1, item 7: NOT hidden while a
        // transcript sheet is open, even if the row that opened it just swept away — hiding the
        // strip unmounts this view and, with the `.sheet` modifier on it, yanks the open sheet
        // out from under the user.
        let isHidden = otherSessions.isEmpty && (mainSession?.phase ?? .idle) == .idle && transcriptSessionId == nil
        // Expanded whenever there's anything besides the main row to show, unless the user has
        // manually collapsed it (and it hasn't emptied out since). With no other sessions,
        // "expanded" vs. "collapsed" is moot — there's only ever the one main line either way.
        let showExpanded = !otherSessions.isEmpty && isExpanded

        return Group {
            if !isHidden {
                VStack(alignment: .leading, spacing: 2) {
                    if showExpanded {
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
                    } else if !otherSessions.isEmpty, let main = mainSession {
                        // Manually collapsed with background work still going: summarize rather
                        // than hide (`● main · idle · 2 subagents running`), so the badge isn't
                        // the only tell.
                        CollapsedSummaryRow(state: state, mainId: main.id)
                    } else if let main = mainSession {
                        SessionRowView(state: state, sessionId: main.id, isMain: true, onTap: {})
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Fix round 1, item 7: hoisted above the `isHidden` conditional (onto the `Group`, which
        // always exists) so the sheet's own presentation state survives the strip's content being
        // momentarily absent.
        .onChange(of: otherSessions.isEmpty) { _, empty in
            // The strip emptied out (nothing left but main): drop any manual collapse so the
            // NEXT subagent/evaluator run starts expanded again, per the ruling above.
            if empty { isExpanded = true }
        }
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

/// The collapsed-but-not-empty main line: `● main · <activity> · 2 subagents running` (or
/// `1 finished`, or both). Reads `state` live like `SessionRowView`, not a captured value.
private struct CollapsedSummaryRow: View {
    var state: AppState
    let mainId: UUID

    var body: some View {
        if let main = state.visibleSessions.first(where: { $0.id == mainId }) {
            let summary = SessionActivity.collapsedSummary(for: state.sessions)
            HStack(spacing: 8) {
                statusGlyph(main.phase)
                    .frame(width: 10, alignment: .center)
                Text(main.role)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Text(SessionActivity.activityText(for: main.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !summary.isEmpty {
                    Text("· \(summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 1)
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
                Text(SessionActivity.activityText(for: session.phase))
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

    /// `nil` (via `elapsedStartTime`) while the session is `.idle` — omit the elapsed time
    /// entirely rather than render one against a stale/placeholder start (fix round 1: this used
    /// to render as a multi-million-hour countdown for an idle main row).
    @ViewBuilder
    private func elapsedView(_ session: SessionSummary) -> some View {
        if let start = session.elapsedStartTime {
            if case .finished(_, let at) = session.phase {
                // A fixed duration for a row that finished in the past.
                Text(SessionActivity.formatElapsed(at.timeIntervalSince(start)))
            } else {
                // Fix round 1: `Text(timerInterval:)` was dropped entirely, not just given
                // `countsDown: false` — it renders `h:mm:ss`, a different style than
                // `SessionActivity.formatElapsed`'s `12s`/`1m 05s`/`1h 02m` used for a finished
                // row, so the two would have shown side by side in different formats.
                // `TimelineView` ticks this once a second through the SAME pure formatter.
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(SessionActivity.formatElapsed(context.date.timeIntervalSince(start)))
                }
            }
        }
    }
}

/// Shared by `SessionRowView` and `CollapsedSummaryRow` — a tiny status dot/spinner, not worth
/// making pure/testable (it's pure presentation, no logic).
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

/// Reports the transcript content's natural height up to `SubagentTranscriptSheet`, so the sheet
/// can size itself to content instead of always opening at a fixed height that leaves a lot of
/// empty gray space under a short transcript (fix round 1 follow-up).
private struct TranscriptContentHeightKey: PreferenceKey {
    // A computed property, not stored: Swift 6 strict concurrency flags a stored `static var` as
    // non-concurrency-safe mutable global state even though `PreferenceKey` only ever reads it.
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// #19's "dedicated way to browse subagent logs": a read-only transcript for one subagent/
/// evaluator conversation. Never shown for the main row (`SessionStripView` never sets
/// `transcriptSessionId` for it).
private struct SubagentTranscriptSheet: View {
    var state: AppState
    let sessionId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 0
    @State private var scrollPassScheduled = false

    /// A rough header-row + divider allowance added to the measured content height. Precision
    /// doesn't matter here — it only widens or narrows the sheet by a few points — so this stays a
    /// constant rather than a second measured value.
    private static let chromeHeight: CGFloat = 60
    private static let minSheetHeight: CGFloat = 160
    private static let maxSheetHeight: CGFloat = 640

    private var conversation: Conversation? { state.conversations.first { $0.id == sessionId } }
    private var role: String {
        state.sessions.first { $0.id == sessionId }?.role ?? conversation?.title ?? "Session"
    }
    private var sheetHeight: CGFloat {
        min(max(contentHeight + Self.chromeHeight, Self.minSheetHeight), Self.maxSheetHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the scroll area (a sibling of it, not inside it) — never scrolls away.
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(conversation.messages) { message in
                                MessageView(message: message)
                            }
                            // Scroll target for `scrollToBottom`, matching `ChatView`'s own
                            // "bottomAnchor" pattern rather than scrolling to a message id directly.
                            Color.clear.frame(height: 1).id("transcriptBottom")
                        }
                        .padding()
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: TranscriptContentHeightKey.self, value: geo.size.height)
                            }
                        )
                    }
                    .onPreferenceChange(TranscriptContentHeightKey.self) { contentHeight = $0 }
                    .onAppear { scrollToBottom(proxy) }
                    // A live subagent's transcript should show the newest content, not the header,
                    // as more messages stream in while the sheet is open.
                    .onChange(of: conversation.messages.count) { _, _ in scrollToBottom(proxy) }
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
        .frame(minWidth: 480, idealWidth: 560,
               minHeight: Self.minSheetHeight, idealHeight: sheetHeight, maxHeight: Self.maxSheetHeight)
    }

    /// Deferred a run loop turn (mirrors `ChatView.scrollAfterUpdate`) so the anchor is laid out
    /// under the just-appended message before the scroll fires; the in-flight guard collapses a
    /// burst of message-count changes (streamed deltas) into one pending scroll.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !scrollPassScheduled else { return }
        scrollPassScheduled = true
        DispatchQueue.main.async {
            proxy.scrollTo("transcriptBottom", anchor: .bottom)
            scrollPassScheduled = false
        }
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
