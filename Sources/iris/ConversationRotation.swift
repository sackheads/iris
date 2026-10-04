import Foundation

/// 5b §0.4: `/new` in Iris rotates it. The order is the design:
/// 1. refuse synchronously (`rotationRefusal`, in the `/new` handler);
/// 2. reflect in the old conversation, so durable learning reaches memory before it leaves context;
/// 3. create the new Iris and move the pin, before the summary call, because cards are routed
///    through `activityConversationId()` at each delivery. The reflection in step 2 is a full
///    model turn that runs BEFORE the move, so a card delivered during it lands in the old Iris;
///    the summary's input includes event cards, so the new Iris still hears of it;
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
    ///
    /// Stoppable (Esc, `interruptActiveConversation`): before the pin moves, a stop changes
    /// nothing; after, the rotation finishes without a summary, so the pin never names a
    /// conversation that is about to be left half-rotated.
    func rotatePinned(engine: IrisEngine) async {
        let oldId = activityConversationId()

        await engine.processInput(Self.reflectionPrompt, source: "System", conversationId: oldId)
        releaseRotationHold()

        if Task.isCancelled {
            appendMessage(role: .system, content: "Rotation stopped; Iris was not rotated.", to: oldId)
            return
        }

        // Follow the pin only if the owner is still looking at Iris; a conversation they switched
        // to during the reflection is theirs to keep.
        let newId = createNewConversation(title: Self.activityConversationTitle,
                                          select: selectedConversationId == oldId)
        // The meta write comes before the pin flags move, so a failed write leaves only an empty
        // conversation to remove, never a pin that disagrees with the meta key.
        do {
            if let writer = pinnedMetaWriter {
                try writer(newId.uuidString)
            } else {
                try store.setMetaValue(newId.uuidString, forKey: Self.activityConversationMetaKey)
            }
        } catch {
            let followedPin = selectedConversationId == newId
            deleteConversation(newId)
            if followedPin { selectedConversationId = oldId }
            appendMessage(role: .command,
                          content: "Rotation stopped: the new Iris could not be recorded (\(error.localizedDescription)). Nothing was archived; this is still Iris.",
                          to: oldId)
            return
        }
        if let o = conversations.firstIndex(where: { $0.id == oldId }) {
            conversations[o].isPinned = false
            markChanged(oldId, .metadata)
        }
        if let n = conversations.firstIndex(where: { $0.id == newId }) {
            conversations[n].isPinned = true
            markChanged(newId, .metadata)
        }
        rotationConversationIds.insert(newId)

        let oldMessages = conversations.first { $0.id == oldId }?.messages ?? []
        let outcome = await Self.unlessCancelled { await engine.summarizeForRotation(messages: oldMessages) }
        let stopped = Task.isCancelled

        let title = Self.archivedTitle(last: rotationNow())
        if let o = conversations.firstIndex(where: { $0.id == oldId }) {
            conversations[o].title = title
            markChanged(oldId, .metadata)
        }
        // A peer can start a turn in the old conversation while the summary runs; archiving it
        // then is refused. Say so rather than leave a silent half-rotation.
        let archived = archiveRefusal(for: oldId) == nil && archiveConversation(oldId) == nil

        let label = "\(Self.rotationSummaryLabel), \"\(title)\"]"
        let fallback = "[No summary was produced. The previous Iris conversation is \"\(title)\"; search_conversations and read_conversation reach it.]"
        var visible: String
        var model: String
        switch stopped ? nil : outcome {
        case .passed(let clean)?:
            visible = "\(label)\n\n\(clean)"
            model = "\(label)\n\n\(InjectionGuard.wrapped(.passed(clean: clean), contextTag: "rotation_summary"))"
        case .blocked(let marker)?:
            visible = "\(label)\n\n\(marker)"
            model = "\(label)\n\n\(InjectionGuard.wrapped(.blocked(marker: marker), contextTag: "rotation_summary"))"
        case nil:
            visible = fallback
            model = fallback
        }
        if !archived {
            let busy = "\n\n[The previous conversation was busy, so it was left in the sidebar unarchived and unpinned, as \"\(title)\".]"
            visible += busy
            model += busy
        }
        // `.agent`: a `.system` line would fold into a SystemGroupView, and a plain `.event` renders
        // as the malformed-card fallback. History gets the guard's wrapped form, the screen does not.
        appendMessage(role: .agent, content: visible, to: newId)
        placeOpeningInHistory(model, for: newId)
        if stopped {
            appendMessage(role: .system, content: "Rotation stopped after the move; no summary was written.", to: newId)
        }
    }

    /// `operation`'s result, or nil as soon as the current task is cancelled. A provider call
    /// that ignores cancellation would otherwise hold the rotation, and `rotationTask` with it,
    /// for as long as it hangs; it is left to finish on its own and its result is dropped.
    static func unlessCancelled<T: Sendable>(_ operation: @escaping @Sendable () async -> T?) async -> T? {
        let box = OneShot<T?>()
        let inner = Task { box.resume(await operation()) }
        return await withTaskCancellationHandler {
            await box.wait()
        } onCancel: {
            inner.cancel()
            box.resume(nil)
        }
    }

    /// The opening goes FIRST in history, as a user entry: Anthropic and Gemini reject a history
    /// that opens with a model entry, and a card delivered mid-rotation may already be there.
    /// Inserting at 0 also means that if the owner already talked in the new Iris, the summary
    /// lands before that exchange, which is where it belongs in time. If a turn is in flight
    /// there, though, the engine holds its own copy of history until the turn ends and would
    /// overwrite a direct edit, so the opening rides the event-line queue instead.
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

