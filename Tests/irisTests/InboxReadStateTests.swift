import Testing
import Foundation
import AppKit
@testable import IrisKit

/// #1027: read/unread, the "from" name, and the remembered divider.
@Suite("Inbox read state, sender name and divider (#1027)")
struct InboxReadStateTests {
    private func item(label: String = "dev-1", emitter: UUID = UUID(), at: Date = Date(timeIntervalSince1970: 1_000)) -> InboxItem {
        InboxItem(id: UUID().uuidString, threadId: "t-\(UUID().uuidString.prefix(6))", ownerChain: "dev-1", emitter: emitter,
                  emitterLabel: label, title: "T", situation: "S", options: [], responseMode: .freeform,
                  routeBack: [], notify: [], deadline: nil, vetoDefaultOptionId: nil, emitterTainted: false,
                  state: .open, createdAt: at, lastActivityAt: at, answer: nil)
    }

    @Test("a new item is unread; opening it reads it; the read leaves lastActivityAt alone")
    func openingReadsIt() throws {
        let s = try ConversationStore.inMemory()
        let it = item()
        try s.inbox.createItem(it, question: "S")
        #expect(try #require(try s.inbox.item(id: it.id)).isUnread)

        try s.inbox.markViewed(itemId: it.id, at: Date(timeIntervalSince1970: 2_000))
        let read = try #require(try s.inbox.item(id: it.id))
        #expect(!read.isUnread)
        #expect(read.lastActivityAt == it.lastActivityAt, "reading must not reorder the list")
    }

    @Test("a follow-up after it was read makes it unread again, independent of its open/answered state")
    func followupUnreads() throws {
        let s = try ConversationStore.inMemory()
        let it = item()
        try s.inbox.createItem(it, question: "S")
        try s.inbox.markViewed(itemId: it.id, at: Date(timeIntervalSince1970: 2_000))
        _ = try s.inbox.appendFollowup(threadId: it.threadId, fromChain: "dev-1", author: "x", body: "again",
                                       at: Date(timeIntervalSince1970: 3_000))
        let after = try #require(try s.inbox.item(id: it.id))
        #expect(after.state == .open && after.isUnread)
    }

    @Test("a row from before the column existed reads as never viewed")
    func legacyRowIsUnread() throws {
        let s = try ConversationStore.inMemory()
        try s.inbox.rawInsertForTesting(id: "old", threadId: "t-old")
        #expect(try #require(try s.inbox.item(id: "old")).viewedAt == nil)
        #expect(try #require(try s.inbox.item(id: "old")).isUnread)
    }

    @Test("marking a read item again writes nothing")
    func markingTwiceIsANoOp() throws {
        let s = try ConversationStore.inMemory()
        let it = item()
        try s.inbox.createItem(it, question: "S")
        try s.inbox.markViewed(itemId: it.id, at: Date(timeIntervalSince1970: 2_000))
        try s.inbox.markViewed(itemId: it.id, at: Date(timeIntervalSince1970: 9_000))
        #expect(try #require(try s.inbox.item(id: it.id)).viewedAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test("an item whose stored label is the session's bare UUID shows the conversation title, else a short id")
    func uuidLabelFallsBack() {
        let id = UUID()
        let legacy = item(label: id.uuidString, emitter: id)
        #expect(InboxUIModel.senderName(of: legacy, conversationTitle: "Inbox Smoke Test") == "Inbox Smoke Test")
        #expect(InboxUIModel.senderName(of: legacy, conversationTitle: Conversation.defaultTitle) == InboxUIModel.shortId(id))
        #expect(InboxUIModel.senderName(of: legacy, conversationTitle: nil) == InboxUIModel.shortId(id))
        #expect(InboxUIModel.shortId(id).count == 8)
        #expect(InboxUIModel.senderName(of: item(label: "inbox tester"), conversationTitle: "ignored") == "inbox tester",
                "a stored name is shown as stored")
    }

    @Test("a new item is raised under card name, then role, then title, then short id: never the full UUID")
    @MainActor func emitterLabelOrder() {
        var c = Conversation(id: UUID(), title: Conversation.defaultTitle)
        #expect(AppState.inboxEmitterLabel(for: c) == InboxUIModel.shortId(c.id))
        c.title = "Smoke test"
        #expect(AppState.inboxEmitterLabel(for: c) == "Smoke test")
        c.role = "dev-1"
        #expect(AppState.inboxEmitterLabel(for: c) == "dev-1")
        c.sessionCard = SessionCard(name: "inbox tester", description: "x")
        #expect(AppState.inboxEmitterLabel(for: c) == "inbox tester")
    }

    @Test("the saved first-pane width is restored onto a new split view and re-saved when dragged")
    @MainActor func dividerRoundTrips() throws {
        let name = "iris-split-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        func makeSplit() -> NSSplitView {
            let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            split.isVertical = true
            split.addArrangedSubview(NSView())
            split.addArrangedSubview(NSView())
            split.layoutSubtreeIfNeeded()
            return split
        }

        let first = SplitDividerPersister(store: store, key: "w", minimum: 100)
        #expect(first.savedWidth == nil)
        let a = makeSplit()
        first.attach(to: a)
        a.setPosition(430, ofDividerAt: 0)
        a.layoutSubtreeIfNeeded()
        #expect(first.savedWidth.map { abs($0 - 430) < 2 } == true, "a drag is saved")

        // The pane is rebuilt: a fresh persister over the same store puts the divider back.
        let second = SplitDividerPersister(store: store, key: "w", minimum: 100)
        let b = makeSplit()
        second.attach(to: b)
        #expect(abs(b.arrangedSubviews[0].frame.width - 430) < 2)
    }

    @Test("an unusable saved width is ignored")
    @MainActor func junkWidthIgnored() {
        let name = "iris-split-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        store.set(3.0, forKey: "w")
        #expect(SplitDividerPersister(store: store, key: "w", minimum: 100).savedWidth == nil)
        store.set("wide", forKey: "w")
        #expect(SplitDividerPersister(store: store, key: "w", minimum: 100).savedWidth == nil)
    }
}
