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

    /// #231: every session that has sent or received a message still in the ledger.
    func sessionsInvolved() throws -> Set<UUID> {
        try writer.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT fromSession FROM peer_messages UNION SELECT toSession FROM peer_messages")
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    /// #231: every session with a request it sent or received still awaiting its reply.
    func sessionsInOpenExchanges() throws -> Set<UUID> {
        try writer.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT fromSession FROM peer_messages WHERE expectsReply = 1 AND closedAt IS NULL
                UNION SELECT toSession FROM peer_messages WHERE expectsReply = 1 AND closedAt IS NULL
                """)
            return Set(ids.compactMap(UUID.init(uuidString:)))
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
            var open = try Row.fetchAll(db, sql: """
                SELECT * FROM peer_messages WHERE toSession = ? AND expectsReply = 1 AND closedAt IS NULL
                """, arguments: [session.uuidString]).compactMap(Self.decode)
            try db.execute(sql: """
                UPDATE peer_messages SET closedAt = ?, closeReason = ?
                WHERE toSession = ? AND expectsReply = 1 AND closedAt IS NULL
                """, arguments: [at, reason, session.uuidString])
            // Reflect the close in the returned records
            for i in 0..<open.count {
                open[i].closedAt = at
                open[i].closeReason = reason
            }
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

    /// A closed request has nothing left to tell either side; a message that never expected a
    /// reply has nothing to wait for either, but `expectsReply = 0` never gets a `closedAt` — so
    /// without the second clause those rows never aged out at all. An open request (`expectsReply
    /// = 1`, `closedAt IS NULL`) matches neither clause and is kept forever (§5.3: requests never
    /// expire by themselves).
    func prune(before cutoff: Date) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM peer_messages
                WHERE (closedAt IS NOT NULL AND closedAt < ?) OR (expectsReply = 0 AND sentAt < ?)
                """, arguments: [cutoff, cutoff])
        }
    }

    /// A row this build cannot read is skipped rather than failing the query. Reads every column
    /// as DatabaseValue first, then converts safely (never traps on type mismatches).
    private static func decode(_ row: Row) -> PeerMessageRecord? {
        guard let msgIdValue = row["msgId"] as DatabaseValue?, !msgIdValue.isNull,
              let msgId = String.fromDatabaseValue(msgIdValue) else { return nil }
        guard let fromValue = row["fromSession"] as DatabaseValue?, !fromValue.isNull,
              let fromStr = String.fromDatabaseValue(fromValue),
              let from = UUID(uuidString: fromStr) else { return nil }
        guard let toValue = row["toSession"] as DatabaseValue?, !toValue.isNull,
              let toStr = String.fromDatabaseValue(toValue),
              let to = UUID(uuidString: toStr) else { return nil }
        guard let contextIdValue = row["contextId"] as DatabaseValue?, !contextIdValue.isNull,
              let contextId = String.fromDatabaseValue(contextIdValue) else { return nil }
        guard let firstLineValue = row["firstLine"] as DatabaseValue?, !firstLineValue.isNull,
              let firstLine = String.fromDatabaseValue(firstLineValue) else { return nil }
        guard let sentAtValue = row["sentAt"] as DatabaseValue?, !sentAtValue.isNull,
              let sentAt = Date.fromDatabaseValue(sentAtValue) else { return nil }
        guard let expectsReplyValue = row["expectsReply"] as DatabaseValue?, !expectsReplyValue.isNull,
              let expectsReply = Bool.fromDatabaseValue(expectsReplyValue) else { return nil }
        guard let depthValue = row["depth"] as DatabaseValue?, !depthValue.isNull,
              let depth = Int.fromDatabaseValue(depthValue) else { return nil }

        let inReplyTo = (row["inReplyTo"] as DatabaseValue?).flatMap { v in !v.isNull ? String.fromDatabaseValue(v) : nil }
        let closedAt = (row["closedAt"] as DatabaseValue?).flatMap { v in !v.isNull ? Date.fromDatabaseValue(v) : nil }
        let closeReason = (row["closeReason"] as DatabaseValue?).flatMap { v in !v.isNull ? String.fromDatabaseValue(v) : nil }

        return PeerMessageRecord(msgId: msgId, fromSession: from, toSession: to, contextId: contextId,
                                 inReplyTo: inReplyTo, depth: depth, firstLine: firstLine,
                                 sentAt: sentAt, expectsReply: expectsReply,
                                 closedAt: closedAt, closeReason: closeReason)
    }
}
