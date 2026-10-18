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
    /// await cannot hang the stop. Counted from the request (`graceDeadline`).
    let grace: TimeInterval
    /// How long the run's teardown (`closeSession`: the container's stop and delete, each up to
    /// 60 s) may take on the stop path before the run goes on without it. A container it leaves is
    /// deleted by the CLI's settle (Task 14).
    let teardown: TimeInterval
    /// SIGTERM to the run's host process groups, then SIGKILL after the runner's grace.
    let terminateGroups: @Sendable () -> Void

    private let lock = NSLock()
    private var phase: Phase = .idle
    /// The parked waiter, with the token of the `wait` call that parked it: a cancellation only
    /// ever resumes its own call's continuation, never a later waiter's.
    private var waiter: (token: UInt64, continuation: CheckedContinuation<String?, Never>)?
    private var nextToken: UInt64 = 0
    /// Cancels the armed run's turn. Set by the run once its turn exists, dropped at `disarm`.
    private var turn: (@Sendable () -> Void)?
    /// Claims the armed run's ending for a stop, with its reason (#615). Set by the run beside
    /// `turn`, dropped at `disarm`. Called before `turn`, so the claim is the stop's even when
    /// the cancelled turn returns at once.
    private var ending: (@Sendable (String) -> Void)?
    /// Set by the armed `request`: see `graceDeadline`.
    private var graceEnd: DispatchTime?

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

    /// On an armed run, the first stop acts here, on the caller's queue (the CLI's signal queue),
    /// never in a pool task: under a held cooperative pool (#372) a task never runs, and a stop
    /// that waited for one would do nothing. So this claims the run's ending for the stop (#615),
    /// cancels the attached turn, sends the host groups their SIGTERM and starts the grace, all
    /// before it returns. The row stays the run's, written on its actor. Losing the claim (the
    /// turn came back first, or the deadline did) makes the rest harmless: cancelling a finished
    /// turn is a no-op, and the CLI's settle ends whatever group is left.
    func request(reason: String) -> Answer {
        typealias Taken = (Answer, CheckedContinuation<String?, Never>?, (@Sendable () -> Void)?,
                           (@Sendable (String) -> Void)?)
        let (answer, waiting, cancel, claim): Taken = lock.withLock {
            switch phase {
            case .idle:
                phase = .requested(reason)
                return (.exitNow, nil, nil, nil)
            case .armed:
                phase = .requested(reason)
                graceEnd = .now() + grace
                let w = waiter?.continuation
                waiter = nil
                return (.runWillStop, w, turn, ending)
            case .requested, .done:
                return (.ignored, nil, nil, nil)
            }
        }
        if answer == .runWillStop {
            // Outside the lock: cancellation handlers run inline. The claim on the run's ending
            // first, here on the signal queue (#615): left to a task, a held pool let the deadline
            // claim a run that was stopped first. Then the turn, so a runner queued but not yet
            // spawned (in no registry) refuses to spawn.
            claim?(reason)
            cancel?()
            terminateGroups()
        }
        waiting?.resume(returning: reason)
        return answer
    }

    /// When the grace for a cancelled turn runs out: `grace` after the stop was asked for, not
    /// after the run's actor got round to waiting, which a held pool can delay without limit. Nil
    /// until an armed run is asked to stop.
    var graceDeadline: DispatchTime? { lock.withLock { graceEnd } }

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
            turn = nil
            ending = nil
            let w = waiter?.continuation
            waiter = nil
            return w
        }
        waiting?.resume(returning: nil)
    }

    /// The armed run's turn, so a stop can cancel it synchronously, from the signal queue: the
    /// clean stop in `request`, and the CLI's exit-now before it reads the registries (a runner
    /// queued but not yet spawned is in neither, and a cancelled turn's runner refuses to spawn).
    /// A stop that came before the turn existed found nothing to cancel, so the turn is cancelled
    /// here, at once.
    func attachTurn(_ cancel: @escaping @Sendable () -> Void) {
        let late: Bool = lock.withLock {
            turn = cancel
            if case .requested = phase { return true }
            return false
        }
        if late { cancel() }
    }

    /// How the armed run claims its ending for a stop, called with the stop's reason on the
    /// caller's queue, never a pool task (#615). A stop that came first is claimed here, at once.
    /// Attach it before `attachTurn`, so a late stop claims before it cancels.
    func attachEnding(_ claim: @escaping @Sendable (String) -> Void) {
        let late: String? = lock.withLock {
            ending = claim
            if case .requested(let reason) = phase { return reason }
            return nil
        }
        if let late { claim(late) }
    }

    /// Cancels the attached turn, if any. Outside the lock: cancellation handlers run inline.
    func cancelTurn() {
        lock.withLock { turn }?()
    }

    /// For tests.
    var hasTurn: Bool { lock.withLock { turn != nil } }
    var isWaiting: Bool { lock.withLock { waiter != nil } }

    /// The reason once a stop is requested, or nil when the run ends or the waiting task is cancelled.
    func wait() async -> String? {
        let token: UInt64 = lock.withLock {
            nextToken += 1
            return nextToken
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                lock.withLock {
                    if case .requested(let reason) = phase { return continuation.resume(returning: reason) }
                    if case .done = phase { return continuation.resume(returning: nil) }
                    if Task.isCancelled { return continuation.resume(returning: nil) }
                    // One waiter at a time: the armed run's teardown's.
                    precondition(waiter == nil, "RunStop has one waiter: the armed run")
                    waiter = (token, continuation)
                }
            }
        } onCancel: {
            // Only this call's own continuation: a cancel that lands before this call parked
            // (its body then sees `isCancelled`) must not resume another call's waiter.
            let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
                guard let w = waiter, w.token == token else { return nil }
                waiter = nil
                return w.continuation
            }
            waiting?.resume(returning: nil)
        }
    }
}
