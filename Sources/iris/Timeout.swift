import Foundation

struct TimeoutError: Error, Equatable {}

/// Runs `operation` with a wall-clock timeout, and returns at the deadline whether or not the
/// operation has finished: past `seconds` it throws `TimeoutError`, and cancelling the caller
/// throws `CancellationError` at once.
///
/// Either way the operation's task is cancelled, before this returns. That is all it is: work that
/// ignores cancellation (a native local-model inference, a bare `withCheckedContinuation`) keeps
/// running in the background after the deadline, and whatever it eventually returns or throws is
/// discarded. Work that must be *stopped*, not just abandoned, has to answer cancellation itself,
/// as `run_command` does by terminating its process.
///
/// Not a task group: a group does not return until every child has finished, so an operation
/// that ignored cancellation used to hold this for its whole duration (#345).
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        // Unstructured on purpose, so nothing here waits for it; `Task {}` rather than detached
        // keeps the caller's priority and task-locals (the guard tiers' test seams ride on those).
        race.start(
            work: Task { race.settle(await Result(awaiting: operation)) },
            timer: Task {
                let ns = UInt64(min(max(0, seconds.isNaN ? 0 : seconds), 1e9) * 1_000_000_000)
                guard (try? await Task.sleep(nanoseconds: ns)) != nil else { return }
                race.settle(.failure(TimeoutError()))
            })
        return try await race.wait()
    } onCancel: {
        race.settle(.failure(CancellationError()))
    }
}

/// The first of result, deadline and caller cancellation wins; everything after it is dropped.
/// One lock-guarded outcome, so the continuation is resumed exactly once.
private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    /// Hands over the two tasks. If the race was already settled (the caller was cancelled before
    /// they existed), they are cancelled on the spot.
    func start(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let settled = outcome != nil
        if !settled { self.work = work; self.timer = timer }
        lock.unlock()
        if settled { work.cancel(); timer.cancel() }
    }

    func settle(_ result: Result<T, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let w = waiter, work = self.work, timer = self.timer
        waiter = nil; self.work = nil; self.timer = nil
        lock.unlock()
        // Cancel before resuming, so an operation that answers cancellation synchronously (a
        // process terminated in its handler) has been told by the time the caller moves on.
        work?.cancel()
        timer?.cancel()
        w?.resume(with: result)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let outcome {
                lock.unlock()
                c.resume(with: outcome)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }
}

private extension Result where Failure == Error {
    init(awaiting body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
