import Testing
import Foundation
@testable import iris

/// #399 — a subagent runs a goal loop: a turn that ends without `goal_complete` is reprompted, up to
/// the subagent's own iteration cap, and the manager waits for the loop's real end rather than the
/// first turn returning. Stops, deadlines and the run's budget reach whichever turn is live.
/// Scripted clients only; caps are set on stores of the tests' own.
@MainActor
@Suite("A subagent's goal loop (#399)")
struct SubagentGoalLoopTests {

    typealias ManualClock = SubagentRunStopTests.ManualClock

    /// Plays one step per model call, in order; past the script it replies with plain text.
    final class LoopClient: LLMClientProtocol, @unchecked Sendable {
        enum Step: Sendable {
            case reply(GeminiResponse)
            /// Sleeps until cancelled, and counts the cancellation.
            case park
        }
        private let lock = NSLock()
        private var steps: [Step]
        private var callCount = 0
        private var parkedCount = 0
        private var cancelledCount = 0

        init(_ steps: [Step]) { self.steps = steps }

        var calls: Int { lock.withLock { callCount } }
        var parked: Int { lock.withLock { parkedCount } }
        var cancelled: Int { lock.withLock { cancelledCount } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let step: Step? = lock.withLock {
                callCount += 1
                return steps.isEmpty ? nil : steps.removeFirst()
            }
            switch step {
            case .reply(let response)?:
                return response
            case .park?:
                lock.withLock { parkedCount += 1 }
                do {
                    try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                } catch {
                    lock.withLock { cancelledCount += 1 }
                    throw error
                }
                return SubagentGoalLoopTests.text("late")
            case nil:
                return SubagentGoalLoopTests.text("still working")
            }
        }
    }

    // MARK: Fixtures

