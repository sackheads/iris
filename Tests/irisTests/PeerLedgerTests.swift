import Testing
import Foundation
@testable import IrisKit

@Suite("Peer ledger")
struct PeerLedgerTests {
    private func record(_ id: String, from: UUID, to: UUID, expects: Bool = true,
                        sentAt: Date = Date(timeIntervalSince1970: 1000)) -> PeerMessageRecord {
        PeerMessageRecord(msgId: id, fromSession: from, toSession: to, contextId: "ctx-\(id)", inReplyTo: nil,
                          depth: 1, firstLine: "do the thing", sentAt: sentAt, expectsReply: expects,
                          closedAt: nil, closeReason: nil)
    }

    @Test("message ids are 8 lowercase hex and unused")
    func ids() throws {
        let peers = try ConversationStore.inMemory().peers
        let id = try peers.newMessageId()
        #expect(id.count == 8)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(try peers.message(id) == nil)
    }

    @Test("a record round-trips; only expects_reply rows are open")
    func roundTrip() throws {
        let peers = try ConversationStore.inMemory().peers
        let a = UUID(), b = UUID()
        try peers.insert(record("aaaa0001", from: a, to: b))
        try peers.insert(record("aaaa0002", from: a, to: b, expects: false))
        #expect(try peers.message("aaaa0001")?.firstLine == "do the thing")
        #expect(try peers.openRequests(from: a).map(\.msgId) == ["aaaa0001"])
    }

    @Test("close reports whether it closed; a second close is a no-op")
    func closeOnce() throws {
        let peers = try ConversationStore.inMemory().peers
        let a = UUID(), b = UUID()
        try peers.insert(record("aaaa0001", from: a, to: b))
        #expect(try peers.close("aaaa0001", reason: "replied bbbb0001", at: Date()) == true)
        #expect(try peers.close("aaaa0001", reason: "again", at: Date()) == false)
        #expect(try peers.message("aaaa0001")?.closeReason == "replied bbbb0001")
        #expect(try peers.openRequests(from: a).isEmpty)
    }

    @Test("closing requests to a session returns them; deleting a session's rows removes both directions")
    func targetGone() throws {
        let peers = try ConversationStore.inMemory().peers
        let a = UUID(), b = UUID(), c = UUID()
        try peers.insert(record("aaaa0001", from: a, to: b))
        try peers.insert(record("aaaa0002", from: c, to: b))
        try peers.insert(record("aaaa0003", from: b, to: a))
        let closed = try peers.closeOpenRequests(to: b, reason: "target archived", at: Date())
        #expect(Set(closed.map(\.msgId)) == ["aaaa0001", "aaaa0002"])
        try peers.deleteMessages(involving: b)
        #expect(try peers.message("aaaa0001") == nil)
        #expect(try peers.message("aaaa0003") == nil)
    }

    @Test("pruning removes only closed rows older than the cutoff")
    func prune() throws {
        let peers = try ConversationStore.inMemory().peers
        let a = UUID(), b = UUID()
        try peers.insert(record("aaaa0001", from: a, to: b))
        try peers.insert(record("aaaa0002", from: a, to: b))
        try peers.close("aaaa0001", reason: "x", at: Date(timeIntervalSince1970: 2000))
        try peers.pruneClosed(before: Date(timeIntervalSince1970: 3000))
        #expect(try peers.message("aaaa0001") == nil)
        #expect(try peers.message("aaaa0002") != nil, "open rows are never pruned")
    }
}
