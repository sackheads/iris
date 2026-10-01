import Foundation

struct HookConfig: Codable {
    let hooks: [String: [HookEvent]]
}

struct HookEvent: Codable {
    let matcher: String
    let hooks: [HookDefinition]
}

struct HookDefinition: Codable {
    let name: String?
    let type: String
    let command: String
    let timeout: Int?
    let description: String?
}

enum HookDecision {
    case proceed(modifiedData: Data?)
    case block(reason: String)
    case warning(message: String)
}

struct HookManager {
    static let shared = HookManager()

    /// Environment variables scrubbed before spawning any hook process so that
    /// provider API keys and Google OAuth secrets never leak into hook scripts.
    static let sensitiveEnvKeys: [String] = [
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_CLIENT_ID",
        "GOOGLE_CLIENT_SECRET",
        "GOOGLE_ACCESS_TOKEN",
        "GOOGLE_REFRESH_TOKEN",
    ]

    var configPathOverride: String?
    
    private var configPath: String {
        configPathOverride ?? IrisPaths.default.settingsJSON.path
    }
    
    private var config: HookConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else { return nil }
        return try? JSONDecoder().decode(HookConfig.self, from: data)
    }
    
    // `useSandbox` is the caller's principal-based sandbox decision for command hooks: the main
    // agent forwards its resolved host-vs-sandboxed policy; subagents forward `true`. It is
    // threaded per-call (never stored) because the shared singleton fires hooks for concurrent
    // main/subagent turns. Defaults to `false` (host) for callers without a principal context
    // (e.g. SessionStart at conversation creation).
    func fireBeforeTool(toolName: String, args: [String: JSONValue], useSandbox: Bool = false) async -> HookDecision {
        return await fireEvent(eventName: "BeforeTool", targetMatcher: toolName, payload: try? JSONEncoder().encode(args), useSandbox: useSandbox)
    }

    func fireAfterTool(toolName: String, result: String, useSandbox: Bool = false) async -> HookDecision {
        let payload = ["result": result]
        return await fireEvent(eventName: "AfterTool", targetMatcher: toolName, payload: try? JSONSerialization.data(withJSONObject: payload), useSandbox: useSandbox)
    }

    func fireBeforeAgent(input: String, useSandbox: Bool = false) async -> HookDecision {
        let payload = ["input": input]
        return await fireEvent(eventName: "BeforeAgent", targetMatcher: "BeforeAgent", payload: try? JSONSerialization.data(withJSONObject: payload), useSandbox: useSandbox)
    }

    func fireBeforeModel(request: GeminiRequest, useSandbox: Bool = false) async -> HookDecision {
        return await fireEvent(eventName: "BeforeModel", targetMatcher: "BeforeModel", payload: try? JSONEncoder().encode(request), useSandbox: useSandbox)
    }

    func fireAfterModel(response: GeminiResponse, useSandbox: Bool = false) async -> HookDecision {
        return await fireEvent(eventName: "AfterModel", targetMatcher: "AfterModel", payload: try? JSONEncoder().encode(response), useSandbox: useSandbox)
    }

    func fireBeforeToolSelection(tools: [FunctionDeclaration], useSandbox: Bool = false) async -> HookDecision {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        return await fireEvent(eventName: "BeforeToolSelection", targetMatcher: "BeforeToolSelection", payload: try? encoder.encode(tools), useSandbox: useSandbox)
    }

    func firePreCompress(history: [Content], useSandbox: Bool = false) async -> HookDecision {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        return await fireEvent(eventName: "PreCompress", targetMatcher: "PreCompress", payload: try? encoder.encode(history), useSandbox: useSandbox)
    }

    func fireNotification(title: String, body: String, useSandbox: Bool = false) async {
        let payload = ["title": title, "body": body]
        _ = await fireEvent(eventName: "Notification", targetMatcher: "Notification", payload: try? JSONSerialization.data(withJSONObject: payload), useSandbox: useSandbox)
    }

    func fireSessionStart(conversationId: UUID, useSandbox: Bool = false) async -> HookDecision {
        let payload = ["conversationId": conversationId.uuidString]
        return await fireEvent(eventName: "SessionStart", targetMatcher: "SessionStart", payload: try? JSONSerialization.data(withJSONObject: payload), useSandbox: useSandbox)
    }

    func fireAfterAgent(output: String, useSandbox: Bool = false) async -> HookDecision {
        let payload = ["output": output]
        return await fireEvent(eventName: "AfterAgent", targetMatcher: "AfterAgent", payload: try? JSONSerialization.data(withJSONObject: payload), useSandbox: useSandbox)
    }

    private func fireEvent(eventName: String, targetMatcher: String, payload: Data?, useSandbox: Bool = false) async -> HookDecision {
        guard let config = config, let eventHooks = config.hooks[eventName] else {
            return .proceed(modifiedData: nil) // No hooks registered — not counted
        }
        let __turnID = PerformanceProfiler.currentTurnID
        let __start = CFAbsoluteTimeGetCurrent()
        defer {
            PerformanceProfiler.shared.record(turnID: __turnID, category: .hooks,
                                              durationMs: (CFAbsoluteTimeGetCurrent() - __start) * 1000.0)
        }

        var currentData = payload
        
        for eventConfig in eventHooks {
            // Check regex matcher
            guard let regex = try? NSRegularExpression(pattern: eventConfig.matcher),
                  regex.firstMatch(in: targetMatcher, range: NSRange(targetMatcher.startIndex..., in: targetMatcher)) != nil else {
                continue
            }
            
            for hook in eventConfig.hooks {
                if hook.type != "command" { continue }
                
                let decision = await executeCommandHook(hook: hook, payload: currentData, useSandbox: useSandbox)
                switch decision {
                case .block:
                    return decision // Immediate hard block
                case .proceed(let modifiedData):
                    if let new = modifiedData {
                        currentData = new // Pass modified data to next hook
                    }
                case .warning:
                    // Treat as proceed, could log warning
                    break
                }
            }
        }
        
        return .proceed(modifiedData: currentData)
    }
    
    private func executeCommandHook(hook: HookDefinition, payload: Data?, useSandbox: Bool = false) async -> HookDecision {
        return await withCheckedContinuation { continuation in
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            if useSandbox {
                guard let containerPath = SandboxingManager.shared.containerBinaryPath else {
                    continuation.resume(returning: .block(reason: "Sandboxing enabled but container missing for hook execution."))
                    return
                }
                process.executableURL = URL(fileURLWithPath: containerPath)
                process.arguments = ["run", "--rm", ConfigManager.shared.sandboxImage, "bash", "-c", hook.command]
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", hook.command]
            }
            
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            var env = ProcessInfo.processInfo.environment
            for key in HookManager.sensitiveEnvKeys {
                env.removeValue(forKey: key)
            }
            env["GEMINI_CWD"] = FileManager.default.currentDirectoryPath
            env = BinaryResolver.commandEnvironment(base: env)
            process.environment = env
            
            if let data = payload {
                inputPipe.fileHandleForWriting.write(data)
                try? inputPipe.fileHandleForWriting.close()
            }
            
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(hook.timeout ?? 60) * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }
            
            process.terminationHandler = { proc in
                timeoutTask.cancel()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                
                if proc.terminationStatus == 2 {
                    let reason = String(data: errorData, encoding: .utf8) ?? "Unknown hook error"
                    continuation.resume(returning: .block(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else if proc.terminationStatus == 0 {
                    // Try parsing output as JSON to enforce the rule
                    if outputData.isEmpty {
                        continuation.resume(returning: .proceed(modifiedData: nil))
                    } else if (try? JSONSerialization.jsonObject(with: outputData)) != nil {
                        continuation.resume(returning: .proceed(modifiedData: outputData))
                    } else {
                        // Pollution = Warning/Failure, treated as proceed for now
                        continuation.resume(returning: .warning(message: "Hook output was not valid JSON"))
                    }
                } else {
                    continuation.resume(returning: .warning(message: "Hook exited with status \(proc.terminationStatus)"))
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .warning(message: "Failed to spawn hook: \(error.localizedDescription)"))
            }
        }
    }
}
