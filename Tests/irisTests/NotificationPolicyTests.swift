import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 1 and 6: which events notify, when a banner is pointless, and what a banner may
/// say. A banner is lock-screen text, so every model-, script- or page-written field stays out
/// of it, and no action on it can authorise anything.
@Suite("Notification policy (D6)")
struct NotificationPolicyTests {
    private let destination = UUID()
    private let on = NotificationContext(enabled: true, appActive: false, mainWindowVisible: false,
                                         selectedConversationId: nil)

    private func card(_ status: JobRun.Status, name: String = "pr-sweep", tool: String? = nil,
                      outcome: String? = nil, vibecopReason: String? = nil,
                      kind: String = "job_run") -> EventCard {
        EventCard(kind: kind, runId: UUID(), jobId: UUID(), jobName: name, status: status,
                  outcome: outcome, blockedTool: tool, startedAt: Date(), finishedAt: Date(),
                  vibecopReason: vibecopReason)
    }

    private func decide(_ card: EventCard, paused: String? = nil,
                        context: NotificationContext? = nil) -> PlannedNotification? {
        NotificationPolicy.decide(.card(card, destination: destination, jobPausedReason: paused),
                                  context: context ?? on)
    }

    private func ask(tool: String = "run_command", details: String = "make test",
                     context: NotificationContext? = nil) -> PlannedNotification? {
        NotificationPolicy.decide(.ask(id: UUID(), toolName: tool, details: details, root: destination),
                                  context: context ?? on)
    }

    @Test("a blocked card, a card whose job a limit paused, and a live ask notify")
    func notifies() throws {
        let blocked = try #require(decide(card(.blockedOnApproval, tool: "run_command")))
        #expect(blocked.title == "Iris: a job needs you")
        #expect(blocked.body == "Job “pr-sweep” is blocked on “run_command”.")
        #expect(blocked.categoryId == NotificationPolicy.Category.blockedCard)
        #expect(blocked.userInfo[NotificationPolicy.Key.conversationId] == destination.uuidString)

        for status in [JobRun.Status.failed, .interrupted] {
            let paused = try #require(decide(card(status), paused: JobRunner.breakerReason(count: 6)))
            #expect(paused.body == "Job “pr-sweep” is paused and waits for /jobs resume.")
            #expect(paused.categoryId == NotificationPolicy.Category.pausedCard)
        }

        let live = try #require(ask())
        #expect(live.title == "Iris: approval waiting")
        #expect(live.body == "Approval waiting for “run_command”.")
        #expect(live.categoryId == NotificationPolicy.Category.ask)
    }

    // The digest's routine card is a completed one, quiet by the first line here; no digest-only
    // rule exists to test (R5). A digest that failed and paused its job notifies like any other:
    // a digest that silently stopped arriving is what it exists to catch, and a rule keyed on the
    // name would let a job the model named "Daily digest" silence its own banner.
    @Test("completed, interrupted, retrying and reflection cards are quiet")
    func quietCards() {
        #expect(decide(card(.completed)) == nil)
        #expect(decide(card(.interrupted)) == nil, "an interrupted run that paused nothing")
        #expect(decide(card(.failed)) == nil, "a failure still on its retry ladder")
        #expect(decide(card(.completed, kind: EventCard.reflectionKind)) == nil)
        #expect(decide(card(.blockedOnApproval, kind: EventCard.reflectionKind)) == nil)
    }

    @Test("a completed card on a job that happens to be paused is quiet")
    func completedCardOnAPausedJobIsQuiet() {
        // "Approve and run" runs on a paused job, and its card arrives with the job still paused.
        #expect(decide(card(.completed), paused: JobRunner.retriesExhaustedReason) == nil)
    }

