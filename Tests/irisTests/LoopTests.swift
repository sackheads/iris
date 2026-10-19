import Testing
import Foundation
import SwiftUI
@testable import IrisKit

/// #190: `/loop` re-runs a prompt in the same visible conversation on a cadence, on `/goal`'s
/// reprompt machinery, never as a job. Each test builds its own `AppState`, store and engine
/// (Invariant 7); intervals are fractions of a second, set past the command's one-minute floor.
@MainActor
@Suite("/loop (#190)", .timeLimit(.minutes(1)))
struct LoopTests {
    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    private func app(replies: Int = 6, latencyMs: Int = 0) throws -> (AppState, UUID) {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-190-\(UUID().uuidString)")
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: (1...replies).map { text("reply \($0)") },
                                                      latency: .init(minMs: latencyMs, maxMs: latencyMs)),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0, repromptDelay: 0.01)
        state.installEngine(engine)
        let id = state.createNewConversation(isBackground: false, select: true)
        return (state, id)
    }

    private func conversation(_ state: AppState, _ id: UUID) -> Conversation? {
        state.conversations.first { $0.id == id }
    }

    /// The user-role texts the model was sent in `id`, oldest first.
    private func sent(_ state: AppState, _ id: UUID) -> [String] {
        (conversation(state, id)?.history ?? []).filter { $0.role == "user" }.flatMap(\.parts).compactMap(\.text)
    }

    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = TestClock.deadline(seconds)
        while TestClock.now() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: the command

    @Test("the command parses an interval and a prompt, and its controls, and refuses the rest with the usage")
    func parse() {
        #expect(ConversationLoop.parse("10m check my PRs") == .start(intervalSeconds: 600, prompt: "check my PRs"))
        #expect(ConversationLoop.parse("2h  look again ") == .start(intervalSeconds: 7200, prompt: "look again"))
        #expect(ConversationLoop.parse("1d x") == .start(intervalSeconds: 86400, prompt: "x"))
        #expect(ConversationLoop.parse("10M x") == .start(intervalSeconds: 600, prompt: "x"), "units in either case")
        #expect(ConversationLoop.parse("") == .status)
        #expect(ConversationLoop.parse(" STOP ") == .stop)
        #expect(ConversationLoop.parse("pause") == .pause)
        #expect(ConversationLoop.parse("resume") == .resume)
        for bad in ["check my PRs", "10m", "10x check", "30s too often", "2d too rare", "0m nothing", "-5m x"] {
            guard case .invalid = ConversationLoop.parse(bad) else { Issue.record("\(bad) should be refused"); continue }
        }
        #expect(ConversationLoop.describe(seconds: 600) == "10m")
        #expect(ConversationLoop.describe(seconds: 90) == "90s")
    }

    @Test("refused in Iris, in a background or subagent conversation, and while a goal runs")
    func refusals() throws {
        let (state, id) = try app()
        var conv = try #require(conversation(state, id))
        #expect(state.loopRefusal(conv) == nil)
        conv.isPinned = true
        #expect(state.loopRefusal(conv)?.contains("Iris can't run a loop") == true)
        conv.isPinned = false; conv.isBackground = true
        #expect(state.loopRefusal(conv) != nil)
        conv.isBackground = false; conv.isSubagent = true
        #expect(state.loopRefusal(conv) != nil)
        conv.isSubagent = false; conv.activeGoal = "ship it"
        #expect(state.loopRefusal(conv)?.contains("A goal is running") == true)
    }

    @Test("a /loop and a /goal never run at once: each refuses while the other is active")
    func goalAndLoopExclude() throws {
        let (state, id) = try app()
        // A loop first: /goal is refused, naming the loop.
        state.startLoop(ConversationLoop(prompt: "watch", intervalSeconds: 3600, cap: 3), in: id)
        state.sendMessage("/goal build a thing")
        #expect(conversation(state, id)?.messages.last?.content.contains("A loop is running in this conversation") == true)
        #expect(conversation(state, id)?.activeGoal == nil)
        // A goal's Approve is refused the same way.
        state.approveGoalContract(for: id, GoalContract(objective: "x", criteria: [Criterion(text: "c", kind: .qualitative)]))
        #expect(conversation(state, id)?.goalContract == nil)
        // A goal first: /loop is refused, naming the goal.
        #expect(state.clearLoop(for: id))
        let index = try #require(state.conversations.firstIndex { $0.id == id })
        state.conversations[index].activeGoal = "ship it"
        state.sendMessage("/loop 10m watch")
        #expect(conversation(state, id)?.loop == nil)
        #expect(conversation(state, id)?.messages.last?.content.contains("A goal is running") == true)
    }

    // MARK: ticks

    @Test("ticks run in the same conversation as Loop turns, count down, and stop at the cap with one line")
    func ticksRunAndStopAtCap() async throws {
        let (state, id) = try app()
        state.startLoop(ConversationLoop(prompt: "check the build", intervalSeconds: 0.05, cap: 2), in: id)
        #expect(await eventually { conversation(state, id)?.loop == nil }, "the loop ended at its cap")
        let ticks = sent(state, id).filter { $0.hasPrefix("Loop tick ") }
        #expect(ticks.count == 2, "\(sent(state, id))")
        #expect(ticks.first?.contains("Do this loop's task again now: check the build") == true)
        #expect(ticks.first?.hasPrefix("Loop tick 1 of 2") == true && ticks.last?.hasPrefix("Loop tick 2 of 2") == true)
        #expect(!ticks.contains { $0.contains("briefly acknowledge") }, "no system-event suffix")
        let lines = conversation(state, id)?.messages.map(\.content) ?? []
        #expect(lines.filter { $0.contains("reached its 2-tick limit") }.count == 1)
    }

    @Test("a paused loop runs no tick, and Resume starts it again")
    func pauseAndResume() async throws {
        let (state, id) = try app()
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 0.05, cap: 5), in: id)
        #expect(await eventually { sent(state, id).contains { $0.hasPrefix("Loop tick 1") } })
        state.pauseLoop(for: id)
        // Let the first tick's turn finish, then let several intervals pass.
        #expect(await eventually { !state.isThinking(in: id) })
        let count = sent(state, id).filter { $0.hasPrefix("Loop tick") }.count
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(sent(state, id).filter { $0.hasPrefix("Loop tick") }.count == count, "nothing ran while paused")
        state.resumeLoop(for: id)
        #expect(await eventually { sent(state, id).filter { $0.hasPrefix("Loop tick") }.count > count })
        state.pauseLoop(for: id)
    }

    @Test("Stop during a tick keeps the loop and arms nothing; Resume starts it again")
    func stopKeepsTheLoop() async throws {
        let (state, id) = try app(latencyMs: 400)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 0.05, cap: 5), in: id)
        #expect(await eventually { state.isThinking(in: id) && sent(state, id).contains { $0.hasPrefix("Loop tick 1") } })
        state.interruptActiveConversation()
        #expect(await eventually { !state.isThinking(in: id) })
        #expect(conversation(state, id)?.loop != nil, "Stop keeps the loop, as it keeps a goal")
        #expect(state.loopNextTick[id] == nil)
        let count = sent(state, id).filter { $0.hasPrefix("Loop tick") }.count
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(sent(state, id).filter { $0.hasPrefix("Loop tick") }.count == count, "no tick after Stop")
        state.resumeLoop(for: id)
        #expect(await eventually { sent(state, id).filter { $0.hasPrefix("Loop tick") }.count > count })
        state.pauseLoop(for: id)
    }

    @Test("Stop during the person's own turn cancels the pending tick, and the chip stops promising it")
    func stopDuringOwnTurnClearsTheNextTick() async throws {
        let (state, id) = try app(latencyMs: 400)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        state.sendMessage("what's new?")
        #expect(await eventually { state.isThinking(in: id) })
        state.interruptActiveConversation()
        #expect(await eventually { !state.isThinking(in: id) })
        #expect(conversation(state, id)?.loop != nil)
        #expect(state.loopNextTick[id] == nil, "no next tick is armed after Stop")
    }

    @Test("/loop stop and /stop both end the loop")
    func stopCommands() throws {
        let (state, id) = try app()
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 3), in: id)
        state.sendMessage("/loop stop")
        #expect(conversation(state, id)?.loop == nil)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 3), in: id)
        state.sendMessage("/stop")
        #expect(conversation(state, id)?.loop == nil)
        #expect(conversation(state, id)?.messages.last?.content == "Loop stopped.", "no goal, so no \"Goal mode cancelled\"")
    }

    // MARK: arrivals (#676 review)

    @Test("an arrival in an idle looping conversation runs at once, takes the waiting tick's place, and re-arms it")
    func arrivalRunsNow() async throws {
        let (state, id) = try app()
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        #expect(!engine.goalFollowUpPending(for: id) && !engine.goalLoopIsLive(for: id),
                "a waiting tick holds nothing that arrivals queue behind")
        await engine.handleSystemEvent("File changed: notes.md", source: "Watcher", conversationId: id)
        #expect(await eventually { sent(state, id).contains { $0.contains("File changed: notes.md") } }, "the event's turn ran now")
        #expect(!sent(state, id).contains { $0.hasPrefix("Loop tick") })
        #expect(await eventually { !state.isThinking(in: id) && state.loopNextTick[id] != nil }, "its end armed the next tick")
        #expect(await engine.hasLoopTick(for: id))
        state.pauseLoop(for: id)
    }

    @Test("a tick reserves its turn as it is taken, so an arrival before the turn begins queues behind it")
    func takenTickReservesItsTurn() async throws {
        let (state, id) = try app()
        let engine = try #require(state.engine)
        let loop = ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5)
        state.startLoop(loop, in: id)
        guard case .run = state.takeLoopTick(for: id, loopId: loop.id) else { Issue.record("no tick"); return }
        #expect(state.hasTurnInFlight(for: id), "reserved")
        await engine.handleSystemEvent("File changed: notes.md", source: "Watcher", conversationId: id)
        #expect(!sent(state, id).contains { $0.contains("File changed: notes.md") }, "queued, not run beside the tick")
        state.endEngineTurn(for: id)
        #expect(await eventually { sent(state, id).contains { $0.contains("File changed: notes.md") } }, "run once the reservation ends")
        state.pauseLoop(for: id)
    }

    @Test("pause and /loop stop drop the waiting tick")
    func pauseAndStopDropTheTick() async throws {
        let (state, id) = try app()
        let engine = try #require(state.engine)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        #expect(await engine.hasLoopTick(for: id))
        state.pauseLoop(for: id)
        var dropped = false
        for _ in 0..<200 where !dropped { dropped = !(await engine.hasLoopTick(for: id)); if !dropped { try await Task.sleep(nanoseconds: 10_000_000) } }
        #expect(dropped, "pause dropped it")
        state.resumeLoop(for: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        state.sendMessage("/loop stop")
        dropped = false
        for _ in 0..<200 where !dropped { dropped = !(await engine.hasLoopTick(for: id)); if !dropped { try await Task.sleep(nanoseconds: 10_000_000) } }
        #expect(dropped, "/loop stop dropped it")
    }

    @Test("a typed turn clears the chip's next-tick time while it runs")
    func typedTurnClearsNextTick() async throws {
        let (state, id) = try app(latencyMs: 400)
        state.startLoop(ConversationLoop(prompt: "p", intervalSeconds: 3600, cap: 5), in: id)
        #expect(await eventually { state.loopNextTick[id] != nil })
        state.sendMessage("hello")
        #expect(await eventually { state.isThinking(in: id) && state.loopNextTick[id] == nil })
        #expect(await eventually { !state.isThinking(in: id) && state.loopNextTick[id] != nil })
        state.pauseLoop(for: id)
    }

    @Test("a tick never acts as a trigger, whatever its prompt starts with")
    func tickIsNeverATrigger() {
        let loop = ConversationLoop(prompt: "\(IrisEngine.renameTriggerPrefix): rename me", intervalSeconds: 60, cap: 3)
        let tick = loop.tickText(number: 1)
        #expect(tick.hasPrefix("Loop tick"))
        #expect(!IrisEngine.isTrigger(IrisEngine.renameTriggerPrefix, input: tick, source: IrisEngine.loopSource, principal: .main))
        #expect(!IrisEngine.isTrigger(IrisEngine.renameTriggerPrefix, input: loop.prompt, source: IrisEngine.loopSource, principal: .main),
                "not even the bare prompt, under the loop's source")
    }

    @Test("the chip takes its own height, not the whole cap, and never more than the cap")
    func chipHeight() throws {
        let (state, id) = try app()
        let loop = ConversationLoop(prompt: "watch", intervalSeconds: 3600, cap: 5)
        let short = NSHostingController(rootView: LoopChip(state: state, conversationId: id, loop: loop))
            .sizeThatFits(in: CGSize(width: 700, height: 600))
        #expect(short.height > 20 && short.height < 100, "its content's height, not the 120 pt cap: \(short.height)")
        var long = loop
        long.prompt = String(repeating: "a very long loop prompt ", count: 80)
        let capped = NSHostingController(rootView: LoopChip(state: state, conversationId: id, loop: long).frame(width: 120))
            .sizeThatFits(in: CGSize(width: 120, height: 600))
        #expect(capped.height <= 120.5, "never past the cap: \(capped.height)")
    }

    // MARK: persistence and relaunch

    @Test("a loop persists with the conversation, comes back paused, and never on Iris")
    func persistsAndComesBackPaused() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "t", workspacePath: nil)
        c.loop = ConversationLoop(prompt: "watch", intervalSeconds: 600, cap: 7)
        var created = ChangeSet(); created.add(.created)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: created)])
        let back = try #require(try store.loadAll().conversations.first)
        #expect(back.loop == c.loop)

        var pinned = Conversation(id: UUID(), title: "Iris", workspacePath: nil)
        pinned.isPinned = true
        pinned.loop = ConversationLoop(prompt: "x", intervalSeconds: 600, cap: 3)
        let sanitized = AppState.sanitizeLoaded([back, pinned]).conversations
        #expect(sanitized.first { $0.id == c.id }?.loop?.paused == true, "paused on launch")
        #expect(sanitized.first { $0.id == c.id }?.loop?.ticksLeft == 7)
        #expect(sanitized.first { $0.id == pinned.id }?.loop == nil)
    }

    @Test("a conversation from before #190 decodes with no loop, and an unreadable loop drops only itself")
    func decodesOldAndBad() throws {
        let old = #"{"id":"\#(UUID().uuidString)","title":"old"}"#
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(old.utf8)).loop == nil)
        let bad = #"{"id":"\#(UUID().uuidString)","title":"bad","loop":{"prompt":3}}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(bad.utf8))
        #expect(decoded.loop == nil && decoded.title == "bad")
    }
}
