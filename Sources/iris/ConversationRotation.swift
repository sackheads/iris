import Foundation

/// 5b §0.4: `/new` in Iris rotates it. The order is the design:
/// 1. refuse synchronously (`rotationRefusal`, in the `/new` handler);
/// 2. reflect in the old conversation, so durable learning reaches memory before it leaves context;
/// 3. create the new Iris and move the pin, before anything slow, because cards are routed
///    through `activityConversationId()` at each delivery;
/// 4. summarise the old conversation into the new one;
/// 5. archive the old one last, because any turn start un-archives (`runThinkingTask`).
/// The meta key never names an archived or missing conversation at any point in between.
extension AppState {
    /// "Iris — until 2026-10-01", in the local calendar day of `last`. Conversations carry no
    /// creation date, so only the end is known.
    static func archivedTitle(last: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return "\(activityConversationTitle) — until \(f.string(from: last))"
    }

    static let rotationSummaryLabel = "[Summary of the previous Iris conversation"

    /// Why `/new` will not rotate Iris now, as a complete sentence; nil means it may. Synchronous,
    /// so it runs before any task starts. `/archive`'s reasons, except `.pinned`, which is the
    /// point of rotating.
    func rotationRefusal() -> String? {
        if rotationTask != nil {
            return "Cannot start a new Iris: a rotation is already running."
        }
        switch archiveRefusal(for: activityConversationId()) {
        case nil, .pinned?: return nil
        case let refusal?: return "Cannot start a new Iris: \(refusal.reason)."
        }
    }

    /// The rotation itself. The caller has already refused synchronously and runs this under
    /// `runThinkingTask(conversationId: nil)`: as the old conversation's own task, it would make
    /// `archiveRefusal` see a turn in flight and refuse its own final archive.
    func rotatePinned(engine: IrisEngine) async {
        let oldId = activityConversationId()

        await engine.processInput(Self.reflectionPrompt, source: "System", conversationId: oldId)

        let newId = createNewConversation(title: Self.activityConversationTitle, select: true)
        if let o = conversations.firstIndex(where: { $0.id == oldId }) {
            conversations[o].isPinned = false
            markChanged(oldId, .metadata)
        }
        if let n = conversations.firstIndex(where: { $0.id == newId }) {
            conversations[n].isPinned = true
            markChanged(newId, .metadata)
        }
        try? store.setMetaValue(newId.uuidString, forKey: Self.activityConversationMetaKey)

        let oldMessages = conversations.first { $0.id == oldId }?.messages ?? []
        let summary = await engine.summarizeForRotation(messages: oldMessages)

        let title = Self.archivedTitle(last: rotationNow())
        if let o = conversations.firstIndex(where: { $0.id == oldId }) {
            conversations[o].title = title
            markChanged(oldId, .metadata)
        }
        // A peer can start a turn in the old conversation while the summary runs; archiving it
        // then is refused. Say so rather than leave a silent half-rotation.
        let archived = archiveRefusal(for: oldId) == nil && archiveConversation(oldId) == nil

        var opening = summary.map { "\(Self.rotationSummaryLabel), \"\(title)\"]\n\n\($0)" }
            ?? "[No summary was produced. The previous Iris conversation is \"\(title)\"; search_conversations and read_conversation reach it.]"
        if !archived {
            opening += "\n\n[The previous conversation was busy, so it was left in the sidebar unarchived and unpinned, as \"\(title)\".]"
        }
        // `.system`, not `.event`: an `.event` row is expected to decode as a card and a plain one
        // renders as the malformed-card fallback.
        appendMessage(role: .system, content: opening, to: newId)
        placeOpeningInHistory(opening, for: newId)
    }

    /// The opening goes FIRST in history, as a user entry: Anthropic and Gemini reject a history
    /// that opens with a model entry, and a card delivered mid-rotation may already be there. If
    /// the owner already started a turn in the new Iris, the engine holds its own copy of history
    /// until the turn ends, so the opening rides the event-line queue instead of being overwritten.
    private func placeOpeningInHistory(_ opening: String, for newId: UUID) {
        if hasTurnInFlight(for: newId) {
            enqueueEventLine(opening, for: newId)
            return
        }
        guard let n = conversations.firstIndex(where: { $0.id == newId }) else { return }
        let entry = Content(role: "user", parts: [Part(text: opening)])
        if conversations[n].history.isEmpty {
            appendContentToHistory(for: newId, content: entry)
        } else {
            updateHistory(for: newId, history: [entry] + conversations[n].history)
        }
    }
}
