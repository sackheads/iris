import Testing
import Foundation
@testable import IrisKit

/// #920 slice 3 (planner ruling F5): an open item is marked stale when the chain that raised it is gone
/// and nothing has happened on it for `IrisEngine.inboxStaleAfter` (7 days). A live sender's unanswered
/// item is pending, not stale. A stale item stays in the list for Brian, out of the open-items badge,
/// and is still answerable; a followup from its owner reopens it.
@MainActor
@Suite("Inbox stale sweep (#920 slice 3)", .timeLimit(.minutes(1)))
struct InboxStaleTests {
    private let now = Date()
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @discardableResult
    private func raise(_ app: AppState, chain: String, quietFor days: Double, threadId: String = UUID().uuidString) throws -> InboxItem {
        let at = daysAgo(days)
        let item = InboxItem(id: UUID().uuidString, threadId: threadId, ownerChain: chain, emitter: UUID(), emitterLabel: "s",
                             title: "t", situation: "s", options: [InboxOption(id: "a", label: "A", pros: [], cons: [])],
                             responseMode: .optionsAndFreeform, routeBack: [], notify: [], deadline: nil, vetoDefaultOptionId: nil,
                             emitterTainted: false, state: .open, createdAt: at, lastActivityAt: at, answer: nil)
        guard case .success(let created) = try app.store.inbox.createItem(item, question: "q") else {
            Issue.record("createItem failed"); return item
        }
        return created
    }

