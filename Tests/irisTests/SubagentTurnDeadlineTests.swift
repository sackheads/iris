import Testing
import Foundation
@testable import IrisKit

/// #402 — a subagent's deadline is per turn, restarted whenever a turn begins, not one limit on the
/// whole subagent. Scripted clients move an injected clock from inside their model calls, so a turn
/// "takes" as long as the test says and nothing waits on a real wall clock. Limits are set on stores
/// of the tests' own.
@MainActor
@Suite("A subagent's per-turn deadline (#402)", .timeLimit(.minutes(1)))
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

    /// The turn events `runSubagent` recorded, in order; `then` runs after each one is logged.
    /// Moving the clock from here puts the move at a known point in the turn sequence: a real-time
    /// wait for "the turn has ended" let a busy suite land it inside the turn instead (#410).
    final class TurnEvents: @unchecked Sendable {
        struct Event: Equatable, Sendable, CustomStringConvertible {
            let began: Bool, seq: Int
            var description: String { "\(began ? "begin" : "end") \(seq)" }
        }
        private let lock = NSLock()
        private var log: [Event] = []
        private let then: @Sendable (Event) -> Void
        init(then: @escaping @Sendable (Event) -> Void = { _ in }) { self.then = then }
        func record(_ began: Bool, _ seq: Int) {
            let event = Event(began: began, seq: seq)
            lock.withLock { log.append(event) }
            then(event)
        }
        var all: [Event] { lock.withLock { log } }
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
        let outcome = try await value(of: task)

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
        let outcome = try await value(of: task)

        #expect(outcome.status == .timedOut)
        #expect(await eventually(10) { client.cancelled == 1 }, "turn 2's model call was cancelled")
        #expect(client.calls == 2)
    }

    // MARK: Review fixes (#403)

    /// Blocks the calling thread: from a MainActor test, that holds the main actor.
    static func block(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    @Test("a turn that ends just under the limit is followed by a turn that completes: the gap between turns does not count")
    func gapBetweenTurnsDoesNotCount() async throws {
        // Turn 1 takes 599 s of 600, and 5 s pass while no turn runs: the reprompt pause.
        let clock = ManualClock()
        let client = ClockClient(clock: clock, [
            .take(599, SubagentGoalLoopTests.text("Step one done.")),
            .take(1, SubagentGoalLoopTests.goalComplete("TURN-TWO-DONE")),
        ])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(turnTimeout: 600); defer { teardown() }
        // The idle time lands as turn 1's end is recorded, never earlier. The reprompt pause is
        // real, but only so the poll sleeps through a gap that, if it counted, would time out.
        let events = TurnEvents { if !$0.began && $0.seq == 1 { clock.advance(by: 5) } }

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            client: client, appState: state, deadlineClock: clock.now, config: config,
            repromptDelay: 1.0, onTurnEvent: events.record, endSandboxSession: { _ in })

        #expect(Array(events.all.prefix(3)) == [.init(began: true, seq: 1), .init(began: false, seq: 1),
                                                .init(began: true, seq: 2)],
                "the idle time fell between the turns")
        #expect(outcome.status == .completed)
        #expect(outcome.rendered.contains("TURN-TWO-DONE"))
        #expect(client.calls == 2)
    }

    @Test("a loop that ends failed is reported failed, not timed out, when the limit passes after its last turn")
    func failedLoopIsNotReportedTimedOut() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-subagentturn-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Blocks the reprompt, so the loop ends without a termination and goes to the grace polls.
        let settings = dir.appendingPathComponent("settings.json")
        try """
        {"hooks": {"BeforeAgent": [{"matcher": "BeforeAgent", "hooks": [
          {"type": "command", "command": "if grep -q 'Continue working'; then echo 'no reprompts' >&2; exit 2; fi; exit 0"}
        ]}]}}
        """.write(to: settings, atomically: true, encoding: .utf8)
        var hooks = HookManager()
        hooks.configPathOverride = settings.path

        let clock = ManualClock()
        let client = ClockClient(clock: clock, [.take(1, SubagentGoalLoopTests.text("Looking into it."))])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(turnTimeout: 600); defer { teardown() }
        // The limit passes once the blocked reprompt has ended, while no turn is running: on the
        // recorded end, before the loop reads as over, so before the grace polls start.
        let events = TurnEvents { if !$0.began && $0.seq == 2 { clock.advance(by: 700) } }

        let outcome = await SubagentManager.shared.runSubagent(
            role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
            client: client, appState: state, deadlineClock: clock.now, config: config, hooks: hooks,
            repromptDelay: 0.01, onTurnEvent: events.record, endSandboxSession: { _ in })

        #expect(events.all.contains(.init(began: false, seq: 2)), "the limit passed after the blocked turn")
        #expect(state.conversations.first { $0.isSubagent }?.messages.contains { $0.content.contains("Hook blocked turn") } == true)
        #expect(outcome.status == .failed)
        #expect(!outcome.rendered.contains("timed out"))
        #expect(client.calls == 1)
    }

    @Test("a turn-2 timeout halts the loop at the verdict, before any MainActor hop, so the turn stops there")
    func turnTwoTimeoutHaltsBeforeTheMainActorHop() async throws {
        let clock = ManualClock()
        let client = ClockClient(clock: clock, [.take(1, SubagentGoalLoopTests.text("Step one done.")), .park])
        let state = try state()
        let parent = UUID(); state.createNewConversation(id: parent)
        let (config, teardown) = config(turnTimeout: 600); defer { teardown() }

        let task = Task {
            await SubagentManager.shared.runSubagent(
                role: "worker", task: "Work.", effort: "easy", parentConversationId: parent,
                client: client, appState: state, deadlineClock: clock.now, config: config,
                repromptDelay: 0.01, endSandboxSession: { _ in })
        }
        #expect(await eventually { client.parked == 1 }, "turn 2 is under way")
        clock.advance(by: 700)
        // Hold the main actor through the verdict: the cleanup after the poll loop needs it, so
        // turn 2 can only be cancelled while it is held if the timeout itself halted the loop.
        // Held until the cancel lands, not for a fixed time a busy suite's poll can outlast (#410).
        let holdUntil = Date().addingTimeInterval(10)
        while client.cancelled == 0, Date() < holdUntil { Self.block(seconds: 0.01) }
        let cancelledWhileMainHeld = client.cancelled
        let outcome = try await value(of: task)

        #expect(cancelledWhileMainHeld == 1, "turn 2 was cancelled at the verdict, not after a MainActor hop")
        #expect(outcome.status == .timedOut)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.calls == 2, "nothing ran after the timeout")
    }
}

