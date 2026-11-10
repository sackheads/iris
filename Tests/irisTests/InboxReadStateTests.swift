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

    @Test("his own answer does not unread the item; an automatic answer does (#1033 review)")
    func ownAnswerIsRead() throws {
        let s = try ConversationStore.inMemory()
        let hand = item(), auto = item(), viaRecord = item()
        for it in [hand, auto, viaRecord] { try s.inbox.createItem(it, question: "S") }
        let at = Date(timeIntervalSince1970: 5_000)
        try s.inbox.submitAnswer(itemId: hand.id, answer: InboxAnswer(chosenOptionId: nil, freeText: "ok", at: at),
                                 pendingTargets: ["dev-1"])
        try s.inbox.submitAnswer(itemId: auto.id, answer: InboxAnswer(chosenOptionId: nil, freeText: "d", at: at, automatic: true),
                                 pendingTargets: [])
        try s.inbox.recordAnswer(itemId: viaRecord.id, answer: InboxAnswer(chosenOptionId: nil, freeText: "ok", at: at))
        #expect(!(try #require(try s.inbox.item(id: hand.id))).isUnread)
        #expect(!(try #require(try s.inbox.item(id: viaRecord.id))).isUnread)
        #expect((try #require(try s.inbox.item(id: auto.id))).isUnread)
    }

    @Test("an item already read, then answered by hand, stays read")
    func readThenAnswered() throws {
        let s = try ConversationStore.inMemory()
        let it = item()
        try s.inbox.createItem(it, question: "S")
        try s.inbox.markViewed(itemId: it.id, at: Date(timeIntervalSince1970: 2_000))
        try s.inbox.submitAnswer(itemId: it.id, answer: InboxAnswer(chosenOptionId: nil, freeText: "ok", at: Date(timeIntervalSince1970: 3_000)),
                                 pendingTargets: [])
        #expect(!(try #require(try s.inbox.item(id: it.id))).isUnread)
    }

    @Test("the divider probe takes only a two-pane split view it is the first pane of, never an outer one (#1033 review)")
    @MainActor func probeIgnoresTheOuterSplit() {
        func pair() -> NSSplitView {
            let v = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            v.isVertical = true
            v.addArrangedSubview(NSView()); v.addArrangedSubview(NSView())
            return v
        }
        let outer = pair()
        let inner = pair()
        // The inbox sits in the outer split's detail pane, with its own split inside.
        outer.arrangedSubviews[1].addSubview(inner)
        let probe = NSView()
        inner.arrangedSubviews[0].addSubview(probe)
        #expect(SplitDividerPersistence.ownSplitView(of: probe) === inner)

        // No inner split of its own: the walk reaches the outer one, where the probe is the detail pane.
        let bare = NSView()
        outer.arrangedSubviews[1].addSubview(bare)
        #expect(SplitDividerPersistence.ownSplitView(of: bare) == nil, "the main window's split view must not be taken")

        // First pane of a split with a third pane is not the inbox's two-pane split either.
        let three = pair(); three.addArrangedSubview(NSView())
        let p3 = NSView(); three.arrangedSubviews[0].addSubview(p3)
        #expect(SplitDividerPersistence.ownSplitView(of: p3) == nil)
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

        let first = SplitDividerPersister(store: store, key: "w", minimum: 100, isUserDrag: { _ in true })
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

    @Test("restoring into a split view too narrow for the saved width does not overwrite the saved width")
    @MainActor func narrowRestoreKeepsSavedWidth() {
        let name = "iris-split-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        store.set(800.0, forKey: "w")
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        split.isVertical = true
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.layoutSubtreeIfNeeded()
        let persister = SplitDividerPersister(store: store, key: "w", minimum: 100)
        persister.attach(to: split)
        #expect(persister.savedWidth == 800, "the clamp to the window is the restore's, not a drag to save")
    }

    private func suite() -> (UserDefaults, () -> Void) {
        let name = "iris-split-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (store, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    @MainActor private func split(width: CGFloat) -> NSSplitView {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        split.isVertical = true
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.layoutSubtreeIfNeeded()
        return split
    }

    @Test("a split view that is not laid out yet is tried again, and restored once it has a width (#1033 review)")
    @MainActor func notReadyIsRetried() {
        let (store, cleanup) = suite(); defer { cleanup() }
        store.set(300.0, forKey: "w")
        let persister = SplitDividerPersister(store: store, key: "w", minimum: 100, isUserDrag: { _ in false })
        let view = split(width: 0)
        persister.attach(to: view)            // no width yet: nothing to restore into
        view.setFrameSize(NSSize(width: 900, height: 400))
        view.layoutSubtreeIfNeeded()
        persister.attach(to: view)            // the next layout tries again
        #expect(abs(view.arrangedSubviews[0].frame.width - 300) < 2)
    }

    @Test("the second pane keeps its minimum when the window is narrower than when the width was saved (#1033 review)")
    @MainActor func secondPaneKeepsItsMinimum() {
        let (store, cleanup) = suite(); defer { cleanup() }
        store.set(800.0, forKey: "w")
        let persister = SplitDividerPersister(store: store, key: "w", minimum: 100, secondPaneMinimum: 320)
        let view = split(width: 700)
        persister.attach(to: view)
        #expect(view.arrangedSubviews[1].frame.width >= 319, "the detail must not collapse")
        #expect(persister.savedWidth == 800, "and the saved width is still the one that was dragged")
    }

    @Test("a resize that is not the person dragging the divider is not saved (#1033 review)")
    @MainActor func windowResizeIsNotSaved() {
        let (store, cleanup) = suite(); defer { cleanup() }
        let notDragging = SplitDividerPersister(store: store, key: "w", minimum: 100, isUserDrag: { _ in false })
        let view = split(width: 900)
        notDragging.attach(to: view)
        view.setPosition(444, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: view)
        #expect(notDragging.savedWidth == nil)

        let dragging = SplitDividerPersister(store: store, key: "w2", minimum: 100, isUserDrag: { _ in true })
        let other = split(width: 900)
        dragging.attach(to: other)
        other.setPosition(444, ofDividerAt: 0)
        other.layoutSubtreeIfNeeded()
        #expect(dragging.savedWidth.map { abs($0 - 444) < 2 } == true)
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
