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
        // The suspending clock, named rather than implied (#605): a bound counts the test's time,
        // not the Mac's sleep. In the sleep that filed #605 this bound, then a bare
        // `Task.sleep(nanoseconds:)`, reported 30 s after a test that had run 1.07 s.
        try? await SuspendingClock().sleep(for: .milliseconds(Int64(seconds * 1000)))
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

/// A one-shot answer that main-actor callbacks (a WebKit navigation delegate) settle and a test awaits with a
/// bound (#1340), instead of a bare `withCheckedContinuation`, which `.timeLimit` cannot end (#428). A settle
/// that lands before the wait, or before the continuation exists, is kept: the continuation is installed and the
/// answer re-checked in one main-actor step. A wait that times out records an issue (unless `recordsTimeout` is
/// false, for a test of the bound itself: a known issue turns the run's summary line into one CI's gate rejects)
/// and leaves nothing parked.
@MainActor
final class MainActorSignal<Value: Sendable> {
    private var answer: Value?
    private var continuation: CheckedContinuation<Value?, Never>?

    func settle(_ value: Value) {
        guard answer == nil else { return }
        answer = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait(within seconds: Double = 10, recordsTimeout: Bool = true,
              sourceLocation: SourceLocation = #_sourceLocation) async -> Value? {
        if let answer { return answer }
        let task = Task { @MainActor [self] () -> Value? in
            await withCheckedContinuation { c in
                if let answer { c.resume(returning: answer) } else { continuation = c }
            }
        }
        let result = await firstOf(seconds) { await task.value }
        if result == nil, recordsTimeout {
            Issue.record("the signal was not settled within \(seconds)s", sourceLocation: sourceLocation)
        }
        continuation?.resume(returning: nil)
        continuation = nil
        return result ?? nil
    }
}

/// `blocking`'s answer, run on a dispatch queue of its own, so a bounded blocking wait (a
/// `usleep` poll, `LiveProcessGroups.waitUntilEmpty`) never parks a cooperative thread: CI's pool
/// is 3 threads. `blocking` must be bounded itself, since the continuation waits for it.
func offPool<T: Sendable>(_ blocking: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "iris.tests.offpool").async { continuation.resume(returning: blocking()) }
    }
}

/// Whether `condition` held within `seconds`, polled every 10 ms off the pool (`offPool`).
func polled(within seconds: Double, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    await offPool {
        let deadline = TestClock.deadline(seconds)
        while !condition() {
            if TestClock.now() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}

/// Thrown by `TestGate.waitOrThrow` when the gate's deadline passed first. The issue is already recorded.
struct TestGateDeadline: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "the gate was not released within \(seconds)s" }
}

/// A gate a test parks its stubs on and releases itself (#1343). A hand-rolled gate parks a bare
/// continuation, and most are awaited inside a turn the engine started (a `ScriptedStreamClient`
/// `.block`, a stub's method), which the test's cancellation never reaches: a test that fails before
/// its release left the turn parked for good (#428). A wait here ends on whichever comes first: a
/// release, its own task's cancellation, or the gate's deadline. A deadline hit is a failing test,
/// never a pass: it is reported in the waiter's own task when the wait resumes, at the caller's
/// source location, because Swift Testing finds the current test through the task (a report from
/// the timer's queue would belong to no test). A waiter in a detached task has no current test, and
/// its report fails the run instead. The deadline is uptime (`DispatchTime`), so the Mac's sleep
/// does not count, and it never waits on the pool or the main actor (#605, #634).
final class TestGate: @unchecked Sendable {
    private enum Outcome { case released, cancelled, deadline }

