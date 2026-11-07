import Foundation
import GRDB

/// How an item's response area is answered (#920 design spec: "one item, four response shapes").
enum InboxResponseMode: String, Codable, Sendable {
    case optionsAndFreeform, freeform, timedVeto, notification
}

/// A thread's lifecycle: `open` needs attention, `answered` has Brian's verdict, `awaitingDelivery`
/// has it but no live recipient yet, `closed` is done, `stale` is a zombie (#920 spec: lifecycle).
enum InboxItemState: String, Codable, Sendable {
    case open, answered, awaitingDelivery, closed, stale
}

/// One choice in an item's decision, with its own pros and cons.
struct InboxOption: Codable, Equatable, Sendable {
    let id: String
    var label: String
    var pros: [String]
    var cons: [String]
}

/// Brian's verdict on a thread: a chosen option, free text, or both.
struct InboxAnswer: Codable, Equatable, Sendable {
    var chosenOptionId: String?
    var freeText: String?
    var at: Date
}

/// One pending (or resolved) decision. `threadId` is namespaced to and owned by `ownerChain` —
/// only that chain may append-and-reopen it (#920 spec: thread ownership / anti-goal #3).
struct InboxItem: Codable, Equatable, Sendable {
    let id: String
    let threadId: String
    let ownerChain: String
    let emitter: UUID
    let emitterLabel: String
    var title: String
    var situation: String
    var options: [InboxOption]
    var responseMode: InboxResponseMode
    var routeBack: [String]
    var notify: [String]
    var deadline: Date?
    var vetoDefaultOptionId: String?
    var emitterTainted: Bool
    var state: InboxItemState
    let createdAt: Date
    var lastActivityAt: Date
    var answer: InboxAnswer?

    init(id: String, threadId: String, ownerChain: String, emitter: UUID, emitterLabel: String,
         title: String, situation: String, options: [InboxOption], responseMode: InboxResponseMode,
         routeBack: [String], notify: [String], deadline: Date?, vetoDefaultOptionId: String?,
         emitterTainted: Bool, state: InboxItemState, createdAt: Date, lastActivityAt: Date,
         answer: InboxAnswer?) {
        self.id = id
        self.threadId = threadId
        self.ownerChain = ownerChain
        self.emitter = emitter
        self.emitterLabel = emitterLabel
        self.title = title
        self.situation = situation
        self.options = options
        self.responseMode = responseMode
        self.routeBack = routeBack
        self.notify = notify
        self.deadline = deadline
        self.vetoDefaultOptionId = vetoDefaultOptionId
        self.emitterTainted = emitterTainted
        self.state = state
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.answer = answer
    }

    /// Invariant 1: every field decodes with a default, so one unreadable field never makes the
    /// whole row — or an encode of this type elsewhere — throw.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId) ?? id
        ownerChain = try c.decodeIfPresent(String.self, forKey: .ownerChain) ?? ""
        emitter = try c.decodeIfPresent(UUID.self, forKey: .emitter) ?? UUID()
        emitterLabel = try c.decodeIfPresent(String.self, forKey: .emitterLabel) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        situation = try c.decodeIfPresent(String.self, forKey: .situation) ?? ""
        options = try c.decodeIfPresent([InboxOption].self, forKey: .options) ?? []
        responseMode = try c.decodeIfPresent(InboxResponseMode.self, forKey: .responseMode) ?? .notification
        routeBack = try c.decodeIfPresent([String].self, forKey: .routeBack) ?? []
        notify = try c.decodeIfPresent([String].self, forKey: .notify) ?? []
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        vetoDefaultOptionId = try c.decodeIfPresent(String.self, forKey: .vetoDefaultOptionId)
        emitterTainted = try c.decodeIfPresent(Bool.self, forKey: .emitterTainted) ?? false
        state = try c.decodeIfPresent(InboxItemState.self, forKey: .state) ?? .open
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? createdAt
        answer = try c.decodeIfPresent(InboxAnswer.self, forKey: .answer)
    }
}

/// One entry in a thread's history: the original question, Brian's answer, or a later followup.
struct InboxThreadEntry: Equatable, Sendable {
    let seq: Int64
    let itemId: String
    let kind: String // "question" | "answer" | "followup"
    let author: String
    let body: String
    let at: Date
}

enum InboxError: Error, Equatable {
    case notOwner
    case unknownThread
}

