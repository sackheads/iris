import Foundation

/// One firing of a job, start to finish (#187 §6). Replaces deliverable 1's fire handler, which
/// pushed a system event into whatever conversation the job was created in — so a five-minute
/// cadence wrote into the chat the user was reading, and a run that needed an approval parked on a
/// dialog nobody was there to answer.
///
/// A run now gets a conversation of its own: `isBackground`, so it is out of the sidebar
/// (`SidebarOrdering.visible`) and out of the selection, but a real conversation all the same, so
/// its transcript can be read back from a card afterwards. Around that turn this writes the two
/// durable records the rest of the feature reads: the `job_runs` row (begun before the turn, so a
/// crash mid-run leaves a `running` row for `closeRunningRuns` to find at the next launch) and one
/// `EventCard` delivered when it is over.
///
/// An actor because `JobScheduler` fires handlers from a task group: two jobs coming due in the
/// same tick run concurrently, and each needs its own conversation and its own row without either
/// of them serialising on the main actor for longer than the hops below.
actor JobRunner {
    /// The failure reason on the row an overlap-skip writes. Spelled once: `/jobs` reads it back.
    static let skipReason = "skipped: previous run still in progress"
    /// A turn that ended without the agent saying anything: a hook that blocked it, a cancelled
    /// engine, a conversation deleted mid-run. Not `completed` — "it worked and had nothing to
    /// report" and "it never got as far as a reply" must not look the same on a card.
    static let noReplyReason = "run produced no reply"
    /// The app quit (or `AppState` was otherwise released) with the run still open.
    static let releasedReason = "app state released"
    /// The longest the deadline watchdog sleeps before looking at the wall clock again. See the
    /// loop in `run()`: the sleep and the deadline are on different clocks, so the bound on how
    /// far a sleeping Mac can push a run past its timeout is this, not the timeout itself.
    static let watchdogSlice: TimeInterval = 60

    /// Weak, both of them: `AppState` owns the engine, the engine owns this runner for the life of
    /// the process, and a strong reference back either way is a cycle that keeps a whole app state
    /// — conversations, store, sessions — alive forever. Each hop below re-reads them and bails
    /// (closing the ledger row) rather than keeping one. `state` is held only for the length of a
    /// single main-actor hop; `engine` is held across `processInput`, because that call IS the
    /// run and an engine deallocated halfway through its own turn is not a state worth surviving.
    private weak var state: AppState?
    private weak var engine: IrisEngine?
    private let ledger: JobLedger
    /// The ledger, except where a test needs the usage read itself to fail (`JobUsageReading`).
    private let usageSource: any JobUsageReading
    private let now: @Sendable () -> Date
    /// Whose day "tokens today" is counted in — the user's, so the budget resets at their
    /// midnight. Injectable only so a test can pin the zone.
    private let calendar: Calendar
    private let config: ConfigManager
    private let protectionEnabled: Bool?
    /// How a run keeps the Mac awake for its own duration (§4). Injected so a test can watch the
    /// begin/end pair instead of asserting on the machine's real power state.
    private let activity: any ActivityAPI
    /// The jobs with a run in flight right now. Every fire goes through `fire`, so one set here is
    /// the whole overlap story, whatever woke the job.
    private var inFlight: Set<UUID> = []
    /// The origin of a held (`policy.overlap == .queue`) fire, by job. In memory on purpose: see
    /// `hold(fire:for:origin:)`.
    private var queuedOrigins: [UUID: FireOrigin] = [:]

    init(state: AppState, engine: IrisEngine, ledger: JobLedger,
         now: @escaping @Sendable () -> Date = Date.init,
         calendar: Calendar = .current,
         config: ConfigManager = .shared,
         protectionEnabled: Bool? = nil,
         activity: any ActivityAPI = ProcessInfoActivity(),
         usageSource: (any JobUsageReading)? = nil) {
        self.state = state
        self.engine = engine
        self.ledger = ledger
        self.usageSource = usageSource ?? ledger
        self.now = now
        self.calendar = calendar
        self.config = config
        self.protectionEnabled = protectionEnabled
        self.activity = activity
    }

    // MARK: Admission (#187 §4)

    /// What a fire is allowed to do. One value per branch of §4's "before a run" order, carrying
    /// the figures the row, the pause reason and the card have to name — a card that says a budget
    /// was reached without saying which number reached it tells nobody anything (§9).
    enum Admission: Equatable, Sendable {
        case run
        case dropPaused
        case dropDisabled
        case skipInFlight
        case queued
        case pauseBreaker(count: Int)
        case pauseBudget(scope: String, used: Int, limit: Int)
        /// The ledger could not say what this job has spent, so admission could not be decided.
        /// Not a pause: see `unavailableReason`.
        case dropUnavailable(reason: String)
    }

    /// Why a fire was not started, as a person reads it — `nil` for `.run`. `/jobs run` prints it:
    /// a hand-started fire that admission refused must say so, or the command looks like it worked.
    static func refusalText(_ admission: Admission) -> String? {
        switch admission {
        case .run: return nil
        case .dropPaused: return "it is paused"
        case .dropDisabled: return "it is disabled"
        case .skipInFlight: return "a run is already in progress"
        case .queued: return "a run is already in progress, so this fire is queued behind it"
        case .pauseBreaker(let count): return breakerReason(count: count)
        case .pauseBudget(let scope, let used, let limit):
            return budgetReason(scope: scope, used: used, limit: limit)
        case .dropUnavailable(let reason): return reason
        }
    }

    /// The whole admission decision, as a pure function of the job and four numbers, so the order
    /// can be tested without a ledger, an engine or a clock.
    ///
    /// The order is load-bearing (§4). A paused job is dropped before anything else, because a
    /// pause is already the answer and re-reporting it as an overlap or a budget would write a row
    /// per tick for a job that is not running. An overlap comes next: a run that never started is
    /// not a run, so it must not be counted against the breaker or a budget. The breaker then
    /// outranks the budgets: a job thrashing its way through its allowance should say it is
    /// thrashing, which is the thing a person can act on.
    ///
    /// A zero limit means "no limit": a job that can never run again is a worse reading of
    /// `maxRunsPerHour: 0` than an unbounded one. Nothing configured produces one — `ConfigManager`
    /// reads 0 back as the default — but a hand-written policy can. A *negative* one never reaches
    /// here at all: `JobLimits.resolve` reads it as the typo it is and takes the default.
    static func admit(job: Job, inFlight: Bool, runsLastHour: Int,
                      tokensTodayJob: Int, tokensTodayAll: Int, limits: JobLimits) -> Admission {
        if job.pausedReason != nil { return .dropPaused }
        // Same shape as a pause and for the same reason: `enabled == false` is already the answer,
        // and the scheduler's query never selects one — but a watch fire and `/jobs run` do not
        // come through that query, so the decision has to live here too.
        if !job.enabled { return .dropDisabled }
        if inFlight { return job.policy.overlap == .queue ? .queued : .skipInFlight }
        if limits.maxRunsPerHour > 0, runsLastHour >= limits.maxRunsPerHour {
            return .pauseBreaker(count: runsLastHour)
        }
        if limits.dailyTokens > 0, tokensTodayJob >= limits.dailyTokens {
            return .pauseBudget(scope: "job", used: tokensTodayJob, limit: limits.dailyTokens)
        }
        if limits.globalDailyTokens > 0, tokensTodayAll >= limits.globalDailyTokens {
            return .pauseBudget(scope: "global", used: tokensTodayAll, limit: limits.globalDailyTokens)
        }
        return .run
    }

    /// The pause reason a breaker trip writes — on the job, on its row, and on its card.
    static func breakerReason(count: Int) -> String {
        "breaker: \(count) runs in the last hour"
    }

    /// The pause reason an exhausted daily budget writes. It names the figure that tripped it
    /// (§9): "reached its budget" without the number leaves a person with nothing to decide on.
    static func budgetReason(scope: String, used: Int, limit: Int) -> String {
        "daily token budget reached (\(scope)): \(used) / \(limit)"
    }

    /// What an unreadable ledger writes on the row it skips a fire with. Not a pause: the read
    /// that failed is a transient database error, and pausing the job would turn one bad query
    /// into a stop that only a person typing `/jobs resume` can undo. Fail closed for this fire
    /// only — the next one asks again.
    static func unavailableReason(_ error: any Error) -> String { "admission unavailable: \(error)" }

    /// Whether this run's input was the filesystem's, which is what decides the retry (R7). Three
    /// fires answer yes: a watch fire, the held re-fire standing in for one, and any fire of a
    /// watch job at all — a hand-started one never had paths to begin with, so retrying it minutes
    /// later would re-run the prompt without them, a different run wearing the same name. The next
    /// save is the retry a watch actually has.
    static func isPathDriven(origin: FireOrigin, job: Job) -> Bool {
        origin.isWatcher || job.trigger.kind == Trigger.fsEventKind
    }

    /// The single admission point for every fire, scheduled or watcher-driven (§4). Decides, acts
    /// on the decision (a row, a pause, a card), runs the turn when it is allowed, and afterwards
    /// takes the one trigger the `queue` policy held back.
    ///
    /// `JobScheduler` no longer keeps its own `firing` set: a watch fire never went through it, so
    /// two bursts a second apart used to start two runs of the same job (D2-R9). Overlap is a
    /// property of the job, so it lives where every fire passes.
    ///
    /// Every decision is made on the row read back here, not on the `Job` the caller was handed.
    /// A watcher fire carries the copy `WatcherManager.reload()` captured when the stream was
    /// started, which can be minutes or days old: deciding on it would re-admit a job that has
    /// since been paused — writing a pause row and a card per filesystem event — and would run a
    /// prompt the user has edited since. A job deleted out from under a fire drops silently: there
    /// is nothing left to run, record or report on.
    ///
    /// The ledger reads are synchronous, so nothing suspends between reading `inFlight` and
    /// inserting into it: two fires arriving at once cannot both be admitted.
    /// Returns what admission decided about the fire the *caller* asked for — a held `queue` fire
    /// that follows it does not change that answer — so `/jobs run` can say what happened instead
    /// of claiming a run that never started. `nil` means there was no job left to fire: the row was
    /// deleted out from under the trigger, or could not be read.
    @discardableResult
    func fire(job: Job, origin: FireOrigin) async -> Admission? {
        var origin = origin
        var decided: Admission?
        // A loop, not recursion: the `queue` policy can hand this straight back a trigger, and a
        // busy job would otherwise grow one stack frame per held fire.
        while true {
            let current: Job
            do {
                guard let stored = try ledger.job(id: job.id) else { return decided }
                current = stored
            } catch {
                print("[JobRunner] not firing \(job.name): could not read the job: \(error)")
                return decided
            }

            // `admit`'s first two branches, taken before the two usage queries: a paused or
            // disabled job is the commonest fire there is (a watch on one sees every save), and it
            // must cost nothing and leave nothing behind.
            if current.pausedReason != nil { return decided ?? .dropPaused }
            if !current.enabled { return decided ?? .dropDisabled }

            let at = now()
            let limits = JobLimits.resolve(job: current, config: config)
            let usage: JobUsage
            let tokensAll: Int
            do {
                usage = try usageSource.usage(jobId: current.id, now: at, calendar: calendar)
                tokensAll = try usageSource.tokensToday(jobId: nil, calendar: calendar, now: at)
            } catch {
                // Swallowed, this read used to answer zero — which opens the breaker and both
                // budgets on a job that may be far past either, silently. Skip the fire instead,
                // say so on a row, and leave the job running: see `unavailableReason`.
                let reason = Self.unavailableReason(error)
                print("[JobRunner] not firing \(current.name): \(reason)")
                do {
                    try Self.recordStillborn(job: current, ledger: ledger, reason: reason,
                                             triggerKind: origin.triggerKind, now: at)
                } catch {
                    print("[JobRunner] could not record the skipped fire for \(current.name): \(error)")
                }
                return decided ?? .dropUnavailable(reason: reason)
            }

            let admission = Self.admit(job: current, inFlight: inFlight.contains(current.id),
                                       runsLastHour: usage.runsLastHour,
                                       tokensTodayJob: usage.tokensToday,
                                       tokensTodayAll: tokensAll, limits: limits)
            if decided == nil { decided = admission }
            switch admission {
            case .dropPaused, .dropDisabled, .dropUnavailable:
                return decided
            case .skipInFlight:
                guard !origin.isWatcher else { return decided }
                do {
                    try Self.recordSkip(job: current, ledger: ledger,
                                        triggerKind: origin.triggerKind, now: at)
                } catch {
                    print("[JobRunner] could not record the skipped run for \(current.name): \(error)")
                }
                return decided
            case .queued:
                hold(fire: at, for: current, origin: origin)
                return decided
            case .pauseBreaker(let count):
                await pause(job: current, origin: origin,
                            reason: Self.breakerReason(count: count), at: at)
                return decided
            case .pauseBudget(let scope, let used, let limit):
                await pause(job: current, origin: origin,
                            reason: Self.budgetReason(scope: scope, used: used, limit: limit), at: at)
                return decided
            case .run:
                break
            }

            inFlight.insert(current.id)
            await run(job: current, origin: origin, limits: limits)
            inFlight.remove(current.id)

            guard let held = takeQueuedFire(job: current) else { return decided }
            // The held fire's own origin, wrapped rather than replaced: what woke the job is what
            // the retry ladder decides on, and re-entering as a bare "queued" erased it (R7).
            origin = .queued(from: held)
        }
    }

    /// Forgets everything held in memory for a job that is gone. `/jobs delete` calls it: the
    /// `queuedFire` column goes with the row, but this actor's copy of the origin would outlive it
    /// and be handed to a job created later under the same id.
    func forget(jobId: UUID) {
        queuedOrigins.removeValue(forKey: jobId)
    }

    /// Remembers the one trigger held back while this job is busy. One, never a queue of them: a
    /// job that fell far behind should run once when it is free, not N times in a row.
    private func hold(fire at: Date, for job: Job, origin: FireOrigin) {
        // The origin is the runner's own, not a column: the paths in it are what a watch saw
        // seconds ago, so they are worth carrying into the held fire but not worth surviving a
        // restart — and a second column would be a second thing to keep in step with `queuedFire`.
        // The latest burst wins; a fire with no paths (a scheduled one) leaves whatever a watch
        // left rather than overwriting it with less.
        if !origin.paths.isEmpty || queuedOrigins[job.id] == nil { queuedOrigins[job.id] = origin }
        do {
            guard job.queuedFire == nil else { return }
            try ledger.setQueuedFire(jobId: job.id, at: at)
        } catch {
            // Nothing will take a fire that was never recorded, so the origin must not be left
            // behind either: it would be handed to the *next* held fire as if it were its own.
            queuedOrigins.removeValue(forKey: job.id)
            print("[JobRunner] could not queue a fire for \(job.name): \(error)")
        }
    }

    /// The trigger held back while this job ran, cleared as it is taken — so a trigger arriving
    /// during the *next* run is what refills the slot rather than this one firing forever. `nil`
    /// when nothing was held.
    private func takeQueuedFire(job: Job) -> FireOrigin? {
        let stored: Job?
        do { stored = try ledger.job(id: job.id) } catch {
            print("[JobRunner] could not take the queued fire for \(job.name): \(error)")
            return nil
        }
        guard let stored else {
            // Deleted mid-run: there is no column left to clear, but this actor's copy would
            // outlive the row it belonged to.
            queuedOrigins.removeValue(forKey: job.id)
            return nil
        }
        // The freshly read row's policy, not the snapshot's: a job switched to `skip` mid-run must
        // not take a fire its policy no longer keeps, and one switched to `queue` must. Switched
        // away, the held fire is not deferred, it is abandoned — so both halves of it go, or
        // `/jobs` keeps showing a queued fire nothing will ever take and a later switch back to
        // `queue` inherits a trigger from another era.
        guard stored.policy.overlap == .queue else {
            discardQueuedFire(job: stored)
            return nil
        }
        guard stored.queuedFire != nil else {
            queuedOrigins.removeValue(forKey: job.id)
            return nil
        }
        do {
            try ledger.setQueuedFire(jobId: job.id, at: nil)
        } catch {
            print("[JobRunner] could not clear the queued fire for \(job.name): \(error)")
            return nil
        }
        return queuedOrigins.removeValue(forKey: job.id) ?? .schedule
    }

    /// Drops a held fire that nothing is going to take, column and origin together.
    private func discardQueuedFire(job: Job) {
        queuedOrigins.removeValue(forKey: job.id)
        guard job.queuedFire != nil else { return }
        do {
            try ledger.setQueuedFire(jobId: job.id, at: nil)
        } catch {
            print("[JobRunner] could not drop the queued fire for \(job.name): \(error)")
        }
    }

    /// Stops a job, says why on the job itself, and tells the user once: the reason on a
    /// zero-length `interrupted` row and on a card. Both, because they answer different questions
    /// — `/jobs` shows the row, and the card is the only thing that reaches someone who is not
    /// looking for it.
    private func pause(job: Job, origin: FireOrigin, reason: String, at: Date) async {
        do {
            try ledger.setPaused(jobId: job.id, reason: reason)
        } catch {
            print("[JobRunner] could not pause \(job.name): \(error)")
        }
        do {
            let run = try Self.recordStillborn(job: job, ledger: ledger, reason: reason,
                                               triggerKind: origin.triggerKind, now: at)
            await deliver(EventCard(runId: run.id, jobId: job.id, jobName: job.name,
                                    status: .interrupted, outcome: reason, startedAt: at,
                                    finishedAt: at), for: job)
        } catch {
            print("[JobRunner] could not record the pause for \(job.name): \(error)")
        }
    }

    /// Creates the background conversation, records the run, runs the turn, closes the row and
    /// delivers the card. Never throws: a fire is unattended, so every failure here is logged and
    /// the run is still accounted for in the ledger rather than surfacing to a caller with no one
    /// to tell.
    ///
    /// Private: `fire` is the only way in, so nothing can start a run that skipped admission.
    private func run(job: Job, origin: FireOrigin, limits: JobLimits) async {
        let startedAt = now()
        guard let conversationId = await openConversation(for: job, at: startedAt) else {
            print("[JobRunner] not running \(job.name): \(Self.releasedReason)")
            return
        }

        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: origin.triggerKind,
                         startedAt: startedAt, transcriptConversationId: conversationId)
        do {
            try ledger.begin(run: run)
        } catch {
            // The row is what makes a run visible — without it the turn would burn tokens and a
            // model call with nothing to show for it, and `finish` below would throw anyway.
            // Deleting the job out from under a due tick is the way this happens.
            print("[JobRunner] not running \(job.name): could not record the run: \(error)")
            await closeSession(conversationId, status: "not recorded")
            return
        }
        do {
            // Here, not in the scheduler: this is the moment a turn actually starts, and the
            // scheduler hands triggers over before admission has decided anything (§4).
            try ledger.setLastRun(jobId: job.id, at: startedAt)
        } catch {
            print("[JobRunner] could not stamp the last run of \(job.name): \(error)")
        }

        guard let engine else {
            await closeInterrupted(run: run, conversationId: conversationId, at: now())
            return
        }
        let prompt = await Self.prompt(job: job, changedPaths: origin.paths,
                                       protectionEnabled: protectionEnabled)

        // The wall clock, not the injected `now`: this deadline bounds a turn that is happening
        // right now, so a test (or a replayed occurrence) that pins the ledger's clock to another
        // instant must not make every run time out before its first model call.
        let deadline = Date().addingTimeInterval(TimeInterval(limits.runTimeoutSeconds))
        let budget = TurnBudget(maxTokens: limits.perRunTokens, deadline: deadline)
        // Stay awake for this run, and no longer: the watchdog gives the assertion back at the
        // deadline even when the turn overruns it, so a wedged run cannot hold the Mac awake for
        // the rest of the session. `ActivityHolder` ends once, whichever gets there first.
        let holder = ActivityHolder(api: activity, reason: "Iris job \(job.name)")
        // One claim, taken by whichever of the two gets there first, because "the turn came back"
        // and "the deadline arrived" are a race and the run has exactly one ending. The watchdog
        // used to set a flag unconditionally, so a turn that returned microseconds before the
        // deadline was still written `failed` / "budget: time exceeded" — a completed run reported
        // as a timeout.
        let ending = DeadlineFlag()
        // The turn is a task of its own so the deadline can actually end it. The budget check at
        // the top of each model round cannot: a turn parked inside a model call that never returns
        // never reaches another round, which is exactly the run a timeout exists for.
        let turnTask = Task { [weak engine] in
            await engine?.processInput(prompt, source: "job:\(job.name)",
                                       conversationId: conversationId, turnBudget: budget,
                                       usageSink: LedgerUsageSink(ledger: ledger, runId: run.id,
                                                                  jobName: job.name))
            // Claimed the instant the turn is back, before anything else can suspend: having won,
            // this run ended on its own terms and is never an overrun, whatever the watchdog does
            // next. A turn that lost — one the deadline already gave up on — claims nothing and
            // writes nothing: the row it would have written was closed at the deadline.
            return await ending.claim(deadline: false)
        }
        let watchdog = Task.detached {
            // Sliced, and re-read from the wall clock every time round, because the two clocks
            // are not the same one: `Task.sleep` suspends on the machine's *suspending* clock,
            // which does not advance while the Mac is asleep, and `deadline` is a wall-clock
            // instant. One long sleep across a lid close wakes up however long the Mac slept past
            // the deadline it exists to enforce — holding the assertion, and the run, open for
            // all of it. A slice is at most a minute, so that overshoot is at most a minute.
            while true {
                let seconds = deadline.timeIntervalSinceNow
                if seconds <= 0 { break }
                // Not `try?`: a cancelled sleep means the run finished first, and the two things
                // below are the deadline's alone to do.
                do {
                    let slice = min(seconds, Self.watchdogSlice)
                    try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                } catch { return }
            }
            // Lost the claim: the turn is already over, so ending its assertion and cancelling it
            // are not this task's to do.
            guard await ending.claim(deadline: true) else { return }
            await holder.end()
            // Cooperative, and that is the whole reason this does not wait for it: a turn parked
            // where nothing checks cancellation never comes back, and `run()` returning on the
            // claim below is what stops that wedging the job forever. The orphaned task leaks —
            // a bounded cost, against a job that would otherwise never run again.
            turnTask.cancel()
        }
        // Whichever of them claimed the ending, not `turnTask.value`: awaiting the turn here gave
        // a non-cooperative one the power to hold `fire` open — and with it the job's `inFlight`
        // slot, its `running` row, and a skip row per cadence tick — for as long as it liked.
        let overran = await ending.wait()
        watchdog.cancel()
        await holder.end()
        let finishedAt = now()

        guard let turn = await readTurn(conversationId: conversationId) else {
            await closeInterrupted(run: run, conversationId: conversationId, at: finishedAt)
            return
        }

        // A cancelled turn leaves a transcript that looks like silence, and `noReplyReason` would
        // be a true sentence about the wrong thing. The deadline is why this run ended, so the row
        // says so — this is the only place that knows.
        let status = overran ? .failed : Self.status(messages: turn.messages, denials: turn.denials,
                                                     softStopped: Self.softStopped(in: turn.messages))
        let outcome = Self.outcome(from: turn.messages)
        let blockedTool = overran ? nil : turn.denials.first?.toolName
        let failureReason = overran ? TurnBudget.timeExceeded
            : Self.failureReason(status: status, messages: turn.messages, blockedTool: blockedTool)
        do {
            // The conversation is fresh, so its accumulated `tokenUsage` IS this run's cost.
            try ledger.finish(runId: run.id, status: status, outcome: outcome,
                              failureReason: failureReason, blockedTool: blockedTool,
                              tokens: turn.tokens, finishedAt: finishedAt)
        } catch {
            print("[JobRunner] could not close the run for \(job.name): \(error)")
        }

        // Decided before the card is built, because what happens to the schedule next is part of
        // what the card has to say: "failed" and "failed, trying again in a minute" are different
        // news to someone who has to decide whether to go and look.
        let retry = Self.retryDecision(status: status, attempt: job.retryAttempt,
                                       retryEnabled: job.policy.retry,
                                       watcherFire: Self.isPathDriven(origin: origin, job: job),
                                       now: finishedAt)
        await apply(retry, job: job, status: status)

        let card = EventCard(runId: run.id, jobId: job.id, jobName: job.name, status: status,
                             // A card shows one line. With no reply to show, that line is why
                             // there is none (§6.2) — a blank failed card tells nobody anything.
                             outcome: Self.cardOutcome(outcome ?? failureReason, retry: retry,
                                                       now: finishedAt),
                             blockedTool: blockedTool,
                             startedAt: startedAt, finishedAt: finishedAt,
                             totalTokens: turn.tokens.totalTokenCount,
                             transcriptConversationId: conversationId)
        await closeSession(conversationId, status: card.statusText)
        await deliver(card, for: job)
    }

    // MARK: Retry and pause (#187 §4, "after a run")

    /// The ladder a failing job climbs: one minute, five, twenty-five. Long enough that a provider
    /// outage or a rate limit has a chance to clear between attempts, short enough that a job
    /// whose next scheduled fire is hours away still gets a second chance today.
    static let backoff: [TimeInterval] = [60, 300, 1_500]

    /// The pause reason the run after the last rung writes. Three failures in a row is not a
    /// transient failure any more, and a job that keeps failing keeps spending.
    static let retriesExhaustedReason = "failed 3 times; paused"

    /// What a finished run does to the job's schedule.
    enum RetryDecision: Equatable, Sendable {
        case none
        case retry(at: Date)
        case pause(reason: String)
    }

    /// Pure, so the whole ladder can be read at once. Only `failed` retries: `blockedOnApproval`
    /// needs a person (running it again would block again), `interrupted` was not the job's doing,
    /// and `completed` has nothing to try again — it is the caller that clears the ladder, because
    /// "no change" and "reset to zero" are the same decision here.
    ///
    /// A watch fire does not retry either, whatever its policy says. Its input is the paths the
    /// filesystem handed it, and a retry minutes later would re-run the prompt without them — a
    /// different run wearing the same name. The next save re-runs it with real paths, which is the
    /// retry a watch actually has.
    static func retryDecision(status: JobRun.Status, attempt: Int, retryEnabled: Bool,
                              watcherFire: Bool, now: Date) -> RetryDecision {
        guard status == .failed, retryEnabled, !watcherFire else { return .none }
        guard attempt < backoff.count else { return .pause(reason: retriesExhaustedReason) }
        return .retry(at: now.addingTimeInterval(backoff[attempt]))
    }

    /// Writes the decision to the job row. The next fire is moved to the retry instant rather than
    /// left on the cadence: a job on a daily schedule that failed at 09:00 should try again at
    /// 09:01, and the scheduler recomputes the ordinary cadence from the run after it.
    private func apply(_ decision: RetryDecision, job: Job, status: JobRun.Status) async {
        do {
            switch decision {
            case .none:
                // A run that finally worked is off the ladder. Read back rather than reusing the
                // snapshot's `nextFireAt`: the scheduler advanced the cadence before this fire.
                guard status == .completed, job.retryAttempt > 0 else { return }
                let stored = try ledger.job(id: job.id)
                try ledger.setRetry(jobId: job.id, attempt: 0, nextFireAt: stored?.nextFireAt)
            case .retry(let at):
                try ledger.setRetry(jobId: job.id, attempt: job.retryAttempt + 1, nextFireAt: at)
            case .pause(let reason):
                // The attempt count is left where it is: `/jobs resume` clears both, and until
                // then the table can say how the job got here.
                try ledger.setPaused(jobId: job.id, reason: reason)
            }
        } catch {
            print("[JobRunner] could not record the retry state of \(job.name): \(error)")
        }
    }

    /// The card's one line, with what happens next on the end of it. A run that is going to be
    /// tried again and one that has given up look identical otherwise, and the difference is the
    /// whole question a person reading the card is asking.
    static func cardOutcome(_ base: String?, retry: RetryDecision, now: Date) -> String? {
        switch retry {
        case .none:
            return base
        case .retry(let at):
            return join(base, "retrying in \(retryDelayText(at.timeIntervalSince(now)))")
        case .pause(let reason):
            return join(base, reason)
        }
    }

    private static func join(_ base: String?, _ tail: String) -> String {
        guard let base, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return tail }
        return base + " — " + tail
    }

    /// One unit, the way the next-fire column reads: "1 m", "25 m", "2 h".
    static func retryDelayText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(0, Int(seconds.rounded()))) s" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) m" }
        return "\(Int((seconds / 3_600).rounded())) h"
    }

    /// The run's own hidden conversation, registered in the session strip. `nil` when the app
    /// state has been released — there is nothing to run a turn against, and no row has been
    /// written yet, so the fire is simply dropped.
    private func openConversation(for job: Job, at startedAt: Date) async -> UUID? {
        guard let state else { return nil }
        let title = "\(job.name) · \(ISO8601DateFormatter().string(from: startedAt))"
        return await MainActor.run { () -> UUID in
            let id = state.createNewConversation(isBackground: true, title: title)
            // `.mutating` is the only profile that asks for a container. `.readOnly` leaves the
            // field nil deliberately: nil means "fall through to the per-workspace/global
            // default", which is not the same as pinning this run to the host (§9).
            if job.profile == .mutating, let idx = state.conversations.firstIndex(where: { $0.id == id }) {
                state.conversations[idx].mainAgentSandbox = .sandboxed
            }
            // The strip is the only place a run in flight is visible at all, since the
            // conversation itself is hidden.
            state.registerSubagent(id: id, role: "job:\(job.name)", kind: .job)
            return id
        }
    }

    /// What the finished turn left behind. `nil` when the app state went away while it ran.
    private struct TurnResult {
        let messages: [ChatMessage]
        let denials: [BlockedToolCall]
        let tokens: TokenUsage
    }

    private func readTurn(conversationId: UUID) async -> TurnResult? {
        guard let state else { return nil }
        return await MainActor.run { () -> TurnResult in
            let conversation = state.conversations.first(where: { $0.id == conversationId })
            // Taken, not read: the denials belong to this run, and leaving them behind would mark
            // the next run in the same conversation blocked too (there is no next run in the same
            // conversation today, but the drain is what guarantees that).
            return TurnResult(messages: conversation?.messages ?? [],
                              denials: state.takeBackgroundDenials(for: conversationId),
                              tokens: conversation?.tokenUsage ?? TokenUsage())
        }
    }

    /// Closes a run whose app state disappeared under it: the same shape as the sweep at the next
    /// launch, because it is the same situation — nothing will ever finish this turn. No card:
    /// there is nowhere to deliver one to.
    private func closeInterrupted(run: JobRun, conversationId: UUID, at: Date) async {
        // The normal path drains through `readTurn`; this one has to drain too, or a denial (and
        // the descendant links behind it) outlives the run that caused it in `AppState`.
        if let state {
            await MainActor.run { _ = state.takeBackgroundDenials(for: conversationId) }
        }
        do {
            try ledger.finish(runId: run.id, status: .interrupted, outcome: nil,
                              failureReason: Self.releasedReason, blockedTool: nil,
                              tokens: TokenUsage(), finishedAt: at)
        } catch {
            print("[JobRunner] could not close the released run for \(run.jobName): \(error)")
        }
        await closeSession(conversationId, status: "interrupted")
    }

    private func closeSession(_ conversationId: UUID, status: String) async {
        guard let state else { return }
        await MainActor.run { state.finishSession(id: conversationId, status: status) }
    }

    private func deliver(_ card: EventCard, for job: Job) async {
        guard let state else { return }
        let destination = await MainActor.run { () -> UUID in
            // A destination that has since been deleted falls back to Activity rather than
            // dropping the card: `deliverEvent` is a no-op for an unknown id, and a run nobody
            // hears about is the failure mode this whole deliverable exists to fix.
            if let wanted = job.destinationConversationId,
               state.conversations.contains(where: { $0.id == wanted }) {
                return wanted
            }
            return state.activityConversationId()
        }
        await state.deliverEvent(card, to: destination)
    }

    /// The job's prompt, plus the paths that woke it when a watch did.
    ///
    /// The job's own prompt is trusted — the user (or the agent on their behalf) wrote it. The
    /// paths are not: a filename is chosen by whoever can write into the watched directory, and
    /// D1 put every fire through `handleSystemEvent`, which sanitized it. So each path goes
    /// through the structural pass and the whole block through the tiered guard, arriving wrapped
    /// in `<untrusted_context>` after the instructions rather than concatenated into them.
    static func prompt(job: Job, changedPaths: [String], protectionEnabled: Bool? = nil) async -> String {
        guard !changedPaths.isEmpty else { return job.prompt }
        let listed = changedPaths
            .map { "- " + PromptInjectionGuard.sanitizeUntrustedInput($0) }
            .joined(separator: "\n")
        let block = await InjectionGuard.sanitize("Changed paths:\n" + listed,
                                                  contextTag: "fs_event_paths",
                                                  maxTier: .tier3_canary,
                                                  protectionEnabled: protectionEnabled)
        return job.prompt + "\n\n" + block
    }

    /// The first line of the last thing the agent said, capped at 200 characters — the one line a
    /// card and `/jobs` show. `nil` when the run said nothing at all, which `status` treats as a
    /// failure: an empty bubble is no more of a reply than no bubble, so both land here.
    static func outcome(from messages: [ChatMessage]) -> String? {
        guard let last = messages.last(where: { $0.role == .agent }) else { return nil }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(200))
    }

    /// Fail-closed precedence (§6.2). A denial outranks everything: it is the one outcome a person
    /// can do something about, and it is the reason the run stopped short even if the turn also
    /// errored on its way out. An `[LLM_ERROR]` outranks a soft stop for the same reason — it says
    /// what actually broke, where a soft stop only says the loop was cut off. Last, a turn that
    /// reached the end with nothing said is a failure too: a hook that blocked the turn, a
    /// cancelled engine or a conversation deleted mid-run all land here, and reporting any of them
    /// as `completed` would put a green card on a run that did nothing.
    static func status(messages: [ChatMessage], denials: [BlockedToolCall], softStopped: Bool) -> JobRun.Status {
        if !denials.isEmpty { return .blockedOnApproval }
        if llmErrorHeadline(in: messages) != nil { return .failed }
        if softStopped { return .failed }
        if outcome(from: messages) == nil { return .failed }
        return .completed
    }

    /// The headline of the last failed model call in the transcript. An `[LLM_ERROR]` is a
    /// `.system` message holding encoded JSON, NOT something the agent said — scanning `.agent`
    /// text for it would find nothing.
    static func llmErrorHeadline(in messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .system && LLMErrorMessage.parse($0.content) != nil }
            .flatMap { LLMErrorMessage.parse($0.content)?.headline }
    }

    /// Whether the turn was cut short rather than ending on its own: the loop detector, a
    /// blocked-result run, or an exhausted per-run budget. The signal is the `.system` line the
    /// engine posts, matched on its shared marker rather than on a copy of the sentence — and on
    /// either marker, because the budget stop deliberately does not claim to be summarizing
    /// (`IrisEngine.budgetStopMarker`).
    static func softStopped(in messages: [ChatMessage]) -> Bool {
        softStopLine(in: messages) != nil
    }

    private static func softStopLine(in messages: [ChatMessage]) -> String? {
        messages.last {
            $0.role == .system
                && ($0.content.contains(IrisEngine.softStopMarker)
                    || $0.content.contains(IrisEngine.budgetStopMarker))
        }?.content
    }

    /// The budget a stop line names, if that is what stopped the turn. The reason on its own, not
    /// the whole line: the row and the card say "budget: tokens exceeded — retrying in 1 m", and
    /// the origin prefix and the marker sentence are for the person reading the transcript.
    static func budgetStopReason(in messages: [ChatMessage]) -> String? {
        guard let line = softStopLine(in: messages), line.contains(IrisEngine.budgetStopMarker)
        else { return nil }
        return [TurnBudget.tokensExceeded, TurnBudget.timeExceeded].first { line.contains($0) }
    }

    /// What the row records about why a run did not simply complete — and, when the run left no
    /// reply to show, what the card prints in its place.
    static func failureReason(status: JobRun.Status, messages: [ChatMessage],
                              blockedTool: String?) -> String? {
        switch status {
        case .blockedOnApproval:
            return "needs approval: \(blockedTool ?? "a gated tool")"
        case .failed:
            return llmErrorHeadline(in: messages) ?? budgetStopReason(in: messages)
                ?? softStopLine(in: messages) ?? noReplyReason
        case .running, .completed, .interrupted:
            return nil
        }
    }

    /// The row an overlap skip writes: a run that started and ended in the same instant, with no
    /// transcript, because no turn ever happened. `interrupted` rather than `failed` — nothing
    /// went wrong, the previous copy was simply still going, and `failed` would put it in front of
    /// a person as something to fix.
    static func recordSkip(job: Job, ledger: JobLedger, triggerKind: String, now: Date) throws {
        _ = try recordStillborn(job: job, ledger: ledger, reason: skipReason,
                                triggerKind: triggerKind, now: now)
    }

    /// A run that never happened, recorded so `/jobs` can show why: begun and finished at the same
    /// instant, `interrupted`, no transcript, no tokens. Every admission branch that refuses a
    /// fire and owes the user an explanation writes one — the overlap skip, both pauses and an
    /// unreadable ledger.
    ///
    /// `triggerKind` is the *fire's*, not `job.trigger.kind`: what was refused was a hand-started
    /// fire or a held one, and a row saying "fsEvent" because that is how the job is configured
    /// describes a fire that never happened.
    @discardableResult
    static func recordStillborn(job: Job, ledger: JobLedger, reason: String, triggerKind: String,
                                now: Date) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: triggerKind,
                         startedAt: now, status: .interrupted)
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: .interrupted, outcome: nil,
                          failureReason: reason, blockedTool: nil,
                          tokens: TokenUsage(), finishedAt: now)
        return run
    }
}

