import Foundation
import Observation

/// The text of agent replies still streaming in (#541), one box per message, owned by `AppState`.
///
/// A streamed reply used to be written into `AppState.conversations` 20 times a second, and every
/// view that had read `conversations` — the whole chat window from its root, the sidebar, the
/// session strip — re-evaluated on each write: about 9% of a core at 40 messages and 21% at 200,
/// growing with the conversation (measured on #541). Now the in-flight text lives here, and only
/// the streaming row reads it, through `AppState.liveContent(of:)`; `conversations` gets the text
/// once, at the stream's final write (`updateMessageContent(persist: true)`), which also removes
/// the box. `boxes` changes only when a stream starts or ends, so a row reading it re-renders on
/// those, and on its own box's `text`, never on another message's tokens.
///
/// Transient, the same rule as `commandStartTimes` (invariant 5): never a field on a `Codable`
/// type, and never persisted except through the save's overlay (`AppState.takeBatch`), which
/// writes a streaming message's latest text so a crash mid-reply loses no more than it did.
@MainActor
@Observable
final class StreamingTexts {
    @MainActor
    @Observable
    final class Box {
        let conversationId: UUID
        var text: String
        init(conversationId: UUID, text: String) {
            self.conversationId = conversationId
            self.text = text
        }
    }

    private(set) var boxes: [UUID: Box] = [:]

    /// The message's text so far: its box created on the first update, and only its `text`
    /// written after that.
    func set(_ messageId: UUID, in conversationId: UUID, text: String) {
        if let box = boxes[messageId] {
            box.text = text
        } else {
            boxes[messageId] = Box(conversationId: conversationId, text: text)
        }
    }

    @discardableResult
    func remove(_ messageId: UUID) -> Box? { boxes.removeValue(forKey: messageId) }

    /// The boxes streaming into `conversationId`, by message id.
    func boxes(in conversationId: UUID) -> [(messageId: UUID, box: Box)] {
        boxes.filter { $0.value.conversationId == conversationId }.map { ($0.key, $0.value) }
    }
}
