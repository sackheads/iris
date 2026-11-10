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

/// One choice in an item's decision, with its own pros and cons. Persisted as a JSON blob
/// (`optionsJSON`), so every field needs `decodeIfPresent ?? default` (Invariant 1): a field this
/// build doesn't know about must not throw and lose the whole item.
struct InboxOption: Codable, Equatable, Sendable {
    let id: String
    var label: String
    var pros: [String]
    var cons: [String]

    init(id: String, label: String, pros: [String], cons: [String]) {
        self.id = id
        self.label = label
        self.pros = pros
        self.cons = cons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        pros = try c.decodeIfPresent([String].self, forKey: .pros) ?? []
        cons = try c.decodeIfPresent([String].self, forKey: .cons) ?? []
    }
}

/// Brian's verdict on a thread: a chosen option, free text, or both. Persisted as a JSON blob
/// (`answerJSON`); same Invariant 1 requirement as `InboxOption`.
struct InboxAnswer: Codable, Equatable, Sendable {
    var chosenOptionId: String?
    var freeText: String?
    var at: Date
    /// True when nobody answered: a timed veto's deadline passed and the emitter's own default
    /// took effect (#920 Task 4). Not Brian's decision, and delivered as not his.
    var automatic: Bool = false

    init(chosenOptionId: String?, freeText: String?, at: Date, automatic: Bool = false) {
        self.chosenOptionId = chosenOptionId
        self.freeText = freeText
        self.at = at
        self.automatic = automatic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chosenOptionId = try c.decodeIfPresent(String.self, forKey: .chosenOptionId)
        freeText = try c.decodeIfPresent(String.self, forKey: .freeText)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
    }
}

/// One pending (or resolved) decision. `threadId` is namespaced to and owned by `ownerChain` —
/// only that chain may append-and-reopen it (#920 spec: thread ownership / anti-goal #3), enforced
/// by a UNIQUE index on `threadId` (one `inbox_items` row per thread) plus the ownership check in
/// `appendFollowup`. Not `Codable`: the store decodes each column itself (`InboxStore.decode`),
/// never this type as one JSON blob, so a synthesized `Decodable` here would be untested dead code
/// that silently defaults `ownerChain` to `""` if anyone later wired it up (dev-2 #924 review).
struct InboxItem: Equatable, Sendable {
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
    /// Route-back targets (as the emitter wrote them) the answer has not reached yet. Non-empty
    /// exactly while `state == .awaitingDelivery`.
    var pendingTargets: [String] = []
    /// When Brian last opened the item (#1027); nil until he does. Unread is "changed since then".
    var viewedAt: Date?

    /// Not yet seen, or changed (a follow-up, an answer) since it was last seen. Separate from
    /// `state`: an answered item can be unread (an automatic answer) and an open one read.
    var isUnread: Bool { viewedAt.map { $0 < lastActivityAt } ?? true }
}

/// What a follow-up puts on the item in place of the question that was answered (#1024). The item
/// is one row per thread, so the follow-up's own title, situation, options and response shape
/// replace the row's current ask; the earlier question and answer stay in the thread entries.
struct InboxFollowupAsk: Equatable, Sendable {
    var title: String
    var situation: String
    var options: [InboxOption]
    var responseMode: InboxResponseMode
    var deadline: Date?
    var vetoDefaultOptionId: String?
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

/// What a successful follow-up reports back: the item it landed on, so the tool can name it.
struct InboxFollowupResult: Equatable, Sendable {
    let itemId: String
}

enum InboxError: Error, Equatable {
    /// `appendFollowup`/`recordAnswer` on a thread/item that doesn't exist.
    case unknownThread
    case unknownItem
    /// `appendFollowup` from a chain other than the thread's own `ownerChain`.
    case notOwner
    /// `createItem` with a `threadId` that already has a row — one `inbox_items` row per thread,
    /// enforced by the UNIQUE index; refused here before the database ever has to (dev-2 finding 1).
    case threadAlreadyExists
    /// A write that would resurrect a `.closed` item (dev-2 finding 4): closing is meant to be final.
    case itemClosed
    /// `submitAnswer` on an item that is not waiting for one (already answered, awaiting delivery or closed).
    case notAnswerable
    /// `appendFollowup` on an item whose answer has not reached its route-back targets yet. A
    /// follow-up reopens the item and so takes it out of `redeliverAwaitingInbox`'s queue; the
    /// answer Brian gave would never arrive (dev-3's #1028 review).
    case awaitingDelivery
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

    /// A thread id namespaced to `ownerChain` (its sanitized prefix), re-rolled against the
    /// `threadId` column until it is free — not the `id` column, which `newItemId` checks (dev-2
    /// finding 2: the old version claimed namespacing but checked the wrong column and ignored
    /// the parameter entirely).
    func newThreadId(ownerChain: String) throws -> String {
        let prefix = ownerChain.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(16)
        while true {
            let suffix = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
            let id = prefix.isEmpty ? suffix : "\(prefix)-\(suffix)"
            if try !threadExists(id) { return id }
        }
    }