/// The run row's own meter: what the turn has spent, written after every model round while the run
/// is still open (#187 §4). Failures are logged and dropped — a ledger that cannot take a progress
/// figure is not a reason to stop a turn that is working, and `finish` writes the total again at
/// the end.
private struct LedgerUsageSink: TurnUsageSink {
    let ledger: JobLedger
    let runId: UUID
    let jobName: String

    func record(_ tokens: TokenUsage) async {
        do {
            try ledger.recordUsage(runId: runId, tokens: tokens)
        } catch {
            print("[JobRunner] could not record the spend of \(jobName): \(error)")
        }
    }
}

/// Which of the two racers gets to say how a run ended, and the one place the run waits to hear
/// it. The turn returning and the deadline arriving are concurrent by construction, so the
/// decision is a single claim rather than a flag: the winner owns it, and the loser does nothing
/// at all. An actor because the two are different tasks — and because "read it, then decide"
/// across a suspension is the race this replaces.
actor DeadlineFlag {
    /// How the run ended, once either racer has said so: `true` when it was the deadline. `nil`
    /// until one of them claims it.
    private var ending: Bool?
    /// `run()`, parked in `wait()`. One at a time, by construction: a run has one waiter.
    private var waiter: CheckedContinuation<Bool, Never>?

    /// `true` for exactly one caller, ever. `deadline` says which racer took it, so the waiter is
    /// told how the run ended rather than having to ask afterwards.
    @discardableResult
    func claim(deadline: Bool) -> Bool {
        guard ending == nil else { return false }
        ending = deadline
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: deadline)
        }
        return true
    }

    /// Returns as soon as either racer has claimed the ending — `true` when it was the deadline.
    /// This is what lets the deadline win the *wait* and not only the claim: a turn parked
    /// somewhere that never checks cancellation is left behind rather than kept waited on, and the
    /// run closes its row and gives the job back.
    func wait() async -> Bool {
        if let ending { return ending }
        return await withCheckedContinuation { self.waiter = $0 }
    }
}

