import Testing
import Foundation
@testable import iris

/// #187 deliverable 4, spec §7 — the manager as a stream owner keyed by root.
///
/// No test here touches FSEvents, `WatcherManager.shared`, or a directory on disk: the stream
/// factory is a fake that records the roots it was asked for and hands the test each continuation,
/// and existence is a closure over a set of paths (invariant 7). What a batch turns into is the
/// coordinator's business and is tested there; all that matters here is which streams exist, which
/// root each batch is tagged with, and what happens when a root goes away.
@Suite("Watcher manager sync (#187)")
struct WatcherManagerSyncTests {

    // MARK: Fixtures

    /// The injected `StreamFactory`. A lock rather than an actor because the factory is a
    /// synchronous closure — the manager calls it while it is deciding, and cannot await.
    final class FakeStreams: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [String] = []
        private var stopped: [String] = []
        private var continuations: [String: AsyncStream<[String]>.Continuation] = [:]

        var factory: WatcherManager.StreamFactory {
            { root in
                let (events, continuation) = AsyncStream<[String]>.makeStream()
                self.lock.withLock {
                    self.opened.append(root)
                    self.continuations[root] = continuation
                }
                return WatcherManager.WatchStream(events: events, stop: {
                    self.lock.withLock { self.stopped.append(root) }
                    continuation.finish()
                })
            }
        }

        var openedRoots: [String] { lock.withLock { opened } }
        var stoppedRoots: [String] { lock.withLock { stopped } }

        /// One FSEvents batch on `root`, as the real stream would yield it.
        func yield(_ root: String, _ paths: [String]) {
            lock.withLock { continuations[root] }?.yield(paths)
        }

