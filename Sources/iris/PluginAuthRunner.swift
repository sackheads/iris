import Foundation

struct PluginAuthStatus: Sendable, Equatable {
    let signedIn: Bool
    let output: String
}

/// Orchestrates `kind: external` auth declared in a plugin manifest. Iris never stores these
/// credentials — the tool owns them.
///
/// Both `check_command` and `setup_command` come from an untrusted `plugin.md`, so neither runs
/// without consent, and every caller must say whose (`approve` has no default). The settings pane
/// is not the chat window, where the approval queue renders, so it never asks through that
/// queue: a prompt raised there parked the pane until the user found the banner (#336). Instead
/// the pane shows each command in full and runs it when the user clicks the button beside it —
/// the click is the consent (`userClicked`) — and on open it refreshes the status only for a
/// `check_command` an "Always allow" rule already permits (`statusOnOpen`). `ToolExecutor` itself
/// applies no gate — the gate lives on the agent tool-call path — so the runner applies it. `${config:KEY}` values are
/// single-quoted for the shell before substitution, so a saved config value containing `;`
/// or backticks cannot inject into the command. `${keychain:KEY}` references are never
/// resolved here: `secrets: [:]` makes them throw instead of interpolating a credential.
enum PluginAuthRunner {
    /// Approval hook: true lets the expanded command run.
    typealias Approver = @Sendable (String) async -> Bool

    /// The user clicked the button beside the command, which the pane shows in full. Never used
    /// for a command with hidden characters: the pane disables the button for those.
    static let userClicked: Approver = { _ in true }

    /// The commands exactly as they would run, for the pane to show beside its buttons. nil when
    /// none is declared or a reference does not resolve (then nothing runs either).
    static func displayCommands(_ auth: IPFManifest.AuthDeclaration,
                                config: [String: String]) -> (check: String?, setup: String?) {
        (auth.checkCommand.flatMap { expandForShell($0, config: config) },
         auth.setupCommand.flatMap { expandForShell($0, config: config) })
    }

    /// The status row on open, with nobody asked: the check runs only when an "Always allow" rule
    /// already permits that exact command. nil means "not checked" — the pane offers its button.
    static func statusOnOpen(_ auth: IPFManifest.AuthDeclaration, config: [String: String],
                             permissions: PermissionManager) async -> PluginAuthStatus? {
        guard let command = displayCommands(auth, config: config).check,
              !command.containsHiddenCharacters,
              isAlwaysAllowed(command, permissions: permissions) else { return nil }
        return await check(auth, config: config, approve: { _ in true })
    }

    /// Whether `command` already has a global "Always allow" rule for `run_command` — the same
    /// rule `statusOnOpen` consults to decide whether to run unasked.
    static func isAlwaysAllowed(_ command: String, permissions: PermissionManager) -> Bool {
        permissions.isAllowed(toolName: "run_command", details: command, workspace: nil)
    }

    /// Writes the rule the pane's "Always allow this command" checkbox grants, through the same
    /// `permissions.allowGlobally` path the chat window's "Always Allow (Global)" button uses
    /// (#338). Only a `check_command` gets this checkbox — `setup_command` changes state (it
    /// signs in), so it always needs a click — and a command with hidden characters is refused
    /// even if `requested` is true, the same rule `runnable` applies to the Check button itself
    /// (#336). `command` is nil when nothing is declared or a reference does not resolve, in
    /// which case there is nothing to allow. Returns whether a rule was written.
    ///
    /// Unchecking the box does not retract a rule written on an earlier click:
    /// `PermissionManager` has no removal API (it only ever appends to `permissions.json`), so
    /// there is nothing here to call. Revoking an existing "Always allow" rule is left to the
    /// permissions UI that already owns that file, once one exists.
    @discardableResult
    static func applyAlwaysAllow(command: String?, requested: Bool, permissions: PermissionManager) -> Bool {
        guard requested, let command, !command.containsHiddenCharacters else { return false }
        permissions.allowGlobally(toolName: "run_command", details: command)
        return true
    }

    /// Single-quotes a value for `/bin/sh` so it is always one literal word.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Expands `${config:}` references with each value shell-quoted. Returns nil when a
    /// reference is unresolvable (including any `${keychain:}` reference).
    static func expandForShell(_ raw: String, config: [String: String]) -> String? {
        try? PluginReferences.expand(raw, config: config.mapValues(shellQuoted), secrets: [:])
    }

    static func check(_ auth: IPFManifest.AuthDeclaration, config: [String: String],
                      approve: Approver, timeoutSeconds: Double = checkTimeoutSeconds) async -> PluginAuthStatus {
        guard let raw = auth.checkCommand, let command = expandForShell(raw, config: config) else {
            return PluginAuthStatus(signedIn: false, output: "No check_command declared or reference unresolvable")
        }
        guard await approve(command) else {
            return PluginAuthStatus(signedIn: false, output: "check_command not approved: \(command)")
        }
        // A process group of its own (#364): output drains as it is written and is read only after
        // the reap, so nothing written right before exit can be lost (#368); on timeout the group
        // gets SIGTERM, then SIGKILL; a background job left holding the pipe cannot hang the pane.
        let outcome = await ProcessGroupRunner.capture(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: BinaryResolver.commandEnvironment(base: ProcessInfo.processInfo.environment),
            mergeStderr: true, timeoutSeconds: timeoutSeconds)
        switch outcome {
        case .success(let output):
            return PluginAuthStatus(signedIn: output.status == 0,
                                    output: String(data: output.stdout, encoding: .utf8) ?? "")
        case .failure(let error):
            return PluginAuthStatus(signedIn: false, output: "Failed to run check: \(error)")
        }
    }

    /// How long a `check_command` gets before its group is killed and the status is signed out.
    static let checkTimeoutSeconds: Double = 30

    static func runSetup(_ auth: IPFManifest.AuthDeclaration, config: [String: String],
                         approve: Approver) async -> String {
        guard let raw = auth.setupCommand, let command = expandForShell(raw, config: config) else {
            return "No setup_command declared or reference unresolvable"
        }
        guard await approve(command) else {
            return "setup_command not approved: \(command)"
        }
        return await ToolExecutor().execute(
            name: "run_command",
            args: ["command": .string(command)],
            useSandbox: false)
    }
}
