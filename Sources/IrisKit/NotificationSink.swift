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
    /// card's job once, because no card field says "this paused the job".
    func notifyForCard(_ card: EventCard, destination: UUID) {
        guard let sink = notificationSink, !card.isReflection else { return }
        let paused = (try? store.ledger.job(id: card.jobId))?.pausedReason
        if let planned = NotificationPolicy.decide(.card(card, destination: destination, jobPausedReason: paused),
                                                   context: notificationContext()) {
            sink.post(planned)
        }
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
            if let askId {
                let owner = pendingApprovals.first { $0.id == askId }?.conversationId
                    ?? info[NotificationPolicy.Key.conversationId].flatMap(UUID.init(uuidString:))
                showMainWindow(selecting: owner.map { delegationRoot(of: $0) })
            } else {
                showMainWindow(selecting: nil)
            }
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
