import Foundation

/// Runs the filesystem half of the job ledger: one `FileWatcher` per enabled `.fsEvent` job.
///
/// The watch list used to be its own array of rules in `UserDefaults`, invisible to the
/// scheduler and to the UI. It is now just a query over the jobs table — `reload()` is the only
/// way watchers change, so creating, disabling, or deleting a watch job is a ledger write plus a
/// reload rather than a second store to keep in step.
actor WatcherManager {
    /// The app-wide manager. Built without a ledger because the store is not open yet when this
    /// initializer runs; `IrisEngine.start()` calls `configure(ledger:)` before its first
    /// `reload()`. Tests construct their own with `init(ledger:)` instead.
    static let shared = WatcherManager(ledger: nil)

    private var ledger: JobLedger?
    private var activeWatchers: [UUID: FileWatcher] = [:]
    private var watchTasks: [UUID: Task<Void, Never>] = [:]
    private var onEventCallback: (@Sendable (Job, [String]) async -> Void)?

    init(ledger: JobLedger?) {
        self.ledger = ledger
    }

    /// Points the manager at the conversation store's ledger. Separate from the initializer so
    /// `shared` can exist before the store does.
    func configure(ledger: JobLedger) {
        self.ledger = ledger
    }

    /// The jobs currently being watched. Used by the tests and by anything that wants to know
    /// whether a reload took effect.
    var activeJobIds: [UUID] { Array(activeWatchers.keys) }

    /// Where a fire goes: the job that was watching and the paths that changed. `IrisEngine.start`
    /// points this straight at `JobRunner.run`, which owns the run, the ledger row and the overlap
    /// guard; the manager itself knows nothing about what a fire turns into.
    func setCallback(_ callback: @escaping @Sendable (Job, [String]) async -> Void) {
        self.onEventCallback = callback
    }

    /// `reload()`, adopting the ledger and the fire callback first if either was never configured.
    /// `shared` is configured in `IrisEngine.start()`, which a subagent, an evaluator or a scenario
    /// run never calls — and the job tools resolve both per call precisely so those engines can
    /// still register a watch. Without the ledger the registration wrote its job and then reloaded
    /// a nil ledger, so the directory was never actually watched; without the callback it is
    /// watched and every fire is dropped on the floor, which is the same inert watch one step
    /// later. An already-configured manager keeps whatever it already has.
    func reload(adoptingIfUnconfigured ledger: JobLedger,
                callback: @escaping @Sendable (Job, [String]) async -> Void) async {
        if self.ledger == nil { self.ledger = ledger }
        if onEventCallback == nil { onEventCallback = callback }
        await reload()
    }

    /// Rebuilds the watch set from the ledger: stop everything, then start one watcher per enabled
    /// `.fsEvent` job. Stopping first — rather than diffing — keeps a job whose path or enabled
    /// flag changed from needing a special case; FSEvents streams are cheap to recreate.
    func reload() async {
        stopAll()
        guard let ledger else { return }
        let jobs: [Job]
        do {
            jobs = try ledger.jobs()
        } catch {
            print("[WatcherManager] could not read jobs: \(error)")
            return
        }
        for job in jobs where job.enabled {
            guard case .fsEvent(let watch) = job.trigger else { continue }
            startWatcher(for: job, path: watch.path)
        }
    }

    /// Stops every watcher and forgets it. Idempotent, so a test can call it in a `defer` after
    /// having already torn down.
    func stopAll() {
        for task in watchTasks.values { task.cancel() }
        watchTasks.removeAll()
        for watcher in activeWatchers.values { watcher.stop() }
        activeWatchers.removeAll()
    }

    private func startWatcher(for job: Job, path: String) {
        if activeWatchers[job.id] != nil { return }

        let watcher = FileWatcher()
        activeWatchers[job.id] = watcher

        watchTasks[job.id] = Task { [weak self] in
            for await eventPaths in watcher.watch(paths: [path]) {
                if Task.isCancelled { return }
                await self?.deliver(job: job, paths: eventPaths)
            }
        }
    }

    /// One fire. Internal rather than private so a test can drive the delivery path without an
    /// FSEvents stream to provoke.
    func deliver(job: Job, paths: [String]) async {
        await onEventCallback?(job, paths)
    }
}