    /// Inserts the item and its opening `"question"` thread entry in one write. Refuses
    /// `.threadAlreadyExists` when `threadId` already has a row (dev-2 finding 1): creating is for
    /// a *new* thread only — reopening an existing one is `appendFollowup`'s job, and the UNIQUE
    /// index on `threadId` makes this check race-free within the one write transaction.
    @discardableResult
    func createItem(_ item: InboxItem, question: String) throws -> Result<InboxItem, InboxError> {
        try writer.write { db in
            if try Self.threadExists(item.threadId, db: db) { return .failure(.threadAlreadyExists) }
            try Self.insert(item, db: db)
            try Self.appendEntry(itemId: item.id, kind: "question", author: item.emitterLabel,
                                 body: question, at: item.createdAt, db: db)
            return .success(item)
        }
    }

    /// Refuses with `.notOwner` when `ownerChain` is not the thread's own owner (#920 spec: thread
    /// ownership) — a foreign chain cannot reopen a decision Brian already trusts. Refuses with
    /// `.itemClosed` once the thread is closed (dev-2 finding 4: closing is final), and with `.awaitingDelivery` while Brian's answer has not reached its recipients. The owner
    /// lookup is `threadId`'s UNIQUE row, not an `ORDER BY` over caller-supplied dates (dev-2
    /// finding 1's root cause). Else appends a `"followup"` entry and flips the item back to
    /// `.open`. `tainted` ORs into the item's `emitterTainted` (dev-3's #929 review finding 2): the
    /// flag was otherwise set once, at creation, so a followup from a session that has since read
    /// untrusted content left a tainted item reading clean.
    ///
    /// `ask` is the follow-up's own question (#1024): it replaces the row's title, situation,
    /// options and response shape, and the earlier answer is cleared so the item can be answered
    /// again (it stays in the thread as its `"answer"` entry). Without it the item is only
    /// reopened and keeps the question it had, the old behaviour, which dropped the follow-up's
    /// options on the floor and left Brian looking at a question he had already answered.
    @discardableResult
    func appendFollowup(threadId: String, fromChain ownerChain: String, author: String, body: String,
                        at: Date, tainted: Bool = false, ask: InboxFollowupAsk? = nil) throws -> Result<InboxFollowupResult, InboxError> {
        return try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, ownerChain, state, emitterTainted FROM inbox_items WHERE threadId = ?",
                                             arguments: [threadId]) else {
                return .failure(.unknownThread)
            }
            guard let itemId = row["id"] as String?, let storedOwner = row["ownerChain"] as String?,
                  let stateRaw = row["state"] as String?, let wasTainted = row["emitterTainted"] as Bool? else {
                return .failure(.unknownThread)
            }
            guard storedOwner == ownerChain else { return .failure(.notOwner) }
            guard stateRaw != InboxItemState.closed.rawValue else { return .failure(.itemClosed) }
            guard stateRaw != InboxItemState.awaitingDelivery.rawValue else { return .failure(.awaitingDelivery) }

