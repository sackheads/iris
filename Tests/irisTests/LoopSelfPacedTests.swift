import Testing
import Foundation
@testable import IrisKit

/// #190 PR 2: `/loop <prompt>` with no interval is self-paced. The model sets each next delay with
/// `schedule_next_tick`, declared only while such a loop is set (Invariant 6), clamped to
/// [60 s, 3600 s], and a turn that makes no call falls back to 20 minutes rather than stopping.
@MainActor
@Suite("/loop, self-paced (#190 PR 2)", .timeLimit(.minutes(1)))
struct LoopSelfPacedTests {
    private func app() throws -> (AppState, UUID) {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-190b-\(UUID().uuidString)")
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        let id = state.createNewConversation(isBackground: false, select: true)
        return (state, id)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(text: nil, functionCall: FunctionCall(name: name, args: args, id: "c1"))]))], usageMetadata: nil)
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    /// One turn that calls `schedule_next_tick`; returns what the tool answered.
    private func scheduleTurn(_ state: AppState, _ id: UUID, delay: JSONValue) async -> String? {
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [call(IrisEngine.scheduleNextTickTool, ["delay_seconds": delay]), text("ok")]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: id)
        let parts = state.conversations.first { $0.id == id }?.history.flatMap(\.parts) ?? []
        return parts.compactMap { $0.functionResponse }.last.map { "\($0.response)" }
    }

    /// The names one turn declares.
    private func declared(_ state: AppState, _ id: UUID) async -> [String] {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: state, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("carry on", source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    private func setLoop(_ state: AppState, _ id: UUID, _ loop: ConversationLoop?) throws {
        let i = try #require(state.conversations.firstIndex { $0.id == id })
        state.conversations[i].loop = loop
    }

    @Test("a prompt with no interval is self-paced; a first word that starts with a digit is a typo")
    func parse() {
        #expect(ConversationLoop.parse("check my open PRs") == .startSelfPaced(prompt: "check my open PRs"))
        #expect(ConversationLoop.parse("10m check") == .start(intervalSeconds: 600, prompt: "check"))
        for typo in ["10mn check", "5x check", "3 check"] {
            guard case .invalid = ConversationLoop.parse(typo) else { Issue.record("\(typo) should be refused"); continue }
        }
        let loop = ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5, selfPaced: true)
        #expect(loop.cadence == "self-paced")
        #expect(loop.tickText(number: 1).contains("schedule_next_tick"))
        #expect(!ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5).tickText(number: 1).contains("schedule_next_tick"))
    }

    @Test("a delay is clamped to 60-3600 s and the result says what was applied")
    func clamp() {
        #expect(ConversationLoop.clampedDelay(600).seconds == 600)
        #expect(!ConversationLoop.clampedDelay(600).result.contains("clamped"))
        let low = ConversationLoop.clampedDelay(5)
        #expect(low.seconds == 60 && low.result.contains("clamped") && low.result.contains("1m"))
        let high = ConversationLoop.clampedDelay(86400)
        #expect(high.seconds == 3600 && high.result.contains("clamped") && high.result.contains("1h"))
        // Any finite number the model sends, however large, is clamped and said without trapping.
        #expect(ConversationLoop.clampedDelay(1e30).seconds == 3600)
        #expect(ConversationLoop.clampedDelay(1e30).result.contains("more than 3600 s"))
        #expect(ConversationLoop.clampedDelay(-1e30).seconds == 60)
        #expect(ConversationLoop.clampedDelay(-1e30).result.contains("less than 60 s"))
    }

    @Test("a one-word control-like prompt is refused, not started as a loop on that word")
    func controlWords() throws {
        for word in ["off", "OFF", "cancel", "end", "quit", "help", "start"] {
            guard case .invalid(let why) = ConversationLoop.parse(word) else { Issue.record("/loop \(word) started a loop"); continue }
            #expect(why.contains("/loop stop"))
        }
        #expect(ConversationLoop.parse("status") == .status, "`/loop status` is `/loop`, never a loop on \"status\"")
        #expect(ConversationLoop.parse(" Status ") == .status)
        #expect(ConversationLoop.parse("Stop.") == .stop && ConversationLoop.parse("stop!") == .stop && ConversationLoop.parse("pause.") == .pause)
        for attempt in ["stop now", "pause for a bit", "off now", "cancel it", "Resume please", "status?"] {
            switch ConversationLoop.parse(attempt) {
            case .invalid, .status: break
            default: Issue.record("/loop \(attempt) started a loop")
            }
        }
        #expect(ConversationLoop.parse("list open issues") == .startSelfPaced(prompt: "list open issues"))
        #expect(ConversationLoop.parse("deploy") == .startSelfPaced(prompt: "deploy"), "an ordinary word is still a prompt")
        #expect(ConversationLoop.parse("end of day summary") == .startSelfPaced(prompt: "end of day summary"))
        let (state, id) = try app()
        state.sendMessage("/loop watch the build")
        for attempt in ["/loop off", "/loop stop now", "/loop pause for a bit"] {
            state.sendMessage(attempt)
            #expect(state.conversations.first { $0.id == id }?.loop?.prompt == "watch the build", "\(attempt) left the running loop alone")
        }
        state.sendMessage("/loop watch the deploy")
        #expect(state.conversations.first { $0.id == id }?.messages.last?.content.contains("This replaces the loop that was running (self-paced: watch the build)") == true)
        state.pauseLoop(for: id)
    }

    @Test("declared only while a self-paced loop is set: not with none, not with a fixed one; then it stays")
    func gating() async throws {
        let (state, id) = try app()
        #expect(!(await declared(state, id)).contains(IrisEngine.scheduleNextTickTool), "no loop")
        try setLoop(state, id, ConversationLoop(prompt: "p", intervalSeconds: 600, cap: 5, paused: true))
        #expect(!(await declared(state, id)).contains(IrisEngine.scheduleNextTickTool), "a fixed loop")
        try setLoop(state, id, ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5, paused: true, selfPaced: true))
        #expect(await declared(state, id).contains(IrisEngine.scheduleNextTickTool), "a self-paced loop")
        try setLoop(state, id, nil)
        #expect(await declared(state, id).contains(IrisEngine.scheduleNextTickTool), "sticky once declared (5c §0.1)")
        #expect(StickyTools.eligible.contains(IrisEngine.scheduleNextTickTool))
        #expect(IrisEngine.mainOnlyDeclared.contains(IrisEngine.scheduleNextTickTool))
        #expect(!IrisEngine.jobRunToolNames.contains(IrisEngine.scheduleNextTickTool))
    }

    @Test("an off-state call is refused at dispatch, with or without a fixed loop")
    func offStateRefused() async throws {
        let (state, id) = try app()
        #expect(await scheduleTurn(state, id, delay: .int(600))?.contains("no self-paced /loop") == true)
        try setLoop(state, id, ConversationLoop(prompt: "p", intervalSeconds: 600, cap: 5, paused: true))
        #expect(await scheduleTurn(state, id, delay: .int(600))?.contains("no self-paced /loop") == true)
        #expect(state.loopRequestedDelay[id] == nil)
    }

    @Test("a call sets the pace until the next tick starts; a tick that makes no call falls back to the default")
    func callSetsTheNextDelay() async throws {
        let (state, id) = try app()
        let loop = ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5, paused: true, selfPaced: true)
        try setLoop(state, id, loop)
        #expect(await scheduleTurn(state, id, delay: .int(30))?.contains("clamped") == true)
        #expect(state.loopRequestedDelay[id] == 60)
        #expect(await scheduleTurn(state, id, delay: .double(900.4))?.contains("15m") == true)
        #expect(state.nextLoopDelay(for: id, loop: loop) == 900)
        #expect(state.nextLoopDelay(for: id, loop: loop) == 900, "a chat turn's re-arm keeps the pace")
        var running = loop
        running.paused = false
        try setLoop(state, id, running)
        guard case .run = state.takeLoopTick(for: id, loopId: running.id) else { Issue.record("no tick"); return }
        state.endEngineTurn(for: id)
        #expect(state.nextLoopDelay(for: id, loop: running) == ConversationLoop.selfPacedDefault,
                "the tick started with no call yet: 20 min, not a stop")
        #expect(state.nextLoopDelay(for: id, loop: ConversationLoop(prompt: "p", intervalSeconds: 600, cap: 5)) == 600,
                "a fixed loop keeps its interval")
    }

    @Test("a non-number delay falls back to the default, clamped")
    func badDelay() async throws {
        let (state, id) = try app()
        try setLoop(state, id, ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5, paused: true, selfPaced: true))
        _ = await scheduleTurn(state, id, delay: .string("soon"))
        #expect(state.loopRequestedDelay[id] == ConversationLoop.selfPacedDefault)
    }

    @Test("/loop <prompt> starts a self-paced loop whose first tick is a minute away")
    func startsSelfPaced() throws {
        let (state, id) = try app()
        state.sendMessage("/loop keep an eye on the build")
        let loop = try #require(state.conversations.first { $0.id == id }?.loop)
        #expect(loop.selfPaced && loop.prompt == "keep an eye on the build")
        #expect(state.conversations.first { $0.id == id }?.messages.last?.content.contains("Looping self-paced") == true)
        #expect(state.nextLoopDelay(for: id, loop: loop) == ConversationLoop.selfPacedMinimum)
        state.pauseLoop(for: id)
    }

    @Test("a self-paced loop persists, and a loop from before PR 2 decodes as fixed")
    func persistence() throws {
        var c = Conversation(id: UUID(), title: "t", workspacePath: nil)
        c.loop = ConversationLoop(prompt: "p", intervalSeconds: 60, cap: 5, selfPaced: true)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Conversation.self, from: data).loop?.selfPaced == true)
        let old = #"{"id":"\#(UUID().uuidString)","title":"t","loop":{"prompt":"p","intervalSeconds":600,"cap":5,"ticksLeft":5,"paused":false}}"#
        #expect(try JSONDecoder().decode(Conversation.self, from: Data(old.utf8)).loop?.selfPaced == false)
    }
}
