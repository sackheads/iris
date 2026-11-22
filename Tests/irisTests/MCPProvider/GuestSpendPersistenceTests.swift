import Testing
import Foundation
import GRDB
@testable import IrisKit

/// #1135, Brian's ruling on the unified-access spec (E): keep the guest budget numbers, persist the daily count. The
/// 500,000-token UTC-day cap was already enforced (`GuestSessionDriver.submit`), but the ledger was memory-only, so a
/// restart refilled a day's allowance. The day's count now lives in the store (`guest_spend`, v45): a ledger built over
/// the same store after a restart starts from what was already spent today.
@Suite("the guest daily spend count survives a restart (#1135)", .serialized, .timeLimit(.minutes(1)))
struct GuestSpendPersistenceTests {
    private final class WallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 86_400 + 23 * 3600))   // 23:00 UTC
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    private func ledger(_ store: ConversationStore, _ wall: WallClock) -> GuestSpendLedger {
        GuestSpendLedger(now: { wall.now }, persistence: StoreGuestSpendPersistence(store: store))
    }

    @Test("a new ledger over the same store starts from what was spent today; another client is untouched")
    func restartKeepsTheDayCount() async throws {
        let store = try ConversationStore.inMemory(), wall = WallClock()
        let before = ledger(store, wall)
        await before.add(400_000, for: "dev-1")
        await before.add(25, for: "dev-2")
        let after = ledger(store, wall)          // the restart
        #expect(await after.todayTotal(for: "dev-1") == 400_000)
        #expect(await after.todayTotal(for: "dev-2") == 25)
        #expect(await after.todayTotal(for: "dev-3") == 0)
        await after.add(100_000, for: "dev-1")
        #expect(await ledger(store, wall).todayTotal(for: "dev-1") == 500_000, "adds accumulate across restarts")
    }

    @Test("the count restarts at 00:00 UTC across a restart too: yesterday's row neither carries over nor survives a new day's add")
    func dayRolloverAcrossRestart() async throws {
        let store = try ConversationStore.inMemory(), wall = WallClock()
        await ledger(store, wall).add(499_000, for: "dev-1")
        wall.advance(2 * 3600)                    // 01:00 UTC the next day
        let next = ledger(store, wall)
        #expect(await next.todayTotal(for: "dev-1") == 0, "yesterday's count is not today's")
        await next.add(10, for: "dev-1")
        #expect(await ledger(store, wall).todayTotal(for: "dev-1") == 10, "the new day's add replaces yesterday's row, it does not add to it")
    }

    @Test("a ledger with no persistence is the memory-only one it always was")
    func noPersistenceIsMemoryOnly() async throws {
        let wall = WallClock()
        let a = GuestSpendLedger(now: { wall.now })
        await a.add(7, for: "dev-1")
        #expect(await a.todayTotal(for: "dev-1") == 7)
        #expect(await GuestSpendLedger(now: { wall.now }).todayTotal(for: "dev-1") == 0)
    }

    // MARK: the cautious side (a damaged row never resets a cap)

    private func today(_ wall: WallClock) -> Int { Int(wall.now.timeIntervalSince1970 / 86_400) }

    @Test("a client with no row has spent nothing; other clients' good rows still count")
    func missingRowIsZero() async throws {
        let store = try ConversationStore.inMemory(), wall = WallClock()
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('good', ?, 42)", arguments: [today(wall)])
        let l = ledger(store, wall)
        #expect(await l.todayTotal(for: "good") == 42)
        #expect(await l.todayTotal(for: "never-sent") == 0)
    }

    @Test("a row whose day or tokens do not read counts that client as spent for the day, never as zero; others are untouched")
    func damagedRowIsSpent() async throws {
        let store = try ConversationStore.inMemory(), wall = WallClock()
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('bad-tokens', ?, 'abc')", arguments: [today(wall)])
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('bad-day', 'x', 10)")
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('good', ?, 42)", arguments: [today(wall)])
        let l = ledger(store, wall)
        #expect(await l.todayTotal(for: "bad-tokens") >= GuestSessionDriver.dailyTokenCap)
        #expect(await l.todayTotal(for: "bad-day") >= GuestSessionDriver.dailyTokenCap)
        #expect(await l.todayTotal(for: "good") == 42)
        #expect(await l.todayTotal(for: "stranger") == 0)
        await l.add(5, for: "bad-tokens")
        #expect(await l.todayTotal(for: "bad-tokens") >= GuestSessionDriver.dailyTokenCap, "a later add does not heal it within the day")
    }

    @Test("a row whose client cannot be read refuses every client until the day turns")
    func unattributableRowRefusesEveryone() async throws {
        let wall = WallClock()
        let junk = try ConversationStore.inMemory()
        try junk.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES (X'00FFFE', ?, 1)", arguments: [today(wall)])
        let l = ledger(junk, wall)
        #expect(await l.todayTotal(for: "anyone") >= GuestSessionDriver.dailyTokenCap)
        wall.advance(2 * 3600)    // 01:00 UTC the next day
        #expect(await l.todayTotal(for: "anyone") == 0, "the refusal is for the day it was found on")
    }

    @Test("a store that cannot be read refuses now, says why, and clears on the first read that works: it is not a lock until midnight")
    func unreadableStoreSelfHeals() async throws {
        let store = try ConversationStore.inMemory(), wall = WallClock()
        try store.rawWrite("DROP TABLE guest_spend")
        let l = ledger(store, wall)
        let reason = try #require(await l.unreadable(), "an unreadable store is refused, not an empty day")
        #expect(!reason.isEmpty)
        #expect(await l.todayTotal(for: "anyone") >= GuestSessionDriver.dailyTokenCap, "every client counts as spent while it cannot be read")
        #expect(await l.unreadable() != nil, "and it stays refused while the store is still unreadable")
        // The store reads again, with a row for one client.
        try store.rawWrite("CREATE TABLE guest_spend (client_id TEXT NOT NULL PRIMARY KEY, day INTEGER NOT NULL, tokens INTEGER NOT NULL)")
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('dev-1', ?, 40)", arguments: [today(wall)])
        #expect(await l.unreadable() == nil, "the first read that works clears the refusal, with no wait for the day to turn")
        #expect(await l.todayTotal(for: "dev-1") == 40)
        #expect(await l.todayTotal(for: "anyone") == 0)
    }

    @Test("spend tallied while the store could not be read is kept, and added to what the store has once it reads again")
    func outageSpendIsNotLost() async throws {
        let store = try ConversationStore.inMemory(), wall = WallClock()
        try store.rawWrite("DROP TABLE guest_spend")
        let l = ledger(store, wall)
        await l.add(30, for: "dev-1")              // a turn that was already running when the store broke
        try store.rawWrite("CREATE TABLE guest_spend (client_id TEXT NOT NULL PRIMARY KEY, day INTEGER NOT NULL, tokens INTEGER NOT NULL)")
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('dev-1', ?, 100)", arguments: [today(wall)])
        #expect(await l.unreadable() == nil)
        #expect(await l.todayTotal(for: "dev-1") == 130, "the safe side: the outage's spend and the store's, even if the store already had it")
    }

    @Test("an existing database from before v45 (no guest_spend table) still opens, keeps its rows, and gains the table")
    func oldSchemaStillOpens() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1135-old-\(UUID().uuidString)")
        let url = root.appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try ConversationStore.migrator.migrate(queue, upTo: "v44_sidebar_groups")
            #expect(try await queue.read { try $0.tableExists("guest_spend") } == false, "the fixture really predates v45")
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage)
                    VALUES (?, 1, 'old chat', datetime('now'), datetime('now'), ?)
                    """, arguments: [id.uuidString, String(decoding: try JSONEncoder().encode(TokenUsage()), as: UTF8.self)])
            }
            try queue.close()
        }
        let store = try ConversationStore.onDisk(at: url)
        #expect(try store.loadAll().conversations.map(\.id) == [id], "the old conversation survived the migration")
        let wall = WallClock()
        let l = ledger(store, wall)
        #expect(await l.todayTotal(for: "dev-1") == 0, "a fresh table is an empty day")
        await l.add(77, for: "dev-1")
        #expect(await ledger(try ConversationStore.onDisk(at: url), wall).todayTotal(for: "dev-1") == 77, "and it persists on disk across a reopen")
    }
}
