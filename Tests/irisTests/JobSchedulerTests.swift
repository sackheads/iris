import Testing
import Foundation
@testable import iris

@Suite("JobScheduler")
struct JobSchedulerTests {
    final class Fired: @unchecked Sendable { var names: [String] = []; let lock = NSLock()
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() } }

    /// How many times a handler has been called, safely across the tick's task group.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        @discardableResult func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

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

    @Test("a cron job whose expression can never match again is paused with a reason")
    func pausesUnmatchable() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = scheduler(store, now: now)
        let job = Job(name: "never", prompt: "p", trigger: .schedule(.cron(CronSchedule(expression: "0 0 30 2 *", timeZone: "UTC"))), nextFireAt: now)
        try store.ledger.upsert(job)
        _ = await s.tick()
        let back = try store.ledger.job(named: "never")!
        #expect(back.pausedReason == "no matching time in the next four years" && back.nextFireAt == nil)
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

    @Test("an overlapping tick still hands the job over: overlap is the runner's call, not the loop's")
    func overlapIsNotTheSchedulersDecision() async throws {
        // D3 §4: `JobScheduler` no longer keeps a `firing` set. It could never cover a watch fire,
        // which never comes through here at all, so the in-flight check moved to `JobRunner.fire`
        // — the one place every fire passes. What stays here is the cadence: the trigger is handed
        // over, and what becomes of it (a run, a skip row, a queued fire) is admission's answer.
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
        try store.ledger.setNextFire(jobId: job.id, at: now.addingTimeInterval(-1), lastRunAt: now)
        await gate.open()
        #expect(await s.tick() == 1)
        #expect(fired.names == ["slow", "slow"])
        #expect(await first.value == 1)
    }

    @Test("a job whose handler is still running is handed over once per occurrence, not once per poll")
    func cadenceBoundsTheTriggersWhileAHandlerRuns() async throws {
        // The cadence advances before the handler is called, so the ten-second poll cannot keep
        // finding the same due job while its run is going: one occurrence is one trigger, however
        // many times the loop looks. This is what keeps a long run from writing a skip row a
        // minute (the row itself is `JobRunner.fire`'s, see JobAdmissionTests).
        let store = try ConversationStore.inMemory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = MovableClock(start)
        let s = JobScheduler(ledger: store.ledger, now: { clock.now })
        let calls = Counter()
        let gate = Gate()
        // Only the first handover parks: the whole question is how many more there are, and a
        // second one that parked too would hang the poll driving this test rather than fail it.
        await s.setFireHandler { _, _ in
            if calls.next() == 1 { await gate.arriveAndWait() }
        }
        let job = Job(name: "slow", prompt: "p", trigger: .schedule(.interval(seconds: 60)),
                      nextFireAt: start.addingTimeInterval(-1))
        try store.ledger.upsert(job)

        let firing = Task { await s.tick() }
        await gate.waitForEntry()
        // Three polls inside the same minute: only the first of them finds the job due.
        var handovers = 0
        for offset in [61.0, 71.0, 81.0] {
            clock.advance(by: offset - clock.now.timeIntervalSince(start))
            handovers += await s.tick()
        }
        await gate.open()
        _ = await firing.value

        #expect(handovers == 1, "one occurrence, one trigger")
        #expect(calls.value == 2, "the held-open fire, and the one occurrence that came due")
        #expect(try store.ledger.job(named: "slow")?.nextFireAt == start.addingTimeInterval(121))
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

    /// A clock the test moves by hand, so a day passes because the test says so rather than
    /// because it waited one.
    final class MovableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(by seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    @Test("the daily maintenance hook does not fire at start, and fires once a day after that")
    func dailyMaintenance() async throws {
        let store = try ConversationStore.inMemory()
        let clock = MovableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let s = JobScheduler(ledger: store.ledger, now: { clock.now })
        let ran = Fired()
        await s.setOnDailyMaintenance { ran.add("maintenance") }

        // The first tick is day zero: launch-time retention is the engine's own explicit call, so
        // firing here would run it twice within a second of each other.
        await s.tick()
        #expect(ran.names.isEmpty)

        // Nothing in between, however many ticks there are.
        for _ in 0..<3 {
            clock.advance(by: 6 * 3600)
            await s.tick()
        }
        #expect(ran.names.isEmpty, "18 hours in, still the same day")

        clock.advance(by: 6 * 3600 + 1)
        await s.tick()
        #expect(ran.names == ["maintenance"])

        // And the day restarts from the fire, not from the launch.
        clock.advance(by: 23 * 3600)
        await s.tick()
        #expect(ran.names == ["maintenance"])
        clock.advance(by: 3600 + 1)
        await s.tick()
        #expect(ran.names == ["maintenance", "maintenance"])
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

    @Test("what the legacy keys held is counted and logged once, and nothing is logged for nothing")
    func legacyDropIsReported() {
        let name = "iris-tests-legacy-log-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // No importer ships: the old records are dropped, so the count is the only trace left.
        defaults.set(Data(#"[{"prompt":"a"},{"prompt":"b"},{"prompt":"c"}]"#.utf8), forKey: "iris_scheduled_jobs")
        defaults.set(Data(#"[{"path":"/tmp/one","instructions":"i"}]"#.utf8), forKey: "WATCHER_RULES")
        var lines: [String] = []
        let dropped = JobScheduler.removeLegacyDefaults(from: defaults, log: { lines.append($0) })
        #expect(dropped.jobs == 3 && dropped.watcherRules == 1)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("3") == true && lines.first?.contains("1") == true)

        // A store that never held them says nothing at all.
        var quiet: [String] = []
        let none = JobScheduler.removeLegacyDefaults(from: defaults, log: { quiet.append($0) })
        #expect(none.jobs == 0 && none.watcherRules == 0)
        #expect(quiet.isEmpty)
    }

    @Test("the drop is a sentence the user sees, counted and pluralised, or nothing at all")
    func legacyDropNoticeWording() throws {
        // `removeLegacyDefaults` logs with `print`, which nobody running a macOS app reads. The
        // records are gone either way, so the notice is the user's only evidence they existed.
        #expect(JobScheduler.legacyDropNotice(jobs: 0, watcherRules: 0) == nil)

        let jobsOnly = try #require(JobScheduler.legacyDropNotice(jobs: 2, watcherRules: 0))
        #expect(jobsOnly.contains("2 scheduled jobs were dropped"))
        #expect(!jobsOnly.contains("0 watcher rules"), "a count of nothing is not reported")
        #expect(jobsOnly.contains("schedule_job"), "and it says how to get them back")

        let rulesOnly = try #require(JobScheduler.legacyDropNotice(jobs: 0, watcherRules: 1))
        #expect(rulesOnly.contains("1 watcher rule was dropped"))
        #expect(!rulesOnly.contains("0 scheduled jobs"), "a count of nothing is not reported")

        let both = try #require(JobScheduler.legacyDropNotice(jobs: 2, watcherRules: 1))
        #expect(both.contains("2 scheduled jobs and 1 watcher rule were dropped"))
    }
}
