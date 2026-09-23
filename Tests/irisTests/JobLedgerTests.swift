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

    @Test("a row with an undecodable createdAt is skipped too, rather than sorting first at the epoch")
    func unreadableDate() throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(makeJob("good"))
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO jobs (id, name, prompt, triggerKind, trigger, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, "bad", "p", "schedule", "{\"kind\":\"schedule\",\"schedule\":{\"kind\":\"interval\",\"seconds\":60}}", "not-a-date"])
        }
        #expect(try store.ledger.jobs().map(\.name) == ["good"])
        #expect(store.ledger.unreadableJobCount == 1)
    }

    @Test("only jobs() publishes the skip count: dueJobs and job(named:) leave it alone")
    func countSurvivesOtherReads() throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(makeJob("good", next: Date(timeIntervalSince1970: 1)))
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO jobs (id, name, prompt, triggerKind, trigger, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, "bad", "p", "schedule", "{\"kind\":\"telepathy\"}", Date()])
        }
        #expect(try store.ledger.jobs().count == 1)
        #expect(store.ledger.unreadableJobCount == 1)
        _ = try store.ledger.dueJobs(at: Date())
        _ = try store.ledger.job(named: "good")
        #expect(store.ledger.unreadableJobCount == 1)
    }

    @Test("renaming a job onto another job's name fails instead of replacing it")
    func renameCollision() throws {
        let store = try ConversationStore.inMemory()
        var a = makeJob("a")
        try store.ledger.upsert(a)
        try store.ledger.upsert(makeJob("b"))
        a.name = "b"
        #expect(throws: (any Error).self) { try store.ledger.upsert(a) }
        #expect(try store.ledger.jobs().map(\.name) == ["a", "b"])
    }

    @Test("setNextFire and setPaused throw for an id that is not in the table")
    func unknownJob() throws {
        let store = try ConversationStore.inMemory()
        let missing = UUID()
        #expect(throws: JobLedgerError.unknownJob(missing)) {
            try store.ledger.setNextFire(jobId: missing, at: Date(), lastRunAt: nil)
        }
        #expect(throws: JobLedgerError.unknownJob(missing)) {
            try store.ledger.setPaused(jobId: missing, reason: "why")
        }
    }

    @Test("deleting a job cascades to its runs")
    func deleteCascadesToRuns() throws {
        let store = try ConversationStore.inMemory()
        let j = makeJob("j")
        try store.ledger.upsert(j)
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO job_runs (id, jobId, jobName, triggerKind, startedAt, status) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, j.id.uuidString, j.name, "schedule", Date(), "running"])
        }
        try store.ledger.delete(jobId: j.id)
        #expect(try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM job_runs") } == 0)
    }

    // MARK: The jobs-changed hook (#187 deliverable 4, §7)

    /// What the hook did, counted from whatever thread the write returned on.
    final class HookCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var reads = 0
        func bump(readable: Bool) { lock.withLock { calls += 1; if readable { reads += 1 } } }
        var count: Int { lock.withLock { calls } }
        var readCount: Int { lock.withLock { reads } }
    }

    @Test("onJobsChanged fires after upsert, delete and setPaused, with the table readable")
    func onJobsChangedFiresAfterUpsertDeleteAndSetPaused() throws {
        let store = try ConversationStore.inMemory()
        let ledger = store.ledger
        let counter = HookCounter()
        // Weak, so the hook the ledger holds does not hold the ledger back. The read inside the
        // hook is the assertion that matters: called from inside `writer.write`, a `jobs()` read
        // would re-enter the writer this thread already holds.
        ledger.onJobsChanged { [weak ledger] in
            counter.bump(readable: ((try? ledger?.jobs()) ?? nil) != nil)
        }

        let job = makeJob("hooked")
        try ledger.upsert(job)
        #expect(counter.count == 1)
        try ledger.setPaused(jobId: job.id, reason: "watch path unavailable: /gone")
        #expect(counter.count == 2)
        try ledger.delete(jobId: job.id)
        #expect(counter.count == 3)
        #expect(counter.readCount == 3, "every call read the table after the write returned")
    }

    @Test("the cadence writers never fire the hook")
    func cadenceWritersDoNotFireTheHook() throws {
        // A watch set that resynced on every `setNextFire` would resync every few seconds for the
        // lifetime of the process, for writes that cannot change which directories are watched.
        let store = try ConversationStore.inMemory()
        let job = makeJob("cadence")
        try store.ledger.upsert(job)
        let counter = HookCounter()
        store.ledger.onJobsChanged { counter.bump(readable: true) }

        try store.ledger.setNextFire(jobId: job.id, at: Date(), lastRunAt: nil)
        try store.ledger.setLastRun(jobId: job.id, at: Date())
        try store.ledger.setRetry(jobId: job.id, attempt: 1, nextFireAt: Date())
        try store.ledger.setQueuedFire(jobId: job.id, at: Date())

        #expect(counter.count == 0)
    }

    @Test("a write that failed does not fire the hook")
    func aFailedWriteDoesNotFireTheHook() throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(makeJob("taken"))
        let counter = HookCounter()
        store.ledger.onJobsChanged { counter.bump(readable: true) }

        // A rename onto another job's name, and a pause for an id that is not there.
        #expect(throws: (any Error).self) { try store.ledger.upsert(self.makeJob("taken")) }
        #expect(throws: (any Error).self) { try store.ledger.setPaused(jobId: UUID(), reason: "why") }

        #expect(counter.count == 0, "nothing changed, so there is nothing to resync")
    }

    @Test("v8 database migrates to v9 with conversations intact and the new columns NULL on the old row")
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