/// What woke a job, carried whole through `fire`'s loop (§4). A string reason could not: a held
/// fire re-entered as "queued" and a hand-started one as "manual", so by the time the retry ladder
/// asked whether the filesystem was the input, the answer had been thrown away (R7).
indirect enum FireOrigin: Equatable, Sendable {
    /// A cadence came due. `kind` is the job's trigger kind, so a polled job's row still reads
    /// "poll" instead of flattening to "schedule" — the column is queried.
    case cadence(kind: String)
    case watcher(paths: [String])
    /// `/jobs run`, or anything else a person started by hand.
    case manual
    /// A fire the `queue` policy held while the previous run finished, standing in for the fire
    /// that was actually held.
    case queued(from: FireOrigin)

    /// The ordinary scheduled fire.
    static let schedule = FireOrigin.cadence(kind: "schedule")

    /// What the `job_runs` row records.
    var triggerKind: String {
        switch self {
        case .cadence(let kind): return kind
        case .watcher: return Trigger.fsEventKind
        case .manual: return "manual"
        case .queued: return "queued"
        }
    }

    /// The fire this one stands in for: itself, unless it is a held re-fire.
    var root: FireOrigin {
        if case .queued(let from) = self { return from.root }
        return self
    }

    /// The paths the filesystem handed this fire — the held re-fire of a watch fire carries them
    /// too, which is the whole reason the origin is kept rather than the reason string.
    var paths: [String] {
        if case .watcher(let paths) = root { return paths }
        return []
    }

    var isWatcher: Bool {
        if case .watcher = root { return true }
        return false
    }
}

