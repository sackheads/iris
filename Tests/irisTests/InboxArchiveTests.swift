import Testing
import Foundation
import GRDB
@testable import IrisKit

/// #920 slice 2: an answered item stays in the mailbox until Brian archives it, and the Archive view shows what he
/// put away. `archivedAt` is a visibility flag beside `state`, never a state: archiving keeps the answer and the
/// lifecycle, and a follow-up (which reopens the thread) brings it back.
@Suite("Inbox archive (#920 slice 2)")
struct InboxArchiveTests {
    private func item(_ threadId: String, mode: InboxResponseMode = .optionsAndFreeform, at: Date = Date(timeIntervalSince1970: 1_000)) -> InboxItem {
        InboxItem(id: UUID().uuidString, threadId: threadId, ownerChain: "dev-1", emitter: UUID(), emitterLabel: "dev-1",
                  title: "Ship it?", situation: "Context.",
                  options: [InboxOption(id: "a", label: "Ship", pros: [], cons: [])],
                  responseMode: mode, routeBack: [], notify: [], deadline: nil, vetoDefaultOptionId: nil,
                  emitterTainted: false, state: .open, createdAt: at, lastActivityAt: at, answer: nil)
    }

    private func answered(_ s: ConversationStore, _ threadId: String) throws -> InboxItem {
        let it = item(threadId)
        try s.inbox.createItem(it, question: "Context.")
        try s.inbox.recordAnswer(itemId: it.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date(timeIntervalSince1970: 2_000)))
        return try #require(try s.inbox.item(id: it.id))
    }

    @Test("an answered item stays listed until archived; archiving moves it to the Archive view, unarchiving brings it back")
    func archiveAndUnarchive() throws {
        let s = try ConversationStore.inMemory()
        let it = try answered(s, "t-1")
        #expect(it.state == .answered && it.archivedAt == nil)
        #expect(try s.inbox.settledItems().map(\.id) == [it.id], "answered stays in the mailbox")
        #expect(try s.inbox.setArchived(itemId: it.id, true, at: Date(timeIntervalSince1970: 3_000)) == .success(()))
        let archived = try #require(try s.inbox.item(id: it.id))
        #expect(archived.archivedAt == Date(timeIntervalSince1970: 3_000))
        #expect(archived.state == .answered && archived.answer?.chosenOptionId == "a", "archiving keeps the state and the answer")
        #expect(try s.inbox.settledItems().isEmpty)
        #expect(try s.inbox.archivedItems().map(\.id) == [it.id])
        #expect(try s.inbox.setArchived(itemId: it.id, false, at: Date()) == .success(()))
        #expect(try #require(try s.inbox.item(id: it.id)).archivedAt == nil, "unarchive clears it")
        #expect(try s.inbox.settledItems().map(\.id) == [it.id])
        #expect(try s.inbox.archivedItems().isEmpty)
    }

    @Test("an item still owed an answer, or still being delivered, can't be archived; an unknown id is refused")
    func notArchivable() throws {
        let s = try ConversationStore.inMemory()
        let open = item("t-open")
        try s.inbox.createItem(open, question: "Context.")
        #expect(try s.inbox.setArchived(itemId: open.id, true, at: Date()) == .failure(.notArchivable))
        let waiting = item("t-wait")
        try s.inbox.createItem(waiting, question: "Context.")
        _ = try s.inbox.submitAnswer(itemId: waiting.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()),
                                     pendingTargets: ["role:planner"])
        #expect(try #require(try s.inbox.item(id: waiting.id)).state == .awaitingDelivery)
        #expect(try s.inbox.setArchived(itemId: waiting.id, true, at: Date()) == .failure(.notArchivable))
        #expect(try s.inbox.archivedItems().isEmpty)
        #expect(try s.inbox.setArchived(itemId: "nope", true, at: Date()) == .failure(.unknownItem))
    }

    @Test("an answer arriving on an archived item leaves it archived")
    func answerKeepsItArchived() throws {
        let s = try ConversationStore.inMemory()
        let it = item("t-stale")
        try s.inbox.createItem(it, question: "Context.")
        try s.inbox.setState(itemId: it.id, .stale)
        #expect(try s.inbox.setArchived(itemId: it.id, true, at: Date(timeIntervalSince1970: 3_000)) == .success(()))
        // A stale item is still answerable; answering it is not a reopening.
        #expect(try s.inbox.submitAnswer(itemId: it.id, answer: InboxAnswer(chosenOptionId: "a", freeText: nil, at: Date()),
                                         pendingTargets: []) == .success(()))
        let after = try #require(try s.inbox.item(id: it.id))
        #expect(after.state == .answered)
        #expect(after.archivedAt == Date(timeIntervalSince1970: 3_000), "the answer did not un-archive it")
        #expect(try s.inbox.settledItems().isEmpty)
    }

    @Test("a follow-up reopens the thread and brings it out of the archive")
    func followupUnarchives() throws {
        let s = try ConversationStore.inMemory()
        let it = try answered(s, "t-1")
        try s.inbox.setArchived(itemId: it.id, true, at: Date(timeIntervalSince1970: 3_000))
        let result = try s.inbox.appendFollowup(threadId: "t-1", fromChain: "dev-1", author: "dev-1", body: "One more thing",
                                                at: Date(timeIntervalSince1970: 4_000))
        #expect(result == .success(InboxFollowupResult(itemId: it.id)))
        let after = try #require(try s.inbox.item(id: it.id))
        #expect(after.state == .open && after.archivedAt == nil)
        #expect(try s.inbox.openItems().map(\.id) == [it.id])
        #expect(try s.inbox.archivedItems().isEmpty)
    }

    @Test("the mailbox list: open, then awaiting delivery, then settled; Archive is offered only where nothing is owed")
    func listComposition() {
        let open = item("o"), waiting = { var i = item("w"); i.state = .awaitingDelivery; return i }()
        let done = { var i = item("d"); i.state = .answered; return i }()
        #expect(InboxUIModel.mailboxItems(open: [open], awaitingDelivery: [waiting], settled: [done]).map(\.threadId) == ["o", "w", "d"])
        #expect(!InboxUIModel.canArchive(open))
        #expect(!InboxUIModel.canArchive(waiting))
        #expect(InboxUIModel.canArchive(done))
        var put = done; put.archivedAt = Date()
        #expect(!InboxUIModel.canArchive(put), "already archived: Unarchive instead")
        var closed = item("c"); closed.state = .closed
        #expect(InboxUIModel.canArchive(closed))
    }

    @Test("a database from before the column opens, its rows load, and none is archived (Invariant 1)")
    func preSliceDatabase() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-inbox-v46-\(UUID().uuidString)")
        let url = root.appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let queue = try DatabaseQueue(path: url.path)
            try ConversationStore.migrator.migrate(queue, upTo: "v46_has_peer_input")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO inbox_items (id, threadId, ownerChain, emitter, emitterLabel, title, situation,
                        optionsJSON, responseMode, routeBackJSON, notifyJSON, emitterTainted, state, createdAt, lastActivityAt, answerJSON)
                    VALUES ('old', 't-old', 'dev-1', ?, 'dev-1', 'Old', 'S', '[]', 'freeform', '[]', '[]', 0, 'answered', ?, ?, ?)
                    """, arguments: [UUID().uuidString, Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 1_000),
                                     String(decoding: try JSONEncoder().encode(InboxAnswer(chosenOptionId: nil, freeText: "ok", at: Date())), as: UTF8.self)])
            }
            try queue.close()
        }
        let store = try ConversationStore.onDisk(at: url)
        let old = try #require(try store.inbox.item(id: "old"))
        #expect(old.archivedAt == nil)
        #expect(old.state == .answered && old.answer?.freeText == "ok")
        #expect(try store.inbox.settledItems().map(\.id) == ["old"], "an answered item from before the column is listed, not lost")
        #expect(try store.inbox.setArchived(itemId: "old", true, at: Date()) == .success(()), "and can be archived after migrating")
    }

    @Test("the badge still counts open items only: answered and archived ones don't add to it")
    func badgeCountsOpen() throws {
        let s = try ConversationStore.inMemory()
        let done = try answered(s, "t-1")
        try s.inbox.setArchived(itemId: done.id, true, at: Date())
        _ = try answered(s, "t-2")
        try s.inbox.createItem(item("t-3"), question: "Context.")
        #expect(try s.inbox.openItems().count == 1, "AppState.inboxBadgeCount is openItems().count")
    }
}
