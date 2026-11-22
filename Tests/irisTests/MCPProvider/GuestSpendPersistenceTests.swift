import Testing
import Foundation
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

    @Test("a row the store cannot read is skipped, not fatal, and not counted")
    func unreadableRowIsSkipped() async throws {
        let store = try ConversationStore.inMemory(), wall = WallClock()
        let day = Int(wall.now.timeIntervalSince1970 / 86_400)
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('bad', 'x', 'y')")
        try store.rawWrite("INSERT INTO guest_spend (client_id, day, tokens) VALUES ('good', ?, 42)", arguments: [day])
        let l = ledger(store, wall)
        #expect(await l.todayTotal(for: "good") == 42)
        #expect(await l.todayTotal(for: "bad") == 0)
    }
}
