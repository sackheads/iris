import Testing
import Foundation
@testable import IrisKit

/// #285 — the watch-sync queue: in order, one run at a time, and at most one run waiting.
@Suite("Sync coalescer (#285)")
struct SyncCoalescerTests {

    /// Stands in for the jobs table and the sync that reads it: `write` is a ledger write, and
    /// each run records the version it read. Runs park while `hold` is set, so a test can keep one
    /// in progress while it makes requests behind it.
    actor Probe {
        private(set) var version = 0
        private(set) var seen: [Int] = []
        private var hold = true
        private var parked: [CheckedContinuation<Void, Never>] = []

        func write() { version += 1 }

        func run() async {
            seen.append(version)
            if hold { await withCheckedContinuation { parked.append($0) } }
        }

        func releaseOne() {
            guard !parked.isEmpty else { return }
            parked.removeFirst().resume()
        }

        func releaseAll() {
            hold = false
            for waiter in parked { waiter.resume() }
            parked = []
        }

        /// Bounded, so a regression fails naming what it waited for instead of hanging the run.
        func waitForRuns(_ n: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
            for _ in 0..<500 {
                if seen.count >= n && parked.count >= 1 { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("waited 5s for run \(n) to start; saw \(seen.count)",
                         sourceLocation: sourceLocation)
        }
    }

    @Test("a burst of writes behind a running sync costs one more sync, and it sees the last write",
          .timeLimit(.minutes(1)))
    func aBurstRunsAtMostTwoSyncs() async {
        let probe = Probe()
        let queue = SyncCoalescer { await probe.run() }
        var tasks = [await queue.request()]
        await probe.waitForRuns(1)

        let burst = 25
        for _ in 0..<burst {
            await probe.write()
            tasks.append(await queue.request())
        }
        await probe.releaseAll()
        for task in tasks { await task.value }

        #expect(await probe.seen.count == 2, "one in progress, one behind it — not \(burst + 1)")
        #expect(await probe.seen.last == burst, "the last sync read the table after the last write")
    }

    @Test("a request made once the waiting sync has started gets a sync of its own",
          .timeLimit(.minutes(1)))
    func aRequestAfterTheWaitingSyncStartsIsNotFoldedIntoIt() async {
        // The ordering half: the waiting sync may already have read the table, so a write after it
        // started must not be answered by it.
        let probe = Probe()
        let queue = SyncCoalescer { await probe.run() }
        let first = await queue.request()
        await probe.waitForRuns(1)
        let second = await queue.request()
        await probe.releaseOne()
        await first.value
        await probe.waitForRuns(2)

        await probe.write()
        let third = await queue.request()
        #expect(third != second, "the started sync read before this write")
        await probe.releaseAll()
        await third.value

        #expect(await probe.seen == [0, 0, 1])
    }
}
