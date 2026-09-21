import Foundation

/// Delivering an event card (#187 §8.3). Two things travel together and must not be confused:
///
/// - the **card**, a `ChatRole.event` message holding the card's JSON. This is a UI artifact —
///   it is what the user sees, it is never indexed for search, and it goes in immediately so the
///   transcript shows the news at the moment it happened rather than whenever the model next
///   speaks.
/// - the **history line**, `EventCard.historyLine`, the one sentence the model is told. It is the
///   only model-legible part of a card, and it is routed by whether the destination is busy.
///
/// The rule the whole file exists for: **delivery never wakes a turn.** A job finishing is news,
/// not a request. Waking the model on every run would turn a five-minute schedule into a
/// five-minute agent loop, and a run that produced nothing worth saying would still cost a turn.
/// So the line is either appended straight to an idle conversation's history — where the next
/// turn, whenever the user starts one, reads it as context — or queued for a running turn to pick
/// up at its next model round (`AppState.takePendingEventLines`, drained by `IrisEngine` at the
/// same boundary it takes steers, and flushed by `endEngineTurn` if the turn ends first).
extension AppState {
    /// The one shape an event line takes in history, spelled in one place: a plain `user` entry.
    /// Three sites build it — delivery to an idle conversation, the engine's drain at the steer
    /// boundary, and the flush when a turn ends — and they must agree, because the model reads
    /// them as one stream. `nonisolated` so the engine can build the value off the main actor and
    /// hop only for the append, as the steer path does.
    nonisolated static func eventLineContent(_ line: String) -> Content {
        Content(role: "user", parts: [Part(text: line)])
    }

    /// Appends the card to `destinationId`'s transcript now and routes its history line per the
    /// in-flight rule. Starts no turn, in either branch.
    ///
    /// The line is sanitised, the card is not. The line is the part that reaches the model, and
    /// its `outcome` is a background run's own words about its own work — text no human read
    /// before it arrived. Tier 1 is the right ceiling: it is synchronous, it cannot block the
    /// line, and it gives the wrapper (`<untrusted_context source="event_card">`) that tells the
    /// model where this sentence came from. The card keeps the raw `encodedContent()`, because
    /// the wrapper is addressed to the model and would only be noise in a rendered card.
    func deliverEvent(_ card: EventCard, to destinationId: UUID) async {
        guard conversations.contains(where: { $0.id == destinationId }) else { return }
        let safeLine = await InjectionGuard.sanitize(card.historyLine,
                                                     contextTag: "event_card",
                                                     maxTier: .tier1_structural)
        // Re-checked after the await: the destination could have been deleted while the guard ran.
        guard conversations.contains(where: { $0.id == destinationId }) else { return }
        appendMessage(role: .event, content: card.encodedContent(), to: destinationId)
        if hasTurnInFlight(for: destinationId) {
            enqueueEventLine(safeLine, for: destinationId)
        } else {
            appendContentToHistory(for: destinationId, content: Self.eventLineContent(safeLine))
        }
    }
}
