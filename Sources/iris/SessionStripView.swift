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

    /// Rough single-row height at `.caption` sizing; six of these bounds the expanded strip so it
    /// scrolls instead of growing without limit (invariant 8's spirit — nothing unbounded in the
    /// composer stack).
    private static let rowHeight: CGFloat = 22
    /// Rows shown before the list scrolls (invariant 8: nothing unbounded in the composer stack).
    private static let maxVisibleRows = 6

    private func expandedRows(_ sessions: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sessions) { session in
                SessionRowView(state: state, sessionId: session.id, isMain: session.kind == .main) {
                    state.transcriptSheetConversationId = session.id
                }
            }
        }
    }

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
        let isHidden = otherSessions.isEmpty && (mainSession?.phase ?? .idle) == .idle
            && state.transcriptSheetConversationId == nil
        // Expanded whenever there's anything besides the main row to show, unless the user has
        // manually collapsed it (and it hasn't emptied out since). With no other sessions,
        // "expanded" vs. "collapsed" is moot — there's only ever the one main line either way.
        let showExpanded = !otherSessions.isEmpty && isExpanded

        return Group {
            if !isHidden {
                VStack(alignment: .leading, spacing: 2) {
                    if showExpanded {
                        // A ScrollView is greedy — it takes its whole height cap even for two rows,
                        // leaving a block of empty space under the composer — so the rows only go
                        // inside one once there are more of them than the cap shows.
                        if sessions.count > Self.maxVisibleRows {
                            ScrollView {
                                expandedRows(sessions)
                            }
                            .frame(maxHeight: Self.rowHeight * CGFloat(Self.maxVisibleRows))
                        } else {
                            expandedRows(sessions)
                        }
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
        // The one transcript sheet in the app, with two openers: a row of this strip, and an
        // event card's "View run" (#187). Its presentation state lives on `AppState`
        // (`transcriptSheetConversationId`) rather than in a `@State` here precisely because of
        // the second opener — a card is a row in a lazy list, so a `.sheet` attached to it would
        // be torn down the moment it scrolled out of view. This `Group` is always mounted.
        .sheet(isPresented: Binding(
            get: { state.transcriptSheetConversationId != nil },
            set: { presented in if !presented { state.transcriptSheetConversationId = nil } }
        )) {
            if let id = state.transcriptSheetConversationId {
                // macOS 15+ can track the content's ideal size after presentation; earlier systems
                // keep the first layout's size, which `TranscriptSizing`'s estimate covers.
                if #available(macOS 15, *) {
                    TranscriptSheet(state: state, sessionId: id)
                        .id(id)  // fresh @State (measured height) per session, not carried over
                        .presentationSizing(.fitted)
                } else {
                    TranscriptSheet(state: state, sessionId: id)
                        .id(id)
                }
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

/// #19's "dedicated way to browse subagent logs": a read-only transcript for one conversation.
/// Never shown for the main row (`SessionStripView` never sets `transcriptSheetConversationId`
/// for it).
///
/// Internal rather than file-private since #187: an event card's "View run" opens this same
/// sheet for a background job run's transcript, so the name no longer says "Subagent".
struct TranscriptSheet: View {
    var state: AppState
    let sessionId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 0
    @State private var scrollPassScheduled = false

    private static let idealWidth: CGFloat = 560

    private var conversation: Conversation? { state.conversations.first { $0.id == sessionId } }
    private var role: String {
        state.sessions.first { $0.id == sessionId }?.role ?? conversation?.title ?? "Session"
    }
    /// The window is sized from this on the first layout pass, before `onGeometryChange` has
    /// reported, so until a measurement exists it comes from `TranscriptSizing`'s text estimate.
    /// On macOS 15+ `.presentationSizing(.fitted)` lets the measured value take over afterwards.
    private var sheetHeight: CGFloat {
        let content: CGFloat
        if contentHeight > 0 {
            content = contentHeight
        } else {
            let rows = (conversation?.messages ?? []).map { (role: $0.role, content: $0.content) }
            content = TranscriptSizing.estimatedContentHeight(messages: rows, width: Self.idealWidth)
        }
        return TranscriptSizing.sheetHeight(forContent: content)
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
                        // A plain VStack, not lazy: the `onGeometryChange` below has to cover the
                        // whole transcript, and a subagent log is short enough to lay out eagerly.
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(conversation.messages) { message in
                                MessageView(message: message, state: state)
                            }
                            // Scroll target for `scrollToBottom`, matching `ChatView`'s own
                            // "bottomAnchor" pattern rather than scrolling to a message id directly.
                            Color.clear.frame(height: 1).id("transcriptBottom")
                        }
                        .padding()
                        // Measured after the first layout; the window can only act on it where
                        // `presentationSizing(.fitted)` is available (see the sheet call site).
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
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
        .frame(minWidth: 480, idealWidth: Self.idealWidth,
               minHeight: TranscriptSizing.minSheetHeight, idealHeight: sheetHeight,
               maxHeight: TranscriptSizing.maxSheetHeight)
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
            return "\(message.exportRoleName):\n\(message.exportText)"
        }.joined(separator: "\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
