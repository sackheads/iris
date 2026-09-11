import Foundation
import os

struct PluginAuthStatus: Sendable, Equatable {
    let signedIn: Bool
    let output: String
}

/// Orchestrates `kind: external` auth declared in a plugin manifest. Iris never stores these
/// credentials — the tool owns them.
///
/// Both `check_command` and `setup_command` come from an untrusted `plugin.md`, so both pass
/// through `AppState.requestApproval` (PermissionManager fast path → Vibecop → user prompt)
/// before anything executes. `ToolExecutor` itself applies no gate — the gate lives on the
/// agent tool-call path — so the runner invokes it explicitly. `${config:KEY}` values are
/// single-quoted for the shell before substitution, so a saved config value containing `;`
/// or backticks cannot inject into the command. `${keychain:KEY}` references are never
/// resolved here: `secrets: [:]` makes them throw instead of interpolating a credential.
enum PluginAuthRunner {
    /// Approval hook. Defaults to the same gate as an agent-issued `run_command`; tests inject
    /// a stub so they neither prompt nor start Vibecop.
    typealias Approver = @Sendable (String) async -> Bool

    static let defaultApprover: Approver = { command in
        await AppState.shared.requestApproval(
            toolName: "run_command", details: command, origin: "Plugin auth")
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
                      approve: Approver = defaultApprover) async -> PluginAuthStatus {
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
                         approve: Approver = defaultApprover) async -> String {
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