/// The `inbox_items` + `inbox_thread` tables: items and their thread entries, independent of any
/// conversation (so a reply outlives a dead emitter) — standalone, no FK, like
/// `pending_context_writes` (ConversationStore.swift). On the store's writer, like `PeerLedger`.
final class InboxStore: Sendable {
    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) { self.writer = writer }

    /// A random id, re-rolled on collision, mirroring `PeerLedger.newMessageId`.
    func newItemId() throws -> String {
        while true {
            let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
            if try item(id: id) == nil { return id }
        }
    }

    /// A thread id namespaced to `ownerChain` so a later ownership check never needs to look the
    /// owner up elsewhere — the id itself is only ever checked against the item that owns it.
    func newThreadId(ownerChain: String) throws -> String {
        while true {
            let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
            if try item(id: id) == nil { return id }
        }
    }

    /// Inserts the item and its opening `"question"` thread entry in one write.
    @discardableResult
    func createItem(_ item: InboxItem, question: String) throws -> InboxItem {
        try writer.write { db in
            try Self.insert(item, db: db)
            try Self.appendEntry(itemId: item.id, kind: "question", author: item.emitterLabel,
                                 body: question, at: item.createdAt, db: db)
        }
        return item
    }

    /// Refuses with `.notOwner` when `ownerChain` is not the thread's own owner (#920 spec: thread
    /// ownership) — a foreign chain cannot reopen a decision Brian already trusts. Else appends a
    /// `"followup"` entry and flips the item back to `.open`.
    @discardableResult
    func appendFollowup(threadId: String, fromChain ownerChain: String, author: String, body: String,
                        at: Date) throws -> Result<Void, InboxError> {
        return try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, ownerChain FROM inbox_items WHERE threadId = ? ORDER BY createdAt LIMIT 1",
                                             arguments: [threadId]) else {
                return .failure(.unknownThread)
            }
            guard let itemId = row["id"] as String?, let storedOwner = row["ownerChain"] as String? else {
                return .failure(.unknownThread)
            }
            guard storedOwner == ownerChain else { return .failure(.notOwner) }

            try Self.appendEntry(itemId: itemId, kind: "followup", author: author, body: body, at: at, db: db)
            try db.execute(sql: "UPDATE inbox_items SET state = ?, lastActivityAt = ? WHERE id = ?",
                           arguments: [InboxItemState.open.rawValue, at, itemId])
            return .success(())
        }
    }

    /// Records Brian's verdict: writes the answer, appends an `"answer"` thread entry, sets `.answered`.
    func recordAnswer(itemId: String, answer: InboxAnswer) throws {
        let answerJSON = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: "UPDATE inbox_items SET answerJSON = ?, state = ?, lastActivityAt = ? WHERE id = ?",
                           arguments: [answerJSON, InboxItemState.answered.rawValue, answer.at, itemId])
            let body = [answer.chosenOptionId, answer.freeText].compactMap { $0 }.joined(separator: ": ")
            try Self.appendEntry(itemId: itemId, kind: "answer", author: "brian", body: body, at: answer.at, db: db)
        }
    }

    func setState(itemId: String, _ state: InboxItemState) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE inbox_items SET state = ? WHERE id = ?", arguments: [state.rawValue, itemId])
        }
    }

    func item(id: String) throws -> InboxItem? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id]).flatMap(Self.decode)
        }
    }

    func thread(itemId: String) throws -> [InboxThreadEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM inbox_thread WHERE itemId = ? ORDER BY seq", arguments: [itemId])
                .compactMap(Self.decodeEntry)
        }
    }

    func openItems() throws -> [InboxItem] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE state = ? ORDER BY lastActivityAt DESC",
                             arguments: [InboxItemState.open.rawValue])
                .compactMap(Self.decode)
        }
    }

    /// Tests insert a row this build cannot decode through this; nothing in the app calls it.
    func rawInsertForTesting(id: String, threadId: String, ownerChain: String, responseMode: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (id, threadId, ownerChain, emitter, emitterLabel, title, situation,
                    optionsJSON, responseMode, routeBackJSON, notifyJSON, deadline, vetoDefaultOptionId,
                    emitterTainted, state, createdAt, lastActivityAt, answerJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, threadId, ownerChain, UUID().uuidString, "test", "t", "s",
                                 "[]", responseMode, "[]", "[]", nil, nil, false,
                                 InboxItemState.open.rawValue, Date(), Date(), nil])
        }
    }

    // MARK: Row encoding/decoding

    private static func insert(_ item: InboxItem, db: Database) throws {
        let optionsJSON = String(decoding: try JSONEncoder().encode(item.options), as: UTF8.self)
        let routeBackJSON = String(decoding: try JSONEncoder().encode(item.routeBack), as: UTF8.self)
        let notifyJSON = String(decoding: try JSONEncoder().encode(item.notify), as: UTF8.self)
        let answerJSON = try item.answer.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.execute(sql: """
            INSERT INTO inbox_items (id, threadId, ownerChain, emitter, emitterLabel, title, situation,
                optionsJSON, responseMode, routeBackJSON, notifyJSON, deadline, vetoDefaultOptionId,
                emitterTainted, state, createdAt, lastActivityAt, answerJSON)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [item.id, item.threadId, item.ownerChain, item.emitter.uuidString, item.emitterLabel,
                             item.title, item.situation, optionsJSON, item.responseMode.rawValue,
                             routeBackJSON, notifyJSON, item.deadline, item.vetoDefaultOptionId,
                             item.emitterTainted, item.state.rawValue, item.createdAt, item.lastActivityAt,
                             answerJSON])
    }

    private static func appendEntry(itemId: String, kind: String, author: String, body: String, at: Date,
                                    db: Database) throws {
        try db.execute(sql: "INSERT INTO inbox_thread (itemId, kind, author, body, at) VALUES (?, ?, ?, ?, ?)",
                       arguments: [itemId, kind, author, body, at])
    }

    /// A row this build cannot read is skipped rather than failing the query (mirrors
    /// `PeerLedger.decode` / `ConversationStore.pendingWrites`): an unknown `responseMode` or
    /// `state`, or malformed JSON, drops that row, never traps the load.
    private static func decode(_ row: Row) -> InboxItem? {
        guard let id = row["id"] as String?,
              let threadId = row["threadId"] as String?,
              let ownerChain = row["ownerChain"] as String?,
              let emitterStr = row["emitter"] as String?, let emitter = UUID(uuidString: emitterStr),
              let emitterLabel = row["emitterLabel"] as String?,
              let title = row["title"] as String?,
              let situation = row["situation"] as String?,
              let optionsText = row["optionsJSON"] as String?,
              let options = try? JSONDecoder().decode([InboxOption].self, from: Data(optionsText.utf8)),
              let responseModeRaw = row["responseMode"] as String?,
              let responseMode = InboxResponseMode(rawValue: responseModeRaw),
              let routeBackText = row["routeBackJSON"] as String?,
              let routeBack = try? JSONDecoder().decode([String].self, from: Data(routeBackText.utf8)),
              let notifyText = row["notifyJSON"] as String?,
              let notify = try? JSONDecoder().decode([String].self, from: Data(notifyText.utf8)),
              let emitterTainted = row["emitterTainted"] as Bool?,
              let stateRaw = row["state"] as String?,
              let state = InboxItemState(rawValue: stateRaw),
              let createdAt = row["createdAt"] as Date?,
              let lastActivityAt = row["lastActivityAt"] as Date? else { return nil }

        let answer: InboxAnswer? = (row["answerJSON"] as String?).flatMap {
            try? JSONDecoder().decode(InboxAnswer.self, from: Data($0.utf8))
        }

        return InboxItem(id: id, threadId: threadId, ownerChain: ownerChain, emitter: emitter,
                         emitterLabel: emitterLabel, title: title, situation: situation, options: options,
                         responseMode: responseMode, routeBack: routeBack, notify: notify,
                         deadline: row["deadline"], vetoDefaultOptionId: row["vetoDefaultOptionId"],
                         emitterTainted: emitterTainted, state: state, createdAt: createdAt,
                         lastActivityAt: lastActivityAt, answer: answer)
    }

    private static func decodeEntry(_ row: Row) -> InboxThreadEntry? {
        guard let seq = row["seq"] as Int64?,
              let itemId = row["itemId"] as String?,
              let kind = row["kind"] as String?,
              let author = row["author"] as String?,
              let body = row["body"] as String?,
              let at = row["at"] as Date? else { return nil }
        return InboxThreadEntry(seq: seq, itemId: itemId, kind: kind, author: author, body: body, at: at)
    }
}
