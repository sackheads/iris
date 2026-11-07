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
    }

    /// Only the tail is kept: the line shows what the model is on now, not the whole transcript.
    static let tailLimit = 240

    @ObservationIgnored private var notes: [UUID: Note] = [:]

    func note(for conversationId: UUID) -> Note {
        if let existing = notes[conversationId] { return existing }
        let created = Note()
        notes[conversationId] = created
        return created
    }

    /// Appends `fragment` and keeps the last `tailLimit` characters.
    func append(_ fragment: String, to conversationId: UUID) {
        let note = note(for: conversationId)
        note.text = String((note.text + fragment).suffix(Self.tailLimit))
    }

    func clear(_ conversationId: UUID) {
        notes[conversationId]?.text = ""
    }
}
