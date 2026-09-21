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
    static let unmatchableReason = "no matching time in the next year"

    private let ledger: JobLedger
    private let now: @Sendable () -> Date
    private let maxFiresPerTick: Int

    private var fireHandler: FireHandler?
    /// Jobs whose handler has not returned yet. The spec's `skip` overlap policy: a job that is
    /// still running when its next fire comes round does not start a second copy. (The ledger row
    /// recording the skip is deliverable 2's.)
    private var firing: Set<UUID> = []
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

    /// The cadence governing a trigger, if it has one. `fsEvent` has none — it is driven by the
    /// filesystem, not the clock — and a `poll` trigger's cadence is how often its gate is checked.
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
    /// already moved and `firing` covers the window before it does.
    @discardableResult
    func tick() async -> Int {
        let handler = fireHandler
        let now = self.now()
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
            if firing.contains(job.id) { continue }
            // A pause is not always a cleared `nextFireAt`: D3 pauses a job on budget exhaustion
            // and leaves its cadence intact, so `dueJobs` keeps returning it. The reason is what
            // says it must not run — honour it here rather than in the query.
            if job.pausedReason != nil { continue }

            // Cadence-less triggers (fsEvent) have no next occurrence to compute; clear the stray
            // nextFireAt that made this row due rather than pausing a job the filesystem drives.
            guard let cadence = Self.cadence(of: job.trigger) else {
                guard handler != nil else { continue }
                if record(jobId: job.id, nextFireAt: nil, lastRunAt: now) {
                    toFire.append(job)
                }
                continue
            }

            guard let next = cadence.next(after: now) else {
                // Not a fire, so this runs whether or not a handler is set: a cadence that can
                // never match again is broken no matter who is listening, and leaving it due
                // would have every tick recompute the same dead lookahead forever.
                do {
                    try ledger.setPaused(jobId: job.id, reason: Self.unmatchableReason)
                    try ledger.setNextFire(jobId: job.id, at: nil, lastRunAt: job.lastRunAt)
                } catch {
                    print("[JobScheduler] could not pause job \(job.name): \(error)")
                }
                continue
            }

            // Nothing to fire into: leave the job due rather than advancing past it, or every
            // run that came due before the engine finished wiring itself up is silently consumed.
            guard handler != nil else { continue }

            // Before the handler, never after: a crash between the two loses a run instead of
            // repeating one.
            if record(jobId: job.id, nextFireAt: next, lastRunAt: now) {
                toFire.append(job)
            }
        }

        guard !toFire.isEmpty, let handler else { return 0 }
        for job in toFire { firing.insert(job.id) }

        await withTaskGroup(of: UUID.self) { group in
            for job in toFire {
                group.addTask {
                    await handler(job, job.trigger.kind)
                    return job.id
                }
            }
            for await id in group { firing.remove(id) }
        }
        return toFire.count
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
    static func removeLegacyDefaults(from store: UserDefaults) {
        store.removeObject(forKey: "iris_scheduled_jobs")
        store.removeObject(forKey: "WATCHER_RULES")
    }
}
