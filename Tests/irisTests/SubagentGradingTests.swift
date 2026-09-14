import Testing
import Foundation
@testable import iris

/// Slice B3 loop behaviour: binding a unit contract to a delegated subagent and grading the
/// finished run with the slice-C evaluator.
// Serialized: `SubagentManager.shared` holds the AppState globally, so parallel tests in this
// suite would hand each other's state to runSubagent.
@MainActor
@Suite("Subagent grading (B3)", .serialized)
struct SubagentGradingTests {

    /// Routes scripted responses by principal rather than by call order: the grader is the engine
    /// whose toolset offers `submit_evaluation`, and the subagent is the one carrying the role
    /// system prompt. Order-based scripting is unreliable here because the subagent's final turn
    /// and the grader's first turn overlap.
    ///
    /// The grader lane SYNTHESIZES its payload from the criterion ids in its own system prompt,
    /// exactly as a real grader does. `GoalEvaluationParsing` reconciles strictly by
    /// `criterion_id`, and a unit contract's ids are minted during parsing — so a canned payload
    /// with a hardcoded id could never match, and every criterion would fall back to
    /// `cannot_verify`.
    private final class RoutingLLMClient: LLMClientProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static let uuidPattern = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/

        private let lock = NSLock()
        private var index: [String: Int] = [:]
        private var graderCallCount = 0
        private var graderSystemText = ""
        private let scripts: [String: [GeminiResponse]]
        private let graderVerdict: (value: String, evidence: String)?

        /// `graderVerdict` nil ⇒ the grader never submits (used where it must not run at all).
        init(main: [GeminiResponse] = [], subagent: [GeminiResponse],
             graderVerdict: (value: String, evidence: String)? = nil) {
            self.scripts = ["main": main, "subagent": subagent]
            self.graderVerdict = graderVerdict
        }

        var graderCalls: Int { lock.withLock { graderCallCount } }
        /// The evaluator's system prompt names the directory it grades in (GoalEvaluator §Workspace).
        var graderPrompt: String { lock.withLock { graderSystemText } }

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
            let lane = offersSubmit ? "grader"
                     : (systemText.contains("specialized subagent role") ? "subagent" : "main")