/// #406 review: `GoalLoopControl` calls its turn observer outside its lock, so turn k's end can be
/// delivered after turn k+1's begin. Plain threads, not the cooperative pool, so the ordering is
/// forced with semaphores; every wait is bounded, so a regression fails rather than hangs.
@Suite("A subagent's turn start under out-of-order turn events (#402)", .timeLimit(.minutes(1)))
struct SubagentTurnStartOrderingTests {

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ d: Date) { value = d }
        var now: Date { lock.withLock { value } }
        func set(_ d: Date) { lock.withLock { value = d } }
    }

    @Test("turn k's end delivered after turn k+1's begin leaves k+1 its deadline")
    func lateEndOfAnOlderTurnIsIgnored() {
        let control = GoalLoopControl()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let clock = Box(t0)
        let tracker = SubagentTurnStart(t0)
        let endOfTurnOneEntered = DispatchSemaphore(value: 0)
        let releaseEndOfTurnOne = DispatchSemaphore(value: 0)
        control.observeTurns(for: id) { began, seq in
            if !began && seq == 1 {
                endOfTurnOneEntered.signal()
                _ = releaseEndOfTurnOne.wait(timeout: .now() + 10)
            }
            tracker.record(began: began, seq: seq, at: clock.now)
        }

        control.beginTurn(for: id)                     // turn 1
        let endDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { control.endTurn(for: id); endDone.signal() }
        #expect(endOfTurnOneEntered.wait(timeout: .now() + 5) == .success, "turn 1's end is being delivered")

        // Turn 2 begins while turn 1's end is still on its way.
        let t2 = t0.addingTimeInterval(10)
        clock.set(t2)
        let beginDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { control.beginTurn(for: id); beginDone.signal() }
        #expect(beginDone.wait(timeout: .now() + 5) == .success, "the observer is not called under the lock")
        #expect(tracker.start == t2)

        clock.set(t0.addingTimeInterval(20))
        releaseEndOfTurnOne.signal()
        #expect(endDone.wait(timeout: .now() + 5) == .success)
        #expect(tracker.start == t2, "turn 1's late end did not clear turn 2's start")
    }

    @Test("a turn's begin delivered after its own end does not restart the deadline")
    func lateBeginOfAnEndedTurnIsIgnored() {
        let tracker = SubagentTurnStart(Date(timeIntervalSince1970: 0))
        tracker.record(began: false, seq: 1, at: Date(timeIntervalSince1970: 5))
        tracker.record(began: true, seq: 1, at: Date(timeIntervalSince1970: 6))
        #expect(tracker.start == nil)
        tracker.record(began: true, seq: 2, at: Date(timeIntervalSince1970: 7))
        #expect(tracker.start == Date(timeIntervalSince1970: 7))
    }
}
