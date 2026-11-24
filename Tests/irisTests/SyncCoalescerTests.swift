import Testing
import Foundation
@testable import IrisKit

/// #285 — the watch-sync queue: in order, one run at a time, and at most one run waiting.
@Suite("Sync coalescer (#285)", .timeLimit(.minutes(1)))
struct SyncCoalescerTests {

    /// Stands in for the jobs table and the sync that reads it: `write` is a ledger write, and
    /// each run records the version it read. Runs park on `gate` until the test releases them, so a
    /// test can keep one in progress while it makes requests behind it.
    actor Probe {
        private(set) var version = 0
        private(set) var seen: [Int] = []
        nonisolated let gate = TestGate()

        func write() { version += 1 }

        func run() async {
            seen.append(version)
            await gate.wait()
        }

        /// Frees the oldest parked run. With none parked it banks a pass for the next one, where the old probe
        /// dropped it; every caller here waits for a parked run first (#1384 review).
        nonisolated func releaseOne() { gate.release() }

        nonisolated func releaseAll() { gate.open() }

        /// Returns once run `n` has started and parked on the gate, or fails the test at the bound. Parked, not
        /// only started: a run already past the gate is no longer "in progress" for the request behind it.
        nonisolated func waitForRuns(_ n: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await gate.waitForArrivals(n, sourceLocation: sourceLocation)
            if gate.waiting == 0 { Issue.record("run \(n) started but is not held at the gate", sourceLocation: sourceLocation) }
        }
    }

    @Test("a burst of writes behind a running sync costs one more sync, and it sees the last write",
          .timeLimit(.minutes(1)))
    func aBurstRunsAtMostTwoSyncs() async throws {
        let probe = Probe()
        let queue = SyncCoalescer { await probe.run() }
        var tasks = [await queue.request()]
        try await probe.waitForRuns(1)

        let burst = 25
        for _ in 0..<burst {
            await probe.write()
            tasks.append(await queue.request())
        }
        probe.releaseAll()
        for task in tasks { try await value(of: task) }

        #expect(await probe.seen.count == 2, "one in progress, one behind it — not \(burst + 1)")
        #expect(await probe.seen.last == burst, "the last sync read the table after the last write")
    }

    @Test("a request made once the waiting sync has started gets a sync of its own",
          .timeLimit(.minutes(1)))
    func aRequestAfterTheWaitingSyncStartsIsNotFoldedIntoIt() async throws {
        // The ordering half: the waiting sync may already have read the table, so a write after it
        // started must not be answered by it.
        let probe = Probe()
        let queue = SyncCoalescer { await probe.run() }
        let first = await queue.request()
        try await probe.waitForRuns(1)
        let second = await queue.request()
        probe.releaseOne()
        try await value(of: first)
        try await probe.waitForRuns(2)

        await probe.write()
        let third = await queue.request()
        #expect(third != second, "the started sync read before this write")
        probe.releaseAll()
        try await value(of: third)

        #expect(await probe.seen == [0, 0, 1])
    }
}