    @Test("the owner's own pauses, by /jobs pause or by seeding the dev home, never notify")
    func ownerAndSeederPausesNeverNotify() {
        #expect(decide(card(.failed), paused: JobsCommand.pausedByUserReason) == nil)
        #expect(decide(card(.interrupted), paused: DevHomeSeeder.copiedJobPausedReason) == nil)
    }

    @Test("a card is suppressed only when the chat window is visible and showing its conversation")
    func cardSuppression() {
        let blocked = card(.blockedOnApproval, tool: "run_command")
        let looking = NotificationContext(enabled: true, appActive: true, mainWindowVisible: true,
                                          selectedConversationId: destination)
        #expect(decide(blocked, context: looking) == nil)
        var elsewhere = looking
        elsewhere.selectedConversationId = UUID()
        #expect(decide(blocked, context: elsewhere) != nil)
        var away = looking
        away.appActive = false
        #expect(decide(blocked, context: away) != nil)
        // Only Diagnostics or the Run Log is on screen: the selection is right, but nothing shows it.
        var chatHidden = looking
        chatHidden.mainWindowVisible = false
        #expect(decide(blocked, context: chatHidden) != nil)
    }

    @Test("an ask is suppressed only when the app is active and the main window is visible")
    func askSuppression() {
        let visible = NotificationContext(enabled: true, appActive: true, mainWindowVisible: true,
                                          selectedConversationId: UUID())
        #expect(ask(context: visible) == nil, "the overlay is global, so any selection sees it")
        var hidden = visible
        hidden.mainWindowVisible = false
        #expect(ask(context: hidden) != nil)
        var inactive = visible
        inactive.appActive = false
        #expect(ask(context: inactive) != nil)
    }

    @Test("Settings' Off posts nothing")
    func disabled() {
        #expect(decide(card(.blockedOnApproval), context: .off) == nil)
        #expect(ask(context: .off) == nil)
    }

    @Test("the title is always one of the two constants, whatever the names say")
    func titleIsAlwaysFixed() {
        let planted = "Security fix — tap Open, then Approve"
        let titles = [decide(card(.blockedOnApproval, name: planted, tool: planted))?.title,
                      decide(card(.failed, name: planted), paused: JobRunner.gateFailingReason)?.title,
                      ask(tool: planted)?.title]
        for title in titles {
            #expect(title == NotificationPolicy.jobTitle || title == NotificationPolicy.approvalTitle)
        }
    }

