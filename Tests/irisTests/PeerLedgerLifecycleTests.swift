import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Peer ledger lifecycle", .timeLimit(.minutes(1)))
struct PeerLedgerLifecycleTests {
    private func open(_ app: AppState, _ id: String, from: UUID, to: UUID, at: Date = Date()) throws {
        try app.store.peers.insert(PeerMessageRecord(msgId: id, fromSession: from, toSession: to, contextId: "c",
                                                     inReplyTo: nil, depth: 1, firstLine: "x", sentAt: at,
                                                     expectsReply: true, closedAt: nil, closeReason: nil))
    }

    @Test("the awaiting-replies section lists open requests with name, id and age, capped at 5")
    func section() {
        let now = Date(timeIntervalSince1970: 10_000)
        let a = UUID()
        let recs = (0..<7).map { i in
            PeerMessageRecord(msgId: "aaaa000\(i)", fromSession: a, toSession: UUID(), contextId: "c", inReplyTo: nil,
                              depth: 1, firstLine: "x", sentAt: now.addingTimeInterval(-840), expectsReply: true,
                              closedAt: nil, closeReason: nil)
        }
        let names = Dictionary(uniqueKeysWithValues: recs.map { ($0.toSession, "worker-\"a\"") })
        let s = try! #require(IrisEngine.awaitingRepliesSection(recs, names: names, now: now))
        #expect(s.body.hasPrefix("Awaiting replies: \"worker-'a'\" (aaaa0000, 14m)"))
        #expect(s.body.hasSuffix("+2 more"))
        #expect(IrisEngine.awaitingRepliesSection([], names: [:], now: now) == nil)
    }

