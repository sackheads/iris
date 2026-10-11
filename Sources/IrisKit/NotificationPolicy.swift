import Foundation

/// A notification Iris has decided to post (D6 decision 6). Every string in it is built by
/// `NotificationPolicy` from fixed words and harness-owned names.
struct PlannedNotification: Equatable, Sendable {
    enum Kind: String, Sendable { case jobNeedsYou, approvalWaiting }

    /// The run id for a card, the ask id for an ask, so a gone ask's banner can be withdrawn.
    let identifier: String
    let kind: Kind
    let title: String
    let body: String
    let categoryId: String
    let userInfo: [String: String]
}

/// The app's state at the moment the policy decides, read by `AppState.notificationContext`.
struct NotificationContext: Equatable, Sendable {
    /// Settings' "Notifications: Off / Needs attention".
    var enabled: Bool
    var appActive: Bool
    var mainWindowVisible: Bool
    var selectedConversationId: UUID?

    static let off = NotificationContext(enabled: false, appActive: false, mainWindowVisible: false,
                                         selectedConversationId: nil)
}

enum NotificationEvent: Sendable {
    /// A delivered card. `jobPausedReason` is read from the job when the card is delivered,
    /// because no card field says "this paused the job".
    case card(EventCard, destination: UUID, jobPausedReason: String?)
    /// A live ask. `details` is passed so that the tests can show it is never used.
    case ask(id: UUID, toolName: String, details: String, root: UUID?)
}

/// Which events notify, when a banner would be pointless, and exactly what it says (D6
/// decisions 1 and 6). Pure.
///
/// The title is a constant per kind: macOS shows titles on the lock screen even when previews
/// are hidden, and a job name is chosen by the model ("Security fix — tap Open, then Approve"
/// fits in the cap). The body carries a quoted, flattened name and fixed words, and never a
/// run's outcome, an ask's details, a conversation title or a Vibecop reason. Every one of those
/// is model-, script- or page-written, and on a lock screen they are a phishing surface.
enum NotificationPolicy {
    static let jobTitle = "Iris: a job needs you"
    static let approvalTitle = "Iris: approval waiting"

    enum Category {
        static let blockedCard = "iris.card.blocked"
        static let pausedCard = "iris.card.paused"
        static let ask = "iris.ask"
    }

    enum Action {
        static let open = "iris.open"
        static let deny = "iris.deny"
        static let dismiss = "iris.dismiss"
    }

    enum Key {
        static let runId = "runId"
        static let jobId = "jobId"
        static let askId = "askId"
        static let conversationId = "conversationId"
    }

    struct ActionSpec: Equatable, Sendable {
        let id: String
        let title: String
        let destructive: Bool
        /// Brings the app forward. Only Open does; Deny and Dismiss act from the banner.
        let foreground: Bool
    }

    struct CategorySpec: Equatable, Sendable {
        let id: String
        let actions: [ActionSpec]
    }

    static let openAction = ActionSpec(id: Action.open, title: "Open", destructive: false, foreground: true)

    /// Decision 1 (owner ruling 1): no category carries an approve action, so no code path can
    /// add one by accident. A tap on a banner can stop work; it can never authorise it. A banner
    /// truncates and a locked screen hides previews, and an approval given without sight of the
    /// payload is worse than no button (`EventCard.swift:45-47`).
    static let categories: [CategorySpec] = [
        CategorySpec(id: Category.blockedCard, actions: [
            openAction,
            ActionSpec(id: Action.dismiss, title: "Dismiss", destructive: false, foreground: false),
        ]),
        CategorySpec(id: Category.pausedCard, actions: [openAction]),
        CategorySpec(id: Category.ask, actions: [
            openAction,
            ActionSpec(id: Action.deny, title: "Deny", destructive: true, foreground: false),
        ]),
    ]

    static func decide(_ event: NotificationEvent, context: NotificationContext) -> PlannedNotification? {
        guard context.enabled else { return nil }
        switch event {
        case .card(let card, let destination, let pausedReason):
            guard !card.isReflection else { return nil }
            // Already on screen: the card is in the conversation the owner is looking at.
            if context.appActive, context.selectedConversationId == destination { return nil }
            let info = [Key.runId: card.runId.uuidString, Key.jobId: card.jobId.uuidString,
                        Key.conversationId: destination.uuidString]
            if card.status == .blockedOnApproval {
                return PlannedNotification(
                    identifier: card.runId.uuidString, kind: .jobNeedsYou, title: jobTitle,
                    body: "Job \(quoted(card.jobName)) is blocked on \(quoted(card.blockedTool ?? "a tool")).",
                    categoryId: Category.blockedCard, userInfo: info)
            }
            // Plan note 5: only a card that ended badly on a job a limit has stopped. A completed
            // card on a paused job (an approved call), or a run of a job the owner paused, is not
            // a job waiting on anyone.
            guard card.status == .failed || card.status == .interrupted, let pausedReason,
                  !LedgerAttention.ownerPauseReasons.contains(pausedReason) else { return nil }
            return PlannedNotification(
                identifier: card.runId.uuidString, kind: .jobNeedsYou, title: jobTitle,
                body: "Job \(quoted(card.jobName)) is paused and waits for /jobs resume.",
                categoryId: Category.pausedCard, userInfo: info)

        case .ask(let id, let toolName, _, let root):
            // The overlay is global: any visible main window is already showing it.
            if context.appActive, context.mainWindowVisible { return nil }
            var info = [Key.askId: id.uuidString]
            if let root { info[Key.conversationId] = root.uuidString }
            return PlannedNotification(
                identifier: id.uuidString, kind: .approvalWaiting, title: approvalTitle,
                body: "\(quoted(toolName)) is waiting for your approval.",
                categoryId: Category.ask, userInfo: info)
        }
    }

    /// A name as a banner may show it: flattened and capped as the briefing does, with every
    /// character a reader could not see removed (controls, bidi overrides, zero-width spaces,
    /// line and paragraph separators, the set #334's `containsHiddenCharacters` names). Every
    /// quotation mark, and the dingbat ones Unicode does not class as such, becomes a straight
    /// `'`, so the name cannot close its own quotation marks, even with a look-alike.
    /// `flattenCardField` strips line breaks, `|` and `"` only, so the rest is done here.
    static func quoted(_ field: String) -> String {
        let flat = IrisEngine.flattenCardField(field, cap: IrisEngine.cardNameCap)
        var scalars = String.UnicodeScalarView()
        for scalar in flat.unicodeScalars where !String(scalar).containsHiddenCharacters {
            let looksLikeAQuote = scalar.properties.isQuotationMark || quoteDingbats.contains(scalar)
            scalars.append(looksLikeAQuote ? "'" : scalar)
        }
        return "\u{201C}\(String(scalars))\u{201D}"
    }

    /// U+275B-275E: heavy turned/comma quotation mark ornaments, which are `So`, not
    /// `Quotation_Mark`.
    private static let quoteDingbats: Set<Unicode.Scalar> = ["\u{275B}", "\u{275C}", "\u{275D}", "\u{275E}"]
}
