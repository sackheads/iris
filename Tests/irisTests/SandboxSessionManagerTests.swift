import Testing
import Foundation
@testable import iris

/// `run(workspace:)` takes the working directory as a typed mount (fix round 1: a path with a `:`
/// in it must never be re-parsed into a different directory). A bare string in a test is the
/// identity read-write mount of that path, which is what every test here meant by it.
extension ContainerMount: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(source: value) }
}

/// Records calls and lets tests script exec results / failures.
final class MockRuntime: ContainerRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var created: [String] = []
    private(set) var removed: [String] = []
    private(set) var execCount = 0
    private var mountsPerCreate: [[String]] = []
    private var workdirsPerCreate: [String] = []
    private var execTimeouts: [Int?] = []
    private var execWorkdirs: [String] = []
    var existing: [String] = []                 // returned by list()
    var execResult: (String, String, Int32) = ("ok", "", 0)
    var failNextExec = false                     // throw once, then succeed
    var nextExecError: Error?                    // throw this once, then succeed
    var nextCreateError: Error?                  // throw this once, then succeed
    private var networksPerCreate: [NetworkMode] = []
    private(set) var networksEnsured: [String] = []
    var nextNetworkError: Error?

    func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms: let all concurrent callers park here before any completes
        if let scripted = lock.withLock({ () -> Error? in let e = nextCreateError; nextCreateError = nil; return e }) {
            throw scripted
        }
        lock.withLock {
            created.append(name); mountsPerCreate.append(mounts); workdirsPerCreate.append(workdir)
            networksPerCreate.append(network)
        }
    }
    func ensureIsolatedNetwork(named name: String) async throws {
        if let scripted = lock.withLock({ () -> Error? in let e = nextNetworkError; nextNetworkError = nil; return e }) {
            throw scripted
        }
        lock.withLock { networksEnsured.append(name) }
    }
    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let (fail, scripted, r) = lock.withLock { () -> (Bool, Error?, (String, String, Int32)) in
            execCount += 1
            execTimeouts.append(timeoutSeconds)
            execWorkdirs.append(workdir)
            let f = failNextExec; failNextExec = false
            let e = nextExecError; nextExecError = nil
            return (f, e, execResult)
        }
        if let scripted { throw scripted }
        if fail { throw ContainerRuntimeError.launchFailed("boom") }
        return r
    }
    /// Refuses on a cancelled task, exactly as `CLIProcessRunner.run` does: it will not launch a
    /// child for a caller that has already given up, so a cleanup that goes down the ordinary path
    /// from a cancelled create spawns neither `stop` nor `delete`.
    func remove(name: String) async {
        guard !Task.isCancelled else { return }
        lock.withLock { removed.append(name) }
    }
    func list(prefix: String) async -> [String] { lock.withLock { existing.filter { $0.hasPrefix(prefix) } } }

    var createdCount: Int { lock.withLock { created.count } }
    var removedNames: [String] { lock.withLock { removed } }
    var createdMounts: [[String]] { lock.withLock { mountsPerCreate } }
    var lastExecTimeout: Int? { lock.withLock { execTimeouts.last ?? nil } }
    var createdNetworks: [NetworkMode] { lock.withLock { networksPerCreate } }
    var createdWorkdirs: [String] { lock.withLock { workdirsPerCreate } }
    var execedWorkdirs: [String] { lock.withLock { execWorkdirs } }
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

    /// A create that failed can still have left a container behind — it has a ceiling now, and a
    /// create killed at it may go on to finish daemon-side. The name is a pure function of the
    /// conversation, so anything left under it would fail every later command in that conversation
    /// with "already exists" until the next launch sweeps it.
    @Test("a failed create is swept up, and the next command can still start a container")
    func failedCreateRemovesWhatItMayHaveLeft() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        rt.nextCreateError = ContainerRuntimeError.timedOut(elapsedSeconds: 1_200.4)

        let first = await m.run(command: "a", conversationId: id, workspace: "/ws")

        #expect(first.hasPrefix("Error:"))
        #expect(rt.removedNames == ["\(SandboxSessionManager.namePrefix)\(id.uuidString.lowercased())"],
                "the name the create was given, removed exactly once")
        #expect(!(await m.hasSession(id)))

        // And the conversation is not poisoned: the next command creates and runs.
        let second = await m.run(command: "b", conversationId: id, workspace: "/ws")
        #expect(second == "ok")
        #expect(rt.createdCount == 1, "one container, built by the second command")
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

    /// The `iris-` prefix is shared on purpose — a gate's container carries it so that one left by
    /// a crash is swept too — which means the prefix alone does not mean "an orphan". A sweep must
    /// leave alone the sessions this manager is holding and the gates that are mid-evaluation.
    @Test("reapOrphans spares a live session and a gate container that is in flight")
    func reapOrphansSparesLiveWork() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        let live = "\(SandboxSessionManager.namePrefix)\(id.uuidString.lowercased())"
        let gate = "\(SandboxSessionManager.namePrefix)gate-\(UUID().uuidString.lowercased())"
        rt.existing = [live, gate, "iris-orphan"]

        await m.reapOrphans(inFlightGates: [gate])

        #expect(rt.removedNames == ["iris-orphan"], "only what nobody is using")
        #expect(await m.hasSession(id), "the live conversation still has its container")
    }

    /// R34: cleanup must survive the caller's cancellation, because that is exactly when a
    /// container is left behind — `CLIProcessRunner` will not launch a child for a task that has
    /// already given up, so `stop` and `delete` never spawn. Asserted on the mechanism itself:
    /// `SandboxSessionManager.create`'s own cleanup is insulated from this today by the create
    /// barrier's unstructured task, and a gate's is not (`GateEvaluatorTests`).
    @Test("a remove issued from a cancelled task still reaches the runtime")
    func removeSurvivesCancellation() async {
        let rt = MockRuntime()
        let call = Task {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            await rt.remove(name: "iris-plain")
            await rt.removeIgnoringCancellation(name: "iris-cleanup")
        }
        call.cancel()
        await call.value

        #expect(rt.removedNames == ["iris-cleanup"],
                "the ordinary route launches nothing from a cancelled task; the cleanup route does")
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

    // MARK: - #282: the network and the working directory's mount

    @Test("an isolated session ensures the network before its create, and a changed network recreates")
    func isolatedNetworkIsEnsuredAndPinned() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws", network: .isolated)
        #expect(rt.networksEnsured == ["iris-isolated"])
        #expect(rt.createdNetworks == [.isolated])
        _ = await m.run(command: "b", conversationId: id, workspace: "/ws", network: .isolated)
        #expect(rt.createdCount == 1 && rt.networksEnsured.count == 1, "the network is ensured per create, not per command")
        _ = await m.run(command: "c", conversationId: id, workspace: "/ws", network: .default)
        #expect(rt.createdCount == 2 && rt.removedNames.count == 1, "a different network is a different container")
        #expect(rt.createdNetworks == [.isolated, .default])
    }

    @Test("a network that cannot be created runs nothing and says why")
    func networkFailureRunsNothing() async {
        let rt = MockRuntime()
        rt.nextNetworkError = ContainerRuntimeError.networkFailed("permission denied")
        let m = mgr(rt)
        let out = await m.run(command: "a", conversationId: UUID(), workspace: "/ws", network: .isolated)
        #expect(out == SandboxSessionManager.isolatedNetworkError("permission denied"))
        #expect(rt.execCount == 0 && rt.createdCount == 0)
        #expect(rt.removedNames == [], "nothing was created, so there is nothing to sweep up")
    }

    /// §0.7 through the manager: `NetworkMode.forGrant` decides, and the decision reaches the
    /// create — on the mock as the recorded mode, and on the real runtime as the argv.
    @Test("NetworkMode.forGrant: no grant and network on keep the default; network off is isolated, ensured, and on the argv")
    func networkFollowsTheGrant() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let proj = ContainerMount(source: "/ws")
        _ = await m.run(command: "a", conversationId: UUID(), workspace: "/ws", network: NetworkMode.forGrant(nil))
        _ = await m.run(command: "a", conversationId: UUID(), workspace: "/ws",
                        network: NetworkMode.forGrant(JobGrant(mounts: [proj], network: true)))
        #expect(rt.createdNetworks == [.default, .default] && rt.networksEnsured.isEmpty,
                "neither an ungranted run nor a network-on grant touches the isolated network")
        _ = await m.run(command: "a", conversationId: UUID(), workspace: "/ws",
                        network: NetworkMode.forGrant(JobGrant(mounts: [proj], network: false)))
        #expect(rt.createdNetworks == [.default, .default, .isolated])
        #expect(rt.networksEnsured == [NetworkMode.isolatedNetworkName])

        let launcher = RecordingLauncher(result: ("[]", "", 0))   // `network ls`: nothing there yet
        let cli = SandboxSessionManager(runtime: CLIContainerRuntime(launch: launcher.launch), image: { "img" })
        let id = UUID()
        _ = await cli.run(command: "a", conversationId: id, workspace: "/ws",
                          network: NetworkMode.forGrant(JobGrant(mounts: [proj], network: false)))
        #expect(launcher.argv.prefix(3).map { Array($0) } == [
            ["network", "ls", "--format", "json"],
            ["network", "create", "--internal", "iris-isolated"],
            ["run", "-d", "--name", "\(SandboxSessionManager.namePrefix)\(id.uuidString.lowercased())",
             "--mount", "type=virtiofs,source=/ws,target=/ws",
             "--network", "iris-isolated", "--no-dns",
             "-w", "/ws", "img", "sleep", "infinity"],
        ])
    }

    /// The working directory is the first read-write mount; the container's `-w` is that mount's
    /// TARGET, and the mount is made once, at the target — never a second time at its source.
    @Test("a working directory with a named target: -w is the target, mounted once at the target")
    func namedTargetIsTheWorkdirAndMountedOnce() async throws {
        let rt = MockRuntime()
        let m = mgr(rt)
        let grant = JobGrant(mounts: [ContainerMount(source: "/host/dir", target: "/work"),
                                      ContainerMount(source: "/ref", readOnly: true)])
        _ = await m.run(command: "a", conversationId: UUID(), workspace: grant.workspaceMount,
                        extraMounts: grant.extraMountEntries())
        #expect(rt.createdMounts == [["/host/dir:/work", "/ref:ro"]], "no identity mount of /host/dir beside it")
        #expect(try ContainerMount.argument(for: "/host/dir:/work") == "type=virtiofs,source=/host/dir,target=/work")
        #expect(rt.createdWorkdirs == ["/work"])
        #expect(rt.execedWorkdirs == ["/work"])
        #expect(grant.workingDirectory == "/host/dir", "the conversation's workspacePath is still the host side")
    }

    /// The seam is typed so that a `:` inside a host path can never be read as a target. macOS
    /// allows one in a name (Finder writes one for every `/` typed), and an ungranted workspace
    /// bound to such a directory was refused by `ContainerMount.argument(for:)` before this task:
    /// the same entry, the same sentence, and no container.
    @Test("an ungranted workspace path containing ':' is still refused, with the sentence it always got")
    func colonInWorkspacePathStillRefused() async {
        let launcher = RecordingLauncher()
        let m = SandboxSessionManager(runtime: CLIContainerRuntime(launch: launcher.launch), image: { "img" })
        let out = await m.run(command: "a", conversationId: UUID(),
                              workspace: ContainerMount(source: "/Users/me/Documents/Backup:/x"))
        #expect(out == "Error: the mount `/Users/me/Documents/Backup:/x:/Users/me/Documents/Backup:/x` cannot be used — expected source[:target][:ro].")
        #expect(!launcher.argv.contains { $0.first == "run" }, "no container was created")
    }
}
