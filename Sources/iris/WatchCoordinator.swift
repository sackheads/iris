import Foundation

/// One burst's worth of change, handed to the runner (#187 deliverable 4, spec §2).
struct WatchFire: Sendable, Equatable {
    /// Sorted and distinct, bounded by `WatchCoordinator.maxTrackedPaths`.
    let paths: [String]
    /// What the burst saw and what it absorbed, for the run row and the card.
    let summary: WatchSummary
}

/// How a fire reaches the runner, and what the runner says back. The return is the admission the
/// coordinator branches on (§2, step 3); `nil` means the job is gone or unreadable, and the
/// subscriber goes with it.
typealias WatchFireHandler = @Sendable (Job, WatchFire) async -> JobRunner.Admission?

/// The actor that owns a watch's *time* (#187 deliverable 4, spec §2).
///
/// `WatcherManager` owns FSEvents streams; everything that has to be decided over an interval —
/// the quiet window, the ceiling, which paths are still owed to a run, what a burst absorbed —
/// lives here, because a stream can be stopped and restarted for reasons that have nothing to do
/// with a burst in progress and a timer held in the manager would die with it.
///
/// Two design rules hold the concurrency together, and breaking either one is the bug this file
/// exists to prevent:
///
/// 1. **The loop never awaits a run.** A fire is dispatched in a `Task` of its own; `tick(now:)`
///    returns immediately, so one watch's run cannot stall every other watch's window. At most one
///    fire is outstanding per subscriber, which is what makes "the run in flight" a single state
///    rather than a set.
/// 2. **A path is in exactly one of `pending`, `heldPaths`, or a started run, at every instant.**
///    The fired paths move into `heldPaths` *before* the handler is called, so the runner's held
///    re-fire (§3) always finds them, and a run that ends before the coordinator has stashed
///    anything is not a state that exists.
///
/// Time is injected (`now`) and evaluation is a method (`tick(now:)`), so every window, ceiling
/// and re-ask in the tests is an instant the test chose. Nothing here sleeps on its own clock
/// except `startLoop`, which is the production wrapper.
actor WatchCoordinator {
    /// Distinct paths kept per subscriber, for `pending` and for `heldPaths` each. Beyond it a
    /// path is counted in `changed` and `overflow` and dropped: a build writing thousands of files
    /// into a watched directory during a long queued run must cost a number, not memory.
    static let maxTrackedPaths = 1_000
    /// Paths that reach the prompt. The rest are one line of arithmetic (`JobRunner.buildPrompt`).
    static let maxDeliveredPaths = 100
    /// A burst fires at `quietWindowSeconds × this` however busy the directory is. Fixed, derived,
    /// never stored: one knob to get wrong instead of two.
    static let ceilingMultiplier = 10

    /// The editor and VCS noise every watch absorbs, spelled once (§0.4). `.#*` is Emacs's lock
    /// file, `4913` is Vim's directory-write probe, and the last two are Foundation's atomic-write
    /// temp forms — every `write_file` in a watched directory produces one.
    static let builtInIgnore: [String] = [
        ".git/", ".DS_Store", "node_modules/", "*~", "*.swp", "*.swx", ".#*", "4913", "*.tmp",
        ".*.sb-*", "(A Document Being Saved By *",
    ]

    /// Spec §2's table, plus the two things the admission branches need: what the runner last
    /// said, and the fire that is still outstanding.
    private struct Subscriber {
        /// As of the last `sync` — the copy a fire is built from, not the copy it runs on. The
        /// run always re-reads the row.
        var job: Job
        var watch: FSWatch
        /// The built-in set plus this watch's own globs, compiled once per `sync`.
        var ignore: @Sendable (String) -> Bool
        var pending: Set<String> = []
        var heldPaths: Set<String> = []
        var fireOutstanding = false
        var burstBegan: Date?
        var lastAccepted: Date?
        var coalesced = 0
        var changed = 0
        var overflow = 0
        var noise = 0
        var ownWrites = 0
        var absorbedSinceLaunch = AbsorbedCounts()
        /// What the handler answered for the outstanding fire, once it has answered.
        var lastAdmission: JobRunner.Admission?
        /// The fire the handler is still holding, kept so a `.skipInFlight` re-ask can carry the
        /// same burst's figures rather than inventing a new set.
        var outstandingFire: WatchFire?
        /// When a `.skipInFlight` subscriber may ask again (R-D4-2). One ask per ceiling, on the
        /// grid the burst's own ceiling sits on.
        var reAskDue: Date?

        var quiet: TimeInterval { TimeInterval(watch.quietWindowSeconds) }
        var ceiling: TimeInterval { quiet * TimeInterval(WatchCoordinator.ceilingMultiplier) }
    }

    private let ledger: JobLedger
    private let now: @Sendable () -> Date
    private let recentWrites: RecentWrites
    private let fire: WatchFireHandler
    private var subscribers: [UUID: Subscriber] = [:]
    private var loop: Task<Void, Never>?

    init(ledger: JobLedger, now: @escaping @Sendable () -> Date, recentWrites: RecentWrites,
         fire: @escaping WatchFireHandler) {
        self.ledger = ledger
        self.now = now
        self.recentWrites = recentWrites
        self.fire = fire
    }

    // MARK: Subscribers

    /// The subscriber set, from the jobs the ledger hook handed over (§7 calls this immediately
    /// before `WatcherManager.sync`).
    ///
    /// A job that is gone, disabled or paused is removed with everything it held: `/jobs` has
    /// nothing to show a removed subscriber's counts against, and a paused watch that kept its
    /// burst would fire it the moment it resumed, hours later. A re-registration — the same id
    /// with a different root — keeps `absorbedSinceLaunch` and nothing else, because "how noisy is
    /// this watch" is the one figure that survives the edit. A window or glob edit is not a
    /// re-registration: it rebuilds the matcher and takes effect from the next accepted event,
    /// leaving `pending` alone rather than re-filtering paths against a rule that did not exist
    /// when they arrived.
    func sync(with jobs: [Job]) {
        var wanted: Set<UUID> = []
        for job in jobs {
            guard job.enabled, job.pausedReason == nil,
                  case .fsEvent(let watch) = job.trigger else { continue }
            wanted.insert(job.id)
            guard var existing = subscribers[job.id] else {
                subscribers[job.id] = Subscriber(job: job, watch: watch, ignore: Self.matcher(for: watch))
                continue
            }
            let overlapWas = existing.job.policy.overlap
            existing.job = job
            if existing.watch.path != watch.path {
                existing.watch = watch
                existing.ignore = Self.matcher(for: watch)
                endBurst(&existing)
                existing.heldPaths = []
                existing.fireOutstanding = false
                existing.outstandingFire = nil
                existing.lastAdmission = nil
                existing.reAskDue = nil
                subscribers[job.id] = existing
                continue
            }
            if existing.watch.ignore != watch.ignore { existing.ignore = Self.matcher(for: watch) }
            existing.watch = watch
            // `queue` → `skip` with a queued fire outstanding: the runner will discard the queued
            // fire it was holding, so nobody else would ever take these paths. Release them into a
            // fresh burst rather than lose an edit session to a policy edit.
            if overlapWas == .queue, job.policy.overlap == .skip, existing.fireOutstanding,
               existing.lastAdmission == .queued {
                existing.pending.formUnion(existing.heldPaths)
                existing.heldPaths = []
                existing.fireOutstanding = false
                existing.outstandingFire = nil
                existing.lastAdmission = nil
                existing.reAskDue = nil
                let at = now()
                existing.burstBegan = at
                existing.lastAccepted = at
                existing.coalesced = existing.pending.count
                existing.changed = existing.pending.count
                existing.overflow = 0
                existing.noise = 0
                existing.ownWrites = 0
            }
            subscribers[job.id] = existing
        }
        for id in subscribers.keys where !wanted.contains(id) { subscribers[id] = nil }
    }

    private static func matcher(for watch: FSWatch) -> @Sendable (String) -> Bool {
        WatchGlob.matcher(builtInIgnore + watch.ignore)
    }

    // MARK: Events

    /// One FSEvents batch, tagged with the stream root it arrived on.
    ///
    /// The batch is fanned out once to every subscriber the path is under, so a watch nested
    /// inside another watch is served by the ancestor's stream and never gets a second copy
    /// (§0.5). `root` is what the stream was started for; coverage is decided per *path*, because
    /// one stream serves several subscribers at different depths.
    ///
    /// Every path is normalised with `IrisPaths.canonicalPath` before anything else (R-D4-5). A
    /// bare `standardizingPath` would not do: its `/private` strip is conditional on the leaf
    /// existing, so a delete event — a path that by definition no longer exists — under `/var`,
    /// `/tmp` or `/etc` arrives spelled `/private/…` and matches neither the canonical root nor
    /// the registry entry the write recorded. The roots and `RecentWrites` use the same helper, so
    /// all three agree on one spelling.
    func deliver(root: String, paths: [String]) async {
        let at = now()
        let canonical = paths.map { IrisPaths.canonicalPath($0) }

        // The registry is another actor, so every answer is gathered before anything is applied:
        // a `sync` or a `tick` interleaving on the await must not find a half-updated subscriber,
        // and a copy written back afterwards would clobber it.
        struct Decision { let id: UUID; let path: String; let verdict: Verdict }
        enum Verdict { case noise, ownWrite, accept }
        var decisions: [Decision] = []
        var ownWriteCache: [String: Bool] = [:]

        for (id, subscriber) in subscribers {
            let root = subscriber.watch.path
            let expiry = RecentWrites.expiry(quietWindowSeconds: subscriber.watch.quietWindowSeconds)
            for path in canonical {
                guard Self.covers(root: root, path: path) else { continue }
                if subscriber.ignore(Self.relative(path, under: root)) {
                    decisions.append(Decision(id: id, path: path, verdict: .noise))
                    continue
                }
                let key = "\(expiry)\u{0}\(path)"
                let own: Bool
                if let cached = ownWriteCache[key] {
                    own = cached
                } else {
                    own = await recentWrites.isOwn(path, within: expiry)
                    ownWriteCache[key] = own
                }
                decisions.append(Decision(id: id, path: path, verdict: own ? .ownWrite : .accept))
            }
        }

        for decision in decisions {
            guard var subscriber = subscribers[decision.id] else { continue }
            switch decision.verdict {
            case .noise:
                subscriber.absorbedSinceLaunch.noise += 1
                // Only a burst in progress has burst counters to add to; absorbed events between
                // bursts are a running total and nothing else (§2).
                if subscriber.burstBegan != nil { subscriber.noise += 1 }
            case .ownWrite:
                subscriber.absorbedSinceLaunch.ownWrites += 1
                if subscriber.burstBegan != nil { subscriber.ownWrites += 1 }
            case .accept:
                subscriber.coalesced += 1
                if subscriber.fireOutstanding {
                    // The burst is over; these belong to whatever takes the hold, and the timers
                    // are not restarted until the run's handler returns.
                    Self.insert(decision.path, held: true, into: &subscriber)
                } else {
                    Self.insert(decision.path, held: false, into: &subscriber)
                    subscriber.burstBegan = subscriber.burstBegan ?? at
                    subscriber.lastAccepted = at
                }
            }
            subscribers[decision.id] = subscriber
        }
    }

    /// Lexical, on canonical forms, and never a `stat`: FSEvents reports a path under the root it
    /// was given, and a delete names a leaf that is already gone.
    private static func covers(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func relative(_ path: String, under root: String) -> String {
        guard path.count > root.count else { return "" }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    /// The bound and the counting in one place, so `pending` and `heldPaths` cannot drift apart.
    /// A path already in the set is a coalesced repeat and nothing more; a new one past the bound
    /// is counted twice over — in `changed`, which is the true figure, and in `overflow`, which is
    /// what says the true figure is not the list.
    private static func insert(_ path: String, held: Bool, into subscriber: inout Subscriber) {
        let count = held ? subscriber.heldPaths.count : subscriber.pending.count
        if held ? subscriber.heldPaths.contains(path) : subscriber.pending.contains(path) { return }
        guard count < maxTrackedPaths else {
            subscriber.changed += 1
            subscriber.overflow += 1
            return
        }
        if held { subscriber.heldPaths.insert(path) } else { subscriber.pending.insert(path) }
        subscriber.changed += 1
    }

    // MARK: Evaluation

    /// The injectable heart. Production's loop is a thin wrapper that sleeps to `nextDeadline()`
    /// and calls this; a test calls it with an instant it chose.
    ///
    /// Nothing here suspends: a fire is dispatched, never awaited, so the whole pass over the
    /// subscribers is one atomic step of the actor and no batch can interleave halfway through it.
    func tick(now at: Date) async {
        for id in subscribers.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let subscriber = subscribers[id] else { continue }
            if subscriber.fireOutstanding {
                if subscriber.lastAdmission == .skipInFlight, let due = subscriber.reAskDue, at >= due {
                    reAsk(id, at: at)
                }
                continue
            }
            guard !subscriber.pending.isEmpty,
                  let began = subscriber.burstBegan, let last = subscriber.lastAccepted else { continue }
            let ceiling = began.addingTimeInterval(subscriber.ceiling)
            let deadline = Swift.min(last.addingTimeInterval(subscriber.quiet), ceiling)
            guard at >= deadline else { continue }
            startFire(id, at: at, ceilingFired: at >= ceiling)
        }
    }

    /// The earliest instant at which `tick` would do something — what the production loop sleeps
    /// to. `nil` when every subscriber is idle: nothing is waiting on a clock.
    func nextDeadline() -> Date? {
        var earliest: Date?
        for subscriber in subscribers.values {
            var candidate: Date?
            if subscriber.fireOutstanding {
                if subscriber.lastAdmission == .skipInFlight { candidate = subscriber.reAskDue }
            } else if !subscriber.pending.isEmpty,
                      let began = subscriber.burstBegan, let last = subscriber.lastAccepted {
                candidate = Swift.min(last.addingTimeInterval(subscriber.quiet),
                                      began.addingTimeInterval(subscriber.ceiling))
            }
            guard let candidate else { continue }
            earliest = earliest.map { Swift.min($0, candidate) } ?? candidate
        }
        return earliest
    }

    // MARK: Firing

    /// Step 1 of §2's firing order — the ledger read — then step 2, the hand-over.
    private func startFire(_ id: UUID, at: Date, ceilingFired: Bool) {
        guard var subscriber = subscribers[id] else { return }

        let fresh: Job?
        do {
            fresh = try ledger.job(id: id)
        } catch {
            // Never silent, and never a fire with the filter bypassed: the check that decides
            // whether this job may run at all could not be made, so the burst is dropped and the
            // row says why. A watch fire never retries (deliverable 3's rule), so the next burst
            // is what tries again.
            do {
                try JobRunner.recordStillborn(job: subscriber.job, ledger: ledger,
                                              reason: "watch fire dropped: \(error)",
                                              triggerKind: Trigger.fsEventKind, now: at, note: nil)
            } catch {
                print("[WatchCoordinator] could not record the dropped fire of \(subscriber.job.name): \(error)")
            }
            endBurst(&subscriber)
            subscribers[id] = subscriber
            return
        }

        guard let fresh else {
            // The row is gone, or no longer decodes. Count nothing: there is nothing left to
            // count it against, and `sync` removes the subscriber on the next ledger change.
            endBurst(&subscriber)
            subscribers[id] = subscriber
            return
        }

        guard fresh.enabled, fresh.pausedReason == nil else {
            // Between the burst and this tick the job stopped. The changes still happened, and a
            // user who pauses a watch, works for an hour and resumes should be able to see in
            // `/jobs` that they did.
            subscriber.absorbedSinceLaunch.whilePaused += subscriber.changed
            endBurst(&subscriber)
            subscribers[id] = subscriber
            return
        }

        subscriber.job = fresh
        // `heldPaths` is empty whenever no fire is outstanding — `.run` moves the remainder into
        // `pending`, every other refusal drops it — so this union cannot exceed the bound.
        subscriber.heldPaths.formUnion(subscriber.pending)
        subscriber.pending = []
        subscriber.fireOutstanding = true
        let paths = subscriber.heldPaths.sorted()
        let summary = WatchSummary(delivered: Swift.min(paths.count, Self.maxDeliveredPaths),
                                   changed: subscriber.changed, overflow: subscriber.overflow,
                                   coalesced: subscriber.coalesced, noise: subscriber.noise,
                                   ownWrites: subscriber.ownWrites, ceilingFired: ceilingFired,
                                   pathsWithheld: false)
        let outstanding = WatchFire(paths: paths, summary: summary)
        subscriber.outstandingFire = outstanding
        subscriber.lastAdmission = nil
        // One ask per ceiling if the runner turns this down as a `skip` overlap (R-D4-2): the grid
        // is the burst's own ceiling, so a watch that fired on its window still waits the full
        // ceiling from the burst before it costs the ledger two more sums.
        let burstCeiling = (subscriber.burstBegan ?? at).addingTimeInterval(subscriber.ceiling)
        subscriber.reAskDue = burstCeiling > at ? burstCeiling : at.addingTimeInterval(subscriber.ceiling)
        zeroBurstCounters(&subscriber)
        subscriber.burstBegan = nil
        subscriber.lastAccepted = nil
        subscribers[id] = subscriber

        dispatch(id, job: fresh, fire: outstanding)
    }

    /// R-D4-2. A `.skipInFlight` subscriber offers its held set again once the ceiling has passed.
    ///
    /// §2's letter says the subscriber waits for "the handler that started the run" to return, but
    /// that handler is never one of this coordinator's: at most one fire is outstanding per
    /// subscriber, so the run in flight is a `/jobs run` or an approved call, and there is nothing
    /// to wait on. Re-asking writes no row for a watcher origin (`JobRunner.fire`'s `.skipInFlight`
    /// branch returns before `recordSkip`) but costs two ledger sums per ask, so the interval is
    /// the ceiling rather than the window: at the default, one ask per 30 s for the length of a
    /// human-started run, not one per 3 s.
    private func reAsk(_ id: UUID, at: Date) {
        guard var subscriber = subscribers[id], let previous = subscriber.outstandingFire else { return }
        let paths = subscriber.heldPaths.sorted()
        // The same burst, plus whatever arrived while the run lasted. Keeping the previous summary
        // verbatim would under-report a hold that grew — and those counters have nowhere else to
        // be reported, because the burst that would have carried them ended at the first ask.
        let summary = WatchSummary(
            delivered: Swift.min(paths.count, Self.maxDeliveredPaths),
            changed: previous.summary.changed + subscriber.changed,
            overflow: previous.summary.overflow + subscriber.overflow,
            coalesced: previous.summary.coalesced + subscriber.coalesced,
            noise: previous.summary.noise + subscriber.noise,
            ownWrites: previous.summary.ownWrites + subscriber.ownWrites,
            ceilingFired: previous.summary.ceilingFired,
            pathsWithheld: false)
        zeroBurstCounters(&subscriber)
        let offer = WatchFire(paths: paths, summary: summary)
        subscriber.outstandingFire = offer
        subscriber.lastAdmission = nil
        subscriber.reAskDue = at.addingTimeInterval(subscriber.ceiling)
        let job = subscriber.job
        subscribers[id] = subscriber
        dispatch(id, job: job, fire: offer)
    }

    /// Step 2's last line: the run goes out in a task of its own, and the loop carries on. The
    /// admission comes back through `apply`.
    private func dispatch(_ id: UUID, job: Job, fire offer: WatchFire) {
        let handler = fire
        Task { [self] in
            let admission = await handler(job, offer)
            await apply(admission, to: id, firedPaths: offer.paths)
        }
    }

    /// Step 3: what the runner said, applied to the hold.
    private func apply(_ admission: JobRunner.Admission?, to id: UUID, firedPaths: [String]) {
        guard var subscriber = subscribers[id] else { return }
        guard let admission else {
            // The job is gone or unreadable. Drop everything for this subscriber and count
            // nothing: there is nothing left to show a count against.
            subscribers[id] = nil
            return
        }
        subscriber.lastAdmission = admission
        switch admission {
        case .run:
            // The handler returned, so the run is over. Only the paths it was given are spent.
            subscriber.heldPaths.subtract(firedPaths)
            subscriber.fireOutstanding = false
            subscriber.outstandingFire = nil
            subscriber.reAskDue = nil
            if !subscriber.heldPaths.isEmpty {
                // Anything accepted during the run begins a new burst, so the quiet window runs
                // from the end of the run rather than from an edit made in the middle of it.
                subscriber.pending = subscriber.heldPaths
                subscriber.heldPaths = []
                let at = now()
                subscriber.burstBegan = at
                subscriber.lastAccepted = at
            }
        case .queued:
            // The runner is holding a fire for these paths and will come back for them through
            // `takeHeldPaths`, which is what clears `fireOutstanding`. The re-fire is the
            // continuation of this fire, not a new one.
            break
        case .skipInFlight:
            // The paths stay held and the subscriber asks again one ceiling from now.
            break
        case .dropPaused, .dropDisabled, .pauseBreaker, .pauseBudget, .dropUnavailable,
             .gateUnchanged, .gateError:
            // A refused job will not be admitted a moment later, and re-offering would write a
            // row per burst for a job whose whole problem is that it is running too often.
            subscriber.heldPaths = []
            subscriber.fireOutstanding = false
            subscriber.outstandingFire = nil
            subscriber.reAskDue = nil
            endBurst(&subscriber)
        }
        subscribers[id] = subscriber
    }

    /// What the runner's held re-fire takes (§3): everything this subscriber is still owed, in one
    /// sorted list, and the end of the outstanding fire.
    ///
    /// The union rather than just the hold, because a `queue`d run's re-fire is the only thing
    /// that will take either set — anything accepted since the fire would otherwise wait for a
    /// window that no longer has a burst behind it. The burst counters go with the paths: they
    /// describe what is being taken, and leaving them would have the next fire report this burst
    /// twice.
    func takeHeldPaths(_ jobId: UUID) -> [String] {
        guard var subscriber = subscribers[jobId] else { return [] }
        let taken = subscriber.heldPaths.union(subscriber.pending).sorted()
        subscriber.heldPaths = []
        subscriber.pending = []
        subscriber.fireOutstanding = false
        subscriber.outstandingFire = nil
        subscriber.lastAdmission = nil
        subscriber.reAskDue = nil
        endBurst(&subscriber)
        subscribers[jobId] = subscriber
        return taken
    }

    /// The running total of what each watch has absorbed since the process started — `/jobs`'s
    /// answer to "why does this watch never fire". Memory only, and never persisted.
    func absorbedSinceLaunch() -> [UUID: AbsorbedCounts] {
        subscribers.mapValues(\.absorbedSinceLaunch)
    }

    /// A test-facing read of one subscriber's state. Deliberately the four things that decide
    /// behaviour rather than the whole struct: a test that asserts on the counters should assert
    /// on the summary a fire carried, which is what the row and the card will show.
    struct Snapshot: Equatable {
        let pending: Int
        let held: Int
        let fireOutstanding: Bool
        let burstBegan: Date?
    }

    func snapshot(_ jobId: UUID) -> Snapshot? {
        guard let subscriber = subscribers[jobId] else { return nil }
        return Snapshot(pending: subscriber.pending.count, held: subscriber.heldPaths.count,
                        fireOutstanding: subscriber.fireOutstanding, burstBegan: subscriber.burstBegan)
    }

    private func endBurst(_ subscriber: inout Subscriber) {
        subscriber.pending = []
        subscriber.burstBegan = nil
        subscriber.lastAccepted = nil
        zeroBurstCounters(&subscriber)
    }

    private func zeroBurstCounters(_ subscriber: inout Subscriber) {
        subscriber.coalesced = 0
        subscriber.changed = 0
        subscriber.overflow = 0
        subscriber.noise = 0
        subscriber.ownWrites = 0
    }

    // MARK: The production loop (wired by Task 5)

    /// Sleeps to the next deadline and ticks. Deliberately thin: every decision is in `tick`,
    /// which is why the tests never start this.
    ///
    /// `everyMinute` is the housekeeping the watch layer hangs off the same timer (Task 5 supplies
    /// it); it is called at most once a minute however often the loop wakes for a window.
    func startLoop(everyMinute: @escaping @Sendable () async -> Void) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var lastHousekeeping = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                let at = await self.instant()
                let wait = await self.nextDeadline().map { Swift.max($0.timeIntervalSince(at), 0) } ?? 60
                try? await Task.sleep(for: .seconds(Swift.min(Swift.max(wait, 0.05), 60)))
                if Task.isCancelled { return }
                await self.tick(now: await self.instant())
                let cycled = await self.instant()
                if cycled.timeIntervalSince(lastHousekeeping) >= 60 {
                    lastHousekeeping = cycled
                    await everyMinute()
                }
            }
        }
    }

    func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    private func instant() -> Date { now() }
}
