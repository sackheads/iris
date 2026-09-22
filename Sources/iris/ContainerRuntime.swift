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
    /// for a comma: it starts the next directive, and the format has no escape for one. Such an
    /// entry is refused here rather than mangled there. An `=` is fine — the CLI splits a
    /// directive at the *first* `=` and takes the rest verbatim, so `source=/a=b` is the path
    /// `/a=b` and not a malformed key.
    ///
    /// Both paths must be absolute. A source that is not is read by the CLI as the name of a
    /// *volume* rather than a directory to bind, so `data:/data` would quietly look up something
    /// else entirely instead of failing.
    ///
    /// What is not checked here, because only the daemon can answer it: the source must exist and
    /// be a directory. A single file cannot be mounted this way — mount its parent. That surfaces
    /// as a `createFailed` from the CLI.
    /// Whether `entry` already ends in the read-only flag. Spelled once, because a caller that
    /// *adds* `:ro` to an entry (a gate's inputs, `GateEvaluator.readOnly`) has to decide the same
    /// question this parser does — two spellings would eventually disagree about an entry whose
    /// target happens to be called `ro`.
    static func hasReadOnlyFlag(_ entry: String) -> Bool {
        let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.last == "ro"
    }

    static func argument(for entry: String) throws -> String {
        var parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var readOnly = false
        if hasReadOnlyFlag(entry) {
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

    /// How long the ordinary exit path gets, after the kill ladder, to deliver the real output
    /// before the ladder's own answer is returned instead.
    static let postKillSettleSeconds: Double = 0.25

    /// How long end-of-file gets after the child has exited. On any ordinary call it arrives in
    /// the same breath as the exit; this only matters when something the child spawned inherited
    /// the pipes and outlived it, and it is what makes a call with no deadline at all still
    /// answer. Deliberately longer than a `Pipe`'s round trip and shorter than any deadline a
    /// caller would set.
    static let postExitEOFGraceSeconds: Double = 2

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
            guard !hasAnswered else { return }
            // The child is gone, so it has written everything it is ever going to write. Anything
            // still keeping the read open is somebody else's file descriptor, and waiting on it
            // is waiting on a process this call does not own — which is how a call with no
            // deadline (a cold `createDetached`, `reapOrphans` at launch) wedges forever. After
            // the grace, whatever is in hand is the answer.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(CLIProcessRunner.postExitEOFGraceSeconds * 1_000_000_000))
                self?.deliverAfterExit()
            }
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

        /// Publishes what the pipes have delivered so far, on the strength of the exit alone.
        /// Only reached when end-of-file did not arrive within `postExitEOFGraceSeconds` of it.
        private func deliverAfterExit() {
            let payload: Output? = lock.withLock {
                guard !answered, let status else { return nil }
                return (Self.text(out), Self.text(err), status)
            }
            if let payload { answer(.success(payload)) }
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

    /// What the kill ladder needs of the child, and the only things it does to it.
    ///
    /// A seam rather than the `Process` itself, so the ladder can be driven against a child that
    /// was never launched — `processIdentifier == 0` — without anything real being signalled. That
    /// case is not hypothetical: when a task is already cancelled on entry, Swift runs
    /// `withTaskCancellationHandler`'s `onCancel` *before* the operation, so the ladder can reach
    /// a process that has not been started yet.
    struct Child: Sendable {
        /// Read afresh at every rung rather than captured once: a pid read before the launch is 0,
        /// and `kill(0, …)` is not a no-op — it signals every process in Iris's own process group,
        /// which is the app and, under `scripts/run-dev.sh`, the shell that started it.
        let pid: @Sendable () -> pid_t
        let isRunning: @Sendable () -> Bool
        let terminate: @Sendable () -> Void
        let killChildren: @Sendable (pid_t) async -> Void
        let signal: @Sendable (pid_t, Int32) -> Void
    }

    /// The kill ladder, and the answer at the end of it. Children first — they inherited the pipes,
    /// and one left alive keeps the read open for as long as it lives — then SIGTERM, then a grace,
    /// then children again and SIGKILL. Whatever survives that is a leaked process; it does not get
    /// to decide when the caller hears back.
    ///
    /// Nothing is signalled while the pid is not a pid. A rung needs both a running process *and* a
    /// positive pid, and the pid is re-read between the rungs, because the two reads are seconds
    /// apart and the first one can predate the launch entirely.
    static func enforce(_ reason: @escaping @Sendable () -> Error, on child: Child,
                        hasAnswered: @escaping @Sendable () -> Bool,
                        fail: @escaping @Sendable (Error) -> Void) async {
        let launched = child.pid()
        if child.isRunning(), launched > 0 {
            await child.killChildren(launched)
            child.terminate()                                           // SIGTERM
        }
        await waitUntil(Self.killGraceSeconds) { !child.isRunning() }
        let pid = child.pid()
        if child.isRunning(), pid > 0 {
            await child.killChildren(pid)                               // anything it spawned since
            child.signal(pid, SIGKILL)
        }
        // A moment for the ordinary path to land with the real output, then the ladder answers.
        // Load bearing on the cancellation path, where a promptly-exiting child's real result is
        // what the caller gets. On the deadline path it only costs latency: `run` throws
        // `.timedOut` below whether or not the result landed, because the deadline did fire.
        await waitUntil(Self.postKillSettleSeconds) { hasAnswered() }
        fail(reason())
    }

    /// Polls `condition` until it holds or `seconds` elapse. Sleeping in slices rather than for
    /// the whole grace so a child that dies promptly is not waited out — and giving up when the
    /// task is cancelled, because `Task.sleep` returns at once from then on and the loop would
    /// otherwise spin a cooperative thread for the rest of the grace.
    private static func waitUntil(_ seconds: Double, _ condition: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition(), !Task.isCancelled {
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
        let child = Child(pid: { box.process.processIdentifier },
                          isRunning: { box.process.isRunning },
                          terminate: { box.process.terminate() },
                          killChildren: { await Self.killChildren(of: $0) },
                          signal: { kill($0, $1) })

        // The watchdog kills; it never abandons. Racing the wait with a `withTimeout` and walking
        // away would leave the child running and unreaped — a zombie holding a pid and, for
        // `container exec`, a live connection to the VM.
        let watchdog: Task<Void, Never>? = timeoutSeconds.map { seconds in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
                // Not "is the child still running?": a child can exit in milliseconds and leave
                // something it spawned holding the inherited pipes, in which case end-of-file
                // never comes, the collector never publishes, and the only condition that means
                // "nobody has been told yet" is the collector's own.
                guard !Task.isCancelled, !collector.hasAnswered else { return }
                deadline.fire()
                await Self.enforce({ ContainerRuntimeError.timedOut(elapsedSeconds: Date().timeIntervalSince(started)) },
                                   on: child, hasAnswered: { collector.hasAnswered },
                                   fail: { collector.fail($0) })
            }
        }
        defer { watchdog?.cancel() }

        let result: (stdout: String, stderr: String, exitCode: Int32) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                collector.start(cont)
                // Checked here, on the calling task, and not before the cancellation handler was
                // installed: when a task is already cancelled on entry, `onCancel` runs *first*,
                // against a child that does not exist yet, and a ladder cannot kill what was never
                // launched. So the launch is what must not happen — otherwise the command runs on
                // in the VM with nobody reading its pipes, no deadline, and a caller already told
                // it was cancelled.
                guard !Task.isCancelled else {
                    collector.fail(CancellationError())
                    return
                }
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
            Task {
                await Self.enforce({ CancellationError() }, on: child,
                                   hasAnswered: { collector.hasAnswered },
                                   fail: { collector.fail($0) })
            }
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

    /// The deadline on the calls that are not the user's command. Generous — `container stop`
    /// waits for the VM to come down — but finite: `reapOrphans()` runs `list` on the launch path,
    /// and nothing there is watching to notice that it never came back.
    static let housekeepingTimeoutSeconds = 60

    /// The ceiling on a create. A cold pull of an image is legitimately minutes, so this is not a
    /// deadline anybody should ever meet — it is the difference between "slow" and "a turn wedged
    /// until the app is quit". A breach comes back as an ordinary timeout, the same error any other
    /// call gets, and the caller reports it like any other failed create. An unattended caller
    /// needs a tighter one of its own: `GateEvaluator.createCeilingSeconds` is five minutes,
    /// because nobody is watching a gate.
    static let createTimeoutSeconds = 1_200

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
        // Generous, because a cold create pulls the image and that is legitimately minutes; finite,
        // because a `container run` that never answers would otherwise wedge the first sandboxed
        // command of a turn with nothing to end it. Separately from the deadline, the collector
        // answers on the child's exit plus a grace, so this cannot wait on a file descriptor
        // somebody else is holding either.
        let r = try await launch(args, Self.createTimeoutSeconds)
        if r.exitCode != 0 {
            throw ContainerRuntimeError.createFailed((r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await launch(["exec", "-w", workdir, name, "bash", "-c", command], timeoutSeconds)
    }

    func remove(name: String) async {
        _ = try? await launch(["stop", name], Self.housekeepingTimeoutSeconds)
        _ = try? await launch(["delete", name], Self.housekeepingTimeoutSeconds)
    }

    func list(prefix: String) async -> [String] {
        guard let r = try? await launch(["list", "-a", "--format", "json"], Self.housekeepingTimeoutSeconds),
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
