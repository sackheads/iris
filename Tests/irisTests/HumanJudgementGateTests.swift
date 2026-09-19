import Testing
import Foundation
@testable import iris

/// The gate's judgement pause (spec §3, §4). Agent-fixable problems come first; a judgement pause
/// happens only when nothing else blocks, and it never burns a retry.
@MainActor
@Suite("Human judgement gate (D2)", .serialized)
struct HumanJudgementGateTests {
    final class GateClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let idPattern = /id ([0-9A-Fa-f-]{36}) \[[a-zA-Z]+\] ([^\n]*)/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderRuns = 0
        private let mainScript: [GeminiResponse]
        private let graderVerdicts: [String: String]

        init(main: [GeminiResponse], graderVerdicts: [String: String]) {
            self.mainScript = main
            self.graderVerdicts = graderVerdicts
        }
        var graderRunCount: Int { lock.withLock { graderRuns } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let offersSubmit = request.tools?.contains {
                $0.functionDeclarations.contains { $0.name == "submit_evaluation" }
            } ?? false
            let systemText = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            return lock.withLock {
                if offersSubmit {
                    graderRuns += 1
                    let entries = systemText.matches(of: Self.idPattern).map {
                        (id: String($0.output.1),
                         text: String($0.output.2).trimmingCharacters(in: .whitespaces))
                    }
                    // A humanJudged criterion is omitted entirely; parsing assigns human_pending.
                    let graded = entries.compactMap { e -> JSONValue? in
                        guard let v = graderVerdicts[e.text] else { return nil }
                        return .object(["criterion_id": .string(e.id), "verdict": .string(v),
                                        "evidence": .string("grader saw: \(e.text)")])
                    }
                    let part = Part(text: nil,
                                    functionCall: FunctionCall(name: "submit_evaluation",
                                                               args: ["evaluations": .array(graded)],
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

    static func goalComplete() -> GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string("done")],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// A locked contract with one machine criterion and one human-judged criterion.
    @discardableResult
    func lockMixedContract(on app: AppState, _ id: UUID) -> (machine: Criterion, judged: Criterion) {
        app.createNewConversation(id: id)
        let machine = Criterion(text: "builds", kind: .qualitative, check: nil)
        let judged = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship it", criteria: [machine, judged]))
        return (machine, judged)
    }

    @Test("a human_pending criterion alone pauses, without burning a retry")
    func pausesWithoutRetrying() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockMixedContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["builds": "met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement == true)
        #expect(conv?.activeGoal != nil, "the goal stays alive while it waits for you")
        #expect(conv?.goalContract?.gateAttempts == 0,
                "a retry cap bounds an agent that might fix something; this is not that")
        #expect(client.graderRunCount == 1)
    }

    @Test("an agent-fixable failure comes first — no judgement pause while not_met is outstanding")
    func notMetTakesPriority() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockMixedContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["builds": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.goalContract?.awaitingHumanJudgement != true,
                "do not ask for judgement on a goal that is about to change underneath the user")
        #expect(conv?.goalContract?.gateAttempts == 1, "this one IS the agent's to fix")
    }

    @Test("a failed grader never triggers a judgement pause")
    func failedGraderDoesNotPause() {
        // A .failed evaluation's verdicts are placeholders (#54's treatment), so a human_pending
        // among them is not a genuine request for judgement — asking the user to rule on a grade
        // that never happened would be theatre.
        let judged = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let contract = GoalContract(objective: "ship", criteria: [judged])
        let failed = GoalEvaluation(
            status: .failed,
            criteria: [CriterionVerdict(criterionId: judged.id, criterionText: judged.text,
                                        kind: .humanJudged, verdict: .humanPending,
                                        evidence: "", method: .human)],
            startedAt: Date(), completedAt: Date())
        #expect(contract.pendingJudgement(from: failed).isEmpty)
    }

    @Test("a contract with no humanJudged criteria never pauses")
    func noJudgedCriteriaNeverPauses() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        let c = Criterion(text: "builds", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship", criteria: [c]))
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["builds": "met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "D1's behaviour, unchanged")
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .passed)
    }
}
