import Foundation

enum ContainerRuntimeError: Error, Equatable {
    case launchFailed(String)
    case createFailed(String)
    /// The command outlived its deadline and was killed. `elapsedSeconds` is wall clock from
    /// launch to the kill ladder finishing — a diagnostic, not the number anybody is told: both
    /// routes report the *allowance*, so a timed-out command reads the same in the container as
    /// on the host.
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
    /// for the two characters the directive list is punctuated with: a comma starts the next
    /// directive and an `=` separates a key from its value, and the format has no escape for
    /// either. Such an entry is refused here rather than mangled there.
    ///
    /// Both paths must be absolute. A source that is not is read by the CLI as the name of a
    /// *volume* rather than a directory to bind, so `data:/data` would quietly look up something
    /// else entirely instead of failing.
    ///
    /// What is not checked here, because only the daemon can answer it: the source must exist and
    /// be a directory. A single file cannot be mounted this way — mount its parent. That surfaces
    /// as a `createFailed` from the CLI.
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
        guard source.hasPrefix("/"), target.hasPrefix("/") else {
            throw ContainerRuntimeError.invalidMount(
                entry: entry,
                reason: "both paths must be absolute; a relative source is read as the name of a volume, not a directory")
        }
        let punctuation = CharacterSet(charactersIn: ",=")
        guard source.rangeOfCharacter(from: punctuation) == nil,
              target.rangeOfCharacter(from: punctuation) == nil else {
            throw ContainerRuntimeError.invalidMount(
                entry: entry,
                reason: "a path containing a comma or an equals sign cannot be expressed as a mount; rename it or mount its parent")
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

    /// How long the ordinary exit path gets, after the kill ladder, to deliver the real output
    /// before the ladder's own answer is returned instead.
    static let postKillSettleSeconds: Double = 0.25

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

    /// Reads the child's output as it arrives and answers the caller exactly once.
    ///
    /// Incremental, because the obvious alternative — one `readDataToEndOfFile` when the child
    /// exits — hands the schedule to whoever holds the write end. A process that inherited it and
    /// outlived everything we can signal blocks that read for as long as it lives, which is a
    /// deadline that expires whenever a stranger says so; and a child that writes more than the
    /// pipe buffer never exits at all, because nobody is emptying it.
    ///
    /// "Exactly once" is the other half: the deadline resumes the caller itself when the ordinary
    /// path has not, and a late exit must then find the answer already given.
    private final class Collector: @unchecked Sendable {
        typealias Output = (stdout: String, stderr: String, exitCode: Int32)

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Output, Error>?
        private var answered = false
        private var out = Data()
        private var err = Data()
        private var outOpen = true
        private var errOpen = true
        private var status: Int32?
        private let outHandle: FileHandle
        private let errHandle: FileHandle

        init(stdout: Pipe, stderr: Pipe) {
            outHandle = stdout.fileHandleForReading
            errHandle = stderr.fileHandleForReading
        }

        /// Call inside the continuation body, before the process is launched: both the drain and
        /// the exit can fire the moment it is.
        func start(_ continuation: CheckedContinuation<Output, Error>) {
            lock.withLock { self.continuation = continuation }
            outHandle.readabilityHandler = { [weak self] handle in self?.absorb(handle.availableData, isStdout: true) }
            errHandle.readabilityHandler = { [weak self] handle in self?.absorb(handle.availableData, isStdout: false) }
        }

        func noteExit(_ code: Int32) {
            lock.withLock { status = code }
            deliverIfComplete()
        }

        func fail(_ error: Error) { answer(.failure(error)) }

        var hasAnswered: Bool { lock.withLock { answered } }

        private func absorb(_ data: Data, isStdout: Bool) {
            lock.withLock {
                guard !data.isEmpty else {
                    // Empty means end of file on that stream.
                    if isStdout { outOpen = false } else { errOpen = false }
                    return
                }
                if isStdout { out.append(data) } else { err.append(data) }
            }
            if isStdout, !lock.withLock({ outOpen }) { outHandle.readabilityHandler = nil }
            if !isStdout, !lock.withLock({ errOpen }) { errHandle.readabilityHandler = nil }
            deliverIfComplete()
        }

        /// The child has exited *and* both streams have ended, so everything it wrote is in hand.
        private func deliverIfComplete() {
            let payload: Output? = lock.withLock {
                guard !answered, let status, !outOpen, !errOpen else { return nil }
                return (Self.text(out), Self.text(err), status)
            }
            if let payload { answer(.success(payload)) }
        }

        private func answer(_ result: Result<Output, Error>) {
            let continuation: CheckedContinuation<Output, Error>? = lock.withLock {
                guard !answered, let c = self.continuation else { return nil }
                answered = true
                self.continuation = nil
                return c
            }
            guard let continuation else { return }
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            continuation.resume(with: result)
        }

        private static func text(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }
    }

    /// SIGKILLs the direct children of `pid`, which must still be alive (a reaped pid can be
    /// reused, and this would then signal a stranger's children). Direct children only — the same
    /// reach the host `run_command` path has.
    ///
    /// Awaited rather than waited on: `pkill` takes milliseconds, but they are milliseconds of a
    /// cooperative-pool thread, and the SIGKILL that follows must not overtake it.
    private static func killChildren(of pid: pid_t) async {
        guard pid > 0 else { return }
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-9", "-P", String(pid)]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        await withCheckedContinuation { cont in
            killer.terminationHandler = { _ in cont.resume() }
            do {
                try killer.run()
            } catch {
                killer.terminationHandler = nil
                cont.resume()
            }
        }
    }

