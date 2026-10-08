import Testing
import Foundation
@testable import iris

/// #402 — a subagent's deadline is per turn, restarted whenever a turn begins, not one limit on the
/// whole subagent. Scripted clients move an injected clock from inside their model calls, so a turn
/// "takes" as long as the test says and nothing waits on a real wall clock. Limits are set on stores
/// of the tests' own.
@MainActor
@Suite("A subagent's per-turn deadline (#402)")
struct SubagentTurnDeadlineTests {

    typealias ManualClock = SubagentRunStopTests.ManualClock

    /// One step per model call, in order; past the script it parks.
    final class ClockClient: LLMClientProtocol, @unchecked Sendable {
        enum Step: Sendable {
            /// Moves the clock by `seconds`, then holds the turn open long enough for several of
            /// `runSubagent`'s 100 ms polls to see the moved clock, then replies.
            case take(TimeInterval, GeminiResponse)
            /// Sleeps until cancelled, and counts the cancellation.
            case park
        }
        private let lock = NSLock()
        private var steps: [Step]
        private var callCount = 0
        private var parkedCount = 0
        private var cancelledCount = 0
        let clock: ManualClock

        init(clock: ManualClock, _ steps: [Step]) { self.clock = clock; self.steps = steps }

        var calls: Int { lock.withLock { callCount } }
        var parked: Int { lock.withLock { parkedCount } }
        var cancelled: Int { lock.withLock { cancelledCount } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let step: Step = lock.withLock {
                callCount += 1
                return steps.isEmpty ? .park : steps.removeFirst()
            }
            switch step {
            case .take(let seconds, let response):
                clock.advance(by: seconds)
                try await Task.sleep(nanoseconds: 400_000_000)
                return response
            case .park:
                lock.withLock { parkedCount += 1 }
                do {
                    try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                } catch {
                    lock.withLock { cancelledCount += 1 }
                    throw error
                }
                return SubagentGoalLoopTests.text("late")
            }
        }
    }

    final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func set() { lock.withLock { done = true } }
        var isSet: Bool { lock.withLock { done } }
    }

    private func state() throws -> AppState {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        return state
    }

    private func config(turnTimeout: Int, cap: Int = 5) -> (ConfigManager, () -> Void) {
        let name = "iris-subagentturn-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let config = ConfigManager(store: store)
        config.maxSubagentIterations = cap
        config.subagentTurnTimeoutSeconds = turnTimeout
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

    @Test("the turn timeout is its own setting: default 900 s, persisted, a bad value read as the default")
    func setting() {
        let name = "iris-subagentturn-setting-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        #expect(ConfigManager(store: store).subagentTurnTimeoutSeconds == 900)
        ConfigManager(store: store).subagentTurnTimeoutSeconds = 1200
        #expect(ConfigManager(store: store).subagentTurnTimeoutSeconds == 1200)
        store.set(-5, forKey: "SUBAGENT_TURN_TIMEOUT_SECONDS")
        #expect(ConfigManager(store: store).subagentTurnTimeoutSeconds == 900)
    }

    @Test("the role prompt gives the subagent its per-turn limit")
    func rolePromptNamesTheLimit() {
        let prompt = SubagentManager.shared.generateRolePrompt(role: "worker", iterationCap: 4, turnTimeout: 900)
        #expect(prompt.contains("at most 15 min"))
    }

    @Test("a subagent whose turns together pass 5 minutes, each under the limit, completes")
    func longLoopOfShortTurnsCompletes() async throws {
        // Three turns of 200 s each against a 300 s limit: 600 s in all, twice the old total.
        let clock = ManualClock()
        let client = ClockClient(clock: clock, [
            .take(200, SubagentGoalLoopTests.text("Step one done.")),
            .take(200, SubagentGoalLoopTests.text("Step two done.")),
            .take(200, SubagentGoalLoopTests.goalComplete("ALL-THREE-DONE")),
        ])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(turnTimeout: 300); defer { teardown() }
        let start = clock.now()

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            client: client, appState: state, deadlineClock: clock.now, config: config,
            repromptDelay: 0.01, endSandboxSession: { _ in })

        #expect(clock.now().timeIntervalSince(start) == 600, "the whole subagent took ten minutes")
        #expect(outcome.status == .completed)
        #expect(outcome.rendered.contains("ALL-THREE-DONE"))
        #expect(client.calls == 3)
    }

    @Test("a single turn past the limit times the subagent out, names the limit, and cancels the turn")
    func oneLongTurnTimesOut() async throws {
        let clock = ManualClock()
        let client = ClockClient(clock: clock, [.park])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(turnTimeout: 600); defer { teardown() }
        let finished = Finished()

        let task = Task {
            let outcome = await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
                client: client, appState: state, deadlineClock: clock.now, config: config,
                repromptDelay: 0.01, endSandboxSession: { _ in })
            finished.set()
            return outcome
        }
        #expect(await eventually { client.parked == 1 }, "turn 1 is under way")
        clock.advance(by: 599)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(!finished.isSet, "still inside the limit")
        clock.advance(by: 2)
        #expect(await eventually(20) { finished.isSet }, "the limit ended it")
        if !finished.isSet { task.cancel() }  // a failure, not a hang
        let outcome = await task.value

        #expect(outcome.status == .timedOut)
        #expect(outcome.rendered.contains("per-turn limit (10 min)"))
        #expect(await eventually(10) { client.cancelled == 1 }, "the turn's model call was cancelled")
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls == 1, "no reprompt after the timeout")
    }

    @Test("the deadline restarts on each reprompt, and still bounds the later turn")
    func deadlineResetsOnReprompt() async throws {
        // Turn 1 takes 500 s of a 600 s limit, then turn 2 parks. Without a restart the limit
        // would fall 100 s into turn 2; with one, it falls 600 s into it.
        let clock = ManualClock()
        let client = ClockClient(clock: clock, [.take(500, SubagentGoalLoopTests.text("Step one done.")), .park])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(turnTimeout: 600); defer { teardown() }
        let finished = Finished()

        let task = Task {
            let outcome = await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
                client: client, appState: state, deadlineClock: clock.now, config: config,
                repromptDelay: 0.01, endSandboxSession: { _ in })
            finished.set()
            return outcome
        }
        #expect(await eventually { client.parked == 1 }, "turn 2 is under way")
        clock.advance(by: 500)  // 1000 s since the start, 500 s into turn 2
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(!finished.isSet, "turn 2 is still inside its own limit")
        clock.advance(by: 200)  // 700 s into turn 2
        #expect(await eventually(20) { finished.isSet }, "turn 2's own limit ended it")
        if !finished.isSet { task.cancel() }  // a failure, not a hang
        let outcome = await task.value

        #expect(outcome.status == .timedOut)
        #expect(await eventually(10) { client.cancelled == 1 }, "turn 2's model call was cancelled")
        #expect(client.calls == 2)
    }
}
