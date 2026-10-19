import CIrisSignals
import Darwin
import Foundation

/// #463 decision 16: the CLI's own SIGINT, SIGTERM and SIGHUP.
///
/// - A do-nothing `sigaction` handler, not `SIG_IGN`: a caught disposition resets to the default
///   across `exec`, so a child cannot inherit an ignore from it whatever spawned it. Iris's own
///   spawners would reset one anyway: `ProcessGroupRunner` and `BlockingSpawn` pass
///   `POSIX_SPAWN_SETSIGDEF`, and Foundation's `Process` was measured to reset it as well.
/// - `SA_RESTART`, so blocking calls on whichever thread takes the signal do not fail with `EINTR`
///   mid-stop.
/// - A `DispatchSource` per signal, on the CLI's own serial queue rather than `.main`: a long
///   main-actor stretch (Vibecop loading ggml) must not delay the stop. Each source is resumed
///   before its handler replaces the default, so no signal lands in the gap and is swallowed.
/// - An inherited ignore on SIGHUP or SIGINT is kept (plan note 16). `nohup iris --run-job x &`
///   sets SIGHUP ignored so a closed terminal does not end the run, and a non-interactive shell
///   starts `&` jobs with SIGINT ignored. SIGTERM is always caught.
enum CLISignals {
    static let stopping: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    static let keepsInheritedIgnore: Set<Int32> = [SIGINT, SIGHUP]

    /// SIGINT goes to its default once the `count`th stopping signal has been delivered (#510). A
    /// source hears a signal when it is posted, which can be before the kernel delivers it to a
    /// thread, so resetting as soon as the source heard it let the very signal that asked for
    /// exit-now meet the default on delivery and end the CLI before the deletes and the vacate.
    /// The count is kept by the handler, in C (`CIrisSignals`). Two signals posted before either is
    /// delivered are delivered once, so the reset then waits for one more, which errs toward
    /// running the cleanup.
    static func resetInterrupt(onceDelivered count: Int) {
        iris_reset_interrupt_once_delivered(count)
    }

    /// How many stopping signals have been delivered to the handler, as opposed to heard by a
    /// source (#636). For tests.
    static var deliveries: Int { iris_stop_signal_deliveries() }

    final class Installation: @unchecked Sendable {
        /// The signals this installation caught: `stopping` minus any inherited ignore it kept.
        let installed: [Int32]
        fileprivate let sources: [DispatchSourceSignal]
        fileprivate let previous: [(Int32, sigaction)]

        fileprivate init(installed: [Int32], sources: [DispatchSourceSignal], previous: [(Int32, sigaction)]) {
            self.installed = installed
            self.sources = sources
            self.previous = previous
        }

        /// Puts the old dispositions back. For tests; the CLI keeps its handlers until it exits.
        func uninstall() {
            sources.forEach { $0.cancel() }
            for (signal, old) in previous {
                var action = old
                sigaction(signal, &action, nil)
            }
        }
    }

    static func install(_ signals: [Int32] = stopping,
                        queue: DispatchQueue = DispatchQueue(label: "iris.cli.signals"),
                        onSignal: @escaping @Sendable (Int32) -> Void) -> Installation {
        var installed: [Int32] = []
        var sources: [DispatchSourceSignal] = []
        var previous: [(Int32, sigaction)] = []
        for signal in signals {
            var old = sigaction()
            sigaction(signal, nil, &old)
            let ignored = unsafeBitCast(old.__sigaction_u, to: UInt.self) == 1   // SIG_IGN
            if ignored, keepsInheritedIgnore.contains(signal) { continue }
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            // A signal source coalesces: two quick SIGINTs can arrive as one event whose `data`
            // is 2, and the second must still mean "exit now".
            source.setEventHandler { for _ in 0..<max(1, Int(source.data)) { onSignal(signal) } }
            source.resume()
            var action = sigaction()
            action.__sigaction_u.__sa_handler = iris_stop_signal_handler
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
            previous.append((signal, old))
            sources.append(source)
            installed.append(signal)
        }
        return Installation(installed: installed, sources: sources, previous: previous)
    }
}

/// What the CLI does with a stopping signal.
/// - The first stops the run cleanly (`RunStop`): on the signal queue, it cancels the turn and
///   SIGTERMs the host groups, and the run then closes itself as stopped. With no run armed yet
///   (before admission, or a dry run), it exits now instead, with 2.
/// - A second means exit now, with `128 + signal`.
/// - Exiting now first arranges for SIGINT to go to its default once the signal that asked for it
///   has been delivered (#510), so a third Ctrl-C ends the CLI at once while the deletes run. It
///   then cancels the run's turn, so a runner queued but not yet spawned (in
///   neither registry) never spawns, and only then SIGKILLs every registered host group, deletes
///   every container this process made (bounded at 5 s, in parallel, plan note 15), flushes
///   stdout and stderr, empties the lock's payload and `_exit`s, in that order: the payload is
///   emptied last, as on the CLI's ordinary exit. All of it on the signal queue, nothing on the
///   pool (#372). The flush, the vacate and the `_exit` are `exit(code:)`, which the ordinary exit
///   shares: whichever reaches it first exits, with its own code.
/// - After a clean stop, `settle()` runs before `_exit`: it closes the host registry, so no new
///   group starts, then waits up to 3 s for the host groups to drain
///   (their SIGKILL rung is 2 s after the SIGTERM), a SIGKILL for any that did not, and a delete
///   for any container the bounded teardown left behind.
final class CLIStop: @unchecked Sendable {
    let run: RunStop

