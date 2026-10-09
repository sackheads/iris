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

/// Which Stop of the user's reached a subagent (#236): Stop, Esc or `/stop` in the conversation it
/// works under, or the Stop on its own session-strip row.
enum SubagentStopKind: Sendable, Equatable {
    case parent
    case row
}

final class SubagentManager: @unchecked Sendable {
    static let shared = SubagentManager()

    private init() {}

    /// The summary of a subagent stopped because the task waiting on it was cancelled (#323).
    static let cancelledReason = "Cancelled: the turn that delegated to this subagent was stopped (its run reached its deadline, or the user pressed Stop), so the subagent was stopped with it — its model call and any running command were cancelled, and it did not finish its task."

    /// The summary of a subagent stopped because the background run it worked for ended (#323).
    static let runEndedReason = "Cancelled: the background run this subagent worked for has ended, so the subagent was stopped — its model call and any running command were cancelled, and it did not finish its task."

    /// The summary of a subagent stopped by Stop, Esc or `/stop` in the conversation it works
    /// under (#236). Its post-back starts no turn: the user stopped everything there.
    static let parentStoppedReason = "Cancelled: the user stopped the conversation that delegated to this subagent, and this subagent with it — its model call and any running command were cancelled, and it did not finish its task."

    /// The summary of a subagent stopped from its own row in the session strip (#236). Only this
    /// helper was stopped, so its post-back is delivered as usual for the parent to re-plan.
    static let rowStoppedReason = "Cancelled: the user stopped this subagent from the session strip — its model call and any running command were cancelled, and it did not finish its task. The conversation that delegated to it was not stopped."

    /// Appended when a user Stop was accepted after `goal_complete` had already decided the result
    /// (#236): the status stays completed, but its last turn was cut short and it was not graded.
    static let stoppedAfterCompletionNote = "Note: the user stopped this subagent just after it called goal_complete, so its last turn was cut short and it was not graded."

