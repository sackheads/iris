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
        init(_ script: [JobRunner.Admission?] = [], fallback: JobRunner.Admission? = .run) {
            self.script = script
            self.fallback = fallback
        }

        func record(_ job: Job, _ fire: WatchFire) -> JobRunner.Admission? {
            fires.append((job, fire))
            return script.isEmpty ? fallback : script.removeFirst()
        }

        var count: Int { fires.count }
        var paths: [[String]] { fires.map(\.fire.paths) }
        var summaries: [WatchSummary] { fires.map(\.fire.summary) }

        /// Waits until at least `n` fires have been handed over, or five seconds pass — the same
        /// bounded shape as `eventually`, and for the same reason.
        ///
        /// The deadline is the point. An unbounded continuation turns a timing regression into a
        /// hung `swift test`: a mutation of `ceilingMultiplier` left two tests here running for
        /// four minutes instead of failing, and in CI that is a job timeout naming no test at all.
        /// With the deadline, a coordinator that stops firing fails on the assertion that follows,
        /// with the count it actually reached.
        func waitFor(_ n: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
            for _ in 0..<500 {
                if fires.count >= n { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("waited 5s for \(n) fires and saw \(fires.count)",
                         sourceLocation: sourceLocation)
        }
    }

    /// A one-shot rendezvous, so a test can hold one subscriber's handler open while the loop
    /// keeps serving the others.
    actor Gate {
        private var entered = false
        private var opened = false
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        /// Bounded, for `waitFor`'s reason: a regression that stops the fire being dispatched
        /// should fail the test that waited, naming what it waited for, rather than park it
        /// forever and turn `swift test` into a CI timeout with no test named.
        func waitForEntry(sourceLocation: SourceLocation = #_sourceLocation) async {
            for _ in 0..<500 {
                if entered { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("waited 5s for a handler to enter the gate", sourceLocation: sourceLocation)
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

        // The batch accepts `a.swift`, so both of its absorbed events belong to the burst that
        // acceptance began — wherever in the batch they happened to sit (R-D4-6).
        await coordinator.deliver(root: "/r",
                                  paths: ["/r/.DS_Store", "/r/a.swift", "/r/summary.md"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)

        let fire = try #require(await recorder.fires.first?.fire)
        #expect(fire.paths == ["/r/a.swift"])
        #expect(fire.summary.changed == 1)
        #expect(fire.summary.coalesced == 1)
        #expect(fire.summary.noise == 1)
        #expect(fire.summary.ownWrites == 1)
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(noise: 1, ownWrites: 1),
                "since launch counts both, burst or no burst")
    }

    /// R-D4-6. §6's card says "40 changed, 12 noise absorbed"; which of the two counters an
    /// absorbed event lands in must not depend on where FSEvents happened to put it inside one
    /// callback, because that is an ordering no user can see, reproduce or reason about.
    @Test("an absorbed event is attributed by its batch, not by its position in it")
    func absorbedAttributionIsPerBatchNotPerPosition() async throws {
        for order in [["/r/.DS_Store", "/r/a.swift"], ["/r/a.swift", "/r/.DS_Store"]] {
            let store = try ConversationStore.inMemory()
            let clock = Clock(Self.t0)
            let recorder = Recorder()
            let job = Self.job("ordering", root: "/r")
            try store.ledger.upsert(job)
            let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                               writes: RecentWrites(now: { clock.now }), recorder: recorder)
            await coordinator.sync(with: [job])

            await coordinator.deliver(root: "/r", paths: order)
            clock.set(Self.at(3))
            await coordinator.tick(now: Self.at(3))
            await recorder.waitFor(1)

            let fire = try #require(await recorder.fires.first?.fire)
            #expect(fire.paths == ["/r/a.swift"], "order: \(order)")
            #expect(fire.summary.noise == 1, "the batch accepted a path, so its noise is this burst's: \(order)")
            #expect(fire.summary.changed == 1, "order: \(order)")
            #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(noise: 1),
                    "since launch counts it either way: \(order)")
        }
    }

    @Test("a batch that accepts nothing at all counts only since launch")
    func aFullyAbsorbedBatchCountsOnlySinceLaunch() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("allnoise", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/.DS_Store", "/r/x.tmp"])
        // A burst that starts afterwards reports its own noise and not the earlier batch's.
        clock.set(Self.at(1))
        await coordinator.deliver(root: "/r", paths: ["/r/a.swift", "/r/b~"])
        clock.set(Self.at(4))
        await coordinator.tick(now: Self.at(4))
        await recorder.waitFor(1)

        let fire = try #require(await recorder.fires.first?.fire)
        #expect(fire.summary.noise == 1, "only the batch that accepted something")
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(noise: 3))
    }

    /// R-D4-7. `realpath` is not case-normalising — measured on APFS, `/tmp/CaseProbe` resolves to
    /// `/private/tmp/CaseProbe` and keeps the caller's spelling — so a root registered with the
    /// user's casing and events reported with the disk's would never meet.
    @Test("a mis-cased root still covers its events, and the event keeps its own spelling")
    func aMisCasedRootStillCoversItsEvents() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("cased", root: "/r/NOTES", ignore: ["Drafts/"])
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r/NOTES", paths: ["/r/notes/a.swift",
                                                            "/r/Notes/.ds_store",
                                                            "/r/notes/drafts/b.md"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)

        let fire = try #require(await recorder.fires.first?.fire)
        #expect(fire.paths == ["/r/notes/a.swift"], "the event's own spelling, not the root's")
        #expect(fire.summary.noise == 2, "the built-in set and the watch's own glob fold case too")
        #expect(await coordinator.snapshot(job.id) != nil)
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
        // Counted in both, which is what says the `/private` spelling reached the registry entry
        // the write recorded: the batch accepted the modify, so its absorbed delete is this
        // burst's as well as the running total's (R-D4-6).
        #expect(fire.summary.ownWrites == 1, "the delete matched the registry entry recorded for it")
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

    /// F2. The admission is applied by fire *identity*, not by job id. A handler still inside its
    /// run when `sync` re-registers the job onto another root is answering a fire that no longer
    /// exists; without the identity check its `.run` subtracts its own paths from the newer fire's
    /// hold, clears the newer fire's `fireOutstanding` and pushes that hold back into `pending` —
    /// so the newer paths get a second run and "at most one fire outstanding" is broken by the one
    /// code path that exists to keep it.
    @Test("a stale admission never lands on the fire that replaced it", .timeLimit(.minutes(1)))
    func aStaleAdmissionNeverLandsOnANewerFire() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        // Fire #1 answers `.run` (late, from inside the gate); fire #2 answers `.queued`, so it is
        // still outstanding and still holding its paths when the stale answer arrives.
        let recorder = Recorder([.run, .queued])
        let gate = Gate()
        var job = Self.job("moving", root: "/old")
        try store.ledger.upsert(job)
        let coordinator = WatchCoordinator(
            ledger: store.ledger, now: { clock.now }, recentWrites: RecentWrites(now: { clock.now }),
            fire: { j, f in
                let admission = await recorder.record(j, f)
                if f.paths.first?.hasPrefix("/old") == true { await gate.arriveAndWait() }
                return admission
            })
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/old", paths: ["/old/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await gate.waitForEntry()

        // Re-registered onto another root while handler #1 is still inside its run.
        clock.set(Self.at(4))
        job.trigger = .fsEvent(FSWatch(path: "/new", quietWindowSeconds: 3))
        try store.ledger.upsert(job)
        await coordinator.sync(with: [job])
        let jobId = job.id
        #expect(await coordinator.snapshot(jobId)?.fireOutstanding == false)

        // A second fire goes out for the new root and is queued behind a run.
        await coordinator.deliver(root: "/new", paths: ["/new/b.txt", "/new/c.txt"])
        clock.set(Self.at(8))
        await coordinator.tick(now: Self.at(8))
        await recorder.waitFor(2)
        #expect(await recorder.paths.last == ["/new/b.txt", "/new/c.txt"])

        // Now handler #1 answers `.run` for a fire that no longer exists.
        await gate.open()
        // It arrives on a task of its own; give it every chance to land on the wrong subscriber.
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = try #require(await coordinator.snapshot(jobId))
        #expect(snapshot.fireOutstanding == true, "the newer fire is still the runner's to answer")
        #expect(snapshot.outstanding == 2, "the stale `.run` did not spend the newer fire's paths")
        #expect(snapshot.pending == 0, "nor re-queue them as a fresh burst")
        #expect(snapshot.burstBegan == nil)

        // And no tick can turn them into a second run for the same paths.
        clock.set(Self.at(40))
        await coordinator.tick(now: Self.at(40))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.count == 2, "no third fire for paths a run already has")
        #expect(await coordinator.takeHeldPaths(jobId).paths == ["/new/b.txt", "/new/c.txt"],
                "the runner's held re-fire still finds them")
    }

    /// RR1-F1. The same stale-admission failure through a third door: a pause removes the
    /// subscriber outright and the resume builds a fresh one. A counter living on the `Subscriber`
    /// struct restarts at 0 there, so the handler parked across the pause comes back holding a
    /// number the *new* subscriber has since reissued — and its `.run` spends the newer fire's
    /// hold. Pausing a noisy watch and resuming it while its run is going is an ordinary thing to
    /// do, which is why the identity has to outlive the struct that issued it.
    @Test("a handler parked across a pause and a resume cannot spend the newer fire's hold",
          .timeLimit(.minutes(1)))
    func aStaleAdmissionSurvivesNeitherAPauseNorAResume() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        // Fire #1 answers `.run` from inside the gate; fire #2 answers `.queued`, so it is still
        // outstanding and still holding its paths when the stale answer arrives.
        let recorder = Recorder([.run, .queued])
        let gate = Gate()
        var job = Self.job("paused-mid-run", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = WatchCoordinator(
            ledger: store.ledger, now: { clock.now }, recentWrites: RecentWrites(now: { clock.now }),
            fire: { j, f in
                let admission = await recorder.record(j, f)
                if f.paths == ["/r/a.txt"] { await gate.arriveAndWait() }
                return admission
            })
        await coordinator.sync(with: [job])
        let jobId = job.id

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await gate.waitForEntry()

        // Paused while the run is going: `sync` takes the subscriber away entirely.
        clock.set(Self.at(4))
        job.pausedReason = "by hand"
        try store.ledger.setPaused(jobId: jobId, reason: "by hand")
        await coordinator.sync(with: [job])
        #expect(await coordinator.snapshot(jobId) == nil)

        // Resumed: a brand-new subscriber, which is where a per-subscriber counter would restart.
        clock.set(Self.at(5))
        job.pausedReason = nil
        try store.ledger.setPaused(jobId: jobId, reason: nil)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/b.txt", "/r/c.txt"])
        clock.set(Self.at(9))
        await coordinator.tick(now: Self.at(9))
        await recorder.waitFor(2)
        #expect(await recorder.paths.last == ["/r/b.txt", "/r/c.txt"])

        // Handler #1 finally answers, for a fire two subscribers ago.
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = try #require(await coordinator.snapshot(jobId))
        #expect(snapshot.fireOutstanding == true, "the newer fire is still the runner's to answer")
        #expect(snapshot.outstanding == 2, "the stale `.run` did not spend the newer fire's paths")
        #expect(snapshot.pending == 0, "nor re-queue them as a fresh burst")
        #expect(snapshot.burstBegan == nil)

        clock.set(Self.at(40))
        await coordinator.tick(now: Self.at(40))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.count == 2, "no third fire for paths a run already has")
    }

    // MARK: The five admissions

    @Test("a run spends the paths it was given and leaves everything accepted since",
          .timeLimit(.minutes(1)))
    func runSpendsOnlyTheFiredPaths() async throws {
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
        let during = try #require(await coordinator.snapshot(job.id))
        #expect(during.outstanding == 1, "a is the fire's until the handler returns")
        #expect(during.held == 1, "and b is the hold's")

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

    /// F5. Noise and own writes absorbed while a fire is out bump the burst counters (R-D4-6)
    /// without putting anything in the hold. When nothing else arrives there is no new burst to
    /// carry them, so they have to be zeroed when the run ends or the *next* burst's summary
    /// reports them a second time. (A re-save of the fired path is not this case since R-D4-10:
    /// it is an arrival, and the burst it begins carries the counters — see
    /// `aFiredPathSavedAgainDuringItsRunFiresAgain`.)
    @Test("a run whose hold stays empty leaves no counters behind for the next burst",
          .timeLimit(.minutes(1)))
    func aRunWithAnEmptyHoldZeroesTheCounters() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let gate = Gate()
        let job = Self.job("leaky", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = WatchCoordinator(
            ledger: store.ledger, now: { clock.now }, recentWrites: RecentWrites(now: { clock.now }),
            fire: { j, f in
                let admission = await recorder.record(j, f)
                if f.paths == ["/r/a.txt"] { await gate.arriveAndWait() }
                return admission
            })
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await gate.waitForEntry()

        // During the run: nothing but noise. It is counted in the burst (the fire is out) and
        // nothing of it survives into a new burst, because there is no arrival to begin one.
        clock.set(Self.at(4))
        await coordinator.deliver(root: "/r", paths: ["/r/.DS_Store", "/r/x.tmp"])
        clock.set(Self.at(5))
        await gate.open()
        await Self.eventually("the run to be applied") {
            await coordinator.snapshot(job.id)?.fireOutstanding == false
        }
        #expect(await coordinator.snapshot(job.id)?.pending == 0, "nothing arrived, so no new burst")

        // The next burst reports itself and nothing else.
        clock.set(Self.at(10))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])
        clock.set(Self.at(13))
        await coordinator.tick(now: Self.at(13))
        await recorder.waitFor(2)

        let second = try #require(await recorder.fires.last?.fire)
        #expect(second.summary.changed == 1)
        #expect(second.summary.coalesced == 1)
        #expect(second.summary.noise == 0, "the noise during the run belonged to the run")
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(noise: 2),
                "the running total still has it")
    }

    /// H1 / R-D4-10. The most ordinary thing a person does while trying a watch: save the file,
    /// see the run start, save it again. The run may have read the file before the second save,
    /// so that save is a change the run did not see — a new arrival, carried to the next burst
    /// and counted — and not a coalesced repeat of the one it did. Before the ruling the fired
    /// paths sat in `heldPaths` for the length of the run, the re-save was indistinguishable from
    /// a repeat, and `.run` erased it: no second fire, no count, nothing on any row.
    @Test("a fired path saved again during its own run fires again", .timeLimit(.minutes(1)))
    func aFiredPathSavedAgainDuringItsRunFiresAgain() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let gate = Gate()
        let job = Self.job("resave", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = WatchCoordinator(
            ledger: store.ledger, now: { clock.now }, recentWrites: RecentWrites(now: { clock.now }),
            fire: { j, f in
                let admission = await recorder.record(j, f)
                // Only the first fire parks: the second carries the same path.
                if await recorder.count == 1 { await gate.arriveAndWait() }
                return admission
            })
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await gate.waitForEntry()
        #expect(await recorder.paths == [["/r/a.txt"]])

        // The same file, saved again while the run is going.
        clock.set(Self.at(20))
        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        let during = try #require(await coordinator.snapshot(job.id))
        #expect(during.outstanding == 1, "the run's `a` is on the fire")
        #expect(during.held == 1, "and the re-saved `a` is a new arrival in the hold")

        clock.set(Self.at(43))
        await gate.open()
        await Self.eventually("the run to be applied") {
            await coordinator.snapshot(job.id)?.fireOutstanding == false
        }
        let after = try #require(await coordinator.snapshot(job.id))
        #expect(after.pending == 1, "the re-save begins the next burst")
        #expect(after.held == 0)
        #expect(after.burstBegan == Self.at(43), "from the end of the run")

        clock.set(Self.at(46))
        await coordinator.tick(now: Self.at(46))
        await recorder.waitFor(2)
        let second = try #require(await recorder.fires.last?.fire)
        #expect(second.paths == ["/r/a.txt"])
        #expect(second.summary.changed == 1)
        #expect(second.summary.coalesced == 1)
        #expect(second.summary.delivered == 1)
    }

    /// The same re-save under `queue`: the held re-fire names the file once and counts it once
    /// in `changed` (R-D4-12) — it is one changed file, however many times it was saved — while
    /// `coalesced` keeps both events (R-D4-10).
    @Test("a fired path saved again while its fire is queued is taken once, and counted")
    func aFiredPathSavedAgainWhileQueuedIsTakenOnceAndCounted() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.queued])
        let job = Self.job("requeued", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)

        clock.set(Self.at(4))
        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        let taken = await coordinator.takeHeldPaths(job.id)
        #expect(taken.paths == ["/r/a.txt"], "once: the prompt names the file, not two copies of it")
        #expect(taken.summary?.changed == 1, "one file, however many saves: never `2 changed, 1 delivered`")
        #expect(taken.summary?.coalesced == 2, "the event count keeps both saves")
        #expect(await coordinator.snapshot(job.id)?.outstanding == 0, "taking the paths ends the fire")
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
        #expect(await coordinator.snapshot(job.id)?.outstanding == 1)
        #expect(await coordinator.snapshot(job.id)?.held == 0, "the fired path is the fire's, not the hold's")

        clock.set(Self.at(4))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt", "/r/.DS_Store"])
        #expect(await coordinator.snapshot(job.id)?.held == 1)
        #expect(await coordinator.snapshot(job.id)?.fireOutstanding == true,
                "the queued fire is still this coordinator's, until the runner takes it")

        // R-D4-9: the counts go with the paths, the queued fire's own included. A `.queued`
        // admission writes no row, so the first fire's arithmetic has never been reported
        // anywhere — dropping it here would leave the burst on no row at all.
        let taken = await coordinator.takeHeldPaths(job.id)
        #expect(taken.paths == ["/r/a.txt", "/r/b.txt"])
        #expect(taken.summary == WatchSummary(delivered: 0, changed: 2, overflow: 0, coalesced: 2,
                                              noise: 1, ownWrites: 0, ceilingFired: false,
                                              pathsWithheld: false),
                "the queued fire's summary plus everything accepted or absorbed since")
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
        #expect(await recorder.paths.last == ["/r/a.txt", "/r/b.txt"], "the fire's path and the hold's")
        let reAsked = try #require(await coordinator.snapshot(job.id))
        #expect(reAsked.outstanding == 2, "the offer took over the hold")
        #expect(reAsked.held == 0)
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

    /// R-D4-12's `skip` mirror: the ceiling re-ask merges the fire and the hold the same way the
    /// held re-fire does, so a fired file saved again during the skip is offered once and counted
    /// once in `changed`, with `coalesced` keeping both saves.
    @Test("a re-ask names a fired path saved again once, and counts it once")
    func aReAskCountsAReSavedFiredPathOnce() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.skipInFlight, .skipInFlight])
        let job = Self.job("reskipper", root: "/r", overlap: .skip)
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        await Self.eventually("the skip to be applied") { await coordinator.nextDeadline() == Self.at(30) }

        // The fired file, saved again while the run it was refused for is still going.
        clock.set(Self.at(10))
        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        #expect(await coordinator.snapshot(job.id)?.held == 1, "a new arrival, not a repeat")

        clock.set(Self.at(30))
        await coordinator.tick(now: Self.at(30))
        await recorder.waitFor(2)
        let offer = try #require(await recorder.fires.last?.fire)
        #expect(offer.paths == ["/r/a.txt"], "named once")
        #expect(offer.summary.changed == 1, "one changed file")
        #expect(offer.summary.coalesced == 2, "two saves")
        #expect(offer.summary.delivered == 1)
        #expect(offer.summary.overflow == 0)
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

    /// R-D4-11. `nil` is what the runner answers when the row is gone — and the row *is* gone
    /// here, deleted inside the fire — so the subscriber goes with it and nothing is written.
    @Test("a nil admission for a job that is gone from the ledger takes the subscriber with it")
    func nilForAGoneJobDropsTheSubscriber() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([nil])
        let job = Self.job("gone", root: "/r")
        try store.ledger.upsert(job)
        let ledger = store.ledger
        let coordinator = WatchCoordinator(
            ledger: ledger, now: { clock.now }, recentWrites: RecentWrites(now: { clock.now }),
            fire: { j, f in
                try? ledger.delete(jobId: j.id)
                return await recorder.record(j, f)
            })
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        await Self.eventually("the subscriber to be dropped") { await coordinator.snapshot(job.id) == nil }
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty, "nothing left to write a row against")
    }

    /// R-D4-11. The other `nil`: the runner's own read of a row that is still there failed — a
    /// transient ledger error a few microseconds after the coordinator's read succeeded, or the
    /// runner itself gone. That is §7's read failure during a fire, and its fail direction is a
    /// dropped burst with a row naming it, never a dropped subscriber: the watch stays alive and
    /// the next burst tries again.
    @Test("a nil admission for a job still in the ledger is a refusal with a row, not a vanished watch")
    func nilForAJobStillInTheLedgerWritesARowAndKeepsTheSubscriber() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([nil])
        let job = Self.job("unreadable", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt", "/r/.DS_Store"])
        clock.set(Self.at(3))
        await coordinator.tick(now: Self.at(3))
        await recorder.waitFor(1)
        await Self.eventually("the refusal to be applied") {
            await coordinator.snapshot(job.id)?.fireOutstanding == false
        }

        let snapshot = try #require(await coordinator.snapshot(job.id), "the subscriber survives")
        #expect(snapshot.pending == 0, "the burst is dropped, not retried")
        #expect(snapshot.held == 0)
        #expect(snapshot.outstanding == 0)
        #expect(await coordinator.absorbedSinceLaunch()[job.id] == AbsorbedCounts(noise: 1),
                "and keeps its running total")
        let runs = try store.ledger.runs(jobId: job.id, limit: 5)
        #expect(runs.count == 1, "never a silent drop")
        #expect(runs.first?.status == .interrupted)
        #expect(runs.first?.failureReason == "watch fire dropped: the runner could not read the job")
        #expect(runs.first?.triggerKind == Trigger.fsEventKind)

        // The watch is alive: the next burst fires.
        clock.set(Self.at(10))
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])
        clock.set(Self.at(13))
        await coordinator.tick(now: Self.at(13))
        await recorder.waitFor(2)
        #expect(await recorder.paths.last == ["/r/b.txt"])
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
        #expect(await coordinator.snapshot(job.id)?.outstanding == 1)

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

    // MARK: The production loop

    /// The injected sleep. Short waits move the clock and return; the idle 60 s wait parks until
    /// the loop cancels it, which is what a wake looks like from here.
    actor Sleeps {
        private let clock: Clock
        private(set) var requested: [TimeInterval] = []
        init(clock: Clock) { self.clock = clock }

        func wait(_ seconds: TimeInterval) async {
            requested.append(seconds)
            guard seconds < 30 else {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return
            }
            clock.set(clock.now.addingTimeInterval(seconds))
        }

        var parkedOnTheIdleWait: Bool { requested.contains { $0 >= 30 } }
        var shortWaits: [TimeInterval] { requested.filter { $0 < 30 } }
    }

    @Test("an accepted event wakes the loop instead of waiting out the idle sleep")
    func theLoopIsWokenByAnAcceptedEvent() async throws {
        // F3. `nextDeadline()` is read before the sleep, so a watch that has been quiet is parked
        // on a 60 s wait when the first save of a burst lands. Without a wake, its 3 s window
        // expires unnoticed and the run happens up to a minute late — §2 promises the loop sleeps
        // to the earliest deadline or until woken, an accepted event being the first source of a
        // wake. This test drives the
        // loop, not `tick`: `tick` is the unit seam and cannot see the bug.
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("notes", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        let sleeps = Sleeps(clock: clock)
        await coordinator.startLoop(everyMinute: {}, sleep: { await sleeps.wait($0) })
        await Self.eventually("the loop to park on its idle wait") { await sleeps.parkedOnTheIdleWait }

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])

        await recorder.waitFor(1)
        #expect(await recorder.paths == [["/r/a.txt"]])
        #expect(await sleeps.shortWaits.contains { $0 > 2.9 && $0 <= 3.0 } == true,
                "woken, the loop sleeps to the window's deadline rather than to the minute")
        await coordinator.stopLoop()
    }

    @Test("a path saved during its own run fires one window after the run, not on the minute wake")
    func theLoopIsWokenWhenARunEndsWithAHold() async throws {
        // Found on screen: a file saved while its watch's run was in flight ran again 62 s later
        // with `ceilingFired` set. The save is accepted into the hold while the fire is out, so it
        // wakes the loop to a no-op `tick`; the burst it belongs to only begins when the handler
        // returns `.run`, and that return happened with the loop parked on its 60 s wait. Nothing
        // woke it, so the window expired unnoticed and the minute wake fired the burst late — and
        // past its ceiling, so the row blamed a save that never stopped. As above, this drives the
        // loop: `tick` cannot see a missing wake.
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let gate = Gate()
        let job = Self.job("notes", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = WatchCoordinator(ledger: store.ledger, now: { clock.now },
                                           recentWrites: RecentWrites(now: { clock.now }),
                                           fire: { job, fire in
            // The first fire is the run; it stays open until the test lets it return.
            if await recorder.count == 0 { await gate.arriveAndWait() }
            return await recorder.record(job, fire)
        })
        await coordinator.sync(with: [job])

        let sleeps = Sleeps(clock: clock)
        await coordinator.startLoop(everyMinute: {}, sleep: { await sleeps.wait($0) })
        await Self.eventually("the loop to park on its idle wait") { await sleeps.parkedOnTheIdleWait }

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        await gate.waitForEntry()
        // Saved again mid-run: held, and the loop is back on its idle wait.
        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        await Self.eventually("the loop to park again behind the outstanding fire") {
            // Idle wait #1 is the start, #2 follows the fire (a fire leaves no deadline), #3 follows
            // the held save's no-op tick — so #3 is the one that says the loop is parked again.
            await sleeps.requested.filter { $0 >= 30 }.count >= 3
        }

        await gate.open()

        await recorder.waitFor(2)
        #expect(await recorder.paths == [["/r/a.txt"], ["/r/a.txt"]])
        #expect(await recorder.summaries.last?.ceilingFired == false,
                "one window after the run ended, not a minute later and past the ceiling")
        #expect(await sleeps.shortWaits.filter { $0 > 2.9 && $0 <= 3.0 }.count == 2,
                "the run's end woke the loop to the new burst's window")
        await coordinator.stopLoop()
    }

    @Test("a burst released by a queue-to-skip edit fires one window later, not on the minute wake")
    func theLoopIsWokenWhenSyncReleasesAQueuedHold() async throws {
        // The third source of a deadline, after an accept and an admission: `sync` releasing a
        // `.queued` fire's paths into a fresh burst when the job's overlap is edited from `queue`
        // to `skip`. The loop is parked on its 60 s wait at that moment (a queued fire leaves
        // `nextDeadline()` nil), so without a wake the released window expires unnoticed.
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder([.queued])
        var job = Self.job("notes", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        let sleeps = Sleeps(clock: clock)
        await coordinator.startLoop(everyMinute: {}, sleep: { await sleeps.wait($0) })
        await Self.eventually("the loop to park on its idle wait") { await sleeps.parkedOnTheIdleWait }

        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        await recorder.waitFor(1)
        await Self.eventually("the loop to park behind the queued fire") {
            await sleeps.requested.filter { $0 >= 30 }.count >= 2
        }
        await coordinator.deliver(root: "/r", paths: ["/r/b.txt"])   // held behind the queued fire
        await Self.eventually("the loop to park again after the held save") {
            await sleeps.requested.filter { $0 >= 30 }.count >= 3
        }

        job.policy.overlap = .skip
        try store.ledger.upsert(job)
        await coordinator.sync(with: [job])

        await recorder.waitFor(2)
        #expect(await recorder.paths.last == ["/r/a.txt", "/r/b.txt"])
        #expect(await recorder.summaries.last?.ceilingFired == false)
        #expect(await sleeps.shortWaits.filter { $0 > 2.9 && $0 <= 3.0 }.count == 2,
                "the release woke the loop to the new burst's window")
        await coordinator.stopLoop()
    }

    @Test("stopping the loop releases it even while it is parked on a wait")
    func stopLoopReleasesAParkedLoop() async throws {
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        let sleeps = Sleeps(clock: clock)
        await coordinator.startLoop(everyMinute: {}, sleep: { await sleeps.wait($0) })
        await Self.eventually("the loop to park on its idle wait") { await sleeps.parkedOnTheIdleWait }

        await coordinator.stopLoop()
        // A second `startLoop` proves the first one let go of the slot rather than leaving a task
        // parked on a continuation nobody will resume.
        await coordinator.startLoop(everyMinute: {}, sleep: { await sleeps.wait($0) })
        await Self.eventually("the new loop to park in turn") { await sleeps.requested.count >= 2 }
        await coordinator.stopLoop()
    }

    @Test("takeHeldPaths answers nil when nobody counted, not a summary of zeroes")
    func takeHeldPathsSummaryIsNilWithoutAFire() async throws {
        // The row's column is nullable for this exact distinction: "the burst saw nothing" and
        // "no coordinator was counting" are different facts, and only the second is a null.
        let store = try ConversationStore.inMemory()
        let clock = Clock(Self.t0)
        let recorder = Recorder()
        let job = Self.job("notes", root: "/r")
        try store.ledger.upsert(job)
        let coordinator = Self.coordinator(ledger: store.ledger, clock: clock,
                                           writes: RecentWrites(now: { clock.now }), recorder: recorder)
        await coordinator.sync(with: [job])

        // No subscriber at all.
        let unknown = await coordinator.takeHeldPaths(UUID())
        #expect(unknown.paths.isEmpty)
        #expect(unknown.summary == nil)

        // A subscriber mid-burst, but no fire outstanding: the paths are owed to the re-fire, the
        // arithmetic belongs to the fire that never happened.
        await coordinator.deliver(root: "/r", paths: ["/r/a.txt"])
        let quiet = await coordinator.takeHeldPaths(job.id)
        #expect(quiet.paths == ["/r/a.txt"])
        #expect(quiet.summary == nil)
    }
}
