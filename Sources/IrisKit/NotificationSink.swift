import Foundation

/// Where a planned notification goes (D6 decision 7). `AppState.notificationSink` is nil unless
/// `IrisApp.init` installed `UserNotificationSink`, so a test, `--run-job` and the bare binary
/// post nothing. A test installs a fake.
@MainActor
protocol NotificationSink: AnyObject {
    func post(_ notification: PlannedNotification)
    /// Takes down delivered or pending banners by `PlannedNotification.identifier`.
    func withdraw(identifiers: [String])
}

/// A tap on a delivered notification, reduced to strings before it reaches the main actor.
struct NotificationResponse: Equatable, Sendable {
    let actionId: String
    let userInfo: [String: String]
}

extension AppState {
    /// The first of the two places the policy is asked: after `deliverEvent`'s append. Reads the
    /// card's job once, because no card field says "this paused the job", and only when
    /// notifications are on and the card is one a pause could make notify.
    func notifyForCard(_ card: EventCard, destination: UUID) {
        guard let sink = notificationSink, !card.isReflection else { return }
        let context = notificationContext()
        guard context.enabled else { return }
        // Only a failed or interrupted card can notify for its job's pause (plan note 5), so no
        // other card costs a main-actor ledger read.
        let paused = card.status == .failed || card.status == .interrupted
            ? (try? store.ledger.job(id: card.jobId))?.pausedReason : nil
        if let planned = NotificationPolicy.decide(.card(card, destination: destination, jobPausedReason: paused),
                                                   context: context) {
            sink.post(planned)
        }
    }

    /// A card's banner comes down once its run is acknowledged (the card's or the banner's
    /// Dismiss, `/jobs ack`, or an Approve-and-run claim): it no longer needs the owner. A banner still held behind the
    /// permission prompt is dropped by the same withdraw.
    func withdrawCardBanner(runId: UUID) {
        notificationSink?.withdraw(identifiers: [runId.uuidString])
    }

    /// The second: every change to `pendingApprovals`, diffed by id. Only an ask that was not in
    /// the queue before is offered to the policy, so no mutation re-posts one already shown; a
    /// gone one's banner is withdrawn, whichever mutation site removed it (resolve, deny-all,
    /// cancellation, or a future one).
    func approvalsChanged(from old: [ToolApprovalRequest]) {
        guard let sink = notificationSink else { return }
        let now = Set(pendingApprovals.map(\.id)), before = Set(old.map(\.id))
        let removed = old.filter { !now.contains($0.id) }.map(\.id.uuidString)
        if !removed.isEmpty { sink.withdraw(identifiers: removed) }
        let added = pendingApprovals.filter { !before.contains($0.id) }
        guard !added.isEmpty else { return }
        let context = notificationContext()
        for request in added {
            let event = NotificationEvent.ask(id: request.id, toolName: request.toolName, details: request.details,
                                              root: request.conversationId.map { delegationRoot(of: $0) })
            if let planned = NotificationPolicy.decide(event, context: context) { sink.post(planned) }
        }
    }

    /// #493: clicks past the gate's cap while Iris waited, in one line in Iris, like dropped links.
    func noteNotificationsDroppedWhileWaiting(_ count: Int) {
        guard count > 0 else { return }
        appendMessage(role: .system, content: Self.droppedNotificationsLine(count), to: activityConversationId())
    }

    static func droppedNotificationsLine(_ count: Int) -> String {
        "\(count) notification click\(count == 1 ? "" : "s") that arrived while Iris waited "
            + "\(count == 1 ? "was" : "were") dropped, so nothing they asked for was done. The Run Log still shows each run."
    }

    /// Open, Deny and Dismiss (decision 7), and nothing else. Every id is the one the banner
    /// carried: Deny resolves that ask and no other, Dismiss acknowledges that run. An id that is
    /// gone is a no-op, and acknowledging a run twice keeps the first acknowledgement. Returns
    /// the work an Open on a card or a Dismiss starts, so a test can await it.
    @discardableResult
    func handleNotificationResponse(_ response: NotificationResponse) -> Task<Void, Never>? {
        let info = response.userInfo
        let runId = info[NotificationPolicy.Key.runId].flatMap(UUID.init(uuidString:))
        let jobId = info[NotificationPolicy.Key.jobId].flatMap(UUID.init(uuidString:))
        let askId = info[NotificationPolicy.Key.askId].flatMap(UUID.init(uuidString:))
        switch response.actionId {
        case NotificationPolicy.Action.open:
            if let runId, let jobId {
                return Task { [weak self] in await self?.revealCard(runId: runId, jobId: jobId) }
            }
            if let askId, let live = pendingApprovals.first(where: { $0.id == askId })?.conversationId {
                // The status item's own path: a root archived while its ask waits is unarchived.
                let root = delegationRoot(of: live)
                return Task { [weak self] in await self?.openStatusRow(.conversation(root)) }
            }
            // An ask already answered unarchives nothing: its root is no longer waiting.
            let gone = askId == nil ? nil : info[NotificationPolicy.Key.conversationId].flatMap(UUID.init(uuidString:))
            showMainWindow(selecting: gone.map { delegationRoot(of: $0) })
            return nil
        case NotificationPolicy.Action.deny:
            if let askId { resolveApproval(id: askId, .deny) }
            return nil
        case NotificationPolicy.Action.dismiss:
            guard let runId else { return nil }
            return acknowledgeRun(runId)
        default:
            // Decision 1: there is no approve action, and no name, however spelled, becomes one.
            return nil
        }
    }
}
