import Testing
import Foundation
@testable import iris

/// End-to-end D3: reach_checkpoint grades first, then decides.
@MainActor
@Suite("Checkpoint auto-advance (D3)")
struct CheckpointAutoAdvanceTests {

    /// Routes by principal: the grader offers `submit_evaluation` and is scripted to hand back
    /// one fixed verdict/evidence pair for every criterion id found in its own system prompt
    /// (ladder ids are minted per test, so the grader can't be scripted by id). Everything else
    /// comes from `mainScript`, in order.
    final class RoutingClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let uuidPattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderCallCount = 0
        private let mainScript: [GeminiResponse]
        private let verdict: String
        private let evidence: String

        init(main: [GeminiResponse], graderVerdict: (String, String)) {
            self.mainScript = main
            self.verdict = graderVerdict.0
            self.evidence = graderVerdict.1
        }
        var graderCalls: Int { lock.withLock { graderCallCount } }

        private static func text(_ s: String) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model",
                parts: [Part(text: s, functionCall: nil, functionResponse: nil,
                             thought_signature: nil, thoughtSignature: nil)]))], usageMetadata: nil)
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let offersSubmit = request.tools?.contains {
                $0.functionDeclarations.contains { $0.name == "submit_evaluation" }
            } ?? false
            let systemText = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            return lock.withLock {
                if offersSubmit {
                    graderCallCount += 1
                    guard graderCallCount == 1 else { return Self.text("done") }
                    let ids = systemText.matches(of: Self.uuidPattern).map { String($0.output) }
                    let evaluations = JSONValue.array(ids.map {
                        .object(["criterion_id": .string($0), "verdict": .string(self.verdict),
                                 "evidence": .string(self.evidence)])
                    })
                    let part = Part(text: nil,
                                    functionCall: FunctionCall(name: "submit_evaluation",
                                                               args: ["evaluations": evaluations],
                                                               id: nil, thought_signature: nil,
                                                               thoughtSignature: nil),
                                    functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
                    return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                          usageMetadata: nil)
                }
                let i = mainIndex
                mainIndex += 1
                return mainScript[min(i, mainScript.count - 1)]
            }
        }
    }

    static func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "ok" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    static func reachCheckpointCall() -> GeminiResponse {
        response(FunctionCall(name: "reach_checkpoint",
                              args: ["milestone_summary": .string("done with this checkpoint")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// Two-milestone ladder on milestone 0, locked, with one qualitative criterion per milestone.
    private func ladder(on app: AppState, _ id: UUID) {
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = 0
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)
    }

    @Test("a clean grade advances the ladder and does not pause")
    func testCleanGradeAdvances() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 1, "a clean checkpoint should advance")
        #expect(c?.checkpointStatus == .running, "a clean checkpoint should not pause")
        #expect(c?.checkpointHistory.first?.resolution == .autoAdvanced)
    }

    @Test("a not_met grade pauses exactly as before")
    func testFailedGradePauses() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("not_met", "parser crashes on nested input"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 0)
        #expect(c?.checkpointStatus == .pausedForReview)
    }

    @Test("the setting off pauses on a grade that would otherwise advance")
    func testSettingOffPauses() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: client, checkpointAutoAdvance: false)
        await engine.processInput("work", source: "User", conversationId: id)

        let c = app.conversations.first { $0.id == id }?.goalContract
        #expect(c?.currentMilestone == 0)
        #expect(c?.checkpointStatus == .pausedForReview)
    }

    @Test("an unjudged humanJudged criterion pauses and asks for the verdict")
    func testHumanJudgedPausesAndAsks() async {
        let app = AppState(); let id = UUID()
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let h = Criterion(text: "output reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, h, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id, h.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, c)

        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let after = app.conversations.first { $0.id == id }?.goalContract
        #expect(after?.currentMilestone == 0, "an unjudged human criterion must not be skipped")
        #expect(after?.awaitingHumanJudgement == true, "the pause must ask, not just stop")
    }

    @Test("an auto-advance announces itself in the transcript")
    func testAutoAdvanceIsAnnounced() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.reachCheckpointCall(), Self.response(nil)],
                                   graderVerdict: ("met", "saw it work"))
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let messages = app.conversations.first { $0.id == id }?.messages ?? []
        #expect(messages.contains { $0.content.contains("auto-advanced") },
                "a skipped checkpoint must leave an audit trail the user can read")
    }
}
