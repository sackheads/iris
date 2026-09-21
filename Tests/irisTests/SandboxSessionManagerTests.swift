import Testing
import Foundation
@testable import iris

/// Records calls and lets tests script exec results / failures.
final class MockRuntime: ContainerRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var created: [String] = []
    private(set) var removed: [String] = []
    private(set) var execCount = 0
    private var mountsPerCreate: [[String]] = []
    private var execTimeouts: [Int?] = []
    var existing: [String] = []                 // returned by list()
    var execResult: (String, String, Int32) = ("ok", "", 0)
    var failNextExec = false                     // throw once, then succeed
    var nextExecError: Error?                    // throw this once, then succeed

    func createDetached(name: String, image: String, mounts: [String], workdir: String) async throws {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms: let all concurrent callers park here before any completes
        lock.withLock { created.append(name); mountsPerCreate.append(mounts) }
    }
    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let (fail, scripted, r) = lock.withLock { () -> (Bool, Error?, (String, String, Int32)) in
            execCount += 1
            execTimeouts.append(timeoutSeconds)
            let f = failNextExec; failNextExec = false
            let e = nextExecError; nextExecError = nil
            return (f, e, execResult)
        }
        if let scripted { throw scripted }
        if fail { throw ContainerRuntimeError.launchFailed("boom") }
        return r
    }
    func remove(name: String) async { lock.withLock { removed.append(name) } }
    func list(prefix: String) async -> [String] { lock.withLock { existing.filter { $0.hasPrefix(prefix) } } }

    var createdCount: Int { lock.withLock { created.count } }
    var removedNames: [String] { lock.withLock { removed } }
    var createdMounts: [[String]] { lock.withLock { mountsPerCreate } }
    var lastExecTimeout: Int? { lock.withLock { execTimeouts.last ?? nil } }
}

@Suite("SandboxSessionManager")
struct SandboxSessionManagerTests {
    private func mgr(_ runtime: ContainerRuntime) -> SandboxSessionManager {
        SandboxSessionManager(runtime: runtime, image: { "ubuntu:latest" })
    }

    @Test("first command lazily creates exactly one container")
    func lazyCreate() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "echo hi", conversationId: id, workspace: "/ws")
        #expect(rt.createdCount == 1)
        #expect(await m.hasSession(id))
    }

    @Test("concurrent first commands still create exactly one container")
    func concurrentCreateOnce() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 { g.addTask { _ = await m.run(command: "echo", conversationId: id, workspace: "/ws") } }
            await g.waitForAll()
        }
        #expect(rt.createdCount == 1)
    }

    @Test("second command reuses the container (no new create)")
    func reuse() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        _ = await m.run(command: "b", conversationId: id, workspace: "/ws")
        #expect(rt.createdCount == 1)
        #expect(rt.execCount == 2)
    }

    @Test("changing workspace removes old container and creates a new one")
    func workspaceChange() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws1")
        _ = await m.run(command: "b", conversationId: id, workspace: "/ws2")
        #expect(rt.createdCount == 2)
        #expect(rt.removedNames.count == 1)
    }

    @Test("output matches host formatting: stderr labeled, empty -> Success")
    func formatting() async {
        let rt = MockRuntime()
        rt.execResult = ("", "", 0)
        let m = mgr(rt)
        let out = await m.run(command: "x", conversationId: UUID(), workspace: nil)
        #expect(out == "Success")

        let rt2 = MockRuntime()
        rt2.execResult = ("hello", "warn", 0)
        let m2 = mgr(rt2)
        let out2 = await m2.run(command: "x", conversationId: UUID(), workspace: nil)
        #expect(out2 == "hello\nStderr: warn")
    }

    @Test("endSession removes the container; next run recreates")
    func endSession() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        await m.endSession(id)
        #expect(!(await m.hasSession(id)))
        #expect(rt.removedNames.count == 1)
        _ = await m.run(command: "b", conversationId: id, workspace: "/ws")
        #expect(rt.createdCount == 2)
    }

    @Test("reapOrphans removes every iris- prefixed container")
    func reapOrphans() async {
        let rt = MockRuntime()
        rt.existing = ["iris-aaa", "iris-bbb", "other-ccc"]
        let m = mgr(rt)
        await m.reapOrphans()
        #expect(rt.removedNames.sorted() == ["iris-aaa", "iris-bbb"])
    }

    @Test("reapIdle removes only stale sessions; next run recreates with a reset notice")
    func reapIdleAndNotice() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        // Everything is stale relative to a far-future 'now'.
        await m.reapIdle(olderThan: 60, now: Date().addingTimeInterval(3600))
        #expect(!(await m.hasSession(id)))
        let out = await m.run(command: "b", conversationId: id, workspace: "/ws")
        #expect(out.hasPrefix("[sandbox]"))
        #expect(out.contains("reclaimed"))
    }

    @Test("first-ever creation emits no reset notice")
    func firstCreateNoNotice() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let out = await m.run(command: "a", conversationId: UUID(), workspace: "/ws")
        #expect(!out.hasPrefix("[sandbox]"))
    }

    @Test("exec failing once triggers a single recreate+retry and a reset notice")
    func selfHeal() async {
        let rt = MockRuntime()
        rt.failNextExec = true
        let m = mgr(rt)
        let id = UUID()
        let out = await m.run(command: "a", conversationId: id, workspace: "/ws")
        #expect(rt.createdCount == 2)   // initial + recreate
        #expect(out.hasPrefix("[sandbox]"))
    }
}
