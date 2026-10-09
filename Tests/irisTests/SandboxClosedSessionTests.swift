import Testing
import Foundation
@testable import IrisKit

/// #292: a closed run's conversation is refused a new sandbox session. A background run's turn is
/// cancelled cooperatively at its deadline, so a turn that ignores the cancellation can call
/// `run_command` after `closeSession` removed the container; before this, that recreated a
/// container nothing but the idle reaper ended. Every runtime here is a stub: no `container`
/// binary, daemon or VM, and nothing reaches `SandboxSessionManager.shared` (invariant 7).
@Suite("Closed sandbox sessions (#292)")
struct SandboxClosedSessionTests {
    private func mgr(_ runtime: ContainerRuntime) -> SandboxSessionManager {
        SandboxSessionManager(runtime: runtime, image: { "ubuntu:latest" })
    }

    /// A runtime that parks `createDetached` or `exec` until the test lets it go, so a close can
    /// be landed while a create or a command is in flight.
    private final class GatedRuntime: ContainerRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var created: [String] = []
        private var removed: [String] = []
        private var gateCreate: Bool
        private var gateExec: Bool
        private var createEntered = false
        private var execEntered = false
        private var execs = 0

        init(gateCreate: Bool = false, gateExec: Bool = false) {
            self.gateCreate = gateCreate; self.gateExec = gateExec
        }

        var createdNames: [String] { lock.withLock { created } }
        var removedNames: [String] { lock.withLock { removed } }
        var execCount: Int { lock.withLock { execs } }
        var isInCreate: Bool { lock.withLock { createEntered } }
        var isInExec: Bool { lock.withLock { execEntered } }
        func releaseCreate() { lock.withLock { gateCreate = false } }
        func releaseExec() { lock.withLock { gateExec = false } }

