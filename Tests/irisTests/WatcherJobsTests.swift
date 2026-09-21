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

    @Test("registering a watch on a manager that was never configured adopts the tools' ledger")
    func reloadAdoptsLedgerWhenUnconfigured() async throws {
        // `WatcherManager.shared` is only configured in `IrisEngine.start()`. An engine that never
        // started — a subagent, a scenario run — still resolves job tools, and the watch it
        // registers has to actually start watching rather than reload an empty nil ledger.
        let store = try ConversationStore.inMemory()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wm = WatcherManager(ledger: nil)
        var executor = ToolExecutor()
        executor.jobToolsProvider = { JobTools(ledger: store.ledger, watchers: wm) }
        let result = await executor.execute(
            name: "register_directory_watcher",
            args: ["path": .string(tmp.path), "instructions": .string("note changes")])
        #expect(result.contains(tmp.path))
        #expect(await wm.activeJobIds.count == 1)
        await wm.stopAll()
    }

    @Test("a fire hands over the job and its paths; the prompt is the job's own, plus what changed")
    func firePath() async throws {
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
        // The whole job travels, so the runner can name it, profile it and route its card.
        #expect(fires.first?.job.createdInConversationId == conversation)
        // #187 §6.1: the turn now runs in a background conversation of its own, over the job's own
        // prompt — the watcher no longer writes a "System Event:" sentence around it. The paths
        // that woke it follow as untrusted content (see JobRunnerTests).
        let fire = try #require(fires.first)
        let prompt = await JobRunner.prompt(job: fire.job, changedPaths: fire.paths,
                                            protectionEnabled: false)
        #expect(prompt.hasPrefix("Note what changed\n\n"))
        #expect(prompt.contains("- /tmp/notes/a.txt\n- /tmp/notes/b.txt"))
        #expect(prompt.contains("<untrusted_context"))
    }
}
