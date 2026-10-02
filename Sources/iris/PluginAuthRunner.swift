import Foundation
import os

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
              permissions.isAllowed(toolName: "run_command", details: command, workspace: nil) else { return nil }
        return await check(auth, config: config, approve: { _ in true })
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
                      approve: Approver) async -> PluginAuthStatus {
        guard let raw = auth.checkCommand, let command = expandForShell(raw, config: config) else {
            return PluginAuthStatus(signedIn: false, output: "No check_command declared or reference unresolvable")
        }
        guard await approve(command) else {
            return PluginAuthStatus(signedIn: false, output: "check_command not approved: \(command)")
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = BinaryResolver.commandEnvironment(base: ProcessInfo.processInfo.environment)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Drain the pipe concurrently as data arrives. Without this, a check_command
            // writing more than the pipe buffer (64KB) blocks on write before exiting,
            // and since we only read after termination, the process never terminates —
            // deadlock until the 30s timeout fires.
            let collected = OSAllocatedUnfairLock(initialState: Data())
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                collected.withLock { $0.append(chunk) }
            }

            // Safe: DispatchWorkItem.cancel() and Process.terminate() are thread-safe under
            // Foundation; cancel/execute are mutually exclusive here.
            nonisolated(unsafe) let timeout = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

            process.terminationHandler = { p in
                timeout.cancel()
                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = nil
                let trailing = (try? handle.readToEnd()) ?? nil
                var data = collected.withLock { $0 }
                if let trailing {
                    data.append(trailing)
                }
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: PluginAuthStatus(
                    signedIn: p.terminationStatus == 0, output: output))
            }
            do {
                try process.run()
            } catch {
                timeout.cancel()
                continuation.resume(returning: PluginAuthStatus(
                    signedIn: false, output: "Failed to run check: \(error)"))
            }
        }
    }

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