    private let closeGroups: @Sendable () -> Void
    private let drainGroups: @Sendable () -> Bool
    private let killGroups: @Sendable () -> Void
    private let deleteContainers: @Sendable () -> Void
    private let resetInterrupt: @Sendable (Int) -> Void
    private let flush: @Sendable () -> Void
    private let vacate: @Sendable () -> Void
    private let exitNow: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var received = 0
    /// Set by the first `exit(code:)`: the process has one exit, and one exit code.
    private var exiting = false

    /// Five seams default to the process-wide `.shared` registries, which only the CLI may use:
    /// `terminateGroups`, `closeGroups`, `drainGroups` and `killGroups` (`LiveProcessGroups`) and
    /// `deleteContainers` (`LiveContainerNames`). A test passes its own closure for each of them
    /// that its path can reach, over a registry of its own, or it closes or kills the registry of
    /// every suite running beside it (invariant 7). `resetInterrupt`, `flush` and `exitNow` default
    /// to the real process-wide actions; a test that reaches the exit path replaces them too.
    init(grace: TimeInterval = 15, teardown: TimeInterval = 5,
         terminateGroups: @escaping @Sendable () -> Void = { LiveProcessGroups.shared.terminateAll() },
         closeGroups: @escaping @Sendable () -> Void = { _ = LiveProcessGroups.shared.closeAndSnapshot() },
         drainGroups: @escaping @Sendable () -> Bool = { LiveProcessGroups.shared.waitUntilEmpty(within: 3) },
         killGroups: @escaping @Sendable () -> Void = { LiveProcessGroups.shared.killAll() },
         deleteContainers: @escaping @Sendable () -> Void = { _ = LiveContainerNames.shared.deleteAll(within: 5) },
         resetInterrupt: @escaping @Sendable (Int) -> Void = { CLISignals.resetInterrupt(onceDelivered: $0) },
         flush: @escaping @Sendable () -> Void = {
             fflush(stdout)
             fflush(stderr)
         },
         vacate: @escaping @Sendable () -> Void,
         exitNow: @escaping @Sendable (Int32) -> Void = { _exit($0) }) {
        self.run = RunStop(grace: grace, teardown: teardown, terminateGroups: terminateGroups)
        self.closeGroups = closeGroups
        self.drainGroups = drainGroups
        self.killGroups = killGroups
        self.deleteContainers = deleteContainers
        self.resetInterrupt = resetInterrupt
        self.flush = flush
        self.vacate = vacate
        self.exitNow = exitNow
    }

    func receive(_ signal: Int32) {
        let count = lock.withLock { () -> Int in
            received += 1
            return received
        }
        guard count == 1 else {
            // Exit now. A row this leaves `running` is closed by the next app launch's sweep
            // (decision 11), with "the Iris process running it ended".
            return exitAtOnce(128 + signal, signals: count)
        }
        if run.request(reason: RunStop.reason(for: signal)) == .exitNow {
            exitAtOnce(RunJobCLI.Exit.notCompleted, signals: count)
        }
    }

    /// After a stopped run has returned, before `_exit`. Blocks its caller for up to the drain
    /// and delete bounds: call it from a dispatch queue, never the main thread or the pool.
    func settle() {
        // Closed first, whichever way the drain goes: the run is over, and a group admitted
        // after the drain would outlive the `_exit` (the kill path closes it too).
        closeGroups()
        if !drainGroups() { killGroups() }
        deleteContainers()
    }

    /// `settle()` on a queue of its own, awaited: `RunJobCLI.run` is on the main actor, and a
    /// blocked main thread holds up whatever else is on it (#372's rule for the pool, applied to
    /// main). Bounded by `settle`'s own bounds, so the plain continuation cannot hang.
    func settled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "iris.cli.settle").async {
                self.settle()
                continuation.resume()
            }
        }
    }

    /// `signals` is how many stopping signals had arrived, this one included.
    private func exitAtOnce(_ code: Int32, signals: Int) {
        exit(code: code) {
            resetInterrupt(signals)
            // Before either registry is read: a cancelled turn's queued runner refuses to spawn.
            run.cancelTurn()
            killGroups()
            deleteContainers()
        }
    }

    /// The CLI's one way out: `before` (the exit-now's kills and deletes), then flush, vacate and
    /// `_exit`. Single-shot, so the run returning on the main thread and a second signal on the
    /// signal queue cannot race to two exit codes: whichever gets here first exits, with its code.
    /// The other returns at once without doing anything, and the caller must not go on as if it
    /// had exited (`IrisMain` parks). Returns only in a test, whose `exitNow` records the code.
    func exit(code: Int32, before: () -> Void = {}) {
        let first: Bool = lock.withLock {
            guard !exiting else { return false }
            exiting = true
            return true
        }
        guard first else { return }
        before()
        flush()
        // Last before `_exit`: an empty payload under a held lock reads as an unnamed holder.
        vacate()
        exitNow(code)
    }
}
