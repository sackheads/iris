import Foundation

/// The filesystem half of a watch: one FSEvents stream per distinct canonical root, and nothing
/// else (#187 deliverable 4, spec §7).
///
/// The split with `WatchCoordinator` is the whole design. Streams live here because they are a
/// per-directory resource; windows, held paths and counts live there because they are per-job and
/// must survive a stream being started or stopped for a reason that has nothing to do with the
/// burst in progress. So this actor knows about *roots* and never about jobs' timing: a batch goes
/// out tagged with the root its stream was started for, and the coordinator fans it out to the
/// subscribers that root covers.
///
/// `sync(with:)` is a diff, not a rebuild. The reload it replaced stopped every stream and started
/// them again on any change at all, which threw away each stream's place in the FSEvents history
/// (and, before the coordinator existed, any timer the manager held) every time an unrelated job's
/// cadence moved.
actor WatcherManager {
    /// One stream, as the manager consumes it: a batch of paths at a time, and a way to stop.
    /// Injectable so tests drive the delivery and failure paths without an FSEvents stream to
    /// provoke (invariant 7).
    struct WatchStream: Sendable {
        let events: AsyncStream<[String]>
        let stop: @Sendable () -> Void
    }

    typealias StreamFactory = @Sendable (_ root: String) -> WatchStream

    /// The app-wide manager. Built without a ledger because the store is not open yet when this
    /// initializer runs; `IrisEngine.start()` calls `configure(ledger:)` before its first `sync`.
    /// Tests construct their own with `init(ledger:streams:fileExists:)` instead.
    static let shared = WatcherManager(ledger: nil)

    /// The production factory: one `FileWatcher` per root. The `stop` closure retains the watcher,
    /// which is what keeps the stream alive for as long as the manager wants it — nothing else
    /// holds one.
    static let fsEventsStream: StreamFactory = { root in
        let watcher = FileWatcher()
        return WatchStream(events: watcher.watch(paths: [root]), stop: { watcher.stop() })
    }

    /// A live stream: the spelling of the root it was opened on, how to stop it, and the task
    /// forwarding its batches.
    private struct Live {
        let root: String
        let stop: @Sendable () -> Void
        let task: Task<Void, Never>
        /// Which generation of the stream on this key this is. A stream that ends by itself
        /// reports through `streamEnded` from its own task, and a `sync` can close it and open
        /// a successor on the same key before that report reaches the actor; the report names
        /// this token so it can tell its own entry from the successor's.
        let token: UUID
    }

    private var ledger: JobLedger?
    private let streams: StreamFactory
    private let fileExists: @Sendable (String) -> Bool
    /// Keyed by the case-folded root (R-D4-8), holding the spelling the stream was opened on.
    private var live: [String: Live] = [:]
    /// The jobs the last `sync` was given — the fallback answer to "who was this stream serving"
    /// for a manager with no ledger.
    private var syncedJobs: [Job] = []
    /// The keys of streams that ended unprompted and whose subscribers are still being reported.
    /// A `sync` that re-enters during that report — every pause fires the hook — finds the root
    /// still wanted by the subscribers not yet paused and would open the stream again, for
    /// FSEvents to refuse again, once per subscriber. Held only for the length of `streamEnded`,
    /// so `/jobs resume` still gets its retry.
    private var refused: Set<String> = []
    private var batchHandler: (@Sendable (_ root: String, _ paths: [String]) async -> Void)?
    private var unavailableHandler: (@Sendable (Job, String) async -> Void)?

    init(ledger: JobLedger?,
         streams: @escaping StreamFactory = WatcherManager.fsEventsStream,
         fileExists: @escaping @Sendable (String) -> Bool = {
             FileManager.default.fileExists(atPath: $0)
         }) {
        self.ledger = ledger
        self.streams = streams
        self.fileExists = fileExists
    }

    /// Points the manager at the conversation store's ledger. Separate from the initializer so
    /// `shared` can exist before the store does.
    func configure(ledger: JobLedger) {
        self.ledger = ledger
    }

    /// Where a batch goes: the root of the stream it arrived on, and the paths FSEvents named.
    /// `IrisEngine.start()` points this at `WatchCoordinator.deliver(root:paths:)`.
    func setBatchHandler(_ handler: @escaping @Sendable (_ root: String, _ paths: [String]) async -> Void) {
        batchHandler = handler
    }

    /// Where a watch whose directory is gone goes: `JobRunner.pauseUnavailable` in the app. A
    /// pause, not a silent stop — a watch that looks live in `/jobs` and never fires is the
    /// failure nobody notices (§7).
    func setUnavailableHandler(_ handler: @escaping @Sendable (Job, String) async -> Void) {
        unavailableHandler = handler
    }

    /// The roots with a live stream, in the spelling each stream was opened on. Sorted, so a test
    /// and a diagnostic read the same both times.
    var activeRoots: [String] { live.values.map(\.root).sorted() }

    /// The generation token of the live stream on `root`, for the test that delivers a stale end
    /// by hand; `nil` when no stream is open there.
    func streamToken(root: String) -> UUID? { live[root.lowercased()]?.token }

    /// The diff (§7): pause what has vanished, open a stream for each new root, stop the stream
    /// for each root nobody is left subscribed to, and touch nothing else.
    ///
    /// Called from the ledger's `onJobsChanged` hook — immediately *after* `WatchCoordinator.sync`,
    /// so a batch can never arrive for a subscriber that does not exist yet — and once a minute
    /// from the coordinator's loop, which is what makes the vanished-root check periodic rather
    /// than only a launch check.
    ///
    /// The stream diff is applied before anything is reported, and deliberately: reporting awaits
    /// the unavailable handler, whose pause is a `setPaused` that re-enters the hook and calls
    /// this method again. The diff itself is atomic — nothing between `syncedJobs = jobs` and the
    /// last `close` suspends, so two syncs cannot interleave their diffs, double-start a stream or
    /// tear the table — but which of two syncs lands last is not this actor's to decide; the
    /// engine queues them so the later one reads the later table, and the minute sync is the
    /// backstop. Reporting last keeps the streams right before anyone is told about them.
    ///
    /// Each vanished job's row is re-read before it is reported: by the time the loop reaches
    /// the second of two, the re-entrant sync the first pause set off may already have paused it,
    /// and one deletion is one card (§7).
    func sync(with jobs: [Job]) async {
        syncedJobs = jobs
        let gone = Self.vanished(in: jobs, fileExists: fileExists)
        let goneIds = Set(gone.map(\.id))
        let wanted = Self.roots(for: jobs.filter { !goneIds.contains($0.id) })

        var wantedKeys: Set<String> = []
        for root in wanted.sorted() {
            let key = root.lowercased()
            wantedKeys.insert(key)
            guard live[key] == nil, !refused.contains(key) else { continue }
            open(root: root, key: key)
        }
        for key in Array(live.keys) where !wantedKeys.contains(key) { close(key) }

        for job in gone {
            guard case .fsEvent(let watch) = job.trigger, stillWatching(job) else { continue }
            await unavailableHandler?(job, Self.unavailableReason(watch.path))
        }
    }

    /// Whether a job is still something to report, as of now rather than as of the list this
    /// pass was given: the row re-read from the ledger when there is one, otherwise the list the
    /// latest (possibly re-entrant) `sync` left behind. A row that cannot be read is reported
    /// anyway — the runner re-reads it too, and its pause is idempotent.
    private func stillWatching(_ job: Job) -> Bool {
        let row: Job?
        if let ledger {
            do { row = try ledger.job(id: job.id) } catch { return true }
        } else {
            row = syncedJobs.first { $0.id == job.id }
        }
        guard let row else { return false }
        return row.enabled && row.pausedReason == nil
    }

    /// The roots that need a stream: every enabled, unpaused `.fsEvent` job's root, with nested
    /// roots collapsed onto their ancestor (§0.5 — an FSEvents stream is recursive and already
    /// carries per-file events, so a second stream inside one would deliver every nested path
    /// twice).
    ///
    /// Distinct is decided case-insensitively and the first spelling seen wins (R-D4-8), because
    /// `realpath` is not case-normalising: two jobs registered as `~/Documents/NOTES` and
    /// `~/Documents/Notes` are one directory on a case-insensitive volume (the default on APFS)
    /// and must be one stream, or each subscriber sees every event twice. The cost, on a
    /// case-sensitive volume: two genuinely distinct directories differing only by case share one
    /// stream, and each of their subscribers is offered the other's events — which the
    /// coordinator's own coverage test, case-insensitive for the same reason, then accepts.
    static func roots(for jobs: [Job]) -> Set<String> {
        var spelling: [String: String] = [:]
        var order: [String] = []
        for job in jobs {
            guard job.enabled, job.pausedReason == nil,
                  case .fsEvent(let watch) = job.trigger else { continue }
            let key = watch.path.lowercased()
            if spelling[key] == nil {
                spelling[key] = watch.path
                order.append(key)
            }
        }
        var kept: Set<String> = []
        for key in order {
            let nested = order.contains { other in other != key && Self.contains(other, key) }
            if !nested, let path = spelling[key] { kept.insert(path) }
        }
        return kept
    }

    /// Whether `ancestor` is a proper ancestor of `path`. Both are already case-folded by
    /// `roots(for:)`; the comparison is lexical, on canonical forms, for the reason the
    /// coordinator's `covers` is.
    private static func contains(_ ancestor: String, _ path: String) -> Bool {
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// The watches whose directory is not there: deleted, renamed or unmounted. FSEvents does not
    /// stop a stream whose root disappears — it keeps running and delivers nothing further — so
    /// this stat is the only thing that ever notices (§7), and it runs on every job change and
    /// once a minute besides. It runs on the actor, synchronously, once per watch: nothing for a
    /// local folder, but a root on a stalled network mount blocks the actor — and every batch
    /// behind it — for the mount's timeout, which is the price of the twentieth watch.
    static func vanished(in jobs: [Job], fileExists: (String) -> Bool) -> [Job] {
        jobs.filter { job in
            guard job.enabled, job.pausedReason == nil,
                  case .fsEvent(let watch) = job.trigger else { return false }
            return !fileExists(watch.path)
        }
    }

    /// One wording for both ways a root can be unusable — gone when it was stat'd, and refused by
    /// FSEvents when the stream was created — because they are the same thing to the person
    /// reading `/jobs`.
    static func unavailableReason(_ path: String) -> String { "watch path unavailable: \(path)" }

    /// Stops every stream and forgets it. Idempotent, so a test can call it in a `defer` after
    /// having already torn down.
    func stopAll() {
        for key in Array(live.keys) { close(key) }
    }

    private func open(root: String, key: String) {
        let stream = streams(root)
        let token = UUID()
        let task = Task { [weak self] in
            for await paths in stream.events {
                if Task.isCancelled { return }
                await self?.forward(root: root, paths: paths)
            }
            // The stream ended by itself. `close` cancels before it stops, so the only way here is
            // a stream FSEvents refused to create (`FileWatcher` finishes the stream immediately)
            // or one it tore down under us.
            if Task.isCancelled { return }
            await self?.streamEnded(root: root, key: key, token: token)
        }
        live[key] = Live(root: root, stop: stream.stop, task: task, token: token)
    }

    private func close(_ key: String) {
        guard let entry = live.removeValue(forKey: key) else { return }
        // Cancel first: stopping finishes the stream, and the task must already know that ending
        // is what was asked for rather than a stream that died.
        entry.task.cancel()
        entry.stop()
    }

    private func forward(root: String, paths: [String]) async {
        await batchHandler?(root, paths)
    }

    /// A stream that ended unprompted is a dead stream: every job it was serving — the one on its
    /// own root and any nested underneath it — is paused, naming its own root rather than the
    /// stream's, because the person registered that path and that is what `/jobs` shows.
    ///
    /// The entry is dropped rather than left in place: a dead stream that still looks live would
    /// stop the next `sync` from ever trying again, and `/jobs resume` is meant to retry. For the
    /// length of the report, though, the key sits in `refused`, so the syncs each pause sets off
    /// do not reopen a stream FSEvents has just declined — one refusal, one report.
    ///
    /// Matched by `token`, not by the key alone: the end is reported from the stream's own task,
    /// and two `sync`s can close that stream and open its successor on the same key before the
    /// report gets the actor. Dropping the successor's entry on the predecessor's word would
    /// leave a stream nobody can stop forwarding every batch beside the one the next `sync`
    /// opens — every subscriber on the root seeing each event twice until relaunch. Internal
    /// rather than private only so the test can deliver that stale end by hand: `close` cancels
    /// the task before it stops the stream, so the window cannot be produced through `sync`.
    func streamEnded(root: String, key: String, token: UUID) async {
        guard live[key]?.token == token else { return }
        live[key] = nil
        refused.insert(key)
        defer { refused.remove(key) }
        let folded = root.lowercased()
        for job in currentJobs() {
            guard job.enabled, job.pausedReason == nil,
                  case .fsEvent(let watch) = job.trigger else { continue }
            let path = watch.path.lowercased()
            guard path == folded || Self.contains(folded, path), stillWatching(job) else { continue }
            await unavailableHandler?(job, Self.unavailableReason(watch.path))
        }
    }

    /// Who a stream is serving, as of now. The ledger when there is one — a stream can die at any
    /// moment, and the jobs that moment's pause should name are the ones in the table, not the
    /// ones the last `sync` happened to see. A manager that was never configured (an engine that
    /// never started) falls back to that snapshot.
    private func currentJobs() -> [Job] {
        if let ledger, let jobs = try? ledger.jobs() { return jobs }
        return syncedJobs
    }
}
