import Testing
import Foundation
@testable import iris

@Suite("Watcher jobs")
struct WatcherJobsTests {
    @Test("a fire's prompt is the job's own, plus what changed")
    func firePath() async throws {
        // Which streams exist is `WatcherManagerSyncTests`; what a burst becomes is
        // `WatchCoordinatorTests`. What is left here is the shape of the turn a fire runs: the
        // job's own prompt, and the paths that woke it as untrusted content.
        let job = Job(name: "notes", prompt: "Note what changed",
                      trigger: .fsEvent(FSWatch(path: "/tmp/notes")),
                      createdInConversationId: UUID())

        // #187 §6.1: the turn runs in a background conversation of its own, over the job's own
        // prompt — the watcher does not write a "System Event:" sentence around it.
        let prompt = await JobRunner.prompt(job: job,
                                            changedPaths: ["/tmp/notes/a.txt", "/tmp/notes/b.txt"],
                                            protectionEnabled: false)
        #expect(prompt.hasPrefix("Note what changed\n\n"))
        #expect(prompt.contains("- /tmp/notes/a.txt\n- /tmp/notes/b.txt"))
        #expect(prompt.contains("<untrusted_context"))
    }
}
