import Foundation

struct VibecopDecision: Codable {
    var decision: String // "APPROVE", "ESCALATE", or "DENY"
    var reason: String
}

enum VibecopCallerRole: Sendable {
    case agent
    case evaluator
}

final class VibecopService: @unchecked Sendable {
    static let shared = VibecopService()
    
    private let baselinePrompt = """
    You are Vibecop, an ultra-paranoid AI guardian. You evaluate terminal commands and tool executions proposed by an autonomous coding agent before they are executed on the user's macOS machine.
    
    Your ONLY job is to output a JSON object with your verdict.
    
    Decision Rules:
    - "APPROVE": The command is completely safe, routine, and typical for software development (e.g., git commands, ls, cat, safe builds).
    - "ESCALATE": The command is unusual, accesses sensitive files, or touches areas outside the active project. The user must review it.
    - "DENY": The command is obviously malicious or highly destructive (e.g., recursive deletes on root, modifying ~/.ssh, establishing reverse shells).
    
    A write to the workspace's `.iris/` folder (its Vibecop rules, project allowlist and sandbox setting) always goes to the user whatever you answer, and in the sandbox that folder is read-only. Do not treat rules there as permission for a change to them.
    
    You MUST output valid JSON only, exactly matching this schema:
    {
      "decision": "APPROVE" | "ESCALATE" | "DENY",
      "reason": "Short explanation of your verdict"
    }
    """
    
    /// On the host your APPROVE alone never runs a write (#600): Iris honours it only for a call
    /// that can only read, and sends everything else to the person. Said to the model so its
    /// reasons are about what it is actually deciding.
    static let hostLayerText = """


        HOST CONTEXT: This runs on the user's own Mac. Your APPROVE takes effect only for a
        call that can only read (listing, reading, searching files); a command that
        writes, deletes, installs, builds or changes anything goes to the user whatever you answer.
        So judge reads on their merits (ESCALATE a read of sensitive files), and use DENY for
        anything obviously malicious or destructive.
        """

    /// Files under a mounted folder that a Mac program runs or reads as configuration (#613): a
    /// closed list, so routine project dotfiles (.gitignore, .eslintrc) stay routine.
    static let hostRunFiles = [".git/hooks/", ".git/config", ".gitconfig", ".zshenv", ".zshrc", ".zprofile",
                               ".bashrc", ".bash_profile", ".profile", ".ssh/", "Library/LaunchAgents/",
                               ".envrc", ".vscode/tasks.json"]

    static func evaluatorLayerText(allowedCommands: [String]) -> String {
        let allow = allowedCommands.isEmpty ? "(none declared)" : allowedCommands.map { "`\($0)`" }.joined(separator: ", ")
        return """


            CALLER ROLE: EVALUATOR. The caller is grading finished work in a fixed workspace
            directory. It should freely INSPECT and TEST, so APPROVE all of the following:
            - reading and listing the workspace: ls, cat, head, tail, grep, pwd, which, file, and
              find scoped to the workspace;
            - running tests/builds/checks in the workspace — the declared checks \(allow) AND
              reasonable equivalents needed to run them (e.g. a project's own ./venv/bin/python or
              other local test runner when a system interpreter is missing).
            ESCALATE or DENY only genuinely dangerous or out-of-role actions: writing, editing, or
            deleting the work; installing packages; network access; sudo or privilege changes; or
            reading OUTSIDE the workspace (home dotfiles, ~root, ~/.ssh, system paths). The
            evaluator inspects and runs checks; it must not modify the work it is grading.
            """
    }

