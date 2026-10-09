import Testing
import Foundation

/// Thrown by `value(of:within:)` when the task has not finished in time. The issue is already
/// recorded; throwing just ends the test instead of letting it go on with no value.
struct BoundedWaitTimeout: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "the awaited task did not finish within \(seconds)s" }
}

/// `task.value`, but a stuck task fails the test rather than hanging the run (#428, #435).
///
/// An unstructured task's value ignores the waiter's cancellation, so `.timeLimit` alone cannot
/// end a test parked on it, and a task group racing it against a timer cannot either: the group
/// waits for every child on the way out. This returns at the deadline, or as soon as the waiting
/// test is cancelled, whether or not `task` honours cancellation: it records an issue, cancels
/// `task`, and throws `BoundedWaitTimeout`. A task still parked on a bare continuation is left
/// behind, which is fine for a test that has already failed.
func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double = 30,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws -> T {
    let outcome = await firstOf(seconds) { await task.value }
    guard let outcome else {
        task.cancel()
        Issue.record("the awaited task did not finish within \(seconds)s", sourceLocation: sourceLocation)
        throw BoundedWaitTimeout(seconds: seconds)
    }
    return outcome
}

/// The throwing-task form: rethrows what the task threw, and times out as above.
func value<T: Sendable>(of task: Task<T, any Error>, within seconds: Double = 30,
                        sourceLocation: SourceLocation = #_sourceLocation) async throws -> T {
    let outcome = await firstOf(seconds) { await task.result }
    guard let outcome else {
        task.cancel()
        Issue.record("the awaited task did not finish within \(seconds)s", sourceLocation: sourceLocation)
        throw BoundedWaitTimeout(seconds: seconds)
    }
    return try outcome.get()
}

/// `operation`'s result, or nil once `seconds` pass or the caller is cancelled, whichever is
/// first. Never waits for `operation` after that: it runs in a task of its own that is abandoned.
private func firstOf<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let first = FirstOf<T>()
    let work = Task { first.resolve(await operation()) }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        first.resolve(nil)
    }
    defer { work.cancel(); timer.cancel() }
    return await withTaskCancellationHandler {
        await withCheckedContinuation { first.install($0) }
    } onCancel: {
        first.resolve(nil)
    }
}

/// One answer, from whichever side gets there first. `resolve` can run before `install` (a
/// cancellation that lands before the continuation exists), so an early answer is held.
private final class FirstOf<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var early: T??
    private var done = false

    func install(_ c: CheckedContinuation<T?, Never>) {
        lock.withLock {
            if let early { done = true; c.resume(returning: early) } else { continuation = c }
        }
    }

    func resolve(_ value: T?) {
        lock.withLock {
            guard !done else { return }
            if let continuation {
                done = true
                self.continuation = nil
                continuation.resume(returning: value)
            } else if early == nil {
                early = .some(value)
            }
        }
    }
}
