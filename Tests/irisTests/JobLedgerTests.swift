import Testing
import Foundation
import GRDB
@testable import iris

@Suite("JobLedger")
struct JobLedgerTests {
    func makeJob(_ name: String, next: Date? = nil) -> Job {
        Job(name: name, prompt: "p \(name)", trigger: .schedule(.interval(seconds: 60)), nextFireAt: next)
    }

    @Test("upsert, list, fetch by name, delete")
    func crud() throws {
        let store = try ConversationStore.inMemory()
        var a = makeJob("a"); try store.ledger.upsert(a)
        try store.ledger.upsert(makeJob("b"))
        #expect(try store.ledger.jobs().map(\.name) == ["a", "b"])
        a.prompt = "changed"; try store.ledger.upsert(a)
        #expect(try store.ledger.job(named: "a")?.prompt == "changed")
        try store.ledger.delete(jobId: a.id)
        #expect(try store.ledger.jobs().map(\.name) == ["b"])
    }

    @Test("name is unique: a second job with the same name and a different id fails")
    func uniqueName() throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(makeJob("dup"))
        #expect(throws: (any Error).self) { try store.ledger.upsert(makeJob("dup")) }
    }

    @Test("dueJobs is inclusive at the boundary, skips disabled and nil nextFireAt, orders by nextFireAt")
    func due() throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try store.ledger.upsert(makeJob("late", next: now.addingTimeInterval(-10)))
        try store.ledger.upsert(makeJob("exact", next: now))
        try store.ledger.upsert(makeJob("future", next: now.addingTimeInterval(1)))
        var off = makeJob("off", next: now.addingTimeInterval(-100)); off.enabled = false; try store.ledger.upsert(off)
        try store.ledger.upsert(makeJob("never"))
        #expect(try store.ledger.dueJobs(at: now).map(\.name) == ["late", "exact"])
    }

    @Test("setNextFire and setPaused update only their columns")
    func updates() throws {
        let store = try ConversationStore.inMemory()
        let j = makeJob("j"); try store.ledger.upsert(j)
        let t = Date(timeIntervalSince1970: 2_000_000)
        try store.ledger.setNextFire(jobId: j.id, at: t, lastRunAt: t.addingTimeInterval(-5))
        try store.ledger.setPaused(jobId: j.id, reason: "why")
        let back = try store.ledger.job(named: "j")!
        #expect(back.nextFireAt == t && back.lastRunAt == t.addingTimeInterval(-5) && back.pausedReason == "why" && back.prompt == "p j")
    }

    @Test("a row with an unreadable trigger is skipped and counted, not fatal")
    func unreadableRow() throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(makeJob("good"))
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO jobs (id, name, prompt, triggerKind, trigger, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, "bad", "p", "schedule", "{\"kind\":\"telepathy\"}", Date()])
        }
        #expect(try store.ledger.jobs().map(\.name) == ["good"])
        #expect(store.ledger.unreadableJobCount == 1)
    }

    @Test("v8 database migrates to v9 with conversations intact and new columns reading false")
    func migrateFromV8() throws {
        let queue = try DatabaseQueue()
        try ConversationStore.migrator.migrate(queue, upTo: "v8_session_card")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage) VALUES (?, 0, 'old', ?, ?, '{}')",
                           arguments: [UUID().uuidString, Date(), Date()])
        }
        try ConversationStore.migrator.migrate(queue)
        let (count, bg, pinned, tables) = try queue.read { db -> (Int, Bool?, Bool?, Set<String>) in
            let row = try Row.fetchOne(db, sql: "SELECT isBackground, isPinned FROM conversations")!
            let names = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return (try Int.fetchOne(db, sql: "SELECT count(*) FROM conversations")!, row["isBackground"], row["isPinned"], names)
        }
        #expect(count == 1 && bg == nil && pinned == nil)
        #expect(tables.isSuperset(of: ["jobs", "job_runs"]))
    }
}
