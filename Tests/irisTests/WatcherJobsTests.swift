import Testing
import Foundation
@testable import iris

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
        defer { Task { await wm.stopAll() } }
        await wm.reload()
        #expect(await wm.activeJobIds.count == 1)
        await wm.stopAll()
    }
}
