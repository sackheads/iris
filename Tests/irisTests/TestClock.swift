import Foundation

/// How a test times things (#605): elapsed bounds and polling deadlines, on `SuspendingClock`,
/// which stops while the Mac sleeps, as the product's own dispatch timers do. `Date()` does not:
/// a maintenance sleep mid-run (703 s, measured) made a test that took 0.4 s report a 7 s wall,
/// and a bounded wait give up after 1 s of real work. `ContinuousClock` counts sleep too, so it
/// would repeat that. Use `Date()` only where a test means wall-clock time: a timestamp, a date,
/// a schedule.
enum TestClock {
    typealias Instant = SuspendingClock.Instant

    static func now() -> Instant { SuspendingClock().now }

    /// Seconds since `start`, as a test compares them against a bound.
    static func seconds(since start: Instant) -> Double {
        let elapsed = start.duration(to: now()).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    /// The instant `seconds` from now, for a polling loop's `while TestClock.now() < deadline`.
    static func deadline(_ seconds: Double) -> Instant { instant(now(), plus: seconds) }

    /// `start` moved on by `seconds`.
    static func instant(_ start: Instant, plus seconds: Double) -> Instant {
        start.advanced(by: .milliseconds(Int64(seconds * 1000)))
    }

    /// Seconds from `start` to `end`.
    static func seconds(from start: Instant, to end: Instant) -> Double {
        let span = start.duration(to: end).components
        return Double(span.seconds) + Double(span.attoseconds) / 1e18
    }
}

extension NSCondition {
    /// `wait(until:)` against a `TestClock` deadline, for a stub that blocks until released or
    /// its hang runs out: false once the deadline has passed. Waits in short slices of wall time
    /// and re-reads the suspending clock, because `NSCondition` only takes a `Date`, and a hang
    /// capped by wall time ends early across a sleep, so a cancel that waited it out would pass
    /// a test's suspending-clock bound. Call with the lock held, in a loop on the condition.
    func wait(until deadline: TestClock.Instant) -> Bool {
        let left = TestClock.seconds(from: TestClock.now(), to: deadline)
        guard left > 0 else { return false }
        _ = wait(until: Date().addingTimeInterval(min(left, 0.1)))
        return true
    }
}
