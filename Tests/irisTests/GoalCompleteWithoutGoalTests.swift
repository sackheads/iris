import Testing
import Foundation
@testable import iris

/// `goal_complete` is the goal loop's terminal signal. In a plain chat with no goal running it has
/// nothing to terminate, but it used to be offered anyway and its effects applied in full —
/// surfacing the goal-completion panel over an ordinary conversation (#84).
@MainActor
@Suite("goal_complete without a goal")
struct GoalCompleteWithoutGoalTests {
    /// Records every prompt the model was sent, so an extra autonomous turn is observable.
    private final class RecordingClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        private var prompts: [String] = []
        private let script: [GeminiResponse]

        init(_ script: [GeminiResponse]) { self.script = script }
        var seenPrompts: [String] { lock.withLock { prompts } }
        var callCount: Int { lock.withLock { index } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock {
                prompts.append(request.contents.flatMap { $0.parts }.compactMap(\.text).joined())
                let r = script[min(index, script.count - 1)]
                index += 1
                return r
            }
        }
    }

    private func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "All done." : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    /// The shape reported in #84: a multi-step task finished, so the model volunteers a summary
    /// AND a per-criterion self-report, even though the user never started a goal.
    private var goalCompleteWithSelfReport: GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: [
            "summary": .string("Registered 3 flights in your calendar."),
            "criteria_status": .array([
                .object(["criterion": .string("events created"), "status": .string("met")])
            ])
        ], id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    @Test("a plain chat does not get the goal-completion panel")
    func noPanelWithoutAGoal() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)   // no activeGoal, no contract — an ordinary thread
        let client = RecordingClient([goalCompleteWithSelfReport, response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("book my flights", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        // ChatView shows the panel when either of these is non-nil.
        #expect(conv?.lastGoalCompletionReport == nil, "the completion panel was triggered in a plain chat")
        #expect(conv?.lastGoalEvaluation == nil)
    }

    /// 5c §0.2 reverses #84's summary push: `goal_complete` is sticky now, so a refused call
    /// leaves no trace beyond its result. What the model reported reaches the user through the
    /// model's own next reply, which the refusal asks for and the turn gives it room to send.
    @Test("the refusal asks the model to reply with its summary, and the turn lets it")
    func summaryIsLeftToTheModel() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = RecordingClient([goalCompleteWithSelfReport, response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("book my flights", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.messages.contains { $0.content.contains("Registered 3 flights") } == false,
                "the harness must not push a refused call's summary")
        #expect(client.callCount == 2, "the model got a round to reply after the refusal")
        let results = conv?.history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let r)? = part.functionResponse?.response["result"] else { return nil }
            return r
        } ?? []
        #expect(results == [IrisEngine.noGoalRefusal])
        #expect(conv?.messages.contains { $0.content.contains("All done.") } == true)
    }

    /// Plain chat has no loop detector, so the reply round is granted once per turn: a model that
    /// keeps calling goal_complete is stopped after its second call, as before 5c after its first.
    /// Self-bounded: eight goal_complete answers, then text, so a missing bound fails, not hangs.
    @Test("a model that keeps calling goal_complete gets one reply round, not a loop")
    func refusedGoalCompleteReplyIsBounded() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = RecordingClient(Array(repeating: goalCompleteWithSelfReport, count: 8) + [response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("book my flights", source: "User", conversationId: id)
        #expect(client.callCount == 2)
    }

    @Test("no skill-check reflection turn is fired in a plain chat")
    func noReflectionTurn() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = RecordingClient([goalCompleteWithSelfReport, response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("book my flights", source: "User", conversationId: id)

        // The goal path fires an autonomous follow-up turn asking the model to consider saving a
        // skill. With no goal there is nothing to reflect on, and the user did not ask for it.
        #expect(!client.seenPrompts.contains { $0.contains("Goal Completion Skill Check") },
                "an unrequested extra model turn ran in a plain chat")
    }

    @Test("an active goal still records its completion report (regression)")
    func activeGoalStillReports() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.setGoal(for: id, goal: "do the thing")
        let client = RecordingClient([goalCompleteWithSelfReport, response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.lastGoalCompletionReport != nil, "a real goal must still produce its report")
        #expect(conv?.activeGoal == nil, "and the goal must still be cleared")
    }
}