            return lock.withLock {
                if lane == "grader" {
                    graderCallCount += 1
                    if graderSystemText.isEmpty { graderSystemText = systemText }
                    // Submit once, then fall silent so the grader loop can end.
                    guard graderCallCount == 1, let graderVerdict else { return Self.text("done") }
                    let ids = systemText.matches(of: Self.uuidPattern).map { String($0.output) }
                    let evaluations = JSONValue.array(ids.map {
                        .object(["criterion_id": .string($0),
                                 "verdict": .string(graderVerdict.value),
                                 "evidence": .string(graderVerdict.evidence)])
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
                let script = scripts[lane] ?? []
                guard !script.isEmpty else { return Self.text("done") }
                let i = index[lane] ?? 0
                index[lane] = i + 1
                return script[min(i, script.count - 1)]
            }
        }
    }

    private func response(_ fc: FunctionCall?) -> GeminiResponse {
        let part = Part(text: fc == nil ? "done" : nil, functionCall: fc, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> FunctionCall {
        FunctionCall(name: name, args: args, id: nil, thought_signature: nil, thoughtSignature: nil)
    }

    private var goalComplete: GeminiResponse {
        response(call("goal_complete", ["summary": .string("unit is done")]))
    }

    private func criteriaJSON(_ text: String) -> JSONValue {
        .array([.object(["text": .string(text), "kind": .string("qualitative")])])
    }

    /// A graded unit, built the way `invoke_subagent` builds one.
    private func gradedUnit(_ text: String, task: String = "build a widget") -> DelegatedUnit {
        DelegatedUnit(contract: GoalContractParsing.unitContract(
            task: task, criteriaJSON: criteriaJSON(text))!, grade: true)
    }

    // NOTE: assertions below read the returned prose and this suite's own client, never
    // `state.conversations`. `SubagentManager.shared` holds its AppState in a global, so a suite
    // running in parallel can swap it mid-run — the rendered result and the injected client are
    // the only handles guaranteed to belong to this test. Persistence of the new fields is
    // covered separately by `storesTheGradedResult` below, which touches no singleton.
    private func freshState() -> (AppState, UUID) {
        let state = AppState()
        SubagentManager.shared.setGlobalState(state)
        let parentId = UUID()
        state.createNewConversation(id: parentId)
        return (state, parentId)
    }

    @Test("a contracted subagent that completes comes back graded")
    func contractedRunIsGraded() async {
        let (_, parentId) = freshState()
        let client = RoutingLLMClient(subagent: [goalComplete, response(nil)],
                                      graderVerdict: ("met", "saw the widget"))

        let rendered = await SubagentManager.shared.runSubagent(
            role: "engineer", task: "build a widget", effort: "easy",
            parentConversationId: parentId, unit: gradedUnit("the widget exists"),
            client: client)

        #expect(client.graderCalls > 0, "the evaluator should have been invoked")
        #expect(rendered.contains("Independent grader verdict (fresh context): 1/1 met"))
        #expect(rendered.contains("✓ the widget exists — met"))
        #expect(rendered.contains("Summary (UNVERIFIED self-report): unit is done"))
    }

    @Test("a contracted run that times out carries its contract but is never graded")
    func timedOutContractedRunIsNotGraded() async {
        let (_, parentId) = freshState()
        // Never terminates, so the contract is still observable on the conversation at the cap.
        let client = RoutingLLMClient(subagent: [response(nil)])

        let rendered = await SubagentManager.shared.runSubagent(
            role: "engineer", task: "build a widget", effort: "easy",
            parentConversationId: parentId, unit: gradedUnit("the widget exists"),
            maxIterations: 2, client: client)

        // A run that never claimed done is never graded, even though it carried a contract.
        #expect(client.graderCalls == 0)
        #expect(rendered.contains("status: timed out"))
        #expect(!rendered.contains("Independent grader verdict"))
        // The contract still reached the result: the parent is told what the run was held to.
        #expect(rendered.contains("Held to 1 criterion"))
        #expect(rendered.contains("Summary (UNVERIFIED self-report)"))
    }

    // MARK: - Tool surface

    @Test("invoke_subagent declares an optional criteria array whose items Gemini will accept")
    func criteriaSchemaIsWellFormed() {
        let decl = SubagentManager.toolDeclaration()
        let criteria = decl.parameters?.properties?["criteria"]
        #expect(criteria?.type == "ARRAY")
        #expect(criteria?.items?.type == "OBJECT")
        #expect(criteria?.items?.properties?["text"] != nil)
        #expect(criteria?.items?.properties?["kind"] != nil)
        #expect(criteria?.items?.properties?["check"] != nil)
        // An ARRAY without `items` is a hard 400 from Gemini.
        #expect([decl].arrayItemsViolations().isEmpty)
        // criteria stays OPTIONAL — every existing ungraded call must keep working untouched.
        #expect(decl.parameters?.required == ["role", "task", "effort"])
    }

    @Test("criteria on the tool call reach the subagent and come back graded")
    func criteriaFlowThroughTheHandler() async {
        let (state, parentId) = freshState()
        let invoke = response(call("invoke_subagent", [
            "role": .string("engineer"),
            "task": .string("build a widget"),
            "effort": .string("easy"),
            "criteria": criteriaJSON("the widget exists")
        ]))
        let client = RoutingLLMClient(main: [invoke, response(nil)],
                                      subagent: [goalComplete, response(nil)],
                                      graderVerdict: ("met", "saw it"))

        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client)
        await engine.processInput("delegate it", source: "User", conversationId: parentId)

        // The grader only ever runs when a unit contract was bound, so a grader call is proof the
        // tool call's `criteria` reached SubagentManager through the handler.
        #expect(client.graderCalls > 0)
    }

    @Test("a subagent with no criteria is never graded and renders the B2 prose")
    func uncontractedRunUnchanged() async {
        let (_, parentId) = freshState()
        let client = RoutingLLMClient(subagent: [goalComplete, response(nil)])

        let rendered = await SubagentManager.shared.runSubagent(
            role: "engineer", task: "build a widget", effort: "easy",
            parentConversationId: parentId, client: client)

        #expect(client.graderCalls == 0, "no contract means no grade")
        #expect(!rendered.contains("Independent grader verdict"))
        #expect(rendered.contains("Summary: unit is done"))
    }

    @Test("a delegated unit is graded in the parent's workspace, not the process cwd")
    func inheritsParentWorkspace() async {
        let (state, parentId) = freshState()
        // A bound workspace on the parent is the case that matters: without inheritance the
        // subagent works in one tree and the grader grades another (the Iris repo).
        let workspace = NSTemporaryDirectory() + "iris-b3-ws-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workspace) }
        state.setWorkspace(for: parentId, path: workspace)

        let client = RoutingLLMClient(subagent: [goalComplete, response(nil)],
                                      graderVerdict: ("met", "saw the widget"))
        _ = await SubagentManager.shared.runSubagent(
            role: "engineer", task: "build a widget", effort: "easy",
            parentConversationId: parentId, unit: gradedUnit("the widget exists"),
            client: client)

        #expect(client.graderCalls > 0)
        #expect(client.graderPrompt.contains(workspace),
                "the grader should inspect the parent's workspace, not the process cwd")
    }

    @Test("an ungraded unit binds the contract as an oracle but runs no grader")
    func ungradedUnitIsNotGraded() async throws {
        let (_, parentId) = freshState()
        let client = RoutingLLMClient(subagent: [goalComplete, response(nil)],
                                      graderVerdict: ("met", "should never be asked for"))
        let contract = try #require(GoalContractParsing.unitContract(
            task: "build a widget", criteriaJSON: criteriaJSON("the widget exists")))

