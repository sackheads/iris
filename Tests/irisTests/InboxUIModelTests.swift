import Testing
import Foundation
@testable import IrisKit

/// #920 Task 5: the mailbox UI's pure view-model logic — selection separation, the badge count,
/// response-mode affordances and overdue display — kept free of SwiftUI so it is testable without
/// a view, the same split `SidebarOrdering` uses.
@MainActor
@Suite("Inbox UI model (#920)")
struct InboxUIModelTests {
    private func app() -> (AppState, UUID) {
        let app = AppState(); app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        return (app, id)
    }

    private func sampleItem(id: String = "a", responseMode: InboxResponseMode = .optionsAndFreeform,
                            state: InboxItemState = .open, deadline: Date? = nil, tainted: Bool = false,
                            routeBack: [String] = [], emitterLabel: String = "dev-1") -> InboxItem {
        InboxItem(id: id, threadId: "t-\(id)", ownerChain: "dev-1", emitter: UUID(), emitterLabel: emitterLabel,
                  title: "Ship it?", situation: "context", options: [], responseMode: responseMode,
                  routeBack: routeBack, notify: [], deadline: deadline, vetoDefaultOptionId: nil,
                  emitterTainted: tainted, state: state, createdAt: Date(), lastActivityAt: Date(), answer: nil)
    }

    @Test("the badge count equals the store's open-item count")
    func badgeCountIsOpenItems() throws {
        let (app, _) = app()
        #expect(app.inboxBadgeCount == 0)
        try app.store.inbox.createItem(sampleItem(id: "a"), question: "q")
        try app.store.inbox.createItem(sampleItem(id: "b"), question: "q")
        #expect(app.inboxBadgeCount == 2)
    }

    @Test("selecting the inbox leaves selectedConversationId nil and does not touch any conversation")
    func selectingInboxDoesNotSelectAConversation() throws {
        let (app, pinnedId) = app()
        let before = app.conversations.first { $0.id == pinnedId }
        app.selectConversation(pinnedId)
        #expect(app.selectedConversationId == pinnedId)
        #expect(app.inboxSelected == false)

        app.selectInbox()
        #expect(app.selectedConversationId == nil)
        #expect(app.inboxSelected == true)
        let after = app.conversations.first { $0.id == pinnedId }
        #expect(before?.updatedAt == after?.updatedAt, "selecting the inbox must not touch a conversation")
    }

    @Test("selecting a conversation exits inbox mode")
    func selectingAConversationExitsInbox() {
        let (app, id) = app()
        app.selectInbox()
        #expect(app.inboxSelected == true)
        app.selectConversation(id)
        #expect(app.inboxSelected == false)
        #expect(app.selectedConversationId == id)
    }

    @Test("each response mode maps to its own affordance", arguments: [
        (InboxResponseMode.optionsAndFreeform, InboxResponseAffordance.optionsAndFreeform),
        (.freeform, .freeformOnly),
        (.timedVeto, .timedVetoCountdown),
        (.notification, .dismissOnly),
    ])
    func responseAffordanceMatchesMode(mode: InboxResponseMode, affordance: InboxResponseAffordance) {
        #expect(mode.inboxAffordance == affordance)
    }

    @Test("a held (tainted, past-deadline) timed-veto item surfaces as overdue, not approved")
    func overdueTaintedVetoShown() {
        let past = Date().addingTimeInterval(-3600)
        let item = sampleItem(responseMode: .timedVeto, state: .open, deadline: past, tainted: true)
        #expect(InboxUIModel.isOverdue(item, now: Date()))
        #expect(item.state == .open, "overdue display must never itself resolve the item")
    }

    @Test("a timed-veto item before its deadline is not overdue")
    func notYetDueIsNotOverdue() {
        let future = Date().addingTimeInterval(3600)
        let item = sampleItem(responseMode: .timedVeto, state: .open, deadline: future, tainted: true)
        #expect(!InboxUIModel.isOverdue(item, now: Date()))
    }

    @Test("a non-timedVeto item is never overdue, whatever its deadline")
    func nonVetoNeverOverdue() {
        let past = Date().addingTimeInterval(-3600)
        let item = sampleItem(responseMode: .optionsAndFreeform, state: .open, deadline: past)
        #expect(!InboxUIModel.isOverdue(item, now: Date()))
    }

    @Test("an answered or closed item is never overdue, however late its deadline sits")
    func resolvedItemNeverOverdue() {
        let past = Date().addingTimeInterval(-3600)
        for state: InboxItemState in [.answered, .closed, .awaitingDelivery, .stale] {
            let item = sampleItem(responseMode: .timedVeto, state: state, deadline: past, tainted: true)
            #expect(!InboxUIModel.isOverdue(item, now: Date()), "\(state)")
        }
    }

    @Test("the mailbox list is open items, then awaiting-delivery ones, never dropped (#920 review finding 3)")
    func mailboxItemsIncludesAwaitingDelivery() {
        let open = [sampleItem(id: "a")]
        let awaiting = [sampleItem(id: "b", state: .awaitingDelivery)]
        #expect(InboxUIModel.mailboxItems(open: open, awaitingDelivery: awaiting).map(\.id) == ["a", "b"])
    }

    @Test("submitInboxAnswer bumps inboxRevision so the badge/list are not left stale (#920 review finding 2)")
    func submitInboxAnswerBumpsRevision() async throws {
        let (app, _) = app()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let item = sampleItem(id: "a")
        guard case .success(let created) = try app.store.inbox.createItem(item, question: "q") else {
            Issue.record("createItem failed"); return
        }
        let before = app.inboxRevision
        _ = await engine.submitInboxAnswer(itemId: created.id, choice: nil, freeText: "go ahead",
                                           deliver: { _, _, _ in .refused("test") })
        #expect(app.inboxRevision > before)
    }
}
