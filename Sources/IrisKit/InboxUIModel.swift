import Foundation

/// The mailbox's response-area affordances (#920 Task 5), one per `InboxResponseMode`. Pure and
/// free of SwiftUI so the mapping is testable without a view, the same split `SidebarOrdering` is.
enum InboxResponseAffordance: Equatable {
    /// Options with pros/cons, plus a free-text box.
    case optionsAndFreeform
    /// A free-text box only.
    case freeformOnly
    /// An approve/veto choice with a countdown to the default.
    case timedVetoCountdown
    /// Nothing to answer; a dismiss action only.
    case dismissOnly
}

extension InboxResponseMode {
    var inboxAffordance: InboxResponseAffordance {
        switch self {
        case .optionsAndFreeform: return .optionsAndFreeform
        case .freeform: return .freeformOnly
        case .timedVeto: return .timedVetoCountdown
        case .notification: return .dismissOnly
        }
    }
}

enum InboxUIModel {
    /// Whether an item should show as overdue: a `timedVeto` item, still `.open`, whose deadline
    /// has passed. Display only — it never itself resolves the item (Task 4's
    /// `evaluateInboxVetoExpiries` does that; a tainted item it deliberately leaves `.open`, which
    /// is exactly the case this exists to surface rather than let read as silently approved).
    static func isOverdue(_ item: InboxItem, now: Date) -> Bool {
        guard item.responseMode == .timedVeto, item.state == .open, let deadline = item.deadline else { return false }
        return deadline <= now
    }

    /// Where Submit actually routes Brian's answer, under his user authority (security
    /// requirement, planner/#920 Task 5, from dev-3's #936 review): `routeBack` is the *emitter's*
    /// own text, so an emitter can aim Brian's decision at an arbitrary session, and the UI must
    /// show him the real targets before he submits, not after. Matches `submitInboxAnswer`'s own
    /// fallback (`item.routeBack.isEmpty ? [item.emitter.uuidString] : item.routeBack`) exactly —
    /// shown here as the emitter's label rather than its id, since that is what the UI already
    /// displays everywhere else, but it is never a different answer from what actually gets used.
    static func answerRouteTargets(_ item: InboxItem) -> [String] {
        item.routeBack.isEmpty ? [item.emitterLabel] : item.routeBack
    }
}
