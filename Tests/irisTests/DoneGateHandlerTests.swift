import Testing
import Foundation
@testable import iris

/// Slice D1: `goal_complete` becomes a gate. These drive a real IrisEngine with a scripted client.
///
/// The grader lane synthesizes verdicts from the criterion ids in its own system prompt, because
/// `GoalEvaluationParsing` reconciles strictly by `criterion_id` and contract ids are minted per
/// test — a canned payload with a hardcoded id silently yields `cannot_verify` for everything.
@MainActor
@Suite("Done gate handler (D1)", .serialized)
struct DoneGateHandlerTests {
    /// Routes by principal: the grader is the engine whose toolset offers `submit_evaluation`.
    /// `graderVerdicts` maps criterion TEXT to the verdict the grader should return for it.
    final class GateClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let idPattern = /id ([0-9A-Fa-f-]{36}) \[[a-zA-Z]+\] ([^\n]*)/
        private let lock = NSLock()
        private var mainIndex = 0
        private var graderRuns = 0
        private let mainScript: [GeminiResponse]
        private let graderVerdicts: [String: String]
        private let graderStatus: EvaluationStatus

        init(main: [GeminiResponse], graderVerdicts: [String: String],
             graderStatus: EvaluationStatus = .graded) {
            self.mainScript = main
            self.graderVerdicts = graderVerdicts
            self.graderStatus = graderStatus
        }
        var graderRunCount: Int { lock.withLock { graderRuns } }

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
                    // A `.failed` grader never submits; the evaluator's safety net records failed.
                    guard graderStatus == .graded else { return Self.text("thinking") }
                    graderRuns += 1
                    let entries = systemText.matches(of: Self.idPattern).map {
                        (id: String($0.output.1), text: String($0.output.2).trimmingCharacters(in: .whitespaces))
                    }
                    let evaluations = JSONValue.array(entries.map { entry in
                        .object(["criterion_id": .string(entry.id),
                                 "verdict": .string(graderVerdicts[entry.text] ?? "met"),
                                 "evidence": .string("grader saw: \(entry.text)")])
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

    static func goalComplete(_ summary: String = "done") -> GeminiResponse {
        response(FunctionCall(name: "goal_complete", args: ["summary": .string(summary)],
                              id: nil, thought_signature: nil, thoughtSignature: nil))
    }

    /// A locked two-criterion contract on a fresh AppState.
    @discardableResult
    func lockContract(on app: AppState, _ id: UUID) -> (Criterion, Criterion) {
        app.createNewConversation(id: id)
        let a = Criterion(text: "builds", kind: .qualitative, check: nil)
        let b = Criterion(text: "tested", kind: .qualitative, check: nil)
        app.setGoalContract(for: id, GoalContract(objective: "ship it", criteria: [a, b]))
        return (a, b)
    }

    @Test("the terminal grade is awaited, so the verdict is present when completion returns")
    func gradeIsAwaited() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: [:])   // everything met
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        // Detached grading left this .verifying (or nil) at this point; awaited means it is graded.
        #expect(conv?.lastGoalEvaluation?.status == .graded)
        #expect(client.graderRunCount == 1)
        #expect(conv?.activeGoal == nil, "an all-met goal still completes")
    }

    @Test("a not_met criterion refuses completion and keeps the goal alive")
    func notMetRefuses() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["tested": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal != nil, "the goal must stay alive so the agent can keep working")
        #expect(conv?.goalContract != nil)
        #expect(conv?.goalContract?.gateAttempts == 1)
    }

    @Test("the refusal tells the agent which criterion failed and why")
    func refusalCarriesEvidence() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["tested": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        // The refusal reaches the agent as the tool RESULT, which lands in `history` as a
        // functionResponse — not in `messages`, which is the human-facing transcript.
        let conv = app.conversations.first { $0.id == id }
        let toolResults = (conv?.history ?? []).flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
        #expect(toolResults.contains("tested"), "the agent must be told which criterion blocked")
        #expect(toolResults.contains("grader saw: tested"), "and the grader's evidence for it")
    }

    @Test("all met completes on the first attempt, gated")
    func allMetCompletes() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)], graderVerdicts: [:])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil)
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .passed)
    }

    @Test("cannot_verify completes without burning a retry")
    func cannotVerifyCompletes() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: ["tested": "cannot_verify"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "an unverifiable criterion must not block")
        #expect(client.graderRunCount == 1, "and must not trigger a retry")
    }

    @Test("a failed grader completes, recorded as ungated rather than blocking on a non-result")
    func failedGraderCompletes() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        lockContract(on: app, id)
        let client = GateClient(main: [Self.goalComplete(), Self.response(nil)],
                                graderVerdicts: [:], graderStatus: .failed)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil)
        #expect(conv?.lastGoalEvaluation?.gateOutcome == .ungatedGraderFailed)
    }

    @Test("refuse, waive, then complete — with the verdict and the waiver both on record")
    func waiveThenComplete() async {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        let (_, b) = lockContract(on: app, id)
        // Attempt 1 fails on "tested"; the agent waives it; attempt 2 completes.
        let client = GateClient(
            main: [Self.goalComplete(),
                   Self.response(FunctionCall(name: "waive_criterion",
                                              args: ["criterion_id": .string(b.id.uuidString),
                                                     "reason": .string("no test harness in this repo")],
                                              id: nil, thought_signature: nil, thoughtSignature: nil)),
                   Self.goalComplete(),
                   Self.response(nil)],
            graderVerdicts: ["tested": "not_met"])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client)
        await engine.processInput("go", source: "User", conversationId: id)
        // The refusal ends the turn; drive the follow-up turns the auto-reprompt would.
        await engine.processInput("continue", source: "System", conversationId: id)

        let conv = app.conversations.first { $0.id == id }
        #expect(conv?.activeGoal == nil, "the waived criterion no longer blocks")
        #expect(conv?.lastGoalEvaluation?.waivers[b.id] == "no test harness in this repo",
                "the waiver must survive clearGoal destroying the contract")
        #expect(conv?.lastGoalEvaluation?.criteria.first { $0.criterionId == b.id }?.verdict == .notMet,
                "and the grader's verdict must still be on record beside it")
    }
}
