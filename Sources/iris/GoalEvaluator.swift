import Foundation

final class GoalEvaluator: Sendable {
    static let shared = GoalEvaluator()
    private init() {}

    /// Runs a fresh-context grader against `contract` and writes a `GoalEvaluation` onto
    /// `originatingConversationId`. Non-blocking for the caller: dispatch this in a detached Task.
    /// `client` is injectable so tests can drive the grader with a `ScriptedLLMClient` instead of
    /// hitting the network.
    func evaluate(contract: GoalContract, workspace: String?, originatingConversationId originId: UUID,
                  app: AppState, client: any LLMClientProtocol = LLMClient()) async {

        // The directory the grader inspects. Callers resolve this to the main agent's effective
        // working directory (its bound workspace, or the process cwd it actually ran in), so the
        // grader never has to guess where the work is.
        let workspaceDir = workspace ?? FileManager.default.currentDirectoryPath

        let evalId = UUID()
        await MainActor.run {
            app.createNewConversation(id: evalId, isSubagent: true)
            app.updateConversationTitle(id: evalId, title: "Evaluator")
            app.setWorkspace(for: evalId, path: workspaceDir)   // its run_command runs here
        }

        // Fresh engine, evaluator principal. It never sees the working transcript.
        let checks = contract.criteria.compactMap { $0.kind == .executable ? $0.check : nil }
        let engine = IrisEngine(state: app, tier: .hard, principal: .evaluator, roleLabel: "evaluator", client: client, evaluatorChecks: checks)
        let prompt = Self.systemPrompt(for: contract, workspaceDir: workspaceDir)
        await engine.setSystemPrompt(text: prompt)

        // Resolve on submit_evaluation: reconcile against the contract's criteria and write graded.
        await MainActor.run {
            app.onEvaluationComplete[evalId] = { payload in
                let verdicts: [CriterionVerdict]
                if case .object(let obj)? = payload {
                    verdicts = GoalEvaluationParsing.verdicts(from: obj, criteria: contract.criteria)
                } else {
                    verdicts = GoalEvaluationParsing.verdicts(from: [:], criteria: contract.criteria)
                }
                let eval = GoalEvaluation(status: .graded, criteria: verdicts, startedAt: Date(), completedAt: Date())
                Task { @MainActor in
                    app.recordEvaluation(for: originId, eval)
                    app.onEvaluationComplete[evalId] = nil
                    app.deleteConversation(evalId)
                }
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

        // Safety net: if the grader loop exits without calling submit_evaluation (crash, timeout,
        // infinite loop detected, etc.), write a `.failed` evaluation so the UI doesn't hang in
        // `.verifying` forever. The onEvaluationComplete callback is nil'd by submit_evaluation
        // synchronously on MainActor; if it's still non-nil here, the grader didn't submit.
        let didSubmit = await MainActor.run { app.onEvaluationComplete[evalId] == nil }
        if !didSubmit {
            let fallback = GoalEvaluationParsing.verdicts(from: [:], criteria: contract.criteria)
            await MainActor.run {
                app.recordEvaluation(for: originId, GoalEvaluation(status: .failed, criteria: fallback, startedAt: Date(), completedAt: Date()))
                app.onEvaluationComplete[evalId] = nil
                app.deleteConversation(evalId)
            }
        }
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
