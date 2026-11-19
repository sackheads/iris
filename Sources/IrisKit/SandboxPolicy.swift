import Foundation

/// Whether a principal's `run_command` runs in a sandbox container or on the host.
public enum SandboxPref: String, Codable, Sendable {
    case host
    case sandboxed
}

/// Who is running: the user-facing main agent, an isolated subagent, a goal-drift evaluator, an
/// external MCP guest's own confined session (#1066), or the disclosure broker (#974 H2, an
/// owner-memory-read-only, zero-acting-tools run). A guest runs the two-tool `GuestToolset` floor
/// and nothing else; the broker's floor is `PrincipalFloor.brokerTools` and nothing else (today
/// unreachable — nothing constructs a `.broker` engine yet, #1201 review). Neither is ever `.main`,
/// and no `!= .main` site may treat either as a subagent.
public enum Principal: Sendable {
    case main
    case subagent
    case evaluator
    case mcpGuest
    case broker
}

/// The routing outcome for one command.
public enum SandboxDecision: Equatable, Sendable {
    case sandboxed
    /// Runs on the host. `warnNoRuntime` is true when a sandbox was intended but the runtime
    /// was unavailable (the caller should surface a one-time notice).
    case host(warnNoRuntime: Bool)
    /// #974 C1: a non-owner binding needs the sandbox and there is no container runtime to give it.
    /// It is never `.host`: the caller refuses the command with this reason.
    case refused(reason: String)
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

    /// Why a non-owner command is refused when there is no container runtime (#974 C1).
    public static let nonOwnerNoRuntimeReason = "this run is not the owner's, so a command runs only in the sandbox, and no container runtime is available"

    /// Pure resolution — no I/O. See the plan's Global Constraints for the cascade.
    ///
    /// `isOwner` is the run's binding (#974 Task 5), never the Principal alone: a subagent on the
    /// owner's binding is the owner (Invariant 1), and a `.main` dropped to a named profile is not.
    /// A non-owner executes only in the sandbox (C1): the master switch and every per-conversation,
    /// per-workspace and global preference are ignored, and with no container runtime the result is
    /// `.refused`, never `.host`. The owner keeps the cascade below, unchanged. No default for
    /// `isOwner`: a caller must say which it is.
    public static func resolve(masterEnabled: Bool,
                               principal: Principal,
                               isOwner: Bool,
                               perConversation: SandboxPref?,
                               perWorkspace: SandboxPref?,
                               globalDefault: SandboxPref,
                               runtimeAvailable: Bool) -> SandboxDecision {
        guard isOwner else {
            return runtimeAvailable ? .sandboxed : .refused(reason: nonOwnerNoRuntimeReason)
        }
        guard masterEnabled else { return .host(warnNoRuntime: false) }

        let intended: SandboxPref
        switch principal {
        case .subagent, .evaluator, .mcpGuest, .broker:
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

    /// Only a `sandbox.json` Iris wrote or a person trusted (#625): one the VM planted in a nested
    /// `.iris/`, or a cloned repository shipped, would otherwise turn the sandbox off.
    static func perWorkspaceOverride(workspace: String?, trust: WorkspaceIrisTrust = WorkspaceIrisTrust()) -> SandboxPref? {
        guard let workspace,
              let data = WorkspaceIrisDir.read("sandbox.json", workspace: workspace, trust: trust),   // #617, #625
              let cfg = try? JSONDecoder().decode(WorkspaceConfig.self, from: data) else {
            return nil
        }
        return cfg.mainAgent
    }

    @discardableResult
    static func setWorkspaceOverride(_ pref: SandboxPref?, for workspace: String,
                                     trust: WorkspaceIrisTrust = WorkspaceIrisTrust()) -> Bool {
        let fileURL = url(for: workspace)
        guard let pref else {
            // clear: success if the file is gone afterward (removing an absent file is still "cleared")
            try? FileManager.default.removeItem(at: fileURL)
            trust.record("sandbox.json", workspace: workspace, data: nil)
            return !FileManager.default.fileExists(atPath: fileURL.path)
        }
        do {
            // A real `.iris/` only, written by rename (#617): see `PermissionManager.saveRules`.
            guard case .ready = WorkspaceIrisDir.prepareForMount(IrisEngine.expandTilde(workspace)) else { return false }
            let data = try JSONEncoder().encode(WorkspaceConfig(mainAgent: pref))
            try data.write(to: fileURL, options: .atomic)
            // Iris wrote it, so Iris trusts it (#625).
            trust.recordWritten("sandbox.json", workspace: workspace, written: data)
            return true
        } catch {
            return false
        }
    }
}