/// A value delivered once, to one waiter, whichever of `resume` and `wait` comes first.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var delivered = false
    private var waiter: CheckedContinuation<T, Never>?

    func resume(_ v: T) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: v)
        } else {
            value = v
            lock.unlock()
        }
    }

    func wait() async -> T {
        await withCheckedContinuation { c in
            lock.lock()
            if delivered, let v = value {
                value = nil
                lock.unlock()
                c.resume(returning: v)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }
}

/// 5b §0.4: what launch does to make the meta key and the `isPinned` flags agree, and to keep the
/// pinned conversation out of the archive. Pure, so every case is testable without an `AppState`;
/// `AppState.repairPinnedConversation()` applies it.
///
/// The meta key is written before the flags move, and the flags reach the store on a debounced
/// flush, so a crash can leave either side behind:
/// - the key names a live conversation: it is Iris. Pin it, un-archive it, unpin every other.
/// - the key names a missing or archived conversation, or there is no key: a crash between the
///   meta write and the flush named a row that was never persisted, or a legacy store predates
///   the key. A conversation still flagged pinned is what the owner last saw as Iris, so the key
///   is pointed back at it.
/// - nothing is pinned either: an archived target is restored; a missing one is left to
///   `activityConversationId()`, which creates a fresh Iris on first use.
struct PinRepair: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let id: UUID
        let isPinned: Bool
        let isArchived: Bool
        let updatedAt: Date
    }

    /// The new meta value to record; nil leaves the key as it is.
    var newMetaId: UUID?
    var pin: Set<UUID> = []
    var unpin: Set<UUID> = []
    var unarchive: Set<UUID> = []

    var isEmpty: Bool { newMetaId == nil && pin.isEmpty && unpin.isEmpty && unarchive.isEmpty }

    static func decide(metaValue: String?, rows: [Row]) -> PinRepair {
        let target = metaValue.flatMap(UUID.init(uuidString:))
        let targetRow = target.flatMap { t in rows.first { $0.id == t } }
        var repair = PinRepair()
        let keep: Row?
        if let row = targetRow, !row.isArchived {
            keep = row
        } else if let best = rows.filter({ $0.isPinned && $0.id != target })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            // Several pins with no live key only come from a crash mid-rotation or from repeated
            // ones; the newest is the latest Iris in that chain. The tie-break is safe because
            // the losers are only unpinned: their messages stay in the sidebar, searchable and
            // archivable, and nothing is deleted or merged on the strength of the guess.
            keep = best
            repair.newMetaId = best.id
        } else {
            keep = targetRow   // archived, unpinned elsewhere: restore it; missing: nil
        }
        if let keep {
            if !keep.isPinned { repair.pin.insert(keep.id) }
            if keep.isArchived { repair.unarchive.insert(keep.id) }
        }
        for row in rows where row.isPinned && row.id != keep?.id {
            repair.unpin.insert(row.id)
        }
        return repair
    }
}
