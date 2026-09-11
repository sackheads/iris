import Foundation
import SwiftUI
import KeyboardShortcuts

actor IrisEngine {
    let client: any LLMClientProtocol
    let executor = ToolExecutor.shared
    let manager = SkillManager.shared

    var systemPrompt: Content!
    var modelTier: ModelTier
    let principal: Principal
    let roleLabel: String?
    let evaluatorChecks: [String]

    /// Conversations already shown the "no sandbox runtime" fallback notice (deduped).
    private var warnedNoRuntime: Set<UUID> = []

    // We need to keep a weak reference to the state or pass it in.
    // Since AppState owns IrisEngine, we can pass it when we start or process.
    private weak var state: AppState?

    init(state: AppState, tier: ModelTier = .medium, principal: Principal = .main, roleLabel: String? = nil, client: any LLMClientProtocol = LLMClient(), evaluatorChecks: [String] = []) {
        self.state = state
        self.modelTier = tier
        self.principal = principal
        self.roleLabel = roleLabel
        self.client = client
        self.evaluatorChecks = evaluatorChecks
        systemPrompt = nil
    }

    func invalidateSystemPrompt() {
        systemPrompt = nil
    }
    
    @discardableResult
    private func ensureSystemPrompt() async -> Content {
        if let existing = systemPrompt { return existing }
        return await measure(.contextAssembly) {
            let soul = await manager.loadSOUL()
            let activeBundle = SkillBundleManager.shared.activeBundle
            let skills = await manager.discoverSkills(activeBundle: activeBundle)
            let steering = SystemSteering.shipped()
            let customRules = await manager.loadCustomRules()
            let combined = "\(soul)\n\n\(skills)\n\n\(steering)\(customRules)"
            let prompt = Content(role: "system", parts: [Part(text: combined, functionCall: nil, functionResponse: nil)])
            systemPrompt = prompt
            return prompt
        }
    }
    
    func setSystemPrompt(text: String) {
        systemPrompt = Content(role: "system", parts: [Part(text: text, functionCall: nil, functionResponse: nil)])
    }
    
    func handleSystemEvent(_ message: String, source: String, conversationId: UUID? = nil) async {
        let localState = state
        let targetId = await MainActor.run { conversationId ?? localState?.selectedConversationId }
        guard let activeId = targetId else { return }
        
        // Sanitize incoming system events (especially those from subagents) to prevent injection
        let structuralSafeEvent = PromptInjectionGuard.sanitizeUntrustedInput(message)
        let safeMessage = await InjectionGuard.sanitize(structuralSafeEvent, contextTag: "system_event_\(source)", maxTier: .tier3_canary)
        
        await MainActor.run {
            localState?.appendMessage(role: .system, content: safeMessage, to: activeId)
        }
        await processInput(safeMessage, source: source, conversationId: activeId)
    }
    
    func start() async {
        ScheduleManager.shared.onJobFired = { [weak self] prompt, convId in
            await self?.handleSystemEvent("Scheduled Job Triggered: \(prompt)", source: "Scheduler", conversationId: convId)
        }
        ScheduleManager.shared.start()
        
        await PluginManager.shared.loadAll()
        let pluginConfigs = await PluginManager.shared.mcpConfigs()
        await MCPManager.shared.setPluginConfigs(pluginConfigs)
        await MCPManager.shared.startServers()
        await WatcherManager.shared.setCallback { [weak self] message, source in
            guard let self = self else { return }
            await self.handleSystemEvent(message, source: source)
        }
        
        await WatcherManager.shared.startAll()

        // Check whether Ollama is reachable when any auxiliary engine depends on it.
        // A silent failure here means Vibecop / PromptGuard timeouts with no user-visible cause.
        let config = ConfigManager.shared
        let needsOllama = (config.enableVibecop && config.vibecopEngine == "ollama")
                       || (config.enableAdvancedPromptInjectionProtection && config.promptGuardEngine == "ollama")

        if needsOllama {
            let reachable = await OllamaEngine.isDaemonReachable()
            if !reachable {
                let localState = state
                let localConversationId = await MainActor.run { localState?.selectedConversationId }
                if let convId = localConversationId {
                    var services: [String] = []
                    if config.enableVibecop, config.vibecopEngine == "ollama" { services.append("Vibecop Guardian") }
                    if config.enableAdvancedPromptInjectionProtection, config.promptGuardEngine == "ollama" { services.append("Prompt Guard") }
                    let serviceList = services.joined(separator: " and ")
                    await pushToUI(role: .system, text: "⚠️ \(serviceList) are configured to use Ollama, but the Ollama daemon is not reachable at http://localhost:11434. Start the Ollama server (`ollama serve`) or switch to a different engine in Settings.", conversationId: convId)
                } else {
                    print("[Iris] Ollama daemon unreachable — Vibecop/PromptGuard will silently fail.")
                }
            }
        }

        // Resume an in-flight goal that was interrupted by an app restart/crash.
        // The goal state (activeGoal, goalContract, history) persists; we re-kick
        // the reprompt loop so the agent picks up where it left off.
        let localState = state
        let localConversationId = await MainActor.run { localState?.selectedConversationId }
        if let convId = localConversationId {
            let shouldResume = await MainActor.run { () -> Bool in
                guard let conv = localState?.conversations.first(where: { $0.id == convId }),
                      conv.activeGoal != nil,
                      conv.goalContract?.isLocked == true,
                      conv.goalContract?.checkpointStatus != .pausedForReview,
                      conv.goalIterationCount < ConfigManager.shared.maxGoalIterations
                else { return false }
                return true
            }
            if shouldResume {
                let objective = await MainActor.run {
                    localState?.conversations.first(where: { $0.id == convId })?.goalContract?.objective
                        ?? localState?.conversations.first(where: { $0.id == convId })?.activeGoal
                        ?? "your goal"
                }
                await pushToUI(role: .system, text: "Goal was interrupted by restart. Resuming: \(objective)", conversationId: convId)

                // Brief delay to let the UI render the message, then re-kick the loop.
                repromptTasks[convId] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    let stillActive = await MainActor.run {
                        localState?.conversations.first(where: { $0.id == convId })?.activeGoal != nil
                    }
                    guard stillActive else { return }
                    let contract = await MainActor.run {
                        localState?.conversations.first(where: { $0.id == convId })?.goalContract
                    }
                    let oracle = contract?.oracleText() ?? ""
                    let closing: String
                    if let c = contract, c.hasLadder, !c.isFinalMilestone {
                        closing = "When the current checkpoint's criteria are satisfied, call `reach_checkpoint` (NOT goal_complete)."
                    } else {
                        closing = "If every criterion is satisfied, call goal_complete."
                    }
                    let reprompt = oracle.isEmpty
                        ? "Continue working on your goal. What is your next step? \(closing)"
                        : "\(oracle)\n\nContinue working toward the objective above. What is your next step? \(closing)"
                    await self.processInput(reprompt, source: "System", conversationId: convId)
                }
            }
        }
    }
    
    /// Tracks the pending auto-reprompt task per conversation so the goal loop can be cancelled.
    private var repromptTasks: [UUID: Task<Void, Never>] = [:]

    /// Per-conversation loop detectors (reset on a fresh UI turn).
    private var loopDetectors: [UUID: LoopDetector] = [:]

    /// Cancels a conversation's pending auto-reprompt, stopping its goal loop.
    func cancelReprompt(for conversationId: UUID) {
        repromptTasks[conversationId]?.cancel()
        repromptTasks[conversationId] = nil
    }

    /// Graceful stop for a responsive-but-stuck goal loop: clear the reprompt, instruct the model
    /// to summarize and call goal_complete, and clear the goal so the loop cannot continue.
    private func softStopWithSummary(conversationId: UUID, reason: String) async {
        cancelReprompt(for: conversationId)
        loopDetectors[conversationId] = nil
        let localState = state
        // Clear the goal FIRST so the summary turn cannot re-enter the cap/loop-detection paths
        // (both gated on activeGoal != nil) and recurse into softStopWithSummary.
        await MainActor.run { localState?.clearGoal(for: conversationId) }
        await pushToUI(role: .system, text: "[\(approvalOrigin)] \(reason) Summarizing and stopping.", conversationId: conversationId)
        await processInput(
            "You have reached a stopping condition (\(reason)). Summarize what you accomplished and what is blocking you, then call `goal_complete` with that summary. Do not take any other action.",
            source: "System", conversationId: conversationId, restrictToGoalComplete: true)
        // If the summary turn didn't deliver a result via goal_complete, fire the fallback.
        // (The goal_complete handler nils out the callback after firing, so a non-nil callback
        // here means no summary was delivered.)
        await MainActor.run {
            if localState?.onSubagentComplete[conversationId] != nil {
                localState?.onSubagentComplete[conversationId]?(SubagentTermination(status: .cancelled, summary: "Stopped: \(reason) (no explicit summary produced).", calledGoalComplete: false))
                localState?.onSubagentComplete[conversationId] = nil
            }
        }
    }

    private var approvalOrigin: String {
        switch principal {
        case .main: return "Main agent"
        case .subagent: return "Subagent (\(roleLabel ?? "subagent"))"
        case .evaluator: return "Evaluator"
        }
    }

    /// The principal-based sandbox decision for this conversation (no side effects). Shared by
    /// run_command routing and command-hook routing so both honor the same dual-layer policy.
    private func sandboxDecision(conversationId: UUID, workspacePath: String?) async -> SandboxDecision {
        let localState = state
        let perConv = await MainActor.run {
            localState?.conversations.first(where: { $0.id == conversationId })?.mainAgentSandbox
        }
        return SandboxPolicy.resolve(
            masterEnabled: ConfigManager.shared.enableSandboxing,
            principal: principal,
            perConversation: perConv,
            perWorkspace: SandboxPolicy.perWorkspaceOverride(workspace: workspacePath),
            globalDefault: ConfigManager.shared.mainAgentSandboxDefault,
            runtimeAvailable: SandboxingManager.shared.isContainerInstalled)
    }

    private func resolveUseSandbox(toolName: String, conversationId: UUID, workspacePath: String?) async -> Bool {
        guard toolName == "run_command" else { return false }
        let decision = await sandboxDecision(conversationId: conversationId, workspacePath: workspacePath)
        switch decision {
        case .sandboxed:
            return true
        case .host(let warn):
            if warn, !warnedNoRuntime.contains(conversationId) {
                warnedNoRuntime.insert(conversationId)
                await pushToUI(role: .system,
                               text: "[sandbox] No container runtime available — running on the host WITHOUT isolation. Install it in Iris Settings → Sandboxing to enable sandboxing.",
                               conversationId: conversationId)
            }
            return false
        }
    }

    /// Whether command hooks fired during this conversation's turn should run sandboxed. Follows
    /// the agent's sandbox policy (subagents always sandboxed; main agent per its resolution),
    /// independent of any specific tool. No warn side effect — run_command already surfaces it.
    private func hooksUseSandbox(conversationId: UUID, workspacePath: String?) async -> Bool {
        if case .sandboxed = await sandboxDecision(conversationId: conversationId, workspacePath: workspacePath) {
            return true
        }
        return false
    }

    func processInput(_ input: String, source: String, conversationId: UUID, inlineParts: [Part] = [], restrictToGoalComplete: Bool = false) async {
        // Own the thinking indicator for the whole turn via a balanced begin/end so that
        // overlapping turns can't leave it stuck (centralized in AppState's reference count).
        let stateForThinking = state
        await MainActor.run { stateForThinking?.beginThinking() }
        let turnID = PerformanceProfiler.shared.beginTurn(label: input, source: source)
        let turnStart = CFAbsoluteTimeGetCurrent()
        await PerformanceProfiler.$currentTurnID.withValue(turnID) {
            await processInputBody(input, source: source, conversationId: conversationId, inlineParts: inlineParts, restrictToGoalComplete: restrictToGoalComplete)
        }
        PerformanceProfiler.shared.endTurn(turnID, totalMs: (CFAbsoluteTimeGetCurrent() - turnStart) * 1000.0)
        await MainActor.run { stateForThinking?.endThinking() }
    }

    private func processInputBody(_ input: String, source: String, conversationId: UUID, inlineParts: [Part] = [], restrictToGoalComplete: Bool = false) async {
        if source == "UI" { loopDetectors[conversationId] = nil }

        let text = (source == "UI") ? input : "System Event [\(source)]: \(input)\nAnalyze this event. If it requires action based on your directives/skills, take it. Otherwise, briefly acknowledge it."

        let localState = state

        // Resolve once per turn where command hooks should run (main agent per policy; subagents
        // always sandboxed). Threaded into every hook fire below — never stored on the shared
        // HookManager, since main/subagent turns fire hooks concurrently.
        let hookWorkspace = await MainActor.run { localState?.conversations.first(where: { $0.id == conversationId })?.workspacePath }
        let hooksSandbox = await hooksUseSandbox(conversationId: conversationId, workspacePath: hookWorkspace)

        // BeforeAgent Hook
        let beforeAgentDecision = await HookManager.shared.fireBeforeAgent(input: text, useSandbox: hooksSandbox)
        var finalText = text
        if case .block(let reason) = beforeAgentDecision {
            await pushToUI(role: .system, text: "Hook blocked turn: \(reason)", conversationId: conversationId)
            return
        } else if case .proceed(let modifiedData) = beforeAgentDecision, let data = modifiedData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let modifiedInput = json["input"] as? String {
            finalText = modifiedInput
        }

        var userParts: [Part] = [Part(text: finalText, functionCall: nil, functionResponse: nil)]
        if !inlineParts.isEmpty {
            userParts.append(contentsOf: inlineParts)
        }
        let userContent = Content(role: "user", parts: userParts)
        await MainActor.run { localState?.appendContentToHistory(for: conversationId, content: userContent) }
        
        var history = await MainActor.run { localState?.conversations.first(where: { $0.id == conversationId })?.history ?? [] }
        let workspacePath = await MainActor.run { localState?.conversations.first(where: { $0.id == conversationId })?.workspacePath }
        
        var currentSystemPrompt = await ensureSystemPrompt()
        
        let userProfile = MemoryManager.shared.getUserProfile()
        
        let facts = (try? FactStoreManager.shared.search(query: input, limit: 5)) ?? []
        
        if !facts.isEmpty {
            try? FactStoreManager.shared.reinforceFacts(ids: facts.map { $0.id })
        }
        
    if let textPart = currentSystemPrompt.parts.first?.text {
        // Append USER.md first (mostly static)
        let structuralSafeUserProfile = PromptInjectionGuard.sanitizeUntrustedInput(userProfile)
        let safeUserProfile = await InjectionGuard.sanitize(structuralSafeUserProfile, contextTag: "user_profile", maxTier: .tier3_canary)
        currentSystemPrompt.parts[0].text = textPart + "\n\n# User Profile (USER.md)\n" + safeUserProfile
    }
        
        if let wp = workspacePath {
            let agentsMdPath = (wp as NSString).expandingTildeInPath
            let fullPath = (agentsMdPath as NSString).appendingPathComponent("AGENTS.md")
            if let agentsMdContent = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                if let textPart = currentSystemPrompt.parts.first?.text {
                    // Append AGENTS.md next (static per workspace)
                    let structuralSafeAgentsMd = PromptInjectionGuard.sanitizeUntrustedInput(agentsMdContent)
                    let safeAgentsMd = await InjectionGuard.sanitize(structuralSafeAgentsMd, contextTag: "workspace_rules", maxTier: .tier3_canary)
                    currentSystemPrompt.parts[0].text = textPart + "\n\n# Project Workspace Rules (AGENTS.md)\n" + safeAgentsMd
                }
            }
        }
        
        if !facts.isEmpty, let textPart = currentSystemPrompt.parts.first?.text {
            let factString = facts.map { "- \($0.content)" }.joined(separator: "\n")
            // Append Fact Store Memory last (highly volatile, changes per query)
            currentSystemPrompt.parts[0].text = textPart + "\n\n# Mid-Term Fact Store Memory (JIT Context)\n" + factString
        }
        
        var toolsList = await executor.getTools()
        // Add set_workspace tool dynamically
        toolsList.append(FunctionDeclaration(
            name: "set_workspace",
            description: "Bind this conversation to a local project workspace. Do this when the user says they are working in a specific project or directory.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "path": Schema(type: "STRING", description: "Absolute or tilde-expanded path to the workspace directory")
                ],
                required: ["path"]
            )
        ))
        
        toolsList.append(FunctionDeclaration(
            name: "rename_conversation",
            description: "Rename the current conversation to a short, descriptive title. Use this when instructed by a System Event or when the conversation topic has fundamentally changed.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "title": Schema(type: "STRING", description: "The new title for the conversation (1-4 words)")
                ],
                required: ["title"]
            )
        ))
        
        toolsList.append(FunctionDeclaration(
            name: "invoke_subagent",
            description: "Spawn an isolated subagent with a constrained persona to execute a task. By default, this blocks until the subagent completes. Set 'background' to true to run it asynchronously and receive a notification when it finishes.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "role": Schema(type: "STRING", description: "The persona (e.g., code_reviewer, security_auditor, researcher, engineer)"),
                    "task": Schema(type: "STRING", description: "The exact task prompt for the subagent"),
                    "effort": Schema(type: "STRING", description: "The reasoning effort required. 'easy' for simple/repetitive lookups, 'medium' for standard tasks, 'hard' for complex problem solving."),
                    "background": Schema(type: "BOOLEAN", description: "Optional. If true, returns immediately while the subagent runs in the background. The system will notify you with the results when done.")
                ],
                required: ["role", "task", "effort"]
            )
        ))
        
        toolsList.append(FunctionDeclaration(
            name: "schedule_job",
            description: "Schedule a recurring cron-like job or interval timer. The job will persist across app restarts and catch up if the computer wakes from sleep. Provide a clear prompt describing what Iris should do when it fires. You MUST provide EITHER intervalSeconds OR one or more cron fields (minute, hour, day, month, weekday), but not both.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "prompt": Schema(type: "STRING", description: "What Iris should do when the job fires"),
                    "minute": Schema(type: "INTEGER", description: "Cron minute (0-59)"),
                    "hour": Schema(type: "INTEGER", description: "Cron hour (0-23)"),
                    "day": Schema(type: "INTEGER", description: "Cron day of month (1-31)"),
                    "month": Schema(type: "INTEGER", description: "Cron month (1-12)"),
                    "weekday": Schema(type: "INTEGER", description: "Cron weekday (1=Sunday, 2=Monday, ..., 7=Saturday)"),
                    "intervalSeconds": Schema(type: "INTEGER", description: "Simple recurring interval in seconds (e.g. 3600 for every hour)")
                ],
                required: ["prompt"]
            )
        ))
        
        toolsList.append(FunctionDeclaration(
            name: "save_fact",
            description: "Silently drop atomic facts, state changes, or relationships into the holographic memory graph. Continuously groom this store to maintain mid-term memory.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "content": Schema(type: "STRING", description: "The factual content to save.")
                ],
                required: ["content"]
            )
        ))
        toolsList.append(FunctionDeclaration(
            name: "reflect",
            description: "Write down your internal thoughts, analysis, or evaluation of your progress. Use this to think step-by-step or evaluate if you are on the right track.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "thoughts": Schema(type: "STRING", description: "Your detailed reflection and thoughts.")
                ],
                required: ["thoughts"]
            )
        ))
        
        toolsList.append(FunctionDeclaration(
            name: "goal_complete",
            description: "Mark the active goal as completely finished and exit the autonomous loop. Always provide a summary of your findings and conclusions in the 'summary' argument so it is presented to the user.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "summary": Schema(type: "STRING", description: "A detailed summary of what was accomplished and final conclusion."),
                    "criteria_status": Schema(type: "ARRAY", description: "Per-criterion self-report against the goal contract. Self-report shown to the user as UNVERIFIED — do not overstate.", items: Schema(type: "OBJECT", properties: [
                        "criterion": Schema(type: "STRING", description: "The criterion text being reported on."),
                        "status": Schema(type: "STRING", description: "met | not_met | cannot_verify"),
                        "evidence": Schema(type: "STRING", description: "Brief evidence or reasoning for the status.")
                    ], required: ["criterion", "status"]))
                ],
                required: ["summary"]
            )
        ))
        toolsList.append(FunctionDeclaration(
            name: "search_memory",
            description: "Actively probe the holographic memory store for past context. Use this if the automatic JIT injection wasn't sufficient.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "query": Schema(type: "STRING", description: "The query string to search for.")
                ],
                required: ["query"]
            )
        ))
        toolsList.append(FunctionDeclaration(
            name: "update_user_profile",
            description: "Overwrite the USER.md profile. Keep it concise. Store high-level facts about the user that define how you should interact with them permanently.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "content": Schema(type: "STRING", description: "The new complete text content for the user profile")
                ],
                required: ["content"]
            )
        ))
        toolsList.append(FunctionDeclaration(
            name: "update_soul",
            description: "Overwrite your core identity file (SOUL.md). Use this to durably evolve your persona, values, and standing directives. Keep it coherent and concise.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "content": Schema(type: "STRING", description: "The new complete text content for SOUL.md")
                ],
                required: ["content"]
            )
        ))
        toolsList.append(FunctionDeclaration(
            name: "update_memory",
            description: "Overwrite your mid-term memory file (memory.md). Use this to consolidate durable facts, project context, and recurring workflows.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "content": Schema(type: "STRING", description: "The new complete text content for memory.md")
                ],
                required: ["content"]
            )
        ))
        toolsList.append(FunctionDeclaration(
            name: "propose_goal_contract",
            description: "Draft a structured contract for a goal the user is starting. Produce concrete criteria for 'done'. Honesty rules: never invent an `executable` check you cannot actually run; prefer a `qualitative` criterion over a fabricated number; flag taste/direction as `humanJudged`. Optionally group criteria into ordered checkpoints via a per-criterion 'milestone' label; the run pauses at each checkpoint for the user. This proposes a DRAFT for the user to edit and approve — it does not start the loop.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "objective": Schema(type: "STRING", description: "One-line restatement of the goal."),
                    "criteria": Schema(type: "ARRAY", description: "Definition of done.", items: Schema(type: "OBJECT", properties: [
                        "text": Schema(type: "STRING", description: "The criterion — what 'done' looks like."),
                        "kind": Schema(type: "STRING", description: "executable | qualitative | humanJudged"),
                        "check": Schema(type: "STRING", description: "A runnable command/test. ONLY for executable criteria."),
                        "milestone": Schema(type: "STRING", description: "Optional. A short checkpoint name; criteria sharing a name form one ordered checkpoint. Omit for a goal with no checkpoints.")
                    ], required: ["text", "kind"])),
                    "out_of_scope": Schema(type: "ARRAY", description: "Explicit non-goals.", items: Schema(type: "STRING")),
                    "stop_before": Schema(type: "ARRAY", description: "Irreversible / authorization boundaries to stop and ask before (e.g. force-push, merge, delete, spend).", items: Schema(type: "STRING")),
                    "assumptions": Schema(type: "ARRAY", description: "Anything you inferred that the user should confirm.", items: Schema(type: "STRING"))
                ],
                required: ["objective", "criteria"]
            )
        ))
        toolsList.append(FunctionDeclaration(
            name: "amend_goal_contract",
            description: "Change the LOCKED goal contract's criteria when the work reveals they were wrong. A `rationale` is mandatory — criteria never change silently. The change is logged and shown to the user.",
            parameters: Schema(type: "OBJECT", properties: [
                "action": Schema(type: "STRING", description: "add | remove | update"),
                "criterion": Schema(type: "STRING", description: "The criterion text to add, or the existing text to remove/update."),
                "kind": Schema(type: "STRING", description: "executable | qualitative | humanJudged (for add/update)."),
                "check": Schema(type: "STRING", description: "Runnable command/test, only for executable."),
                "rationale": Schema(type: "STRING", description: "One line: why the criteria must change.")
            ], required: ["action", "criterion", "rationale"])
        ))

        let ladderContract = await MainActor.run {
            localState?.conversations.first(where: { $0.id == conversationId })?.goalContract
        }
        if principal == .main, let gc = ladderContract, gc.hasLadder, !gc.isFinalMilestone {
            toolsList.append(FunctionDeclaration(
                name: "reach_checkpoint",
                description: "Signal that the CURRENT checkpoint's criteria are satisfied. The run pauses and an independent evaluator grades the work so far; the user then reviews before the next checkpoint. Use goal_complete only at the final checkpoint.",
                parameters: Schema(
                    type: "OBJECT",
                    properties: [
                        "milestone_summary": Schema(type: "STRING", description: "What you accomplished for this checkpoint."),
                        "criteria_status": Schema(type: "ARRAY", description: "Per-criterion self-report for this checkpoint. Shown to the user as UNVERIFIED.", items: Schema(type: "OBJECT", properties: [
                            "criterion": Schema(type: "STRING", description: "The criterion text."),
                            "status": Schema(type: "STRING", description: "met | not_met | cannot_verify"),
                            "evidence": Schema(type: "STRING", description: "Brief evidence.")
                        ], required: ["criterion", "status"]))
                    ],
                    required: ["milestone_summary"]
                )
            ))
        }

        // Offer an optional `intent` on every tool so the model can attach a one-line
        // rationale the UI shows next to each call (#31). Central + idempotent, so any
        // future tool is covered automatically.
        toolsList = ToolIntent.augment(toolsList)

        // The evaluator gets a mutation-free surface: read + run + submit_evaluation only (#9).
        if principal == .evaluator {
            toolsList = EvaluatorToolset.restrict(toolsList)
        }

        // Guard the Gemini array-schema contract: an ARRAY property missing `items` is rejected
        // with HTTP 400. Fires in debug/test builds (the engine-exercising tests run this path),
        // so a future tool that forgets `items` trips here instead of at runtime against the API.
        assert(toolsList.arrayItemsViolations().isEmpty,
               "Tool ARRAY schema(s) missing `items` (Gemini will reject): \(toolsList.arrayItemsViolations())")

        let toolSelectionDecision = await HookManager.shared.fireBeforeToolSelection(tools: toolsList, useSandbox: hooksSandbox)
        if case .block(let reason) = toolSelectionDecision {
            await pushToUI(role: .system, text: "Hook blocked tool selection: \(reason)", conversationId: conversationId)
            return
        } else if case .proceed(let modifiedData) = toolSelectionDecision, let data = modifiedData {
            if let modifiedTools = try? JSONDecoder().decode([FunctionDeclaration].self, from: data) {
                toolsList = modifiedTools
            }
        }
        
        let preCompressDecision = await HookManager.shared.firePreCompress(history: history, useSandbox: hooksSandbox)
        if case .block(let reason) = preCompressDecision {
            await pushToUI(role: .system, text: "Hook PreCompress blocked execution: \(reason)", conversationId: conversationId)
            return
        } else if case .proceed(let modifiedData) = preCompressDecision, let data = modifiedData {
            if let modifiedHistory = try? JSONDecoder().decode([Content].self, from: data) {
                history = modifiedHistory
            }
        }
        
        // A soft-stop summary turn gets ONLY goal_complete: the model can summarize or finish,
        // but physically cannot keep calling the tool it was looping on. A worded "please stop"
        // does not bind the model (it rationalizes past it — see the loop-detection stop signal),
        // so enforcement has to be mechanical: remove the tool from the schema.
        if restrictToGoalComplete {
            toolsList = toolsList.filter { $0.name == "goal_complete" }
        }
        var request = GeminiRequest(contents: history, systemInstruction: currentSystemPrompt, tools: [Tool(functionDeclarations: toolsList)])
        
        var turnFinished = false
        while !turnFinished {
            await Task.yield()
            // Cooperative cancellation: bail out at turn boundaries if this task was cancelled
            // (e.g. the conversation was deleted or the goal was stopped mid-turn).
            if Task.isCancelled { break }
            do {
                let beforeModelDecision = await HookManager.shared.fireBeforeModel(request: request, useSandbox: hooksSandbox)
                if case .block(let reason) = beforeModelDecision {
                    await pushToUI(role: .system, text: "Hook BeforeModel blocked execution: \(reason)", conversationId: conversationId)
                    break
                }
                
                var activeRequest = request
                if case .proceed(let modifiedData) = beforeModelDecision, let data = modifiedData {
                    if let modifiedReq = try? JSONDecoder().decode(GeminiRequest.self, from: data) {
                        activeRequest = modifiedReq
                    }
                }
                
                await MainActor.run {
                    localState?.updateSubagentStatus(id: conversationId, status: "Thinking...")
                }
                // Measure at the seam so every client (real, fake, future) is attributed
                // uniformly, and the span includes engine-side call overhead.
                let response = try await measure(.primaryLLM) {
                    try await client.generateContent(request: activeRequest, tier: modelTier)
                }
                await MainActor.run {
                    localState?.updateSubagentStatus(id: conversationId, status: "Executing...")
                }
                
                let afterModelDecision = await HookManager.shared.fireAfterModel(response: response, useSandbox: hooksSandbox)
                if case .block(let reason) = afterModelDecision {
                    await pushToUI(role: .system, text: "Hook AfterModel blocked execution: \(reason)", conversationId: conversationId)
                    break
                }
                
                var activeResponse = response
                if case .proceed(let modifiedData) = afterModelDecision, let data = modifiedData {
                    if let modifiedRes = try? JSONDecoder().decode(GeminiResponse.self, from: data) {
                        activeResponse = modifiedRes
                    }
                }
                
                guard let candidate = activeResponse.candidates?.first, let responseContent = candidate.content else {
                    await pushToUI(role: .agent, text: "Error: No candidate returned.", conversationId: conversationId)
                    break
                }
                
                let modelContent = Content(role: "model", parts: responseContent.parts)
                await MainActor.run { 
                    localState?.appendContentToHistory(for: conversationId, content: modelContent) 
                }
                history = await MainActor.run {
                    localState?.conversations.first(where: { $0.id == conversationId })?.history ?? []
                }
                await MainActor.run { 
                    if let usage = activeResponse.usageMetadata {
                        localState?.updateTokenUsage(for: conversationId, usage: usage)
                    }
                }
                
                var hasFunctionCall = false
                
                for part in responseContent.parts {
                    if let responseText = part.text {
                        await pushToUI(role: .agent, text: responseText, conversationId: conversationId)
                        
                        let afterAgentDecision = await HookManager.shared.fireAfterAgent(output: responseText, useSandbox: hooksSandbox)
                        if case .block(let reason) = afterAgentDecision {
                            await pushToUI(role: .system, text: "Hook AfterAgent blocked execution: \(reason)", conversationId: conversationId)
                        }
                    }
                }
                
                var toolCalls: [FunctionCall] = []
                for part in responseContent.parts {
                    if let fc = part.functionCall {
                        toolCalls.append(fc)
                    }
                }
                
                if !toolCalls.isEmpty {
                    hasFunctionCall = true
                    
                    let results = await measure(.toolExecution) {
                        await withTaskGroup(of: (Int, String).self) { group in
                            for (index, call) in toolCalls.enumerated() {
                                group.addTask {
                                    // Hard enforcement for a soft-stop summary turn: the model can
                                    // still EMIT any tool call (the restricted schema is only advisory
                                    // to it, and this dispatcher executes any named tool), so block
                                    // everything except goal_complete here — this is what actually
                                    // stops the looping action from running again.
                                    if restrictToGoalComplete && call.name != "goal_complete" {
                                        await self.pushToUI(role: .system, text: "[blocked] '\(call.name)' is unavailable — the goal loop was stopped. Call goal_complete.", conversationId: conversationId)
                                        return (index, "Blocked: the goal loop has been stopped after repeating an action too many times. '\(call.name)' is unavailable in this turn. Call goal_complete with a summary of what you accomplished and what is blocking you.")
                                    }
                                    let toolCallDict: [String: Any] = [
                                        "name": call.name,
                                        "args": call.args.mapValues { $0.anyValue }
                                    ]
                                    // For run_command, supply a stable UUID so the UI can key
                                    // elapsed-time display against this exact message.
                                    let timingId: UUID? = call.name == "run_command" ? UUID() : nil
                                    if let jsonData = try? JSONSerialization.data(withJSONObject: toolCallDict, options: .prettyPrinted),
                                       let jsonString = String(data: jsonData, encoding: .utf8) {
                                        await self.pushToUI(role: .system, text: "[TOOL_CALL]\n\(jsonString)", conversationId: conversationId, id: timingId)
                                    } else {
                                        await self.pushToUI(role: .system, text: "Running tool: \(call.name)", conversationId: conversationId, id: timingId)
                                    }
                                    if let id = timingId {
                                        await self.recordCommandStart(id: id)
                                    }

                                    let cmdStart = Date()
                                    let result = await self.executeFunctionCall(call, conversationId: conversationId, workspacePath: workspacePath, restrictToGoalComplete: restrictToGoalComplete)
                                    if let id = timingId {
                                        let elapsed = Date().timeIntervalSince(cmdStart)
                                        await self.recordCommandDuration(id: id, elapsed: elapsed)
                                    }
                                    return (index, result)
                                }
                            }

                            // Collect results keyed by their original index so we can restore order
                            // deterministically even when multiple calls share the same name/args.
                            var collection: [Int: String] = [:]
                            for await (index, result) in group {
                                collection[index] = result
                            }
                            return collection
                        }
                    }

                    var responseParts: [Part] = []
                    // Preserve original order of tool calls by iterating over toolCalls
                    for (index, call) in toolCalls.enumerated() {
                        if let result = results[index] {
                            responseParts.append(Part(text: nil, functionCall: nil, functionResponse: FunctionResponse(name: call.name, response: ["result": .string(result)], id: call.id)))
                        }
                    }
                    
                    let functionResponse = Content(role: "user", parts: responseParts)
                    await MainActor.run { localState?.appendContentToHistory(for: conversationId, content: functionResponse) }
                    history = await MainActor.run { localState?.conversations.first(where: { $0.id == conversationId })?.history ?? [] }
                    request.contents = history

                    // Loop detection: if the same tool call repeats too many times, stop early.
                    if await MainActor.run(body: { localState?.conversations.first(where: { $0.id == conversationId })?.activeGoal != nil }) {
                        let threshold = ConfigManager.shared.loopDetectionThreshold
                        var detector = loopDetectors[conversationId] ?? LoopDetector(threshold: threshold)
                        var tripped = false
                        for call in toolCalls {
                            if detector.record(LoopDetector.signature(toolName: call.name, args: call.args)) { tripped = true }
                        }
                        loopDetectors[conversationId] = detector
                        if tripped {
                            turnFinished = true
                            await softStopWithSummary(conversationId: conversationId, reason: "repeated the same action \(threshold)× in a row")
                            break
                        }
                    }

                    // `goal_complete`, `reach_checkpoint`, and `submit_evaluation` all
                    // return control to the parent/user (or end the evaluator), so the turn
                    // is over. Ending here also prevents an unbounded turn loop if the model
                    // keeps re-issuing the same tool call.
                    if toolCalls.contains(where: {
                        $0.name == "goal_complete" ||
                        $0.name == "reach_checkpoint" ||
                        $0.name == "submit_evaluation"
                    }) {
                        turnFinished = true
                    }

                    // A soft-stop summary turn runs exactly one round: with the looping tool
                    // blocked above, do not reprompt a stopped loop into another attempt.
                    // (The goal is already cleared, so loop detection above is inactive here.)
                    if restrictToGoalComplete {
                        turnFinished = true
                    }
                }

                if !hasFunctionCall {
                    turnFinished = true
                }
            } catch {
                await HookManager.shared.fireNotification(title: "LLM Error", body: error.localizedDescription, useSandbox: hooksSandbox)
                await pushToUI(role: .agent, text: "Error calling LLM: \(error.localizedDescription)", conversationId: conversationId)
                turnFinished = true
                await MainActor.run {
                    localState?.clearGoal(for: conversationId)
                    localState?.onSubagentComplete[conversationId]?(SubagentTermination(status: .failed, summary: "Subagent failed due to LLM Error: \(error.localizedDescription)", calledGoalComplete: false))
                    localState?.onSubagentComplete[conversationId] = nil
                }
            }
        }
        
        await MainActor.run {
            localState?.stripInlineDataFromHistory(for: conversationId)
        }

        // Auto-reprompt if we are in goal mode
        let activeGoalResult = await MainActor.run { () -> (String?, Int) in
            if let index = localState?.conversations.firstIndex(where: { $0.id == conversationId }) {
                localState?.conversations[index].goalIterationCount += 1
                return (localState?.conversations[index].activeGoal, localState?.conversations[index].goalIterationCount ?? 0)
            }
            return (nil, 0)
        }
        
        let pausedForReview = await MainActor.run {
            localState?.conversations.first(where: { $0.id == conversationId })?.goalContract?.checkpointStatus == .pausedForReview
        }
        if let _ = activeGoalResult.0, !pausedForReview {
            if activeGoalResult.1 >= ConfigManager.shared.maxGoalIterations {
                await softStopWithSummary(conversationId: conversationId,
                                          reason: "reached the \(ConfigManager.shared.maxGoalIterations)-iteration limit")
            } else {
                await pushToUI(role: .system, text: "Auto-continuing goal loop (iteration \(activeGoalResult.1))...", conversationId: conversationId)
                repromptTasks[conversationId]?.cancel()
                repromptTasks[conversationId] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    // Re-verify the conversation still exists and the goal is still active before
                    // reprompting — it may have been deleted or stopped during the sleep.
                    let stillActive = await MainActor.run { () -> Bool in
                        guard let conv = localState?.conversations.first(where: { $0.id == conversationId }) else { return false }
                        return conv.activeGoal != nil
                    }
                    guard stillActive else { return }
                    let contract = await MainActor.run {
                        localState?.conversations.first(where: { $0.id == conversationId })?.goalContract
                    }
                    let oracle = contract?.oracleText() ?? ""
                    // Keep the closing instruction consistent with the oracle. With an active ladder
                    // that hasn't reached its final checkpoint, the next terminal action is
                    // `reach_checkpoint`, NOT `goal_complete` — otherwise this tail contradicts the
                    // ladder oracle and steers the model straight past every checkpoint.
                    let closing: String
                    if let c = contract, c.hasLadder, !c.isFinalMilestone {
                        closing = "When the current checkpoint's criteria are satisfied, call `reach_checkpoint` (NOT goal_complete)."
                    } else {
                        closing = "If every criterion is satisfied, call goal_complete."
                    }
                    let reprompt = oracle.isEmpty
                        ? "Continue working on your goal. What is your next step? \(closing)"
                        : "\(oracle)\n\nContinue working toward the objective above. What is your next step? \(closing)"
                    await self.processInput(reprompt, source: "System", conversationId: conversationId)
                }
            }
        }
    }
    
    private func executeFunctionCall(_ functionCall: FunctionCall, conversationId: UUID, workspacePath: String?, restrictToGoalComplete: Bool = false) async -> String {
        let localState = state
        var result = ""
        
        if functionCall.name == "set_workspace", let path = functionCall.args["path"]?.stringValue {
            let currentWorkspace = path
            
            var extraHint = ""
            let fm = FileManager.default
            let irisDir = URL(fileURLWithPath: currentWorkspace).appendingPathComponent(".iris")
            let vibecopPath = irisDir.appendingPathComponent("vibecop.md").path
            
            if !fm.fileExists(atPath: vibecopPath) {
                if let contents = try? fm.contentsOfDirectory(atPath: currentWorkspace), !contents.isEmpty {
                    extraHint = "\n\n💡 Hint: No Vibecop Guardian config found for this workspace. Suggest that the user run `/vibecop init` to generate one."
                }
            }
            
            await MainActor.run { localState?.setWorkspace(for: conversationId, path: currentWorkspace) }
            result = "Workspace successfully set to \(currentWorkspace). You will now load AGENTS.md from this directory." + extraHint
        } else if functionCall.name == "rename_conversation", let newTitle = functionCall.args["title"]?.stringValue {
            await MainActor.run { localState?.renameConversation(id: conversationId, newTitle: newTitle) }
            result = "Conversation renamed to '\(newTitle)'."
        } else if functionCall.name == "propose_goal_contract" {
            if let draft = GoalContractParsing.contract(from: functionCall.args) {
                await MainActor.run { localState?.setDraftContract(for: conversationId, draft) }
                result = "Draft goal contract proposed for user review. Await approval before starting the goal loop."
            } else {
                result = "Could not parse the proposed goal contract (missing objective?)."
            }
        } else if functionCall.name == "schedule_job", let prompt = functionCall.args["prompt"]?.stringValue {
            let minute = Int(functionCall.args["minute"]?.stringValue ?? "")
            let hour = Int(functionCall.args["hour"]?.stringValue ?? "")
            let day = Int(functionCall.args["day"]?.stringValue ?? "")
            let month = Int(functionCall.args["month"]?.stringValue ?? "")
            let weekday = Int(functionCall.args["weekday"]?.stringValue ?? "")
            let intervalSeconds = Int(functionCall.args["intervalSeconds"]?.stringValue ?? "")
            
            ScheduleManager.shared.schedule(
                conversationId: conversationId,
                prompt: prompt,
                minute: minute,
                hour: hour,
                day: day,
                month: month,
                weekday: weekday,
                intervalSeconds: intervalSeconds
            )
            result = "Job scheduled successfully. It will fire in the background."
        } else if functionCall.name == "save_fact", let content = functionCall.args["content"]?.stringValue {
            let category = functionCall.args["category"]?.stringValue ?? "general"
            let entity = functionCall.args["entity"]?.stringValue
            _ = try? FactStoreManager.shared.addFact(content: content, category: category, entity: entity)
            result = "Fact saved to fact store."
        } else if functionCall.name == "search_memory", let query = functionCall.args["query"]?.stringValue {
            let facts = (try? FactStoreManager.shared.search(query: query)) ?? []
            if facts.isEmpty {
                result = "No relevant facts found."
            } else {
                result = facts.map { "- \($0.content)" }.joined(separator: "\n")
            }
        } else if functionCall.name == "update_user_profile", let content = functionCall.args["content"]?.stringValue {
            MemoryManager.shared.updateUserProfile(content: content)
            result = "User profile updated."
        } else if functionCall.name == "update_soul", let content = functionCall.args["content"]?.stringValue {
            MemoryManager.shared.updateSoul(content: content)
            systemPrompt = nil   // invalidate cache so the new SOUL loads next turn
            result = "Soul updated. It will take effect on the next turn."
        } else if functionCall.name == "update_memory", let content = functionCall.args["content"]?.stringValue {
            MemoryManager.shared.updateMemory(content: content)
            result = "Memory updated."
        } else if functionCall.name == "reflect" {
            result = "Reflection logged. Proceed with your next action."
        } else if functionCall.name == "invoke_subagent",
                  let role = functionCall.args["role"]?.stringValue,
                  let task = functionCall.args["task"]?.stringValue {
            // `effort` is optional; default to medium so the subagent isn't silently dropped when
            // the model omits it.
            let effort = functionCall.args["effort"]?.stringValue ?? "medium"
            let isBackground = (functionCall.args["background"]?.stringValue.lowercased() == "true")
            
            if isBackground {
                Task {
                    let rendered = await SubagentManager.shared.runSubagent(role: role, task: task, effort: effort, parentConversationId: conversationId)
                    await self.handleSystemEvent("Background subagent result:\n\(rendered)", source: "SubagentManager", conversationId: conversationId)
                }
                result = "Subagent '\(role)' spawned in the background. You will receive a System Event when it finishes."
            } else {
                result = await SubagentManager.shared.runSubagent(role: role, task: task, effort: effort, parentConversationId: conversationId)
            }
        } else if functionCall.name == "goal_complete", let summary = functionCall.args["summary"]?.stringValue {
            // Ladder gate: with an active checkpoint ladder, `goal_complete` is valid ONLY at the
            // final checkpoint — before then the model must advance through checkpoints via
            // `reach_checkpoint`, so the terminal tool can't silently skip the ladder. Bypassed under
            // a soft-stop (`restrictToGoalComplete`): that is an emergency termination (iteration cap
            // / loop detection) which must be allowed to end the goal regardless of ladder position,
            // and `reach_checkpoint` isn't even offered in that restricted turn.
            if principal == .main, !restrictToGoalComplete {
                let ladder = await MainActor.run {
                    localState?.conversations.first(where: { $0.id == conversationId })?.goalContract
                }
                if let c = ladder, c.hasLadder, !c.isFinalMilestone {
                    return "You are at checkpoint \(c.currentMilestone + 1) of \(c.milestones.count). Call `reach_checkpoint` to complete the CURRENT checkpoint — `goal_complete` is only valid at the final checkpoint, once every earlier checkpoint has been approved."
                }
            }
            let statusReport = functionCall.args["criteria_status"]
            let contractToGrade: GoalContract? = (principal == .main)
                ? await MainActor.run { localState?.conversations.first(where: { $0.id == conversationId })?.goalContract }
                : nil
            // Resolve the EFFECTIVE working directory the main agent used, so the evaluator grades
            // in the same place. When no workspace is bound, run_command inherits the process cwd
            // (it never sets currentDirectoryURL), so fall back to that same path — otherwise the
            // grader is dropped context-free and roams the filesystem looking for the artifacts.
            let gradeWorkspace = workspacePath ?? FileManager.default.currentDirectoryPath
            await MainActor.run {
                localState?.recordCompletionSelfReport(for: conversationId, statusJSON: statusReport)
                if let c = contractToGrade { localState?.beginGoalEvaluation(for: conversationId, contract: c) }
                localState?.clearGoal(for: conversationId)
                localState?.onSubagentComplete[conversationId]?(SubagentTermination(status: .completed, summary: summary, calledGoalComplete: true))
                localState?.onSubagentComplete[conversationId] = nil
            }
            if let c = contractToGrade {
                // Non-blocking: grade in the background; the verdict fills in the chip when ready.
                // Pass the engine's own client so tests drive the grader with a scripted client
                // (in production this is the real LLMClient). `client` here is this IrisEngine's
                // stored client property (from init(...client:)) — capture it into a local first
                // since the detached task can't touch actor-isolated state.
                let graderClient = self.client
                let graderApp = localState
                if let graderApp {
                    Task.detached { await GoalEvaluator.shared.evaluate(contract: c, workspace: gradeWorkspace, originatingConversationId: conversationId, app: graderApp, client: graderClient) }
                }
            }
            await pushToUI(role: .agent, text: summary, conversationId: conversationId)
            if principal == .main {
                let reflectionNotice = "System Event [Goal Completion Skill Check]: Evaluate the goal just completed. Did you execute a complex multi-step procedure, overcome non-obvious errors, or discover a reusable recipe? If so, call `create_skill` or `update_skill` now to save or patch it in your permanent skill library."
                await processInput(reflectionNotice, source: "System", conversationId: conversationId)
            }
            result = "Goal marked as complete. Summary: \(summary)"
        } else if functionCall.name == "reach_checkpoint", principal == .main {
            let summary = functionCall.args["milestone_summary"]?.stringValue ?? ""
            let statusReport = functionCall.args["criteria_status"]
            let contract = await MainActor.run {
                localState?.conversations.first(where: { $0.id == conversationId })?.goalContract
            }
            guard let contract, contract.hasLadder else {
                result = "No checkpoint ladder is active. Call goal_complete when the goal is finished."
                return result
            }
            if contract.isFinalMilestone {
                result = "This is the final checkpoint — call `goal_complete` to finish, not `reach_checkpoint`."
                return result
            }
            let projected = contract.projectedContract(throughMilestone: contract.currentMilestone)
            let gradeWorkspace = workspacePath ?? FileManager.default.currentDirectoryPath
            await MainActor.run {
                localState?.recordCompletionSelfReport(for: conversationId, statusJSON: statusReport)
                localState?.beginGoalEvaluation(for: conversationId, contract: projected)
                localState?.setCheckpointPaused(for: conversationId)   // leaves activeGoal set
            }
            // Await the grade (unlike goal_complete's detached grade) — the human should see the
            // verdict before re-engaging. The reprompt guard (Task 6) keeps the loop quiet meanwhile.
            let graderClient = self.client
            if let graderApp = localState {
                await GoalEvaluator.shared.evaluate(contract: projected, workspace: gradeWorkspace,
                                                    originatingConversationId: conversationId,
                                                    app: graderApp, client: graderClient)
            }
            let ladderPos = "\(contract.currentMilestone + 1) of \(contract.milestones.count)"
            await pushToUI(role: .agent, text: "Reached checkpoint \(ladderPos): \(summary)\nPaused for your review — approve to continue or send me back.", conversationId: conversationId)
            result = "Checkpoint \(ladderPos) reached and graded. Paused for user review."
        } else if functionCall.name == "submit_evaluation" {
            let payload = functionCall.args["evaluations"]
            await MainActor.run {
                localState?.onEvaluationComplete[conversationId]?(JSONValue.object(["evaluations": payload ?? .null]))
                localState?.onEvaluationComplete[conversationId] = nil
                localState?.clearGoal(for: conversationId)   // end the evaluator's own loop (mirrors goal_complete)
            }
            result = "Evaluation submitted."
        } else if functionCall.name == "amend_goal_contract" {
            let action = functionCall.args["action"]?.stringValue ?? "add"
            let text = functionCall.args["criterion"]?.stringValue ?? ""
            let kind = functionCall.args["kind"]?.stringValue ?? "qualitative"
            let check = functionCall.args["check"]?.stringValue
            let rationale = functionCall.args["rationale"]?.stringValue ?? ""
            let ok = await MainActor.run {
                localState?.amendGoalContract(for: conversationId, action: action, criterionText: text, kind: kind, check: check, rationale: rationale) ?? false
            }
            result = ok ? "Goal contract amended (\(action): \(text)). Logged with rationale."
                        : "Amend rejected — a non-empty rationale is required to change locked criteria."
        } else {
            var needsApproval = false
            var details = ""
            if functionCall.name == "run_command", let cmd = functionCall.args["command"]?.stringValue {
                needsApproval = true
                details = cmd
            } else if functionCall.name == "read_file" || functionCall.name == "write_file", let path = functionCall.args["path"]?.stringValue {
                needsApproval = true
                details = path
            }
            
            let useSandbox = await resolveUseSandbox(toolName: functionCall.name, conversationId: conversationId, workspacePath: workspacePath)
            if needsApproval {
                let approved = await localState?.requestApproval(
                    toolName: functionCall.name, details: details, workspace: workspacePath,
                    conversationId: conversationId, origin: approvalOrigin, inSandbox: useSandbox,
                    callerRole: principal == .evaluator ? .evaluator : .agent,
                    allowedCommands: evaluatorChecks) ?? false
                if approved {
                    result = await executeToolWithHooks(name: functionCall.name, args: functionCall.args, cwd: workspacePath, conversationId: conversationId, useSandbox: useSandbox)
                } else {
                    result = "User denied permission to execute this tool. You must ask the user for clarification or suggest an alternative."
                }
            } else {
                result = await executeToolWithHooks(name: functionCall.name, args: functionCall.args, cwd: workspacePath, conversationId: conversationId, useSandbox: useSandbox)
            }
        }
        
        return result
    }
    
    private func executeToolWithHooks(name: String, args: [String: JSONValue], cwd: String?, conversationId: UUID?, useSandbox: Bool) async -> String {
        var execArgs: [String: JSONValue] = args

        // Command hooks run in the agent's environment (per principal policy), independent of this
        // specific tool's own host/sandbox routing.
        let hooksSandbox = conversationId == nil ? false : await hooksUseSandbox(conversationId: conversationId!, workspacePath: cwd)

        let beforeDecision = await HookManager.shared.fireBeforeTool(toolName: name, args: execArgs, useSandbox: hooksSandbox)
        if case .block(let reason) = beforeDecision {
            return "System Hook blocked execution: \(reason)"
        }
        
        if case .proceed(let modifiedData) = beforeDecision, let data = modifiedData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Re-encode and decode via JSONValue to keep it simple, or map manually
            if let updatedArgsData = try? JSONSerialization.data(withJSONObject: json),
               let updatedArgs = try? JSONDecoder().decode([String: JSONValue].self, from: updatedArgsData) {
                for (k, v) in updatedArgs {
                    execArgs[k] = v
                }
            }
        }
        
        var result = await executor.execute(name: name, args: execArgs, cwd: cwd, conversationId: conversationId, useSandbox: useSandbox)

        if name == "write_file", result.hasPrefix("Successfully wrote to "),
           let cid = conversationId, let path = execArgs["path"]?.stringValue {
            let resolved = ToolExecutor.resolvePath(path, cwd: cwd)
            let localState = state
            await MainActor.run { localState?.recordSubagentWrite(conversationId: cid, path: resolved) }
        }

        let afterDecision = await HookManager.shared.fireAfterTool(toolName: name, result: result, useSandbox: hooksSandbox)
        if case .block(let reason) = afterDecision {
            return "System Hook blocked result: \(reason)"
        } else if case .proceed(let modifiedData) = afterDecision, let data = modifiedData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let newResult = json["result"] as? String {
            result = newResult
        }
        
        // First-party trust: reading a file under ~/.iris/ returns Iris's OWN content
        // (SOUL, USER, memory.md, skills, artifacts, library, rules, configs) — not untrusted external data.
        // Return it raw, bypassing the guard, so the same `---`-stripping / <untrusted_context>
        // wrapping that mangles first-party content on read-back does not apply. Everything else
        // (other paths, other tools, web results) stays guarded below.
        if name == "read_file",
           let path = execArgs["path"]?.stringValue,
           IrisPaths.default.isUnderIrisDir(path) {
            return result
        }

        // Tier 1 Sanitization: Apply structural isolation to prevent prompt injection from tool outputs
        let structuralSafeResult = PromptInjectionGuard.sanitizeUntrustedInput(result)

        let trustedTools: Set<String> = ["set_workspace", "register_directory_watcher"]
        let maxTier: InjectionGuard.SanitizationTier = trustedTools.contains(name) ? .tier1_structural : .tier3_canary
        
        // Tier 2 & 3 Sanitization: Active heuristic and canary detection (skipped for trusted tools)
        let sanitizedResult = await InjectionGuard.sanitize(structuralSafeResult, contextTag: "tool_output_\(name)", maxTier: maxTier)
        
        return sanitizedResult
    }
    
    func pushToUI(role: ChatRole, text: String, conversationId: UUID, id: UUID? = nil) async {
        let localState = state
        await MainActor.run {
            if let id {
                localState?.appendMessage(role: role, content: text, id: id, to: conversationId)
            } else {
                localState?.appendMessage(role: role, content: text, to: conversationId)
            }
        }
    }

    func recordCommandStart(id: UUID) async {
        let localState = state
        await MainActor.run { localState?.commandStartTimes[id] = Date() }
    }

    func recordCommandDuration(id: UUID, elapsed: TimeInterval) async {
        let localState = state
        await MainActor.run { localState?.commandDurations[id] = elapsed }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Bypass static destructors in llama.cpp ggml-metal to prevent GGML_ASSERT crash on exit
        _exit(0)
    }
}

