import Testing
import Foundation
@testable import IrisKit

/// #1022: `set_alarm` lets the model wait without a blocking `sleep`. It is a one-shot loop: the
/// same conversation, the same tick machinery, one tick, then gone. Declared on attended main
/// turns like `schedule_job` (Invariant 6), 15-3600 s, refused beside a user's `/loop`.
@MainActor
@Suite("set_alarm (#1022)", .timeLimit(.minutes(1)))
struct SetAlarmTests {
    private func app() throws -> (AppState, UUID) {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1022-\(UUID().uuidString)")
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        let id = state.createNewConversation(isBackground: false, select: true)
        return (state, id)
    }

    private func loop(_ state: AppState, _ id: UUID) -> ConversationLoop? {
        state.conversations.first { $0.id == id }?.loop
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(text: nil, functionCall: FunctionCall(name: name, args: args, id: "c1"))]))], usageMetadata: nil)
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    /// One turn that calls `set_alarm`; returns what the tool answered.
    private func alarmTurn(_ state: AppState, _ id: UUID, args: [String: JSONValue]) async -> String? {
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [call(IrisEngine.setAlarmTool, args), text("ok")]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: id)
        let parts = state.conversations.first { $0.id == id }?.history.flatMap(\.parts) ?? []
        return parts.compactMap { $0.functionResponse }.last.map { "\($0.response)" }
    }

    private func declared(_ state: AppState, _ id: UUID) async -> [String] {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: state, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("carry on", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("a delay is clamped to 15-3600 s and the result says what was applied")
    func clamp() {
        #expect(ConversationLoop.clampedAlarmDelay(30).seconds == 30)
        #expect(!ConversationLoop.clampedAlarmDelay(30).result.contains("clamped"))
        let low = ConversationLoop.clampedAlarmDelay(2)
        #expect(low.seconds == 15 && low.result.contains("clamped"))
        let high = ConversationLoop.clampedAlarmDelay(86400)
        #expect(high.seconds == 3600 && high.result.contains("clamped"))
        #expect(ConversationLoop.clampedAlarmDelay(1e30).seconds == 3600)
        #expect(ConversationLoop.clampedAlarmDelay(-1e30).seconds == 15)
        #expect(ConversationLoop.clampedAlarmDelay(.nan).seconds == 15, "no number at all is the shortest wait, never a trap")
    }

    @Test("declared on a plain attended turn, main only, never to a job run")
    func declaration() async throws {
        let (state, id) = try app()
        #expect(await declared(state, id).contains(IrisEngine.setAlarmTool))
        #expect(IrisEngine.mainOnlyDeclared.contains(IrisEngine.setAlarmTool))
        #expect(IrisEngine.unattendedNeverDeclared.contains(IrisEngine.setAlarmTool))
        #expect(!IrisEngine.jobRunToolNames.contains(IrisEngine.setAlarmTool))
        #expect(IrisEngine.allDeclaredToolNames.contains(IrisEngine.setAlarmTool))
    }

    @Test("run_command's description sends a wait to set_alarm")
    func runCommandNudge() async {
        let tools = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false)
        let desc = tools.first { $0.name == "run_command" }?.description ?? ""
        #expect(desc.contains("set_alarm"))
    }

    @Test("a call sets a one-tick alarm loop with the clamped delay and says it does not survive a relaunch")
    func callSetsAlarm() async throws {
        let (state, id) = try app()
        let answer = await alarmTurn(state, id, args: ["delay_seconds": .int(120), "note": .string("check the CI run")])
        let set = try #require(loop(state, id))
        #expect(set.isAlarm && set.cap == 1 && set.ticksLeft == 1 && !set.selfPaced)
        #expect(set.intervalSeconds == 120)
        #expect(set.prompt == "check the CI run")
        #expect(answer?.contains("2m") == true)
        #expect(answer?.contains("relaunch") == true, "the result says a quit drops it")
    }

    @Test("a second call replaces the first alarm; a user's /loop is refused and left alone")
    func replaceAndRefuse() async throws {
        let (state, id) = try app()
        _ = await alarmTurn(state, id, args: ["delay_seconds": .int(60), "note": .string("first")])
        let replaced = await alarmTurn(state, id, args: ["delay_seconds": .int(90), "note": .string("second")])
        #expect(loop(state, id)?.prompt == "second" && loop(state, id)?.intervalSeconds == 90)
        #expect(replaced?.contains("replaces") == true)

        state.clearLoop(for: id)
        state.startLoop(ConversationLoop(prompt: "watch", intervalSeconds: 600, cap: 5, paused: true), in: id)
        let refused = await alarmTurn(state, id, args: ["delay_seconds": .int(60), "note": .string("x")])
        #expect(refused?.contains("/loop") == true)
        #expect(loop(state, id)?.prompt == "watch" && loop(state, id)?.isAlarm == false)
    }

    @Test("an alarm is refused where a loop would be: a running goal, a background conversation")
    func refusals() throws {
        let (state, id) = try app()
        let i = try #require(state.conversations.firstIndex { $0.id == id })
        state.conversations[i].activeGoal = "ship it"
        #expect(state.setAlarm(for: id, requested: 60, note: "x").contains("goal"))
        #expect(loop(state, id) == nil)
        state.conversations[i].activeGoal = nil
        state.conversations[i].isBackground = true
        #expect(loop(state, id) == nil)
        #expect(!state.setAlarm(for: id, requested: 60, note: "x").contains("Alarm set"))
        #expect(loop(state, id) == nil)
    }

    @Test("the pinned Iris conversation may hold an alarm: one tick does not fill it the way a loop would")
    func pinnedAllowed() throws {
        let (state, id) = try app()
        let i = try #require(state.conversations.firstIndex { $0.id == id })
        state.conversations[i].isPinned = true
        #expect(state.loopRefusal(state.conversations[i]) != nil, "a /loop is still refused there")
        #expect(state.loopRefusal(state.conversations[i], forAlarm: true) == nil)
        #expect(state.setAlarm(for: id, requested: 60, note: "x").contains("Alarm set"))
        #expect(loop(state, id)?.isAlarm == true)
    }

    @Test("the tick that fires an alarm says it is an alarm, carries the note and asks for no pacing")
    func tickText() throws {
        let (state, id) = try app()
        _ = state.setAlarm(for: id, requested: 60, note: "check the CI run")
        let set = try #require(loop(state, id))
        guard case .run(let text) = state.takeLoopTick(for: id, loopId: set.id) else {
            Issue.record("the alarm did not fire"); return
        }
        #expect(text.contains("check the CI run"))
        #expect(text.localizedCaseInsensitiveContains("alarm"))
        #expect(!text.contains("Loop tick") && !text.contains("schedule_next_tick"))
        let said = state.conversations.first { $0.id == id }?.messages.map(\.content) ?? []
        #expect(said.contains { $0.contains("Alarm") })
        state.endEngineTurn(for: id)
    }

    @Test("a fired alarm ends silently, not as a reached tick limit")
    func endsSilently() throws {
        let (state, id) = try app()
        _ = state.setAlarm(for: id, requested: 60, note: "x")
        let set = try #require(loop(state, id))
        _ = state.takeLoopTick(for: id, loopId: set.id)
        state.endEngineTurn(for: id)
        state.endLoopAtCap(for: id)
        #expect(loop(state, id) == nil)
        let said = state.conversations.first { $0.id == id }?.messages.map(\.content) ?? []
        #expect(!said.contains { $0.contains("tick limit") })
    }

    @Test("an alarm that comes due during a turn is retried soon, not an interval later")
    func busyRetriesSoon() throws {
        let (state, id) = try app()
        _ = state.setAlarm(for: id, requested: 900, note: "x")
        let set = try #require(loop(state, id))
        state.beginEngineTurn(for: id)
        #expect(state.takeLoopTick(for: id, loopId: set.id) == .busy)
        #expect(loop(state, id)?.ticksLeft == 1, "a skipped alarm is not spent")
        #expect(loop(state, id)?.intervalSeconds == ConversationLoop.alarmMinimum)
        state.endEngineTurn(for: id)
    }

    @Test("a stored loop without the alarm key decodes as an ordinary loop; an alarm round-trips")
    func codable() throws {
        let old = #"{"id":"6F0C2D3E-1111-4222-8333-444455556666","prompt":"p","intervalSeconds":600,"ticksLeft":3,"cap":3,"paused":true,"selfPaced":false}"#
        let decoded = try JSONDecoder().decode(ConversationLoop.self, from: Data(old.utf8))
        #expect(!decoded.isAlarm)
        let alarm = ConversationLoop.alarm(note: "n", delaySeconds: 30)
        let back = try JSONDecoder().decode(ConversationLoop.self, from: JSONEncoder().encode(alarm))
        #expect(back == alarm && back.isAlarm)
    }
}
