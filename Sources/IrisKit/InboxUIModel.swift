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

    /// Words a resolved route target (the emitter's own id, or `role:<name>`) for display. Kept
    /// SwiftUI-free, the same split as the rest of this file, so the wording is testable without a
    /// view. `emitterLabel` and `roleHolderLabel` are each a card name the *session itself* chose —
    /// an untrusted field — so neither is ever run into the surrounding sentence as if it were
    /// trusted prose: both are set off in quotes, with any embedded quote flattened first so a
    /// crafted name cannot break out of them (dev-3's #943 review finding 2).
    static func routeTargetDescription(_ target: String, emitterId: UUID, emitterLabel: String,
                                       roleHolderLabel: String?) -> String {
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.caseInsensitiveCompare(emitterId.uuidString) == .orderedSame {
            return "the session that raised it (named \"\(quoted(emitterLabel))\")"
        }
        guard raw.lowercased().hasPrefix("role:") else { return raw }
        let role = String(raw.dropFirst(5))
        if let roleHolderLabel {
            return "whoever holds the \(role) role (currently named \"\(quoted(roleHolderLabel))\")"
        }
        return "whoever holds the \(role) role"
    }

    private static func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "'")
    }

    /// The mailbox list's contents: open items needing attention, then awaiting-delivery ones —
    /// answered, but with no live recipient yet — so an answered item does not simply vanish once
    /// Brian has acted on it (dev-3's #943 review finding 3). The two states are mutually
    /// exclusive by construction (`InboxStore`'s queries), so there is nothing to de-duplicate.
    static func mailboxItems(open: [InboxItem], awaitingDelivery: [InboxItem]) -> [InboxItem] {
        open + awaitingDelivery
    }
}
