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
    /// The isolated network could not be vouched for: a failed listing, or a create that failed
    /// for a reason other than the network already existing.
    case networkFailed(String)
}

/// One host directory made visible inside the container. Was a caseless enum of helpers; the
/// helpers keep their names so every existing caller compiles unchanged.
///
/// Codable through a single string value — the on-disk form, the tool argument grammar, and what
/// every surface prints are all `source[:target][:ro]`: a bare path mounts at itself, and `ro`
/// makes the mount read-only. A second schema here would be one more thing for a model, or a hand
/// edited policy column, to get wrong.
struct ContainerMount: Codable, Equatable, Hashable, Sendable {
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
    let source: String
    let target: String
    let readOnly: Bool

    init(source: String, target: String? = nil, readOnly: Bool = false) {
        self.source = source
        self.target = target ?? source
        self.readOnly = readOnly
    }

    /// Strict, through `argument(for:)`: an entry this refuses is one no container could be
    /// created with, and refusing here means a grant can never store one.
    init(parsing entry: String) throws {
        _ = try Self.argument(for: entry)
        var parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let readOnly = Self.hasReadOnlyFlag(entry)
        if readOnly { parts.removeLast() }
        self.init(source: parts[0], target: parts.count == 2 ? parts[1] : nil, readOnly: readOnly)
    }

    /// The one spelling: `source[:target][:ro]`, target omitted when identity-mapped. This is the
    /// tool's input grammar, the stored form and what every surface prints.
    var entry: String {
        var text = source
        if target != source { text += ":\(target)" }
        if readOnly { text += ":ro" }
        return text
    }

    var argument: String {
        get throws { try Self.argument(for: entry) }
    }

    init(from decoder: Decoder) throws {
        try self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entry)
    }

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

/// Which network a container is attached to (#282 §0.7). The CLI has no "none": `run --network`
/// takes a name, so "off" is an Iris-owned internal network with no route out and no DNS — no
/// egress and no LAN; the host's own listeners are still reachable from it (measured, §0.7), and
/// `/jobs` says so.
enum NetworkMode: Equatable, Sendable {
    case `default`
    case isolated(name: String)

    static let isolatedNetworkName = "iris-isolated"
    static let isolated = NetworkMode.isolated(name: isolatedNetworkName)

    /// A granted run without the network bit is isolated; a granted run with it, and every run
    /// with no grant at all, keeps the default network — an ungranted job's container is exactly
    /// what it was before grants existed.
    static func forGrant(_ grant: JobGrant?) -> NetworkMode {
        guard let grant, !grant.network else { return .default }
        return .isolated
    }
}

/// Seam over the `container` CLI so `SandboxSessionManager` is unit-testable without a real VM.
protocol ContainerRuntime: Sendable {
    /// `container run -d --init --name <name> [--mount <spec>]… [--network <name> --no-dns] -w <workdir> <image> sleep infinity`
    func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws
    /// Makes sure the host-only network `name` exists: `container network ls`, then
    /// `container network create --internal <name>` when it is missing. Throws `networkFailed`.
    func ensureIsolatedNetwork(named name: String) async throws
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

extension ContainerRuntime {
    /// The pre-grant form: the default network. Every caller that is not a granted run.
    func createDetached(name: String, image: String, mounts: [String], workdir: String) async throws {
        try await createDetached(name: name, image: image, mounts: mounts, workdir: workdir, network: .default)
    }

    /// `remove`, run where the caller's cancellation cannot reach it — for cleanup, and only for
    /// cleanup.
    ///
    /// A cancelled call is exactly when a container most needs removing and exactly when the
    /// ordinary route will not do it: `CLIProcessRunner.run` refuses to launch on an
    /// already-cancelled task (deliberately — a ladder cannot kill a child that was never started),
    /// so `container stop` and `container delete` never spawn and the container outlives the call
    /// that made it. An unstructured `Task` does not inherit the caller's cancellation, and
    /// awaiting it keeps the cleanup ordered before whatever the caller does next. Bounded by the
    /// remove's own `housekeepingTimeoutSeconds`, so a cancelled caller waits seconds, not
    /// indefinitely.
    func removeIgnoringCancellation(name: String) async {
        await Task { await self.remove(name: name) }.value
    }
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
        private let queue: DispatchQueue

