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

    /// Returns (what `evaluate` returned, what it recorded on the conversation, grader call count).
    private func grade(inspectionRounds: Int) async -> (GoalEvaluation, GoalEvaluation?, Int) {
        let app = AppState()
        app.autoApproveTools = true
        let originId = UUID()
        app.createNewConversation(id: originId)
        let c = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let client = InspectThenSubmitGrader(criterionId: c.id, inspectionRounds: inspectionRounds)

        let returned = await GoalEvaluator.shared.evaluate(
            contract: GoalContract(objective: "obj", criteria: [c]),
            workspace: FileManager.default.currentDirectoryPath,
            originatingConversationId: originId, app: app, client: client)

        return (returned, app.conversations.first { $0.id == originId }?.lastGoalEvaluation, client.callCount)
    }

    @Test("a grader that inspects before submitting is graded, not written off as failed")
    func inspectsThenSubmits() async {
        let (returned, recorded, calls) = await grade(inspectionRounds: 1)
        #expect(calls == 2)
        #expect(returned.status == .graded)
        #expect(returned.criteria.first?.verdict == .met)
        #expect(recorded?.status == .graded)
    }

    @Test("several rounds of inspection still land a graded verdict")
    func multipleInspectionRounds() async {
        let (returned, _, calls) = await grade(inspectionRounds: 3)
        #expect(calls == 4)
        #expect(returned.status == .graded)
        #expect(returned.criteria.first?.verdict == .met)
    }

    @Test("evaluate returns the same verdict it records, so callers need no read-back")
    func returnsWhatItRecords() async {
        let (returned, recorded, _) = await grade(inspectionRounds: 1)
        // The returned value IS the verdict — a caller should never have to go looking for it on
        // the conversation, where it is only correct while that conversation still exists and
        // nothing else has overwritten it.
        #expect(returned == recorded)
    }

    @Test("the returned verdict does not depend on the deferred recording task having run")
    func returnedVerdictIsIndependentOfRecordingHop() async {
        // The graded evaluation is captured synchronously inside the completion callback, before
        // the MainActor hop that writes it to the conversation (#103). The return value is
        // therefore correct regardless of how that hop is scheduled.
        let (returned, _, _) = await grade(inspectionRounds: 2)
        #expect(returned.status == .graded)
        #expect(returned.criteria.count == 1)
    }

    @Test("by the time evaluate returns, its bookkeeping is done — nothing is left pending")
    func bookkeepingIsCompleteOnReturn() async {
        // The completion callback records the evaluation and deletes the evaluator's throwaway
        // conversation. Deferring that to a later runloop turn leaves callers observing a
        // half-finished state right after the await (#103).
        let app = AppState()
        app.autoApproveTools = true
        let originId = UUID()
        app.createNewConversation(id: originId)
        let c = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let client = InspectThenSubmitGrader(criterionId: c.id, inspectionRounds: 1)

        _ = await GoalEvaluator.shared.evaluate(
            contract: GoalContract(objective: "obj", criteria: [c]),
            workspace: FileManager.default.currentDirectoryPath,
            originatingConversationId: originId, app: app, client: client)

        #expect(app.conversations.first { $0.id == originId }?.lastGoalEvaluation?.status == .graded)
        // Assert the evaluator's own throwaway conversation is gone, by identity rather than by
        // total count: AppState persists conversations to UserDefaults.standard even under test, so
        // a fresh AppState() loads every conversation any previous run left behind and the count is
        // not a stable baseline.
        #expect(app.conversations.contains { $0.title.hasPrefix("Evaluator") } == false,
                "the evaluator conversation should already be gone")
    }

    @Test("a grader that never submits is recorded as failed, not left verifying forever")
    func neverSubmits() async {
        // 500 inspection rounds: it never reaches submit_evaluation. The safety net must fire.
        let (returned, recorded, _) = await grade(inspectionRounds: 500)
        #expect(returned.status == .failed)
        #expect(returned.criteria.first?.verdict == .cannotVerify)
        #expect(recorded?.status == .failed)
    }

    /// Repeats one identical tool call forever, which trips loop detection (threshold 5) inside a
    /// single turn. Records whether it was ever asked to summarize and call `goal_complete`.
    private final class StuckGrader: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var sawSoftStopPrompt = false
        var wasAskedToGoalComplete: Bool { lock.withLock { sawSoftStopPrompt } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let text = request.contents.flatMap { $0.parts }.compactMap(\.text).joined()
            if text.contains("You have reached a stopping condition") {
                lock.withLock { sawSoftStopPrompt = true }
            }
            let fc = FunctionCall(name: "read_file", args: ["path": .string("Package.swift")],
                                  id: nil, thought_signature: nil, thoughtSignature: nil)
            let part = Part(text: nil, functionCall: fc, functionResponse: nil,
                            thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                  usageMetadata: nil)
        }
    }

    @Test("a stuck evaluator is not asked to call goal_complete, which it does not have")
    func stuckEvaluatorIsNotAskedForGoalComplete() async {
        // The evaluator's toolset is read_file / run_command / submit_evaluation — no
        // `goal_complete`, and no onSubagentComplete entry. Asking it to call one wastes a model
        // turn on an impossible instruction and reads like a graceful stop in the transcript (#104).
        let app = AppState()
        app.autoApproveTools = true
        let originId = UUID()
        app.createNewConversation(id: originId)
        let c = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let client = StuckGrader()

        let verdict = await GoalEvaluator.shared.evaluate(
            contract: GoalContract(objective: "obj", criteria: [c]),
            workspace: FileManager.default.currentDirectoryPath,
            originatingConversationId: originId, app: app, client: client)

        #expect(client.wasAskedToGoalComplete == false,
                "the evaluator was asked for a tool it cannot call")
        // The outcome was already honest via the safety net; that must not regress.
        #expect(verdict.status == .failed)
        #expect(app.conversations.first { $0.id == originId }?.lastGoalEvaluation?.status == .failed)
    }
}
