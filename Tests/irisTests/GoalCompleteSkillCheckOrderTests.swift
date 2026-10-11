import Testing
import Foundation
@testable import IrisKit

/// #474: `goal_complete` used to run the skill-check turn from inside its own handler, so the
/// check's user entry landed between the model's `functionCall` and its `functionResponse`.
/// Anthropic rejects that history (a `tool_use` with no `tool_result` immediately after), so on
/// Anthropic every goal completion logged an HTTP 400 and the check never ran. The check is now a
/// follow-up turn of its own, scheduled once the tool result is in history.
@MainActor
@Suite("goal_complete schedules its skill check after its result", .timeLimit(.minutes(1)))
struct GoalCompleteSkillCheckOrderTests {
    private static let callId = "toolu_gc474"

    private func reply(_ part: Part) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
    }

    /// A conversation with a goal but no contract: the handler skips grading and completes.
    private func goalApp() -> (AppState, UUID) {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.setGoal(for: id, goal: "do the thing")
        return (app, id)
    }

    /// The Anthropic rule the 400 enforces: each assistant message's `tool_use` blocks are
    /// answered by `tool_result` blocks at the very start of the next message, which is a user one.
    private func expectToolUsesAnswered(_ body: [String: Any], request n: Int,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        let messages = body["messages"] as? [[String: Any]] ?? []
        for (i, message) in messages.enumerated() where message["role"] as? String == "assistant" {
            let uses = (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            guard !uses.isEmpty else { continue }
            guard i + 1 < messages.count, messages[i + 1]["role"] as? String == "user" else {
                Issue.record("request \(n): tool_use \(uses) is not followed by a user message", sourceLocation: sourceLocation)
                continue
            }
            let leading = (messages[i + 1]["content"] as? [[String: Any]] ?? [])
                .prefix { $0["type"] as? String == "tool_result" }
                .compactMap { $0["tool_use_id"] as? String }
            #expect(Set(uses).isSubset(of: Set(leading)),
                    "request \(n): tool_use \(uses) without tool_result immediately after (leading results: \(leading))",
                    sourceLocation: sourceLocation)
        }
    }

    @Test("the skill-check turn runs after goal_complete's result, which directly follows its call")
    func skillCheckFollowsTheToolResult() async throws {
        let (app, id) = goalApp()
        let call = FunctionCall(name: "goal_complete", args: ["summary": .string("done")], id: Self.callId)
        let client = RecordingClient([
            reply(Part(functionCall: call)),
            reply(Part(text: "Nothing reusable to save.")),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                                repromptDelay: 0)

        await engine.processInput("go", source: "UI", conversationId: id)
        // The check is its own turn now, so it may still be pending or running here.
        let deadline = Date().addingTimeInterval(20)
        while engine.goalLoopIsLive(for: id), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!engine.goalLoopIsLive(for: id), "the skill-check turn never finished")

        let requests = client.requests
        try #require(requests.count == 2, "expected the goal turn's request and the skill check's, got \(requests.count)")

        // What Anthropic would have been sent: every tool_use answered at once.
        for (n, request) in requests.enumerated() {
            expectToolUsesAnswered(try ThinkingFixtures.body(request), request: n + 1)
        }

        // The skill check's own request: call, then its result, then the check — in that order.
        let contents = requests[1].contents
        let callIdx = try #require(contents.firstIndex { c in
            c.role == "model" && c.parts.contains { $0.functionCall?.id == Self.callId }
        })
        let resultIdx = try #require(contents.firstIndex { c in
            c.parts.contains { $0.functionResponse?.id == Self.callId }
        })
        let checkIdx = try #require(contents.firstIndex { c in
            c.parts.contains { $0.text?.contains("Goal Completion Skill Check") == true }
        })
        #expect(resultIdx == callIdx + 1, "the functionResponse must directly follow its functionCall")
        #expect(checkIdx == resultIdx + 1, "the skill check comes right after the result")
        #expect(contents[resultIdx].role == "user")

        // History keeps the same order, and the check's reply is in it.
        let history = app.conversations.first { $0.id == id }?.history ?? []
        let hCall = try #require(history.firstIndex { $0.parts.contains { $0.functionCall?.id == Self.callId } })
        let hResult = try #require(history.firstIndex { $0.parts.contains { $0.functionResponse?.id == Self.callId } })
        let hCheck = try #require(history.firstIndex { $0.parts.contains { $0.text?.contains("Goal Completion Skill Check") == true } })
        #expect(hResult == hCall + 1)
        #expect(hCheck == hResult + 1)
        #expect(history.last?.parts.contains { $0.text == "Nothing reusable to save." } == true)
        #expect(app.conversations.first { $0.id == id }?.activeGoal == nil)
    }

    @Test("a Stop before the follow-up runs cancels the skill check")
    func stopCancelsThePendingSkillCheck() async throws {
        let (app, id) = goalApp()
        let call = FunctionCall(name: "goal_complete", args: ["summary": .string("done")], id: Self.callId)
        let client = RecordingClient([reply(Part(functionCall: call)), reply(Part(text: "late"))])
        // A long delay, so the cancel lands while the follow-up is still waiting.
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                                repromptDelay: 30)
        await engine.processInput("go", source: "UI", conversationId: id)
        #expect(engine.goalLoopIsLive(for: id), "the skill check should be pending after the turn")
        await engine.cancelReprompt(for: id)
        #expect(!engine.goalLoopIsLive(for: id))
        #expect(client.requests.count == 1)
    }

    /// Waits, bounded, until the conversation's goal loop has nothing running or pending.
    private func settle(_ engine: IrisEngine, _ id: UUID, within seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while engine.goalLoopIsLive(for: id), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!engine.goalLoopIsLive(for: id), "the conversation's follow-up turns never settled")
    }

    @Test("an unattended run never schedules the skill check")
    func unattendedRunSchedulesNoSkillCheck() async throws {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id, isBackground: true)
        app.setGoal(for: id, goal: "do the thing")
        let call = FunctionCall(name: "goal_complete", args: ["summary": .string("done")], id: Self.callId)
        let client = RecordingClient([reply(Part(functionCall: call)), reply(Part(text: "late"))])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                                repromptDelay: 0)
        await engine.processInput("run", source: "job:test", conversationId: id)
        #expect(!engine.goalLoopIsLive(for: id), "a job run's follow-up would outlive the run")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(client.requests.count == 1)
        #expect(app.conversations.first { $0.id == id }?.activeGoal == nil, "the goal still completed")
    }

    /// Holds request `gated` until released, so a turn can be kept in flight on purpose.
    private final class GatedClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [GeminiRequest] = []
        private var open = false
        private let script: [GeminiResponse]
        private let gated: Int
        init(_ script: [GeminiResponse], gated: Int) { self.script = script; self.gated = gated }
        var requests: [GeminiRequest] { lock.withLock { recorded } }
        func release() { lock.withLock { open = true } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let n = lock.withLock { recorded.append(request); return recorded.count }
            if n == gated {
                let deadline = Date().addingTimeInterval(10)
                while !lock.withLock({ open }), Date() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            return script[min(n - 1, script.count - 1)]
        }
    }

    @Test("a message typed before the check starts defers the check until after that turn")
    func userTurnInTheGapDefersTheSkillCheck() async throws {
        let (app, id) = goalApp()
        let call = FunctionCall(name: "goal_complete", args: ["summary": .string("done")], id: Self.callId)
        let client = GatedClient([reply(Part(functionCall: call)), reply(Part(text: "hello back")),
                                  reply(Part(text: "Nothing reusable to save."))], gated: 2)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                                repromptDelay: 0.2)
        await engine.processInput("go", source: "UI", conversationId: id)
        #expect(engine.goalLoopIsLive(for: id), "the skill check should be waiting out its delay")

        // The user's turn starts inside the delay and is held well past it.
        let userTurn = Task { await engine.processInput("hello", source: "UI", conversationId: id) }
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(client.requests.count == 2, "the skill check ran beside the user's turn")
        client.release()
        try await value(of: userTurn)
        try await settle(engine, id)

        let requests = client.requests
        try #require(requests.count == 3, "the deferred skill check should run after the user's turn")
        let texts = requests[2].contents.flatMap(\.parts).compactMap(\.text)
        let hello = try #require(texts.firstIndex { $0.contains("hello") && !$0.contains("Skill Check") })
        let check = try #require(texts.firstIndex { $0.contains("Goal Completion Skill Check") })
        #expect(hello < check, "the check follows the user's turn")
        #expect(texts.filter { $0.contains("Goal Completion Skill Check") }.count == 1, "it runs once")
    }

    @Test("Esc while the check waits out its delay cancels it")
    func escapeInTheGapCancelsTheSkillCheck() async throws {
        let (app, id) = goalApp()
        let call = FunctionCall(name: "goal_complete", args: ["summary": .string("done")], id: Self.callId)
        let client = RecordingClient([reply(Part(functionCall: call)), reply(Part(text: "late"))])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                                repromptDelay: 30)
        app.installEngine(engine)
        app.selectedConversationId = id
        await engine.processInput("go", source: "UI", conversationId: id)
        #expect(app.hasInterruptibleWork(in: id), "Esc must have something to reach")
        app.interruptActiveConversation()
        try await settle(engine, id, within: 5)
        #expect(client.requests.count == 1)
        #expect(app.conversations.first { $0.id == id }?.messages.last?.content == "Interrupted.")
    }

    @Test("a Stop after a goal turn's final reply schedules no reprompt")
    func cancelAfterFinalReplySchedulesNoReprompt() async throws {
        let (app, id) = goalApp()
        // The AfterAgent hook runs after the final reply has been read, so a cancel landing while
        // it runs is past every point where the turn would notice a Stop and take the catch.
        let dir = try ThinkingFixtures.tempDirectory("474-stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("after-agent-started")
        let hooks = try ThinkingFixtures.hooks(in: dir, ["AfterAgent": "touch '\(marker.path)'; sleep 5"])
        let client = RecordingClient([reply(Part(text: "Working on it."))])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0,
                                hooks: hooks, repromptDelay: 30)
        let turn = Task { await engine.processInput("go", source: "UI", conversationId: id) }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path), "the AfterAgent hook never ran")
        turn.cancel()
        try await value(of: turn)
        #expect(client.requests.count == 1)
        #expect(app.conversations.first { $0.id == id }?.activeGoal != nil,
                "the goal is still set, so only the cancel can skip the re-arm")
        #expect(!engine.goalLoopIsLive(for: id), "a stopped turn re-armed the goal loop")
        await engine.cancelReprompt(for: id)
    }
}
