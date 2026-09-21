import Testing
import Foundation
@testable import iris

/// Captures what the watcher handed its callback, so the fire path can be driven without an
/// FSEvents stream to provoke.
actor FireRecorder {
    private(set) var fires: [(job: Job, paths: [String])] = []
    func record(_ job: Job, _ paths: [String]) { fires.append((job, paths)) }
}

@Suite("Watcher jobs")
struct WatcherJobsTests {
    @Test("reload starts one watcher per enabled fsEvent job and none for schedules or disabled jobs")
    func reload() async throws {
        let store = try ConversationStore.inMemory()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try store.ledger.upsert(Job(name: "w1", prompt: "i", trigger: .fsEvent(FSWatch(path: tmp.path, quietWindowSeconds: 3))))
        var off = Job(name: "w2", prompt: "i", trigger: .fsEvent(FSWatch(path: tmp.path + "/b", quietWindowSeconds: 3))); off.enabled = false
        try store.ledger.upsert(off)
        try store.ledger.upsert(Job(name: "s", prompt: "i", trigger: .schedule(.interval(seconds: 60))))
        let wm = WatcherManager(ledger: store.ledger)
        await wm.reload()
        #expect(await wm.activeJobIds.count == 1)
        await wm.stopAll()
    }

    @Test("registering a watch on a manager that was never configured adopts the tools' ledger and its fire callback")
    func reloadAdoptsLedgerWhenUnconfigured() async throws {
        // `WatcherManager.shared` is only configured in `IrisEngine.start()`. An engine that never
        // started — a subagent, a scenario run — still resolves job tools, and the watch it
        // registers has to actually start watching rather than reload an empty nil ledger.
        // Adopting the ledger alone is not enough: `setCallback` has exactly one caller, three
        // lines from `configure(ledger:)` in `start()`, so an unstarted engine that adopted only
        // the ledger would run a live FSEvents stream whose fires go nowhere.
        let store = try ConversationStore.inMemory()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let recorder = FireRecorder()
        let wm = WatcherManager(ledger: nil)
        var executor = ToolExecutor()
        executor.jobToolsProvider = {
            JobTools(ledger: store.ledger, watchers: wm,
                     watcherCallback: { job, paths in await recorder.record(job, paths) })
        }
        let result = await executor.execute(
            name: "register_directory_watcher",
            args: ["path": .string(tmp.path), "instructions": .string("note changes")])
        #expect(result.contains(tmp.path))
        #expect(await wm.activeJobIds.count == 1)

        // And a fire on the adopted manager reaches the callback the tools supplied.
        let job = try #require(try store.ledger.jobs().first)
        await wm.deliver(job: job, paths: [tmp.path + "/a.txt"])
        let fires = await recorder.fires
        #expect(fires.count == 1)
        #expect(fires.first?.job.id == job.id)
        #expect(fires.first?.paths == [tmp.path + "/a.txt"])
        await wm.stopAll()
    }

    @Test("a fire hands over the job and its paths; the message is the watcher's standing text")
    func firePath() async {
        let conversation = UUID()
        let job = Job(name: "notes", prompt: "Note what changed",
                      trigger: .fsEvent(FSWatch(path: "/tmp/notes")),
                      createdInConversationId: conversation)
        let recorder = FireRecorder()
        let wm = WatcherManager(ledger: nil)
        await wm.setCallback { job, paths in await recorder.record(job, paths) }

        await wm.deliver(job: job, paths: ["/tmp/notes/a.txt", "/tmp/notes/b.txt"])

        let fires = await recorder.fires
        #expect(fires.count == 1)
        // The turn lands in the conversation that created the watch, not whatever is selected.
        #expect(fires.first?.job.createdInConversationId == conversation)
        #expect(fires.first.map { WatcherManager.eventMessage(job: $0.job, paths: $0.paths) } == """
            System Event: Files modified at /tmp/notes/a.txt, /tmp/notes/b.txt.
            Your standing instructions for this event are: Note what changed
            Analyze the event and take action silently or acknowledge it if necessary.
            """)
    }
}