            try Self.appendEntry(itemId: itemId, kind: "followup", author: author, body: body, at: at, db: db)
            try db.execute(sql: "UPDATE inbox_items SET state = ?, lastActivityAt = ?, emitterTainted = ? WHERE id = ?",
                           arguments: [InboxItemState.open.rawValue, at, wasTainted || tainted, itemId])
            if let ask {
                let optionsJSON = String(decoding: try JSONEncoder().encode(ask.options), as: UTF8.self)
                try db.execute(sql: """
                    UPDATE inbox_items SET title = ?, situation = ?, optionsJSON = ?, responseMode = ?, deadline = ?,
                        vetoDefaultOptionId = ?, answerJSON = NULL, pendingTargetsJSON = NULL WHERE id = ?
                    """, arguments: [ask.title, ask.situation, optionsJSON, ask.responseMode.rawValue, ask.deadline,
                                     ask.vetoDefaultOptionId, itemId])
            }
            return .success(InboxFollowupResult(itemId: itemId))
        }
    }

    /// Records Brian's verdict: writes the answer, appends an `"answer"` thread entry, sets
    /// `.answered`. Refuses `.unknownItem` on an id with no row (dev-2 finding 4: used to insert an
    /// orphan thread entry for nothing) and `.itemClosed` once the item is closed.
    @discardableResult
    func recordAnswer(itemId: String, answer: InboxAnswer) throws -> Result<Void, InboxError> {
        let answerJSON = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        return try writer.write { db in
            guard let stateRaw = try String.fetchOne(db, sql: "SELECT state FROM inbox_items WHERE id = ?",
                                                      arguments: [itemId]) else {
                return .failure(.unknownItem)
            }
            guard stateRaw != InboxItemState.closed.rawValue else { return .failure(.itemClosed) }

            // His own answer is not news to him; an automatic one is (viewedAt stays behind it).
            try db.execute(sql: "UPDATE inbox_items SET answerJSON = ?, state = ?, lastActivityAt = ?, viewedAt = CASE WHEN ? THEN viewedAt ELSE ? END WHERE id = ?",
                           arguments: [answerJSON, InboxItemState.answered.rawValue, answer.at, answer.automatic, answer.at, itemId])
            let body = [answer.chosenOptionId, answer.freeText].compactMap { $0 }.joined(separator: ": ")
            try Self.appendEntry(itemId: itemId, kind: "answer", author: "brian", body: body, at: answer.at, db: db)
            return .success(())
        }
    }

    /// Brian's answer plus the targets it still has to reach, in one write (#920 Task 3). Durable
    /// first: the pending targets are stored before any delivery is tried, so a crash between the
    /// answer and the delivery leaves an `.awaitingDelivery` item the next launch redelivers.
    /// Refuses `.notAnswerable` unless the item is `.open` or `.stale`, so two submits cannot both
    /// deliver. State is `.awaitingDelivery` while any target is pending, else `.answered`.
    @discardableResult
    func submitAnswer(itemId: String, answer: InboxAnswer, pendingTargets: [String]) throws -> Result<Void, InboxError> {
        let answerJSON = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        let pendingJSON = String(decoding: try JSONEncoder().encode(pendingTargets), as: UTF8.self)
        return try writer.write { db in
            guard let stateRaw = try String.fetchOne(db, sql: "SELECT state FROM inbox_items WHERE id = ?",
                                                      arguments: [itemId]) else { return .failure(.unknownItem) }
            guard stateRaw == InboxItemState.open.rawValue || stateRaw == InboxItemState.stale.rawValue else {
                return .failure(stateRaw == InboxItemState.closed.rawValue ? .itemClosed : .notAnswerable)
            }
            let state: InboxItemState = pendingTargets.isEmpty ? .answered : .awaitingDelivery
            try db.execute(sql: "UPDATE inbox_items SET answerJSON = ?, state = ?, lastActivityAt = ?, pendingTargetsJSON = ?, viewedAt = CASE WHEN ? THEN viewedAt ELSE ? END WHERE id = ?",
                           arguments: [answerJSON, state.rawValue, answer.at, pendingJSON, answer.automatic, answer.at, itemId])
            // The thread is history Brian reads, so name the option by its label, not its id; the
            // label is looked up now because a later follow-up replaces the options (#1024).
            let optionsText = try String.fetchOne(db, sql: "SELECT optionsJSON FROM inbox_items WHERE id = ?", arguments: [itemId])
            let options = optionsText.flatMap { try? JSONDecoder().decode([InboxOption].self, from: Data($0.utf8)) } ?? []
            let chosen = answer.chosenOptionId.map { id in options.first { $0.id == id }?.label ?? id }
            let body = [chosen, answer.freeText].compactMap { $0 }.joined(separator: ": ")
            try Self.appendEntry(itemId: itemId, kind: "answer", author: answer.automatic ? "veto-timer" : "brian",
                                 body: answer.automatic ? "no answer by the deadline; default \(body) took effect" : body,
                                 at: answer.at, db: db)
            return .success(())
        }
    }

    /// What delivery left undone: no targets means the answer reached everyone (`.answered`), any
    /// left keeps the item `.awaitingDelivery`. Only an item already in one of those two states is
    /// touched, so a reopen or a close that happened meanwhile is not overwritten.
    @discardableResult
    func setPendingTargets(itemId: String, _ targets: [String]) throws -> Result<Void, InboxError> {
        let json = String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)
        return try writer.write { db in
            let state: InboxItemState = targets.isEmpty ? .answered : .awaitingDelivery
            try db.execute(sql: """
                UPDATE inbox_items SET pendingTargetsJSON = ?, state = ?
                WHERE id = ? AND state IN (?, ?)
                """, arguments: [json, state.rawValue, itemId,
                                 InboxItemState.awaitingDelivery.rawValue, InboxItemState.answered.rawValue])
            return db.changesCount > 0 ? .success(()) : .failure(.notAnswerable)
        }
    }

    /// `.open` timed-veto items whose absolute deadline is at or before `now`, oldest deadline
    /// first. Whether each fires or holds is the caller's call (taint, a usable default).
    func dueVetoItems(now: Date) throws -> [InboxItem] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM inbox_items WHERE state = ? AND responseMode = ? AND deadline IS NOT NULL AND deadline <= ?
                ORDER BY deadline
                """, arguments: [InboxItemState.open.rawValue, InboxResponseMode.timedVeto.rawValue, now]).compactMap(Self.decode)
        }
    }

    /// Items whose answer is stored but not fully delivered, oldest answer first.
    func awaitingDeliveryItems() throws -> [InboxItem] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE state = ? ORDER BY lastActivityAt",
                             arguments: [InboxItemState.awaitingDelivery.rawValue]).compactMap(Self.decode)
        }
    }

    /// Notes that Brian has looked at the item, as of `at`. Touches only `viewedAt`, never
    /// `lastActivityAt`, so reading changes neither the order of the list nor what counts as new.
    /// Writes only when the item is unread, so reopening a read item costs nothing.
    func markViewed(itemId: String, at: Date) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE inbox_items SET viewedAt = ? WHERE id = ? AND (viewedAt IS NULL OR viewedAt < lastActivityAt)
                """, arguments: [at, itemId])
        }
    }

    /// Refuses `.unknownItem` when nothing was updated (dev-2 finding 4).
    @discardableResult
    func setState(itemId: String, _ state: InboxItemState) throws -> Result<Void, InboxError> {
        try writer.write { db in
            try db.execute(sql: "UPDATE inbox_items SET state = ? WHERE id = ?", arguments: [state.rawValue, itemId])
            return db.changesCount > 0 ? .success(()) : .failure(.unknownItem)
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

    /// Every open item, most recently active first. A row this build cannot decode is skipped
    /// (never traps the whole load) but logged once — unlike a dropped chat message, a dropped
    /// inbox row is a decision Brian is waiting on, so it must not vanish with no trace (dev-2
    /// finding 5).
    func openItems() throws -> [InboxItem] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE state = ? ORDER BY lastActivityAt DESC",
                                        arguments: [InboxItemState.open.rawValue])
            var items: [InboxItem] = []
            for row in rows {
                if let decoded = Self.decode(row) {
                    items.append(decoded)
                } else {
                    print("WARNING: unreadable inbox item row (id=\(row["id"] as String? ?? "?")); skipped")
                }
            }
            return items
        }
    }

    private func threadExists(_ threadId: String) throws -> Bool {
        try writer.read { db in try Self.threadExists(threadId, db: db) }
    }

    private static func threadExists(_ threadId: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM inbox_items WHERE threadId = ?)", arguments: [threadId]) ?? false
    }

    /// Tests insert a row this build cannot decode through this; nothing in the app calls it.
    func rawInsertForTesting(id: String, threadId: String, ownerChain: String = "test-chain",
                             emitter: String = UUID().uuidString, responseMode: String = InboxResponseMode.notification.rawValue,
                             state: String = InboxItemState.open.rawValue, optionsJSON: String = "[]",
                             answerJSON: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (id, threadId, ownerChain, emitter, emitterLabel, title, situation,
                    optionsJSON, responseMode, routeBackJSON, notifyJSON, deadline, vetoDefaultOptionId,
                    emitterTainted, state, createdAt, lastActivityAt, answerJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, threadId, ownerChain, emitter, "test", "t", "s",
                                 optionsJSON, responseMode, "[]", "[]", nil, nil, false,
                                 state, Date(), Date(), answerJSON])
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
    /// `state`, a non-UUID `emitter`, or malformed `optionsJSON`/`routeBackJSON`/`notifyJSON` drops
    /// that row, never traps the load. An `answerJSON` that is present but fails to decode also
    /// drops the row — an answered item with a silently-emptied answer (`answer == nil` while
    /// `state == .answered`) would be worse than one that's absent entirely (dev-2 finding 3).
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

        var answer: InboxAnswer?
        if let answerText = row["answerJSON"] as String? {
            guard let decoded = try? JSONDecoder().decode(InboxAnswer.self, from: Data(answerText.utf8)) else { return nil }
            answer = decoded
        }

        // Nullable column: absent reads as none; present but unreadable drops the row like any other.
        var pendingTargets: [String] = []
        if let pendingText = row["pendingTargetsJSON"] as String? {
            guard let decoded = try? JSONDecoder().decode([String].self, from: Data(pendingText.utf8)) else { return nil }
            pendingTargets = decoded
        }

        return InboxItem(id: id, threadId: threadId, ownerChain: ownerChain, emitter: emitter,
                         emitterLabel: emitterLabel, title: title, situation: situation, options: options,
                         responseMode: responseMode, routeBack: routeBack, notify: notify,
                         deadline: row["deadline"], vetoDefaultOptionId: row["vetoDefaultOptionId"],
                         emitterTainted: emitterTainted, state: state, createdAt: createdAt,
                         lastActivityAt: lastActivityAt, answer: answer, pendingTargets: pendingTargets,
                         viewedAt: row["viewedAt"])
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
