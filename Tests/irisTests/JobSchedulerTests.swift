import Testing
import Foundation
@testable import iris

@Suite("JobScheduler")
struct JobSchedulerTests {
    final class Fired: @unchecked Sendable { var names: [String] = []; let lock = NSLock()
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() } }

    /// A one-shot rendezvous: the handler signals it has started, then parks on a continuation
    /// until the test opens the gate. Lets a test hold a fire open and drive an overlapping tick.
    actor Gate {
        private var entered = false
        private var opened = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        /// Called from inside the fire handler.
        func arriveAndWait() async {
            entered = true
            for waiter in entryWaiters { waiter.resume() }
            entryWaiters = []
            if opened { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        /// Returns once the handler has reached `arriveAndWait`.
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() {
            opened = true
            for waiter in openWaiters { waiter.resume() }
            openWaiters = []
        }
    }

    func scheduler(_ store: ConversationStore, now: Date, cap: Int = 3) -> (JobScheduler, Fired) {
        let fired = Fired()
        let s = JobScheduler(ledger: store.ledger, now: { now }, maxFiresPerTick: cap)
        return (s, fired)
    }

    @Test("a due interval job fires once and is rescheduled from now")
    func firesAndReschedules() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, fired) = scheduler(store, now: now)
        await s.setFireHandler { job, _ in fired.add(job.name) }
        try store.ledger.upsert(Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 300)), nextFireAt: now.addingTimeInterval(-1)))
        #expect(await s.tick() == 1)
        #expect(fired.names == ["j"])
        #expect(try store.ledger.job(named: "j")?.nextFireAt == now.addingTimeInterval(300))
        #expect(await s.tick() == 0)
    }

    @Test("at most maxFiresPerTick jobs start per tick; the rest wait")
    func cap() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, fired) = scheduler(store, now: now, cap: 2)
        await s.setFireHandler { job, _ in fired.add(job.name) }
        for n in ["a", "b", "c", "d"] {
            try store.ledger.upsert(Job(name: n, prompt: "p", trigger: .schedule(.interval(seconds: 3600)), nextFireAt: now.addingTimeInterval(-10)))
        }
        #expect(await s.tick() == 2)
        #expect(await s.tick() == 2)
        #expect(Set(fired.names) == ["a", "b", "c", "d"])
    }

    @Test("a cron job with no match in a year is paused with a reason")
    func pausesUnmatchable() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = scheduler(store, now: now)
        let job = Job(name: "never", prompt: "p", trigger: .schedule(.cron(CronSchedule(expression: "0 0 30 2 *", timeZone: "UTC"))), nextFireAt: now)
        try store.ledger.upsert(job)
        _ = await s.tick()
        let back = try store.ledger.job(named: "never")!
        #expect(back.pausedReason == "no matching time in the next year" && back.nextFireAt == nil)
    }

    @Test("schedule(_:) computes the first fire for a cron job")
    func scheduleComputesNext() async throws {
        let store = try ConversationStore.inMemory()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 8))!
        let (s, _) = scheduler(store, now: now)
        let stored = try await s.schedule(Job(name: "nine", prompt: "p", trigger: .schedule(.cron(CronSchedule(expression: "0 9 * * *", timeZone: "UTC")))))
        #expect(stored.nextFireAt == cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 9)))
    }

    @Test("a paused job stays put even when its nextFireAt is due")
    func pausedJobDoesNotFire() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, fired) = scheduler(store, now: now)
        await s.setFireHandler { job, _ in fired.add(job.name) }
        let due = now.addingTimeInterval(-1)
        try store.ledger.upsert(Job(name: "broke", prompt: "p", trigger: .schedule(.interval(seconds: 300)),
                                    nextFireAt: due, pausedReason: "budget"))
        #expect(await s.tick() == 0)
        #expect(fired.names.isEmpty)
        let back = try store.ledger.job(named: "broke")!
        #expect(back.nextFireAt == due && back.pausedReason == "budget")
    }

    @Test("with no fire handler set, a due job is left untouched")
    func noHandlerDoesNotAdvance() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = scheduler(store, now: now)
        let due = now.addingTimeInterval(-1)
        try store.ledger.upsert(Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 300)), nextFireAt: due))
        #expect(await s.tick() == 0)
        let back = try store.ledger.job(named: "j")!
        #expect(back.nextFireAt == due && back.lastRunAt == nil)
    }

    @Test("a job still firing is skipped by an overlapping tick")
    func skipsJobAlreadyFiring() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, fired) = scheduler(store, now: now)
        let gate = Gate()
        await s.setFireHandler { job, _ in
            fired.add(job.name)
            await gate.arriveAndWait()
        }
        let job = Job(name: "slow", prompt: "p", trigger: .schedule(.interval(seconds: 300)),
                      nextFireAt: now.addingTimeInterval(-1))
        try store.ledger.upsert(job)

        let first = Task { await s.tick() }
        await gate.waitForEntry()
        // The job is due again while its first run is still in flight: the `skip` overlap policy
        // must not start a second copy.
        try store.ledger.setNextFire(jobId: job.id, at: now.addingTimeInterval(-1), lastRunAt: now)
        #expect(await s.tick() == 0)
        #expect(fired.names == ["slow"])
        await gate.open()
        #expect(await first.value == 1)
    }

    @Test("a job deleted from inside another job's handler does not break the tick")
    func deletionDuringAFireIsSurvivable() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, fired) = scheduler(store, now: now)
        let a = Job(name: "a", prompt: "p", trigger: .schedule(.interval(seconds: 300)),
                    nextFireAt: now.addingTimeInterval(-2))
        let b = Job(name: "b", prompt: "p", trigger: .schedule(.interval(seconds: 300)),
                    nextFireAt: now.addingTimeInterval(-1))
        try store.ledger.upsert(a)
        try store.ledger.upsert(b)
        let ledger = store.ledger
        let doomed = b.id
        await s.setFireHandler { job, _ in
            fired.add(job.name)
            if job.name == "a" { try? ledger.delete(jobId: doomed) }
        }
        #expect(await s.tick() == 2)
        #expect(Set(fired.names) == ["a", "b"])
        #expect(try store.ledger.job(named: "b") == nil)
        // The vanished job neither throws out of the next tick nor keeps it from running.
        #expect(await s.tick() == 0)
    }

    @Test("legacy defaults keys are removed")
    func legacyKeys() {
        let name = "iris-tests-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("[]".utf8), forKey: "iris_scheduled_jobs")
        defaults.set(Data("[]".utf8), forKey: "WATCHER_RULES")
        JobScheduler.removeLegacyDefaults(from: defaults)
        #expect(defaults.data(forKey: "iris_scheduled_jobs") == nil && defaults.data(forKey: "WATCHER_RULES") == nil)
    }
}
