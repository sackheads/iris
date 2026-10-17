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
        private(set) var text: String
        /// The reply split for the row (#541 fix D): completed blocks, which change only at a cut,
        /// and the live tail, which changes per token. See `StreamingBlocks`.
        private(set) var blocks: [String] = []
        private(set) var tail = ""
        @ObservationIgnored private var splitter = StreamingBlocks()

        init(conversationId: UUID, text: String) {
            self.conversationId = conversationId
            self.text = text
            split(text)
        }

        func update(_ text: String) {
            self.text = text
            split(text)
        }

        private func split(_ text: String) {
            let newTail = splitter.update(text)
            // Assigned only when they changed: a write to `blocks` re-renders the block list.
            if splitter.blocks.count != blocks.count { blocks = splitter.blocks }
            tail = newTail
        }
    }

    private(set) var boxes: [UUID: Box] = [:]
    /// The last sequence applied per streaming message, and the messages whose final write has
    /// landed (#583 review): a partial is dropped when it is not newer than what is shown, or
    /// arrives after the final, which would otherwise recreate the box and leave the stale text to
    /// be committed over the final one. The closed set keeps the most recent ids only; a partial
    /// that late, behind hundreds of later replies, does not happen.
    @ObservationIgnored private var lastSequence: [UUID: Int] = [:]
    @ObservationIgnored private var closedOrder: [UUID] = []
    @ObservationIgnored private var closed: Set<UUID> = []
    static let closedMemory = 512

    /// Whether a partial update numbered `sequence` should be shown. `nil` (a caller with no
    /// numbering) is shown unless the message is closed.
    func accepts(_ messageId: UUID, sequence: Int?) -> Bool {
        if closed.contains(messageId) { return false }
        guard let sequence else { return true }
        if let last = lastSequence[messageId], sequence <= last { return false }
        lastSequence[messageId] = sequence
        return true
    }

    /// The message's final write has landed: its box goes, and nothing after this is shown.
    func close(_ messageId: UUID) {
        remove(messageId)
        lastSequence[messageId] = nil
        guard closed.insert(messageId).inserted else { return }
        closedOrder.append(messageId)
        if closedOrder.count > Self.closedMemory { closed.remove(closedOrder.removeFirst()) }
    }

    /// The message's text so far: its box created on the first update, and only its `text`
    /// written after that.
    func set(_ messageId: UUID, in conversationId: UUID, text: String) {
        if let box = boxes[messageId] {
            box.update(text)
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
