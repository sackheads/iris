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
        return await fireEvent(eventName: "BeforeModel", targetMatcher: "BeforeModel", payload: Self.beforeModelPayload(request), useSandbox: useSandbox)
    }

    /// What a `BeforeModel` hook reads on stdin. Split out so a test can pin it without a hook.
    static func beforeModelPayload(_ request: GeminiRequest) -> Data? {
        try? JSONEncoder().encode(request)
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
    
    /// How long a hook gets when its definition sets no `timeout`.
    static let defaultTimeoutSeconds = 60

    private func executeCommandHook(hook: HookDefinition, payload: Data?, useSandbox: Bool = false) async -> HookDecision {
        let executable: String
        let arguments: [String]
        // Named, so a timeout or a cancel can delete it: killing the `container run` client does
        // not stop the container (#353).
        var ephemeralContainer: (binary: String, name: String)? = nil
        if useSandbox {
            guard let containerPath = SandboxingManager.shared.containerBinaryPath else {
                return .block(reason: "Sandboxing enabled but container missing for hook execution.")
            }
            let name = "iris-hook-\(UUID().uuidString.lowercased())"
            ephemeralContainer = (containerPath, name)
            executable = containerPath
            arguments = ["run", "--rm", "--name", name, ConfigManager.shared.sandboxImage, "bash", "-c", hook.command]
        } else {
            executable = "/bin/zsh"
            arguments = ["-c", hook.command]
        }
        let timeout = hook.timeout ?? Self.defaultTimeoutSeconds
        // It carries `SandboxSessionManager.namePrefix`, so the launch sweep would take it for an
        // orphan; registered for its whole life, and one a crash left behind is still swept.
        if let ephemeralContainer { await EphemeralContainerRegistry.shared.register(ephemeralContainer.name) }
        let outcome = await Self.runHookProcess(executable: executable, arguments: arguments,
                                                payload: payload, timeoutSeconds: Double(timeout))
        if let ephemeralContainer {
            let binary = ephemeralContainer.binary, name = ephemeralContainer.name
            if Task.isCancelled || (try? outcome.get())?.timedOut == true {
                Task {
                    _ = try? await CLIProcessRunner(executable: binary)
                        .run(["delete", "--force", name], timeoutSeconds: CLIContainerRuntime.housekeepingTimeoutSeconds)
                    await EphemeralContainerRegistry.shared.unregister(name)
                }
            } else {
                await EphemeralContainerRegistry.shared.unregister(name)
            }
        }
        // A cancel kills the hook, so its verdict never arrived: fail closed, or a hook that would
        // have blocked lets the tool through as a warning (#364 review).
        if Task.isCancelled { return Self.cancelledDecision }
        return Self.decision(for: outcome, timeoutSeconds: timeout)
    }

    static let cancelledDecision = HookDecision.block(reason: "cancelled before the hook decided")

    /// Spawns one hook in a process group of its own (#364): the payload goes in on stdin while
    /// stdout and stderr drain, so neither side can fill a pipe and stall; on timeout or cancel
    /// the whole group gets SIGTERM, then SIGKILL; and a background job the hook left holding its
    /// pipes cannot keep the turn waiting. Secrets are scrubbed and the login-shell PATH applied.
    static func runHookProcess(executable: String, arguments: [String], payload: Data?,
                               timeoutSeconds: Double) async -> Result<ProcessGroupRunner.Output, Error> {
        var env = ProcessInfo.processInfo.environment
        for key in sensitiveEnvKeys {
            env.removeValue(forKey: key)
        }
        env["GEMINI_CWD"] = FileManager.default.currentDirectoryPath
        env = BinaryResolver.commandEnvironment(base: env)
        return await ProcessGroupRunner.capture(executable: executable, arguments: arguments, environment: env,
                                                stdin: payload, timeoutSeconds: timeoutSeconds)
    }

    /// Exit 2 blocks with stderr as the reason; exit 0 proceeds, with stdout as the new payload
    /// when it is JSON; anything else is a warning.
    static func decision(for outcome: Result<ProcessGroupRunner.Output, Error>, timeoutSeconds: Int) -> HookDecision {
        let output: ProcessGroupRunner.Output
        switch outcome {
        case .success(let o): output = o
        case .failure(is CancellationError):
            return cancelledDecision
        case .failure(let error):
            return .warning(message: "Failed to spawn hook: \(error.localizedDescription)")
        }
        if output.status == 2 {
            let reason = String(data: output.stderr, encoding: .utf8) ?? "Unknown hook error"
            return .block(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if output.status == 0 {
            // Try parsing output as JSON to enforce the rule
            if output.stdout.isEmpty {
                return .proceed(modifiedData: nil)
            } else if (try? JSONSerialization.jsonObject(with: output.stdout)) != nil {
                return .proceed(modifiedData: output.stdout)
            } else {
                // Pollution = Warning/Failure, treated as proceed for now
                return .warning(message: "Hook output was not valid JSON")
            }
        } else if output.timedOut {
            return .warning(message: "Hook timed out after \(timeoutSeconds) seconds")
        } else {
            return .warning(message: "Hook exited with status \(output.status)")
        }
    }
}

/// The one-off containers in flight — a sandboxed hook's `iris-hook-*` and a session-less
/// `run_command`'s `iris-run-*` — which `SandboxSessionManager.reapOrphans` spares the way it
/// spares live sessions and gates (`GateContainerRegistry`). A snapshot, like that one.
actor EphemeralContainerRegistry {
    static let shared = EphemeralContainerRegistry()

    private var names: Set<String> = []

    func register(_ name: String) { names.insert(name) }
    func unregister(_ name: String) { names.remove(name) }
    func current() -> Set<String> { names }
}