    private func engine(_ app: AppState) -> IrisEngine {
        IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []), retryDelays: [], sessionPeerCount: 0)
    }

    private func state(_ app: AppState, _ item: InboxItem) throws -> InboxItemState? { try app.store.inbox.item(id: item.id)?.state }

    @Test("a deleted or archived sender's item, quiet for 8 days, is marked stale, and the thread says why")
    func goneSenderGoesStale() async throws {
        let app = AppState(); app.conversations.removeAll()
        let archived = app.createNewConversation(select: false)
        if let i = app.conversations.firstIndex(where: { $0.id == archived }) { app.conversations[i].isArchived = true }
        let deleted = try raise(app, chain: UUID().uuidString, quietFor: 8)
        let ofArchived = try raise(app, chain: archived.uuidString, quietFor: 8)

        #expect(await engine(app).evaluateInboxStaleness(now: now) == 2)
        #expect(try state(app, deleted) == .stale)
        #expect(try state(app, ofArchived) == .stale)
        #expect(try app.store.inbox.thread(itemId: deleted.id).last?.kind == "stale")
    }

    @Test("a gone sender quiet for only 6 days, and a live sender quiet for 30, stay open")
    func notYetOrNotGone() async throws {
        let app = AppState(); app.conversations.removeAll()
        let live = app.createNewConversation(select: false)
        let recent = try raise(app, chain: UUID().uuidString, quietFor: 6)
        let pending = try raise(app, chain: live.uuidString, quietFor: 30)

        #expect(await engine(app).evaluateInboxStaleness(now: now) == 0)
        #expect(try state(app, recent) == .open)
        #expect(try state(app, pending) == .open, "a live sender's unanswered item is pending, not stale")
    }

    @Test("a role chain is gone only when nobody holds the role")
    func roleChainNeedsNoHolder() async throws {
        let app = AppState(); app.conversations.removeAll()
        let holder = app.createNewConversation(select: false)
        if let i = app.conversations.firstIndex(where: { $0.id == holder }) { app.conversations[i].role = "planner" }
        let held = try raise(app, chain: "planner", quietFor: 30)
        let orphaned = try raise(app, chain: "reviewer", quietFor: 30)

        #expect(await engine(app).evaluateInboxStaleness(now: now) == 1)
        #expect(try state(app, held) == .open, "the role moved on but has a holder")
        #expect(try state(app, orphaned) == .stale)
    }

    @Test("a job chain is never marked here; slice 1b decides when a job is gone")
    func jobChainIsLeftAlone() async throws {
        let app = AppState(); app.conversations.removeAll()
        let item = try raise(app, chain: "job:\(UUID().uuidString)", quietFor: 30)
        #expect(await engine(app).evaluateInboxStaleness(now: now) == 0)
        #expect(try state(app, item) == .open)
    }

    @Test("a followup that lands after the sweep read the item wins: it is not marked")
    func activitySinceTheReadWins() throws {
        let store = try ConversationStore.inMemory()
        let at = daysAgo(8)
        let item = InboxItem(id: UUID().uuidString, threadId: "t-race", ownerChain: "gone", emitter: UUID(), emitterLabel: "s",
                             title: "t", situation: "s", options: [], responseMode: .freeform, routeBack: [], notify: [],
                             deadline: nil, vetoDefaultOptionId: nil, emitterTainted: false, state: .open,
                             createdAt: at, lastActivityAt: at, answer: nil)
        _ = try store.inbox.createItem(item, question: "q")
        _ = try store.inbox.appendFollowup(threadId: "t-race", fromChain: "gone", author: "gone", body: "still here", at: now)
        #expect(try store.inbox.markStale(itemId: item.id, quietSince: daysAgo(7), at: now) == false)
        #expect(try store.inbox.item(id: item.id)?.state == .open)
    }

    @Test("a stale item stays in the list, leaves the badge, can be answered, and its owner's followup reopens it")
    func staleItemStaysUsable() async throws {
        let app = AppState(); app.conversations.removeAll()
        let answerable = try raise(app, chain: "gone-a", quietFor: 8, threadId: "t-a")
        let reopenable = try raise(app, chain: "gone-b", quietFor: 8, threadId: "t-b")
        await engine(app).evaluateInboxStaleness(now: now)

        let listed = InboxUIModel.mailboxItems(open: try app.store.inbox.openItems(), stale: try app.store.inbox.staleItems(),
                                               awaitingDelivery: try app.store.inbox.awaitingDeliveryItems()).map(\.id)
        #expect(Set(listed) == [answerable.id, reopenable.id])
        #expect(app.inboxBadgeCount == 0, "the badge counts open items (Brian, F1)")

        let answered = try app.store.inbox.submitAnswer(itemId: answerable.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: now),
                                                        pendingTargets: [])
        guard case .success = answered else { Issue.record("a stale item refused an answer: \(answered)"); return }
        #expect(try app.store.inbox.appendFollowup(threadId: "t-b", fromChain: "gone-b", author: "b", body: "back", at: now)
                == .success(InboxFollowupResult(itemId: reopenable.id)))
        #expect(try state(app, reopenable) == .open)
    }

    @Test("a failed or partial load marks nothing it could not read as gone (dev-2's #1375 review)")
    func loadFailureMarksNothing() {
        let dropped = UUID()
        let chains = [UUID().uuidString, dropped.uuidString, "reviewer"]
        // A store that failed to load reads as no conversations at all: without the guard, every chain looks gone.
        #expect(IrisEngine.goneInboxChains(chains, in: [], loadFailed: true, unloaded: []).isEmpty)
        // A conversation the load dropped (#163) is not gone; the others are judged as usual.
        let gone = IrisEngine.goneInboxChains(chains, in: [], loadFailed: false, unloaded: [dropped])
        #expect(gone == [chains[0], "reviewer"])
    }

    @Test("the gone-chain rule, by shape")
    func chainGoneTable() {
        let live = Conversation(title: "live")
        var archived = Conversation(title: "archived"); archived.isArchived = true
        var roleHolder = Conversation(title: "holder"); roleHolder.role = "planner"
        let all = [live, archived, roleHolder]
        #expect(!IrisEngine.inboxChainGone(live.id.uuidString, in: all))
        #expect(IrisEngine.inboxChainGone(archived.id.uuidString, in: all))
        #expect(IrisEngine.inboxChainGone(UUID().uuidString, in: all))
        #expect(!IrisEngine.inboxChainGone("planner", in: all))
        #expect(IrisEngine.inboxChainGone("reviewer", in: all))
        #expect(!IrisEngine.inboxChainGone("job:\(UUID().uuidString)", in: all))
    }
}
