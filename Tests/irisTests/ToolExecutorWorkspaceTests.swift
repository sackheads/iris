import Testing
import Foundation
@testable import iris

@Suite("ToolExecutor workspace path resolution")
struct ToolExecutorWorkspaceTests {

    @Test("resolvePath joins relative paths onto the workspace; leaves absolute and tilde alone")
    func resolve() {
        #expect(ToolExecutor.resolvePath("f.txt", cwd: "/ws") == "/ws/f.txt")
        #expect(ToolExecutor.resolvePath("a/b.txt", cwd: "/ws") == "/ws/a/b.txt")
        #expect(ToolExecutor.resolvePath("/abs/f.txt", cwd: "/ws") == "/abs/f.txt")   // absolute unchanged
        #expect(ToolExecutor.resolvePath("f.txt", cwd: nil) == "f.txt")               // no workspace → prior behavior
        let home = ("~/f.txt" as NSString).expandingTildeInPath
        #expect(ToolExecutor.resolvePath("~/f.txt", cwd: "/ws") == home)              // tilde expands to absolute
    }

    @Test("write_file + read_file with a relative path use the bound workspace, not the process cwd")
    func relativeWriteLandsInWorkspace() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writeResult = await ToolExecutor.shared.execute(
            name: "write_file",
            args: ["path": .string("hangman.py"), "content": .string("print('hi')")],
            cwd: tmp.path
        )

        // It landed under the workspace, NOT the process working directory.
        let landed = tmp.appendingPathComponent("hangman.py").path
        #expect(FileManager.default.fileExists(atPath: landed))
        #expect(writeResult.contains(landed))
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/hangman.py"))

        // read_file with the same relative path + workspace reads it back.
        let readResult = await ToolExecutor.shared.execute(
            name: "read_file",
            args: ["path": .string("hangman.py")],
            cwd: tmp.path
        )
        #expect(readResult.contains("print('hi')"))
    }

    @Test("register_directory_watcher with a relative path resolves against the bound workspace")
    func relativeWatcherResolvesToWorkspace() async throws {
        // The tool now writes a job, so it needs a ledger to write into (nil declines instead).
        let store = try ConversationStore.inMemory()
        let watchers = WatcherManager(ledger: store.ledger)
        var executor = ToolExecutor()
        executor.jobToolsProvider = { JobTools(ledger: store.ledger, watchers: watchers) }

        let result = await executor.execute(
            name: "register_directory_watcher",
            args: ["path": .string("src"), "instructions": .string("note changes")],
            cwd: "/ws"
        )
        // The confirmation echoes the resolved path — under the workspace, not the process cwd.
        #expect(result.contains("/ws/src"))
        #expect(!result.contains(FileManager.default.currentDirectoryPath + "/src"))
        // And the job it stored watches that same resolved path.
        #expect(try store.ledger.jobs().first?.trigger == .fsEvent(FSWatch(path: "/ws/src", quietWindowSeconds: 3)))
        await watchers.stopAll()
    }

    @Test("registering the same directory twice rewrites the one job instead of doubling the watch")
    func watcherReregistration() async throws {
        let store = try ConversationStore.inMemory()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let watchers = WatcherManager(ledger: store.ledger)
        var executor = ToolExecutor()
        executor.jobToolsProvider = { JobTools(ledger: store.ledger, watchers: watchers) }
        let args: [String: JSONValue] = ["path": .string(tmp.path), "instructions": .string("first")]
        let firstConversation = UUID()
        let secondConversation = UUID()

        _ = await executor.execute(name: "register_directory_watcher", args: args,
                                   conversationId: firstConversation)
        let firstJob = try #require(try store.ledger.jobs().first)
        #expect(firstJob.createdInConversationId == firstConversation)
        let second = await executor.execute(
            name: "register_directory_watcher",
            args: ["path": .string(tmp.path), "instructions": .string("second")],
            conversationId: secondConversation)

        let jobs = try store.ledger.jobs()
        #expect(jobs.count == 1)                      // one directory, one job
        #expect(jobs.first?.id == firstJob.id)        // the same job, rewritten
        #expect(jobs.first?.name == firstJob.name)
        #expect(jobs.first?.prompt == "second")       // with the latest standing instructions
        // and firing into the conversation the latest registration was made from, not the first.
        #expect(jobs.first?.createdInConversationId == secondConversation)
        #expect(second.contains(tmp.path))
        #expect(await watchers.activeJobIds.count == 1)
        await watchers.stopAll()
    }

    @Test("register_directory_watcher declines when no ledger is wired up")
    func watcherWithoutLedger() async {
        let result = await ToolExecutor().execute(
            name: "register_directory_watcher",
            args: ["path": .string("/ws/src"), "instructions": .string("note changes")]
        )
        #expect(result == "Jobs are not available yet.")
    }
}
