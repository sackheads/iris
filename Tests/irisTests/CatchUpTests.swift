import Testing
import Foundation
@testable import iris

/// What a job that fell behind does when the scheduler next looks (#187 §5): the Mac slept, or the
/// app was closed, and `nextFireAt` is now more than one cadence in the past.
///
/// Every test here pins the clock and puts an eight-hour gap in front of a quarter-hourly cron, so
/// the three policies are compared on exactly the same 32 missed occurrences.
@Suite("Catch-up after sleep")
struct CatchUpTests {

    // MARK: A fixed day, in UTC

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-21 at `hour`:`minute` UTC.
    static func at(_ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: hour, minute: minute))!
    }

    /// Now, for every test below: 08:59, one minute short of the next quarter-hour.
    static let now = at(8, 59)
    /// The occurrence that made the row due: eight hours before `now`.
    static let due = at(1, 0)

    static let quarterHourly = Trigger.schedule(.cron(CronSchedule(expression: "*/15 * * * *", timeZone: "UTC")))

    static func job(_ catchUp: JobPolicy.CatchUp, trigger: Trigger = quarterHourly,
                    due: Date = CatchUpTests.due) -> Job {
        Job(name: "behind", prompt: "p", trigger: trigger, nextFireAt: due,
            policy: JobPolicy(catchUp: catchUp))
    }

    // MARK: A handler that records, refuses on cue, and notices overlap

    /// Stands in for `JobRunner.fire`: records what it was handed, answers whether the fire was
    /// admitted, and fails loudly if two fires of the same job are ever in flight at once.
    final class Handovers: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(name: String, note: String?)] = []
        private var inFlight = Set<String>()
        private var refuseFrom = Int.max
        private(set) var overlapped = false

        /// The handler refuses every fire from the `n`th onwards (1-based), the way admission
        /// refuses a paused job, an open breaker or a gate that found nothing.
        init(refusingFrom refuseFrom: Int = .max) { self.refuseFrom = refuseFrom }

        func handler() -> JobScheduler.FireHandler {
            { [self] job, fire in
                let admitted: Bool = lock.withLock {
                    entries.append((job.name, fire.note))
                    if inFlight.contains(job.name) { overlapped = true }
                    inFlight.insert(job.name)
                    return entries.count < refuseFrom
                }
                // A suspension point inside the fire, so two concurrent fires of one job would
                // actually interleave rather than being serialised by luck.
                await Task.yield()
                lock.withLock { _ = inFlight.remove(job.name) }
                return admitted
            }
        }

        var names: [String] { lock.withLock { entries.map(\.name) } }
        var notes: [String?] { lock.withLock { entries.map(\.note) } }
        var count: Int { lock.withLock { entries.count } }
    }

    // MARK: The three policies over one eight-hour sleep

    @Test("coalesce, the default, fires once and reschedules from now")
    func coalesceFiresOnce() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 10)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.coalesce))

        #expect(await scheduler.tick() == 1)
        #expect(fires.names == ["behind"])
        #expect(fires.notes == [nil], "nothing was dropped past a cap; there is no cap")
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))
    }

    @Test("skip fires nothing and jumps to the first occurrence still in the future")
    func skipFiresNothing() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 10)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.skip))

        #expect(await scheduler.tick() == 0)
        #expect(fires.count == 0)
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))
        #expect(try store.ledger.job(named: "behind")?.pausedReason == nil, "skipping is not a fault")
    }

    @Test("replay fires the last five missed occurrences and counts the earlier ones on the first card")
    func replayFiresTheCap() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 10)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.replay(cap: 5)))

        #expect(await scheduler.tick() == 5)
        #expect(fires.names == Array(repeating: "behind", count: 5))
        // 32 occurrences from 01:00 to 08:45; five replayed, the 27 older ones dropped. The count
        // is one fact about the burst, so only the first of the five carries it.
        #expect(fires.notes == ["27 earlier occurrences skipped", nil, nil, nil, nil])
        #expect(fires.overlapped == false, "a job never runs beside itself, replay or not")
        // Rescheduled from the last replayed slot (08:45), which is the same instant as
        // rescheduling from now: nothing is due between the last missed occurrence and `now`.
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))
        #expect(await scheduler.tick() == 0, "and the burst is over")
    }

    // MARK: The tick's cap still bounds the burst

    @Test("a replay longer than maxFiresPerTick continues on the next tick rather than exceeding it")
    func replayIsBoundedByTheTicksCap() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 2)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.replay(cap: 5)))

        #expect(await scheduler.tick() == 2)
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(8, 15),
                "still behind, and the next tick picks up where this one stopped")
        #expect(await scheduler.tick() == 2)
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(8, 45))
        #expect(await scheduler.tick() == 1)
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))

        #expect(fires.count == 5, "the cap is the cap, however many ticks it takes")
        #expect(fires.notes.first == "27 earlier occurrences skipped")
        #expect(fires.notes.dropFirst().allSatisfy { $0 == nil }, "counted once, on the first fire")
        #expect(await scheduler.tick() == 0)
    }

    @Test("the tick's cap is shared across jobs: one job's replay does not starve the loop")
    func theTicksCapIsSharedAcrossJobs() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 3)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        var replaying = Self.job(.replay(cap: 5))
        replaying.name = "replaying"
        try store.ledger.upsert(replaying)
        // Due later, so `dueJobs` orders it second and it takes what the replay leaves.
        try store.ledger.upsert(Job(name: "plain", prompt: "p", trigger: Self.quarterHourly,
                                    nextFireAt: Self.at(8, 45)))

        #expect(await scheduler.tick() == 3)
        #expect(fires.names == ["replaying", "replaying", "replaying"],
                "three fires is three fires, whoever they belong to")
        #expect(try store.ledger.job(named: "plain")?.nextFireAt == Self.at(8, 45),
                "the job that did not fit is left due for the next tick")
    }

    // MARK: A refusal ends the burst

    @Test("a refused replay stops there and the schedule advances from now (R32)")
    func aRefusalEndsTheBurst() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 2)
        // The second fire is refused — a pause, an open breaker, an exhausted budget, a gate that
        // found nothing. What refused this occurrence would refuse the next one too.
        let fires = Handovers(refusingFrom: 2)
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.replay(cap: 5)))

        #expect(await scheduler.tick() == 2)
        #expect(fires.count == 2)
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0),
                "the three occurrences still owed are abandoned, not tried again next tick")
        #expect(await scheduler.tick() == 0)
    }

    @Test("a replay whose fire paused the job leaves the paused cadence where it is")
    func aPauseEndsTheBurstWithoutBumpingTheCadence() async throws {
        // What refuses the second occurrence here is a budget or the breaker, which pause the job
        // as they refuse it. Abandoning the burst must not then walk the cadence of a job that is
        // no longer following it — the tick loop refuses to do that, and so does this.
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 2)
        let ledger = store.ledger
        let counted = Counter()
        await scheduler.setFireHandler { job, _ in
            guard counted.next() > 1 else { return true }
            try? ledger.setPaused(jobId: job.id, reason: "budget: tokens exceeded")
            return false
        }
        try store.ledger.upsert(Self.job(.replay(cap: 5)))

        #expect(await scheduler.tick() == 2)
        let back = try #require(try store.ledger.job(named: "behind"))
        #expect(back.pausedReason == "budget: tokens exceeded")
        #expect(back.nextFireAt == Self.at(8, 15), "the cadence is left exactly where the pause found it")
        #expect(await scheduler.tick() == 0, "and a paused job is not due, however far behind it is")
    }

    /// Counts calls across the tick's task group.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
    }

    // MARK: Behind by exactly one occurrence is not behind

    @Test("a job that missed a single occurrence fires it, whatever its catch-up policy says")
    func oneMissedOccurrenceIsAnOrdinaryFire() async throws {
        for policy in [JobPolicy.CatchUp.coalesce, .skip, .replay(cap: 5)] {
            let store = try ConversationStore.inMemory()
            let clock = Self.at(8, 50)
            let scheduler = JobScheduler(ledger: store.ledger, now: { clock }, maxFiresPerTick: 10)
            let fires = Handovers()
            await scheduler.setFireHandler(fires.handler())
            try store.ledger.upsert(Self.job(policy, due: Self.at(8, 45)))

            #expect(await scheduler.tick() == 1, "\(policy) is about occurrences that were missed in bulk")
            #expect(fires.notes == [nil])
            #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))
        }
    }

    @Test("replay with a cap of zero drops the lot and reschedules, like skip")
    func aCapOfZeroReplaysNothing() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 10)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.replay(cap: 0)))

        #expect(await scheduler.tick() == 0)
        #expect(fires.count == 0)
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))
    }

    // MARK: A polled cadence is a cadence

    @Test("a poll job's missed cadence replays like any other")
    func aPolledCadenceReplaysToo() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 10)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        let poll = Trigger.poll(PollSpec(schedule: .cron(CronSchedule(expression: "*/15 * * * *", timeZone: "UTC")),
                                         gate: .urlChanged(url: "https://example.com/feed")))
        try store.ledger.upsert(Self.job(.replay(cap: 3), trigger: poll))

        #expect(await scheduler.tick() == 3)
        #expect(fires.notes.first == "29 earlier occurrences skipped")
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))
    }

    @Test("a watch has no cadence to fall behind on")
    func aWatchHasNoCadence() async throws {
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 10)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.replay(cap: 5), trigger: .fsEvent(FSWatch(path: "/tmp"))))

        #expect(await scheduler.tick() == 1, "the stray nextFireAt is handed over once and cleared")
        #expect(fires.notes == [nil])
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == nil)
    }

    // MARK: The arithmetic itself

    @Test("the missed window is the most recent occurrences, oldest first, with the rest counted")
    func missedWindowIsTheMostRecent() throws {
        let cadence = Schedule.cron(CronSchedule(expression: "*/15 * * * *", timeZone: "UTC"))
        let missed = try #require(JobScheduler.missedOccurrences(of: cadence, from: Self.due,
                                                                 to: Self.now, keeping: 5))
        #expect(missed.replay == [Self.at(7, 45), Self.at(8, 0), Self.at(8, 15), Self.at(8, 30), Self.at(8, 45)])
        #expect(missed.dropped == 27)
    }

    @Test("an interval cadence walks the same way")
    func intervalWindow() throws {
        let cadence = Schedule.interval(seconds: 3600)
        let missed = try #require(JobScheduler.missedOccurrences(of: cadence, from: Self.at(0, 0),
                                                                 to: Self.at(8, 30), keeping: 2))
        #expect(missed.replay == [Self.at(7, 0), Self.at(8, 0)])
        #expect(missed.dropped == 7)
    }

    @Test("a job further behind than the walk's limit is not enumerated at all")
    func theWalkIsBounded() {
        // 32 occurrences, a limit of 10: the answer is `nil` — too far behind to enumerate, so the
        // caller coalesces rather than stepping through a cadence's whole history on the actor.
        let cadence = Schedule.cron(CronSchedule(expression: "*/15 * * * *", timeZone: "UTC"))
        #expect(JobScheduler.missedOccurrences(of: cadence, from: Self.due, to: Self.now,
                                               keeping: 5, limit: 10) == nil)
        #expect(JobScheduler.missedOccurrences(of: cadence, from: Self.due, to: Self.now,
                                               keeping: 5, limit: 32) != nil, "exactly at the limit is fine")
    }

    @Test("a job past the walk's limit coalesces: one fire now, rescheduled from now")
    func tooFarBehindCoalesces() async throws {
        let store = try ConversationStore.inMemory()
        // A per-minute cadence and a fortnight of downtime: 20,160 occurrences, past the walk's
        // ceiling. That is not catching up, it is starting again, and one fire is what a restart
        // wants — the alternative is stepping through 20,160 dates on the actor at wake.
        let start = Self.at(1, 0)
        let later = start.addingTimeInterval(14 * 86_400)
        let scheduler = JobScheduler(ledger: store.ledger, now: { later }, maxFiresPerTick: 10)
        let fires = Handovers()
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Job(name: "ancient", prompt: "p",
                                    trigger: .schedule(.cron(CronSchedule(expression: "* * * * *", timeZone: "UTC"))),
                                    nextFireAt: start, policy: JobPolicy(catchUp: .replay(cap: 5))))

        #expect(await scheduler.tick() == 1)
        #expect(fires.count == 1)
        #expect(try store.ledger.job(named: "ancient")?.nextFireAt == later.addingTimeInterval(60))
    }

    // MARK: DST

    @Test("a replay across a fall-back counts the repeated hour once each and terminates")
    func replayAcrossTheFallBack() throws {
        // 2026-11-01 in New York: 01:00 happens twice, once at UTC-4 and once at UTC-5. Both are
        // real instants whose local clock reads 01:00, so an hourly cadence fires at both — and
        // the walk must make strictly forward progress through them, which is the #252 fix this
        // arithmetic is standing on.
        let cadence = Schedule.cron(CronSchedule(expression: "0 * * * *", timeZone: "America/New_York"))
        // 2026-11-01 00:00 EDT is 04:00 UTC; five hours of real time later the local clock reads
        // 04:00 EST, because one of those five hours was lived through twice.
        let midnightEDT = Self.utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 4))!
        let fourEST = midnightEDT.addingTimeInterval(5 * 3600)
        let missed = try #require(JobScheduler.missedOccurrences(of: cadence, from: midnightEDT,
                                                                 to: fourEST, keeping: 3))
        #expect(missed.dropped == 3, "00:00 EDT, 01:00 EDT and 01:00 EST — the repeated hour is two occurrences")
        #expect(missed.replay == [midnightEDT.addingTimeInterval(3 * 3600),
                                  midnightEDT.addingTimeInterval(4 * 3600),
                                  fourEST])
    }

    // MARK: The note, on a real card

    @MainActor
    @Test("the first replayed run's card carries the count of what was dropped")
    func theCardCarriesTheNote() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let client = FakeLLMClient(responses: Array(repeating:
            Scenario.ScriptedResponse(kind: .text, text: "tick", calls: nil).asGeminiResponse(), count: 2))
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)

        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 10)
        await scheduler.setFireHandler(engine.fireHandler())
        try store.ledger.upsert(Self.job(.replay(cap: 2)))

        #expect(await scheduler.tick() == 2)
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let cards = activity.messages.compactMap { EventCard.decode($0.content) }
        #expect(cards.count == 2)
        #expect(cards.first?.catchUpNote == "30 earlier occurrences skipped")
        #expect(cards.last?.catchUpNote == nil)
        #expect(cards.first?.transcriptLine.contains("30 earlier occurrences skipped") == true,
                "and a copied transcript says so too")
    }
}
