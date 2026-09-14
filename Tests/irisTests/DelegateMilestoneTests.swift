import Testing
import Foundation
@testable import iris

/// Slice B4: `delegate_milestone` hands the current ladder milestone to a bounded subagent.
///
/// Assertions read the PARENT conversation (owned by this test's AppState, which the engine holds
/// directly) and this suite's own client. The subagent itself is spawned through
/// `SubagentManager.shared`, whose AppState is a global another suite can swap — so nothing here
/// asserts on the subagent's conversation. Serialized for the same reason.
@MainActor
@Suite("delegate_milestone (B4)", .serialized)
struct DelegateMilestoneTests {
    /// Routes by principal: the grader offers `submit_evaluation`; the subagent carries the role
    /// prompt. The grader synthesizes verdicts from the criterion ids in its own system prompt,
    /// because `GoalEvaluationParsing` reconciles strictly by id and ladder ids are minted per test.
    final class RoutingClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let uuidPattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderCallCount = 0
        private var subagentCallCount = 0
        private let mainScript: [GeminiResponse]
        private let subagentTerminal: GeminiResponse?

        /// `subagentTerminal` nil ⇒ the subagent never calls goal_complete (it will time out).
        init(main: [GeminiResponse], subagentTerminal: GeminiResponse?) {
            self.mainScript = main
            self.subagentTerminal = subagentTerminal
        }
        var graderCalls: Int { lock.withLock { graderCallCount } }
        var subagentCalls: Int { lock.withLock { subagentCallCount } }

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
                        .object(["criterion_id": .string($0), "verdict": .string("met"),
                                 "evidence": .string("verified")])
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
                if systemText.contains("specialized subagent role") {
                    subagentCallCount += 1
                    return subagentTerminal ?? Self.text("still working")
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

    static func delegateCall(role: String = "engineer") -> GeminiResponse {
        response(FunctionCall(name: "delegate_milestone",
                              args: ["role": .string(role), "effort": .string("easy")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    static var subagentDone: GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string("milestone built")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// A two-milestone locked ladder on a fresh AppState, wired into the subagent manager.
    func ladder(on app: AppState, _ id: UUID, currentMilestone: Int = 0) {
        app.createNewConversation(id: id)
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        c.currentMilestone = currentMilestone
        app.setGoalContract(for: id, c)
        SubagentManager.shared.setGlobalState(app)
    }

    @Test("the tool declares no criteria parameter — the ladder is the only source")
    func schemaHasNoCriteriaParameter() {
        let decl = SubagentManager.milestoneDelegationDeclaration()
        let props = decl.parameters?.properties
        #expect(props?["criteria"] == nil, "a criteria parameter would let the model restate its own gate")
        #expect(props?["role"] != nil)
        #expect(props?["effort"] != nil)
        #expect(props?["brief"] != nil)
        #expect(decl.parameters?.required == ["role", "effort"])
        #expect([decl].arrayItemsViolations().isEmpty)
    }

    @Test("delegating spawns a subagent against the milestone, ungraded")
    func delegatesTheMilestone() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        #expect(client.subagentCalls > 0, "a subagent should have run the milestone")
    }

    @Test("a completed subagent reaches the checkpoint, graded cumulatively and paused")
    func completedSubagentReachesCheckpoint() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.checkpointStatus == .pausedForReview)
        #expect(conv?.activeGoal != nil, "the goal stays active at a checkpoint pause")
        #expect(conv?.goalContract?.currentMilestone == 0, "advancing is the human's click, not the loop's")
        #expect(conv?.lastGoalEvaluation != nil, "the checkpoint grade must have landed")
        #expect(client.graderCalls > 0)
    }

    @Test("the checkpoint grade covers earlier milestones, not just the delegated one")
    func checkpointGradeIsCumulative() async {
        // Delegating the MIDDLE rung of a three-rung ladder: the projection spans milestones 0...1,
        // so the grade covers the delegated milestone AND the one before it. This is what catches a
        // delegated milestone's work breaking an earlier milestone's criterion — the reason a
        // checkpoint is a gate rather than a status print (B1 §6.3).
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        let a = Criterion(text: "one", kind: .qualitative, check: nil)
        let b = Criterion(text: "two", kind: .qualitative, check: nil)
        let c = Criterion(text: "three", kind: .qualitative, check: nil)
        var contract = GoalContract(objective: "Ship", criteria: [a, b, c])
        contract.milestones = [Milestone(title: "One", criterionIds: [a.id]),
                               Milestone(title: "Two", criterionIds: [b.id]),
                               Milestone(title: "Three", criterionIds: [c.id])]
        contract.currentMilestone = 1
        app.setGoalContract(for: id, contract)
        SubagentManager.shared.setGlobalState(app)

        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let eval = app.conversations.first { $0.id == id }?.lastGoalEvaluation
        #expect(eval?.criteria.count == 2, "milestones 0...1 — the delegated one AND the one before it")
    }

    @Test("a subagent that never completes does not pause the human")
    func failedSubagentDoesNotCheckpoint() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id)
        // subagentTerminal nil ⇒ the subagent never calls goal_complete and hits its iteration cap.
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.checkpointStatus == .running,
                "a milestone nobody claimed done must not pause a human")
        #expect(conv?.lastGoalEvaluation == nil, "nothing claimed done, so nothing to grade")
        #expect(client.graderCalls == 0)
        #expect(conv?.goalContract?.currentMilestone == 0)
    }

    @Test("with no ladder there is no milestone to delegate")
    func noLadderIsRefused() async {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)
        app.setGoalContract(for: id, GoalContract(objective: "Ship", criteria: [
            Criterion(text: "it works", kind: .qualitative, check: nil)
        ]))
        SubagentManager.shared.setGlobalState(app)
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        #expect(client.subagentCalls == 0, "no ladder must not spawn a subagent")
        #expect(app.conversations.first { $0.id == id }?.goalContract?.checkpointStatus == .running)
    }

    @Test("the final milestone is not delegable")
    func finalMilestoneIsRefused() async {
        let app = AppState(); let id = UUID(); ladder(on: app, id, currentMilestone: 1)
        let client = RoutingClient(main: [Self.delegateCall(), Self.response(nil)],
                                   subagentTerminal: Self.subagentDone)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("work", source: "User", conversationId: id)

        #expect(client.subagentCalls == 0, "the final milestone must not spawn a subagent")
        #expect(app.conversations.first { $0.id == id }?.goalContract?.checkpointStatus == .running)
    }
}
