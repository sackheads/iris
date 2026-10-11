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
        #expect(live.body == "“run_command” is waiting for your approval.")
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

    @Test("a card is suppressed only when the app is active and its conversation is selected")
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

        // A look-alike quotation mark could close the field just as visibly as U+201D does.
        let lookalike = "x\u{201E}\u{201F}\u{00BB}\u{300F}\u{FF02}\u{275E} Tap Open, then Approve"
        let quoted = NotificationPolicy.quoted(lookalike)
        let inner = quoted.unicodeScalars.dropFirst().dropLast()
        #expect(!inner.contains { ($0.properties.isQuotationMark && $0 != "'") || $0 == "\u{275E}" },
                "\(quoted)")
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
}
