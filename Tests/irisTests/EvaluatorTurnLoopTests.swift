import Testing
import Foundation
@testable import iris

/// A real grader inspects the workspace before it grades — `EVALUATOR.md` tells it to. These
/// pin the property every awaited caller of `GoalEvaluator.evaluate` depends on: one
/// `processInput` call runs the grader for as many model rounds as it needs, because tool calls
/// iterate INSIDE the turn (`iris.swift`, `while !turnFinished`). Only a terminal tool ends it.
/// A grader scripted to submit on its first round cannot detect a regression here.
@MainActor
@Suite("Evaluator turn loop", .serialized)
struct EvaluatorTurnLoopTests {
    private final class InspectThenSubmitGrader: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let criterionId: UUID
        private let inspectionRounds: Int

        init(criterionId: UUID, inspectionRounds: Int) {
            self.criterionId = criterionId
            self.inspectionRounds = inspectionRounds
        }
        var callCount: Int { lock.withLock { calls } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let n = lock.withLock { calls += 1; return calls }
            let fc: FunctionCall
            if n <= inspectionRounds {
                fc = FunctionCall(name: "read_file", args: ["path": .string("Package.swift")],
                                  id: nil, thought_signature: nil, thoughtSignature: nil)
            } else {
                fc = FunctionCall(name: "submit_evaluation", args: ["evaluations": .array([
                    .object(["criterion_id": .string(criterionId.uuidString),
                             "verdict": .string("met"), "evidence": .string("inspected the tree")])
                ])], id: nil, thought_signature: nil, thoughtSignature: nil)
            }
            let part = Part(text: nil, functionCall: fc, functionResponse: nil,
                            thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                  usageMetadata: nil)
        }
    }

    private func grade(inspectionRounds: Int) async -> (GoalEvaluation?, Int) {
        let app = AppState()
        app.autoApproveTools = true
        let originId = UUID()
        app.createNewConversation(id: originId)
        let c = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let client = InspectThenSubmitGrader(criterionId: c.id, inspectionRounds: inspectionRounds)

        await GoalEvaluator.shared.evaluate(
            contract: GoalContract(objective: "obj", criteria: [c]),
            workspace: FileManager.default.currentDirectoryPath,
            originatingConversationId: originId, app: app, client: client)

        return (app.conversations.first { $0.id == originId }?.lastGoalEvaluation, client.callCount)
    }

    @Test("a grader that inspects before submitting is graded, not written off as failed")
    func inspectsThenSubmits() async {
        let (eval, calls) = await grade(inspectionRounds: 1)
        #expect(calls == 2)
        #expect(eval?.status == .graded)
        #expect(eval?.criteria.first?.verdict == .met)
    }

    @Test("several rounds of inspection still land a graded verdict")
    func multipleInspectionRounds() async {
        let (eval, calls) = await grade(inspectionRounds: 3)
        #expect(calls == 4)
        #expect(eval?.status == .graded)
        #expect(eval?.criteria.first?.verdict == .met)
    }

    @Test("a grader that never submits is recorded as failed, not left verifying forever")
    func neverSubmits() async {
        // 500 inspection rounds: it never reaches submit_evaluation. The safety net must fire.
        let (eval, _) = await grade(inspectionRounds: 500)
        #expect(eval?.status == .failed)
        #expect(eval?.criteria.first?.verdict == .cannotVerify)
    }
}
