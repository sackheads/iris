import Foundation

/// #813: holding, approving and rejecting standing-context writes. The engine holds; the person
/// decides here, from the chip or the review sheet.
extension AppState {
    /// Records a held item and persists it. Best-effort on the store: the item still shows this
    /// session if the write fails, and the failure is logged.
    func holdContextWrite(_ item: PendingContextWrite) {
        pendingContextWrites.append(item)
        do { try store.savePendingWrite(item) } catch { print("WARNING: held context write not persisted: \(error)") }
    }

    /// Whether `conversationId`, or any session it was delegated from, has read untrusted output.
    /// A subagent inherits the flag when created (#818), but its parent can be tainted later, while
    /// it works; this asks the chain at the moment of the write (#818 review note). A conversation
    /// the app doesn't know reads as tainted: unknown is not clean.
    func readUntrustedThroughDelegation(_ conversationId: UUID) -> Bool {
        var current = conversationId
        for _ in 0..<16 {
            guard let conversation = conversations.first(where: { $0.id == current }) else { return true }
            if conversation.hasUntrustedToolOutput { return true }
            guard let parent = delegationParent(of: current) else { return false }
            current = parent
        }
        return true
    }

    /// The items waiting for `conversationId`: its own and its delegates'. The pinned Iris also
    /// shows those whose session the person can't open (a job run, or one that no longer exists),
    /// so nothing waits unseen.
    func pendingContextWrites(shownIn conversationId: UUID) -> [PendingContextWrite] {
        let isPinned = conversations.first { $0.id == conversationId }?.isPinned == true
        return pendingContextWrites.filter { item in
            guard item.state == .pending else { return false }
            let home = item.rootConversationId ?? item.conversationId
            if home == conversationId { return true }
            guard isPinned else { return false }
            guard let owner = conversations.first(where: { $0.id == home }) else { return true }
            return owner.isBackground || owner.isSubagent
        }
    }

    var pendingContextWriteCount: Int { pendingContextWrites.filter { $0.state == .pending }.count }

    enum HeldWriteOutcome: Equatable {
        case applied(String)
        /// The target changed since the hold; approve again with `replacingChanged: true`.
        case targetChanged
        case stale(String)
        case notPending
    }

    /// Applies one held item through the engine that would have applied it. A target edited since
    /// the hold is not overwritten unless the person said so for this item.
    @discardableResult
    func approveContextWrite(_ id: UUID, replacingChanged: Bool = false, now: Date = Date()) async -> HeldWriteOutcome {
        guard let item = pendingContextWrites.first(where: { $0.id == id }), item.state == .pending else { return .notPending }
        if !replacingChanged, ContextHolds.targetChanged(item) { return .targetChanged }
        guard let engine else { return .notPending }
        // Out of `.pending` before the await, so a second tap while this one applies is refused
        // above instead of applying the write twice.
        decide(id, state: .applied, outcome: nil, now: now)
        let result = await engine.applyHeldWrite(item)
        let stale = result.contains(" unchanged: ") || result.hasPrefix("manage_fact needs")
        decide(id, state: stale ? .stale : .applied, outcome: result, now: now)
        appendMessage(role: .system, content: stale ? "Held change not applied: \(result)" : "You approved \(item.firstLine).",
                      to: item.rootConversationId ?? item.conversationId)
        return stale ? .stale(result) : .applied(result)
    }

    /// Approves every item shown in `conversationId` whose target is unchanged; one whose target
    /// changed stays for the person to decide on its own.
    func approveAllContextWrites(shownIn conversationId: UUID, now: Date = Date()) async {
        for item in pendingContextWrites(shownIn: conversationId) {
            _ = await approveContextWrite(item.id, now: now)
        }
    }

    func rejectContextWrite(_ id: UUID, now: Date = Date()) {
        guard let item = pendingContextWrites.first(where: { $0.id == id }), item.state == .pending else { return }
        decide(id, state: .rejected, outcome: nil, now: now)
        appendMessage(role: .system, content: "You declined \(item.firstLine); nothing was written.",
                      to: item.rootConversationId ?? item.conversationId)
    }

    func rejectAllContextWrites(shownIn conversationId: UUID, now: Date = Date()) {
        for item in pendingContextWrites(shownIn: conversationId) { rejectContextWrite(item.id, now: now) }
    }

    private func decide(_ id: UUID, state: PendingContextWrite.State, outcome: String?, now: Date) {
        guard let i = pendingContextWrites.firstIndex(where: { $0.id == id }) else { return }
        pendingContextWrites[i].state = state
        pendingContextWrites[i].decidedAt = now
        pendingContextWrites[i].outcome = outcome
        do { try store.savePendingWrite(pendingContextWrites[i]) } catch { print("WARNING: held context write decision not persisted: \(error)") }
    }
}
