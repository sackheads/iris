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
        private var park: Gate?
        private(set) var overlapped = false

        /// The handler refuses every fire from the `n`th onwards (1-based), the way admission
        /// refuses a paused job, an open breaker or a gate that found nothing. `parkingFirstFireOn`
        /// holds the first fire open — a model turn outlasting the ten-second poll — so a test can
        /// drive a second tick while a burst is still running.
        init(refusingFrom refuseFrom: Int = .max, parkingFirstFireOn park: Gate? = nil) {
            self.refuseFrom = refuseFrom
            self.park = park
        }

        func handler() -> JobScheduler.FireHandler {
            { [self] job, fire in
                let (admitted, first): (Bool, Bool) = lock.withLock {
                    entries.append((job.name, fire.note))
                    if inFlight.contains(job.name) { overlapped = true }
                    inFlight.insert(job.name)
                    return (entries.count < refuseFrom, entries.count == 1)
                }
                if first, let park {
                    await park.arriveAndWait()
                } else {
                    // A suspension point inside the fire, so two concurrent fires of one job would
                    // actually interleave rather than being serialised by luck.
                    await Task.yield()
                }
                lock.withLock { _ = inFlight.remove(job.name) }
                return admitted
            }
        }

        var names: [String] { lock.withLock { entries.map(\.name) } }
        var notes: [String?] { lock.withLock { entries.map(\.note) } }
        var count: Int { lock.withLock { entries.count } }
    }

    /// A one-shot rendezvous: the handler signals it has started, then parks until the test opens
    /// the gate. Lets a test hold a fire open and drive an overlapping tick, which is how the poll
    /// loop and the wake observer both behave — each dispatches `tick()` detached.
    actor Gate {
        private var entered = false
        private var opened = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            entered = true
            for waiter in entryWaiters { waiter.resume() }
            entryWaiters = []
            if opened { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

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

    // `.timeLimit`, because the rendezvous below is an unbounded continuation: the failure it
    // exists to catch fails fast, but a future change that handed this job no fires at all would
    // park `waitForEntry()` for ever and hang the suite instead of failing it.
    @Test("a burst still running is not planned a second time by an overlapping tick",
          .timeLimit(.minutes(1)))
    func aTruncatedBurstIsNotPlannedTwice() async throws {
        // The shipped defaults: `maxFiresPerTick` 3 against a cap of 5, so the burst is cut short
        // and `nextFireAt` is deliberately left in the past — which is what lets a later tick
        // finish it. The poll loop and the wake observer both dispatch `tick()` detached, and a
        // model turn routinely outlasts the ten-second poll, so the next tick arrives while the
        // burst is still running and must not start a second one on top of it.
        let store = try ConversationStore.inMemory()
        let scheduler = JobScheduler(ledger: store.ledger, now: { Self.now }, maxFiresPerTick: 3)
        let gate = Gate()
        let fires = Handovers(parkingFirstFireOn: gate)
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.replay(cap: 5)))

        let firstTick = Task { await scheduler.tick() }
        await gate.waitForEntry()
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(8, 30),
                "the row is due again on purpose: three of the five slots have been handed over")

        let overlapping = await scheduler.tick()
        await gate.open()
        let started = await firstTick.value

        #expect(overlapping == 0, "the burst in flight owns the job until it ends")
        #expect(fires.overlapped == false, "and a job never runs beside itself")
        #expect(started == 3)

        // Once the burst is over the job is planned again and finishes what it owed — five fires
        // in total, the cap, with the dropped count still counted once.
        #expect(await scheduler.tick() == 2)
        #expect(fires.count == 5)
        #expect(fires.notes.first == "27 earlier occurrences skipped")
        #expect(fires.notes.dropFirst().allSatisfy { $0 == nil })
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0))
        #expect(await scheduler.tick() == 0)
    }

    @Test("the tick's cap counts fires across jobs, so a replay crowds out what does not fit")
    func theTicksCapCountsFiresAcrossJobs() async throws {
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
        // `dueJobs` orders by nextFireAt, so the job furthest behind is always the one that takes
        // the budget: a replaying job does crowd the rest of the tick out.
        #expect(fires.names == ["replaying", "replaying", "replaying"],
                "three fires is three fires, whoever they belong to")
        // Bounded at ceil(cap / maxFiresPerTick) ticks, and nothing is lost meanwhile.
        #expect(try store.ledger.job(named: "plain")?.nextFireAt == Self.at(8, 45),
                "the job that did not fit is left due for the next tick")
    }

    // MARK: A refusal ends the burst

    @Test("a refused replay stops there and the schedule advances from now (R32)")
    func aRefusalEndsTheBurst() async throws {
        let store = try ConversationStore.inMemory()
        let clock = MutableClock(Self.now)
        let scheduler = JobScheduler(ledger: store.ledger, now: { clock.now }, maxFiresPerTick: 2)
        // The second fire is refused — a pause, an open breaker, an exhausted budget, a gate that
        // found nothing. What refused this occurrence would refuse the next one too.
        let fires = Handovers(refusingFrom: 2)
        await scheduler.setFireHandler(fires.handler())
        try store.ledger.upsert(Self.job(.replay(cap: 5)))

        // Two fires, not five: the tick's cap allowed two and the second was refused. The cap is
        // also what makes this the burst-lock case — `nextFireAt` is left in the past mid-burst,
        // so the job is locked out of being planned again until the burst ends.
        #expect(await scheduler.tick() == 2)
        #expect(fires.count == 2)
        #expect(try store.ledger.job(named: "behind")?.nextFireAt == Self.at(9, 0),
                "the three occurrences still owed are abandoned, not tried again next tick")
        #expect(await scheduler.tick() == 0, "nothing is due at 08:59 any more")

        // The lock has to come off on the refusal path too, and only the clock can prove it: the
        // assertion above reads the same whether it was released or leaked, because the abandoned
        // job is not due either way. A leaked entry is not a lost tick, it is a job silenced for
        // the life of the process, so move past 09:00 and watch it fire again.
        clock.advance(to: Self.at(9, 1))
        #expect(await scheduler.tick() == 1, "the burst lock was released when the refusal ended it")
        #expect(fires.count == 3)
    }

    /// A clock a test can move between ticks. The suite's other tests pin one instant; the ones
    /// about what happens *next* need two.
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(to date: Date) { lock.withLock { value = date } }
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
        // And it says so where the user will see it. A `print` is not a notice in a GUI app, and
        // this quietly turns a `replay` job into a `coalesce` one for the fire.
        #expect(fires.notes == ["too far behind to replay; ran once instead"])
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

    // MARK: The count survives a refused first fire (#187 §5)

    @MainActor
    @Test("a gate that refuses the first replayed fire still records what the catch-up dropped")
    func aRefusedFirstFireStillSaysWhatWasDropped() async throws {
        // A gated poll job is the commonest `replay` subject, and a gate row carries no card — so
        // without this the user sees a job that went quiet for eight hours and then did nothing,
        // with the 30 dropped occurrences recorded nowhere at all.
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        let (config, teardown) = Self.isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in .unchanged(signal: "etag=aaa") })
        let job = Self.job(.replay(cap: 2),
                           trigger: .poll(PollSpec(schedule: .cron(CronSchedule(expression: "*/15 * * * *", timeZone: "UTC")),
                                                   gate: .urlChanged(url: "https://example.invalid/f"))))
        try store.ledger.upsert(job)

        let admission = await runner.fire(job: job, origin: .cadence(kind: "poll"),
                                          note: JobScheduler.skippedNote(30))

        #expect(admission == .gateUnchanged)
        let row = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(row.outcome == "\(JobRunner.gateUnchangedOutcome) (30 earlier occurrences skipped)")
    }

    @MainActor
    @Test("a budget that pauses the first replayed fire puts the count on the pause card")
    func aPauseOnTheFirstFireStillSaysWhatWasDropped() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        let (config, teardown) = Self.isolatedConfig()
        defer { teardown() }
        // The clock is pinned on the runner too, not only on the rows: `tokensToday` sums the
        // *current* local day, so a runner on the real clock stops counting this suite's 2026-09-21
        // row the moment the machine's own midnight passes — and the budget this test spends is
        // then unspent, deterministically, for every wall-clock day but one.
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               now: { Self.now }, calendar: Self.utc, config: config,
                               protectionEnabled: false)
        // A daily budget of one token, already spent by a finished run, so the next fire pauses.
        var job = Self.job(.replay(cap: 2))
        job.policy.dailyTokenBudget = 1
        try store.ledger.upsert(job)
        let spent = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Self.now)
        try store.ledger.begin(run: spent)
        try store.ledger.finish(runId: spent.id, status: .completed, outcome: "done",
                                failureReason: nil, blockedTool: nil,
                                tokens: TokenUsage(promptTokenCount: 0, candidatesTokenCount: 0,
                                                   totalTokenCount: 50),
                                finishedAt: Self.now)

        let admission = await runner.fire(job: job, origin: .schedule,
                                          note: JobScheduler.skippedNote(30))

        guard case .pauseBudget = admission else {
            Issue.record("expected a budget pause, got \(String(describing: admission))")
            return
        }
        let card = try #require(state.conversations.first { $0.id == state.activityConversationId() }?
            .messages.compactMap { EventCard.decode($0.content) }.last)
        #expect(card.catchUpNote == "30 earlier occurrences skipped")
        #expect(try store.ledger.job(named: "behind")?.pausedReason?.contains("earlier occurrences") == false,
                "the pause reason says why the job stopped, not how far behind it was")
    }

    static func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-catchup-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
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