        /// `queue` is the call's ladder queue, which times the post-exit grace.
        init(stdout: Pipe, stderr: Pipe, queue: DispatchQueue) {
            outHandle = stdout.fileHandleForReading
            errHandle = stderr.fileHandleForReading
            self.queue = queue
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
            // A dispatch timer, not a `Task.sleep`, which waits for a free pool thread (#372). On
            // the ladder's queue rather than `global()`, which does not overcommit (#377). Weak:
            // an unanswered call is still suspended in `run`, which holds this collector.
            queue.asyncAfter(deadline: .now() + CLIProcessRunner.postExitEOFGraceSeconds) { [weak self] in
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
    /// Waited on, on the ladder's own queue, so the SIGKILL that follows cannot overtake it. Never
    /// on a cooperative-pool thread: the ladder does not run there (#372).
    private static func killChildren(of pid: pid_t) {
        guard pid > 0 else { return }
        BlockingSpawn.run("/usr/bin/pkill", ["-9", "-P", String(pid)])
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
        let killChildren: @Sendable (pid_t) -> Void
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
    ///
    /// Synchronous, and run on a dispatch queue of its own: it blocks its thread for the grace,
    /// which must never be a cooperative-pool thread, and its timing must not depend on one being
    /// free: a pool held by blocking work held the old, `Task.sleep`-paced ladder with it (#372).
    ///
    /// `onKill` runs on this same queue, first, and only when the ladder finds the child running:
    /// it is how a caller acts beyond the child's reach — `CLIContainerRuntime.exec` kills the
    /// command's group inside the VM, which killing the client never does (#377). Here rather
    /// than after `run` throws, because that is a pool thread, and a held pool held the in-VM kill
    /// with it. First, because the caller can be answered the moment SIGTERM lands, and the hook
    /// must have run by then. It must not block: the ladder waits for it.
    ///
    /// And again at the end of the ladder, no sooner than `killGraceSeconds` after the first call,
    /// on a queue of its own so the answer does not wait for it. A cancel can land before the
    /// command has recorded its group in the VM, and the first kill then finds nothing; a group
    /// recorded in the meantime is still killed. So the hook runs twice and must be idempotent,
    /// as the group killer is: a group that already ended removed its note.
    static func enforce(_ reason: @escaping @Sendable () -> Error, on child: Child,
                        hasAnswered: @escaping @Sendable () -> Bool,
                        fail: @escaping @Sendable (Error) -> Void,
                        onKill: (@Sendable () -> Void)? = nil) {
        let launched = child.pid()
        var firstKill: Date?
        if child.isRunning(), launched > 0 {
            firstKill = Date()
            onKill?()
            child.killChildren(launched)
            child.terminate()                                           // SIGTERM
        }
        waitUntil(Self.killGraceSeconds) { !child.isRunning() }
        let pid = child.pid()
        if child.isRunning(), pid > 0 {
            child.killChildren(pid)                                     // anything it spawned since
            child.signal(pid, SIGKILL)
        }
        if let firstKill, let onKill {
            let wait = max(0, Self.killGraceSeconds - Date().timeIntervalSince(firstKill))
            DispatchQueue(label: "iris.cli-process.refire").asyncAfter(deadline: .now() + wait, execute: onKill)
        }
        // A moment for the ordinary path to land with the real output, then the ladder answers.
        // Load bearing on the cancellation path, where a promptly-exiting child's real result is
        // what the caller gets. On the deadline path it only costs latency: `run` throws
        // `.timedOut` below whether or not the result landed, because the deadline did fire.
        waitUntil(Self.postKillSettleSeconds) { hasAnswered() }
        fail(reason())
    }

    /// Polls `condition` until it holds or `seconds` elapse, blocking the ladder's thread. In
    /// slices rather than for the whole grace, so a child that dies promptly is not waited out.
    private static func waitUntil(_ seconds: Double, _ condition: @Sendable () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            usleep(50_000)
        }
    }

    /// `onKill`: see `enforce`. Runs when a deadline or a cancel had to kill a running child —
    /// twice, on the ladder's queue and then at the end of the ladder — and never otherwise.
    ///
    /// The kill does not need the cooperative pool; the answer does. Resuming the caller takes a
    /// pool thread, so with the pool held the child dies on time and the result arrives when the
    /// pool frees (#377). That is accepted rather than engineered around: whatever reads the
    /// result — the engine's tool dispatch — runs on the same pool, so it could not act sooner.
    func run(_ arguments: [String], timeoutSeconds: Int? = nil,
             onKill: (@Sendable () -> Void)? = nil) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
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

        // The deadline and the cancel both run the ladder here, off the cooperative pool: a
        // `Task.sleep` deadline fires only when a pool thread is free, and a pool held by blocking
        // work held the kill with it (#372). The post-exit grace is timed here too.
        let ladder = DispatchQueue(label: "iris.cli-process.ladder")

        let box = Box(process)
        let collector = Collector(stdout: out, stderr: err, queue: ladder)
        let deadline = Deadline()
        let started = Date()
        let child = Child(pid: { box.process.processIdentifier },
                          isRunning: { box.process.isRunning },
                          terminate: { box.process.terminate() },
                          killChildren: { Self.killChildren(of: $0) },
                          signal: { kill($0, $1) })

        // The watchdog kills; it never abandons. Racing the wait with a `withTimeout` and walking
        // away would leave the child running and unreaped — a zombie holding a pid and, for
        // `container exec`, a live connection to the VM.
        let watchdog: DispatchSourceTimer? = timeoutSeconds.map { seconds in
            let timer = DispatchSource.makeTimerSource(queue: ladder)
            timer.schedule(deadline: .now() + .seconds(max(1, seconds)))
            timer.setEventHandler {
                // Not "is the child still running?": a child can exit in milliseconds and leave
                // something it spawned holding the inherited pipes, in which case end-of-file
                // never comes, the collector never publishes, and the only condition that means
                // "nobody has been told yet" is the collector's own.
                guard !collector.hasAnswered else { return }
                deadline.fire()
                Self.enforce({ ContainerRuntimeError.timedOut(elapsedSeconds: Date().timeIntervalSince(started)) },
                             on: child, hasAnswered: { collector.hasAnswered },
                             fail: { collector.fail($0) }, onKill: onKill)
            }
            timer.resume()
            return timer
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
            ladder.async {
                Self.enforce({ CancellationError() }, on: child,
                             hasAnswered: { collector.hasAnswered },
                             fail: { collector.fail($0) }, onKill: onKill)
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
    /// One spawn of the `container` CLI: the argv, the deadline the command is allowed, and what
    /// to run when a deadline or a cancel had to kill it (`CLIProcessRunner.run`'s `onKill`).
    /// Injectable so a test can assert what a call renders without a binary, a daemon or a VM.
    typealias Launch = @Sendable (_ arguments: [String], _ timeoutSeconds: Int?,
                                  _ onKill: (@Sendable () -> Void)?) async throws -> (stdout: String, stderr: String, exitCode: Int32)

    /// A `container` call nobody waits for, started from a kill ladder's own thread: it must not
    /// block that thread and must not need the cooperative pool (#377). Injectable for the same
    /// reason as `Launch`.
    typealias Fire = @Sendable (_ arguments: [String], _ timeoutSeconds: Int) -> Void

    /// The installed `container` binary, resolved per call because it can be installed while the
    /// app is running.
    static var binary: String { SandboxingManager.shared.containerBinaryPath ?? "/usr/local/bin/container" }

    static let spawnCLI: Launch = { arguments, timeoutSeconds, onKill in
        try await CLIProcessRunner(executable: binary).run(arguments, timeoutSeconds: timeoutSeconds, onKill: onKill)
    }

    static let fireCLI: Fire = { arguments, timeoutSeconds in
        BlockingSpawn.detached(binary, arguments, timeoutSeconds: Double(timeoutSeconds))
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

    private let launchKillable: Launch
    private let fire: Fire

    init(launch: @escaping Launch = CLIContainerRuntime.spawnCLI, fire: @escaping Fire = CLIContainerRuntime.fireCLI) {
        self.launchKillable = launch
        self.fire = fire
    }

    /// Every call but `exec`'s command: nothing beyond the client to kill.
    private func launch(_ arguments: [String], _ timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await launchKillable(arguments, timeoutSeconds, nil)
    }

    func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws {
        // `--init`: the CLI's init process is PID 1 and reaps. `sleep infinity` as PID 1 reaps
        // nothing, so every command the in-VM group killer ended left its processes as zombies
        // for the life of the session (#365). The init also forwards signals, so `container stop`
        // no longer waits out its timeout on a PID 1 that ignores SIGTERM.
        var args = ["run", "-d", "--init", "--name", name]
        // Rendered before anything is spawned, so a mount the CLI could not read refuses the
        // container rather than producing one with a mount missing.
        for entry in mounts {
            args += ["--mount", try ContainerMount.argument(for: entry)]
        }
        if case .isolated(let networkName) = network {
            // `--no-dns` too: an internal network has no resolver to offer, and the default DNS
            // would be a route out that the network itself does not have.
            args += ["--network", networkName, "--no-dns"]
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

    /// Measured 2026-09-23 (CLI 1.1.0): `network ls --format json` is an array of objects with a
    /// top-level `id` and a `configuration.name`; a duplicate `network create` exits non-zero
    /// with `Error: network <name> already exists` on stderr. That stderr is success here — two
    /// fires racing to create the same network must not fail each other — and a listing that fails
    /// is a network nobody can vouch for, so it fails closed.
    func ensureIsolatedNetwork(named name: String) async throws {
        let listed = try await launch(["network", "ls", "--format", "json"], Self.housekeepingTimeoutSeconds)
        guard listed.exitCode == 0 else {
            throw ContainerRuntimeError.networkFailed((listed.stdout + listed.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if Self.networkNames(in: listed.stdout).contains(name) { return }
        let created = try await launch(["network", "create", "--internal", name], Self.housekeepingTimeoutSeconds)
        guard created.exitCode == 0 || created.stderr.contains("already exists") else {
            throw ContainerRuntimeError.networkFailed((created.stdout + created.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Both spellings the CLI uses for a network's name.
    private static func networkNames(in json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var names: Set<String> = []
        for entry in arr {
            if let id = entry["id"] as? String { names.insert(id) }
            if let name = (entry["configuration"] as? [String: Any])?["name"] as? String { names.insert(name) }
        }
        return names
    }

    /// The command runs under a wrapper that records its process group in the container, so a
    /// timeout or a cancel can kill it there (#353). Killing the `container exec` client on the
    /// host does not reach into the VM — measured 2026-10-04, CLI 1.1.0: the client fails to
    /// forward the signal ("missing signal in xpc message"), and the command and everything it
    /// forked run on in the container after the client is SIGKILLed.
    ///
    /// The killer is started by the client's kill ladder, on the ladder's queue, as the ladder
    /// starts on a client that is still running (#377). It used to start from here, in a `Task`
    /// after `launch` threw — which needs a free pool thread, so a held pool held the in-VM kill
    /// with it, while the host-side kill (#372) went ahead. Fired, not awaited: the caller hears
    /// back without waiting out the killer's own grace, and a cancelled caller cannot stop it. A
    /// cancel whose client died on SIGTERM and so came back as an ordinary result used to start no
    /// killer at all; the ladder fires it either way.
    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let pidFile = Self.execPidFile(token: UUID().uuidString)
        let fire = self.fire
        return try await launchKillable(["exec", "-w", workdir, name, "bash", "-c", Self.recordingWrapper(pidFile), "iris-exec", command],
                                        timeoutSeconds,
                                        { fire(["exec", name, "bash", "-c", Self.groupKiller(pidFile)], Self.housekeepingTimeoutSeconds) })
    }

    static func execPidFile(token: String) -> String { "/tmp/.iris-exec-\(token).pid" }

    /// `bash -c <this> iris-exec <command>`: notes its own pid — the group `container exec` makes
    /// it the leader of — runs the command as `bash -c` always ran it, and passes its status on.
    /// Not `exec`, so the note can be removed on the way out. If `/tmp` is not writable the command
    /// runs all the same; only the kill on timeout is lost.
    static func recordingWrapper(_ pidFile: String) -> String {
        "printf %s \"$$\" > \(pidFile) 2>/dev/null; bash -c \"$1\"; s=$?; rm -f \(pidFile); exit $s"
    }

    /// SIGTERM to the recorded group, a grace, then SIGKILL. A group that already finished removed
    /// its note, so there is nothing to signal.
    static func groupKiller(_ pidFile: String) -> String {
        "[ -s \(pidFile) ] || exit 0; p=$(cat \(pidFile)); kill -TERM -- -\"$p\" 2>/dev/null; "
            + "sleep \(Int(CLIProcessRunner.killGraceSeconds)); kill -KILL -- -\"$p\" 2>/dev/null; rm -f \(pidFile)"
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