    let deadline: Double
    private let onTimeout: @Sendable (String, SourceLocation) -> Void
    private let lock = NSLock()
    private var opened = false
    private var banked = 0
    private var arrived = 0
    private var nextID: UInt64 = 0
    private var parked: [(id: UInt64, continuation: CheckedContinuation<Outcome, Never>)] = []
    private var arrivalWaiters: [UInt64: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

    /// `onTimeout` reports a missed deadline; a test of the gate itself injects one, since the default
    /// records an issue and a known issue fails CI's summary gate (#1348).
    init(deadline seconds: Double = 30, onTimeout: (@Sendable (String, SourceLocation) -> Void)? = nil) {
        deadline = seconds
        self.onTimeout = onTimeout ?? { message, location in Issue.record(Comment(rawValue: message), sourceLocation: location) }
    }

    /// Parks until a release, this task's cancellation or the deadline. Never throws, so a `.block`
    /// step or a non-throwing stub keeps its signature; a deadline hit is reported all the same. It returns
    /// normally on a cancel too, so a stub that does more after its wait does it on a cancelled task: one whose
    /// later work must not run then uses `waitOrThrow()`.
    func wait(sourceLocation: SourceLocation = #_sourceLocation) async {
        if await park() == .deadline { onTimeout(TestGateDeadline(seconds: deadline).description, sourceLocation) }
    }

    /// `wait()` for a throwing stub: a cancellation throws `CancellationError`, a deadline `TestGateDeadline`.
    func waitOrThrow(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        switch await park() {
        case .released: return
        case .cancelled: throw CancellationError()
        case .deadline:
            let error = TestGateDeadline(seconds: deadline)
            onTimeout(error.description, sourceLocation)
            throw error
        }
    }

    /// `wait()` deaf to its task's cancellation, for a stub that stands in for something that ignores it (a wedged
    /// provider): only a release or the deadline ends it, so it still cannot outlive its test.
    func waitIgnoringCancellation(sourceLocation: SourceLocation = #_sourceLocation) async {
        if await park(honouringCancel: false) == .deadline { onTimeout(TestGateDeadline(seconds: deadline).description, sourceLocation) }
    }

    /// Latches: every parked and later wait passes.
    func open() {
        let all = lock.withLock { () -> [CheckedContinuation<Outcome, Never>] in
            opened = true
            defer { parked = [] }
            return parked.map(\.continuation)
        }
        all.forEach { $0.resume(returning: .released) }
    }

    /// Frees the oldest parked waiters, one per permit; a permit with nobody parked is kept for the next arrival.
    func release(_ permits: Int = 1) {
        let freed = lock.withLock { () -> [CheckedContinuation<Outcome, Never>] in
            let n = min(permits, parked.count)
            banked += permits - n
            defer { parked.removeFirst(n) }
            return parked.prefix(n).map(\.continuation)
        }
        freed.forEach { $0.resume(returning: .released) }
    }

    /// Frees whoever is parked now, without latching: a later wait parks again.
    func releaseWaiting() {
        let all = lock.withLock { () -> [CheckedContinuation<Outcome, Never>] in
            defer { parked = [] }
            return parked.map(\.continuation)
        }
        all.forEach { $0.resume(returning: .released) }
    }

    /// How many waits are parked now.
    var waiting: Int { lock.withLock { parked.count } }

    /// How many waits have begun, whether they parked or passed.
    var arrivals: Int { lock.withLock { arrived } }

    /// Returns once `count` waits have begun; at `seconds` it reports a timeout and throws `BoundedWaitTimeout`.
    func waitForArrivals(_ count: Int, within seconds: Double = 30,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let reached: Bool? = await firstOf(seconds) { [self] in await arrivalsReached(count); return true }
        guard reached != nil else {
            let error = BoundedWaitTimeout(seconds: seconds)
            onTimeout("\(count) arrivals at the gate did not come within \(seconds)s (\(arrivals) did)", sourceLocation)
            throw error
        }
    }

    private func arrivalsReached(_ count: Int) async {
        let id = lock.withLock { nextID += 1; return nextID }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if arrived >= count || Task.isCancelled { return true }
                    arrivalWaiters[id] = (count, c)
                    return false
                }
                if now { c.resume() }
            }
        } onCancel: {
            lock.withLock { arrivalWaiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    /// One wait, resumed exactly once by whichever claimant takes it out of `parked` first: a release, the
    /// cancel handler (unless `honouringCancel` is off) or the deadline. A cancel that lands before the park is seen by `Task.isCancelled`.
    private func park(honouringCancel: Bool = true) async -> Outcome {
        let id = lock.withLock { nextID += 1; return nextID }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
                let (now, arrivedWaiters) = lock.withLock { () -> (Outcome?, [CheckedContinuation<Void, Never>]) in
                    arrived += 1
                    let reached = arrivalWaiters.filter { $0.value.count <= arrived }
                    reached.keys.forEach { arrivalWaiters.removeValue(forKey: $0) }
                    let waiters = reached.values.map(\.continuation)
                    if opened { return (.released, waiters) }
                    if banked > 0 { banked -= 1; return (.released, waiters) }
                    if honouringCancel && Task.isCancelled { return (.cancelled, waiters) }
                    parked.append((id, c))
                    return (nil, waiters)
                }
                arrivedWaiters.forEach { $0.resume() }
                if let now {
                    c.resume(returning: now)
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [self] in take(id)?.resume(returning: .deadline) }
                }
            }
        } onCancel: {
            if honouringCancel { take(id)?.resume(returning: .cancelled) }
        }
    }

    private func take(_ id: UInt64) -> CheckedContinuation<Outcome, Never>? {
        lock.withLock {
            guard let i = parked.firstIndex(where: { $0.id == id }) else { return nil }
            return parked.remove(at: i).continuation
        }
    }
}
