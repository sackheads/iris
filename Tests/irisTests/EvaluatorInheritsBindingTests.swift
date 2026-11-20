import Testing
import Foundation
@testable import IrisKit

/// #974 Task 10 (C6): the evaluator acts with the authority of the run it grades, no more. A
/// non-owner run's grader is bound by that run's grant, so a tool, memory write or file read the
/// run could not make is refused inside the grader too, and an evaluator with no parent binding at
/// all is not run.
@MainActor
@Suite("The evaluator inherits its parent's binding (#974 Task 10, C6)", .serialized, .timeLimit(.minutes(2)))
struct EvaluatorInheritsBindingTests {
    /// A grader that tries `attempts` (tool name, args) in order, one per round, then submits. It
    /// keeps every function response it was handed back, so a test reads what the dispatcher said.
    private final class ProbingGrader: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var seen: [String] = []
        private let criterionId: UUID
        private let attempts: [(String, [String: JSONValue])]

        init(criterionId: UUID, attempts: [(String, [String: JSONValue])]) {
            self.criterionId = criterionId
            self.attempts = attempts
        }
        var responses: [String] { lock.withLock { seen } }
        var callCount: Int { lock.withLock { calls } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let n = lock.withLock { () -> Int in
                calls += 1
                let texts = request.contents.flatMap(\.parts).compactMap { part -> String? in
                    guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
                    return s
                }
                seen = texts
                return calls
            }
            let fc: FunctionCall
            if n <= attempts.count {
                fc = FunctionCall(name: attempts[n - 1].0, args: attempts[n - 1].1, id: "p\(n)", thought_signature: nil, thoughtSignature: nil)
            } else {
                fc = FunctionCall(name: "submit_evaluation", args: ["evaluations": .array([
                    .object(["criterion_id": .string(criterionId.uuidString), "verdict": .string("met"), "evidence": .string("probed")])
                ])], id: "s", thought_signature: nil, thoughtSignature: nil)
            }
            let part = Part(text: nil, functionCall: fc, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
    }

    private func nonOwner(tools: Set<String>, memoryWrite: MemoryTier = .none) -> AccessBinding {
        AccessBinding(profile: AccessProfile(memoryWrite: memoryWrite, tools: .set(tools)), principal: .main, isOwner: false)
    }

    /// Grade once with `parent`; returns (the evaluation, what the grader was told for each attempt).
    private func grade(parent: AccessBinding?, attempts: [(String, [String: JSONValue])]) async -> (GoalEvaluation, [String], ProbingGrader) {
        let app = AppState()
        app.autoApproveTools = true
        let originId = UUID()
        app.createNewConversation(id: originId)
        let c = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let client = ProbingGrader(criterionId: c.id, attempts: attempts)
        let evaluation = await GoalEvaluator.shared.evaluate(
            contract: GoalContract(objective: "obj", criteria: [c]),
            workspace: FileManager.default.temporaryDirectory.path,
            originatingConversationId: originId, app: app, client: client, parentBinding: parent)
        return (evaluation, client.responses, client)
    }

    @Test("the evaluator's binding is the parent's grant under the evaluator principal, and a nil parent has none")
    func bindingComposition() async {
        let parent = nonOwner(tools: ["read_file"], memoryWrite: .task)
        let child = GoalEvaluator.evaluatorBinding(ofParent: parent)
        #expect(child?.profile == parent.profile)
        #expect(child?.principal == .evaluator)
        #expect(child?.isOwner == false)
        #expect(GoalEvaluator.evaluatorBinding(ofParent: nil) == nil)
        // The engine hands the grader's dispatcher that binding, whatever the turn.
        let engine = IrisEngine(state: AppState(), tier: .hard, principal: .evaluator, roleLabel: "evaluator", client: FakeLLMClient(responses: []),
                                binding: child)
        let effective = await engine.bindingForCall(conversationId: UUID())
        #expect(effective == child)
    }

    @Test("a non-owner parent's grader is refused a tool the parent cannot call")
    func toolOutsideTheParentGrantIsRefused() async {
        let marker = "grader-ran-this-\(UUID().uuidString)"
        let (evaluation, told, _) = await grade(parent: nonOwner(tools: ["read_file"]),
                                                 attempts: [("run_command", ["command": .string("echo \(marker)")])])
        #expect(!told.isEmpty, "the grader reached its dispatcher")
        #expect(!told.contains { $0.contains(marker) }, "the command must not have run: \(told)")
        #expect(evaluation.status == .graded)
    }

    @Test("a non-owner parent with no memory-write grant: the grader cannot write memory either")
    func memoryWriteOutsideTheParentGrantIsRefused() async {
        let (_, told, _) = await grade(parent: nonOwner(tools: ["read_file", "save_fact"]),
                                       attempts: [("save_fact", ["fact": .string("grader-planted-fact"), "category": .string("general")])])
        #expect(!told.isEmpty)
        #expect(!told.contains { $0.lowercased().contains("saved") }, "no memory write for a parent with memoryWrite == .none: \(told)")
    }

    @Test("no parent binding: the evaluation is refused with a reason, not run")
    func nilParentIsRefusedNotRun() async {
        let app = AppState()
        app.autoApproveTools = true
        let originId = UUID()
        app.createNewConversation(id: originId)
        let c = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let client = ProbingGrader(criterionId: c.id, attempts: [])
        let evaluation = await GoalEvaluator.shared.evaluate(
            contract: GoalContract(objective: "obj", criteria: [c]),
            workspace: FileManager.default.temporaryDirectory.path,
            originatingConversationId: originId, app: app, client: client)
        #expect(evaluation.status == .failed, "a refused grade is not a pass")
        #expect(client.callCount == 0, "the grader was never run")
        #expect(app.conversations.first { $0.id == originId }?.lastGoalEvaluation?.status == .failed)
        let said = app.conversations.first { $0.id == originId }?.messages.map(\.content) ?? []
        #expect(said.contains(GoalEvaluator.noParentBindingRefusal), "the person is told why: \(said)")
    }
}
