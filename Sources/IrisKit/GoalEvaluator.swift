import Foundation

/// Lock-guarded slot for the graded evaluation. The completion callback is synchronous and
/// non-isolated, so it cannot `await` an actor; a lock is the available primitive.
private final class EvaluationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GoalEvaluation?
    func set(_ v: GoalEvaluation) { lock.withLock { if value == nil { value = v } } }
    func get() -> GoalEvaluation? { lock.withLock { value } }
}

/// How a grade in flight is stopped from outside (#464). The grading turn runs in a task of its
/// own so a stop can cancel it without the caller's cancellation, and a stop that lands before the
/// task exists keeps it from starting.
private final class GradingControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var task: Task<Void, Never>?

    var isStopped: Bool { lock.withLock { stopped } }

    /// Starts the grading turn unless a stop got here first. The task is created under the lock,
    /// so a stop either sees it or prevents it.
    func start(_ make: () -> Task<Void, Never>) -> Task<Void, Never>? {
        lock.withLock {
            guard !stopped else { return nil }
            let t = make()
            task = t
            return t
        }
    }

    /// True for the first caller only.
    func stop() -> Task<Void, Never>?? {
        lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return .some(task)
        }
    }
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
    ///
    /// `recentWrites` is the graded run's self-write registry (#187 §4), threaded for the same
    /// reason `isBackground` is inherited a few lines below: a grader run for an unattended run is
    /// itself unattended, so anything it writes through a file tool is the run's own output, and
    /// one registry per process only holds if every engine is handed the same one.
    func evaluate(contract: GoalContract, workspace: String?, originatingConversationId originId: UUID,
                  app: AppState, client: any LLMClientProtocol = LLMClient(),
                  recentWrites: RecentWrites = .shared) async -> GoalEvaluation {

        // The directory the grader inspects. Callers resolve this to the main agent's effective
        // working directory (its bound workspace, or the process cwd it actually ran in), so the
        // grader never has to guess where the work is.
        let workspaceDir = Self.gradingDirectory(workspace, contract: contract)

        let evalId = UUID()
        // Fresh engine, evaluator principal. It never sees the working transcript. Built before
        // the registration below, which needs it to halt the loop.
        let checks = contract.criteria.compactMap { $0.kind == .executable ? $0.check : nil }
        let engine = IrisEngine(state: app, tier: .hard, principal: .evaluator, roleLabel: "evaluator", client: client, evaluatorChecks: checks, recentWrites: recentWrites)

        // Halt the loop first, as a subagent's stop does: after its first turn the grader's live
        // turn is a reprompt task, which cancelling the grading task does not reach.
        let control = GradingControl()
        let stop: @Sendable (String) -> Void = { _ in
            guard let task = control.stop() else { return }
            engine.haltGoalLoop(for: evalId)
            task?.cancel()
        }

        await MainActor.run {
            // Inherited from the work being graded: a grader run for an unattended run is itself
            // unattended, and must fail closed on anything gated rather than raise a dialog or
            // ask a local model (#187).
            let originIsBackground = app.conversations.first(where: { $0.id == originId })?.isBackground == true
            app.createNewConversation(id: evalId, isSubagent: true, isBackground: originIsBackground)
            if originIsBackground { app.linkBackgroundDescendant(evalId, of: originId) }
            app.linkDelegate(evalId, of: originId, kind: .evaluator)   // #418: its asks are the graded session's
            app.updateConversationTitle(id: evalId, title: "Evaluator")
            app.setWorkspace(for: evalId, path: workspaceDir)   // its run_command runs here
            app.registerSubagent(id: evalId, role: "evaluator", kind: .evaluator)
            // Stoppable like any delegate (#464): the run drain, a walk of the delegation tree on
            // a run's close or a parent's delete, and — grading a background subagent, which no
            // cancellation of the parent's tasks reaches — the parent's Stop. In the same job as
            // the link, so no stop can find the evaluator linked but not yet stoppable.
            app.registerLiveSubagent(evalId, parent: originId,
                                     background: app.isLiveBackgroundSubagent(originId),
                                     kind: .evaluator, stop: stop)
        }

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
        // In a task of its own, so a stop from the registry can cancel the model call in flight;
        // the caller's cancellation (a foreground parent's Stop) is forwarded to the same stop.
        let gradingTask = control.start {
            Task { await engine.processInput(evaluationPrompt, source: "GoalEvaluator", conversationId: evalId) }
        }
        if let gradingTask {
            await withTaskCancellationHandler {
                await gradingTask.value
            } onCancel: {
                stop(SubagentManager.cancelledReason)
            }
        }
        // Registered until its last turn has ended, not just until the caller has its answer: a
        // reprompt still unwinding is a turn still alive. Not awaited, as for a subagent.
        Task {
            await gradingTask?.value
            while engine.goalLoopIsLive(for: evalId) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await MainActor.run { app.unregisterLiveSubagent(evalId) }
        }

        // The grader submitted iff the callback ran and filled the box. A verdict that landed
        // before a stop is still a verdict.
        if let eval = graded.get() { return eval }

        // Stopped from outside before a verdict: say so, never as a grade (#464).
        if control.isStopped {
            let placeholders = GoalEvaluationParsing.verdicts(from: [:], criteria: contract.criteria,
                                                              judgements: contract.judgements)
            let stopped = GoalEvaluation(status: .stopped, criteria: placeholders, startedAt: Date(), completedAt: Date())
            await MainActor.run {
                app.recordEvaluation(for: originId, stopped)
                app.onEvaluationComplete[evalId] = nil
                app.finishSession(id: evalId, status: "stopped")
                app.deleteConversation(evalId)
            }
            return stopped
        }

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

    /// Where the grader runs: the conversation's bound workspace, or, with none bound, the process
    /// cwd its `run_command` inherits. One spelling, because the #334 pre-approval compares this
    /// directory with the one recorded when the human approved the contract.
    ///
    /// Given the contract, a directory that resolves to its `approvedWorkspace` is spelled as that
    /// (#359 review): the grader's reads are pre-approved by spelling, so a workspace reached
    /// through a symlinked prefix (`~/src` → `/Volumes/…`) would otherwise ask on every read. Same
    /// directory, the human's approved spelling; a workspace moved elsewhere since keeps its own.
    nonisolated static func gradingDirectory(_ workspacePath: String?, contract: GoalContract? = nil) -> String {
        let directory = workspacePath ?? FileManager.default.currentDirectoryPath
        if let approved = contract?.approvedWorkspace, IrisPaths.canonicalPath(directory) == approved {
            return approved
        }
        return directory
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
        s += "Your `run_command` calls already execute there. Confine your inspection to this directory — start by reading it with `read_file`, which lists a directory. NEVER search the wider filesystem (no `find /`, no reading files outside this directory, no `~root`/home snooping). If an expected artifact is not present here, the relevant criterion is `not_met` or `cannot_verify` — do not go hunting for it elsewhere.\n"
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
