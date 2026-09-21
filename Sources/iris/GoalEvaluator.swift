import Foundation

/// Lock-guarded slot for the graded evaluation. The completion callback is synchronous and
/// non-isolated, so it cannot `await` an actor; a lock is the available primitive.
private final class EvaluationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GoalEvaluation?
    func set(_ v: GoalEvaluation) { lock.withLock { if value == nil { value = v } } }
    func get() -> GoalEvaluation? { lock.withLock { value } }
}

final class GoalEvaluator: Sendable {
    static let shared = GoalEvaluator()
    private init() {}

    /// Runs a fresh-context grader against `contract`, writes the `GoalEvaluation` onto
    /// `originatingConversationId` for the UI to observe, and **returns it**.
    ///
    /// Fire-and-forget callers (the main agent's `goal_complete` grade) can discard the result and
    /// let the UI pick it up from the conversation. Programmatic callers — `SubagentManager`, and
    /// the checkpoint grade — use the return value instead of reading `lastGoalEvaluation` back
    /// out, which is only correct while that conversation still exists and nothing else has
    /// overwritten it (#102).
    ///
    /// `client` is injectable so tests can drive the grader with a `FakeLLMClient` instead of
    /// hitting the network.
    @discardableResult
    func evaluate(contract: GoalContract, workspace: String?, originatingConversationId originId: UUID,
                  app: AppState, client: any LLMClientProtocol = LLMClient()) async -> GoalEvaluation {

        // The directory the grader inspects. Callers resolve this to the main agent's effective
        // working directory (its bound workspace, or the process cwd it actually ran in), so the
        // grader never has to guess where the work is.
        let workspaceDir = workspace ?? FileManager.default.currentDirectoryPath

        let evalId = UUID()
        await MainActor.run {
            app.createNewConversation(id: evalId, isSubagent: true)
            app.updateConversationTitle(id: evalId, title: "Evaluator")
            app.setWorkspace(for: evalId, path: workspaceDir)   // its run_command runs here
            app.registerSubagent(id: evalId, role: "evaluator", kind: .evaluator)
        }

        // Fresh engine, evaluator principal. It never sees the working transcript.
        let checks = contract.criteria.compactMap { $0.kind == .executable ? $0.check : nil }
        let engine = IrisEngine(state: app, tier: .hard, principal: .evaluator, roleLabel: "evaluator", client: client, evaluatorChecks: checks)
        let prompt = Self.systemPrompt(for: contract, workspaceDir: workspaceDir)
        await engine.setSystemPrompt(text: prompt)

        // Filled in by the completion callback. The did-it-submit check below reads this rather
        // than probing whether `onEvaluationComplete` was cleared, so it cannot mistake a run that
        // succeeded for one that never submitted.
        let graded = EvaluationBox()

        // Resolve on submit_evaluation: reconcile against the contract's criteria and write graded.
        await MainActor.run {
            app.onEvaluationComplete[evalId] = { payload in
                let verdicts: [CriterionVerdict]
                if case .object(let obj)? = payload {
                    verdicts = GoalEvaluationParsing.verdicts(from: obj, criteria: contract.criteria,
                                                              judgements: contract.judgements)
                } else {
                    verdicts = GoalEvaluationParsing.verdicts(from: [:], criteria: contract.criteria,
                                                              judgements: contract.judgements)
                }
                let eval = GoalEvaluation(status: .graded, criteria: verdicts, startedAt: Date(), completedAt: Date())
                graded.set(eval)
                // Directly, not through a detached Task: the callback is already MainActor-isolated,
                // and deferring meant a caller could observe half-finished bookkeeping right after
                // awaiting `evaluate` (#103).
                app.recordEvaluation(for: originId, eval)
                app.onEvaluationComplete[evalId] = nil
                app.finishSession(id: evalId, status: "graded")
                app.deleteConversation(evalId)
            }
        }

        // Kick the grader loop; its activeGoal makes it auto-reprompt until it calls submit_evaluation.
        let evaluationPrompt = """
        The goal contract below is LOCKED. Your job is to independently grade every criterion —
        whether the finished work (in `\(workspaceDir)`) satisfies it — using read_file and
        run_command to gather your own evidence. The main agent claims it is done; you are the
        independent appraisal. When you have graded every criterion, call submit_evaluation.
        """

        // Lock the contract so the evaluator can't amend it, then fire the goal loop.
        await MainActor.run {
            app.updateConversationTitle(id: evalId, title: "Evaluator — \(contract.objective)")
            app.setGoalContract(for: evalId, contract)
            app.appendMessage(role: .system, content: evaluationPrompt, to: evalId)
        }
        await engine.processInput(evaluationPrompt, source: "GoalEvaluator", conversationId: evalId)

        // The grader submitted iff the callback ran and filled the box.
        if let eval = graded.get() { return eval }

        // Safety net: the grader loop exited without calling submit_evaluation (crash, timeout,
        // infinite loop detected, etc.). Write a `.failed` evaluation so the UI doesn't hang in
        // `.verifying` forever, and hand the same verdict back to the caller.
        let fallback = GoalEvaluationParsing.verdicts(from: [:], criteria: contract.criteria,
                                                      judgements: contract.judgements)
        let failed = GoalEvaluation(status: .failed, criteria: fallback, startedAt: Date(), completedAt: Date())
        await MainActor.run {
            app.recordEvaluation(for: originId, failed)
            app.onEvaluationComplete[evalId] = nil
            app.finishSession(id: evalId, status: "failed")
            app.deleteConversation(evalId)
        }
        return failed
    }

    private static func systemPrompt(for contract: GoalContract, workspaceDir: String) -> String {
        guard let url = Bundle.module.url(forResource: "EVALUATOR", withExtension: "md"),
              let base = try? String(contentsOf: url, encoding: .utf8),
              !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            fatalError("EVALUATOR.md resource missing from bundle — the evaluator cannot run without its system prompt.")
        }
        var s = base
        s += "\n\n## Workspace\nThe completed work is in this directory:\n`\(workspaceDir)`\n"
        s += "Your `run_command` calls already execute there. Confine your inspection to this directory — start with `ls`. NEVER search the wider filesystem (no `find /`, no reading files outside this directory, no `~root`/home snooping). If an expected artifact is not present here, the relevant criterion is `not_met` or `cannot_verify` — do not go hunting for it elsewhere.\n"
        s += "\n## The locked contract you are grading\nObjective: \(contract.objective)\n\nCriteria (grade each by its id):\n"
        for c in contract.criteria {
            let checkNote = (c.kind == .executable) ? " — run this check: `\(c.check ?? "")`" : ""
            let kindNote = (c.kind == .humanJudged) ? " — HUMAN-JUDGED: do NOT grade this; omit it." : ""
            s += "  - id \(c.id.uuidString) [\(c.kind.rawValue)] \(c.text)\(checkNote)\(kindNote)\n"
        }
        if !contract.outOfScope.isEmpty { s += "\nOut of scope (do not reward or penalize): \(contract.outOfScope.joined(separator: "; "))\n" }
        return s
    }
}