        let rendered = await SubagentManager.shared.runSubagent(
            role: "engineer", task: "build a widget", effort: "easy",
            parentConversationId: parentId,
            unit: DelegatedUnit(contract: contract, grade: false),
            client: client)

        // The unit was bound (the parent is told what it was held to) but nothing graded it.
        #expect(client.graderCalls == 0, "grade: false must not spin up an evaluator")
        #expect(!rendered.contains("Independent grader verdict"))
        #expect(rendered.contains("Held to 1 criterion"))
    }

    // MARK: - Persistence

    @Test("a graded result survives the round-trip onto its conversation")
    func storesTheGradedResult() throws {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        let c = Criterion(text: "the widget exists", kind: .qualitative, check: nil)
        let contract = GoalContract(objective: "build a widget", criteria: [c])
        let result = SubagentResult(
            role: "engineer", status: .completed, calledGoalComplete: true,
            summary: "unit is done", filesWritten: [], startedAt: Date(), endedAt: Date(),
            unitContract: contract,
            verdict: GoalEvaluation(status: .graded, criteria: [
                CriterionVerdict(criterionId: c.id, criterionText: c.text, kind: .qualitative,
                                 verdict: .met, evidence: "saw it", method: .judge)
            ], startedAt: Date(), completedAt: Date()))
        app.setSubagentResult(for: id, result)

        let stored = try #require(app.conversations.first { $0.id == id }?.subagentResult)
        #expect(stored.unitContract?.objective == "build a widget")
        #expect(stored.verdict?.criteria.first?.verdict == .met)

        // And survives the encode/decode the conversation store puts it through.
        let conv = try #require(app.conversations.first { $0.id == id })
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.subagentResult?.verdict?.criteria.first?.verdict == .met)
        #expect(back.subagentResult?.unitContract?.criteria.count == 1)
    }
}