        func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws {
            lock.withLock { createEntered = true }
            while lock.withLock({ gateCreate }) { try? await Task.sleep(nanoseconds: 1_000_000) }
            lock.withLock { created.append(name) }
        }
        func ensureIsolatedNetwork(named name: String) async throws {}
        func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
            lock.withLock { execs += 1; execEntered = true }
            while lock.withLock({ gateExec }) { try? await Task.sleep(nanoseconds: 1_000_000) }
            // The container was removed under the command: what the CLI reports then.
            if lock.withLock({ removed.contains(name) }) { throw ContainerRuntimeError.launchFailed("no such container") }
            return ("ok", "", 0)
        }
        func remove(name: String) async { lock.withLock { removed.append(name) } }
        func list(prefix: String) async -> [String] { [] }
    }

    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out waiting for \(description)"); return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test("after closeSession a late run_command is refused and no container is created")
    func closedRefusesANewSession() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        #expect(rt.createdCount == 1)
        await m.closeSession(id)
        #expect(rt.removedNames == ["iris-\(id.uuidString.lowercased())"])

        let late = await m.run(command: "b", conversationId: id, workspace: "/ws")
        #expect(late == SandboxSessionManager.closedSessionError)
        #expect(rt.createdCount == 1, "the closed conversation got no new container")
        #expect(rt.execCount == 1, "and nothing ran")
        #expect(!(await m.hasSession(id)))
        #expect(await m.isClosed(id))
    }

    @Test("a close that lands while the create is in flight deletes that container and refuses the command")
    func closeDuringCreate() async throws {
        let rt = GatedRuntime(gateCreate: true)
        let m = mgr(rt)
        let id = UUID()
        let name = "iris-\(id.uuidString.lowercased())"
        let first = Task { await m.run(command: "a", conversationId: id, workspace: "/ws") }
        try await waitFor("the create to start") { rt.isInCreate }
        await m.closeSession(id)
        rt.releaseCreate()

        #expect(await first.value == SandboxSessionManager.closedSessionError)
        #expect(rt.execCount == 0, "nothing ran in the container the create made")
        #expect(rt.removedNames.contains(name), "the container the create made was swept, not left as an orphan")
        #expect(!(await m.hasSession(id)), "and it was never recorded as a session")
    }

    /// Holds the manager for a closure the manager itself is built with.
    private final class ManagerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SandboxSessionManager?
        var manager: SandboxSessionManager? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test("a close that lands while the container system is being started refuses the retried create")
    func closeDuringSystemStartRetry() async {
        let rt = MockRuntime()
        rt.nextCreateError = ContainerRuntimeError.createFailed("Error: run `container system start` first")
        let id = UUID()
        let box = ManagerBox()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" }, startContainerSystem: {
            await box.manager?.closeSession(id)
            return true
        })
        box.manager = m

        let out = await m.run(command: "a", conversationId: id, workspace: "/ws")
        #expect(out == SandboxSessionManager.closedSessionError)
        #expect(rt.createdCount == 1, "the retry branch ran its create")
        #expect(!(await m.hasSession(id)), "and the closed conversation was not given the session")
        #expect(rt.execCount == 0)
        #expect(rt.removedNames.contains("iris-\(id.uuidString.lowercased())"), "the retried container was swept")
    }

    @Test("a close under a running command does not self-heal into a new container")
    func closeDuringExec() async throws {
        let rt = GatedRuntime(gateExec: true)
        let m = mgr(rt)
        let id = UUID()
        let first = Task { await m.run(command: "a", conversationId: id, workspace: "/ws") }
        try await waitFor("the command to start") { rt.isInExec }
        await m.closeSession(id)
        rt.releaseExec()

        #expect(await first.value == SandboxSessionManager.closedMidCommandError)
        #expect(rt.createdNames.count == 1, "the lost-container retry did not recreate it")
        #expect(rt.execCount == 1)
        #expect(!(await m.hasSession(id)))
    }

    @Test("an attended conversation that ends and restarts its session is not blocked, nor is any other conversation")
    func endSessionStaysRestartable() async {
        let rt = MockRuntime()
        let m = mgr(rt)
        let attended = UUID(), run = UUID()
        _ = await m.run(command: "a", conversationId: attended, workspace: "/ws")
        _ = await m.run(command: "a", conversationId: run, workspace: "/ws")
        await m.closeSession(run)

        // The toggle shape: the session goes away, then sandboxing is back on and asks again.
        await m.endSession(attended)
        #expect(!(await m.isClosed(attended)))
        let again = await m.run(command: "b", conversationId: attended, workspace: "/ws")
        #expect(again == "ok")
        #expect(rt.createdCount == 3, "the attended conversation got its container back")
        #expect(await m.hasSession(attended))
    }

    // MARK: Wiring: a run's close marks its conversation

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    @MainActor
    @Test("a finished run's conversation refuses run_command's sandboxed branch, with no container created")
    func jobRunClosesItsConversation() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let user = UUID()
        state.createNewConversation(id: user)
        state.selectedConversationId = user
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [textResponse("done")]),
                                protectionEnabled: false, sessionPeerCount: 0)
        let suite = "iris-closedsession-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: defaults)

        let rt = MockRuntime()
        let sessions = mgr(rt)
        // The runner's own close, against a manager of the test's: no `endSandboxSession`
        // override, so this is the default the app runs with.
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, sandboxSessions: sessions,
                               ensureIsolatedNetwork: { nil }, config: config, sandboxAvailable: { true })
        let job = Job(name: "sweep", prompt: "Do it.", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        await runner.fire(job: job, origin: .schedule)
        let runConversation = try #require(state.conversations.first { $0.isBackground }).id
        #expect(await sessions.isClosed(runConversation))

        // The abandoned turn's late call, through the executor's sandboxed branch.
        var executor = ToolExecutor()
        executor.sandboxSession = { command, conversationId, workspace, extra, network, timeout in
            await sessions.run(command: command, conversationId: conversationId, workspace: workspace,
                               extraMounts: extra, network: network, timeoutSeconds: timeout)
        }
        let out = await executor.execute(name: "run_command", args: ["command": .string("ls")], cwd: "/ws",
                                         conversationId: runConversation, useSandbox: true)
        #expect(out.contains(SandboxSessionManager.closedSessionError), "got: \(out)")
        #expect(rt.createdCount == 0)
        #expect(rt.execCount == 0)
    }
}