    /// Whether a subagent has been stopped from outside; trips once.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false
        /// True for the first caller only.
        func trip() -> Bool { lock.withLock { defer { tripped = true }; return !tripped } }
        var isTripped: Bool { lock.withLock { tripped } }
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
    /// `appState` is injected rather than read from a global. It used to live in a weak
    /// process-wide property that `AppState.init` wrote to, so constructing an AppState anywhere —
    /// including in an unrelated test — swapped it, and letting one deallocate nilled it (#171).
    /// `recentWrites` is the parent run's self-write registry, threaded rather than defaulted at
    /// the engine: a subagent of an unattended run is unattended too, and its writes have to reach
    /// the same registry the watch coordinator consults, or a run that delegates its file writing
    /// escapes the filter (#187 §4).
    /// `endSandboxSession` frees the subagent's container on every way out, injected so a test can
    /// see it called without a container runtime (#291). The default closes the session for good,
    /// so an engine that ignored its cancellation cannot start another container (#292).
    /// `deadlineClock` is the wall clock the per-turn deadline below is set and watched on,
    /// injected only so a test can hold it off until the subagent is parked mid-turn, then move it
    /// (#355, following #335/#342): a real deadline raced a busy suite's MainActor work and
    /// sometimes let the run's own soft-stop classify as `.failed` first. The default is the same
    /// wall clock as before, so nothing changes outside tests.
    /// `turnTimeout` is how long one turn may run before the subagent ends `.timedOut` (#402),
    /// restarted whenever a turn begins. Nil, as at every production call site, reads `config`'s
    /// `subagentTurnTimeoutSeconds`; tests pass a short one. There is no total limit of its own:
    /// the cap times this bounds the subagent, and a background run's deadline cancels it sooner.
    /// `config` supplies the subagent's iteration cap (`maxSubagentIterations`, #399): the most
    /// turns its goal loop runs before it ends `failed` without `goal_complete`. Injected so a test
    /// sets it on a store of its own rather than on `ConfigManager.shared`.
    /// `hooks` is the subagent engine's hook manager, injected so a test can block one of its
    /// turns without a settings file in the shared home. `repromptDelay` is its goal loop's pause
    /// between turns, shortened only by tests.
    /// `onTurnEvent` sees each turn event after the deadline has recorded it, so a test can move
    /// `deadlineClock` at a known point (a turn's end) rather than after a real-time wait that a
    /// busy suite outlasts, landing the move inside the turn (#410). Nil in production; called
    /// outside `GoalLoopControl`'s lock (and after `SubagentTurnStart`'s), so a tap that calls back
    /// into the loop cannot deadlock.
    /// `background` is true for `invoke_subagent background: true`, whose caller is an unstructured
    /// task nothing cancels: the parent's Stop reaches it through the registry instead (#236).
    func runSubagent(role: String, task: String, effort: String, parentConversationId: UUID,
                     unit: DelegatedUnit? = nil, background: Bool = false, turnTimeout: TimeInterval? = nil,
                     client: (any LLMClientProtocol)? = nil,
                     appState: AppState,
                     recentWrites: RecentWrites = .shared,
                     deadlineClock: @escaping @Sendable () -> Date = Date.init,
                     config: ConfigManager = .shared,
                     hooks: HookManager = .shared,
                     repromptDelay: TimeInterval = 1.5,
                     onTurnEvent: (@Sendable (_ began: Bool, _ seq: Int) -> Void)? = nil,
                     endSandboxSession: @escaping @Sendable (UUID) async -> Void = {
                         await SandboxSessionManager.shared.closeSession($0)
                     }) async -> (rendered: String, status: SubagentTerminalStatus, stoppedBy: SubagentStopKind?) {
        let startedAt = Date()

        // 1. Create a new conversation for the subagent
        let subagentId = UUID()
        await MainActor.run {
            // Fail-closed is inherited (#187). A subagent of an unattended run is created
            // foreground-by-default no longer: that made delegation a way around the gate, since a
            // foreground conversation falls through to auto-approval, Vibecop, or a modal dialog
            // nobody is there to answer. Its denials are drained with the parent run.
            let parentIsBackground = appState.conversations
                .first(where: { $0.id == parentConversationId })?.isBackground == true
            appState.createNewConversation(id: subagentId, isSubagent: true, isBackground: parentIsBackground)
            if parentIsBackground { appState.linkBackgroundDescendant(subagentId, of: parentConversationId) }
            appState.linkDelegate(subagentId, of: parentConversationId)   // #418: its asks are the parent's
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
            // A granted run's delegate works under the same grant, never wider (#282 §2): the same
            // mounts, the same network, the same host-write boundary.
            if let parentGrant = appState.conversations.first(where: { $0.id == parentConversationId })?.sandboxGrant {
                appState.setSandboxGrant(for: subagentId, parentGrant)
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
                                client: client ?? LLMClient(), recentWrites: recentWrites,
                                hooks: hooks, subagentConfig: config, repromptDelay: repromptDelay)

        // 3. Craft the role-specific prompt
        let iterationCap = max(1, config.maxSubagentIterations)
        let perTurn = max(1, turnTimeout ?? Double(config.subagentTurnTimeoutSeconds))
        let customPromptText = generateRolePrompt(role: role, iterationCap: iterationCap, turnTimeout: perTurn)
        await engine.setSystemPrompt(text: customPromptText)
        await engine.setGoalIterationCap(iterationCap, for: subagentId)

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

        // Lock-based, not an actor, so a termination can be recorded synchronously — from a
        // cancellation handler (#323), and from `onSubagentComplete` without the detached Task an
        // actor hop needed. First write wins, as before.
        final class ResultHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var termination: SubagentTermination? = nil
            func set(_ t: SubagentTermination) { lock.withLock { if termination == nil { termination = t } } }
            func get() -> SubagentTermination? { lock.withLock { termination } }
        }
        let holder = ResultHolder()

        await MainActor.run {
            appState.onSubagentComplete[subagentId] = { termination in
                holder.set(termination)
                Task { @MainActor in appState.onSubagentComplete[subagentId] = nil }
            }
        }

        // Tracks the first turn returning. On its own that is NOT the loop's end (#399): a turn that
        // ends without goal_complete schedules the next one as a reprompt task of its own, 1.5 s
        // later, and the poll below waits for `goalLoopIsLive` too. Together they catch a loop
        // that ended without firing `onSubagentComplete` — a hook-blocked turn, a reprompt that
        // found its goal gone — which would otherwise spin to the turn deadline (15 minutes, by
        // default), stalling the parent that is awaiting the result.
        actor EngineDone {
            var finished = false
            func set() { finished = true }
            func get() -> Bool { finished }
        }
        let engineDone = EngineDone()

        // Per turn, on the wall clock (`deadlineClock`), not a poll count: a count of 100ms sleeps
        // still measures *polls*, not time, when the clock behind it is injected and can be held
        // still or jumped — see the parameter doc above. Each turn stamps its own start as it
        // begins and clears it as it ends (#402), so the deadline restarts on every reprompt, from
        // the turn's real start, and only a turn in flight is held to it: the reprompt pause and
        // the grace polls after the loop's end never count, and never turn a `.failed` into a
        // `.timedOut`. Seeded with now, so turn 1 is covered before its own stamp lands.
        let turnStart = SubagentTurnStart(deadlineClock())
        engine.observeGoalLoopTurns(for: subagentId) { began, seq in
            turnStart.record(began: began, seq: seq, at: deadlineClock())
            onTurnEvent?(began, seq)
        }

        let engineTask = Task {
            // The first turn. Since activeGoal is set, the engine reprompts itself after each turn
            // until goal_complete, the iteration cap, or a stop; those turns run in its own tasks.
            await engine.processInput(task, source: "System", conversationId: subagentId)
            await engineDone.set()
        }

        // How this subagent is stopped from outside (#323): by the cancellation of the task that is
        // waiting on it — a run's turn cancelled at its deadline, or the user's Stop — by the
        // drain of the run it works for, or by the user stopping it directly, which is the only
        // way to reach a background subagent (#236). The verdict is recorded before the engine is cancelled,
        // for the reason the timeout below classifies first: the cancelled engine reports a
        // `.failed` of its own, and that must not be the one that lands.
        let stopped = StopFlag()
        // After the first turn the live turn runs in the engine's reprompt task, which cancelling
        // `engineTask` does not reach, so the loop is halted too: halting forbids any further
        // reprompt before it cancels the pending one, so a turn unwinding cannot schedule another.
        let stop: @Sendable (String) -> Void = { reason in
            guard stopped.trip() else { return }
            holder.set(SubagentTermination(status: .cancelled, summary: reason, calledGoalComplete: false))
            engine.haltGoalLoop(for: subagentId)
            engineTask.cancel()
        }
        await MainActor.run {
            appState.registerLiveSubagent(subagentId, parent: parentConversationId, background: background, stop: stop)
        }

        var gracePolls = 0
        var timedOut = false
        await withTaskCancellationHandler {
            while holder.get() == nil {
                // Cancelled before the handler was installed: it never fires for that, so look.
                if Task.isCancelled { stop(Self.cancelledReason); break }
                // The engine loop is over: the first turn returned and no turn or reprompt is
                // left. Allow a few polls for a termination still on its way before concluding
                // nothing is coming.
                if await engineDone.get(), !engine.goalLoopIsLive(for: subagentId) {
                    gracePolls += 1
                    if gracePolls > 3 {
                        holder.set(SubagentTermination(status: .failed,
                            summary: "Subagent stopped without calling goal_complete — the unit was not completed.",
                            calledGoalComplete: false))
                        break
                    }
                }
                if let start = turnStart.start, deadlineClock() >= start.addingTimeInterval(perTurn) {
                    // Classify BEFORE `engineTask.cancel()`, not after: cancelling it can itself
                    // unwind the engine's in-flight model call, which hits `processInput`'s own
                    // catch block and fires `onSubagentComplete` with `.failed` — a second write to
                    // this same `holder`, which would otherwise misreport a timeout (#355).
                    holder.set(SubagentTermination(status: .timedOut,
                        summary: "Subagent timed out: one of its turns ran past the per-turn limit (\(Self.describe(seconds: perTurn))) and was cancelled (task, pending approvals, and sandbox container cleaned up).",
                        calledGoalComplete: false))
                    // Halt, then cancel, as `stop` does: from turn 2 on the live turn is the
                    // reprompt task, which `engineTask.cancel()` below does not reach, and it must
                    // not keep running through the MainActor hop that follows.
                    engine.haltGoalLoop(for: subagentId)
                    timedOut = true
                    break
                }
                // A poll interval, not a deadline: a cancelled sleep returns at once and the loop
                // sees the termination the cancellation handler recorded.
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        } onCancel: {
            stop(Self.cancelledReason)
        }
        let termination = holder.get() ?? SubagentTermination(status: .failed, summary: "Subagent completed with no summary.", calledGoalComplete: false)
        // Decided: a later Stop from the user must not cut a completed subagent's last turn short.
        // Read the flag only after settling: a Stop accepted between the two would otherwise trip
        // it unseen, and the result would lose its stopped-after-completion note (#236).
        await MainActor.run {
            appState.beforeSubagentSettle?(subagentId)
            appState.settleLiveSubagent(subagentId)
        }
        let wasStopped = stopped.isTripped

        // Hard stop for a subagent ended from outside: cancel the engine task (already done by
        // `stop`, harmless twice) and unstick any pending approval.
        if timedOut || wasStopped {
            engineTask.cancel()
            await MainActor.run { appState.denyPendingApprovals(for: subagentId) }
        }
        // Stop the loop on every way out — a reprompt in flight is a task of its own that cancelling
        // `engineTask` does not reach — and clear the goal of anything that did not complete. A
        // completed loop is only forbidden further turns: its last turn is still writing results.
        engine.haltGoalLoop(for: subagentId, cancelling: termination.status != .completed)
        if termination.status != .completed {
            await MainActor.run { appState.clearGoal(for: subagentId) }
        }
        // Every path frees the container, a completed one too (#291): it held the run's grant
        // mounts until the idle reaper. Out of reach of this task's cancellation, which would
        // otherwise refuse to launch the `container delete` at exactly the moment it is needed.
        await Task { await endSandboxSession(subagentId) }.value

        let files = await MainActor.run { appState.drainSubagentWrites(for: subagentId) }

        // Grade the unit. ONLY a `.completed` run is graded: it is the one that claimed the unit is
        // done. A failed/timed-out/cancelled subagent claimed nothing, so its status carries the
        // story and `verdict` stays nil rather than reporting a grade against unfinished work.
        // Awaited, not detached (unlike the main agent's goal_complete): the parent must receive the
        // verdict IN the result it branches on. Not when the caller has been cancelled: nobody is
        // waiting for the verdict, and an evaluator started now would outlive the run (#323).
        var verdict: GoalEvaluation? = nil
        if termination.status == .completed, let unit, unit.grade, !Task.isCancelled, !wasStopped {
            // The directory the subagent actually worked in. With no bound workspace its
            // run_command inherits the process cwd, so the grader is pointed at the same place.
            let workspace = GoalEvaluator.gradingDirectory(await MainActor.run {
                appState.conversations.first { $0.id == subagentId }?.workspacePath
            })
            verdict = await GoalEvaluator.shared.evaluate(contract: unit.contract, workspace: workspace,
                                                          originatingConversationId: subagentId,
                                                          app: appState, client: client ?? LLMClient(),
                                                          recentWrites: recentWrites)
        }

        let result = SubagentResult(role: role, status: termination.status,
                                    calledGoalComplete: termination.calledGoalComplete,
                                    summary: termination.summary, filesWritten: files,
                                    startedAt: startedAt, endedAt: Date(),
                                    unitContract: unitContract, verdict: verdict)
        // Read while still registered: the background post-back is routed on it, not on the
        // status, which a completion can win over an accepted Stop (#236).
        let stoppedBy = await MainActor.run {
            appState.setSubagentResult(for: subagentId, result)
            appState.finishSession(id: subagentId, status: termination.status.rawValue)
            return appState.subagentStopRequest(subagentId)
        }
        // Registered until the engine task has actually returned, not just until the parent has
        // its answer: a task still unwinding is a task still alive. Not awaited here, so an engine
        // parked where cancellation cannot reach does not hold the parent too.
        // And until the loop's last turn has, too: after the first turn, that is a reprompt task.
        Task {
            await engineTask.value
            while engine.goalLoopIsLive(for: subagentId) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            engine.observeGoalLoopTurns(for: subagentId, nil)
            await MainActor.run { appState.unregisterLiveSubagent(subagentId) }
        }
        var rendered = result.renderedForParent()
        if wasStopped, termination.status != .cancelled, stoppedBy != nil {
            rendered += "\n" + Self.stoppedAfterCompletionNote
        }
        return (rendered, termination.status, stoppedBy)
    }
    
    /// "15 min" for whole minutes, "90 s" otherwise.
    static func describe(seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 && s % 60 == 0 ? "\(s / 60) min" : "\(s) s"
    }

    /// The `invoke_subagent` tool schema. Declared beside the manager it drives so the contract
    /// input (slice B3) is unit-testable without standing up an engine.
    static func toolDeclaration() -> FunctionDeclaration {
        FunctionDeclaration(
            name: "invoke_subagent",
            description: "Spawn an isolated subagent with a constrained persona to execute a task. The subagent works in a loop, reprompted after each turn until it calls goal_complete or reaches its iteration cap (a capped subagent comes back failed); each of its turns is a full model round, with a time limit of its own that restarts every turn (a turn past it comes back timed out). By default, this blocks until the subagent completes. Set 'background' to true to run it asynchronously and receive a notification when it finishes (not in a background job run, where it is refused). Criteria are optional; when you provide them, the run is graded by an independent evaluator and the verdict is returned to you alongside the subagent's own (unverified) summary.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "role": Schema(type: "STRING", description: "The persona (e.g., code_reviewer, security_auditor, researcher, engineer)"),
                    "task": Schema(type: "STRING", description: "The exact task prompt for the subagent"),
                    "effort": Schema(type: "STRING", description: "The reasoning effort required. 'easy' for simple/repetitive lookups, 'medium' for standard tasks, 'hard' for complex problem solving."),
                    "background": Schema(type: "BOOLEAN", description: "Optional. If true, returns immediately while the subagent runs in the background. The system will notify you with the results when done, unless the user stops this conversation, which stops the subagent too and leaves its result only in the transcript. Refused in a background job run, where delegation must block."),
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
            description: "Hand the CURRENT checkpoint's milestone to a bounded subagent that works it in its own context, in a loop of turns up to its iteration cap, each turn under a time limit that restarts every turn. Its definition of done is taken from the locked ladder — you do not restate it. When the subagent finishes the milestone, the checkpoint is reached and graded automatically: a clean grade advances the ladder on its own, anything contested pauses for the user. Use reach_checkpoint instead when you did the work yourself.",
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

    func generateRolePrompt(role: String, iterationCap: Int = ConfigManager.shared.maxSubagentIterations,
                            turnTimeout: TimeInterval = Double(ConfigManager.shared.subagentTurnTimeoutSeconds)) -> String {
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
        
        return base + specific + "\n\nYou work in a loop: after each turn in which you have not called `goal_complete`, you are prompted to continue, for at most \(iterationCap) turn\(iterationCap == 1 ? "" : "s") in all. Reaching that cap without `goal_complete` ends your task as failed. Each turn may run for at most \(Self.describe(seconds: turnTimeout)), its tool calls included; a turn that runs longer is cancelled and ends your task as timed out, so split long work across turns. When you are finished, you MUST call the `goal_complete` tool with a summary of your findings to return control to the parent agent."
    }
}