    /// The line this routes is lost if it only ever lands in the queue `enqueueEventLine` feeds:
    /// that queue drains only at the destination's next model round, so an idle sender — the
    /// common case, since nothing of its own is running — would never see it, and it would not
    /// survive a quit. Routed like `deliverEvent`/`deliverStoppedSubagentResult`: appended to the
    /// sender's transcript, then straight into its history because it is idle.
    @Test("archiving a target closes requests to it and tells each idle sender via history, not only the queue")
    func archiveCloses() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        try open(app, "aaaa0001", from: a, to: b)
        #expect(app.archiveConversation(b) == nil)
        #expect(try app.store.peers.message("aaaa0001")?.isOpen == false)
        #expect(app.takePendingEventLines(for: a).isEmpty, "an idle sender must not need its next turn to see this")
        let messages = app.conversations.first { $0.id == a }!.messages
        #expect(messages.contains { $0.role == .system && $0.content.contains("aaaa0001") && $0.content.contains("closed unanswered") },
                "the user must see the close in the sender's transcript")
        let history = app.conversations.first { $0.id == a }!.history
            .flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
        #expect(history.contains("aaaa0001") && history.contains("closed unanswered"),
                "an idle sender gets the line straight into history, not just a queue nothing will ever drain")
    }

    @Test("archiving a target queues the close line for a BUSY sender's own turn instead")
    func archiveClosesQueuesForBusySender() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        app.beginEngineTurn(for: a)
        try open(app, "aaaa0001", from: a, to: b)
        #expect(app.archiveConversation(b) == nil)
        let messages = app.conversations.first { $0.id == a }!.messages
        #expect(messages.contains { $0.role == .system && $0.content.contains("aaaa0001") },
                "the transcript line is unconditional, busy or not")
        #expect(app.conversations.first { $0.id == a }!.history.isEmpty, "must not cut into the running turn's history")
        #expect(app.takePendingEventLines(for: a).contains { $0.contains("aaaa0001") && $0.contains("closed unanswered") })
    }

    @Test("deleting a session closes requests to it, drops requests from it, and removes its rows")
    func deleteBothWays() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        try open(app, "aaaa0001", from: a, to: b)
        try open(app, "aaaa0002", from: b, to: a)
        app.deleteConversation(b)
        let history = app.conversations.first { $0.id == a }!.history
            .flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
        #expect(history.contains("aaaa0001"), "a now idle sender gets the close straight into history")
        #expect(try app.store.peers.message("aaaa0001") == nil)
        #expect(try app.store.peers.message("aaaa0002") == nil)
    }

    @Test("a 31-day-old message that never expected a reply is pruned")
    func pruneNoReplyExpected() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        let old = Date().addingTimeInterval(-31 * 86_400)
        try app.store.peers.insert(PeerMessageRecord(msgId: "aaaa0001", fromSession: a, toSession: b, contextId: "c",
                                                     inReplyTo: nil, depth: 1, firstLine: "x", sentAt: old,
                                                     expectsReply: false, closedAt: nil, closeReason: nil))
        try app.store.peers.prune(before: Date().addingTimeInterval(-30 * 86_400))
        #expect(try app.store.peers.message("aaaa0001") == nil,
                "expectsReply=false never gets closedAt, so sentAt alone must age it out")
    }

    @Test("a 31-day-old open request is kept forever")
    func keepsOldOpenRequest() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        let old = Date().addingTimeInterval(-31 * 86_400)
        try app.store.peers.insert(PeerMessageRecord(msgId: "aaaa0002", fromSession: a, toSession: b, contextId: "c",
                                                     inReplyTo: nil, depth: 1, firstLine: "x", sentAt: old,
                                                     expectsReply: true, closedAt: nil, closeReason: nil))
        try app.store.peers.prune(before: Date().addingTimeInterval(-30 * 86_400))
        #expect(try app.store.peers.message("aaaa0002") != nil,
                "an open request never expires by itself (§5.3), however old")
    }

    // MARK: - closeIfTargetGone (#469 review item 4)
    //
    // `send_to_session` resolves the target and decides to send in `decidePeerSend` (a MainActor
    // hop), then crosses an `await` (tier 1/2/3 sanitisation) before `peers.insert(record)` runs.
    // The user can archive or delete the target in that gap. `closeRequestsToGone` does not catch
    // it: at the moment the user archives, this message's row does not exist yet, so there is
    // nothing for it to close. `closeIfTargetGone` is the re-check that runs AFTER the insert, so
    // a request that expects a reply never sits open against a target that cannot answer it.
    // Driven directly against the helper, not through a timing race on the real send.

    @Test("closeIfTargetGone closes an open request whose target was archived meanwhile")
    func closeIfTargetGoneArchived() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        try open(app, "aaaa0001", from: a, to: b)
        // Simulates the race directly: by the time the row above was inserted, `b` had already
        // been archived (set directly, bypassing `archiveConversation`'s own `closeRequestsToGone`
        // call, which — at the real moment of archiving — ran before this row existed and so found
        // nothing to close).
        app.conversations[app.conversations.firstIndex { $0.id == b }!].isArchived = true
        app.closeIfTargetGone("aaaa0001", target: b)
        let record = try app.store.peers.message("aaaa0001")
        #expect(record?.isOpen == false)
        #expect(record?.closeReason == "target archived")
    }

    @Test("closeIfTargetGone closes an open request whose target was deleted meanwhile")
    func closeIfTargetGoneDeleted() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        try open(app, "aaaa0001", from: a, to: b)
        app.conversations.removeAll { $0.id == b }
        app.closeIfTargetGone("aaaa0001", target: b)
        let record = try app.store.peers.message("aaaa0001")
        #expect(record?.isOpen == false)
        #expect(record?.closeReason == "target deleted")
    }

    @Test("closeIfTargetGone leaves an open request alone when the target is still active")
    func closeIfTargetGoneStillActive() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        try open(app, "aaaa0001", from: a, to: b)
        app.closeIfTargetGone("aaaa0001", target: b)
        #expect(try app.store.peers.message("aaaa0001")?.isOpen == true)
    }

    @Test("closeIfTargetGone does nothing for a message that never expected a reply")
    func closeIfTargetGoneNoReplyExpected() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        try app.store.peers.insert(PeerMessageRecord(msgId: "aaaa0001", fromSession: a, toSession: b, contextId: "c",
                                                     inReplyTo: nil, depth: 1, firstLine: "x", sentAt: Date(),
                                                     expectsReply: false, closedAt: nil, closeReason: nil))
        app.conversations.removeAll { $0.id == b }
        app.closeIfTargetGone("aaaa0001", target: b)
        let record = try app.store.peers.message("aaaa0001")
        #expect(record?.closedAt == nil, "nothing was awaiting an answer, so there is nothing to close")
    }

    @Test("open requests survive a store reopen")
    func survivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID(), b = UUID()
        let sent = Date(timeIntervalSince1970: 5000)
        let dbURL = dir.appendingPathComponent("conversations.sqlite")
        do {
            let store = try ConversationStore.onDisk(at: dbURL)
            try store.peers.insert(PeerMessageRecord(msgId: "aaaa0001", fromSession: a, toSession: b, contextId: "c",
                                                     inReplyTo: nil, depth: 1, firstLine: "x", sentAt: sent,
                                                     expectsReply: true, closedAt: nil, closeReason: nil))
        }
        let reopened = try ConversationStore.onDisk(at: dbURL)
        #expect(try reopened.peers.openRequests(from: a).first?.sentAt == sent)
    }
}