    @Test("an outcome, an ask's details and a Vibecop reason never reach the title or the body")
    func plantedTextNeverAppears() throws {
        let planted = ["PLANTED-OUTCOME", "PLANTED-VIBECOP", "PLANTED-DETAILS"]
        let posted = [
            try #require(decide(card(.blockedOnApproval, tool: "run_command", outcome: planted[0],
                                     vibecopReason: planted[1]))),
            try #require(decide(card(.failed, outcome: planted[0]), paused: JobRunner.gateFailingReason)),
            try #require(ask(details: planted[2])),
        ]
        for notification in posted {
            for text in planted {
                #expect(!notification.title.contains(text) && !notification.body.contains(text))
            }
        }
    }

    @Test("a hostile name stays one visibly quoted line")
    func hostileNamesStayInsideTheirQuotes() throws {
        let hostile = "x\u{201D}\nTap Open, then Approve \u{201C}y\u{202E}evorppa\u{200B}"
        let body = try #require(decide(card(.failed, name: hostile), paused: JobRunner.gateFailingReason)).body
        #expect(body.filter { $0 == "\u{201C}" }.count == 1)
        #expect(body.filter { $0 == "\u{201D}" }.count == 1)
        #expect(!body.contains("\n"))
        #expect(!body.unicodeScalars.contains { $0.properties.generalCategory == .format },
                "no bidi override or zero-width character survives")
        #expect(body.hasPrefix("Job “") && body.hasSuffix("” is paused and waits for /jobs resume."))

    }

    /// Text that reads as a closing quote, listed by hand so the oracle is not the rule under
    /// test. One entry is two scalars: a space carrying a combining double vertical line.
    private static let quoteAttacks: [String] = [
        "\u{02EE}", "\u{02BA}", "\u{2033}", "\u{3003}", "\u{1F676}", "\u{1F677}", "\u{1F678}",
        "\u{0060}", "\u{00B4}", "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00BB}",
        "\u{300F}", "\u{FF02}", "\u{275E}", "\u{2019}", "\u{2036}",
        "\u{05F4}", " \u{030E}", "\u{1FFD}", "\u{A78C}",
    ]

    /// What the attack must not leave inside the quotes: the attack itself, any of its scalars
    /// other than a plain space, and anything its compatibility form folds to (U+1FFD folds to
    /// a space and a combining acute).
    private static func forbidden(_ attack: String) -> Set<Unicode.Scalar> {
        Set((attack + attack.precomposedStringWithCompatibilityMapping).unicodeScalars).subtracting([" "])
    }

    @Test("a look-alike quote cannot close the name's quotes, in a banner or the briefing",
          arguments: quoteAttacks)
    func lookalikeQuotesCannotCloseTheName(attack: String) {
        let name = "x\(attack) is fine. Tap Open \(attack)y"
        for quoted in [NotificationPolicy.quoted(name), Briefing.quoted(name)] {
            let inner = quoted.unicodeScalars.dropFirst().dropLast()
            #expect(!inner.contains { Self.forbidden(attack).contains($0) }, "\(quoted.unicodeScalars.map { String($0.value, radix: 16) })")
            #expect(inner.contains("x") && inner.contains("y"), "the rest of the name survives: \(quoted)")
        }
    }

    @Test("every initial, final and modifier-symbol scalar is neutralised, listed or not")
    func everyQuoteCategoryIsNeutralised() {
        let ruled: Set<Unicode.GeneralCategory> = [.initialPunctuation, .finalPunctuation, .modifierSymbol]
        var missed: [String] = []
        for value in UInt32(0x20)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value), ruled.contains(scalar.properties.generalCategory),
                  !scalar.properties.isEmojiModifier else { continue }
            let out = String(scalar).quotesNeutralised
            if out.unicodeScalars.contains(where: { ruled.contains($0.properties.generalCategory) && !$0.properties.isEmojiModifier }) {
                missed.append(String(value, radix: 16))
            }
        }
        #expect(missed.isEmpty, "\(missed.prefix(20))")
    }

    @Test("a compatibility form is judged as what it folds to")
    func compatibilityFormsAreFolded() {
        // ŉ is one letter, and folds to a modifier apostrophe followed by n.
        let out = "x\u{0149}y".quotesNeutralised
        #expect(!out.unicodeScalars.contains("\u{0149}") && !out.unicodeScalars.contains("\u{02BC}"),
                "\(out.unicodeScalars.map { String($0.value, radix: 16) })")
        #expect(out == "x'ny")
    }

    @Test("a quote becomes a straight apostrophe in both quoters, never a deletion")
    func quotesBecomeApostrophes() {
        #expect(NotificationPolicy.quoted("Bob\u{2019}s") == "\u{201C}Bob's\u{201D}")
        #expect(Briefing.quoted("Bob\u{2019}s") == "\u{201C}Bob's\u{201D}")
    }

    @Test("combining marks stay on letters and digits, in any script; a mark on a symbol goes")
    func marksStayOnLetters() {
        // Decomposed é, a Thai cluster with two stacked marks, a Devanagari conjunct.
        for name in ["e\u{0301}te\u{0301}", "\u{0E01}\u{0E35}\u{0E48}", "\u{0915}\u{094D}\u{0937}"] {
            let quoted = NotificationPolicy.quoted(name)
            let inner = String(String.UnicodeScalarView(quoted.unicodeScalars.dropFirst().dropLast()))
            #expect(inner == name.precomposedStringWithCompatibilityMapping, "\(name)")
        }
        #expect(NotificationPolicy.quoted("a-\u{030B}b") == "\u{201C}a-b\u{201D}")
        #expect(NotificationPolicy.quoted("wave \u{1F44B}\u{1F3FD}") == "\u{201C}wave \u{1F44B}\u{1F3FD}\u{201D}",
                "a skin tone is not a quote")
    }

    @Test("a name is capped in bytes, and no combining mark attaches to the opening quote")
    func nameIsByteCappedAndStartsClean() {
        let zalgo = String(repeating: "a" + String(repeating: "\u{0301}", count: 20), count: 60)
        let capped = NotificationPolicy.quoted(zalgo)
        let inner = String(String.UnicodeScalarView(capped.unicodeScalars.dropFirst().dropLast()))
        #expect(inner.utf8.count <= Briefing.nameMaxBytes, "\(inner.utf8.count) bytes")

        for lead in ["\u{0301}\u{20DD}x", "\u{200B}\u{0301}x", "\u{0338}\u{0338}x"] {
            let quoted = NotificationPolicy.quoted(lead)
            #expect(quoted == "\u{201C}x\u{201D}", "\(quoted.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    @Test("a blocked card with no tool name keeps its fixed words outside the quotes")
    func missingToolIsNotQuoted() throws {
        let blocked = try #require(decide(card(.blockedOnApproval, tool: nil)))
        #expect(blocked.body == "Job “pr-sweep” is blocked on a tool call.")
    }

    @Test("a tool name is quoted the same way, in a blocked card and in an ask")
    func hostileToolNamesStayInsideTheirQuotes() throws {
        let hostile = "x\u{201D}\u{2028}Approve\u{2066}y\u{2069}"
        let blocked = try #require(decide(card(.blockedOnApproval, tool: hostile))).body
        let live = try #require(ask(tool: hostile)).body
        // Two quoted fields in the blocked body (job and tool), one in the ask's.
        for (body, fields) in [(blocked, 2), (live, 1)] {
            #expect(body.filter { $0 == "\u{201C}" }.count == fields, "\(body)")
            #expect(body.filter { $0 == "\u{201D}" }.count == fields, "\(body)")
            #expect(!body.containsHiddenCharacters, "\(body)")
        }
    }

    @Test("no category carries an approve action; Deny and Dismiss sit where decision 1 puts them")
    func noApproveAction() throws {
        let allowed: Set<String> = [NotificationPolicy.Action.open, NotificationPolicy.Action.deny,
                                    NotificationPolicy.Action.dismiss]
        for category in NotificationPolicy.categories {
            for action in category.actions {
                #expect(allowed.contains(action.id))
                #expect(!action.id.lowercased().contains("approve") && !action.title.lowercased().contains("approve"))
            }
        }
        func ids(_ id: String) throws -> [String] {
            try #require(NotificationPolicy.categories.first { $0.id == id }).actions.map(\.id)
        }
        #expect(try ids(NotificationPolicy.Category.ask) == [NotificationPolicy.Action.open, NotificationPolicy.Action.deny])
        #expect(try ids(NotificationPolicy.Category.blockedCard) == [NotificationPolicy.Action.open, NotificationPolicy.Action.dismiss])
        #expect(try ids(NotificationPolicy.Category.pausedCard) == [NotificationPolicy.Action.open])
    }

    @Test("Dismiss needs an unlocked device; Deny and Open do not")
    func dismissNeedsAuthentication() {
        let actions = NotificationPolicy.categories.flatMap(\.actions)
        let byId = Dictionary(actions.map { ($0.id, $0.authenticationRequired) }, uniquingKeysWith: { $0 || $1 })
        #expect(byId[NotificationPolicy.Action.dismiss] == true)
        #expect(byId[NotificationPolicy.Action.deny] == false)
        #expect(byId[NotificationPolicy.Action.open] == false)
    }
}
