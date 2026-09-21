import Foundation

enum ContainerRuntimeError: Error, Equatable {
    case launchFailed(String)
    case createFailed(String)
    /// The command outlived its deadline and was killed. `elapsedSeconds` is wall clock from
    /// launch to the child being reaped, so a caller can say how long was actually spent rather
    /// than only how long was allowed.
    case timedOut(elapsedSeconds: Double)
    /// A mount entry that cannot be handed to the CLI without changing what it means.
    case invalidMount(entry: String, reason: String)
}

/// One host directory made visible inside the container.
///
/// Entries stay `String`s rather than a struct because they travel in a job's stored gate and in
/// tool arguments, where a second schema is one more thing for a model to get wrong. The grammar
/// is `source[:target][:ro]`: a bare path mounts at itself, and `ro` makes the mount read-only.
enum ContainerMount {
    /// The value of one `--mount` flag: `type=virtiofs,source=<src>,target=<dst>[,readonly]`,
    /// which is the format `container run --mount` documents.
    ///
    /// Paths are passed through byte for byte. That is safe for every character the CLI's own
    /// parser can read back — `Process` execs the binary directly, so no shell ever sees these,
    /// and a path with a space needs no quoting because it is one argv element. It is *not* safe
    /// for a comma: the flag's value is a comma-separated `key=value` list with no escape, so a
    /// comma inside a path would start a key the CLI does not have. Such an entry is refused
    /// here rather than mangled there.
    static func argument(for entry: String) throws -> String {
        var parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var readOnly = false
        if parts.count > 1, parts.last == "ro" {
            readOnly = true
            parts.removeLast()
        }
        guard parts.count == 1 || parts.count == 2 else {
            throw ContainerRuntimeError.invalidMount(entry: entry, reason: "expected source[:target][:ro]")
        }
        let source = parts[0]
        let target = parts.count == 2 ? parts[1] : source
        guard !source.isEmpty, !target.isEmpty else {
            throw ContainerRuntimeError.invalidMount(entry: entry, reason: "the source and target must both be non-empty")
        }
        guard !source.contains(","), !target.contains(",") else {
            throw ContainerRuntimeError.invalidMount(
                entry: entry,
                reason: "a path containing a comma cannot be expressed as a mount; rename it or mount its parent")
        }
        var spec = "type=virtiofs,source=\(source),target=\(target)"
        if readOnly { spec += ",readonly" }
        return spec
    }
}

/// Seam over the `container` CLI so `SandboxSessionManager` is unit-testable without a real VM.
protocol ContainerRuntime: Sendable {
    /// `container run -d --name <name> [--mount <spec>]… -w <workdir> <image> sleep infinity`
    func createDetached(name: String, image: String, mounts: [String], workdir: String) async throws
    /// `container exec -w <workdir> <name> bash -c <command>`.
    ///
    /// `timeoutSeconds` is a wall-clock deadline for the whole command; past it the CLI process is
    /// killed and `ContainerRuntimeError.timedOut` is thrown. `nil` means no deadline.
    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32)
    /// `container stop <name>` then `container delete <name>` — best-effort, never throws.
    func remove(name: String) async
    /// Names of existing containers whose name starts with `prefix`.
    func list(prefix: String) async -> [String]
}

/// Spawns one child process, bounds it with a deadline, and reaps it.
///
/// Split out of `CLIContainerRuntime` so the deadline can be tested against a child of the test's
/// own — `/bin/sh -c 'sleep …'` — with no `container` binary, daemon or VM in sight.
struct CLIProcessRunner: Sendable {
    let executable: String

    /// How long SIGTERM gets to be polite before SIGKILL settles it.
    static let killGraceSeconds: Double = 2

