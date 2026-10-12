import Foundation

/// #463 decision 16: a CLI stop, as the run sees it. A third claimant on the run's ending, beside
/// the turn and the watchdog. Lock-based, so a signal source on its own queue can ask without
/// waiting for the main actor or the runner's actor.
final class RunStop: @unchecked Sendable {
    enum Answer: Equatable, Sendable {
        /// No run is armed: before admission, or a dry run. The CLI exits 2 now, with no row.
        case exitNow
        /// An armed run will close itself as stopped; the CLI exits when it returns.
        case runWillStop
        /// Already asked, or the run is over: the CLI finishes on its own.
        case ignored
    }

    private enum Phase { case idle, armed, requested(String), done }

    /// How long the run waits for a cancelled turn before abandoning it, so an uncancellable
    /// await cannot hang the stop.
    let grace: TimeInterval
    /// How long the run's teardown (`closeSession`: the container's stop and delete, each up to
    /// 60 s) may take on the stop path before the run goes on without it. A container it leaves is
    /// deleted by the CLI's settle (Task 14).
    let teardown: TimeInterval
    /// SIGTERM to the run's host process groups, then SIGKILL after the runner's grace.
    let terminateGroups: @Sendable () -> Void

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var waiter: CheckedContinuation<String?, Never>?

    init(grace: TimeInterval = 15, teardown: TimeInterval = 5,
         terminateGroups: @escaping @Sendable () -> Void = { LiveProcessGroups.shared.terminateAll() }) {
        self.grace = grace
        self.teardown = teardown
        self.terminateGroups = terminateGroups
    }

    /// Whether a stop was ever asked for, armed or not. The CLI settles its groups and containers
    /// before `_exit` when it was.
    var wasRequested: Bool { requestedReason != nil }

    /// The reason a stop was asked for, or nil when none was.
    var requestedReason: String? {
        lock.withLock {
            if case .requested(let reason) = phase { return reason }
            return nil
        }
    }

    static func reason(for signal: Int32) -> String { "stopped by a signal (\(signalName(signal)))" }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        default: "signal \(signal)"
        }
    }

    func request(reason: String) -> Answer {
        let (answer, waiting): (Answer, CheckedContinuation<String?, Never>?) = lock.withLock {
            switch phase {
            case .idle:
                phase = .requested(reason)
                return (.exitNow, nil)
            case .armed:
                phase = .requested(reason)
                let w = waiter
                waiter = nil
                return (.runWillStop, w)
            case .requested, .done:
                return (.ignored, nil)
            }
        }
        waiting?.resume(returning: reason)
        return answer
    }

    /// At the top of a run. nil: armed. A reason: a stop came first, so the run must not start.
    /// One armed run at a time: a second would be a second waiter, so it traps here, before it
    /// has a row.
    func arm() -> String? {
        lock.withLock {
            switch phase {
            case .armed:
                preconditionFailure("RunStop arms one run at a time: the CLI's")
            case .idle, .done:
                phase = .armed
                return nil
            case .requested(let reason):
                return reason
            }
        }
    }

    /// At the end of a run: a later signal is `.ignored`, so the CLI's flush and print are kept.
    func disarm() {
        let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
            if case .armed = phase { phase = .done }
            let w = waiter
            waiter = nil
            return w
        }
        waiting?.resume(returning: nil)
    }

    /// The reason once a stop is requested, or nil when the run ends or the waiting task is cancelled.
    func wait() async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                lock.withLock {
                    if case .requested(let reason) = phase { return continuation.resume(returning: reason) }
                    if case .done = phase { return continuation.resume(returning: nil) }
                    if Task.isCancelled { return continuation.resume(returning: nil) }
                    // One waiter at a time: the armed run's stop watcher, then its teardown's.
                    precondition(waiter == nil, "RunStop has one waiter: the armed run")
                    waiter = continuation
                }
            }
        } onCancel: {
            let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
                let w = waiter
                waiter = nil
                return w
            }
            waiting?.resume(returning: nil)
        }
    }
}
