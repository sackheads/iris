import Testing
import Foundation
import GRDB
@testable import iris

/// #187 deliverable 4, spec §2 — the actor that owns a watch's time.
///
/// Everything here runs on an injected clock and an injected fire handler: `tick(now:)` is the
/// whole evaluation step, `deliver(root:paths:)` is the whole event source, and no test writes a
/// file to provoke an FSEvent or waits on a real window (invariant 7, and the plan's test
/// constraints). Each test builds its own in-memory ledger, its own `RecentWrites` and its own
/// coordinator; `RecentWrites.shared` is never touched.
@Suite("Watch coordinator (#187)")
struct WatchCoordinatorTests {

    // MARK: Fixtures

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A clock the test moves by hand. Shared by the coordinator and the registry so "ours" and
    /// "now" never disagree.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        var now: Date { lock.withLock { t } }
        func set(_ t: Date) { lock.withLock { self.t = t } }
    }

    /// Every fire the coordinator dispatched, and the admission each one is answered with. The
    /// script is consumed in order; once it runs out, `fallback` answers.
    actor Recorder {
        private(set) var fires: [(job: Job, fire: WatchFire)] = []
        private var script: [JobRunner.Admission?]
        private let fallback: JobRunner.Admission?
        private var waiters: [(wanted: Int, continuation: CheckedContinuation<Void, Never>)] = []

        init(_ script: [JobRunner.Admission?] = [], fallback: JobRunner.Admission? = .run) {
            self.script = script
            self.fallback = fallback
        }

        func record(_ job: Job, _ fire: WatchFire) -> JobRunner.Admission? {
            fires.append((job, fire))
            let reached = fires.count
            var still: [(wanted: Int, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in waiters {
                if waiter.wanted <= reached { waiter.continuation.resume() } else { still.append(waiter) }
            }
            waiters = still
            return script.isEmpty ? fallback : script.removeFirst()
        }

        var count: Int { fires.count }
        var paths: [[String]] { fires.map(\.fire.paths) }
        var summaries: [WatchSummary] { fires.map(\.fire.summary) }

        /// Parks until at least `n` fires have been handed over. Every caller is inside a
        /// `.timeLimit`ed test or follows a `tick` that set `fireOutstanding` synchronously, so a
        /// coordinator that never dispatches fails as a timeout rather than a hang.
        func waitFor(_ n: Int) async {
            if fires.count >= n { return }
            await withCheckedContinuation { waiters.append((n, $0)) }
        }
    }

    /// A one-shot rendezvous, so a test can hold one subscriber's handler open while the loop
    /// keeps serving the others.
    actor Gate {
        private var entered = false
        private var opened = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            entered = true
            for waiter in entryWaiters { waiter.resume() }
            entryWaiters = []
            if opened { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() {
            opened = true
            for waiter in openWaiters { waiter.resume() }
            openWaiters = []
        }
    }

    static func handler(_ recorder: Recorder) -> WatchFireHandler {
        { job, fire in await recorder.record(job, fire) }
    }

    static func job(_ name: String, root: String, quiet: Int = 3, ignore: [String] = [],
                    overlap: JobPolicy.Overlap = .queue) -> Job {
        Job(name: name, prompt: "Note what changed",
            trigger: .fsEvent(FSWatch(path: root, quietWindowSeconds: quiet, ignore: ignore)),
            policy: JobPolicy(overlap: overlap))
    }

    static func coordinator(ledger: JobLedger, clock: Clock, writes: RecentWrites,
                            recorder: Recorder) -> WatchCoordinator {
        WatchCoordinator(ledger: ledger, now: { clock.now }, recentWrites: writes,
                         fire: handler(recorder))
    }

    /// The fire is dispatched in a task of its own and its admission is applied in another, so
    /// state that follows a handler's return is observed by polling rather than by guessing at an
    /// ordering. Bounded: a coordinator that never applies the admission fails in six seconds
    /// with the description, not by hanging.
    static func eventually(_ what: String, _ check: @Sendable () async -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<600 {
            if await check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: The quiet window

    @Test("eight batches inside two seconds are one fire, after the window")
    func eightBatchesWithinTwoSecondsFireOnce() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("notes", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        for i in 0..<8 {
            clock.set(Self.at(Double(i) / 4))
            await coordinator.deliver(root: "/r", paths: ["/r/f\(i).txt"])
        }

        clock.set(Self.at(2))
        await coordinator.tick(now: Self.at(2))
        #expect(await recorder.count == 0, "the window has not elapsed since the last batch")
        #expect(await coordinator.snapshot(job.id)?.pending == 8)

        clock.set(Self.at(5))
        await coordinator.tick(now: Self.at(5))
        await recorder.waitFor(1)
        #expect(await recorder.count == 1)
        let fire = try #require(await recorder.fires.first?.fire)
        #expect(fire.paths == (0..<8).map { "/r/f\($0).txt" }, "sorted, and every path once")
        #expect(fire.summary.coalesced == 8)
        #expect(fire.summary.changed == 8)
        #expect(fire.summary.delivered == 8)
        #expect(fire.summary.ceilingFired == false)
    }

    @Test("a directory that never goes quiet still fires, at the ceiling, and the next event starts a new one")
    func aBatchEverySecondFiresAtTheCeiling() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("busy", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        // A batch every second, and a tick after each one: the window never elapses, so only the
        // ceiling can end this burst.
        for second in 0...29 {
            clock.set(Self.at(Double(second)))
            await coordinator.deliver(root: "/r", paths: ["/r/f\(second).txt"])
            await coordinator.tick(now: Self.at(Double(second)))
            if second < 29 { #expect(await recorder.count == 0, "no fire at +\(second)") }
        }
        clock.set(Self.at(30))
        await coordinator.tick(now: Self.at(30))
        await recorder.waitFor(1)
        let first = try #require(await recorder.fires.first?.fire)
        #expect(first.paths.count == 30, "everything the burst saw")
        #expect(first.summary.ceilingFired)

        // The ceiling fire ended the burst. The next accepted event begins a new one, with a
        // ceiling of its own — thirty seconds from *it*, not from the first burst.
        await Self.eventually("the run to be applied") { await coordinator.snapshot(job.id)?.fireOutstanding == false }
        clock.set(Self.at(31))
        await coordinator.deliver(root: "/r", paths: ["/r/late.txt"])
        #expect(await coordinator.snapshot(job.id)?.burstBegan == Self.at(31))
        clock.set(Self.at(34))
        await coordinator.tick(now: Self.at(34))
        await recorder.waitFor(2)
        let second = try #require(await recorder.fires.last?.fire)
        #expect(second.paths == ["/r/late.txt"])
        #expect(second.summary.ceilingFired == false, "this one went quiet inside its own window")
        #expect(second.summary.changed == 1, "the counters started at zero with the burst")
    }

    // MARK: Absorption

    @Test("noise and Iris's own writes never start a burst")
    func noiseAndOwnWritesNeverStartABurst() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let writes = RecentWrites(now: { clock.now })
        await writes.record("/r/summary.md")
        let job = Self.job("quiet", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock, writes: writes,
                                           recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/.DS_Store"])
        await coordinator.deliver(root: "/r", paths: ["/r/summary.md"])
        await coordinator.tick(now: Self.at(10))

        #expect(await recorder.count == 0)
        let snapshot = try #require(await coordinator.snapshot(job.id))
        #expect(snapshot.burstBegan == nil)
        #expect(snapshot.pending == 0)
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(noise: 1, ownWrites: 1))
        #expect(await coordinator.nextDeadline() == nil, "nothing is waiting on a clock")
    }

    @Test("a mixed batch accepts only the rest, and the burst's counters start at zero with it")
    func aMixedBatchAcceptsOnlyTheRest() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let writes = RecentWrites(now: { clock.now })
        await writes.record("/r/summary.md")
        let job = Self.job("mixed", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock, writes: writes,
                                           recorder: recorder)
        await coordinator.sync(with: [job])

        // Order is the batch's own: the `.DS_Store` arrives before any burst exists, so it is
        // absorbed since launch and nowhere else; `a.swift` begins the burst; `summary.md` is
        // absorbed *inside* it and is the one the run's summary reports.
        await coordinator.deliver(root: "/r",
                                  paths: ["/r/.DS_Store", "/r/a.swift", "/r/summary.md"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)

        let fire = try #require(await recorder.fires.first?.fire)
        #expect(fire.paths == ["/r/a.swift"])
        #expect(fire.summary.changed == 1)
        #expect(fire.summary.coalesced == 1)
        #expect(fire.summary.noise == 0, "the noise arrived before the burst did")
        #expect(fire.summary.ownWrites == 1)
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(noise: 1, ownWrites: 1),
                "since launch counts both, burst or no burst")
    }

    // MARK: Fan-out

    @Test("two subscribers on one root keep their own windows and their own counts")
    func twoSubscribersOnOneRootAreIndependent() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let quick = Self.job("quick", root: "/r", quiet: 3)
        let slow = Self.job("slow", root: "/r", quiet: 10)
        try store.ledger.upsert(quick)
        try store.ledger.upsert(slow)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [quick, slow])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(1))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])

        clock.set(Self.at(4))
        await coordinator.tick(now: Self.at(4))
        await recorder.waitFor(1)
        #expect(await recorder.count == 1)
        #expect(await recorder.fires.first?.job.id == quick.id)
        #expect(await coordinator.snapshot(slow.id)?.pending == 2, "the slow one is still gathering")

        clock.set(Self.at(11))
        await coordinator.tick(now: Self.at(11))
        await recorder.waitFor(2)
        let second = try #require(await recorder.fires.last)
        #expect(second.job.id == slow.id)
        #expect(second.fire.paths == ["/r/a.txt", "/r/b.txt"])
        #expect(second.fire.summary.changed == 2)
        #expect(await recorder.fires.first?.fire.summary.changed == 2,
                "each subscriber counted the batch for itself")
    }

    @Test("a nested root is served by the ancestor's stream, exactly once")
    func aChildRootIsServedOnceByTheAncestorStream() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let parent = Self.job("parent", root: "/r")
        let child = Self.job("child", root: "/r/sub")
        try store.ledger.upsert(parent)
        try store.ledger.upsert(child)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [parent, child])

        // One stream, one batch: the child has no stream of its own (§0.5).
        await coordinator.deliver(root: "/r", paths: ["/r/sub/a", "/r/other"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(2)

        #expect(await recorder.count == 2)
        let fires = await recorder.fires
        let byJob = Dictionary(uniqueKeysWithValues: fires.map { ($0.job.id, $0.fire) })
        #expect(byJob[parent.id]?.paths == ["/r/other", "/r/sub/a"])
        #expect(byJob[child.id]?.paths == ["/r/sub/a"], "the path outside the child root never reached it")
        #expect(byJob[child.id]?.summary.changed == 1)
    }

    /// R-D4-5. FSEvents reports a path under the root it was given, and a delete names a leaf that
    /// is already gone — `standardizingPath` then leaves the `/private` prefix on, so the event
    /// would be attributed to no root at all and matched against no registry entry.
    @Test("a /private/var-shaped root attributes both a delete and a modify")
    func aPrivateVarRootAttributesADeleteAndAModify() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try #require(WatchRoot.canonical(tmp.path))
        #expect(root.hasPrefix("/var/folders/"), "precondition: the temp directory is under /var")

        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let writes = RecentWrites(now: { clock.now })
        let job = Self.job("temp", root: root)
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock, writes: writes,
                                           recorder: recorder)
        await coordinator.sync(with: [job])

        // The deleted file was written by an unattended run and recorded before it went; the
        // event for its removal arrives in the `/private` spelling, which is the shape a path
        // whose leaf no longer exists standardises into.
        let deleted = tmp.appendingPathComponent("gone.txt").path
        await writes.record(deleted)
        await coordinator.deliver(root: root, paths: ["/private" + deleted,
                                                      "/private" + tmp.appendingPathComponent("edited.txt").path])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)

        let fire = try #require(await recorder.fires.first?.fire)
        #expect(fire.paths == ["\(root)/edited.txt"], "both were attributed to the root, in its spelling")
        #expect(fire.summary.changed == 1, "the modify was accepted and the delete was not")
        // The delete arrived before anything had started a burst, so it is counted where an
        // absorbed event outside a burst is counted — and counted at all, which is what says the
        // `/private` spelling reached the registry entry the write recorded.
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(ownWrites: 1))
    }

    // MARK: The fire never blocks the loop

    @Test("a handler that parks does not stop another subscriber firing", .timeLimit(.minutes(1)))
    func aFireNeverBlocksTheLoop() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let gate = Gate()
        let parked = Self.job("parked", root: "/a")
        let other = Self.job("other", root: "/b")
        try store.ledger.upsert(parked)
        try store.ledger.upsert(other)
        let coordinator = WatchCoordinator(
            ledger: store.ledger, now: { clock.now }, recentWrites: RecentWrites(now: { clock.now }),
            fire: { job, fire in
                let admission = await recorder.record(job, fire)
                if job.id == parked.id { await gate.arriveAndWait() }
                return admission
            })
        await coordinator.sync(with: [parked, other])

        await coordinator.deliver(root: "/a", paths: ["/a/one.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await gate.waitForEntry()

        // The first handler is still inside its run. The loop is not.
        clock.set(Self.at(4))
        await coordinator.deliver(root: "/b", paths: ["/b/two.txt"])
        clock.set(Self.at(7))
        await coordinator.tick(now: Self.at(7))
        await recorder.waitFor(2)
        #expect(await recorder.fires.last?.job.id == other.id)
        #expect(await coordinator.snapshot(parked.id)?.fireOutstanding == true)

        await gate.open()
        await Self.eventually("the parked fire to finish") {
            await coordinator.snapshot(parked.id)?.fireOutstanding == false
        }
    }

    // MARK: The five admissions

    @Test("a run takes the paths it was given and leaves everything accepted since")
    func runRemovesOnlyTheFiredPaths() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.run])
        let gate = Gate()
        let job = Self.job("run", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = WatchCoordinator(
            ledger: store.ledger, now: { clock.now }, recentWrites: RecentWrites(now: { clock.now }),
            fire: { j, f in
                let admission = await recorder.record(j, f)
                await gate.arriveAndWait()
                return admission
            })
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await gate.waitForEntry()
        #expect(await recorder.fires.first?.fire.paths == ["/r/a.txt"])

        // `b` arrives while the run is going: it is held, never handed to this fire.
        clock.set(Self.at(4))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])
        #expect(await coordinator.snapshot(job.id)?.held == 2, "a is still held until the handler returns")

        clock.set(Self.at(9))
        await gate.open()
        await Self.eventually("the run to be applied") {
            await coordinator.snapshot(job.id)?.fireOutstanding == false
        }
        let snapshot = try #require(await coordinator.snapshot(job.id))
        #expect(snapshot.held == 0)
        #expect(snapshot.pending == 1, "what arrived during the run begins the next burst")
        #expect(snapshot.burstBegan == Self.at(9), "and the window runs from the end of the run")
    }

    @Test("a queued fire keeps its paths, and takeHeldPaths returns the union")
    func queuedKeepsThePathsAndTakeHeldPathsReturnsTheUnion() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.queued])
        let job = Self.job("queued", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        #expect(await coordinator.snapshot(job.id)?.held == 1)

        clock.set(Self.at(4))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])
        #expect(await coordinator.snapshot(job.id)?.fireOutstanding == true,
                "the queued fire is still this coordinator's, until the runner takes it")

        #expect(await coordinator.takeHeldPaths(job.id) == ["/r/a.txt", "/r/b.txt"])
        let after = try #require(await coordinator.snapshot(job.id))
        #expect(after.held == 0)
        #expect(after.pending == 0)
        #expect(after.fireOutstanding == false, "taking the paths is what ends the fire")
    }

    /// R-D4-2. Re-asking writes no row for a watcher origin, but it costs two ledger sums each
    /// time, so the interval is the ceiling rather than the window: at the default that is one ask
    /// per thirty seconds for the length of a human-started run, not one per three.
    @Test("a skipped fire re-asks once per ceiling, not once per window")
    func skipInFlightReAsksOncePerCeiling() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.skipInFlight, .skipInFlight, .run])
        let job = Self.job("skipper", root: "/r", overlap: .skip)
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        // The re-ask is due one ceiling after the burst began, and `nextDeadline` says so the
        // moment the admission is applied — which is the sync point the rest of this test needs.
        await Self.eventually("the skip to be applied") { await coordinator.nextDeadline() == Self.at(30) }

        // A window later, and two windows later: nothing. This is the whole point of the ruling.
        for second in [3.0, 6.0] {
            clock.set(Self.at(second))
            await coordinator.tick(now: Self.at(second))
            #expect(await recorder.count == 1, "no second ask at +\(second)")
        }

        // More changes arrive during the run; they join the held set rather than a new burst.
        clock.set(Self.at(10))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])
        #expect(await coordinator.snapshot(job.id)?.pending == 0, "nothing accumulates outside the hold")

        clock.set(Self.at(30))
        await coordinator.tick(now: Self.at(30))
        await recorder.waitFor(2)
        #expect(await recorder.count == 2, "the ceiling, not the window, is what re-asks")
        #expect(await coordinator.snapshot(job.id)?.held == 2)
        await Self.eventually("the second skip to be applied") {
            await coordinator.nextDeadline() == Self.at(60)
        }

        clock.set(Self.at(60))
        await coordinator.tick(now: Self.at(60))
        await recorder.waitFor(3)
        #expect(await recorder.count == 3)
        #expect(await recorder.paths.last == ["/r/a.txt", "/r/b.txt"], "the whole held set")
        await Self.eventually("the run to be applied") {
            await coordinator.snapshot(job.id)?.fireOutstanding == false
        }
        #expect(await coordinator.snapshot(job.id)?.held == 0)
    }

    @Test("any other refusal drops the held paths")
    func otherRefusalsDropHeldPaths() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.pauseBreaker(count: 6)])
        let job = Self.job("breaker", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        await Self.eventually("the refusal to be applied") {
            await coordinator.snapshot(job.id)?.fireOutstanding == false
        }
        let snapshot = try #require(await coordinator.snapshot(job.id))
        #expect(snapshot.held == 0, "a refused job will not be admitted a moment later")
        #expect(snapshot.pending == 0)
        #expect(snapshot.burstBegan == nil)
    }

    @Test("a handler that answers nil takes the subscriber with it")
    func nilDropsTheSubscriber() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([nil])
        let job = Self.job("gone", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        await Self.eventually("the subscriber to be dropped") { await coordinator.snapshot(job.id) == nil }
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == nil)
    }

    // MARK: sync

    @Test("a re-registration keeps what a watch has absorbed; a pause takes the subscriber away")
    func syncKeepsAbsorbedAcrossReRegistrationAndRemovesAPausedJob() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        var moved = Self.job("moved", root: "/r")
        var paused = Self.job("paused", root: "/r")
        try store.ledger.upsert(moved)
        try store.ledger.upsert(paused)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [moved, paused])

        await coordinator.deliver(root: "/r", paths: ["/r/.DS_Store", "/r/a.txt"])
        #expect(await coordinator.snapshot(moved.id)?.pending == 1)

        // Re-registered onto another path: the burst is gone, the tally of what this watch has
        // absorbed is not — it is the answer to "why does this watch never fire".
        moved.trigger = .fsEvent(FSWatch(path: "/r2", quietWindowSeconds: 3))
        paused.pausedReason = "by hand"
        await coordinator.sync(with: [moved, paused])

        let after = try #require(await coordinator.snapshot(moved.id))
        #expect(after.pending == 0)
        #expect(after.burstBegan == nil)
        #expect(await coordinator.absorbedSinceLaunch()[moved.id] == AbsorbedCounts(noise: 1))
        #expect(await coordinator.snapshot(paused.id) == nil)
        #expect(await coordinator.absorbedSinceLaunch()[paused.id] == nil,
                "/jobs has nothing to show a removed subscriber's counts against")

        // And the new root is the one that is served now.
        clock.set(Self.at(1))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])
        #expect(await coordinator.snapshot(moved.id)?.pending == 0)
        await coordinator.deliver(root: "/r2", paths: ["/r2/b.txt"])
        #expect(await coordinator.snapshot(moved.id)?.pending == 1)
    }

    @Test("an overlap edit to skip while a fire is queued releases the hold rather than losing it")
    func anOverlapEditFromQueueToSkipReleasesTheHold() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.queued])
        var job = Self.job("switcher", root: "/r", overlap: .queue)
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        #expect(await coordinator.snapshot(job.id)?.held == 1)

        // The runner will discard the queued fire it was holding, so nobody else would ever come
        // for these paths. The edit is re-applied until it takes: `sync` is idempotent, and the
        // release can only happen once the handler's `.queued` has come back — which is a task of
        // its own, by design.
        clock.set(Self.at(5))
        job.policy.overlap = .skip
        try store.ledger.upsert(job)
        let edited = job
        await Self.eventually("the overlap edit to release the hold") {
            await coordinator.sync(with: [edited])
            return await coordinator.snapshot(edited.id)?.pending == 1
        }

        let snapshot = try #require(await coordinator.snapshot(job.id))
        #expect(snapshot.held == 0)
        #expect(snapshot.pending == 1)
        #expect(snapshot.fireOutstanding == false)
        #expect(snapshot.burstBegan == Self.at(5), "a fresh burst, from the edit")

        clock.set(Self.at(8))
        await coordinator.tick(now: Self.at(8))
        await recorder.waitFor(2)
        #expect(await recorder.paths.last == ["/r/a.txt"])
        #expect(await recorder.summaries.last?.changed == 1)
    }

    // MARK: Firing against the ledger

    @Test("a row that went paused between the burst and the tick drops it into whilePaused")
    func aPausedRowDropsTheBurstIntoWhilePaused() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("pausing", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt", "/r/b.txt"])
        try store.ledger.setPaused(jobId: job.id, reason: "breaker: 6 runs in the last hour")
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))

        #expect(await recorder.count == 0, "a paused job's burst never reaches a handler")
        let snapshot = try #require(await coordinator.snapshot(job.id))
        #expect(snapshot.pending == 0)
        #expect(snapshot.burstBegan == nil)
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(whilePaused: 2))
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty, "a pause writes no row here")
    }

    @Test("a ledger read that fails writes a failed row rather than firing without the filter")
    func aLedgerReadFailureWritesAFailedRow() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("unreadable", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])
        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])

        // The `jobs` table goes out from under the read — the shape of a database error the fire
        // cannot see past. The run rows still land, which is the half under test: a fire the
        // coordinator cannot check is never a fire, and never silent either.
        try await store.writer.write { db in try db.execute(sql: "ALTER TABLE jobs RENAME TO jobs_moved") }
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))

        #expect(await recorder.count == 0, "never a fire with the filter bypassed")
        let runs = try store.ledger.runs(jobId: job.id, limit: 5)
        #expect(runs.count == 1)
        #expect(runs.first?.status == .interrupted)
        #expect(runs.first?.failureReason?.hasPrefix("watch fire dropped: ") == true,
                "got: \(String(describing: runs.first?.failureReason))")
        #expect(runs.first?.triggerKind == Trigger.fsEventKind)
        #expect(await coordinator.snapshot(job.id)?.pending == 0, "the burst is dropped, not retried")
    }

    // MARK: Bounds

    @Test("fifteen hundred paths keep a thousand and count the rest")
    func fifteenHundredPathsKeepAThousand() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("flood", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: (0..<1500).map { "/r/f\($0).txt" })
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)

        let fire = try #require(await recorder.fires.first?.fire)
        #expect(fire.paths.count == WatchCoordinator.maxTrackedPaths)
        #expect(fire.summary.changed == 1500, "the row and the card report the true figure")
        #expect(fire.summary.overflow == 500)
        #expect(fire.summary.coalesced == 1500)
        #expect(fire.summary.delivered == WatchCoordinator.maxDeliveredPaths)
    }

    @Test("a long gap — a sleep, a stalled loop — is still one fire")
    func aSimulatedLongGapFiresOnce() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("sleepy", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3600))
        await coordinator.tick(now: Self.at(3600))
        await recorder.waitFor(1)

        #expect(await recorder.count == 1)
        #expect(await recorder.fires.first?.fire.summary.ceilingFired == true,
                "the gap swallowed the ceiling as well as the window")
        await Self.eventually("the run to be applied") {
            await coordinator.snapshot(job.id)?.fireOutstanding == false
        }
        await coordinator.tick(now: Self.at(7200))
        #expect(await recorder.count == 1, "and nothing fires a second time on the same burst")
    }
}
