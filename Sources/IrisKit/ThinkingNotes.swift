import Foundation

/// The thinking text the API returns while a reply is being produced (#314 PR 7), per
/// conversation, for the status line under "Iris is thinking...". Transient: never persisted and
/// never part of a message (the full text is already in `Content.anthropicBlocks`), and never
/// synthesized, so a model that returns none (display "omitted", or a provider with no thinking
/// text) leaves the line empty.
///
/// Like `StreamingTexts`, each conversation's text sits in its own `@Observable` note and the
/// dictionary is not observed, so only the one line that reads a note re-renders per update; the
/// chat window's root never reads it.
@MainActor
@Observable
final class ThinkingNotes {
    @MainActor
    @Observable
    final class Note {
        var text = ""
        /// Longer buffer for the floating thought-bubble overlay (#1100), preserving newlines.
        var bubbleText = ""
        /// True once the model starts emitting `.textDelta` for the current round, so an
        /// auto-shown thought bubble can fade out and uncover the streaming reply (#1100).
        var isStreamingReply = false
        /// Pointer is over the inline `ThinkingNoteLine` on the "Iris is thinking..." row.
        var isHoveringLine = false
        /// Pointer is inside the floating `ThinkingBubbleOverlay` card or its trailing dots.
        var isHoveringBubble = false
        /// User clicked dismiss (`×`) on an auto-shown bubble during the current model round.
        var isDismissedForRound = false

        /// Stabilized single-line preview for the inline "Iris is thinking..." row (#1100):
        /// shows the current non-empty line/sentence from the left edge (for `.truncationMode(.tail)`)
        /// instead of head-truncating a sliding character window on every token.
        var headline: String {
            ThinkingNotes.extractHeadline(from: bubbleText.isEmpty ? text : bubbleText)
        }

        func shouldShowBubble(isThinking: Bool, autoShow: Bool, composerHasText: Bool) -> Bool {
            ThinkingBubbleVisibility.shouldShow(
                isThinking: isThinking,
                bubbleText: bubbleText.isEmpty ? text : bubbleText,
                isStreamingReply: isStreamingReply,
                isHoveringLine: isHoveringLine,
                isHoveringBubble: isHoveringBubble,
                autoShow: autoShow,
                composerHasText: composerHasText,
                isDismissedForTurn: isDismissedForRound
            )
        }
    }

    /// Only the tail is kept for `Note.text`: the line shows what the model is on now, not the whole transcript.
    nonisolated static let tailLimit = 240
    /// Tail kept for the floating thought-bubble overlay (#1100).
    nonisolated static let bubbleLimit = 4000
    /// Soft length cap before `extractHeadline` advances to the latest sentence on a long line.
    nonisolated static let headlineClauseLimit = 110

    @ObservationIgnored private var notes: [UUID: Note] = [:]

    func note(for conversationId: UUID) -> Note {
        if let existing = notes[conversationId] { return existing }
        let created = Note()
        notes[conversationId] = created
        return created
    }

    /// Appends `fragment` and keeps the last `tailLimit` / `bubbleLimit` characters.
    func append(_ fragment: String, to conversationId: UUID) {
        let note = note(for: conversationId)
        note.text = String((note.text + fragment).suffix(Self.tailLimit))
        note.bubbleText = String((note.bubbleText + fragment).suffix(Self.bubbleLimit))
    }

    /// Marks that the model has started streaming visible reply tokens for this round (#1100).
    func markReplyStreaming(_ conversationId: UUID) {
        notes[conversationId]?.isStreamingReply = true
    }

    func clear(_ conversationId: UUID) {
        guard let note = notes[conversationId] else { return }
        note.text = ""
        note.bubbleText = ""
        note.isStreamingReply = false
        note.isHoveringLine = false
        note.isHoveringBubble = false
        note.isDismissedForRound = false
    }

    /// Extracts a left-anchored single line from `raw` so the inline status row grows left-to-right
    /// per sentence/line instead of sliding horizontally on every token (#1100).
    nonisolated static func extractHeadline(from raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { cleanMarkdownLine($0) }
            .filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return "" }
        guard lastLine.count > headlineClauseLimit else { return lastLine }
        // Advance to the latest sentence on a long single-paragraph thought so the left edge stays
        // stationary while that sentence streams, rather than overflowing off the right forever.
        let sentences = splitSentences(lastLine)
        return sentences.last ?? lastLine
    }

    private nonisolated static func cleanMarkdownLine(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, first == "#" || first == "*" || first == "-" || first == ">" {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        s = s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func splitSentences(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var chars = line.makeIterator()
        while let ch = chars.next() {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty {
            result.append(remainder)
        }
        return result
    }
}

/// Pure visibility rules for `ThinkingBubbleOverlay` (#1100), separated from SwiftUI state so tests
/// can pin hover, auto-show, reply-streaming fade, composer-typing fade, and per-turn dismissal.
enum ThinkingBubbleVisibility {
    static func shouldShow(
        isThinking: Bool,
        bubbleText: String,
        isStreamingReply: Bool,
        isHoveringLine: Bool,
        isHoveringBubble: Bool,
        autoShow: Bool,
        composerHasText: Bool,
        isDismissedForTurn: Bool
    ) -> Bool {
        guard isThinking, !bubbleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if isHoveringLine || isHoveringBubble {
            return true
        }
        guard autoShow, !isDismissedForTurn, !isStreamingReply, !composerHasText else {
            return false
        }
        return true
    }
}