        /// The stream ending on its own — what `FileWatcher` does when FSEvents refuses to create
        /// it at all.
        func finish(_ root: String) {
            lock.withLock { continuations[root] }?.finish()
        }
    }

    /// What the two handlers were told.
    actor Sink {
        private(set) var batches: [(root: String, paths: [String])] = []
        private(set) var unavailable: [(job: Job, reason: String)] = []
        func batch(_ root: String, _ paths: [String]) { batches.append((root, paths)) }
        func unavailable(_ job: Job, _ reason: String) { unavailable.append((job, reason)) }
        var batchCount: Int { batches.count }
        var unavailableCount: Int { unavailable.count }
    }

    /// A stream's task forwards on a task of its own, so what it forwarded is observed by polling.
    /// Bounded, so a manager that stops forwarding fails the assertion that follows rather than
    /// hanging `swift test`.
    static func eventually(_ what: String, _ check: @Sendable () async -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<300 {
            if await check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    static func watchJob(_ name: String, root: String) -> Job {
        Job(name: name, prompt: "Note what changed",
            trigger: .fsEvent(FSWatch(path: root, quietWindowSeconds: 3)))
    }

    /// A manager over the fake factory, where only `present` exists on disk.
    static func manager(_ fake: FakeStreams, present: Set<String>,
                        sink: Sink? = nil) async -> WatcherManager {
        let manager = WatcherManager(ledger: nil, streams: fake.factory,
                                     fileExists: { present.contains($0) })
        if let sink {
            await manager.setBatchHandler { root, paths in await sink.batch(root, paths) }
            await manager.setUnavailableHandler { job, reason in await sink.unavailable(job, reason) }
        }
        return manager
    }

    // MARK: The stream set

    @Test("two jobs watching one directory share one stream")
    func syncStartsOneStreamForTwoJobsOnOneRoot() async throws {
        let fake = FakeStreams()
        let manager = await Self.manager(fake, present: ["/r"])
        await manager.sync(with: [Self.watchJob("a", root: "/r"), Self.watchJob("b", root: "/r")])

        #expect(await manager.activeRoots == ["/r"])
        #expect(fake.openedRoots == ["/r"], "one stream, opened once")
        await manager.stopAll()
    }

    @Test("a watch nested under another watch gets no stream of its own")
    func aNestedRootGetsNoStream() async throws {
        let fake = FakeStreams()
        let manager = await Self.manager(fake, present: ["/r", "/r/sub"])
        await manager.sync(with: [Self.watchJob("outer", root: "/r"),
                                  Self.watchJob("inner", root: "/r/sub")])

        // The ancestor's stream is recursive and already carries per-file events (§0.5); a second
        // stream inside it would deliver every nested path twice.
        #expect(await manager.activeRoots == ["/r"])
        #expect(fake.openedRoots == ["/r"])
        await manager.stopAll()
    }

    @Test("two spellings of one root differing only by case share one stream")
    func caseDifferingRootsShareOneStream() async throws {
        // R-D4-8. `realpath` keeps the caller's casing, so one directory can be stored under two
        // spellings; on a case-insensitive volume they are one directory and must be one stream.
        let fake = FakeStreams()
        let manager = await Self.manager(fake, present: ["/r/Notes", "/r/notes"])
        await manager.sync(with: [Self.watchJob("a", root: "/r/Notes"),
                                  Self.watchJob("b", root: "/r/notes")])

        #expect(await manager.activeRoots == ["/r/Notes"], "the first spelling seen opens the stream")
        #expect(fake.openedRoots.count == 1)
        await manager.stopAll()
    }

    @Test("the stream stops when its last subscriber leaves")
    func theStreamStopsWhenTheLastSubscriberLeaves() async throws {
        let fake = FakeStreams()
        let manager = await Self.manager(fake, present: ["/r"])
        await manager.sync(with: [Self.watchJob("a", root: "/r")])
        #expect(await manager.activeRoots == ["/r"])

        await manager.sync(with: [])
        #expect(await manager.activeRoots.isEmpty)
        #expect(fake.stoppedRoots == ["/r"], "stopped once, not once per sync")

        await manager.sync(with: [])
        #expect(fake.stoppedRoots == ["/r"])
        await manager.stopAll()
    }

    @Test("a sync that changes nothing about a root leaves its stream alone")
    func anUnchangedStreamIsNotRestarted() async throws {
        // The whole point of the diff: a schedule job being added must not cost a watch its timer
        // and its place in the FSEvents history.
        let fake = FakeStreams()
        let manager = await Self.manager(fake, present: ["/r"])
        let watch = Self.watchJob("a", root: "/r")
        await manager.sync(with: [watch])

        let unrelated = Job(name: "s", prompt: "p", trigger: .schedule(.interval(seconds: 60)))
        await manager.sync(with: [watch, unrelated])

        #expect(fake.openedRoots == ["/r"], "no second stream for the same root")
        #expect(fake.stoppedRoots.isEmpty, "and the first was never stopped")
        await manager.stopAll()
    }

    // MARK: Delivery

    @Test("a batch reaches the handler tagged with the root its stream was started for")
    func batchesReachTheHandlerTaggedWithTheRoot() async throws {
        let fake = FakeStreams()
        let sink = Sink()
        let manager = await Self.manager(fake, present: ["/r"], sink: sink)
        await manager.sync(with: [Self.watchJob("a", root: "/r")])

        fake.yield("/r", ["/r/a.txt", "/r/sub/b.txt"])

        await Self.eventually("the batch to reach the handler") { await sink.batchCount == 1 }
        let batch = try #require(await sink.batches.first)
        #expect(batch.root == "/r")
        #expect(batch.paths == ["/r/a.txt", "/r/sub/b.txt"])
        await manager.stopAll()
    }

    // MARK: Roots that go away

    @Test("a root that is gone pauses its watch instead of pretending to watch it")
    func aVanishedRootPausesTheWatch() async throws {
        let fake = FakeStreams()
        let sink = Sink()
        let manager = await Self.manager(fake, present: [], sink: sink)
        let job = Self.watchJob("gone", root: "/gone")

        await manager.sync(with: [job])

        #expect(await sink.unavailableCount == 1)
        let reported = try #require(await sink.unavailable.first)
        #expect(reported.job.id == job.id)
        #expect(reported.reason == "watch path unavailable: /gone")
        #expect(fake.openedRoots.isEmpty, "and no stream was started for it")
        #expect(await manager.activeRoots.isEmpty)
        await manager.stopAll()
    }

    @Test("a stream that ends without being stopped reports every job on it as unavailable")
    func aStreamThatEndsUnpromptedReportsUnavailable() async throws {
        // How `FileWatcher` signals a stream FSEvents refused to create: the AsyncStream finishes
        // straight away. Nothing else ends a stream except `stop`, which cancels the task first.
        let fake = FakeStreams()
        let sink = Sink()
        let manager = await Self.manager(fake, present: ["/r", "/r/sub"], sink: sink)
        let outer = Self.watchJob("outer", root: "/r")
        let inner = Self.watchJob("inner", root: "/r/sub")
        await manager.sync(with: [outer, inner])
        #expect(fake.openedRoots == ["/r"])

        fake.finish("/r")

        await Self.eventually("both jobs on the dead stream to be reported") {
            await sink.unavailableCount == 2
        }
        let reported = await sink.unavailable
        #expect(Set(reported.map(\.job.id)) == [outer.id, inner.id],
                "the nested subscriber the stream was serving is reported too")
        #expect(Set(reported.map(\.reason)) == ["watch path unavailable: /r",
                                                "watch path unavailable: /r/sub"],
                "each named by its own root, which is what the person registered")
        #expect(await manager.activeRoots.isEmpty, "a dead stream is not left looking live")
        await manager.stopAll()
    }

    @Test("a refused stream is opened once, not once per subscriber it was serving")
    func aRefusedStreamIsNotReopenedWhileItsDeathIsReported() async throws {
        // Reporting a dead stream pauses each subscriber in turn, and each pause re-enters `sync`
        // through the hook with the subscribers not yet paused still wanting the root. Without a
        // guard, every one of those re-entries opens the stream again, FSEvents refuses it again,
        // and the report starts over. The hook's sync is modelled inline in the handler, with the
        // job it just paused marked as such, so the re-entry happens every time.
        let fake = FakeStreams()
        let sink = Sink()
        let paused = Paused()
        let one = Self.watchJob("one", root: "/r")
        let two = Self.watchJob("two", root: "/r")
        let manager = await Self.manager(fake, present: ["/r"], sink: sink)
        await manager.setUnavailableHandler { job, reason in
            await sink.unavailable(job, reason)
            await paused.mark(job.id)
            await manager.sync(with: await paused.apply(to: [one, two]))
        }
        await manager.sync(with: [one, two])
        #expect(fake.openedRoots == ["/r"])

        fake.finish("/r")

        await Self.eventually("both subscribers of the dead stream to be reported") {
            await sink.unavailableCount == 2
        }
        #expect(Set(await sink.unavailable.map(\.job.id)) == [one.id, two.id])
        #expect(fake.openedRoots == ["/r"], "one refusal is not tried again per subscriber")
        #expect(await manager.activeRoots.isEmpty)
        await manager.stopAll()
    }

    /// A stream's end is reported from its own task, and two syncs can close it and open a
    /// successor on the same key before that report gets the actor. The report must recognise
    /// its own generation: dropping the successor's entry on the predecessor's word leaves a
    /// stream nobody can stop, forwarding beside the one the next sync opens. The window cannot
    /// be produced through `sync` — `close` cancels the task before it stops the stream — so the
    /// stale end is delivered by hand with the predecessor's token.
    @Test("a stale end for an earlier stream on a root does not tear down its successor")
    func aStaleStreamEndDoesNotTearDownTheSuccessor() async throws {
        let fake = FakeStreams()
        let sink = Sink()
        let manager = await Self.manager(fake, present: ["/r"], sink: sink)
        let job = Self.watchJob("one", root: "/r")

        await manager.sync(with: [job])
        let first = try #require(await manager.streamToken(root: "/r"))
        await manager.sync(with: [])
        #expect(fake.stoppedRoots == ["/r"], "the first generation was closed")
        await manager.sync(with: [job])
        let second = try #require(await manager.streamToken(root: "/r"))
        #expect(second != first, "a reopened stream is a new generation")
        #expect(fake.openedRoots == ["/r", "/r"])

        // The first generation's end arrives late.
        await manager.streamEnded(root: "/r", key: "/r", token: first)
        #expect(await manager.activeRoots == ["/r"], "the successor is still live")
        #expect(await manager.streamToken(root: "/r") == second)
        #expect(await sink.unavailableCount == 0, "and nobody was told the watch died")

        // The successor's own end is still honoured.
        await manager.streamEnded(root: "/r", key: "/r", token: second)
        #expect(await manager.activeRoots.isEmpty)
        #expect(await sink.unavailableCount == 1)
        await manager.stopAll()
    }

    /// The pauses a handler applied, so the re-entrant sync can be handed the table as the ledger
    /// would show it.
    actor Paused {
        private var ids: Set<UUID> = []
        func mark(_ id: UUID) { ids.insert(id) }
        func apply(to jobs: [Job]) -> [Job] {
            jobs.map { job in
                var job = job
                if ids.contains(job.id) { job.pausedReason = "watch path unavailable" }
                return job
            }
        }
    }
}
