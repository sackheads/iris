import Testing
import Foundation
@testable import IrisKit

/// #236 — the user can stop a background subagent: Stop and `/stop` in its parent conversation
/// reach it, and so does the Stop on its row in the session strip. Scripted clients only.
@MainActor
@Suite("The user's Stop reaches background subagents (#236)")
struct SubagentUserStopTests {

    typealias RoutingClient = DelegatedSpendTests.RoutingClient

    /// Parks every subagent's model call until it is cancelled; the parent is answered from a
    /// queue, and its calls are counted so a test can see no turn was started.
    final class ParkingSubagentsClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var entered = 0
        private var cancelled = 0
        private let routed: RoutingClient

        init(parent: [GeminiResponse] = []) {
            routed = RoutingClient([RoutingClient.parent: parent])
        }

        var parkedCalls: Int { lock.withLock { entered } }
        var cancelledCalls: Int { lock.withLock { cancelled } }
        var parentCalls: Int { routed.callCount(RoutingClient.parent) }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let prompt = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            guard prompt.contains("subagent role: **") else {
                return try await routed.generateContent(request: request, tier: tier)
            }
            lock.withLock { entered += 1 }
            do {
                try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "late")]))],
                                  usageMetadata: nil)
        }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var get: T { lock.withLock { value } }
        func set(_ v: T) { lock.withLock { value = v } }
    }

    // MARK: Fixtures

    private func calls(_ list: [(String, [String: JSONValue])]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: list.map { Part(functionCall: FunctionCall(name: $0.0, args: $0.1)) }))],
                       usageMetadata: nil)
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    private func state() throws -> AppState {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        return state
    }

    private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// A background subagent as `invoke_subagent background: true` starts one: an unstructured
    /// task nothing cancels.
    private func spawnBackground(_ role: String, under parent: UUID, client: any LLMClientProtocol,
                                 state: AppState) -> Task<(rendered: String, status: SubagentTerminalStatus, stoppedBy: SubagentStopKind?), Never> {
        Task {
            await SubagentManager.shared.runSubagent(
                role: role, task: "Work.", effort: "easy", parentConversationId: parent, background: true,
                turnTimeout: 20, client: client, appState: state, endSandboxSession: { _ in })
        }
    }

    private func subagentId(_ role: String, in state: AppState) -> UUID? {
        state.conversations.first { $0.title == "Subagent: \(role)" }?.id
    }

    private func phase(of id: UUID, in state: AppState) -> SessionSummary.Phase? {
        state.sessions.first { $0.id == id }?.phase
    }

    private func finishedStatus(of id: UUID, in state: AppState) -> String? {
        if case .finished(let status, _) = phase(of: id, in: state) { return status }
        return nil
    }

    // MARK: The parent's Stop

    @Test("Stop in the parent stops its background subagent, says so, and posts back once without waking the parent")
    func parentInterruptStopsBackgroundSubagent() async throws {
        let client = ParkingSubagentsClient(parent: [
            calls([("invoke_subagent", ["role": .string("worker"), "task": .string("Research."),
                                        "effort": .string("easy"), "background": .string("true")])]),
            text("Spawned it."),
        ])
        let state = try state()
        let main = state.createNewConversation()
        let engine = IrisEngine(state: state, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        state.installEngine(engine)

        await engine.processInput("Start a background worker.", source: "User", conversationId: main)
        #expect(await eventually { client.parkedCalls == 1 }, "the background subagent is inside its model call")
        let worker = try #require(subagentId("worker", in: state))
        let parentCallsBefore = client.parentCalls
        #expect(parentCallsBefore == 2)

        state.interruptActiveConversation()

        #expect(state.conversations.first { $0.id == main }?.messages.last { $0.role == .system }?.content
                == "Interrupted. Also stopped 1 background subagent.")
        #expect(await eventually { client.cancelledCalls == 1 }, "its model call was cancelled")
        #expect(await eventually { finishedStatus(of: worker, in: state) == "cancelled" })
        #expect(state.conversations.first { $0.id == worker }?.subagentResult?.status == .cancelled)

        let postBacks: @MainActor () -> [ChatMessage] = {
            state.conversations.first { $0.id == main }?.messages
                .filter { $0.content.contains("Background subagent result") } ?? []
        }
        #expect(await eventually { postBacks().count == 1 })
        // Time for a second post-back, or a turn it started, to show up.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(postBacks().count == 1, "exactly one post-back")
        #expect(postBacks().first?.content.contains("status: cancelled") == true)
        #expect(postBacks().first?.content.contains(SubagentManager.parentStoppedReason) == true)
        #expect(client.parentCalls == parentCallsBefore, "the post-back did not start a turn the user just stopped")
        let history = state.conversations.first { $0.id == main }?.history.flatMap(\.parts).compactMap(\.text) ?? []
        #expect(history.contains { $0.contains("status: cancelled") }, "the next turn reads that it was stopped")
    }

    @Test("Esc on an idle parent with only a background subagent working reaches its stop (#234 x #236)")
    func escOnIdleParentReachesBackgroundSubagent() async throws {
        let client = ParkingSubagentsClient(parent: [
            calls([("invoke_subagent", ["role": .string("worker"), "task": .string("Research."),
                                        "effort": .string("easy"), "background": .string("true")])]),
            text("Spawned it."),
        ])
        let state = try state()
        let main = state.createNewConversation()
        let engine = IrisEngine(state: state, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        state.installEngine(engine)

        await engine.processInput("Start a background worker.", source: "User", conversationId: main)
        #expect(await eventually { client.parkedCalls == 1 })
        let worker = try #require(subagentId("worker", in: state))

        // The parent is idle, so the indicator is off, but Esc's guard must still pass.
        #expect(state.isThinking(in: main) == false)
        #expect(state.hasInterruptibleWork(in: main), "ChatView.handleEscape gates on this")
        if state.hasInterruptibleWork(in: state.selectedConversationId) {
            state.interruptActiveConversation()
        }

        #expect(await eventually { client.cancelledCalls == 1 }, "the subagent's model call was cancelled")
        #expect(await eventually { finishedStatus(of: worker, in: state) == "cancelled" })
        #expect(state.hasInterruptibleWork(in: main) == false, "nothing left to stop")
    }

    @Test("/stop stops the conversation's background subagents and says how many")
    func slashStopStopsBackgroundSubagents() async throws {
        let client = ParkingSubagentsClient()
        let state = try state()
        let main = state.createNewConversation()
        let a = spawnBackground("alpha", under: main, client: client, state: state)
        let b = spawnBackground("beta", under: main, client: client, state: state)
        #expect(await eventually { client.parkedCalls == 2 })

        state.sendMessage("/stop")

        #expect(state.conversations.first { $0.id == main }?.messages.last?.content
                == "Goal mode cancelled. Also stopped 2 background subagents.")
        #expect(await a.value.status == .cancelled)
        #expect(await b.value.status == .cancelled)
        #expect(await eventually { client.cancelledCalls == 2 })
    }

    // MARK: The row's Stop

    @Test("stopSubagent stops that subagent and leaves its sibling running")
    func stopSubagentStopsJustOne() async throws {
        let client = ParkingSubagentsClient()
        let state = try state()
        let main = state.createNewConversation()
        let a = spawnBackground("alpha", under: main, client: client, state: state)
        let b = spawnBackground("beta", under: main, client: client, state: state)
        #expect(await eventually { client.parkedCalls == 2 })
        let alpha = try #require(subagentId("alpha", in: state))
        let beta = try #require(subagentId("beta", in: state))

        #expect(state.stopSubagent(alpha))

        let outcome = await a.value
        #expect(outcome.status == .cancelled)
        #expect(outcome.rendered.contains(SubagentManager.rowStoppedReason))
        #expect(outcome.stoppedBy == .row)
        #expect(finishedStatus(of: alpha, in: state) == "cancelled")
        #expect(await eventually { client.cancelledCalls == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.cancelledCalls == 1, "the sibling's call is still running")
        #expect(finishedStatus(of: beta, in: state) == nil)
        #expect(state.backgroundSubagents(under: main) == [beta])

        #expect(state.stopSubagent(beta))
        #expect(await b.value.status == .cancelled)
    }

    // MARK: Nothing stopped twice

    @Test("a subagent whose result is decided is not stopped again, and its row offers no Stop")
    func settledSubagentIsNotStopped() async throws {
        let client = RoutingClient(["WORKER": [calls([("goal_complete", ["summary": .string("done")])])]])
        let state = try state()
        let main = state.createNewConversation()
        let stopAccepted = Box<Bool?>(nil)
        let offered = Box<Bool?>(nil)

        // `endSandboxSession` runs after the result is decided and while the subagent is still
        // registered: the window grading also sits in.
        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: main, background: true,
            client: client, appState: state, endSandboxSession: { id in
                let (accepted, button) = await MainActor.run { (state.stopSubagent(id), state.userStoppableSubagents.contains(id)) }
                stopAccepted.set(accepted)
                offered.set(button)
            })

        #expect(outcome.status == .completed, "the late Stop did not turn a completion into a cancel")
        #expect(stopAccepted.get == false, "there was nothing left to stop")
        #expect(offered.get == false, "the strip hides Stop once it would do nothing")
        #expect(outcome.stoppedBy == nil, "a row Stop of a settled subagent is not recorded")
        #expect(!outcome.rendered.contains(SubagentManager.stoppedAfterCompletionNote))
    }

    @Test("the parent's Stop while a subagent is settled (being graded) is recorded, so its result will not wake the parent")
    func parentStopDuringGradingIsRecorded() async throws {
        let client = RoutingClient(["WORKER": [calls([("goal_complete", ["summary": .string("done")])])]])
        let state = try state()
        let main = state.createNewConversation()
        let stopped = Box<Int?>(nil)

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: main, background: true,
            client: client, appState: state, endSandboxSession: { _ in
                let n = await MainActor.run { state.stopBackgroundSubagents(under: main) }
                stopped.set(n)
            })

        #expect(stopped.get == 0, "settled: nothing left to stop, so not counted in the notice")
        #expect(outcome.status == .completed)
        #expect(outcome.stoppedBy == .parent)
    }

    @Test("Esc on an idle parent whose only background subagent is being graded records the parent's Stop")
    func escDuringGradingIsRecorded() async throws {
        let client = RoutingClient(["WORKER": [calls([("goal_complete", ["summary": .string("done")])])]])
        let state = try state()
        let main = state.createNewConversation()
        let request = Box<SubagentStopKind?>(nil)
        let interruptible = Box<Bool>(false)

        // `endSandboxSession` runs after the result is settled, while it is being graded.
        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: main, background: true,
            client: client, appState: state, endSandboxSession: { _ in
                await MainActor.run {
                    let worker = state.conversations.first { $0.title == "Subagent: worker" }!.id
                    #expect(state.backgroundSubagents(under: main).isEmpty, "settled: not stoppable")
                    // What `ChatView.handleEscape` does.
                    interruptible.set(state.hasInterruptibleWork(in: state.selectedConversationId))
                    if interruptible.get { state.interruptActiveConversation() }
                    request.set(state.subagentStopRequest(worker))
                }
            })

        #expect(interruptible.get, "Esc's guard passes for a settled background subagent")
        #expect(request.get == .parent)
        // The engine routes the post-back on this: `.parent` delivers without waking the parent.
        #expect(outcome.stoppedBy == .parent)
    }

    @Test("a parent Stop accepted just after goal_complete still does not wake the parent")
    func stopRacingCompletionDoesNotWakeParent() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [
                calls([("invoke_subagent", ["role": .string("worker"), "task": .string("Research."),
                                            "effort": .string("easy"), "background": .string("true")])]),
                text("Spawned it."),
            ],
            "WORKER": [calls([("goal_complete", ["summary": .string("done")])])],
        ])
        let state = try state()
        let main = state.createNewConversation()
        let engine = IrisEngine(state: state, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        state.installEngine(engine)

        await engine.processInput("Start a background worker.", source: "User", conversationId: main)
        // The moment the completion is recorded (its handler clears itself), before the manager's
        // poll sees it and settles: the window the review reproduced 10 of 10.
        var stoppedCount = 0
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if let worker = subagentId("worker", in: state), state.onSubagentComplete[worker] == nil,
               state.conversations.first(where: { $0.id == worker })?.messages.contains(where: { $0.role == .system }) == true,
               state.subagentStopRequest(worker) == nil, !state.backgroundSubagents(under: main, stoppableOnly: false).isEmpty {
                stoppedCount = state.stopBackgroundSubagents(under: main)
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(stoppedCount == 1, "the Stop landed before the result settled")

        let postBacks: @MainActor () -> [ChatMessage] = {
            state.conversations.first { $0.id == main }?.messages
                .filter { $0.content.contains("Background subagent result") } ?? []
        }
        #expect(await eventually { postBacks().count == 1 })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(postBacks().count == 1)
        #expect(postBacks().first?.content.contains(SubagentManager.stoppedAfterCompletionNote) == true)
        #expect(client.callCount(RoutingClient.parent) == 2, "the parent was not woken")
    }

    @Test("a row Stop delivers the result as usual, so the parent can re-plan")
    func rowStopWakesParent() async throws {
        let client = ParkingSubagentsClient(parent: [
            calls([("invoke_subagent", ["role": .string("worker"), "task": .string("Research."),
                                        "effort": .string("easy"), "background": .string("true")])]),
            text("Spawned it."),
            text("Re-planning without it."),
        ])
        let state = try state()
        let main = state.createNewConversation()
        let engine = IrisEngine(state: state, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        state.installEngine(engine)

        await engine.processInput("Start a background worker.", source: "User", conversationId: main)
        #expect(await eventually { client.parkedCalls == 1 })
        let worker = try #require(subagentId("worker", in: state))
        #expect(state.userStoppableSubagents.contains(worker), "the row offers Stop while it works")

        #expect(state.stopSubagent(worker))
        #expect(!state.userStoppableSubagents.contains(worker))

        #expect(await eventually { client.parentCalls == 3 }, "the post-back started a parent turn")
        let postBack = state.conversations.first { $0.id == main }?.messages
            .first { $0.content.contains("Background subagent result") }
        #expect(postBack?.content.contains(SubagentManager.rowStoppedReason) == true)
    }

    @Test("Stop calls a registered stop once it is live and never once it is settled")
    func registryRefusesSettled() throws {
        let state = try state()
        let parent = UUID(), sub = UUID()
        let fired = Box(0)
        state.registerLiveSubagent(sub, parent: parent, background: true, stop: { _ in fired.set(fired.get + 1) })

        #expect(state.stopBackgroundSubagents(under: parent) == 1)
        #expect(fired.get == 1)
        #expect(state.stopBackgroundSubagents(under: parent) == 0, "already stopped")
        state.settleLiveSubagent(sub)
        #expect(state.stopSubagent(sub) == false)
        #expect(state.stopBackgroundSubagents(under: parent) == 0)
        #expect(fired.get == 1)
        state.unregisterLiveSubagent(sub)
    }

    @Test("a foreground subagent is left to its parent's cancellation; a background one it spawned is not")
    func foregroundIsNotStoppedTwice() async throws {
        let state = try state()
        let main = state.createNewConversation()
        let foreground = UUID(), grandchild = UUID()
        let fired = Box<[UUID]>([])
        state.registerLiveSubagent(foreground, parent: main, background: false, stop: { _ in fired.set(fired.get + [foreground]) })
        state.registerLiveSubagent(grandchild, parent: foreground, background: true, stop: { _ in fired.set(fired.get + [grandchild]) })

        #expect(state.stopBackgroundSubagents(under: main) == 1)
        #expect(fired.get == [grandchild], "only the background one; the foreground one stops with the parent's turn")
        state.unregisterLiveSubagent(foreground)
        state.unregisterLiveSubagent(grandchild)
    }

    @Test("a background grandchild is still reached after its foreground parent has left the registry")
    func orphanedGrandchildIsReached() async throws {
        let state = try state()
        let main = state.createNewConversation()
        let foreground = UUID(), grandchild = UUID()
        let fired = Box<[UUID]>([])
        state.registerLiveSubagent(foreground, parent: main, background: false, stop: { _ in fired.set(fired.get + [foreground]) })
        state.registerLiveSubagent(grandchild, parent: foreground, background: true, stop: { _ in fired.set(fired.get + [grandchild]) })
        state.unregisterLiveSubagent(foreground)   // its work ended; the background one it spawned did not

        #expect(state.delegationRoot(of: grandchild) == main, "its asks are still the main session's")
        #expect(state.backgroundSubagents(under: main) == [grandchild])
        #expect(state.stopBackgroundSubagents(under: main) == 1)
        #expect(fired.get == [grandchild])
        state.unregisterLiveSubagent(grandchild)
    }

    @Test("a running foreground subagent stops through its waiting task, with the cancelled-turn reason")
    func foregroundStopsWithTheParentsTurn() async throws {
        let client = ParkingSubagentsClient()
        let state = try state()
        let main = state.createNewConversation()
        let waiting = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: main,
                turnTimeout: 20, client: client, appState: state, endSandboxSession: { _ in })
        }
        #expect(await eventually { client.parkedCalls == 1 })
        #expect(state.backgroundSubagents(under: main).isEmpty)

        waiting.cancel()
        let outcome = await waiting.value
        #expect(outcome.status == .cancelled)
        #expect(outcome.rendered.contains(SubagentManager.cancelledReason))
    }
}