/// The numbers one fire is judged against: the job's own policy where it set one, the global
/// `ConfigManager` defaults where it did not (§0.1). Resolved once per fire rather than read
/// field by field, so a run and the card that reports it cannot disagree about what its budget was.
struct JobLimits: Equatable, Sendable {
    let maxRunsPerHour: Int
    let dailyTokens: Int
    /// Across every job. Deliberately not overridable per job: it is the ceiling on the whole
    /// unattended system, and a job that could raise its own share of it is not a ceiling.
    let globalDailyTokens: Int
    let perRunTokens: Int
    let runTimeoutSeconds: Int

    static func resolve(job: Job, config: ConfigManager) -> JobLimits {
        let policy = job.policy
        // `runTimeoutSeconds` is the one non-optional override on `JobPolicy`, so "the job set it"
        // has to be read as "it is not the struct's own default" — which is what lets the global
        // stepper still move every job that never asked for a timeout of its own.
        //
        // Zero (or less) takes the global default too, and deliberately does NOT mean "no timeout"
        // the way a zero token budget does: a budget bounds spend, which a person may reasonably
        // want unbounded, while this bounds a turn that has stopped responding — and a run nothing
        // can end is the failure the whole deliverable is about. Nothing configurable writes one;
        // a hand-edited policy can.
        let overridden = policy.runTimeoutSeconds > 0
            && policy.runTimeoutSeconds != JobPolicy().runTimeoutSeconds
        let timeout = overridden ? policy.runTimeoutSeconds
            : global(config.jobRunTimeoutSeconds, default: ConfigManager.JobDefaults.runTimeoutSeconds)
        return JobLimits(
            maxRunsPerHour: limit(policy.maxRunsPerHour, global: config.jobMaxRunsPerHour,
                                  default: ConfigManager.JobDefaults.maxRunsPerHour),
            dailyTokens: limit(policy.dailyTokenBudget, global: config.jobDailyTokenBudget,
                               default: ConfigManager.JobDefaults.dailyTokenBudget),
            globalDailyTokens: global(config.jobGlobalDailyTokenBudget,
                                      default: ConfigManager.JobDefaults.globalDailyTokenBudget),
            perRunTokens: limit(policy.perRunTokenBudget, global: config.jobPerRunTokenBudget,
                                default: ConfigManager.JobDefaults.perRunTokenBudget),
            runTimeoutSeconds: timeout)
    }

    /// A per-job override where the job set a usable one, the global number otherwise.
    ///
    /// A *negative* override is not an override. Zero is kept, and does mean "unlimited" for the
    /// token budgets and the breaker (see the note above) — but nobody writes -1 to mean
    /// unlimited, so it reads as the typo it is and takes the default exactly as an absent value
    /// does. Reading it the other way would silently take a job's ceiling off, which is the one
    /// direction these numbers must never fail in.
    private static func limit(_ override: Int?, global value: Int, default fallback: Int) -> Int {
        if let override, override >= 0 { return override }
        return global(value, default: fallback)
    }

    /// The global number, or the spec's figure when nothing usable is stored. `ConfigManager`
    /// already reads a non-positive key back as the default; this is the same reading applied to
    /// a value set after launch, so one settings write cannot leave the whole unattended system
    /// unbounded for the rest of the session.
    private static func global(_ value: Int, default fallback: Int) -> Int {
        value > 0 ? value : fallback
    }
}
