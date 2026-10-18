import Foundation

/// The clock a product deadline or a measured duration is timed on (#608): mach uptime, the clock
/// `DispatchTime` and the dispatch-timer deadlines run on (invariant 4), which pauses while the Mac
/// sleeps. `Date()` does not pause: a deadline taken from it before a sleep has passed by the
/// wake, and a wait polled against it gives up at once. Injectable so a test can stop it while
/// wall time runs on, which is what a sleep looks like from here.
struct UptimeClock: Sendable {
    /// Seconds on a clock that stops in sleep. Only differences mean anything.
    let now: @Sendable () -> Double

    static let live = UptimeClock { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    func seconds(since start: Double) -> Double { now() - start }
}
