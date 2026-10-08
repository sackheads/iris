import Testing
import Foundation
@testable import iris

/// #323 — a background run's subagents stop with the run: at once and saying why when the run's
/// budget refuses their next round, and cancelled — model call included — when the run's turn is
/// cancelled at its deadline or the run is drained. Scripted clients only.
@MainActor
@Suite("A run's subagents stop with the run (#323)")
struct SubagentRunStopTests {

    typealias RoutingClient = DelegatedSpendTests.RoutingClient

    /// A client whose `role` call parks until it is cancelled, and says whether it was. Every
    /// other call is answered from the routing queues.
    final class ParkingClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var entered = 0
        private var cancelled = 0
        private let role: String
        private let routed: RoutingClient

        init(parking role: String, otherwise queues: [String: [GeminiResponse]]) {
            self.role = role
            self.routed = RoutingClient(queues)
        }

        var parkedCalls: Int { lock.withLock { entered } }
        var cancelledCalls: Int { lock.withLock { cancelled } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let prompt = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            guard prompt.contains("subagent role: **\(role)**") else {
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

    // MARK: Fixtures

    private func usage(_ total: Int) -> UsageMetadata {
        UsageMetadata(promptTokenCount: total - 1, candidatesTokenCount: 1, totalTokenCount: total)
    }

    private func calls(_ list: [(String, [String: JSONValue])], total: Int) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: list.map { Part(functionCall: FunctionCall(name: $0.0, args: $0.1)) }))],
                       usageMetadata: usage(total))
    }

    private func delegate(_ role: String) -> (String, [String: JSONValue]) {
        ("invoke_subagent", ["role": .string(role), "task": .string("Do the \(role) part."), "effort": .string("easy")])
    }

    private func state() throws -> AppState {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        return state
    }

    /// A background run registered as `JobRunner` registers one.
    private func run(in state: AppState, maxTokens: Int = 100_000) -> UUID {
        let run = state.createNewConversation(isBackground: true, select: false)
        state.registerRun(run, budget: TurnBudget(maxTokens: maxTokens, deadline: Date().addingTimeInterval(600)),
                          sink: DelegatedSpendTests.RecordingSink())
        return run
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-subagentrunstop-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    /// Polls `condition` for up to `seconds`; false if it never held.
    private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: Budget

    @Test("a subagent the run's budget refuses ends at once, and the parent is told the budget stopped it")
    func budgetRefusalIsTerminal() async throws {
        let client = RoutingClient(["WORKER": [calls([("noop_probe", [:])], total: 500)]])
        let state = try state()
        let run = run(in: state, maxTokens: 100)

        let started = Date()
        // A 30 s poll cap: were the refusal not terminal the subagent would run into it and read
        // `timed out`, rather than spending the five-minute default.
        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: run,
            maxIterations: 300, client: client, appState: state, endSandboxSession: { _ in })

        // Only shows the subagent stopped well before its poll cap, not how fast; the full parallel suite runs it at ~4 s.
        #expect(Date().timeIntervalSince(started) < 10, "seconds, not the poll cap")
        #expect(client.callCount("WORKER") == 1, "the second round was refused, not made")
        #expect(outcome.status == .failed)
        #expect(outcome.rendered.contains("status: failed"))
        #expect(outcome.rendered.contains("Stopped by the background run's budget"),
                "the parent reads that the budget stopped it, not a generic give-up")
        #expect(outcome.rendered.contains(TurnBudget.weightedTokensExceeded))
        #expect(await eventually { state.liveSubagents(ofRun: run).isEmpty })
    }

    @Test("a job run whose subagent the budget refuses gets the budget-stopped result in its transcript")
    func budgetRefusalReachesTheParent() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 10)],
            "WORKER": [calls([("noop_probe", [:])], total: 500)],
        ])
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let main = UUID()
        state.createNewConversation(id: main)
        let engine = IrisEngine(state: state, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        var job = Job(name: "budgeted", prompt: "Work.", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        job.policy.perRunTokenBudget = 100
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true })

        let started = Date()
        await runner.fire(job: job, origin: .schedule)

        #expect(Date().timeIntervalSince(started) < 10)
        let row = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(row.status == .failed)
        let transcript = try #require(state.conversations.first { $0.id == row.transcriptConversationId })
        let results = transcript.history.flatMap(\.parts).compactMap(\.functionResponse)
        #expect(results.contains { $0.response.values.contains {
            $0.stringValue.contains("Stopped by the background run's budget")
        } }, "the invoke_subagent result says the budget stopped the subagent")
    }

    // MARK: Cancellation

    @Test("cancelling the task waiting on a subagent cancels its model call, and the result says cancelled")
    func cancellationReachesTheSubagent() async throws {
        let client = ParkingClient(parking: "WORKER", otherwise: [:])
        let state = try state()
        let run = run(in: state)
        let ended = Recorder()

        let waiting = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: run,
                maxIterations: 100, client: client, appState: state, endSandboxSession: { id in
                    // A cancelled task never launches `container delete`, so only an uncancelled
                    // call counts as freeing the container.
                    if !Task.isCancelled { ended.add(id) }
                })
        }
        #expect(await eventually { client.parkedCalls == 1 }, "the subagent is inside its model call")
        let subagent = try #require(state.liveSubagents(ofRun: run).first)

        let cancelledAt = Date()
        waiting.cancel()
        let outcome = await waiting.value

        #expect(Date().timeIntervalSince(cancelledAt) < 5, "the poll cap is ten seconds: this is the cancel")
        #expect(outcome.status == .cancelled)
        #expect(outcome.rendered.contains("status: cancelled"))
        #expect(outcome.rendered.contains(SubagentManager.cancelledReason))
        #expect(await eventually { client.cancelledCalls == 1 }, "the in-flight model call was cancelled")
        #expect(await eventually { state.liveSubagents(ofRun: run).isEmpty }, "no subagent task outlives the cancel")
        #expect(ended.all == [subagent], "its container is freed even though the caller was cancelled")
    }

    @Test("draining a run stops a subagent still working for it")
    func drainStopsTheRunsSubagents() async throws {
        let client = ParkingClient(parking: "WORKER", otherwise: [:])
        let state = try state()
        let run = run(in: state)

        // Unstructured and never cancelled: only the drain can reach it.
        let waiting = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: run,
                maxIterations: 100, client: client, appState: state, endSandboxSession: { _ in })
        }
        #expect(await eventually { client.parkedCalls == 1 })
        #expect(state.liveSubagents(ofRun: run).count == 1)

        _ = state.takeBackgroundDenials(for: run)
        let outcome = await waiting.value

        #expect(outcome.status == .cancelled, "stopped by the drain, not left to the poll cap")
        #expect(outcome.rendered.contains(SubagentManager.runEndedReason))
        #expect(await eventually { client.cancelledCalls == 1 })
        #expect(await eventually { state.liveSubagents(ofRun: run).isEmpty })
    }

    @Test("a job run's deadline cancels the subagent it is waiting on")
    func deadlineReachesTheSubagent() async throws {
        let client = ParkingClient(parking: "WORKER", otherwise: [
            RoutingClient.parent: [calls([delegate("worker")], total: 10)],
        ])
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let main = UUID()
        state.createNewConversation(id: main)
        let engine = IrisEngine(state: state, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
        var job = Job(name: "slow-delegator", prompt: "Work.", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        job.policy.runTimeoutSeconds = 600
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let clock = ManualClock()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true },
                               watchdogSlice: 0.01, deadlineClock: clock.now)

        let fire = Task { await runner.fire(job: job, origin: .schedule) }
        #expect(await eventually { client.parkedCalls == 1 }, "the run is waiting on its subagent's model call")
        let row = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let runConversation = try #require(row.transcriptConversationId)
        #expect(state.liveSubagents(ofRun: runConversation).count == 1)

        clock.advance(by: 601)
        await fire.value

        let closed = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(closed.failureReason == TurnBudget.timeExceeded)
        #expect(await eventually { client.cancelledCalls == 1 }, "the subagent's model call was cancelled")
        #expect(await eventually { state.liveSubagents(ofRun: runConversation).isEmpty },
                "no subagent task outlives its run")
        let worker = try #require(state.conversations.first { $0.title == "Subagent: worker" })
        #expect(await eventually { state.conversations.first { $0.id == worker.id }?.subagentResult?.status == .cancelled })
    }

    // MARK: Containers (#291)

    @Test("a subagent that completes frees its container")
    func completedSubagentEndsItsSession() async throws {
        let client = RoutingClient(["WORKER": [calls([("goal_complete", ["summary": .string("done")])], total: 1)]])
        let state = try state()
        let parent = state.createNewConversation(select: false)
        let ended = Recorder()

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            client: client, appState: state, endSandboxSession: { ended.add($0) })

        #expect(outcome.status == .completed)
        let worker = try #require(state.conversations.first { $0.title == "Subagent: worker" })
        #expect(ended.all == [worker.id])
    }
}