    /// `Process` is not `Sendable`, and the watchdog below runs on a different task from the one
    /// awaiting the exit. It only reads `isRunning`/`processIdentifier` and calls `terminate()`,
    /// each of which Foundation makes safe to call from another thread.
    private final class Box: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Set by the watchdog before it kills, read after the exit is observed, so the two agree on
    /// whether this was a deadline or an ordinary exit.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() { lock.withLock { fired = true } }
        var didFire: Bool { lock.withLock { fired } }
    }

    /// SIGKILLs the direct children of `pid`, which must still be alive (a reaped pid can be
    /// reused, and this would then signal a stranger's children). Direct children only — the same
    /// reach the host `run_command` path has.
    private static func killChildren(of pid: pid_t) {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-9", "-P", String(pid)]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()      // milliseconds, and the SIGKILL below must not overtake it
    }

    func run(_ arguments: [String], timeoutSeconds: Int? = nil) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Nothing types at these: a sandboxed command that reads stdin gets EOF rather than
        // inheriting the app's and blocking until its deadline.
        process.standardInput = FileHandle.nullDevice

        let box = Box(process)
        let deadline = Deadline()
        let started = Date()

        // The watchdog kills; it never abandons. Racing the wait with a `withTimeout` and walking
        // away would leave the child running and unreaped — a zombie holding a pid and, for
        // `container exec`, a live connection to the VM. It is a separate task rather than a
        // `waitUntilExit()` with a timer because a cooperative-pool thread must not be parked in
        // a blocking wait.
        let watchdog: Task<Void, Never>? = timeoutSeconds.map { seconds in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                guard !Task.isCancelled, box.process.isRunning else { return }
                deadline.fire()
                let pid = box.process.processIdentifier
                // Children first. They inherited the pipes, so one left alive holds
                // `readDataToEndOfFile` below open for as long as it lives — and a deadline that
                // returns when some grandchild feels like it is not a deadline. Sent while the
                // child is known to be alive, so its pid cannot have been recycled under us.
                Self.killChildren(of: pid)
                box.process.terminate()                                     // SIGTERM
                try? await Task.sleep(nanoseconds: UInt64(Self.killGraceSeconds * 1_000_000_000))
                guard box.process.isRunning else { return }
                Self.killChildren(of: pid)                                  // anything it spawned since
                kill(pid, SIGKILL)
            }
        }
        defer { watchdog?.cancel() }

        let result: (stdout: String, stderr: String, exitCode: Int32) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Installed before `run()`: a process that exits first would never call a handler
                // attached after the fact, and this continuation would never resume.
                process.terminationHandler = { proc in
                    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(returning: (o, e, proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: ContainerRuntimeError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }

        if deadline.didFire {
            throw ContainerRuntimeError.timedOut(elapsedSeconds: Date().timeIntervalSince(started))
        }
        return result
    }
}

struct CLIContainerRuntime: ContainerRuntime {
    /// One spawn of the `container` CLI: the argv, and the deadline the command is allowed.
    /// Injectable so a test can assert what a call renders without a binary, a daemon or a VM.
    typealias Launch = @Sendable (_ arguments: [String], _ timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32)

    /// The real thing: the installed `container` binary, resolved per call because it can be
    /// installed while the app is running.
    static let spawnCLI: Launch = { arguments, timeoutSeconds in
        let binary = SandboxingManager.shared.containerBinaryPath ?? "/usr/local/bin/container"
        return try await CLIProcessRunner(executable: binary).run(arguments, timeoutSeconds: timeoutSeconds)
    }

    private let launch: Launch

    init(launch: @escaping Launch = CLIContainerRuntime.spawnCLI) {
        self.launch = launch
    }

    func createDetached(name: String, image: String, mounts: [String], workdir: String) async throws {
        var args = ["run", "-d", "--name", name]
        // Rendered before anything is spawned, so a mount the CLI could not read refuses the
        // container rather than producing one with a mount missing.
        for entry in mounts {
            args += ["--mount", try ContainerMount.argument(for: entry)]
        }
        args += ["-w", workdir, image, "sleep", "infinity"]
        // No deadline: a cold create pulls the image, which can legitimately take minutes.
        let r = try await launch(args, nil)
        if r.exitCode != 0 {
            throw ContainerRuntimeError.createFailed((r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await launch(["exec", "-w", workdir, name, "bash", "-c", command], timeoutSeconds)
    }

    func remove(name: String) async {
        _ = try? await launch(["stop", name], nil)
        _ = try? await launch(["delete", name], nil)
    }

    func list(prefix: String) async -> [String] {
        guard let r = try? await launch(["list", "-a", "--format", "json"], nil),
              let data = r.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        // Each entry's identifier may be under "configuration.id" or top-level "id"/"name".
        return arr.compactMap { entry -> String? in
            if let id = entry["id"] as? String { return id }
            if let cfg = entry["configuration"] as? [String: Any], let id = cfg["id"] as? String { return id }
            return entry["name"] as? String
        }.filter { $0.hasPrefix(prefix) }
    }
}
