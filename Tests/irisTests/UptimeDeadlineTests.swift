import Testing
import Foundation
import os
@testable import IrisKit

/// #608: a product deadline runs on uptime, which stops while the Mac sleeps, so a sleep does not
/// spend it. A sleep looks like wall time moving on while the deadline's clock stands still: each
/// test holds an injected `UptimeClock` still while real time passes the bound, and the deadline
/// must not fire. One per site; the "moves" tests show the deadline is read from that clock.
@Suite("Product deadlines run on uptime, not the wall clock (#608)", .timeLimit(.minutes(1)))
struct UptimeDeadlineTests {
    /// Stands still until moved: the deadline's view of a Mac asleep.
    final class ManualClock: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0.0)
        func advance(by seconds: Double) { lock.withLock { $0 += seconds } }
        var clock: UptimeClock { UptimeClock { self.lock.withLock { $0 } } }
    }

    @Test("BlockingSpawn's timeout is not spent while its clock stands still")
    func blockingSpawnStill() async {
        let still = ManualClock()
        let started = TestClock.now()
        let status = await offPool {
            BlockingSpawn.run("/bin/sh", ["-c", "sleep 0.6; exit 4"], timeoutSeconds: 0.2, clock: still.clock)
        }
        #expect(status == 4, "the child ran to its own exit, not to a 0.2 s kill")
        #expect(TestClock.seconds(since: started) >= 0.5)
    }

    @Test("BlockingSpawn's timeout fires when its clock moves past it")
    func blockingSpawnMoves() async {
        let manual = ManualClock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { manual.advance(by: 2) }
        let started = TestClock.now()
        let status = await offPool {
            BlockingSpawn.run("/bin/sh", ["-c", "sleep 20"], timeoutSeconds: 1, clock: manual.clock)
        }
        #expect(status == 128 + SIGKILL)
        #expect(TestClock.seconds(since: started) < 10)
    }

    @Test("the container kill ladder's grace is not spent while its clock stands still")
    func ladderGraceStill() async {
        let still = ManualClock()
        let done = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { done.withLock { $0 = true } }
        let started = TestClock.now()
        await offPool { CLIProcessRunner.waitUntil(0.2, clock: still.clock) { done.withLock { $0 } } }
        #expect(done.withLock { $0 }, "the wait ended on its condition, not at a 0.2 s grace")
        #expect(TestClock.seconds(since: started) >= 0.5)
    }

    @Test("the container kill ladder's grace ends when its clock moves past it")
    func ladderGraceMoves() async {
        let manual = ManualClock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { manual.advance(by: 2) }
        let started = TestClock.now()
        await offPool { CLIProcessRunner.waitUntil(1, clock: manual.clock) { false } }
        #expect(TestClock.seconds(since: started) < 5)
    }

    @Test("LiveProcessGroups' drain wait is not spent while its clock stands still")
    func drainStill() async throws {
        let registry = LiveProcessGroups()
        let runner = ProcessGroupRunner(registry: registry)
        let task = Task { await runner.run(executable: "/bin/sh", arguments: ["-c", "sleep 0.6"],
                                           environment: nil, currentDirectory: nil) }
        #expect(await polled(within: 5) { registry.count == 1 }, "the group joined the registry")
        let still = ManualClock()
        let drained = await offPool { registry.waitUntilEmpty(within: 0.2, clock: still.clock) }
        #expect(drained, "it waited for the group to end, not for a 0.2 s bound")
        _ = try await value(of: task, within: 10)
    }
}