    /// `vibecopEnabled` overrides the settings gate; nil consults the config, which is what
    /// production always does. Injectable so tests never mutate `ConfigManager.shared`.
    ///
    /// nil when Vibecop is off: no pre-screen, so no decision. Never a stand-in APPROVE — that
    /// let every gated call through unasked on a default install (#334).
    func evaluateAction(toolName: String, details: String, workspace: String?, inSandbox: Bool = false,
                        callerRole: VibecopCallerRole = .agent, allowedCommands: [String] = [],
                        vibecopEnabled: Bool? = nil) async throws -> VibecopDecision? {
        guard vibecopEnabled ?? ConfigManager.shared.enableVibecop else { return nil }
        
        let manager = AuxiliaryModelManager.shared
        
        let engineType = AuxiliaryEngineType(rawValue: ConfigManager.shared.vibecopEngine) ?? .llamaCPP
        let config = AuxiliaryModelConfig(
            role: "vibecop",
            engineType: engineType,
            modelPathOrName: ConfigManager.shared.vibecopModel
        )
        
        let engine = try await manager.getEngine(for: "vibecop", config: config)
        
        var prompt = baselinePrompt
        
        // Incorporate Guardian Prompt if available
        if let ws = workspace {
            // Through `WorkspaceIrisDir.read` (#617): rules behind a link may be the sandbox's.
            if let data = WorkspaceIrisDir.read("vibecop.md", workspace: ws),
               let guardianContent = String(data: data, encoding: .utf8) {
                prompt += "\n\nGUARDIAN MODE ENABLED. Workspace Specific Rules:\n" + guardianContent
            }
        }
        
        if !inSandbox {
            prompt += Self.hostLayerText
        }

        // The VM is thrown away; its mounts are not (#611). The model must not be told otherwise.
        if inSandbox {
            let mounted = workspace.map { "the workspace \($0) (the working directory), and any paths a job grants" }
                ?? "any paths a job grants"
            // Prefixed with the mount, so a name in the list is never read as the VM's own `~`
            // (work's A/B on #613: a bare `.bashrc` escalated the VM's own ~/.bashrc).
            let root = workspace.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? "<mounted folder>/"
            let hostRun = Self.hostRunFiles.map { root + $0 }.joined(separator: ", ")
            prompt += """


            EXECUTION CONTEXT: This command runs inside a disposable, network-capable Linux VM.
            The VM's own home directory (~ and $HOME, which is /root) and everything else in the VM
            outside the mounted folders is thrown away with it, so editing ~/.bashrc or any other
            file under the VM's ~ is routine. Mounted from the user's real Mac, read-write unless
            marked read-only: \(mounted). A write under a mounted folder is a write on the user's
            Mac and outlives the VM. Auto-APPROVE routine work: building, testing, inspecting
            files, editing the project's files, installing packages, editing files under the VM's
            own ~. ESCALATE a write to one of these paths on the Mac, which a Mac program runs or
            reads as configuration: \(hostRun). DENY an obvious attempt to leave code behind for
            the Mac to run. Also reserve ESCALATE/DENY for outbound network connections to
            new/unknown hosts, attempts to escape the container or escalate privilege, or reaching
            host-bridged resources.
            """
        }

        if callerRole == .evaluator {
            prompt += VibecopService.evaluatorLayerText(allowedCommands: allowedCommands)
        }

        prompt += "\n\nProposed Action:\nTool: \(toolName)\nDetails: \(details)"
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let responseJson = try await engine.generate(prompt: prompt, jsonSchema: "vibecop_schema")
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            
            var cleanJson = responseJson
            
            if let startIndex = cleanJson.firstIndex(of: "{"),
               let endIndex = cleanJson.lastIndex(of: "}") {
                cleanJson = String(cleanJson[startIndex...endIndex])
            }
            
            // Parse the JSON
            if let data = cleanJson.data(using: .utf8),
               let decision = try? JSONDecoder().decode(VibecopDecision.self, from: data) {
                PerformanceProfiler.shared.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: durationMs)
                PerformanceProfiler.shared.recordSpan(turnID: PerformanceProfiler.currentTurnID, name: "vibecop", durationMs: durationMs)
                Self.trackLatency(model: config.modelPathOrName, durationMs: durationMs, success: true)
                return decision
            }

            // Fallback to escalation if JSON parsing fails
            print("Vibecop failed to parse JSON: \(responseJson)")
            PerformanceProfiler.shared.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: durationMs)
            PerformanceProfiler.shared.recordSpan(turnID: PerformanceProfiler.currentTurnID, name: "vibecop", durationMs: durationMs)
            Self.trackLatency(model: config.modelPathOrName, durationMs: durationMs, success: false)
            return VibecopDecision(decision: "ESCALATE", reason: "Failed to parse Vibecop response. Defaulting to escalate.")
        } catch {
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            PerformanceProfiler.shared.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: durationMs)
            PerformanceProfiler.shared.recordSpan(turnID: PerformanceProfiler.currentTurnID, name: "vibecop", durationMs: durationMs)
            Self.trackLatency(model: config.modelPathOrName, durationMs: durationMs, success: false)
            throw error
        }
    }

    /// The metrics live on the main actor, and are not awaited: the verdict is bounded
    /// (`AppState.boundedVibecopVerdict`), and a hop to a busy main actor after the engine had
    /// answered turned an instant verdict into a timeout and a person prompt (#634).
    private static func trackLatency(model: String, durationMs: Double, success: Bool) {
        Task { @MainActor in
            MetricsManager.shared.trackLatency(operation: .vibecop, modelName: model, durationMs: durationMs, success: success)
        }
    }
}
