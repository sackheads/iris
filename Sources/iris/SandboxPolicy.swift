import Foundation

/// Whether a principal's `run_command` runs in a sandbox container or on the host.
public enum SandboxPref: String, Codable, Sendable {
    case host
    case sandboxed
}

/// Who is running: the user-facing main agent, an isolated subagent, or a goal-drift evaluator.
public enum Principal: Sendable {
    case main
    case subagent
    case evaluator
}

/// The routing outcome for one command.
public enum SandboxDecision: Equatable, Sendable {
    case sandboxed
    /// Runs on the host. `warnNoRuntime` is true when a sandbox was intended but the runtime
    /// was unavailable (the caller should surface a one-time notice).
    case host(warnNoRuntime: Bool)
}

public enum SandboxPolicy {
    /// Whether a `mutating` job (#187 §0.2) has a VM to run in: the container runtime installed
    /// AND the master switch on. Both halves, because `resolve` below returns `.host` the moment
    /// `masterEnabled` is false — without even the missing-runtime warning — so a job pinned
    /// `.sandboxed` on a machine with sandboxing off runs unsandboxed and says nothing. Asked at
    /// creation (`ScheduleJobArguments.makeJob`) and again at every fire, in `JobRunner.run`: a
    /// check made once, on a thing that fires forever, only describes the day it was made.
    ///
    /// Where in `run` matters. The re-check sits *after* `ledger.begin` and `setLastRun`, so a
    /// refused fire is a real fire: it has a `failed` row with the reason `sandbox unavailable`, it
    /// bumps the job's `lastRun`, and it counts towards the breaker and the retry ladder like any
    /// other failure. That is the intended shape — a job whose VM has gone should be visible in
    /// `/jobs` and should pause itself rather than retry forever — but it does mean the refusal
    /// costs the job a slot in its hourly allowance.
    static func mutatingJobCanRun(config: ConfigManager = .shared,
                                  runtimeAvailable: Bool = SandboxingManager.shared.isContainerInstalled) -> Bool {
        config.enableSandboxing && runtimeAvailable
    }

    /// Pure resolution — no I/O. See the plan's Global Constraints for the cascade.
    public static func resolve(masterEnabled: Bool,
                               principal: Principal,
                               perConversation: SandboxPref?,
                               perWorkspace: SandboxPref?,
                               globalDefault: SandboxPref,
                               runtimeAvailable: Bool) -> SandboxDecision {
        guard masterEnabled else { return .host(warnNoRuntime: false) }

        let intended: SandboxPref
        switch principal {
        case .subagent, .evaluator:
            intended = .sandboxed
        case .main:
            intended = perConversation ?? perWorkspace ?? globalDefault
        }

        switch intended {
        case .sandboxed:
            return runtimeAvailable ? .sandboxed : .host(warnNoRuntime: true)
        case .host:
            return .host(warnNoRuntime: false)
        }
    }

    // MARK: - Per-workspace override (<workspace>/.iris/sandbox.json)

    private struct WorkspaceConfig: Codable { let mainAgent: SandboxPref }

    private static func url(for workspace: String) -> URL {
        URL(fileURLWithPath: workspace)
            .appendingPathComponent(".iris")
            .appendingPathComponent("sandbox.json")
    }

    public static func perWorkspaceOverride(workspace: String?) -> SandboxPref? {
        guard let workspace,
              let data = try? Data(contentsOf: url(for: workspace)),
              let cfg = try? JSONDecoder().decode(WorkspaceConfig.self, from: data) else {
            return nil
        }
        return cfg.mainAgent
    }

    @discardableResult
    public static func setWorkspaceOverride(_ pref: SandboxPref?, for workspace: String) -> Bool {
        let fileURL = url(for: workspace)
        guard let pref else {
            // clear: success if the file is gone afterward (removing an absent file is still "cleared")
            try? FileManager.default.removeItem(at: fileURL)
            return !FileManager.default.fileExists(atPath: fileURL.path)
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(WorkspaceConfig(mainAgent: pref))
            try data.write(to: fileURL)
            return true
        } catch {
            return false
        }
    }
}
