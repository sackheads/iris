import Foundation
import GRDB

/// One peer message as the ledger records it (#469 §5, §8).
struct PeerMessageRecord: Equatable, Sendable {
    let msgId: String
    let fromSession: UUID
    let toSession: UUID
    let contextId: String
    let inReplyTo: String?
    let depth: Int
    let firstLine: String
    let sentAt: Date
    let expectsReply: Bool
    var closedAt: Date?
    var closeReason: String?

    /// A request still owed a reply. Requests never expire by themselves (§5.3).
    var isOpen: Bool { expectsReply && closedAt == nil }
}

/// The `peer_messages` table: correlation, `in_reply_to` validation, and the outstanding-request
/// ledger (#469 §5). On the store's writer, like `JobLedger`.
final class PeerLedger: Sendable {
    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) { self.writer = writer }

    func newMessageId() throws -> String {
        while true {
            let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            if try message(id) == nil { return id }
        }
    }

    func insert(_ r: PeerMessageRecord) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO peer_messages (msgId, fromSession, toSession, contextId, inReplyTo, depth,
                    firstLine, sentAt, expectsReply, closedAt, closeReason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [r.msgId, r.fromSession.uuidString, r.toSession.uuidString, r.contextId,
                                 r.inReplyTo, r.depth, r.firstLine, r.sentAt, r.expectsReply,
                                 r.closedAt, r.closeReason])
        }
    }

    func message(_ msgId: String) throws -> PeerMessageRecord? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM peer_messages WHERE msgId = ?", arguments: [msgId])
                .flatMap(Self.decode)
        }
    }

    func openRequests(from session: UUID) throws -> [PeerMessageRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM peer_messages WHERE fromSession = ? AND expectsReply = 1 AND closedAt IS NULL
                ORDER BY sentAt, rowid
                """, arguments: [session.uuidString]).compactMap(Self.decode)
        }
    }

    @discardableResult
    func close(_ msgId: String, reason: String, at: Date) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE peer_messages SET closedAt = ?, closeReason = ?
                WHERE msgId = ? AND expectsReply = 1 AND closedAt IS NULL
                """, arguments: [at, reason, msgId])
            return db.changesCount > 0
        }
    }

    func closeOpenRequests(to session: UUID, reason: String, at: Date) throws -> [PeerMessageRecord] {
        try writer.write { db in
            let open = try Row.fetchAll(db, sql: """
                SELECT * FROM peer_messages WHERE toSession = ? AND expectsReply = 1 AND closedAt IS NULL
                """, arguments: [session.uuidString]).compactMap(Self.decode)
            try db.execute(sql: """
                UPDATE peer_messages SET closedAt = ?, closeReason = ?
                WHERE toSession = ? AND expectsReply = 1 AND closedAt IS NULL
                """, arguments: [at, reason, session.uuidString])
            return open
        }
    }

    func closeOpenRequests(from session: UUID, reason: String, at: Date) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE peer_messages SET closedAt = ?, closeReason = ?
                WHERE fromSession = ? AND expectsReply = 1 AND closedAt IS NULL
                """, arguments: [at, reason, session.uuidString])
        }
    }

    func deleteMessages(involving session: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM peer_messages WHERE fromSession = ? OR toSession = ?",
                           arguments: [session.uuidString, session.uuidString])
        }
    }

    func pruneClosed(before cutoff: Date) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM peer_messages WHERE closedAt IS NOT NULL AND closedAt < ?",
                           arguments: [cutoff])
        }
    }

    /// A row this build cannot read is skipped rather than failing the query.
    private static func decode(_ row: Row) -> PeerMessageRecord? {
        guard let msgId: String = row["msgId"],
              let from = (row["fromSession"] as String?).flatMap(UUID.init(uuidString:)),
              let to = (row["toSession"] as String?).flatMap(UUID.init(uuidString:)),
              let contextId: String = row["contextId"],
              let firstLine: String = row["firstLine"],
              let sentAt = Date.fromDatabaseValue(row["sentAt"]) else { return nil }
        return PeerMessageRecord(msgId: msgId, fromSession: from, toSession: to, contextId: contextId,
                                 inReplyTo: row["inReplyTo"], depth: row["depth"] ?? 0, firstLine: firstLine,
                                 sentAt: sentAt, expectsReply: row["expectsReply"] ?? false,
                                 closedAt: Date.fromDatabaseValue(row["closedAt"]),
                                 closeReason: row["closeReason"])
    }
}