    /// The kill ladder, and the answer at the end of it. Children first — they inherited the pipes,
    /// and one left alive keeps the read open for as long as it lives — then SIGTERM, then a grace,
    /// then children again and SIGKILL. Whatever survives that is a leaked process; it does not get
    /// to decide when the caller hears back.
    private static func enforce(_ reason: @escaping @Sendable () -> Error, on box: Box, collector: Collector) async {
        let pid = box.process.processIdentifier
        if box.process.isRunning {
            await killChildren(of: pid)
            box.process.terminate()                                     // SIGTERM
        }
        await waitUntil(Self.killGraceSeconds) { !box.process.isRunning }
        if box.process.isRunning {
            await killChildren(of: pid)                                 // anything it spawned since
            kill(pid, SIGKILL)
        }
        // A moment for the ordinary path to land with the real output, then the ladder answers.
        await waitUntil(Self.postKillSettleSeconds) { collector.hasAnswered }
        collector.fail(reason())
    }

    /// Polls `condition` until it holds or `seconds` elapse. Sleeping in slices rather than for
    /// the whole grace so a child that dies promptly is not waited out.
    private static func waitUntil(_ seconds: Double, _ condition: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
        let collector = Collector(stdout: out, stderr: err)
        let deadline = Deadline()
        let started = Date()

        // The watchdog kills; it never abandons. Racing the wait with a `withTimeout` and walking
        // away would leave the child running and unreaped — a zombie holding a pid and, for
        // `container exec`, a live connection to the VM.
        let watchdog: Task<Void, Never>? = timeoutSeconds.map { seconds in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                guard !Task.isCancelled, !collector.hasAnswered, box.process.isRunning else { return }
                deadline.fire()
                await Self.enforce({ ContainerRuntimeError.timedOut(elapsedSeconds: Date().timeIntervalSince(started)) },
                                   on: box, collector: collector)
            }
        }
        defer { watchdog?.cancel() }

        let result: (stdout: String, stderr: String, exitCode: Int32) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                collector.start(cont)
                // Installed before `run()`: a process that exits first would never call a handler
                // attached after the fact, and this continuation would never resume.
                process.terminationHandler = { collector.noteExit($0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    collector.fail(ContainerRuntimeError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            // The same ladder the deadline uses, for the same reason: a cancelled call that waits
            // on a survivor is a cancelled call that never returns.
            Task { await Self.enforce({ CancellationError() }, on: box, collector: collector) }
        }

        if deadline.didFire {
            throw ContainerRuntimeError.timedOut(elapsedSeconds: Date().timeIntervalSince(started))
        }
        // No `Task.checkCancellation()` here on purpose: a cancelled call whose child exited
        // anyway has a real result, and the host route returns that result too. Cancellation only
        // becomes an error when the ladder above had to answer for a process that would not.
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
