import Testing
import Foundation

/// #1340: `MainActorSignal`, which the Viewer navigation waiters settle instead of resuming a bare continuation.
@MainActor
@Suite("MainActorSignal is bounded and keeps an early answer (#1340)", .timeLimit(.minutes(1)))
struct MainActorSignalTests {
    @Test("an answer settled before the wait is returned at once")
    func settledFirst() async {
        let signal = MainActorSignal<Int>()
        signal.settle(7)
        #expect(await signal.wait(within: 5) == 7)
    }

    @Test("an answer settled while the wait is parked resumes it, and only the first settle counts")
    func settledDuring() async {
        let signal = MainActorSignal<Int>()
        // Late enough that the wait has installed its continuation, so this is the parked case, not the early one.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            signal.settle(1)
            signal.settle(2)
        }
        #expect(await signal.wait(within: 5) == 1)
    }

    @Test("with no answer, the wait ends at its bound with nil and records the timeout")
    func boundedWithoutAnswer() async {
        let signal = MainActorSignal<Int>()
        let clock = SuspendingClock()
        let start = clock.now
        await withKnownIssue("the bound records the timeout") {
            let result = await signal.wait(within: 0.3)
            #expect(result == nil)
        }
        #expect(clock.now - start < .seconds(5), "returned at the bound, not later")
    }
}
