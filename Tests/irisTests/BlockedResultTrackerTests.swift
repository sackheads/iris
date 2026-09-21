import Testing
@testable import iris

/// `LoopDetector` keys on identical `toolName|args`, so an agent that rephrases its query every
/// time never trips it (#235). This counts consecutive guard-blocked results instead.
@Suite("BlockedResultTracker (#235)")
struct BlockedResultTrackerTests {

    @Test("consecutive blocked results increment the count")
    func incrementsOnBlocked() {
        var tracker = BlockedResultTracker()
        #expect(tracker.consecutive == 0)
        #expect(tracker.record(blocked: true) == 1)
        #expect(tracker.record(blocked: true) == 2)
        #expect(tracker.record(blocked: true) == 3)
        #expect(tracker.consecutive == 3)
    }

    @Test("any result that passes resets the run to zero")
    func resetsOnPass() {
        var tracker = BlockedResultTracker()
        _ = tracker.record(blocked: true)
        _ = tracker.record(blocked: true)
        #expect(tracker.record(blocked: false) == 0)
        #expect(tracker.consecutive == 0)
        // The next block starts a fresh run rather than resuming the old one.
        #expect(tracker.record(blocked: true) == 1)
    }
}
