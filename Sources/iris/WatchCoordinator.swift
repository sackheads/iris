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
/// 2. **An accepted arrival lands in exactly one of `pending`, `heldPaths`, or the outstanding
///    fire; `pending` and `heldPaths` are never both non-empty; and a fire out means no pending
///    burst** (`outstandingFire != nil ⟹ pending == ∅`, `fireOutstanding == (outstandingFire !=
///    nil)`). The fired paths leave `pending` for the fire itself *before* the handler is called,
///    and `heldPaths` takes only what arrives while that fire is out (R-D4-10). So the runner's
///    held re-fire (§3) always finds both; a path saved again during its own run is a new arrival
///    — the run may have read it before the save — and not a repeat of one it holds; and a run
///    that ends before the coordinator has stashed anything is not a state that exists. The fire
///    and the hold may therefore name the same path, which is why every consumer of the two
///    unions them and counts the union once (R-D4-12).
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
        /// Accepted while a fire is outstanding: arrivals since the fire, never the fire's own
        /// paths — those live on `outstandingFire`. Empty whenever no fire is out.
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
        /// The fire the handler is still holding — the paths in flight and the burst's figures —
        /// so a `.skipInFlight` re-ask and the runner's `takeHeldPaths` carry the same paths and
        /// the same arithmetic rather than inventing a new set.
        var outstandingFire: WatchFire?
        /// When a `.skipInFlight` subscriber may ask again (R-D4-2). One ask per ceiling, on the
        /// grid the burst's own ceiling sits on.
        var reAskDue: Date?
        /// Which dispatch the outstanding handler is answering; 0 for none. A handler runs in a
        /// task of its own and may come back long after the subscriber moved on — a
        /// re-registration onto another root, the runner taking the hold, or a pause and a resume
        /// — so the admission is applied only when the fire it answers is still the current one.
        /// The values come from the actor's `nextFireSeq`, never from here: a counter living on
        /// this struct restarts at 0 when `sync` removes and later re-creates the subscriber, and
        /// a handler parked across that pause would then hold a number the new subscriber reissues.
        var fireSeq: UInt64 = 0

        var quiet: TimeInterval { TimeInterval(watch.quietWindowSeconds) }
        var ceiling: TimeInterval { quiet * TimeInterval(WatchCoordinator.ceilingMultiplier) }
    }

    private let ledger: JobLedger
    private let now: @Sendable () -> Date
    private let recentWrites: RecentWrites
    private let fire: WatchFireHandler
    private var subscribers: [UUID: Subscriber] = [:]
    /// Issues every dispatch's identity. On the actor rather than on `Subscriber`, and never reset:
    /// a subscriber can be removed by a pause and re-created by the resume while a handler is still
    /// inside its run, so the identity a dispatch carries has to outlive the struct that issued it.
    /// 0 is never issued, which is what lets an abandoned fire be marked by setting `fireSeq = 0`.
    private var nextFireSeq: UInt64 = 0
    private var loop: Task<Void, Never>?
    /// The loop, parked on its wait. Only ever one: `startLoop` refuses a second loop, and
    /// `waitOrWake` refuses to park a loop that has been cancelled — so a loop stopped between
    /// waits cannot take the slot from the one started after it. The precondition there is what
    /// makes that a fact rather than a convention.
    private var sleeper: CheckedContinuation<Void, Never>?
    /// A wake that arrived while the loop was between waits. Without it, an event accepted in that
    /// window would be answered by the *next* wait rather than by this one, which is the same
    /// late fire the wake exists to prevent.
    private var pendingWake = false

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
                // A handler may still be inside the run this abandons. Clearing the sequence is
                // what stops its admission landing on whatever fires next for the new root.
                existing.fireSeq = 0
                subscribers[job.id] = existing
                continue
            }
            if existing.watch.ignore != watch.ignore { existing.ignore = Self.matcher(for: watch) }
            existing.watch = watch
            // `queue` → `skip` with a queued fire outstanding: the runner will discard the queued
            // fire it was holding, so nobody else would ever take these paths. Release them into a
            // fresh burst rather than lose an edit session to a policy edit.
            //
            // The `lastAdmission == .queued` guard is the *invariant*, not a flag: it is what says
            // the handler has already answered. Releasing while a handler is genuinely inside its
            // run would clear `fireOutstanding` under it and put two fires in flight for one
            // subscriber — the break F2 closes. `sync` runs on every jobs change and is
            // idempotent, so an edit that lands in the gap is applied by the next one. Do not
            // "simplify" this condition away.
            if overlapWas == .queue, job.policy.overlap == .skip, existing.fireOutstanding,
               existing.lastAdmission == .queued {
                // The queued fire's own paths and the hold behind it, cut back to one burst's
                // bound with the cut counted as overflow.
                var released = existing.pending.union(existing.heldPaths)
                if let queued = existing.outstandingFire { released.formUnion(queued.paths) }
                let kept = released.sorted().prefix(Self.maxTrackedPaths)
                existing.pending = Set(kept)
                existing.heldPaths = []
                existing.fireOutstanding = false
                existing.outstandingFire = nil
                existing.lastAdmission = nil
                existing.reAskDue = nil
                existing.fireSeq = 0
                let at = now()
                existing.burstBegan = at
                existing.lastAccepted = at
                existing.coalesced = released.count
                existing.changed = released.count
                existing.overflow = released.count - kept.count
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
    /// (§0.5).
    ///
    /// `root` is the stream's own contract with `WatcherManager` — what the stream was started for
    /// — and is deliberately *not* the coverage test: coverage is decided per path, because one
    /// stream serves several subscribers at different depths. The manager's side of that contract
    /// is that exactly one live stream covers any given path (it re-keys by canonical root and
    /// drops a root nested under another). Two overlapping streams delivering the same path would
    /// hand every subscriber the same event twice and double its `coalesced`; that is the
    /// manager's invariant to keep, not something this method can check.
    ///
    /// Every path is normalised with `IrisPaths.canonicalPath` before anything else (R-D4-5). A
    /// bare `standardizingPath` would not do: its `/private` strip is conditional on the leaf
    /// existing, so a delete event — a path that by definition no longer exists — under `/var`,
    /// `/tmp` or `/etc` arrives spelled `/private/…` and matches neither the canonical root nor
    /// the registry entry the write recorded. The roots and `RecentWrites` use the same helper, so
    /// all three agree on one spelling.
    ///
    /// `root` is carried for diagnostics, not used to route: fan-out is decided per subscriber by
    /// `covers(root:path:)` against each watch's own root, which is the same answer — a stream
    /// on `/r` only ever yields paths under `/r` — and does not trust the tag to be right.
    func deliver(root: String, paths: [String]) async {
        let at = now()
        let canonical = paths.map { IrisPaths.canonicalPath($0) }

        // The registry is another actor, so every answer is gathered before anything is applied:
        // a `sync` or a `tick` interleaving on the await must not find a half-updated subscriber,
        // and a copy written back afterwards would clobber it.
        struct Decision { let id: UUID; let root: String; let path: String; let verdict: Verdict }
        enum Verdict { case noise, ownWrite, accept }
        var decisions: [Decision] = []
        var ownWriteCache: [String: Bool] = [:]
        /// Whether each subscriber already had a burst under way when this batch arrived — a
        /// pending burst, or a hold whose counters the next fire (or `reAsk`'s merged summary)
        /// will carry.
        var burstOpen: [UUID: Bool] = [:]
        /// Which subscribers this batch accepted at least one path for.
        var acceptedIn: Set<UUID> = []

        for (id, subscriber) in subscribers {
            burstOpen[id] = subscriber.burstBegan != nil || subscriber.fireOutstanding
            let watchRoot = subscriber.watch.path
            let expiry = RecentWrites.expiry(quietWindowSeconds: subscriber.watch.quietWindowSeconds)
            for path in canonical {
                guard Self.covers(root: watchRoot, path: path) else { continue }
                if subscriber.ignore(Self.relative(path, under: watchRoot)) {
                    decisions.append(Decision(id: id, root: watchRoot, path: path, verdict: .noise))
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
                if !own { acceptedIn.insert(id) }
                decisions.append(Decision(id: id, root: watchRoot, path: path,
                                          verdict: own ? .ownWrite : .accept))
            }
        }

        for decision in decisions {
            // Re-fetched by id, and re-checked by root: a `sync` landing inside the registry
            // round-trip can re-register this id onto another folder, and a decision taken under
            // the old root must not put a path from it into the new root's burst.
            guard var subscriber = subscribers[decision.id],
                  subscriber.watch.path == decision.root else { continue }
            // R-D4-6: attribution is decided per *batch*, not per position within it. A batch that
            // accepts at least one path — or that arrives while a burst is already open — counts
            // its absorbed events in the burst as well as since launch; a batch that accepts
            // nothing counts them since launch only. One callback's internal ordering is something
            // no user can see, reproduce or reason about, and §6's card ("40 changed, 12 noise
            // absorbed") must not depend on it.
            let inBurst = burstOpen[decision.id] == true || acceptedIn.contains(decision.id)
            switch decision.verdict {
            case .noise:
                subscriber.absorbedSinceLaunch.noise += 1
                if inBurst { subscriber.noise += 1 }
            case .ownWrite:
                subscriber.absorbedSinceLaunch.ownWrites += 1
                if inBurst { subscriber.ownWrites += 1 }
            case .accept:
                subscriber.coalesced += 1
                if subscriber.fireOutstanding {
                    // The burst is over; these belong to whatever takes the hold, and the timers
                    // are not restarted until the run's handler returns. A path the fire itself
                    // carries is a new arrival here, not a repeat (R-D4-10): the run may have read
                    // it before this save.
                    Self.insert(decision.path, held: true, into: &subscriber)
                } else {
                    Self.insert(decision.path, held: false, into: &subscriber)
                    subscriber.burstBegan = subscriber.burstBegan ?? at
                    subscriber.lastAccepted = at
                }
            }
            subscribers[decision.id] = subscriber
        }

        // §2: the loop sleeps to the earliest deadline *or until woken by an accepted event*. An
        // accept is what brings a deadline forward (the other source of a new deadline is an
        // admission, which `apply` wakes for), so it is what wakes here; a batch of nothing but
        // noise leaves the loop where it was. A wake for an accept that only joined a hold (no
        // deadline of its own yet) costs one no-op `tick`, which is cheaper than the arithmetic
        // needed to be sure it did not.
        if !acceptedIn.isEmpty { signalWake() }
    }

    /// Lexical, on canonical forms, and never a `stat`: FSEvents reports a path under the root it
    /// was given, and a delete names a leaf that is already gone.
    ///
    /// Case-insensitive (R-D4-7), because `realpath` is not case-normalising: measured on APFS,
    /// `/tmp/CaseProbe` resolves to `/private/tmp/CaseProbe` and keeps the *caller's* spelling. So
    /// a root registered as `~/Documents/NOTES` against a directory spelled `Notes` is stored with
    /// the user's casing while FSEvents reports the disk's, and a case-sensitive `hasPrefix` would
    /// have every event miss — a watch that silently never fires, with `/jobs` showing zero
    /// absorbed as well as zero fired, so even §0.7's diagnostic says nothing. The stored root
    /// keeps its own spelling: the canonical form is what the migration wrote and what
    /// `WatcherManager` keys streams by, and case-folding it here would make those two disagree.
    ///
    /// The cost, on a case-sensitive volume: two directories in one parent differing only by case
    /// are one watch as far as this test is concerned, so a watch on `src/` also absorbs events
    /// under a sibling `SRC/`. That is the rarer configuration by a wide margin, and it
    /// over-delivers (a run with paths it did not ask for) where the alternative under-delivers to
    /// nothing at all.
    private static func covers(root: String, path: String) -> Bool {
        if path.compare(root, options: .caseInsensitive) == .orderedSame { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.count >= prefix.count else { return false }
        return path.prefix(prefix.count).compare(prefix, options: .caseInsensitive) == .orderedSame
    }

    /// The path relative to its root, in the *event's* spelling — the root's casing may differ
    /// (see `covers`), and the set, the prompt and the run row should all carry the name the
    /// filesystem reported.
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
        // The burst's paths leave `pending` for the fire itself. `heldPaths` is empty here —
        // every exit from a fire clears it — and from now until the handler returns it takes only
        // what arrives meanwhile (R-D4-10).
        let paths = subscriber.pending.sorted()
        subscriber.pending = []
        subscriber.fireOutstanding = true
        let summary = WatchSummary(delivered: Swift.min(paths.count, Self.maxDeliveredPaths),
                                   changed: subscriber.changed, overflow: subscriber.overflow,
                                   coalesced: subscriber.coalesced, noise: subscriber.noise,
                                   ownWrites: subscriber.ownWrites, ceilingFired: ceilingFired,
                                   pathsWithheld: false)
        let outstanding = WatchFire(paths: paths, summary: summary)
        subscriber.outstandingFire = outstanding
        subscriber.lastAdmission = nil
        nextFireSeq &+= 1
        subscriber.fireSeq = nextFireSeq
        let seq = nextFireSeq
        // One ask per ceiling if the runner turns this down as a `skip` overlap (R-D4-2): the grid
        // is the burst's own ceiling, so a watch that fired on its window still waits the full
        // ceiling from the burst before it costs the ledger two more sums.
        let burstCeiling = (subscriber.burstBegan ?? at).addingTimeInterval(subscriber.ceiling)
        subscriber.reAskDue = burstCeiling > at ? burstCeiling : at.addingTimeInterval(subscriber.ceiling)
        zeroBurstCounters(&subscriber)
        subscriber.burstBegan = nil
        subscriber.lastAccepted = nil
        subscribers[id] = subscriber

        dispatch(id, job: fresh, fire: outstanding, seq: seq)
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
        // The same burst, plus whatever arrived while the run lasted: the offer takes over the
        // hold, so a `.run` on it spends both and the hold starts again from empty. Keeping the
        // previous summary verbatim would under-report a hold that grew — and those counters have
        // nowhere else to be reported, because the burst that would have carried them ended at
        // the first ask. The union is cut back to the bound, and what it cuts is counted as
        // overflow, so a hold that is re-asked for the length of a long run cannot grow past it.
        //
        // `changed` is the merged set plus what each segment had already overflowed (R-D4-12):
        // a file saved before the fire and again during it is one changed file named once, not
        // two, and `changed − overflow == paths.count` holds here as it does for a single burst.
        // Overflowed paths were never stored, so they cannot be de-duplicated and count once
        // each, as they always did. `coalesced` stays the event count.
        let owed = Set(previous.paths).union(subscriber.heldPaths).sorted()
        let paths = Array(owed.prefix(Self.maxTrackedPaths))
        subscriber.heldPaths = []
        let summary = WatchSummary(
            delivered: Swift.min(paths.count, Self.maxDeliveredPaths),
            changed: owed.count + previous.summary.overflow + subscriber.overflow,
            overflow: previous.summary.overflow + subscriber.overflow + (owed.count - paths.count),
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
        nextFireSeq &+= 1
        subscriber.fireSeq = nextFireSeq
        let seq = nextFireSeq
        let job = subscriber.job
        subscribers[id] = subscriber
        dispatch(id, job: job, fire: offer, seq: seq)
    }

    /// Step 2's last line: the run goes out in a task of its own, and the loop carries on. The
    /// admission comes back through `apply`.
    private func dispatch(_ id: UUID, job: Job, fire offer: WatchFire, seq: UInt64) {
        let handler = fire
        Task { [self] in
            let admission = await handler(job, offer)
            // No `await`: this task inherits the actor's isolation, so only the handler suspends.
            apply(admission, to: id, seq: seq)
        }
    }

    /// Step 3: what the runner said, applied to the hold.
    private func apply(_ admission: JobRunner.Admission?, to id: UUID, seq: UInt64) {
        // The fire this answers must still be the subscriber's current one. Three windows make the
        // id alone insufficient: a `sync` that re-registered the job onto another root while the
        // handler was inside its run, a `takeHeldPaths` that beat the handler's return, and a
        // pause that removed the subscriber followed by a resume that re-created it. In each, a
        // stale `.run` would end a *newer* fire under its handler's feet, clear that fire's
        // `fireOutstanding` and start a burst from its hold — the same paths run twice, and the
        // "at most one fire outstanding" invariant broken by the one code path that exists to
        // keep it.
        guard var subscriber = subscribers[id], subscriber.fireSeq == seq else { return }
        guard let admission else {
            // `nil` has two meanings, and only one of them is "the job is gone". The runner
            // answers it for a row it could not read as well as for one that is not there, and
            // the handler answers it when the runner itself has gone. Re-read before dropping
            // (R-D4-11): a row that is still here makes this a refusal, with the fail direction §7
            // gives every other read failure during a fire — the burst is dropped, a row says why,
            // the subscriber stays and the next burst tries again. Only a row that is genuinely
            // missing takes the subscriber with it, which `sync` would do on the next ledger
            // change anyway.
            let gone: Bool
            do { gone = try ledger.job(id: id) == nil } catch { gone = false }
            if gone {
                subscribers[id] = nil
                return
            }
            do {
                try JobRunner.recordStillborn(job: subscriber.job, ledger: ledger,
                                              reason: "watch fire dropped: the runner could not read the job",
                                              triggerKind: Trigger.fsEventKind, now: now(), note: nil)
            } catch {
                print("[WatchCoordinator] could not record the dropped fire of \(subscriber.job.name): \(error)")
            }
            dropHold(&subscriber)
            subscribers[id] = subscriber
            return
        }
        subscriber.lastAdmission = admission
        switch admission {
        case .run:
            // The handler returned, so the run is over and the fire's paths are spent. The hold
            // is everything accepted since the fire — a fired path saved again during its own run
            // included (R-D4-10) — and nothing is subtracted from it.
            subscriber.fireOutstanding = false
            subscriber.outstandingFire = nil
            subscriber.reAskDue = nil
            if subscriber.heldPaths.isEmpty {
                // Nothing arrived, but noise and own writes absorbed while the fire was out have
                // bumped the burst counters (R-D4-6). Those figures describe a burst that is over;
                // leaving them would have the next burst's summary report them a second time.
                zeroBurstCounters(&subscriber)
            } else {
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
            dropHold(&subscriber)
        }
        subscribers[id] = subscriber
        // An admission can leave a deadline behind — the new burst's window, or a `.skipInFlight`
        // re-ask — with the loop parked on the 60 s wait it took when the fire went out and
        // `nextDeadline()` had nothing to offer. Seen on screen: a file saved during its own run
        // ran again a minute later, and past the ceiling, because nothing here woke the loop when
        // the run returned. The wake costs one `tick` when there is nothing to do.
        if !subscriber.pending.isEmpty || admission == .skipInFlight { signalWake() }
    }

    /// A refusal's exit from a fire: the fire, its hold and the burst behind it are all dropped.
    private func dropHold(_ subscriber: inout Subscriber) {
        subscriber.heldPaths = []
        subscriber.fireOutstanding = false
        subscriber.outstandingFire = nil
        subscriber.reAskDue = nil
        endBurst(&subscriber)
    }

    /// What the runner's held re-fire takes (§3): everything this subscriber is still owed — the
    /// outstanding fire's own paths, the hold that grew behind it, and any pending burst — in one
    /// sorted list, and the end of the outstanding fire.
    ///
    /// The union rather than just the fire, because a `queue`d run's re-fire is the only thing
    /// that will take any of the three — anything accepted since the fire would otherwise wait
    /// for a window that no longer has a burst behind it. A fired path saved again during the
    /// wait is in the fire and in the hold, and is named once — and counted once in `changed`,
    /// which is the merged set plus both segments' overflow, so `changed − overflow` is the
    /// number of paths handed over (R-D4-12); `coalesced` keeps both events. The burst counters
    /// go with the paths: they describe what is being taken, and leaving them would have the
    /// next fire report this burst twice.
    ///
    /// The summary is the outstanding fire's plus everything accumulated since (R-D4-9), the same
    /// arithmetic `reAsk` does and for a stronger reason: an admission of `.queued` writes no row,
    /// so the queued fire's own counts have never been reported anywhere and this re-fire's row is
    /// the only one that will ever carry them. (A `.run` admission does not come through here with
    /// a fire outstanding: `apply` clears `outstandingFire` when the handler returns, and what
    /// stops a second fire for those paths is `tick` skipping `fireOutstanding` until it does.)
    /// `delivered` and `pathsWithheld` stay at zero: only the runner's prompt build knows how many
    /// paths got past the cap and the guard.
    ///
    /// `nil` — no subscriber, or no fire outstanding — rather than a summary of zeroes: there is a
    /// difference between "this burst saw nothing" and "nobody counted", and only the second one
    /// belongs in the row as a null column. A watch whose job was deleted mid-run, and a held
    /// re-fire for a watch the coordinator never fired, are both the second.
    func takeHeldPaths(_ jobId: UUID) -> (paths: [String], summary: WatchSummary?) {
        guard var subscriber = subscribers[jobId] else { return ([], nil) }
        var owed = subscriber.heldPaths.union(subscriber.pending)
        if let outstanding = subscriber.outstandingFire { owed.formUnion(outstanding.paths) }
        let taken = owed.sorted()
        let counted = subscriber
        let summary = subscriber.outstandingFire.map { outstanding in
            WatchSummary(delivered: 0,
                         changed: taken.count + outstanding.summary.overflow + counted.overflow,
                         overflow: outstanding.summary.overflow + counted.overflow,
                         coalesced: outstanding.summary.coalesced + counted.coalesced,
                         noise: outstanding.summary.noise + counted.noise,
                         ownWrites: outstanding.summary.ownWrites + counted.ownWrites,
                         ceilingFired: outstanding.summary.ceilingFired,
                         pathsWithheld: false)
        }
        subscriber.heldPaths = []
        subscriber.pending = []
        subscriber.fireOutstanding = false
        subscriber.outstandingFire = nil
        subscriber.lastAdmission = nil
        subscriber.reAskDue = nil
        // The runner owns these paths now. If the handler for the fire they came from has not
        // returned yet, its admission must not land on the burst that starts after this.
        subscriber.fireSeq = 0
        endBurst(&subscriber)
        subscribers[jobId] = subscriber
        return (taken, summary)
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
        /// Arrivals since the fire, not the fire's own paths — those are `outstanding`.
        let held: Int
        /// The paths on the fire the handler is still holding; 0 when none is.
        let outstanding: Int
        let fireOutstanding: Bool
        let burstBegan: Date?
    }

    func snapshot(_ jobId: UUID) -> Snapshot? {
        guard let subscriber = subscribers[jobId] else { return nil }
        return Snapshot(pending: subscriber.pending.count, held: subscriber.heldPaths.count,
                        outstanding: subscriber.outstandingFire?.paths.count ?? 0,
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

    // MARK: The production loop

    /// Sleeps to the next deadline and ticks. Deliberately thin: every decision is in `tick`,
    /// which is why the unit tests call that instead.
    ///
    /// `everyMinute` is the housekeeping the watch layer hangs off the same timer — in the app,
    /// the periodic re-stat of every watch root (§7). It is called at most once a minute however
    /// often the loop wakes for a window.
    ///
    /// The wait is `min(nextDeadline(), now + 60 s)` **or until a wake** (§2) — from an accepted
    /// event, or from an admission that left a deadline behind. Both halves are needed: the
    /// deadline is read once, before the wait, so without the wake the first save after a quiet
    /// period would sit through the rest of a 60 s sleep and its 3 s window would fire nearly a
    /// minute late (and a save during a run would do the same when the run returned); and without
    /// the ceiling of 60 s a clock the process cannot see moving (a laptop waking from sleep) would
    /// never be noticed.
    ///
    /// `sleep` is injected so a test can drive this loop on its own clock rather than in real
    /// seconds — a wake is only observable from the loop, never from `tick`.
    func startLoop(everyMinute: @escaping @Sendable () async -> Void,
                   sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                       try? await Task.sleep(for: .seconds(seconds))
                   }) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var lastHousekeeping = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                let at = await self.instant()
                let wait = await self.nextDeadline().map { Swift.max($0.timeIntervalSince(at), 0) } ?? 60
                await self.waitOrWake(Swift.min(Swift.max(wait, 0.05), 60), sleeping: sleep)
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
        // A cancelled task parked on a continuation stays parked: nothing resumes it and the loop
        // never returns. Releasing it here is what makes `stopLoop` actually stop.
        resumeSleeper()
    }

    /// The loop's one wait: whichever comes first, the deadline or a wake.
    ///
    /// A timer task races a continuation rather than a task group racing two children, because the
    /// wake side parks indefinitely — a group would have to cancel it and then wait for it, which
    /// is the deadlock this avoids. `pendingWake` closes the window where the wake arrives (or the
    /// timer fires, for a zero-length wait) before the loop has parked.
    private func waitOrWake(_ seconds: TimeInterval,
                            sleeping sleep: @escaping @Sendable (TimeInterval) async -> Void) async {
        let timer = Task { [weak self] in
            await sleep(seconds)
            if Task.isCancelled { return }
            await self?.signalWake()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // A loop cancelled between waits does not park: nothing but its timer would resume
            // it, and a loop started in the meantime would find the slot taken — or take it
            // from this one, leaking this continuation. Resumed at once, it sees the
            // cancellation on the line after the wait and returns.
            if Task.isCancelled {
                continuation.resume()
                return
            }
            precondition(sleeper == nil, "two loops parked on one WatchCoordinator")
            if pendingWake {
                pendingWake = false
                continuation.resume()
            } else {
                sleeper = continuation
            }
        }
        timer.cancel()
    }

    /// Wakes the loop, or remembers that it should not park when it next tries to. Called for a
    /// batch that accepted at least one path, for an admission that left a deadline behind (a
    /// burst begun from a run's hold, or a `.skipInFlight` re-ask) — the two things that can move
    /// the earliest deadline earlier — and by the timer when the wait runs out.
    private func signalWake() {
        if sleeper != nil { resumeSleeper() } else { pendingWake = true }
    }

    private func resumeSleeper() {
        guard let sleeper else { return }
        self.sleeper = nil
        sleeper.resume()
    }

    private func instant() -> Date { now() }
}
