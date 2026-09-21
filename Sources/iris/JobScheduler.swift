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
    /// Called once per fire, off the ledger's write path. `reason` is the trigger kind that caused
    /// it, so a handler can tell a cadence fire from a poll or a watch.
    typealias FireHandler = @Sendable (Job, _ reason: String) async -> Void

    /// The `pausedReason` written for a cadence whose `next(after:)` finds nothing inside
    /// `CronSchedule`'s lookahead — a job that can never run again (`0 0 30 2 *`) must stop being
    /// due every tick forever, and the user needs to be told why it went quiet.
    static let unmatchableReason = "no matching time in the next four years"

    private let ledger: JobLedger
    private let now: @Sendable () -> Date
    private let maxFiresPerTick: Int

    private var fireHandler: FireHandler?
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

    /// Fires every due job, up to `maxFiresPerTick`, and returns how many were started.
    ///
    /// Awaits the batch it started, so a caller (and a test) can observe the fires this tick
    /// caused. `start()`'s loop therefore runs each tick detached: a handler that takes an hour
    /// must not hold up the next poll, and an overlapping tick is safe because `nextFireAt` has
    /// already moved before the handler is called and the runner refuses a job it is already
    /// running (§4) — overlap is the runner's, so a watch fire is covered by the same set.
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

        var toFire: [Job] = []
        for job in due {
            if toFire.count >= maxFiresPerTick { break }
            // A pause is not always a cleared `nextFireAt` — D3 pauses a job on budget exhaustion
            // and leaves its cadence intact, so `dueJobs` keeps returning it — and a paused job
            // must not be bumped along a cadence it is no longer following. The reason is what
            // says it must not run, so honour it here rather than in the query. The runner drops
            // a paused fire too; this is what stops the cadence from drifting while it is quiet.
            if job.pausedReason != nil { continue }

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

            if advanceCadence(for: job, at: now) { toFire.append(job) }
        }

        guard !toFire.isEmpty, let handler else { return 0 }

        await withTaskGroup(of: Void.self) { group in
            for job in toFire {
                group.addTask { await handler(job, job.trigger.kind) }
            }
        }
        return toFire.count
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
