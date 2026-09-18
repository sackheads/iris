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
    
    You MUST output valid JSON only, exactly matching this schema:
    {
      "decision": "APPROVE" | "ESCALATE" | "DENY",
      "reason": "Short explanation of your verdict"
    }
    """
    
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
    func evaluateAction(toolName: String, details: String, workspace: String?, inSandbox: Bool = false,
                        callerRole: VibecopCallerRole = .agent, allowedCommands: [String] = [],
                        vibecopEnabled: Bool? = nil) async throws -> VibecopDecision {
        guard vibecopEnabled ?? ConfigManager.shared.enableVibecop else {
            return VibecopDecision(decision: "APPROVE", reason: "Vibecop is disabled in settings.")
        }
        
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
            let guardianPath = URL(fileURLWithPath: ws).appendingPathComponent(".iris/vibecop.md").path
            if let guardianContent = try? String(contentsOfFile: guardianPath, encoding: .utf8) {
                prompt += "\n\nGUARDIAN MODE ENABLED. Workspace Specific Rules:\n" + guardianContent
            }
        }
        
        if inSandbox {
            prompt += """


            EXECUTION CONTEXT: This command runs inside a disposable, network-capable Linux VM
            fully isolated from the macOS host filesystem. Auto-APPROVE routine in-VM work
            (building, testing, inspecting files, installing packages). Reserve ESCALATE/DENY for
            genuinely risky actions: outbound network connections to new/unknown hosts, attempts
            to escape the container or escalate privilege, or reaching host-bridged resources.
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
                await MetricsManager.shared.trackLatency(operation: .vibecop, modelName: config.modelPathOrName, durationMs: durationMs, success: true)
                PerformanceProfiler.shared.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: durationMs)
                PerformanceProfiler.shared.recordSpan(turnID: PerformanceProfiler.currentTurnID, name: "vibecop", durationMs: durationMs)
                return decision
            }

            // Fallback to escalation if JSON parsing fails
            print("Vibecop failed to parse JSON: \(responseJson)")
            await MetricsManager.shared.trackLatency(operation: .vibecop, modelName: config.modelPathOrName, durationMs: durationMs, success: false)
            PerformanceProfiler.shared.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: durationMs)
            PerformanceProfiler.shared.recordSpan(turnID: PerformanceProfiler.currentTurnID, name: "vibecop", durationMs: durationMs)
            return VibecopDecision(decision: "ESCALATE", reason: "Failed to parse Vibecop response. Defaulting to escalate.")
        } catch {
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            await MetricsManager.shared.trackLatency(operation: .vibecop, modelName: config.modelPathOrName, durationMs: durationMs, success: false)
            PerformanceProfiler.shared.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: durationMs)
            PerformanceProfiler.shared.recordSpan(turnID: PerformanceProfiler.currentTurnID, name: "vibecop", durationMs: durationMs)
            throw error
        }
    }
}
