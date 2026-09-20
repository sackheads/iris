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

    @Test("the summary still reaches the user")
    func summaryIsStillShown() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = RecordingClient([goalCompleteWithSelfReport, response(nil)])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("book my flights", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.messages.contains { $0.content.contains("Registered 3 flights") } == true,
                "suppressing the panel must not swallow what the model reported")
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
        // #191: clearGoal now nils lastGoalCompletionReport along with the contract, so a
        // completed goal's report is gone by the time processInput returns — this no longer
        // distinguishes "recorded then cleared" from "never recorded". activeGoal == nil is the
        // remaining observable proof that the completion path ran to the end.
        #expect(conv?.lastGoalCompletionReport == nil)
        #expect(conv?.activeGoal == nil, "and the goal must still be cleared")
    }
}