    nonisolated static func text(_ s: String, total: Int? = nil) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))],
                       usageMetadata: total.map { UsageMetadata(promptTokenCount: $0 - 1, candidatesTokenCount: 1, totalTokenCount: $0) })
    }

    static func goalComplete(_ summary: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(functionCall: FunctionCall(name: "goal_complete", args: ["summary": .string(summary)]))]))],
                       usageMetadata: nil)
    }

    private func state() throws -> AppState {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        return state
    }

    /// A background run registered as `JobRunner` registers one, so the subagent is on its registry.
    private func run(in state: AppState, maxTokens: Int = 100_000) -> UUID {
        let run = state.createNewConversation(isBackground: true, select: false)
        state.registerRun(run, budget: TurnBudget(maxTokens: maxTokens, deadline: Date().addingTimeInterval(600)),
                          sink: DelegatedSpendTests.RecordingSink())
        return run
    }

    /// A `ConfigManager` over a suite of the test's own, with the subagent cap set.
    private func config(cap: Int) -> (ConfigManager, () -> Void) {
        let name = "iris-subagentloop-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let config = ConfigManager(store: store)
        config.maxSubagentIterations = cap
        return (config, {
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

    // MARK: The loop

    @Test("a subagent whose first turn is text only is reprompted, and the parent gets turn 2's result")
    func secondTurnResultReachesTheParent() async throws {
        let client = LoopClient([.reply(Self.text("Looking into it.")), .reply(Self.goalComplete("TURN2-SUMMARY"))])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(cap: 5); defer { teardown() }

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            maxIterations: 300, client: client, appState: state, config: config, endSandboxSession: { _ in })

        #expect(outcome.status == .completed)
        #expect(outcome.rendered.contains("TURN2-SUMMARY"))
        #expect(client.calls == 2)
    }

    @Test("a subagent that never calls goal_complete stops at its iteration cap, failed, saying so")
    func capEndsTheLoopAtN() async throws {
        let client = LoopClient([])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(cap: 2); defer { teardown() }

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            maxIterations: 300, client: client, appState: state, config: config, endSandboxSession: { _ in })

        #expect(outcome.status == .failed)
        #expect(outcome.rendered.contains("reached its iteration cap (2)"))
        #expect(client.calls == 2, "two turns, no summary turn past the cap")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(client.calls == 2, "nothing runs after the cap")
    }

    @Test("the subagent cap is its own setting: default 10, persisted, a bad value read as the default")
    func capSetting() {
        let name = "iris-subagentloop-cap-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        #expect(ConfigManager(store: store).maxSubagentIterations == 10)
        ConfigManager(store: store).maxSubagentIterations = 7
        #expect(ConfigManager(store: store).maxSubagentIterations == 7)
        #expect(ConfigManager(store: store).maxGoalIterations == 50, "the main agent's cap is untouched")
        store.set(-3, forKey: "MAX_SUBAGENT_ITERATIONS")
        #expect(ConfigManager(store: store).maxSubagentIterations == 10)
    }

    @Test("the role prompt tells the subagent it loops, and its cap")
    func rolePromptNamesTheCap() {
        let prompt = SubagentManager.shared.generateRolePrompt(role: "worker", iterationCap: 4)
        #expect(prompt.contains("at most 4 turns"))
        #expect(prompt.contains("goal_complete"))
    }

    // MARK: Stops under the loop

    @Test("cancelling the parent during turn 2 cancels that turn at once, and nothing is reprompted after")
    func cancelDuringTurnTwo() async throws {
        let client = LoopClient([.reply(Self.text("Looking into it.")), .park])
        let state = try state()
        let run = run(in: state)
        let (config, teardown) = config(cap: 5); defer { teardown() }

        let task = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: run,
                maxIterations: 3000, client: client, appState: state, config: config, endSandboxSession: { _ in })
        }
        #expect(await eventually { client.parked == 1 }, "turn 2 is under way")
        #expect(client.calls == 2)
        #expect(state.liveSubagents(ofRun: run).count == 1, "registered while it works")
        let cancelledAt = Date()
        task.cancel()
        let outcome = await task.value

        #expect(Date().timeIntervalSince(cancelledAt) < 2, "seconds, not the poll cap")
        #expect(outcome.status == .cancelled)
        #expect(await eventually(2) { client.cancelled == 1 }, "turn 2's model call was cancelled")
        #expect(await eventually { state.liveSubagents(ofRun: run).isEmpty })
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(client.calls == 2, "no reprompt after the cancel")
    }

    @Test("the deadline during turn 2 times the subagent out and cancels that turn")
    func deadlineDuringTurnTwo() async throws {
        let client = LoopClient([.reply(Self.text("Looking into it.")), .park])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(cap: 5); defer { teardown() }
        let clock = ManualClock()

        let task = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
                maxIterations: 3000, client: client, appState: state, deadlineClock: clock.now,
                config: config, endSandboxSession: { _ in })
        }
        #expect(await eventually { client.parked == 1 }, "turn 2 is under way")
        clock.advance(by: 10_000)
        let outcome = await task.value

        #expect(outcome.status == .timedOut)
        #expect(await eventually(2) { client.cancelled == 1 }, "turn 2's model call was cancelled")
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(client.calls == 2, "no reprompt after the deadline")
    }

    @Test("a subagent stays registered until its live turn has returned, not just turn 1")
    func registryWaitsForTheLiveTurn() async throws {
        // Turn 2 calls goal_complete beside a command that outlasts it: the parent has its result
        // while turn 2 is still running that command, and the subagent is still alive until then.
        let both = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(functionCall: FunctionCall(name: "goal_complete", args: ["summary": .string("done")])),
            Part(functionCall: FunctionCall(name: "run_command", args: ["command": .string("sleep 2")])),
        ]))], usageMetadata: nil)
        let client = LoopClient([.reply(Self.text("Looking into it.")), .reply(both)])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(cap: 5); defer { teardown() }

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            maxIterations: 300, client: client, appState: state, config: config, endSandboxSession: { _ in })
        let returnedAt = Date()
        #expect(outcome.status == .completed)
        let sub = try #require(state.conversations.first { $0.isSubagent }?.id)

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(state.liveSubagents(ofRun: sub).count == 1, "turn 2 is still running its command, so it is still registered")
        #expect(await eventually { state.liveSubagents(ofRun: sub).isEmpty })
        #expect(Date().timeIntervalSince(returnedAt) > 1, "it went when the command did, not before")
        try? await Task.sleep(nanoseconds: 1_700_000_000)
        #expect(client.calls == 2, "the finished loop reprompts nothing")
    }

    @Test("the run's budget refusing turn 2 ends the subagent there, saying the budget stopped it")
    func budgetRefusesTurnTwo() async throws {
        let client = LoopClient([.reply(Self.text("Looking into it.", total: 500))])
        let state = try state()
        let run = run(in: state, maxTokens: 100)
        let (config, teardown) = config(cap: 5); defer { teardown() }

        let started = Date()
        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: run,
            maxIterations: 300, client: client, appState: state, config: config, endSandboxSession: { _ in })

        #expect(Date().timeIntervalSince(started) < 5)
        #expect(outcome.status == .failed)
        #expect(outcome.rendered.contains("Stopped by the background run's budget"))
        #expect(client.calls == 1, "turn 2's round was refused, not made")
        #expect(await eventually { state.liveSubagents(ofRun: run).isEmpty })
    }

    @Test("a hook-blocked reprompt ends the loop promptly, not at the poll cap")
    func hookBlockedTurnEndsPromptly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-subagentloop-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Blocks the reprompt ("Continue working…") and lets the first turn through.
        let settings = dir.appendingPathComponent("settings.json")
        try """
        {"hooks": {"BeforeAgent": [{"matcher": "BeforeAgent", "hooks": [
          {"type": "command", "command": "if grep -q 'Continue working'; then echo 'no reprompts' >&2; exit 2; fi; exit 0"}
        ]}]}}
        """.write(to: settings, atomically: true, encoding: .utf8)
        var hooks = HookManager()
        hooks.configPathOverride = settings.path

        let client = LoopClient([.reply(Self.text("Looking into it."))])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(cap: 5); defer { teardown() }

        let started = Date()
        // A 30 s poll cap: were the blocked turn waited on, the result would read `timed out`.
        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            maxIterations: 300, client: client, appState: state, config: config, hooks: hooks,
            endSandboxSession: { _ in })

        #expect(Date().timeIntervalSince(started) < 10)
        #expect(outcome.status == .failed)
        #expect(client.calls == 1, "turn 2 was blocked before its model call")
        let sub = state.conversations.first { $0.isSubagent }
        #expect(sub?.messages.contains { $0.content.contains("Hook blocked turn") } == true,
                "the hook, not something else, ended the loop")
    }
}
