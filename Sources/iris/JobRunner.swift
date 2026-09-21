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

    /// Weak, both of them: `AppState` owns the engine, the engine owns this runner for the life of
    /// the process, and a strong reference back either way is a cycle that keeps a whole app state
    /// — conversations, store, sessions — alive forever. Each hop below re-reads them and bails
    /// (closing the ledger row) rather than keeping one. `state` is held only for the length of a
    /// single main-actor hop; `engine` is held across `processInput`, because that call IS the
    /// run and an engine deallocated halfway through its own turn is not a state worth surviving.
    private weak var state: AppState?
    private weak var engine: IrisEngine?
    private let ledger: JobLedger
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
    /// The changed paths belonging to a held (`policy.overlap == .queue`) fire, by job. In memory
    /// on purpose: see `hold(fire:for:paths:)`.
    private var queuedPaths: [UUID: [String]] = [:]

    init(state: AppState, engine: IrisEngine, ledger: JobLedger,
         now: @escaping @Sendable () -> Date = Date.init,
         calendar: Calendar = .current,
         config: ConfigManager = .shared,
         protectionEnabled: Bool? = nil,
         activity: any ActivityAPI = ProcessInfoActivity()) {
        self.state = state
        self.engine = engine
        self.ledger = ledger
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
        case skipInFlight
        case queued
        case pauseBreaker(count: Int)
        case pauseBudget(scope: String, used: Int, limit: Int)
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
    /// A non-positive limit means "no limit". Nothing configured can produce one — `ConfigManager`
    /// reads 0 back as the default — but a hand-written policy can, and a job that can never run
    /// again is a worse reading of `maxRunsPerHour: 0` than an unbounded one.
    static func admit(job: Job, inFlight: Bool, runsLastHour: Int,
                      tokensTodayJob: Int, tokensTodayAll: Int, limits: JobLimits) -> Admission {
        if job.pausedReason != nil { return .dropPaused }
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

    /// A fire that came from a filesystem watch. FSEvents delivers a burst per save, so the
    /// overlap it causes is not news: it is dropped without a row, where a scheduled overlap
    /// writes one. D2's decision, kept — a row per dropped event would bury the ledger far worse
    /// than the overlap it recorded.
    static func isWatcherFire(reason: String) -> Bool { reason.hasPrefix("fsEvent") }

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
    func fire(job: Job, reason: String, changedPaths: [String] = []) async {
        var reason = reason
        var paths = changedPaths
        // A loop, not recursion: the `queue` policy can hand this straight back a trigger, and a
        // busy job would otherwise grow one stack frame per held fire.
        while true {
            let current: Job
            do {
                guard let stored = try ledger.job(id: job.id) else { return }
                current = stored
            } catch {
                print("[JobRunner] not firing \(job.name): could not read the job: \(error)")
                return
            }

            // `admit`'s first branch, taken before the two usage queries: a paused job is the
            // commonest fire there is (a watch on a paused job sees every save), and it must cost
            // nothing and leave nothing behind.
            if current.pausedReason != nil { return }

            let at = now()
            let limits = JobLimits.resolve(job: current, config: config)
            let usage = (try? ledger.usage(jobId: current.id, now: at, calendar: calendar))
                ?? JobUsage(tokensToday: 0, runsLastHour: 0)
            let tokensAll = (try? ledger.tokensToday(jobId: nil, calendar: calendar, now: at)) ?? 0

            switch Self.admit(job: current, inFlight: inFlight.contains(current.id),
                              runsLastHour: usage.runsLastHour, tokensTodayJob: usage.tokensToday,
                              tokensTodayAll: tokensAll, limits: limits) {
            case .dropPaused:
                return
            case .skipInFlight:
                guard !Self.isWatcherFire(reason: reason) else { return }
                do {
                    try Self.recordSkip(job: current, ledger: ledger, now: at)
                } catch {
                    print("[JobRunner] could not record the skipped run for \(current.name): \(error)")
                }
                return
            case .queued:
                hold(fire: at, for: current, paths: paths)
                return
            case .pauseBreaker(let count):
                await pause(job: current, reason: Self.breakerReason(count: count), at: at)
                return
            case .pauseBudget(let scope, let used, let limit):
                await pause(job: current,
                            reason: Self.budgetReason(scope: scope, used: used, limit: limit), at: at)
                return
            case .run:
                break
            }

            inFlight.insert(current.id)
            await run(job: current, reason: reason, changedPaths: paths, limits: limits)
            inFlight.remove(current.id)

            guard let held = takeQueuedFire(job: current) else { return }
            reason = "queued"
            paths = held
        }
    }

    /// Remembers the one trigger held back while this job is busy. One, never a queue of them: a
    /// job that fell far behind should run once when it is free, not N times in a row.
    private func hold(fire at: Date, for job: Job, paths: [String]) {
        // The paths are the runner's own, not a column: they are what a watch saw seconds ago, so
        // they are worth carrying into the held fire but not worth surviving a restart — and a
        // `queuedPaths` column would be a second thing to keep in step with `queuedFire`. The
        // latest burst wins; an empty list (a scheduled fire) leaves whatever a watch left.
        if !paths.isEmpty { queuedPaths[job.id] = paths }
        do {
            guard job.queuedFire == nil else { return }
            try ledger.setQueuedFire(jobId: job.id, at: at)
        } catch {
            print("[JobRunner] could not queue a fire for \(job.name): \(error)")
        }
    }

    /// The trigger held back while this job ran, cleared as it is taken — so a trigger arriving
    /// during the *next* run is what refills the slot rather than this one firing forever. `nil`
    /// when nothing was held; an empty array is a held fire that carried no paths.
    private func takeQueuedFire(job: Job) -> [String]? {
        let stored: Job?
        do { stored = try ledger.job(id: job.id) } catch {
            print("[JobRunner] could not take the queued fire for \(job.name): \(error)")
            return nil
        }
        // The freshly read row's policy, not the snapshot's: a job switched to `skip` mid-run must
        // not take a fire its policy no longer keeps, and one switched to `queue` must.
        guard let stored, stored.policy.overlap == .queue, stored.queuedFire != nil else { return nil }
        do {
            try ledger.setQueuedFire(jobId: job.id, at: nil)
        } catch {
            print("[JobRunner] could not clear the queued fire for \(job.name): \(error)")
            return nil
        }
        return queuedPaths.removeValue(forKey: job.id) ?? []
    }

    /// Stops a job, says why on the job itself, and tells the user once: the reason on a
    /// zero-length `interrupted` row and on a card. Both, because they answer different questions
    /// — `/jobs` shows the row, and the card is the only thing that reaches someone who is not
    /// looking for it.
    private func pause(job: Job, reason: String, at: Date) async {
        do {
            try ledger.setPaused(jobId: job.id, reason: reason)
        } catch {
            print("[JobRunner] could not pause \(job.name): \(error)")
        }
        do {
            let run = try Self.recordStillborn(job: job, ledger: ledger, reason: reason, now: at)
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
    private func run(job: Job, reason: String, changedPaths: [String] = [], limits: JobLimits) async {
        let startedAt = now()
        guard let conversationId = await openConversation(for: job, at: startedAt) else {
            print("[JobRunner] not running \(job.name): \(Self.releasedReason)")
            return
        }

        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: reason, startedAt: startedAt,
                         transcriptConversationId: conversationId)
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
        let prompt = await Self.prompt(job: job, changedPaths: changedPaths,
                                       protectionEnabled: protectionEnabled)

        // The wall clock, not the injected `now`: this deadline bounds a turn that is happening
        // right now, so a test (or a replayed occurrence) that pins the ledger's clock to another
        // instant must not make every run time out before its first model call.
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, limits.runTimeoutSeconds)))
        let budget = TurnBudget(maxTokens: limits.perRunTokens, deadline: deadline)
        // Stay awake for this run, and no longer: the watchdog gives the assertion back at the
        // deadline even when the turn overruns it, so a wedged run cannot hold the Mac awake for
        // the rest of the session. `ActivityHolder` ends once, whichever gets there first.
        let holder = ActivityHolder(api: activity, reason: "Iris job \(job.name)")
        let watchdog = Task.detached {
            let seconds = deadline.timeIntervalSinceNow
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await holder.end()
        }
        await engine.processInput(prompt, source: "job:\(job.name)", conversationId: conversationId,
                                  turnBudget: budget)
        watchdog.cancel()
        await holder.end()
        let finishedAt = now()

        guard let turn = await readTurn(conversationId: conversationId) else {
            await closeInterrupted(run: run, conversationId: conversationId, at: finishedAt)
            return
        }

        let status = Self.status(messages: turn.messages, denials: turn.denials,
                                 softStopped: Self.softStopped(in: turn.messages))
        let outcome = Self.outcome(from: turn.messages)
        let blockedTool = turn.denials.first?.toolName
        let failureReason = Self.failureReason(status: status, messages: turn.messages,
                                               blockedTool: blockedTool)
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
                                       retryEnabled: job.policy.retry, now: finishedAt)
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
    static func retryDecision(status: JobRun.Status, attempt: Int, retryEnabled: Bool,
                              now: Date) -> RetryDecision {
        guard status == .failed, retryEnabled else { return .none }
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

    /// Whether the loop detector (or a blocked-result run) cut the turn short. The signal is the
    /// `.system` line `IrisEngine.softStopWithSummary` posts, matched on the shared marker rather
    /// than a copy of the sentence.
    static func softStopped(in messages: [ChatMessage]) -> Bool {
        softStopLine(in: messages) != nil
    }

    private static func softStopLine(in messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .system && $0.content.contains(IrisEngine.softStopMarker) }?.content
    }

    /// What the row records about why a run did not simply complete — and, when the run left no
    /// reply to show, what the card prints in its place.
    static func failureReason(status: JobRun.Status, messages: [ChatMessage],
                              blockedTool: String?) -> String? {
        switch status {
        case .blockedOnApproval:
            return "needs approval: \(blockedTool ?? "a gated tool")"
        case .failed:
            return llmErrorHeadline(in: messages) ?? softStopLine(in: messages) ?? noReplyReason
        case .running, .completed, .interrupted:
            return nil
        }
    }

    /// The row an overlap skip writes: a run that started and ended in the same instant, with no
    /// transcript, because no turn ever happened. `interrupted` rather than `failed` — nothing
    /// went wrong, the previous copy was simply still going, and `failed` would put it in front of
    /// a person as something to fix.
    static func recordSkip(job: Job, ledger: JobLedger, now: Date) throws {
        _ = try recordStillborn(job: job, ledger: ledger, reason: skipReason, now: now)
    }

    /// A run that never happened, recorded so `/jobs` can show why: begun and finished at the same
    /// instant, `interrupted`, no transcript, no tokens. Every admission branch that refuses a
    /// fire and owes the user an explanation writes one — the overlap skip and both pauses.
    @discardableResult
    static func recordStillborn(job: Job, ledger: JobLedger, reason: String, now: Date) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: job.trigger.kind,
                         startedAt: now, status: .interrupted)
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: .interrupted, outcome: nil,
                          failureReason: reason, blockedTool: nil,
                          tokens: TokenUsage(), finishedAt: now)
        return run
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
        let timeout = policy.runTimeoutSeconds == JobPolicy().runTimeoutSeconds
            ? config.jobRunTimeoutSeconds : policy.runTimeoutSeconds
        return JobLimits(maxRunsPerHour: policy.maxRunsPerHour ?? config.jobMaxRunsPerHour,
                         dailyTokens: policy.dailyTokenBudget ?? config.jobDailyTokenBudget,
                         globalDailyTokens: config.jobGlobalDailyTokenBudget,
                         perRunTokens: policy.perRunTokenBudget ?? config.jobPerRunTokenBudget,
                         runTimeoutSeconds: timeout)
    }
}
