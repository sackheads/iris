import Testing
import Foundation
@testable import IrisKit

/// #291 — a conversation's delegates end with it. When a run closes, every subagent under its
/// conversation, grandchildren included, is stopped and its sandbox session closed: they inherit
/// the run's grant, so until this they held the same read-write mounts until the idle reaper.
/// Deleting a conversation does the same walk, and denies what its delegates had queued. Stub
/// runtimes and scripted clients only; nothing reaches `SandboxSessionManager.shared`.
@MainActor
@Suite("A conversation's delegates close with it (#291)", .timeLimit(.minutes(1)))
struct RunDelegateCloseTests {

    /// PARENT (no subagent role) parks until cancelled. A subagent role parks too, but ignores
    /// its cancellation — noting that it arrived — until the test releases it: the turn that
    /// outlives its stop, and the one whose engine task keeps the subagent registered and linked.
    final class StubbornClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var entered: [String: Int] = [:]
        private var cancelled: [String: Int] = [:]
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func parked(_ role: String) -> Int { lock.withLock { entered[role] ?? 0 } }
        func cancellations(_ role: String) -> Int { lock.withLock { cancelled[role] ?? 0 } }
        func release() {
            let parked = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                released = true; defer { waiters = [] }; return waiters
            }
            for c in parked { c.resume() }
        }

        private func role(of request: GeminiRequest) -> String {
            let prompt = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            guard let range = prompt.range(of: "subagent role: **") else { return "PARENT" }
            return String(prompt[range.upperBound...].prefix { $0 != "*" })
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let role = role(of: request)
            lock.withLock { entered[role, default: 0] += 1 }
            if role == "PARENT" {
                try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            } else {
                await withTaskCancellationHandler {
                    // A bare continuation: deaf to cancellation, as a turn that ignores it is.
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        let now = lock.withLock { () -> Bool in
                            if released { return true }
                            waiters.append(c); return false
                        }
                        if now { c.resume() }
                    }
                } onCancel: {
                    lock.withLock { cancelled[role, default: 0] += 1 }
                }
            }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "late")]))],
                                  usageMetadata: nil)
        }
    }

    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()
        func now() -> Date { lock.withLock { current } }
        func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID] = []
        func add(_ id: UUID) { lock.withLock { ids.append(id) } }
        var all: [UUID] { lock.withLock { ids } }
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-rundelegateclose-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func containerName(_ id: UUID) -> String { "iris-\(id.uuidString.lowercased())" }

    @Test("a closing run closes the sessions of its subagent and grandchild, stops their turns, and lets none start a container")
    func runCloseClosesDescendants() async throws {
        let client = StubbornClient()
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        state.createNewConversation(id: UUID())
        let engine = IrisEngine(state: state, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        var job = Job(name: "delegator", prompt: "Work.", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        job.policy.runTimeoutSeconds = 600
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let rt = MockRuntime()
        let sessions = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let clock = ManualClock()
        // No `endSandboxSession` override: the runner closes through the test's manager, as the
        // app's runner closes through the shared one.
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, sandboxSessions: sessions,
                               ensureIsolatedNetwork: { nil }, config: config, activity: RecordingActivity(),
                               sandboxAvailable: { true }, watchdogSlice: 0.01, deadlineClock: clock.now)

        let fire = Task { await runner.fire(job: job, origin: .schedule) }
        #expect(await eventually { client.parked("PARENT") == 1 })
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first?.transcriptConversationId)

        // The subagents' own exit closes nothing here, so only the runner's walk can.
        let ownClose = Recorder()
        let child = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: run, turnTimeout: 600,
                client: client, appState: state, config: config, endSandboxSession: { ownClose.add($0) })
        }
        #expect(await eventually { client.parked("WORKER") == 1 })
        let childId = try #require(state.conversations.first { $0.title == "Subagent: worker" }).id
        let grandchild = Task {
            await SubagentManager.shared.runSubagent(
                role: "inner", task: "Work.", effort: "easy", parentConversationId: childId, turnTimeout: 600,
                client: client, appState: state, config: config, endSandboxSession: { ownClose.add($0) })
        }
        #expect(await eventually { client.parked("INNER") == 1 })
        let grandId = try #require(state.conversations.first { $0.title == "Subagent: inner" }).id
        #expect(state.delegationRoot(of: grandId) == run)

        for id in [run, childId, grandId] {
            _ = await sessions.run(command: "true", conversationId: id, workspace: "/ws")
        }
        #expect(rt.createdCount == 3)

        clock.advance(by: 601)
        await fire.value

        for id in [run, childId, grandId] {
            #expect(await sessions.isClosed(id), "session \(id) was closed")
            #expect(!(await sessions.hasSession(id)))
            #expect(rt.removedNames.contains(containerName(id)), "container of \(id) was removed")
        }
        #expect(await eventually { client.cancellations("WORKER") == 1 }, "the subagent's in-flight turn was cancelled")
        #expect(await eventually { client.cancellations("INNER") == 1 }, "and the grandchild's")

        // Their turns, outliving the stop, reach for a container: refused, none created.
        for id in [childId, grandId] {
            let late = await sessions.run(command: "ls", conversationId: id, workspace: "/ws")
            #expect(late == SandboxSessionManager.closedSessionError)
        }
        #expect(rt.createdCount == 3, "no container after the close")

        client.release()
        #expect(await child.value.status == .cancelled)
        #expect(await grandchild.value.status == .cancelled)
    }

    @Test("deleting a conversation stops its delegates, denies their queued asks and closes their sessions")
    func deleteReachesDescendants() async throws {
        let client = StubbornClient()
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let closes = Recorder()
        state.closeSandboxSession = { closes.add($0) }
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let parent = state.createNewConversation(select: false)

        // Background: no cancellation of the parent's tasks reaches it, only the walk.
        let child = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: parent, background: true,
                turnTimeout: 600, client: client, appState: state, config: config, endSandboxSession: { _ in })
        }
        #expect(await eventually { client.parked("WORKER") == 1 })
        let childId = try #require(state.conversations.first { $0.title == "Subagent: worker" }).id
        // A grandchild delegated by the subagent, linked as `runSubagent` links one.
        let grandId = UUID()
        state.createNewConversation(id: grandId, isSubagent: true, select: false)
        state.linkDelegate(grandId, of: childId)

        let childAsk = Task {
            await state.enqueueUserApproval(toolName: "write_file", details: "x", workspace: nil,
                                            conversationId: childId, origin: "test")
        }
        let grandAsk = Task {
            await state.enqueueUserApproval(toolName: "write_file", details: "y", workspace: nil,
                                            conversationId: grandId, origin: "test")
        }
        #expect(await eventually { state.pendingApprovals.count == 2 })

        state.deleteConversation(parent)

        // Checked on the queue, synchronously after the delete: awaiting an ask nobody denied
        // would hang the test rather than fail it.
        #expect(!state.pendingApprovals.contains { $0.conversationId == childId }, "the delegate's queued ask was denied")
        #expect(!state.pendingApprovals.contains { $0.conversationId == grandId }, "and the grandchild's")
        state.denyPendingApprovals(for: childId)   // unblocks a failed run; a no-op on a passing one
        state.denyPendingApprovals(for: grandId)
        #expect(await childAsk.value == false)
        #expect(await grandAsk.value == false)
        #expect(await eventually { Set(closes.all) == [parent, childId, grandId] }, "closed: \(closes.all)")
        #expect(await eventually { client.cancellations("WORKER") == 1 }, "the background subagent's turn was stopped")

        client.release()
        let outcome = await child.value
        #expect(outcome.status == .cancelled)
        #expect(outcome.rendered.contains(SubagentManager.parentDeletedReason))
    }
}
