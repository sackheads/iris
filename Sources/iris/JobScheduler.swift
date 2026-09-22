import Foundation
import AppKit

/// Polls the job ledger for due jobs and hands each one to a fire handler (#187 deliverable 1).
///
/// Replaces the old schedule manager, whose jobs lived in `UserDefaults` and whose next-fire arithmetic
/// was a `DateComponents` match with no way to express "every weekday". The state that used to be
/// in this object — the job list — is now rows in the conversation database, so this type owns
/// only the loop: when to look, how many to start at once, and what to do with a cadence that has
/// no next occurrence.
///
/// Every fire advances `nextFireAt` **before** the handler is called. A crash mid-fire then loses
/// that run rather than replaying it on the next launch, which is the safe direction for a handler
/// that sends the model a prompt.
actor JobScheduler {
    /// One handover from the loop: everything about a fire that is not on the job's row.
    struct Fire: Equatable, Sendable {
        /// The trigger kind that caused it, so a handler can tell a cadence fire from a poll or a
        /// watch.
        let reason: String
        /// What a replayed fire's card says about the occurrences the cap dropped (§5), or `nil`
        /// for every ordinary fire. Carried by the first fire of a catch-up burst only: it is one
        /// fact about the burst, not about each run in it.
        let note: String?

        init(reason: String, note: String? = nil) {
            self.reason = reason
            self.note = note
        }
    }

    /// Called once per fire, off the ledger's write path.
    ///
    /// Returns whether the fire was admitted. Only a `replay` catch-up reads the answer, and R32
    /// is why: a replayed occurrence is an ordinary cadence fire, so what refused this one — a
    /// pause, an open breaker, an exhausted budget, a run already in flight, a gate that found
    /// nothing — would refuse the next one a moment later, and firing the rest of the burst into
    /// it would write a row apiece for nothing.
    typealias FireHandler = @Sendable (Job, Fire) async -> Bool

    /// The `pausedReason` written for a cadence whose `next(after:)` finds nothing inside
    /// `CronSchedule`'s lookahead — a job that can never run again (`0 0 30 2 *`) must stop being
    /// due every tick forever, and the user needs to be told why it went quiet.
    static let unmatchableReason = "no matching time in the next four years"

    private let ledger: JobLedger
    private let now: @Sendable () -> Date
    private let maxFiresPerTick: Int

    private var fireHandler: FireHandler?
    /// Jobs whose catch-up burst the tick's cap cut short and which are still firing it.
    ///
    /// Those rows are left due on purpose — a `nextFireAt` still in the past is what brings the
    /// next tick back to finish the burst — but `tick()` suspends inside its task group while the
    /// handlers run, and the poll loop and the wake observer both dispatch it detached. Without
    /// this, a tick arriving ten seconds into a model turn would plan a *second* burst for the
    /// same job alongside the first: the runner's in-flight check would turn each of its fires
    /// into an `interrupted` row for a run nothing interrupted, and the refusal that followed
    /// would abandon the occurrences the first burst still owed.
    ///
    /// Deliberately narrow. Overlap in general is the runner's call (§4) and the loop still hands
    /// over an ordinary fire while its predecessor runs — this covers only the one case the loop
    /// itself creates, a row it knowingly left in the past.
    private var burstsInFlight: Set<UUID> = []
    /// Called at most once every `maintenanceInterval`, from the same loop that polls for due jobs
    /// (#187 §10: retention runs "at launch and once a day"). The loop is the only thing in the
    /// app that already ticks forever, so a daily chore hangs off it rather than off a second
    /// timer that would have to be started, stopped and woken in step with this one.
    private var onDailyMaintenance: (@Sendable () async -> Void)?
    /// When maintenance last ran, or the baseline a day is measured from. Set — without firing —
    /// by `start()` and by the first tick, because launch-time maintenance is the engine's own
    /// explicit call: firing here too would run the same prune twice within a second.
    private var lastMaintenanceAt: Date?
    private var pollTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

    init(ledger: JobLedger, now: @escaping @Sendable () -> Date = Date.init, maxFiresPerTick: Int = 3) {
        self.ledger = ledger
        self.now = now
        self.maxFiresPerTick = maxFiresPerTick
    }

    func setFireHandler(_ handler: @escaping FireHandler) {
        fireHandler = handler
    }

    /// A day, as the maintenance hook counts one. Not a calendar day: nothing about retention
    /// cares which side of midnight it runs on, and an elapsed-seconds comparison cannot be
    /// skipped or repeated by a DST change.
    static let maintenanceInterval: TimeInterval = 86_400

    func setOnDailyMaintenance(_ handler: @escaping @Sendable () async -> Void) {
        onDailyMaintenance = handler
    }

    /// The cadence governing a trigger, if it has one. `fsEvent` has none — it is driven by the
    /// filesystem, not the clock — and a `poll` trigger's cadence is how often its gate is checked.
    /// When a job with this trigger would next come due after `now` — `nil` for a watch, which has
    /// no cadence, and for a cadence with no future occurrence. `/jobs resume` recomputes through
    /// this so a job put back on its feet lands where the polling loop would have put it.
    static func nextFire(for trigger: Trigger, after now: Date) -> Date? {
        cadence(of: trigger)?.next(after: now)
    }

    private static func cadence(of trigger: Trigger) -> Schedule? {
        switch trigger {
        case .schedule(let schedule): return schedule
        case .poll(let spec): return spec.schedule
        case .fsEvent: return nil
        }
    }

    /// Fires every due job, up to `maxFiresPerTick`, and returns how many fires were handed over.
    ///
    /// Awaits the batch it started, so a caller (and a test) can observe the fires this tick
    /// caused. `start()`'s loop therefore runs each tick detached: a handler that takes an hour
    /// must not hold up the next poll, and an overlapping tick is safe because `nextFireAt` has
    /// already moved before the handler is called and the runner refuses a job it is already
    /// running (§4) — overlap is the runner's, so a watch fire is covered by the same set.
    ///
    /// A truncated `replay` burst is the one exception to "`nextFireAt` has already moved": it is
    /// left in the past on purpose, so `burstsInFlight` holds the job until the burst is over.
    ///
    /// A job is usually one fire. A `replay` catch-up is the exception (§5): it hands over one
    /// fire per missed occurrence, in order, **sequentially** — a job must never run beside
    /// itself, and firing a burst into a task group would ask the runner's in-flight check to turn
    /// four of the five into skip rows. Jobs are still fired concurrently with each other.
    @discardableResult
    func tick() async -> Int {
        let handler = fireHandler
        let now = self.now()
        await runDailyMaintenanceIfDue(at: now)
        let due: [Job]
        do {
            due = try ledger.dueJobs(at: now)
        } catch {
            print("[JobScheduler] could not read due jobs: \(error)")
            return 0
        }

        var planned: [(job: Job, fires: [Fire], resumes: Bool)] = []
        var handovers = 0
        for job in due {
            // The tick's cap counts fires, not jobs: a five-occurrence replay is five of them, so
            // one job catching up cannot start more work in a tick than three jobs coming due
            // together would. What the cap cuts short is still due, and the next tick takes it.
            if handovers >= maxFiresPerTick { break }
            // A pause is not always a cleared `nextFireAt` — D3 pauses a job on budget exhaustion
            // and leaves its cadence intact, so `dueJobs` keeps returning it — and a paused job
            // must not be bumped along a cadence it is no longer following. The reason is what
            // says it must not run, so honour it here rather than in the query. The runner drops
            // a paused fire too; this is what stops the cadence from drifting while it is quiet.
            if job.pausedReason != nil { continue }
            // A burst this loop cut short is still running; its row is due because the burst is
            // not finished, not because a fresh one is owed.
            if burstsInFlight.contains(job.id) { continue }

            guard handler != nil else {
                // Nothing to fire into: leave the job due rather than advancing past it, or every
                // run that came due before the engine finished wiring itself up is silently
                // consumed. A cadence that can never match again is the exception — that is not a
                // fire, it is broken no matter who is listening, and leaving it due would have
                // every tick recompute the same dead lookahead forever.
                if let cadence = Self.cadence(of: job.trigger), cadence.next(after: now) == nil {
                    pauseUnmatchable(job)
                }
                continue
            }

            let outcome = plan(for: job, at: now, budget: maxFiresPerTick - handovers)
            guard !outcome.fires.isEmpty else { continue }
            if outcome.resumes { burstsInFlight.insert(job.id) }
            planned.append((job, outcome.fires, outcome.resumes))
            handovers += outcome.fires.count
        }

        guard !planned.isEmpty, let handler else { return 0 }

        return await withTaskGroup(of: Int.self) { group in
            for entry in planned {
                group.addTask { [weak self] in
                    var started = 0
                    for fire in entry.fires {
                        started += 1
                        if await handler(entry.job, fire) { continue }
                        // R32: the burst ends at the first refusal, and what is left of it is
                        // abandoned rather than tried again on the next tick.
                        await self?.abandonCatchUp(of: entry.job, at: now)
                        break
                    }
                    // Whichever way the burst ended — run out, refused, abandoned — the job is
                    // the loop's again.
                    if entry.resumes { await self?.burstEnded(entry.job.id) }
                    return started
                }
            }
            var total = 0
            for await started in group { total += started }
            return total
        }
    }

    /// What this tick hands over for one due job, with `nextFireAt` already moved past all of it.
    ///
    /// `fires` empty means nothing fires — the row is gone, the cadence is dead, or the job's
    /// `catchUp` says these occurrences are not worth running. `resumes` means the written
    /// `nextFireAt` is still at or before `now`, so the row stays due and a later tick has to come
    /// back and finish the burst; only a `replay` the tick's cap cut short does that, and it is
    /// what `burstsInFlight` locks on.
    private struct Plan {
        var fires: [Fire] = []
        var resumes = false
    }

    /// `budget` is what is left of `maxFiresPerTick`, and is at least one.
    private func plan(for job: Job, at now: Date, budget: Int) -> Plan {
        let kind = job.trigger.kind
        // Cadence-less triggers (fsEvent) have no next occurrence to compute and nothing to fall
        // behind on; clear the stray nextFireAt that made this row due rather than pausing a job
        // the filesystem drives.
        guard let cadence = Self.cadence(of: job.trigger) else {
            return single(record(jobId: job.id, nextFireAt: nil, lastRunAt: job.lastRunAt), kind)
        }
        // Behind by more than one cadence — the Mac slept, or the app was closed — is the only
        // case `catchUp` has an opinion about (§5). One missed occurrence is an ordinary fire
        // whatever the policy says, because there is nothing to coalesce, skip or replay.
        guard let due = job.nextFireAt, let second = cadence.next(after: due), second <= now else {
            return single(advanceCadence(for: job, at: now), kind)
        }

        switch job.policy.catchUp {
        case .coalesce:
            // One fire now, rescheduled from now: the job does its work once against the world as
            // it is, rather than N times against a world that has moved on.
            return single(advanceCadence(for: job, at: now), kind)
        case .skip:
            // Not a fault and not a pause: the job asked for the missed work to be dropped, so
            // the cadence moves on and nothing is recorded.
            _ = advanceCadence(for: job, at: now)
            return Plan()
        case .replay(let cap):
            return replay(job: job, cadence: cadence, from: due, at: now, cap: cap, budget: budget)
        }
    }

    /// One ordinary fire, or none when the write that had to precede it did not land.
    private func single(_ written: Bool, _ kind: String, note: String? = nil) -> Plan {
        Plan(fires: written ? [Fire(reason: kind, note: note)] : [])
    }

    /// The `replay(cap:)` arm of `plan`, split out because it is the only one that writes a
    /// `nextFireAt` the tick may still be behind on.
    private func replay(job: Job, cadence: Schedule, from due: Date, at now: Date,
                        cap: Int, budget: Int) -> Plan {
        let kind = job.trigger.kind
        guard let missed = Self.missedOccurrences(of: cadence, from: due, to: now, keeping: cap) else {
            // Further behind than the walk will enumerate. See `maxMissedOccurrences`: that is a
            // restart, not a catch-up, and one fire against the present is what a restart wants.
            // Said on the card, not just to a console nobody running a GUI app is reading: this
            // quietly turns a `replay` job into a `coalesce` one for this fire, and everything
            // else in this subsystem that changes what a job does leaves a trace the user can find.
            return single(advanceCadence(for: job, at: now), kind, note: Self.tooFarBehindNote)
        }
        // What the tick has room for. A cap of zero is a real answer — replay nothing, drop the
        // lot — and reads the same here as a window that came back empty.
        let slots = missed.replay.prefix(budget)
        guard let lastPlanned = slots.last else {
            _ = advanceCadence(for: job, at: now)
            return Plan()
        }
        // Past the slots this tick hands over, and before any of them is fired: a crash mid-burst
        // then loses the rest rather than replaying them, the same direction every other fire
        // takes. When the tick's cap cut the burst short this is still in the past, which is what
        // leaves the job due for the next tick to finish — and what `burstsInFlight` has to cover
        // until this burst is done.
        guard let next = cadence.next(after: lastPlanned) else {
            pauseUnmatchable(job)
            return Plan()
        }
        guard record(jobId: job.id, nextFireAt: next, lastRunAt: job.lastRunAt) else { return Plan() }
        let fires = slots.enumerated().map { index, _ in
            Fire(reason: kind,
                 note: index == 0 && missed.dropped > 0 ? Self.skippedNote(missed.dropped) : nil)
        }
        return Plan(fires: fires, resumes: next <= now)
    }

    /// Releases a job whose truncated burst has ended, so the loop can plan it again.
    private func burstEnded(_ jobId: UUID) {
        burstsInFlight.remove(jobId)
    }

    /// Gives up on the rest of a catch-up burst and puts the job back on its ordinary cadence.
    ///
    /// Decided on the row as it is now, not on the copy this tick was handed, and it does nothing
    /// unless that row is *still* behind — which is the only state a burst with occurrences owed
    /// can be in. An ordinary fire that admission refused has nothing to abandon: `plan` already
    /// moved it to the same instant this would write, and writing again would put a stale
    /// `lastRunAt` back over the stamp a held `queue` fire may have left while the tick waited.
    /// A job the fire itself paused is left alone for the same reason the tick loop leaves one
    /// alone: a paused job must not be bumped along a cadence it is no longer following.
    private func abandonCatchUp(of job: Job, at now: Date) {
        guard let cadence = Self.cadence(of: job.trigger) else { return }
        guard let stored = try? ledger.job(id: job.id), stored.pausedReason == nil,
              let owed = stored.nextFireAt, owed <= now else { return }
        guard let next = cadence.next(after: now) else {
            pauseUnmatchable(job)
            return
        }
        _ = record(jobId: job.id, nextFireAt: next, lastRunAt: stored.lastRunAt)
    }

    // MARK: Catch-up arithmetic (#187 §5)

    /// The most occurrences the catch-up walk will step through before it gives up on enumerating
    /// them one at a time. A per-minute cadence and a fortnight with the app closed is 20,160 of
    /// them, and `CronSchedule`'s four-year lookahead puts the ceiling at two million: stepping
    /// through those on the actor at wake would cost far more than the five runs at the end of
    /// them are worth, and a job that far behind is not catching up, it is starting again.
    static let maxMissedOccurrences = 10_000

    /// What a replay has to work with: the `cap` most recent occurrences a cadence should have
    /// fired at and did not, oldest first, and a count of the older ones being dropped.
    ///
    /// The most recent, not the oldest. Two reasons, and they point the same way: a job that slept
    /// through thirty-two quarter-hours wants the last five states of the world rather than five
    /// from eight hours ago, and rescheduling from the oldest five would leave the job still
    /// behind — the next tick would find it behind again and replay another capful, until it had
    /// run every occurrence the cap exists to prevent.
    ///
    /// `from` is itself the first missed occurrence: it is the `nextFireAt` that made the row due.
    /// `nil` means the job is further behind than `limit` occurrences, which the caller coalesces.
    ///
    /// The walk demands strictly forward progress from `next(after:)` and stops when it does not
    /// get it. Nothing in `CronSchedule` should ever hand back the instant it was given — the
    /// fall-back repeated-hour bug that could (#252) is fixed — but an `interval` cadence of zero
    /// seconds decoded out of a hand-edited row would, and a loop that never ends on an actor
    /// takes the scheduler and a core with it.
    static func missedOccurrences(of cadence: Schedule, from due: Date, to now: Date,
                                  keeping cap: Int,
                                  limit: Int = maxMissedOccurrences) -> (replay: [Date], dropped: Int)? {
        guard cap > 0 else { return ([], 0) }
        var window: [Date] = []
        var dropped = 0
        var occurrence = due
        var steps = 0
        while occurrence <= now {
            window.append(occurrence)
            if window.count > cap {
                window.removeFirst()
                dropped += 1
            }
            steps += 1
            if steps > limit { return nil }
            guard let next = cadence.next(after: occurrence), next > occurrence else { break }
            occurrence = next
        }
        return (window, dropped)
    }

    /// What the one fire of a job past `maxMissedOccurrences` says for itself. Its `replay` policy
    /// is intact and its next ordinary catch-up will honour it; this fire alone coalesced.
    static let tooFarBehindNote = "too far behind to replay; ran once instead"

    /// What the first fire of a replay burst says about the occurrences the cap dropped.
    static func skippedNote(_ count: Int) -> String {
        "\(count) earlier occurrence\(count == 1 ? "" : "s") skipped"
    }

    /// Runs the daily chore if a day has passed since the last one, from the top of the tick so a
    /// ledger read that throws cannot cost the app its retention pass.
    ///
    /// `lastMaintenanceAt` moves *before* the hook is awaited: `tick()` is dispatched detached
    /// from the poll loop, so a maintenance pass that outlasts the poll interval would otherwise
    /// have the next tick start a second one on top of it.
    private func runDailyMaintenanceIfDue(at now: Date) async {
        guard let lastMaintenanceAt else {
            // A scheduler that was never `start()`ed — a test, or a `schedule_job` write-only
            // instance. Day zero begins now, and nothing fires: see the property's note.
            self.lastMaintenanceAt = now
            return
        }
        guard now.timeIntervalSince(lastMaintenanceAt) >= Self.maintenanceInterval,
              let onDailyMaintenance else { return }
        self.lastMaintenanceAt = now
        await onDailyMaintenance()
    }

    /// Moves a job past the trigger being handed over, and says whether it is still schedulable —
    /// false when the row is gone or the cadence has no future match.
    ///
    /// Always before the handler, never after: a crash between the two loses a run instead of
    /// repeating one. `lastRunAt` is deliberately left alone — the scheduler no longer knows
    /// whether this trigger will become a run (admission is the runner's, §4), so the runner
    /// stamps it with `setLastRun` when a turn actually starts.
    private func advanceCadence(for job: Job, at now: Date) -> Bool {
        let lastRunAt = job.lastRunAt
        // Cadence-less triggers (fsEvent) have no next occurrence to compute; clear the stray
        // nextFireAt that made this row due rather than pausing a job the filesystem drives.
        guard let cadence = Self.cadence(of: job.trigger) else {
            return record(jobId: job.id, nextFireAt: nil, lastRunAt: lastRunAt)
        }
        guard let next = cadence.next(after: now) else {
            pauseUnmatchable(job)
            return false
        }
        return record(jobId: job.id, nextFireAt: next, lastRunAt: lastRunAt)
    }

    /// Stops a job whose cadence has no next occurrence from being due forever, and says why.
    private func pauseUnmatchable(_ job: Job) {
        do {
            try ledger.setPaused(jobId: job.id, reason: Self.unmatchableReason)
            try ledger.setNextFire(jobId: job.id, at: nil, lastRunAt: job.lastRunAt)
        } catch {
            print("[JobScheduler] could not pause job \(job.name): \(error)")
        }
    }

    /// Writes a fire's bookkeeping. Returns false when the job has been deleted out from under the
    /// tick, in which case there is nothing left to fire.
    private func record(jobId: UUID, nextFireAt: Date?, lastRunAt: Date?) -> Bool {
        do {
            try ledger.setNextFire(jobId: jobId, at: nextFireAt, lastRunAt: lastRunAt)
            return true
        } catch {
            print("[JobScheduler] skipping job \(jobId): \(error)")
            return false
        }
    }

    /// Starts the polling loop and the wake observer. Calling it twice replaces the first loop
    /// rather than running two.
    func start(interval: TimeInterval = 10) {
        stop()
        // Day zero for the maintenance hook. Launch-time retention is `configureJobBookkeeping`'s
        // own explicit call — this only decides when the *next* one is due.
        lastMaintenanceAt = now()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Detached so one slow handler cannot stall the cadence of the poll itself.
                Task { await self?.tick() }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        // Sleep stops the timer, so every job that came due while the Mac was asleep is still
        // sitting in the ledger; catch up the moment it wakes instead of up to `interval` later.
        // This is NSWorkspace's own centre, not `NotificationCenter.default`, which never sees it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.tick() }
        }
    }

    /// Cancels the polling loop and the wake observer. Nothing calls this in the app: the
    /// scheduler is app-lifetime, and `applicationWillTerminate` ends the process with `_exit(0)`
    /// without an async teardown for `MCPManager` or `WatcherManager` either. It exists so tests
    /// can tear a scheduler down, so `start()` is idempotent, and for a future orderly shutdown.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Stores `job` with its first fire computed, and returns what was stored. A cadence that
    /// matches nothing is stored paused rather than silently never running.
    @discardableResult
    func schedule(_ job: Job) async throws -> Job {
        var stored = job
        if let cadence = Self.cadence(of: job.trigger) {
            stored.nextFireAt = cadence.next(after: now())
            if stored.nextFireAt == nil { stored.pausedReason = Self.unmatchableReason }
        }
        try ledger.upsert(stored)
        return stored
    }

    /// Drops the two `UserDefaults` keys the pre-ledger scheduler and watcher persisted to, so a
    /// build that still reads them cannot resurrect a job the ledger does not know about.
    ///
    /// Nothing is imported: no install outside development ever had a real job in these keys, so
    /// an importer would be untested code carrying untested records. What was there is counted and
    /// logged once on the way out, because after this call the only evidence it existed is the
    /// line — and a machine that turns out to have had ten of them is worth knowing about.
    @discardableResult
    static func removeLegacyDefaults(from store: UserDefaults, log: (String) -> Void = { print($0) }) -> (jobs: Int, watcherRules: Int) {
        let jobs = legacyRecordCount(store.data(forKey: "iris_scheduled_jobs"))
        let rules = legacyRecordCount(store.data(forKey: "WATCHER_RULES"))
        store.removeObject(forKey: "iris_scheduled_jobs")
        store.removeObject(forKey: "WATCHER_RULES")
        if jobs + rules > 0 {
            log("[JobScheduler] dropped \(jobs) legacy scheduled job(s) and \(rules) legacy watcher rule(s) from UserDefaults; they are not imported — the jobs table is the only store now.")
        }
        return (jobs, rules)
    }

    /// The one-time line the app shows for what `removeLegacyDefaults` just deleted, or nil when
    /// there was nothing to delete. The log line above is a `print`, which nobody running a macOS
    /// app ever reads: no importer ships, so this sentence in the conversation is the user's only
    /// notice that records they created are gone and have to be made again.
    static func legacyDropNotice(jobs: Int, watcherRules: Int) -> String? {
        var counted: [String] = []
        if jobs > 0 { counted.append("\(jobs) scheduled job\(jobs == 1 ? "" : "s")") }
        if watcherRules > 0 { counted.append("\(watcherRules) watcher rule\(watcherRules == 1 ? "" : "s")") }
        guard !counted.isEmpty else { return nil }
        let verb = jobs + watcherRules == 1 ? "was" : "were"
        return "Iris no longer reads the scheduled jobs and watcher rules saved by an earlier version: "
            + "\(counted.joined(separator: " and ")) \(verb) dropped. "
            + "Recreate them with schedule_job or register_directory_watcher."
    }

    /// The length of a legacy JSON array blob. Read as untyped JSON rather than through the old
    /// `Codable` types, which no longer exist: a count does not need the fields, and a row the old
    /// decoder would have rejected still counts as something the user lost.
    private static func legacyRecordCount(_ data: Data?) -> Int {
        guard let data, let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return array.count
    }
}
