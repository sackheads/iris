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

    @Test("archiving a target closes requests to it and tells each sender")
    func archiveCloses() throws {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        try open(app, "aaaa0001", from: a, to: b)
        #expect(app.archiveConversation(b) == nil)
        #expect(try app.store.peers.message("aaaa0001")?.isOpen == false)
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
        #expect(app.takePendingEventLines(for: a).contains { $0.contains("aaaa0001") })
        #expect(try app.store.peers.message("aaaa0001") == nil)
        #expect(try app.store.peers.message("aaaa0002") == nil)
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
