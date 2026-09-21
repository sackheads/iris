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