struct IrisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() {
        IrisMigrator.migrate(.default)
        ShippedSkills.seedIfNeeded(.default)
        Task {
            await SandboxSessionManager.shared.reapOrphans()
            while true {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // every 5 min
                let minutes = await MainActor.run { ConfigManager.shared.sandboxIdleTimeoutMinutes }
                await SandboxSessionManager.shared.reapIdle(olderThan: TimeInterval(minutes * 60))
            }
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if let imagePath = Bundle.module.path(forResource: "iris-icon", ofType: "png"),
           let image = NSImage(contentsOfFile: imagePath) {
            NSApplication.shared.applicationIconImage = image
        }
        
        KeyboardShortcuts.onKeyUp(for: .toggleIris) {
            if let window = NSApp.windows.first(where: { $0.title == "Iris" }) {
                if window.isVisible && NSApp.isActive {
                    window.orderOut(nil)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            } else {
                // If it's closed but a SwiftUI window still exists (sometimes hidden)
                if let window = NSApp.windows.first(where: { $0.className.contains("SwiftUI") }) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
    
    var body: some Scene {
        WindowGroup("Iris") {
            ChatView()
                .tint(.irisIndigo)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Divider()
                Button("Rerun Setup Wizard...") {
                    NotificationCenter.default.post(name: NSNotification.Name("RerunSetupWizard"), object: nil)
                }
            }
        }
        
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
        }
        
        // This is a minimal MenuBarExtra, we can expand it later.
        MenuBarExtra("Iris", systemImage: "sparkles") {
            Button("Show Chat") {
                // If the window is closed, this doesn't automatically reopen it in SwiftUI 
                // without URL routing or openWindow. But it serves as a placeholder.
                // In macOS 13+, we'd use openWindow(id:)
            }
            Divider()
            Button("Settings...") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        
        Settings {
            SettingsView()
        }
    }
}
