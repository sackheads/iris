import Testing
import Foundation
@testable import iris

@Suite("JobScheduler")
struct JobSchedulerTests {
    final class Fired: @unchecked Sendable { var names: [String] = []; let lock = NSLock()
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() } }

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
