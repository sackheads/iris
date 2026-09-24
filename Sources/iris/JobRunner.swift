import Foundation

/// A run's prompt and what the untrusted half of it cost (#187 deliverable 4, spec §2).
///
/// Two figures rather than one, because the row and the card have to tell the two apart: a watch
/// fire that delivered 100 of 1,500 changed paths is working as designed, and one that delivered
/// none because the guard blocked the block is a thing a person needs to know happened.
struct PromptBuild: Sendable, Equatable {
    let text: String
    /// Paths that actually reached the prompt — 0 when the guard withheld the block.
    let delivered: Int
    /// The guard blocked the block, so the run got the marker and no paths at all.
    let pathsWithheld: Bool
}

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
    static let defaultWatchdogSlice: TimeInterval = 60

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
    /// How long the deadline watchdog sleeps between looks at the wall clock. Injected only so a
    /// test can drive the loop round more than once without waiting a minute to do it.
    private let watchdogSlice: TimeInterval
    /// How a run keeps the Mac awake for its own duration (§4). Injected so a test can watch the
    /// begin/end pair instead of asserting on the machine's real power state.
    private let activity: any ActivityAPI
    /// Whether a `mutating` job has the VM it is promised, asked afresh at every fire (§0.2, R12).
    /// A creation-time check only describes the day the job was made: the user can uninstall the
    /// runtime or turn sandboxing off at any point, and `SandboxPolicy.resolve` would then quietly
    /// downgrade the run's pinned `.sandboxed` to the host. Injected so a test can pin the answer.
    private let sandboxAvailable: @Sendable () -> Bool
    /// What asks a job's gate whether anything changed (§7). Injected so a test can answer for it
    /// without a network, a file or a VM; in the app it is `GateEvaluator` over the real three.
    private let gateEvaluator: @Sendable (Gate, String?) async -> GateResult
    /// The ledger's own `lastGateSignal`, except where a test needs that one read to fail — the
    /// same reason `usageSource` exists. A gate whose previous signal cannot be read is a gate
    /// error like any other, and there is no other way to make only that read fail.
    private let lastGateSignal: @Sendable (UUID) throws -> String?
    /// Ends the run's container when the run closes (§2). Injected so a test can watch which
    /// conversations were ended without touching `SandboxSessionManager.shared` (invariant 7).
    private let endSandboxSession: @Sendable (UUID) async -> Void
    /// Makes sure the host-only network a `network: false` grant runs on exists (§0.7), answering
    /// the failure detail or nil. Injected so a test can answer without a runtime; the default
    /// asks the real `CLIContainerRuntime`.
    private let ensureIsolatedNetwork: @Sendable () async -> String?
    /// The jobs with a run in flight right now. Every fire goes through `fire`, so one set here is
    /// the whole overlap story, whatever woke the job.
    private var inFlight: Set<UUID> = []
    /// The origin of a held (`policy.overlap == .queue`) fire, by job. In memory on purpose: see
    /// `hold(fire:for:origin:note:)`.
    private var queuedOrigins: [UUID: FireOrigin] = [:]
    /// The catch-up count a held fire was carrying when it was held, by job (R44). A `queue` job
    /// still running from before the sleep is one of the two commonest ways the first slot of a
    /// catch-up burst ends, and the held fire is where that count goes: it is the same fire, taken
    /// later, so it arrives on the row and card that fire eventually writes.
    private var queuedNotes: [UUID: String] = [:]
    /// What a watch has seen since the fire that was held, and what it counted seeing it —
    /// `WatchCoordinator.takeHeldPaths` in the app, injected here because the coordinator owns the
    /// runner's fire handler and a reference the other way would be a cycle (and, in a test, a
    /// real event source). Optional: the `--run-job` process and every test that is not about
    /// watches has no coordinator at all, and a held re-fire there is exactly what it was before
    /// this deliverable — its paths, and a null summary column rather than invented arithmetic.
    private var heldPathsSource: (@Sendable (UUID) async -> (paths: [String], summary: WatchSummary?))?

    /// Wires the coordinator's held paths into the re-fire (#187 deliverable 4, §3). Set once at
    /// launch, alongside the fire handler it is the other half of. The summary is optional for the
    /// same reason the column is: the coordinator answers `nil` when it never counted this fire,
    /// and a null column is the honest record of that.
    func setHeldPathsSource(
        _ source: @escaping @Sendable (UUID) async -> (paths: [String], summary: WatchSummary?)
    ) {
        heldPathsSource = source
    }

    init(state: AppState, engine: IrisEngine, ledger: JobLedger,
         endSandboxSession: (@Sendable (UUID) async -> Void)? = nil,
         ensureIsolatedNetwork: (@Sendable () async -> String?)? = nil,
         now: @escaping @Sendable () -> Date = Date.init,
         calendar: Calendar = .current,
         config: ConfigManager = .shared,
         protectionEnabled: Bool? = nil,
         activity: any ActivityAPI = ProcessInfoActivity(),
         usageSource: (any JobUsageReading)? = nil,
         sandboxAvailable: (@Sendable () -> Bool)? = nil,
         gateEvaluator: (@Sendable (Gate, String?) async -> GateResult)? = nil,
         lastGateSignal: (@Sendable (UUID) throws -> String?)? = nil,
         watchdogSlice: TimeInterval = JobRunner.defaultWatchdogSlice) {
        self.state = state
        self.engine = engine
        self.ledger = ledger
        self.usageSource = usageSource ?? ledger
        self.now = now
        self.calendar = calendar
        self.config = config
        self.protectionEnabled = protectionEnabled
        self.activity = activity
        let resolvedSandboxAvailable = sandboxAvailable ?? { SandboxPolicy.mutatingJobCanRun(config: config) }
        self.sandboxAvailable = resolvedSandboxAvailable
        self.gateEvaluator = gateEvaluator ?? Self.liveGateEvaluator(
            sandboxAvailable: resolvedSandboxAvailable, image: { config.sandboxImage })
        self.lastGateSignal = lastGateSignal ?? { [ledger] in try ledger.lastGateSignal(jobId: $0) }
        self.endSandboxSession = endSandboxSession ?? { await SandboxSessionManager.shared.endSession($0) }
        self.ensureIsolatedNetwork = ensureIsolatedNetwork ?? {   // Task 4a: the real network check
            do { try await CLIContainerRuntime().ensureIsolatedNetwork(named: NetworkMode.isolatedNetworkName); return nil }
            catch ContainerRuntimeError.networkFailed(let detail) { return detail }
            catch { return "\(error)" }
        }
        self.watchdogSlice = watchdogSlice
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
        /// The job's gate looked and nothing had moved (§4 step 5). A row, no card, no turn.
        case gateUnchanged
        /// The gate could not answer. `paused` is the third such answer in a row, which stops the
        /// job.
        case gateError(detail: String, paused: Bool)
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
        case .gateUnchanged: return "its gate found nothing changed"
        case .gateError(let detail, let paused):
            return paused
                ? "\(gateErrorReason(detail)) — \(consecutiveGateErrorsToPause) in a row, so the job is now paused"
                : gateErrorReason(detail)
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

    /// The held fire's origin with more watch paths folded into it (§3): a union, sorted and
    /// deduplicated, **never** a replacement. Two things are held at once while a watch job runs —
    /// the fire the runner kept and whatever the coordinator has accepted since — and each of them
    /// is a save the run is supposed to see. Taking the later lot alone would silently drop the
    /// earlier one, which is how a watch ends up running on half a burst.
    ///
    /// A hold whose root is not a watcher comes back untouched: a scheduled or hand-started fire
    /// has no burst behind it, and stapling a watch's paths to it would tell that run the
    /// filesystem woke it when a person did.
    static func mergedWatcherOrigin(_ held: FireOrigin, taking extra: [String]) -> FireOrigin {
        guard held.isWatcher else { return held }
        // Nothing to fold in: the hold comes back untouched rather than rebuilt. `isWatcher` and
        // `paths` both read `root`, so a `.queued`-rooted hold that *does* get paths folded in
        // comes back unwrapped — which changes nothing, because both callers re-wrap the result in
        // `.queued` and neither `triggerKind` nor `root` counts the layers.
        guard !extra.isEmpty else { return held }
        return .watcher(paths: Set(held.paths).union(extra).sorted())
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
    /// A watcher fire carries the copy the coordinator's subscriber was built from at the last
    /// `sync`, which can be minutes or days old: deciding on it would re-admit a job that has
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
    ///
    /// `note` is what the scheduler's catch-up arithmetic wants said on this fire's card — "27
    /// earlier occurrences skipped" (§5) — and belongs to the caller's fire alone: a held `queue`
    /// fire taken afterwards stands in for a different one and carries nothing of this one's. It
    /// follows every outcome that ends the fire to whatever that outcome writes (R44): the pause
    /// card, the gate row, the skip row, the stillborn row — and when the outcome is "held", the
    /// note is held with it and arrives when that fire is finally taken.
    ///
    /// `watch` is the arithmetic of the burst that woke this fire (#187 deliverable 4, §6), which
    /// only `WatchCoordinator` can count. It is stamped on the row this fire begins, with
    /// `delivered` and `pathsWithheld` filled in from the prompt build — and, like `note`, it
    /// belongs to the caller's fire alone: a held fire taken afterwards is a different burst.
    @discardableResult
    func fire(job: Job, origin: FireOrigin, note: String? = nil,
              watch: WatchSummary? = nil) async -> Admission? {
        var origin = origin
        var note = note
        var watch = watch
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
                                             triggerKind: origin.triggerKind, now: at, note: note)
                } catch {
                    print("[JobRunner] could not record the skipped fire for \(current.name): \(error)")
                }
                return decided ?? .dropUnavailable(reason: reason)
            }

            let admission = Self.admit(job: current, inFlight: inFlight.contains(current.id),
                                       runsLastHour: usage.runsLastHour,
                                       tokensTodayJob: usage.tokensToday,
                                       tokensTodayAll: tokensAll, limits: limits)
            // Whether this pass is the fire the caller asked about — the first one round the loop.
            // A held `queue` fire that follows must not overwrite the answer given for it.
            let isCallersFire = decided == nil
            if isCallersFire { decided = admission }
            switch admission {
            // The two gate answers are not `admit`'s to reach — it is a pure function of four
            // numbers, and a gate is I/O — so they cannot arrive here. Listed rather than
            // defaulted, so adding a branch to `Admission` still has to come past this switch.
            case .dropPaused, .dropDisabled, .dropUnavailable, .gateUnchanged, .gateError:
                // The only two of these `admit` can reach are the pause and the disable, and both
                // are already handled above — so a catch-up note cannot be lost here. Nor would
                // there be anywhere to put one: these are the branches that must cost nothing and
                // leave nothing behind (a watch on a paused job sees every save), and the
                // scheduler does not plan a burst for a row it can see is paused or disabled, so
                // reaching one of them with a note in hand means the job stopped between the plan
                // and the fire — and what the user needs then is the pause reason, which they have.
                return decided
            case .skipInFlight:
                guard !origin.isWatcher else { return decided }
                do {
                    try Self.recordSkip(job: current, ledger: ledger,
                                        triggerKind: origin.triggerKind, now: at, note: note)
                } catch {
                    print("[JobRunner] could not record the skipped run for \(current.name): \(error)")
                }
                return decided
            case .queued:
                hold(fire: at, for: current, origin: origin, note: note)
                return decided
            case .pauseBreaker(let count):
                await pause(job: current, origin: origin,
                            reason: Self.breakerReason(count: count), at: at, note: note)
                return decided
            case .pauseBudget(let scope, let used, let limit):
                await pause(job: current, origin: origin,
                            reason: Self.budgetReason(scope: scope, used: used, limit: limit),
                            at: at, note: note)
                return decided
            case .run:
                break
            }

            inFlight.insert(current.id)
            // §4 step 5, and the last thing asked before a turn starts: a gated job runs only when
            // its gate says something moved. Asked with the job already marked in flight, because
            // a gate does I/O — a HEAD request, a container — and a fire that arrives while it is
            // thinking is the overlap it is, not a second admitted run.
            let gate: GateContext?
            switch await gateDecision(for: current, origin: origin, at: at, note: note) {
            case .proceed(let context):
                gate = context
            case .refuse(let refusal):
                inFlight.remove(current.id)
                if isCallersFire { decided = refusal }
                // Recorded by the branch above, on the row it wrote; a held fire taken next is a
                // different fire and must not claim the count again. The burst summary goes with
                // it, for the same reason.
                note = nil
                watch = nil
                // A fire held while the gate was being evaluated is still owed an answer, and the
                // gate is asked again for it: one held fire at a time, so this terminates.
                guard let held = takeQueuedFire(job: current) else { return decided }
                let merged = await mergedHeldOrigin(held.origin, jobId: current.id)
                origin = .queued(from: merged.origin)
                watch = merged.watch
                note = held.note
                continue
            }
            await run(job: current, origin: origin, limits: limits, gate: gate, note: note,
                      watch: watch)
            note = nil
            // The summary describes the burst the *caller* handed over, and it is now on that
            // run's row. A held fire taken next is a different burst, whose arithmetic only the
            // coordinator knows; claiming this one's counts for it would report the same changes
            // twice.
            watch = nil
            inFlight.remove(current.id)

            guard let held = takeQueuedFire(job: current) else { return decided }
            // The held fire's own origin, wrapped rather than replaced: what woke the job is what
            // the retry ladder decides on, and re-entering as a bare "queued" erased it (R7). Its
            // own catch-up count comes back with it, for the same reason: this pass *is* that fire.
            let merged = await mergedHeldOrigin(held.origin, jobId: current.id)
            origin = .queued(from: merged.origin)
            // The burst this fire stands in for, counted by the coordinator and reported by no
            // row until this one: a `.queued` admission writes nothing (R-D4-9).
            watch = merged.watch
            note = held.note
        }
    }

    // MARK: The gate (#187 §7)

    /// What a gate that said "changed" hands the run it let through: the signal to stamp on the
    /// row, and (a script gate only) the output to put in the prompt as untrusted context.
    struct GateContext: Equatable, Sendable {
        let signal: String
        let payload: String?
    }

    /// The gate's answer, as a fire needs it. `.refuse` has already written whatever the ledger
    /// and the user are owed — a row for "nothing changed", a row for an error, and on the third
    /// consecutive error the pause and its card.
    private enum GateDecision {
        case proceed(GateContext?)
        case refuse(Admission)
    }

    /// The outcome recorded on the row a gate's "nothing changed" leaves (§0.4 step 5).
    static let gateUnchangedOutcome = "gate: no change"
    /// The pause a gate nobody can evaluate earns, spelled exactly as the spec does.
    static let gateFailingReason = "gate failing"
    /// How a gate error reads on the row it writes. The prefix is load bearing: it is how the
    /// streak below recognises its own rows, and the pause row deliberately does not carry it, so
    /// a resumed job starts counting from zero again rather than being paused by its own history.
    static let gateErrorPrefix = "gate error"
    static func gateErrorReason(_ detail: String) -> String {
        "\(gateErrorPrefix): \(firstLine(of: detail) ?? "the gate could not be evaluated")"
    }
    /// Three, per spec §7.
    static let consecutiveGateErrorsToPause = 3

    /// What a gate whose last signal could not be read says. The one gate error that is Iris's own
    /// fault rather than the world's, and the reason it is worded as the gate's failure anyway is
    /// that the consequence is identical: nothing can be decided, and after three of them a person
    /// has to look.
    static func gateUnreadableDetail(_ error: any Error) -> String {
        "the last gate signal could not be read: \(error)"
    }

    /// The real evaluator, over the real three gates. The runtime is handed over only when the
    /// sandbox is resolvable *at this evaluation* (R28) — installed and switched on — so a script
    /// gate on a machine that has lost either is a gate error rather than a command on the host.
    /// Asked afresh every time for the same reason the fire asks about the profile: a check made
    /// when the job was created only describes the day it was made.
    static func liveGateEvaluator(sandboxAvailable: @escaping @Sendable () -> Bool,
                                  image: @escaping @Sendable () -> String)
        -> @Sendable (Gate, String?) async -> GateResult {
        { gate, previous in
            let runtime: (any ContainerRuntime)? = sandboxAvailable() ? CLIContainerRuntime() : nil
            return await GateEvaluator.evaluate(gate, previous: previous, runtime: runtime,
                                                image: image())
        }
    }

    /// Whether this fire is one the gate gets a say in (R29). A **cadence** fire that is not a
    /// retry — including one the `queue` policy held.
    ///
    /// The two that skip it have already had the question answered for them. A retry re-runs work
    /// the gate authorised a minute ago, and asking again would get "nothing has changed since the
    /// run that failed" — the work would be dropped, the row would read `completed`, and the ladder
    /// would sit at attempt 1 for ever, which is the retry silently disabled for exactly the jobs
    /// that were gated to avoid wasted turns. And `/jobs run` is a person saying "run it now",
    /// which a gate does not get a vote on; `--dry-run` is where someone asks what the gate thinks.
    ///
    /// A held `queue` re-fire is not one of them: it is a cadence fire whose gate was never asked,
    /// held before the question could be put — or held *because* the gate had just said nothing
    /// had changed. Running it unasked spends the full model turn the gate exists to avoid. So the
    /// root of the origin decides, not its wrapper.
    ///
    /// Pure, so the table of origins can be read and tested without a fire.
    static func gateApplies(origin: FireOrigin, job: Job) -> Bool {
        guard case .cadence = origin.root else { return false }
        return job.retryAttempt == 0
    }

    /// Asks this job's gate, if it has one and this fire is one it decides, and records what it
    /// said.
    private func gateDecision(for job: Job, origin: FireOrigin, at: Date,
                              note: String? = nil) async -> GateDecision {
        guard let gate = job.trigger.gate, Self.gateApplies(origin: origin, job: job) else {
            return .proceed(nil)
        }
        let previous: String?
        do {
            previous = try lastGateSignal(job.id)
        } catch {
            // A gate error, not a quiet drop. Without the last signal the gate cannot be decided,
            // so nothing runs either way — but a ledger that stays unreadable is not a passing
            // flake, and anything quieter than this leaves the job writing a row every tick for
            // ever: never running, never pausing, never carded. Carrying `gateErrorPrefix` is what
            // makes it count towards the three-error pause like any other gate that cannot answer.
            let detail = Self.gateUnreadableDetail(error)
            print("[JobRunner] not firing \(job.name): \(detail)")
            return .refuse(await noteGateError(detail, job: job, origin: origin, at: at, note: note))
        }

        switch await gateEvaluator(gate, previous) {
        case .changed(let signal, let payload):
            return .proceed(GateContext(signal: signal, payload: payload))
        case .unchanged(let signal):
            await recordGateSkip(job: job, origin: origin, signal: signal, at: at, note: note)
            return .refuse(.gateUnchanged)
        case .error(let detail):
            return .refuse(await noteGateError(detail, job: job, origin: origin, at: at, note: note))
        }
    }

    /// The row a gate's "nothing changed" leaves: a run that correctly did not happen. `completed`
    /// rather than `interrupted` — the job did exactly what it was asked to — carrying the signal
    /// it saw, with no transcript (so the breaker counts it as the non-event it is) and no card:
    /// cards are for things that happened, and a quiet job checked every five minutes would
    /// otherwise bury the Activity conversation (§11 ruling 4).
    private func recordGateSkip(job: Job, origin: FireOrigin, signal: String, at: Date,
                                note: String? = nil) async {
        await recordGateRow(job: job, origin: origin, at: at, status: .completed,
                            outcome: Self.gateUnchangedOutcome, reason: nil, signal: signal,
                            note: note)
    }

    /// Every row the gate path writes goes through here, and every one of them then goes through
    /// `apply` (R29). The rows are stillborn — begun and finished at the same instant, with no
    /// transcript, so `runsStarted` and the breaker read them as the non-events they are — but a
    /// gated job's ladder bookkeeping has to be identical to an ungated one's, and the way to
    /// guarantee that is for no gate-path row to be written anywhere else. Today `apply` is a
    /// no-op on all of them (the gate is only consulted at attempt 0, and neither `completed` nor
    /// `interrupted` starts a ladder); it is here so that stays true when `gateApplies` changes.
    ///
    /// The pause on the third error is the exception, and deliberately so: it goes through
    /// `pause`, which is the one writer of a pause row, the same as the breaker's and the budget's.
    ///
    /// `note` is the scheduler's catch-up count (§5). A gate row carries no card, so a replay
    /// burst whose first occurrence the gate refused has nowhere else to say that 27 occurrences
    /// were dropped — it rides on whichever line this row already has, rather than being lost.
    private func recordGateRow(job: Job, origin: FireOrigin, at: Date, status: JobRun.Status,
                               outcome: String?, reason: String?, signal: String?,
                               note: String? = nil) async {
        var outcome = outcome
        var reason = reason
        if note != nil {
            if reason != nil { reason = Self.withNote(reason, note) }
            else { outcome = Self.withNote(outcome, note) }
        }
        do {
            let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: origin.triggerKind,
                             startedAt: at, status: status)
            try ledger.begin(run: run)
            if let signal { try ledger.setGateSignal(runId: run.id, signal) }
            try ledger.finish(runId: run.id, status: status, outcome: outcome,
                              failureReason: reason, blockedTool: nil, tokens: TokenUsage(),
                              finishedAt: at)
        } catch {
            print("[JobRunner] could not record the gate's answer for \(job.name): \(error)")
        }
        await apply(Self.retryDecision(status: status, attempt: job.retryAttempt,
                                       retryEnabled: job.policy.retry,
                                       watcherFire: Self.isPathDriven(origin: origin, job: job),
                                       now: at),
                    job: job, status: status)
    }

    /// Records a gate that could not answer, and pauses the job on the third in a row (§7).
    ///
    /// The first two are quiet rows — a flaky server or a machine off the network is not worth a
    /// card apiece — and the third is the pause, which gets one, because at that point the job has
    /// stopped and only a person can start it again.
    private func noteGateError(_ detail: String, job: Job, origin: FireOrigin, at: Date,
                               note: String? = nil) async -> Admission {
        var previousErrors = 0
        do {
            previousErrors = Self.gateErrorStreak(
                in: try ledger.runs(jobId: job.id, limit: Self.consecutiveGateErrorsToPause))
        } catch {
            // Counting is what decides the pause, and a failed count must not be read as "this is
            // the third": leave the streak at zero and let the next tick ask again.
            print("[JobRunner] could not count \(job.name)'s gate errors: \(error)")
        }
        guard previousErrors + 1 < Self.consecutiveGateErrorsToPause else {
            await pause(job: job, origin: origin, reason: Self.gateFailingReason, at: at, note: note)
            return .gateError(detail: detail, paused: true)
        }
        await recordGateRow(job: job, origin: origin, at: at, status: .interrupted, outcome: nil,
                            reason: Self.gateErrorReason(detail), signal: nil, note: note)
        return .gateError(detail: detail, paused: false)
    }

    /// How many of the newest rows, in a row, are gate errors. Newest first, stopping at the first
    /// row that is anything else: a run that happened, a quiet tick, or the pause row itself.
    ///
    /// The rows come from `decodeRuns`, which drops one it cannot read — so an unreadable row
    /// between two errors collapses the streak and the pause takes an extra tick. That is the fail
    /// direction to have: it narrows towards pausing late rather than pausing a job nothing is
    /// wrong with.
    static func gateErrorStreak(in runs: [JobRun]) -> Int {
        runs.prefix { ($0.failureReason ?? "").hasPrefix(gateErrorPrefix) }.count
    }

    /// Forgets everything held in memory for a job that is gone. `/jobs delete` calls it: the
    /// `queuedFire` column goes with the row, but this actor's copy of the origin would outlive it
    /// and be handed to a job created later under the same id.
    func forget(jobId: UUID) {
        queuedOrigins.removeValue(forKey: jobId)
        queuedNotes.removeValue(forKey: jobId)
    }

    /// A held fire's origin plus everything the coordinator has been holding for the same job, and
    /// the burst arithmetic that came with it (§3, R-D4-9). Asked only of `.watcher`-rooted holds:
    /// see `mergedWatcherOrigin`. The origin is re-wrapped in `.queued` by both callers, so the row
    /// still records `queued` and the gate still reads the root.
    ///
    /// The summary is `nil` for a non-watcher root and when no source is wired: a null column is
    /// the honest answer when nobody counted, and `run` fills in `delivered`/`pathsWithheld` from
    /// the prompt build for the summaries that do arrive.
    private func mergedHeldOrigin(_ held: FireOrigin,
                                  jobId: UUID) async -> (origin: FireOrigin, watch: WatchSummary?) {
        guard held.isWatcher, let heldPathsSource else { return (held, nil) }
        let taken = await heldPathsSource(jobId)
        return (Self.mergedWatcherOrigin(held, taking: taken.paths), taken.summary)
    }

    /// Remembers the one trigger held back while this job is busy. One, never a queue of them: a
    /// job that fell far behind should run once when it is free, not N times in a row.
    private func hold(fire at: Date, for job: Job, origin: FireOrigin, note: String? = nil) {
        // The origin is the runner's own, not a column: the paths in it are what a watch saw
        // seconds ago, so they are worth carrying into the held fire but not worth surviving a
        // restart — and a second column would be a second thing to keep in step with `queuedFire`.
        //
        // Watch paths accumulate rather than replace (§3): the latest burst used to win, which
        // meant a second save while the run was going threw away the first one's paths and the
        // held fire ran on less than it was given. A fire with no paths (a scheduled one) still
        // leaves whatever a watch left rather than overwriting it with nothing, and a watch fire
        // held on top of a hand-started one takes over, because that one has no burst to lose.
        // Unbounded growth is not a risk: the coordinator offers no further fire once it has been
        // answered `.queued`, so what lands *here* is bounded by `maxTrackedPaths`. The re-fire's
        // own list is the union of two such sets — this hold and what `takeHeldPaths` returns — so
        // up to twice that; the 100-path cap in `buildPrompt` is what bounds what a run sees.
        if let existing = queuedOrigins[job.id] {
            if existing.isWatcher {
                queuedOrigins[job.id] = Self.mergedWatcherOrigin(existing, taking: origin.paths)
            } else if !origin.paths.isEmpty {
                queuedOrigins[job.id] = origin
            }
        } else {
            queuedOrigins[job.id] = origin
        }
        // The catch-up count travels with the held fire (R44). One burst per job, so there is
        // never a second count to argue with; a later ordinary fire held on top of this one
        // carries no note and must not wipe the one already waiting, or the occurrences a sleep
        // dropped are recorded nowhere at all.
        if let note { queuedNotes[job.id] = note }
        do {
            guard job.queuedFire == nil else { return }
            try ledger.setQueuedFire(jobId: job.id, at: at)
        } catch {
            // Nothing will take a fire that was never recorded, so the origin must not be left
            // behind either: it would be handed to the *next* held fire as if it were its own.
            queuedOrigins.removeValue(forKey: job.id)
            queuedNotes.removeValue(forKey: job.id)
            print("[JobRunner] could not queue a fire for \(job.name): \(error)")
        }
    }

    /// The trigger held back while this job ran, cleared as it is taken — so a trigger arriving
    /// during the *next* run is what refills the slot rather than this one firing forever. `nil`
    /// when nothing was held.
    private func takeQueuedFire(job: Job) -> (origin: FireOrigin, note: String?)? {
        let stored: Job?
        do { stored = try ledger.job(id: job.id) } catch {
            print("[JobRunner] could not take the queued fire for \(job.name): \(error)")
            return nil
        }
        guard let stored else {
            // Deleted mid-run: there is no column left to clear, but this actor's copy would
            // outlive the row it belonged to.
            queuedOrigins.removeValue(forKey: job.id)
            queuedNotes.removeValue(forKey: job.id)
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
            queuedNotes.removeValue(forKey: job.id)
            return nil
        }
        do {
            try ledger.setQueuedFire(jobId: job.id, at: nil)
        } catch {
            print("[JobRunner] could not clear the queued fire for \(job.name): \(error)")
            return nil
        }
        return (queuedOrigins.removeValue(forKey: job.id) ?? .schedule,
                queuedNotes.removeValue(forKey: job.id))
    }

    /// One line with the catch-up count folded in, for the paths that have no card to put it on.
    private static func withNote(_ text: String?, _ note: String?) -> String? {
        guard let note else { return text }
        guard let text, !text.isEmpty else { return note }
        return "\(text) (\(note))"
    }

    /// Drops a held fire that nothing is going to take, column and origin together.
    private func discardQueuedFire(job: Job) {
        queuedOrigins.removeValue(forKey: job.id)
        queuedNotes.removeValue(forKey: job.id)
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
    ///
    /// `note` is the scheduler's catch-up count (§5), which goes on the card and not into
    /// `pausedReason`: the reason is what `/jobs` prints and `/jobs resume` clears, and it has to
    /// keep saying why the job stopped rather than how far behind it happened to be.
    private func pause(job: Job, origin: FireOrigin, reason: String, at: Date,
                       note: String? = nil) async {
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
                                    finishedAt: at, catchUpNote: note), for: job)
        } catch {
            print("[JobRunner] could not record the pause for \(job.name): \(error)")
        }
    }

    /// Stops a watch whose folder is gone (§7): deleted, renamed or unmounted, so the stream is
    /// dead and no save will ever wake this job again. A pause, not a silent stop, because a watch
    /// that looks live in `/jobs` and never fires is the failure nobody notices — and `reason` is
    /// the caller's to word, since only the stream knows which path vanished.
    ///
    /// The origin is a watcher with no paths: nothing changed, the watch itself did.
    ///
    /// Idempotent on the row, not on the argument: the manager can report one vanished root twice
    /// — the hook its first pause fires re-enters `sync`, which pauses the next vanished job before
    /// the report loop that woke it gets there — and a second card for one deletion is a second
    /// thing to explain. A row that is gone is nothing to pause either.
    func pauseUnavailable(job: Job, reason: String) async {
        guard let current = try? ledger.job(id: job.id), current.pausedReason == nil else { return }
        await pause(job: current, origin: .watcher(paths: []), reason: reason, at: now())
    }

    /// Creates the background conversation, records the run, runs the turn, closes the row and
    /// delivers the card. Never throws: a fire is unattended, so every failure here is logged and
    /// the run is still accounted for in the ledger rather than surfacing to a caller with no one
    /// to tell.
    ///
    /// Private: `fire` is the only way in, so nothing can start a run that skipped admission.
    private func run(job: Job, origin: FireOrigin, limits: JobLimits, gate: GateContext? = nil,
                     note: String? = nil, watch: WatchSummary? = nil) async {
        // L1: a grant on a read-only row is inert — never stamped, never checked.
        let grant = job.profile == .mutating ? job.policy.grants : nil
        let startedAt = now()
        let title = "\(job.name) · \(ISO8601DateFormatter().string(from: startedAt))"
        guard let conversationId = await openConversation(for: job, titled: title,
                                                          sandboxed: job.profile == .mutating,
                                                          grant: grant) else {
            print("[JobRunner] not running \(job.name): \(Self.releasedReason)")
            return
        }

        // Before the row, not after it: two of the eight figures a watch summary carries are the
        // build's — how many paths got past the cap, and whether the guard withheld the block —
        // and a row inserted first would have to be updated with them a moment later. One write,
        // so a crash between the two cannot leave a run row whose summary contradicts its prompt.
        let promptBuild = await Self.buildPrompt(job: job, changedPaths: origin.paths,
                                                 gateOutput: gate?.payload,
                                                 protectionEnabled: protectionEnabled)
        var summary = watch
        summary?.delivered = promptBuild.delivered
        summary?.pathsWithheld = promptBuild.pathsWithheld

        var run = JobRun(jobId: job.id, jobName: job.name, triggerKind: origin.triggerKind,
                         startedAt: startedAt, transcriptConversationId: conversationId)
        // Nil for every fire no burst started, which is what leaves the column null on the rows
        // §6 says it should be null on.
        run.watchSummary = summary
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
        if let gate {
            // What the gate saw, on the row of the run it let through: this is what the next
            // evaluation compares against (`JobLedger.lastGateSignal`), so a run that happens
            // without it would ask the same question again next tick and get the same answer.
            do { try ledger.setGateSignal(runId: run.id, gate.signal) }
            catch { print("[JobRunner] could not record the gate signal for \(job.name): \(error)") }
        }

        // R12: a mutating job runs in the container or not at all. The conversation is pinned
        // `.sandboxed`, but a pin is an intent — with the runtime gone or sandboxing switched off
        // since the job was created, `SandboxPolicy.resolve` downgrades it to the host silently,
        // and an unattended run with the full tool surface on the host is the one outcome this
        // profile exists to prevent. Refused like any other failure, so the card and the retry
        // ladder say so.
        if job.profile == .mutating, !sandboxAvailable() {
            await closeFailed(run: run, job: job, origin: origin, conversationId: conversationId,
                              reason: Self.sandboxUnavailableReason, at: now(), note: note)
            return
        }
        // §0.8: the grant is a claim about the disk made once, and the disk moves. Asked before
        // the container exists; a miss is a failed row on the ordinary ladder.
        if let grant {
            if let drift = JobGrant.drift(grant) {
                await closeFailed(run: run, job: job, origin: origin, conversationId: conversationId,
                                  reason: drift, at: now(), note: note)
                return
            }
            // §0.7: "network off" is a network that has to exist. This is the check that puts the
            // reason on the row; the session manager asks again at create so a container rebuilt
            // mid-turn is isolated too.
            if !grant.network, let detail = await ensureIsolatedNetwork() {
                await closeFailed(run: run, job: job, origin: origin, conversationId: conversationId,
                                  reason: Self.isolatedNetworkUnavailableReason(detail), at: now(), note: note)
                return
            }
        }

        guard let engine else {
            await closeInterrupted(run: run, conversationId: conversationId, at: now())
            return
        }
        let prompt = promptBuild.text

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
        // The turn's claim on the thinking indicator and this conversation's engine-turn count,
        // held here so the deadline can give it back for a turn that will not. `thinkingCount` is
        // one global count: an abandoned turn that kept it would leave the spectrum lit and
        // Escape appending "Interrupted." to whatever the user is reading, for the rest of the
        // session.
        let lifetime = TurnLifetime()
        let turnTask = Task { [weak engine, weak orphanState = state] in
            await engine?.processInput(prompt, source: "job:\(job.name)",
                                       conversationId: conversationId, turnBudget: budget,
                                       usageSink: LedgerUsageSink(ledger: ledger, runId: run.id,
                                                                  jobName: job.name),
                                       lifetime: lifetime)
            // Claimed the instant the turn is back, before anything else can suspend: having won,
            // this run ended on its own terms and is never an overrun, whatever the watchdog does
            // next. A turn that lost — one the deadline already gave up on — claims nothing and
            // writes nothing: the row it would have written was closed at the deadline.
            if await ending.claim(deadline: false) { return true }
            // Except this, which is not a record of the run but a bucket in `AppState`: a denial
            // the orphan collected after `readTurn` drained would sit against a conversation
            // nothing will ever read again. Same drain `closeInterrupted` does, same reason.
            if let orphanState {
                await MainActor.run { _ = orphanState.takeBackgroundDenials(for: conversationId) }
            }
            return false
        }
        let watchdogSlice = self.watchdogSlice
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
                    let slice = min(seconds, watchdogSlice)
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
        // The indicator is the run's while the run is running, and this run is over. A turn that
        // came back released it on its own way out, so this is a no-op then; a turn the deadline
        // abandoned never will, so this is the only release it gets.
        if overran { await lifetime.release() }
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
        // The whole call, not just its name: the card renders every argument and "Approve and
        // run" re-dispatches exactly this (§6). Only the first — a run has one ending.
        let blockedCall = overran ? nil : turn.denials.first
        let blockedTool = blockedCall?.toolName
        let failureReason = overran ? TurnBudget.timeExceeded
            : Self.failureReason(status: status, messages: turn.messages, blockedTool: blockedTool,
                                 blockedReason: blockedCall?.reason ?? .approval)
        do {
            // The conversation is fresh, so its accumulated `tokenUsage` IS this run's cost.
            try ledger.finish(runId: run.id, status: status, outcome: outcome,
                              failureReason: failureReason, blockedTool: blockedTool,
                              tokens: turn.tokens, finishedAt: finishedAt)
        } catch {
            print("[JobRunner] could not close the run for \(job.name): \(error)")
        }
        if let blockedCall {
            // After `finish`, and separately from it: the row has to exist, and a blocked call
            // that fails to store still leaves a correctly-closed `blockedOnApproval` row behind.
            do { try ledger.setBlockedCall(runId: run.id, blockedCall) }
            catch { print("[JobRunner] could not store the blocked call for \(job.name): \(error)") }
        }

        // Decided before the card is built, because what happens to the schedule next is part of
        // what the card has to say: "failed" and "failed, trying again in a minute" are different
        // news to someone who has to decide whether to go and look.
        let retry = Self.retryDecision(status: status, attempt: job.retryAttempt,
                                       retryEnabled: job.policy.retry,
                                       watcherFire: Self.isPathDriven(origin: origin, job: job),
                                       now: finishedAt)
        await apply(retry, job: job, status: status)

        // What the card can offer a person to do about the blocked call, and what Vibecop makes of
        // it (§6) — taken now, while the card is being written, because it is there to inform the
        // click and a verdict taken afterwards would be too late to.
        let approval = await approvalOffer(for: blockedCall, job: job)
        let card = EventCard(runId: run.id, jobId: job.id, jobName: job.name, status: status,
                             // A card shows one line. With no reply to show, that line is why
                             // there is none (§6.2) — a blank failed card tells nobody anything.
                             outcome: Self.cardOutcome(outcome ?? failureReason, retry: retry,
                                                       now: finishedAt),
                             blockedTool: blockedTool,
                             startedAt: startedAt, finishedAt: finishedAt,
                             totalTokens: turn.tokens.totalTokenCount,
                             transcriptConversationId: conversationId,
                             // The card keeps a display copy: the ledger holds the call that
                             // gets re-dispatched, and a long body belongs in one place only.
                             blockedCall: blockedCall.map(EventCard.displayCopy),
                             vibecopVerdict: approval.verdict,
                             vibecopReason: approval.reason,
                             approvalBlockedReason: approval.refusal,
                             catchUpNote: note,
                             watchSummary: run.watchSummary)
        await closeSession(conversationId, status: card.statusText)
        await deliver(card, for: job)
    }

    // MARK: The blocked call, on the card (#187 §6)

    /// What a card can offer a person to do about the call a run failed closed on: the reason no
    /// click can authorise it, when there is one, and otherwise what Vibecop makes of it.
    struct ApprovalOffer: Equatable, Sendable {
        /// Non-nil means "Approve and run" is not offered, and this is what the card says instead.
        let refusal: String?
        let verdict: String?
        let reason: String?
        static let nothing = ApprovalOffer(refusal: nil, verdict: nil, reason: nil)
    }

    /// Decided when the card is WRITTEN, both halves of it. The refusals because a card is a
    /// snapshot — it has to read correctly months later, after the job has been renamed or
    /// deleted, without re-deriving anything. The verdict because it is there to inform the person
    /// before they click, which is too late if it is only taken afterwards: **Vibecop still runs
    /// on the persisted call, and a human click overrides a `DENY` rather than skipping the
    /// evaluation** (§6). Nothing is asked about a call no click can authorise — a refusal is
    /// already the answer, and a local model call to decorate it would be spent for nothing.
    /// Takes the job rather than the blocked run's conversation, because the job is what decides
    /// how the call would run if it were approved. Internal so a test can ask for the offer
    /// without driving a whole turn.
    func approvalOffer(for call: BlockedCall?, job: Job) async -> ApprovalOffer {
        guard let call, let state else { return .nothing }
        // R13 is not stored: the card decides it from the call's own reason, so a card written by
        // a build that stored nothing still cannot offer a button for a read-only job's call.
        guard call.reason != .profile else { return .nothing }
        let protectedTarget = await MainActor.run { state.permissions.isProtectedWrite(call) }
        if protectedTarget {
            return ApprovalOffer(refusal: EventCard.protectedNotApprovable, verdict: nil, reason: nil)
        }
        // The same expression `runApproved` opens the approved call's conversation with, so the
        // verdict is taken about the isolation the call would actually have. Asking the *blocked
        // run's* conversation instead — which is what this used to do — answered for a `write_file`
        // with "not sandboxed" even when the job is `mutating` and the approved call would run in
        // the VM, and answered for a `run_command` with whatever that conversation happened to
        // resolve to rather than with R20's "the container or nobody".
        let sandboxed = job.profile == .mutating || call.toolName == "run_command"
        let verdict = await state.vibecopVerdict(for: call, inSandbox: sandboxed,
                                                 vibecopEnabled: config.enableVibecop)
        return ApprovalOffer(refusal: nil, verdict: verdict?.decision, reason: verdict?.reason)
    }

    // MARK: Approve and run (#187 §6)

    /// What a click on "Approve and run" did. A refusal carries the sentence the user is shown:
    /// silence after a click reads as a broken button rather than a refused one.
    enum ApprovalOutcome: Equatable, Sendable {
        case dispatched(runId: UUID)
        case refused(String)
    }

    /// The `triggerKind` an approved call's row records. Queried, so it is spelled once.
    static let approvalTriggerKind = "approval"

    static let missingRunRefusal = "that run is no longer in the ledger"
    static let noBlockedCallRefusal = "that run recorded no call to approve"
    /// R13: a `readOnly` job's call was not refused for want of a human, so no human can grant it.
    static let profileNotApprovableRefusal = "a read-only job's call cannot be approved; the job would have to be mutating"
    static let missingJobRefusal = "that job has been deleted"
    /// R10: `~/.iris/config` and `~/.iris/plugins` are where permission is granted.
    static let protectedWriteRefusal = "it would write into a protected directory, which an approval cannot authorise"
    static let alreadyApprovedRefusal = "it has already been approved once"
    static let runnerUnavailableRefusal = "jobs are not available right now"
    static func ledgerRefusal(_ error: any Error) -> String { "the ledger could not be read: \(error)" }

    /// The sentence a refused click puts in the conversation the card is in. Spelled once: the
    /// runner writes it for every refusal it decides, and `AppState` writes it for the one case
    /// there is no runner to decide anything.
    static func refusalNotice(_ reason: String) -> String { "Not run: \(reason)." }

    /// Dispatches the call a person approved on an event card: exactly that call, exactly once, as
    /// a tracked run of its own (§6).
    ///
    /// Deliberately not "resume the job". The original turn is over and the model's plan after the
    /// blocked call is unknowable, so re-entering it would be guessing on the user's behalf with
    /// their approval in hand. What the call did is reported on a follow-up card; if the job needs
    /// to go further, its next fire takes it there.
    ///
    /// The one-shot lives in the ledger, not in this actor: `markApproved` stamps `approvedAt` in
    /// the same `UPDATE` that checks it is unset, and it is stamped BEFORE the call runs. A second
    /// click, a second process, and a crash between the click and the execution therefore all land
    /// on the same refusal instead of running the call twice.
    ///
    /// The row this writes is an ordinary `job_runs` row, so the approved call counts towards the
    /// breaker and the daily budgets the next fire is judged against. Admission is deliberately
    /// NOT re-run over it: a person clicking a button is not an unattended fire, and refusing them
    /// because the job is paused (it usually is, after a failure) would make the button a lie.
    func runApproved(runId: UUID) async -> ApprovalOutcome {
        // Every refusal is said out loud, and the ones decided before the job is known have
        // nowhere but Activity to say it — a pruned row is exactly the click that most needs an
        // answer, because the card it came from is still on screen.
        let blocked: JobRun?
        do { blocked = try ledger.run(id: runId) } catch {
            return await refuse(Self.ledgerRefusal(error), for: nil)
        }
        guard let blocked else { return await refuse(Self.missingRunRefusal, for: nil) }
        guard let call = blocked.blockedCall else {
            return await refuse(Self.noBlockedCallRefusal, for: nil)
        }
        let stored: Job?
        do { stored = try ledger.job(id: blocked.jobId) } catch {
            return await refuse(Self.ledgerRefusal(error), for: nil)
        }
        // Read before R13 rather than after, only so the refusal can be said where the card is.
        guard let job = stored else { return await refuse(Self.missingJobRefusal, for: nil) }
        guard call.reason != .profile else {
            return await refuse(Self.profileNotApprovableRefusal, for: job)
        }
        guard let state, let engine else {
            return await refuse(Self.runnerUnavailableRefusal, for: job)
        }
        // R10, again — the card does not offer this one, and a stale card in an old transcript
        // still has a button that would try.
        let protectedTarget = await MainActor.run { state.permissions.isProtectedWrite(call) }
        if protectedTarget { return await refuse(Self.protectedWriteRefusal, for: job) }
        // R20: the profile is re-asked HERE, at click time, not inherited from the fire. Between
        // the run that was blocked and this click the user can have uninstalled the runtime or
        // turned sandboxing off, and the answer to "may this job do this?" changes with it. The
        // click authorises the command; it does not authorise dropping the isolation, and nothing
        // on the card would say the isolation had gone.
        let sandboxed = sandboxAvailable()
        // A `run_command` that came out of a background run is the container's or nobody's,
        // whatever the profile. `readOnly` says so because the host is where its containment ends;
        // `mutating` says so because the VM is what pays for its wider surface (R12).
        if call.toolName == "run_command", !sandboxed {
            return await refuse(Self.sandboxUnavailableReason, for: job)
        }
        if job.profile == .mutating, !sandboxed {
            return await refuse(Self.sandboxUnavailableReason, for: job)
        }
        if job.profile == .readOnly {
            // The same predicate the fire's dispatcher uses, asked again with today's answers: a
            // tool this build has since taken off the allowlist, or an MCP server that no longer
            // claims a tool is read-only, is refused now even though it was only an approval
            // denial then.
            let readOnlyMCP = JobProfile.isMCPTool(call.toolName)
                ? await MCPManager.shared.readOnlyToolNames() : []
            if JobProfile.readOnlyDenies(call.toolName, sandboxedRunCommand: sandboxed,
                                         readOnlyMCPTools: readOnlyMCP) {
                return await refuse(Self.profileNotApprovableRefusal, for: job)
            }
        }
        // §0.8 again, at click time: the grant is re-checked before the approval is spent.
        let grant = job.profile == .mutating ? job.policy.grants : nil
        if let grant {
            if let drift = JobGrant.drift(grant) { return await refuse(drift, for: job) }
            if !grant.network, let detail = await ensureIsolatedNetwork() {
                return await refuse(Self.isolatedNetworkUnavailableReason(detail), for: job)
            }
        }
        // The claim, before anything runs. Every refusal above is a decision about the call rather
        // than a dispatch of it, so none of them burns it.
        do {
            guard try ledger.markApproved(runId: runId, at: now()) else {
                return await refuse(Self.alreadyApprovedRefusal, for: job)
            }
        } catch {
            return await refuse(Self.ledgerRefusal(error), for: job)
        }

        let startedAt = now()
        // Pinned to the container whenever the call could run a command: `openConversation`'s
        // profile rule alone would leave a `readOnly` job's approved `run_command` to fall through
        // to whatever the per-workspace default says, which is the host fallback R20 forbids.
        guard let conversationId = await openConversation(
            for: job, titled: "\(job.name) · approved \(call.toolName)",
            sandboxed: job.profile == .mutating || call.toolName == "run_command",
            grant: grant)
        else { return await refuse(Self.runnerUnavailableRefusal, for: job) }

        var approved = JobRun(jobId: job.id, jobName: job.name,
                              triggerKind: Self.approvalTriggerKind, startedAt: startedAt,
                              transcriptConversationId: conversationId)
        approved.parentRunId = blocked.id
        do {
            try ledger.begin(run: approved)
        } catch {
            print("[JobRunner] could not record the approved run for \(job.name): \(error)")
            await closeSession(conversationId, status: "not recorded")
            return await refuse(Self.ledgerRefusal(error), for: job)
        }

        // Straight into the executor: `executeApprovedCall` runs the tool through the hook layer
        // and never enters `AppState.requestApproval`, so the approval is given by construction
        // rather than by a grant anyone has to remember to take back (#187 R21). The checks the
        // gate would have made are made instead by this function above and by the executor's own
        // R10/R13/R20 backstops.
        let result = await engine.executeApprovedCall(call, conversationId: conversationId)
        let finishedAt = now()
        await MainActor.run {
            // The transcript "View run" opens: what was run, and what came back.
            state.appendMessage(role: .system, content: Self.approvedCallLine(call), to: conversationId)
            state.appendMessage(role: .system, content: result, to: conversationId)
            // Anything the call was refused on the way (a nested ask, fail-closed like any other)
            // belongs to nothing once this run is over.
            _ = state.takeBackgroundDenials(for: conversationId)
        }

        let failed = Self.approvedCallFailed(result)
        let outcome = Self.firstLine(of: result)
        do {
            try ledger.finish(runId: approved.id, status: failed ? .failed : .completed,
                              outcome: outcome, failureReason: failed ? outcome : nil,
                              blockedTool: nil, tokens: TokenUsage(), finishedAt: finishedAt)
        } catch {
            print("[JobRunner] could not close the approved run for \(job.name): \(error)")
        }
        // No retry ladder: a person asked for this call once. If it failed, the answer is another
        // decision by them, not a schedule.
        let card = EventCard(runId: approved.id, jobId: job.id, jobName: job.name,
                             status: failed ? .failed : .completed, outcome: outcome,
                             blockedTool: nil, startedAt: startedAt, finishedAt: finishedAt,
                             totalTokens: 0, transcriptConversationId: conversationId)
        await closeSession(conversationId, status: card.statusText)
        await deliver(card, for: job)
        return .dispatched(runId: approved.id)
    }

    /// Says why a click did nothing, where the card the person clicked actually is — the job's
    /// destination conversation, or Activity when it has none (or when there is no job left to
    /// ask). Silence after a click reads as a broken button rather than a refused one, and a
    /// sentence in a conversation the user does not have open is the same silence.
    private func refuse(_ reason: String, for job: Job?) async -> ApprovalOutcome {
        guard let state else { return .refused(reason) }
        let destination = await destination(for: job)
        await MainActor.run {
            state.appendMessage(role: .system, content: Self.refusalNotice(reason), to: destination)
        }
        return .refused(reason)
    }

    /// The transcript line naming the call that was approved, so the hidden conversation reads as
    /// a record of an action rather than an unattributed result.
    static func approvedCallLine(_ call: BlockedCall) -> String {
        let detail = call.details
        let head = "Approved by you: `\(call.toolName)`"
        return detail.isEmpty ? head : "\(head) — \(detail)"
    }

    /// The first line of some text, trimmed and capped at 200 characters, or `nil` when there is
    /// nothing to show. The one spelling of "what a row and a card display", shared by the turn
    /// path (`outcome(from:)`, over the agent's last message) and the approved-call path (over the
    /// tool result) so the two cannot drift into different truncations.
    static func firstLine(of result: String) -> String? {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let line = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
            ?? trimmed
        return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
    }

    /// Whether a tool result reads as a failure. There is no status channel out of the executor —
    /// every tool returns a string — so this matches the shapes the tools, the hook layer and the
    /// approval backstops actually produce, and anything unrecognised counts as a success.
    ///
    /// Deliberately NOT covered: a `run_command` that exited non-zero. `ToolExecutor.runCommand`
    /// discards `terminationStatus` and returns stdout plus a `Stderr:` block, so no caller in this
    /// harness can see an exit code — a failed `git push` therefore writes a `completed` row with
    /// its stderr as the outcome. That is a harness-wide blind spot rather than one this path
    /// invents, and the stderr is verbatim on the card and in the transcript, so what is wrong is
    /// the dot's colour and the row's status word, not what the person is told happened.
    static func approvedCallFailed(_ result: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["Error", "Not run:", "System Hook blocked"].contains { trimmed.hasPrefix($0) }
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

    /// The run's own hidden conversation, registered in the session strip. Titled by the caller: an
    /// ordinary fire is named for when it started, an approved call for what it runs. `nil` when
    /// the app state has been released — there is nothing to run a turn against, and no row has been
    /// written yet, so the fire is simply dropped.
    private func openConversation(for job: Job, titled title: String,
                                  sandboxed: Bool, grant: JobGrant?) async -> UUID? {
        guard let state else { return nil }
        return await MainActor.run { () -> UUID in
            let id = state.createNewConversation(isBackground: true, title: title)
            // What the turn is allowed to do: the tool-list builder narrows a `readOnly` run's
            // declarations by this, and the dispatcher fails closed on what it still gets asked
            // for (§4). Stamped for both profiles — nil means "not a job run at all", which is
            // the unnarrowed surface.
            state.setJobProfile(for: id, job.profile)
            // §0.6, §2: the first read-write mount is the run's working directory — it feeds `-w`,
            // relative paths in `write_file`, the AGENTS.md loader and the per-workspace sandbox
            // file — and the grant itself is what the approval gate and the executor read.
            if let grant {
                if let workingDirectory = grant.workingDirectory { state.setWorkspace(for: id, path: workingDirectory) }
                state.setSandboxGrant(for: id, grant)
            }
            // An ordinary `.mutating` fire asks for a container, and so does any approved call
            // that could run a command (R20). `.readOnly` otherwise leaves the field nil
            // deliberately: nil means "fall through to the per-workspace/global default", which is
            // not the same as pinning this run to the host (§9).
            if sandboxed, let idx = state.conversations.firstIndex(where: { $0.id == id }) {
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
        let denials: [BlockedCall]
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

    /// The failure reason a `mutating` fire with nowhere to run writes. Read back by `/jobs`.
    static let sandboxUnavailableReason = "sandbox unavailable"
    /// A granted fire whose source moved, or is no longer a directory (§0.8). Read back by `/jobs`.
    static func grantSourceUnavailableReason(_ path: String) -> String { "grant source unavailable: \(path)" }
    /// A `network: false` fire whose host-only network could not be created (§0.7).
    static func isolatedNetworkUnavailableReason(_ detail: String) -> String { "isolated network unavailable: \(detail)" }

    /// Closes a run that never started its turn, as a failure: the row, the retry ladder and the
    /// card, exactly as the tail of `run` would have written them, minus everything that only a
    /// finished turn has (an outcome, a token count, a blocked call). Separate from
    /// `closeInterrupted`, which is not a failure and never retries.
    private func closeFailed(run: JobRun, job: Job, origin: FireOrigin, conversationId: UUID,
                             reason: String, at finishedAt: Date, note: String? = nil) async {
        if let state {
            await MainActor.run { _ = state.takeBackgroundDenials(for: conversationId) }
        }
        do {
            try ledger.finish(runId: run.id, status: .failed, outcome: nil, failureReason: reason,
                              blockedTool: nil, tokens: TokenUsage(), finishedAt: finishedAt)
        } catch {
            print("[JobRunner] could not close the refused run for \(job.name): \(error)")
        }
        let retry = Self.retryDecision(status: .failed, attempt: job.retryAttempt,
                                       retryEnabled: job.policy.retry,
                                       watcherFire: Self.isPathDriven(origin: origin, job: job),
                                       now: finishedAt)
        await apply(retry, job: job, status: .failed)
        let card = EventCard(runId: run.id, jobId: job.id, jobName: job.name, status: .failed,
                             outcome: Self.cardOutcome(reason, retry: retry, now: finishedAt),
                             blockedTool: nil,
                             startedAt: run.startedAt, finishedAt: finishedAt, totalTokens: 0,
                             transcriptConversationId: conversationId, catchUpNote: note,
                             watchSummary: run.watchSummary)
        await closeSession(conversationId, status: card.statusText)
        await deliver(card, for: job)
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
        // The strip and the card flip first: a slow `container rm` must not hold up either one
        // just because the two happen to be closing together.
        if let state {
            await MainActor.run { state.finishSession(id: conversationId, status: status) }
        }
        // The run's container goes with the run (§2): before this, a job's container stood until
        // the idle reaper or the next launch's sweep, holding its mounts open the whole time.
        await endSandboxSession(conversationId)
    }

    private func deliver(_ card: EventCard, for job: Job) async {
        guard let state else { return }
        await state.deliverEvent(card, to: await destination(for: job))
    }

    /// Where a job's news goes: its own destination conversation, or Activity. Shared by the card
    /// and by a refused "Approve and run", because the sentence explaining a click has to land
    /// where the card the person clicked is — anywhere else is silence with extra steps.
    ///
    /// A destination that has since been deleted falls back to Activity rather than dropping the
    /// news: `deliverEvent` is a no-op for an unknown id, and a run nobody hears about is the
    /// failure mode this whole deliverable exists to fix. `nil` — no job left at all — is Activity
    /// for the same reason.
    private func destination(for job: Job?) async -> UUID {
        guard let state else { return UUID() }
        return await MainActor.run { () -> UUID in
            if let wanted = job?.destinationConversationId,
               state.conversations.contains(where: { $0.id == wanted }) {
                return wanted
            }
            return state.activityConversationId()
        }
    }

    /// The job's prompt, plus the paths that woke it when a watch did — and what became of them.
    ///
    /// The job's own prompt is trusted — the user (or the agent on their behalf) wrote it. The
    /// paths are not: a filename is chosen by whoever can write into the watched directory, and
    /// D1 put every fire through `handleSystemEvent`, which sanitized it. So each path goes
    /// through the structural pass and the whole block through the tiered guard, arriving wrapped
    /// in `<untrusted_context>` after the instructions rather than concatenated into them.
    ///
    /// The cap is applied **before** the guard (#187 deliverable 4, §2): at most
    /// `WatchCoordinator.maxDeliveredPaths` paths plus one line of arithmetic, so a build dropping
    /// ten thousand files into a watched directory costs the classifier a bounded block rather
    /// than an unbounded one. `delivered` and `pathsWithheld` are what the run row and the card
    /// report — a guard that blocked the block used to be silent, which left a run that got no
    /// paths looking exactly like a run whose burst had none.
    static func buildPrompt(job: Job, changedPaths: [String], gateOutput: String? = nil,
                            protectionEnabled: Bool? = nil) async -> PromptBuild {
        var prompt = job.prompt
        var delivered = 0
        var pathsWithheld = false
        if !changedPaths.isEmpty {
            let sorted = changedPaths.sorted()
            let shown = sorted.prefix(WatchCoordinator.maxDeliveredPaths)
            var block = "Changed paths:\n" + shown
                .map { "- " + PromptInjectionGuard.sanitizeUntrustedInput($0) }
                .joined(separator: "\n")
            let withheld = sorted.count - shown.count
            if withheld > 0 { block += "\nand \(withheld) more changed paths" }
            let outcome = await InjectionGuard.classify(block, contextTag: "fs_event_paths",
                                                        maxTier: .tier3_canary,
                                                        protectionEnabled: protectionEnabled)
            if case .passed = outcome { delivered = shown.count } else { pathsWithheld = true }
            prompt += "\n\n" + InjectionGuard.wrapped(outcome, contextTag: "fs_event_paths")
        }
        // A gate script's output is the least trusted thing in a run: model-written code read
        // whatever it was pointed at and printed it. Same treatment as the paths, under its own
        // tag (§7).
        if let gateOutput, !gateOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + (await InjectionGuard.sanitize(gateOutput,
                                                              contextTag: "gate_output",
                                                              maxTier: .tier3_canary,
                                                              protectionEnabled: protectionEnabled))
        }
        return PromptBuild(text: prompt, delivered: delivered, pathsWithheld: pathsWithheld)
    }

    /// The text alone. Test-only since deliverable 4: `run` takes the whole build, because it has
    /// a summary to fill in, so the four remaining call sites are all in `Tests/`. Kept because
    /// the tests that assert on the prompt's shape have no use for the figures, and pinned against
    /// the build it wraps by `JobRunnerTests.promptCapsAtAHundredPaths`.
    static func prompt(job: Job, changedPaths: [String], gateOutput: String? = nil,
                       protectionEnabled: Bool? = nil) async -> String {
        await buildPrompt(job: job, changedPaths: changedPaths, gateOutput: gateOutput,
                          protectionEnabled: protectionEnabled).text
    }

    /// The first line of the last thing the agent said, capped at 200 characters — the one line a
    /// card and `/jobs` show. `nil` when the run said nothing at all, which `status` treats as a
    /// failure: an empty bubble is no more of a reply than no bubble, so both land here.
    static func outcome(from messages: [ChatMessage]) -> String? {
        guard let last = messages.last(where: { $0.role == .agent }) else { return nil }
        return firstLine(of: last.content)
    }

    /// Fail-closed precedence (§6.2). A denial outranks everything: it is the one outcome a person
    /// can do something about, and it is the reason the run stopped short even if the turn also
    /// errored on its way out. An `[LLM_ERROR]` outranks a soft stop for the same reason — it says
    /// what actually broke, where a soft stop only says the loop was cut off. Last, a turn that
    /// reached the end with nothing said is a failure too: a hook that blocked the turn, a
    /// cancelled engine or a conversation deleted mid-run all land here, and reporting any of them
    /// as `completed` would put a green card on a run that did nothing.
    static func status(messages: [ChatMessage], denials: [BlockedCall], softStopped: Bool) -> JobRun.Status {
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
                              blockedTool: String?,
                              blockedReason: BlockedCall.Reason = .approval) -> String? {
        switch status {
        case .blockedOnApproval:
            let tool = blockedTool ?? "a gated tool"
            // The two reasons read differently on purpose: one is waiting for a person, the other
            // is waiting for a job that was never created to be able to do this at all.
            return blockedReason == .profile
                ? "not available to a read-only job: \(tool)"
                : "needs approval: \(tool)"
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
    static func recordSkip(job: Job, ledger: JobLedger, triggerKind: String, now: Date,
                           note: String? = nil) throws {
        _ = try recordStillborn(job: job, ledger: ledger, reason: skipReason,
                                triggerKind: triggerKind, now: now, note: note)
    }

    /// A run that never happened, recorded so `/jobs` can show why: begun and finished at the same
    /// instant, `interrupted`, no transcript, no tokens. Every admission branch that refuses a
    /// fire and owes the user an explanation writes one — the overlap skip, both pauses and an
    /// unreadable ledger.
    ///
    /// `triggerKind` is the *fire's*, not `job.trigger.kind`: what was refused was a hand-started
    /// fire or a held one, and a row saying "fsEvent" because that is how the job is configured
    /// describes a fire that never happened.
    /// `note` is the scheduler's catch-up count (§5, R44), folded into the reason this row already
    /// carries. These rows have no card — an overlap skip and an unreadable ledger are not things
    /// to interrupt anybody with — so the row is the only place the count can be told, and
    /// `/jobs` shows it there.
    @discardableResult
    static func recordStillborn(job: Job, ledger: JobLedger, reason: String, triggerKind: String,
                                now: Date, note: String? = nil) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: triggerKind,
                         startedAt: now, status: .interrupted)
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: .interrupted, outcome: nil,
                          failureReason: withNote(reason, note), blockedTool: nil,
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
        // One waiter, and enforced where it is relied on: a second would overwrite the first
        // continuation, which is never resumed again — a silent permanent hang, the exact failure
        // this whole mechanism exists to remove.
        precondition(waiter == nil, "DeadlineFlag has one waiter: the run that owns the ending")
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
