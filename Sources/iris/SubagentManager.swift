import Foundation

/// A bounded unit of work handed to a subagent: the contract it runs against, and whether that
/// contract is independently graded when the run completes.
///
/// `grade: false` binds the contract as an oracle only — the subagent knows its definition of done
/// while working, and `SubagentResult.verdict` stays nil. Slice B4 delegates a ladder milestone
/// this way, because the CHECKPOINT grades it cumulatively and a second grade of the same criteria
/// would be redundant work.
struct DelegatedUnit: Sendable {
    var contract: GoalContract
    var grade: Bool = true
}

final class SubagentManager: @unchecked Sendable {
    static let shared = SubagentManager()
    
    private let lock = NSLock()
    private weak var _state: AppState?
    
    var state: AppState? {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    
    private init() {}
    
    func setGlobalState(_ state: AppState) {
        self.state = state
    }
    
    /// Runs a delegated unit to termination, returning the prose the parent sees and how the run
    /// ended. Callers that only render take `.rendered`; slice B4 branches on `.status`, because
    /// only a `.completed` run may reach a checkpoint.
    ///
    /// Slice B3: when the parent supplies a `unit`, its contract is bound LOCKED to this run — the
    /// subagent works against slice A's oracle — and on a `.completed` termination the slice-C
    /// evaluator grades it from fresh context, unless the unit asked not to be graded (slice B4,
    /// where the checkpoint grades the same criteria cumulatively). With no unit this is the
    /// unchanged B2 path: a plain goal, no contract, no grade. `client` is injectable so tests can
    /// drive both the subagent and its grader without touching the network.
    func runSubagent(role: String, task: String, effort: String, parentConversationId: UUID,
                     unit: DelegatedUnit? = nil, maxIterations: Int = 3000,
                     client: (any LLMClientProtocol)? = nil) async -> (rendered: String, status: SubagentTerminalStatus) {
        guard let appState = self.state else {
            return ("Error: AppState not available for subagent execution.", .failed)
        }

        let startedAt = Date()

        // 1. Create a new conversation for the subagent
        let subagentId = UUID()
        await MainActor.run {
            appState.createNewConversation(id: subagentId, isSubagent: true)
            appState.updateConversationTitle(id: subagentId, title: "Subagent: \(role)")
            appState.registerSubagent(id: subagentId, role: role)
            // Delegation must not drop the workspace the parent is bound to. Without this the
            // subagent's run_command inherits the process cwd (the Iris repo) while the parent
            // works somewhere else — and a unit contract's executable `check` would then be graded
            // against the wrong tree, reporting `met` on evidence unrelated to the delegated work.
            // With no bound parent workspace this is a no-op and both sides stay on the cwd (#68).
            if let parentWorkspace = appState.conversations.first(where: { $0.id == parentConversationId })?.workspacePath {
                appState.setWorkspace(for: subagentId, path: parentWorkspace)
            }
        }

        let tier: ModelTier
        switch effort.lowercased() {
        case "easy": tier = .easy
        case "hard": tier = .hard
        default: tier = .medium
        }

        // 2. Instantiate a fresh IrisEngine linked to this conversation
        let engine = IrisEngine(state: appState, tier: tier, principal: .subagent, roleLabel: role,
                                client: client ?? LLMClient())

        // 3. Craft the role-specific prompt
        let customPromptText = generateRolePrompt(role: role)
        await engine.setSystemPrompt(text: customPromptText)

        // 4. Inject the initial task and set the goal so the engine auto-loops.
        // With a unit contract the objective IS the task, so the loop gate (activeGoal != nil) is
        // satisfied either way; the contract additionally injects slice A's oracle each iteration.
        let unitContract = unit?.contract
        await MainActor.run {
            if let unitContract {
                appState.setGoalContract(for: subagentId, unitContract)
            } else {
                appState.setGoal(for: subagentId, goal: task)
            }
            appState.appendMessage(role: .system, content: "Starting subagent with role '\(role)' to execute task:\n\(task)", to: subagentId)
        }

        actor ResultHolder {
            var termination: SubagentTermination? = nil
            func set(_ t: SubagentTermination) { if termination == nil { termination = t } }
            func get() -> SubagentTermination? { return termination }
        }
        let holder = ResultHolder()

        await MainActor.run {
            appState.onSubagentComplete[subagentId] = { termination in
                Task { await holder.set(termination) }
                Task { @MainActor in appState.onSubagentComplete[subagentId] = nil }
            }
        }

        // Tracks the engine loop ending. A subagent that stops WITHOUT calling goal_complete — its
        // own goal loop soft-stopped on the iteration cap, the model just replied with text, the
        // turn threw — never fires `onSubagentComplete`. Without this the poll below would spin to
        // `maxIterations` (3000 × 100ms = five minutes) waiting for a termination that can no
        // longer arrive, stalling the parent that is awaiting the result.
        actor EngineDone {
            var finished = false
            func set() { finished = true }
            func get() -> Bool { finished }
        }
        let engineDone = EngineDone()

        let engineTask = Task {
            // Kick off the first turn. Since activeGoal is set, the engine will autonomously reprompt itself
            // in a loop until goal_complete is called.
            await engine.processInput(task, source: "System", conversationId: subagentId)
            await engineDone.set()
        }

        var iterations = 0
        var gracePolls = 0
        while await holder.get() == nil {
            // The engine loop is over. `goal_complete` resolves the holder from a detached Task, so
            // allow a few polls for that to land before concluding nothing is coming.
            if await engineDone.get() {
                gracePolls += 1
                if gracePolls > 3 {
                    await engine.cancelReprompt(for: subagentId)
                    await SandboxSessionManager.shared.endSession(subagentId)
                    await MainActor.run { appState.clearGoal(for: subagentId) }
                    await holder.set(SubagentTermination(status: .failed,
                        summary: "Subagent stopped without calling goal_complete — the unit was not completed.",
                        calledGoalComplete: false))
                    break
                }
            }
            if iterations >= maxIterations {
                // Hard stop: cancel the engine task, unstick any pending approval, stop the
                // reprompt loop, free the sandbox container, and clear the goal.
                engineTask.cancel()
                await MainActor.run { appState.denyPendingApprovals(for: subagentId) }
                await engine.cancelReprompt(for: subagentId)
                await SandboxSessionManager.shared.endSession(subagentId)
                await MainActor.run { appState.clearGoal(for: subagentId) }
                await holder.set(SubagentTermination(status: .timedOut,
                    summary: "Subagent timed out after the iteration cap and was cancelled (task, pending approvals, and sandbox container cleaned up).",
                    calledGoalComplete: false))
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            iterations += 1
        }
        let termination = await holder.get() ?? SubagentTermination(status: .failed, summary: "Subagent completed with no summary.", calledGoalComplete: false)
        let files = await MainActor.run { appState.drainSubagentWrites(for: subagentId) }

        // Grade the unit. ONLY a `.completed` run is graded: it is the one that claimed the unit is
        // done. A failed/timed-out/cancelled subagent claimed nothing, so its status carries the
        // story and `verdict` stays nil rather than reporting a grade against unfinished work.
        // Awaited, not detached (unlike the main agent's goal_complete): the parent must receive the
        // verdict IN the result it branches on.
        var verdict: GoalEvaluation? = nil
        if termination.status == .completed, let unit, unit.grade {
            // The directory the subagent actually worked in. With no bound workspace its
            // run_command inherits the process cwd, so the grader is pointed at the same place.
            let workspace = await MainActor.run {
                appState.conversations.first { $0.id == subagentId }?.workspacePath
            } ?? FileManager.default.currentDirectoryPath
            verdict = await GoalEvaluator.shared.evaluate(contract: unit.contract, workspace: workspace,
                                                          originatingConversationId: subagentId,
                                                          app: appState, client: client ?? LLMClient())
        }

        let result = SubagentResult(role: role, status: termination.status,
                                    calledGoalComplete: termination.calledGoalComplete,
                                    summary: termination.summary, filesWritten: files,
                                    startedAt: startedAt, endedAt: Date(),
                                    unitContract: unitContract, verdict: verdict)
        await MainActor.run {
            appState.setSubagentResult(for: subagentId, result)
            appState.removeSubagent(id: subagentId)
        }
        return (result.renderedForParent(), termination.status)
    }
    
    /// The `invoke_subagent` tool schema. Declared beside the manager it drives so the contract
    /// input (slice B3) is unit-testable without standing up an engine.
    static func toolDeclaration() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "invoke_subagent",
            description: "Spawn an isolated subagent with a constrained persona to execute a task. By default, this blocks until the subagent completes. Set 'background' to true to run it asynchronously and receive a notification when it finishes. Criteria are optional; when you provide them, the run is graded by an independent evaluator and the verdict is returned to you alongside the subagent's own (unverified) summary.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "role": Schema(type: "STRING", description: "The persona (e.g., code_reviewer, security_auditor, researcher, engineer)"),
                    "task": Schema(type: "STRING", description: "The exact task prompt for the subagent"),
                    "effort": Schema(type: "STRING", description: "The reasoning effort required. 'easy' for simple/repetitive lookups, 'medium' for standard tasks, 'hard' for complex problem solving."),
                    "background": Schema(type: "BOOLEAN", description: "Optional. If true, returns immediately while the subagent runs in the background. The system will notify you with the results when done."),
                    "criteria": Schema(type: "ARRAY", description: "Optional definition of done for this delegated unit. When present, the subagent runs against these criteria and an independent grader verifies them, returning a trusted verdict. You author them — the subagent does not negotiate them.", items: Schema(type: "OBJECT", properties: [
                        "text": Schema(type: "STRING", description: "The criterion — what 'done' looks like for this unit."),
                        "kind": Schema(type: "STRING", description: "executable | qualitative | humanJudged"),
                        "check": Schema(type: "STRING", description: "A runnable command/test the grader re-runs. ONLY for executable criteria.")
                    ], required: ["text"]))
                ],
                required: ["role", "task", "effort"]
            )
        )
    }

    /// The `delegate_milestone` tool schema (slice B4). Note the absence of a `criteria` parameter:
    /// a delegated milestone's definition of done comes from the locked ladder, so the model cannot
    /// restate the gate it is about to be measured by.
    static func milestoneDelegationDeclaration() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "delegate_milestone",
            description: "Hand the CURRENT checkpoint's milestone to a bounded subagent that works it in its own context. Its definition of done is taken from the locked ladder — you do not restate it. When the subagent finishes the milestone, the checkpoint is reached and graded automatically and the run pauses for the user. Use reach_checkpoint instead when you did the work yourself.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "role": Schema(type: "STRING", description: "The persona (e.g. engineer, researcher, code_reviewer)."),
                    "effort": Schema(type: "STRING", description: "The reasoning effort required: easy | medium | hard."),
                    "brief": Schema(type: "STRING", description: "Optional. How to approach the work — context, starting points, gotchas. NEVER criteria: those come from the ladder.")
                ],
                required: ["role", "effort"]
            )
        )
    }

    func generateRolePrompt(role: String) -> String {
        let base = "You are Iris, operating in a specialized subagent role: **\(role.uppercased())**.\n" +
                   "You are executing within a fully configurable sandboxed micro-VM. You have full root permissions inside this VM environment to install packages, configure tools, and run commands needed to complete your objective.\n\n"
        var specific = ""
        
        switch role.lowercased() {
        case "code_reviewer":
            specific = "Your goal is to review code. Look for bugs, architectural flaws, and style issues. Do not write new features. Be critical and precise."
        case "security_auditor":
            specific = "Your goal is to audit code for security vulnerabilities. Look for prompt injections, path traversals, XSS, and weak cryptography."
        case "researcher":
            specific = "Your goal is to gather context. Use search_web and read_file heavily. Summarize your findings accurately. Do not mutate any files."
        case "engineer":
            specific = "Your goal is to implement a specific component using TDD. Write failing tests first, then implement. Do not modify unrelated code."
        default:
            specific = "Your goal is to execute the assigned task efficiently and autonomously."
        }
        
        return base + specific + "\n\nWhen you are finished, you MUST call the `goal_complete` tool with a summary of your findings to return control to the parent agent."
    }
}
