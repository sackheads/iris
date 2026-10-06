import Foundation
import Darwin

/// Runs one host command as the leader of a process group of its own, so that stopping it stops
/// everything it started (#353).
///
/// The pid alone is not enough. `zsh -c 'sleep 30; true'` forks `sleep`; SIGTERM to the shell
/// kills the shell, `sleep` is reparented to launchd, and `pkill -P <shell>` then finds nothing.
/// Every descendant that does not leave on purpose stays in the group, and `kill(-pgid, …)`
/// reaches all of them.
///
/// Spawned with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`, not `Process`: the group is set inside
/// the spawn, before the child runs a single instruction of its own, so there is no window in
/// which it can fork outside the group. `setpgid` from the parent after the launch has exactly
/// that window, and fails outright once the child has exec'd. (`Process` does make its child a
/// group leader today, and its `terminate()` SIGTERMs the group, but neither is documented; it has
/// no SIGKILL rung; and `terminate()` raises on a process that was never launched.)
///
/// The leader is not reaped until the kill sequence is over: an unreaped leader keeps its pid —
/// and with it the group id — from being reused, so `kill(-pgid, …)` can never reach a stranger.
final class ProcessGroupRunner: @unchecked Sendable {
    struct Output: Sendable {
        var stdout: Data
        var stderr: Data
        /// The exit status, or 128 + the signal number for a leader killed by a signal.
        var status: Int32
        /// The `timeoutSeconds` deadline passed and the group was killed.
        var timedOut = false
        /// The kill ladder ran — `terminate()` or `timeoutSeconds` — and `onKilled` was called.
        var killed = false
    }

    /// How long SIGTERM gets before SIGKILL, once `terminate()` is called.
    static let terminateGraceSeconds: Double = 2
    /// After the leader exits on its own, how long the pipes get to reach end-of-file before the
    /// group is SIGKILLed. Anything still holding them then is a background process the command
    /// left behind, and it does not get to decide when the caller hears back (invariant 4).
    static let strayGraceSeconds: Double = 1
    /// After that SIGKILL, how long before the pipes are abandoned and the answer is whatever is in
    /// hand — the holder left the group (`setsid`), so nothing here can signal it.
    static let abandonGraceSeconds: Double = 1

    private let queue = DispatchQueue(label: "iris.process-group")

    // Everything below is read and written on `queue` only.
    private var pid: pid_t = 0
    private var cancelled = false
    private var leaderExited = false
    private var terminating = false
    private var groupKilled = false
    private var finished = false
    private var timedOut = false
    private var pendingInput = Data()
    private var inputOffset = 0
    private var inSource: DispatchSourceWrite?
    private var out = Data()
    private var err = Data()
    private var outSource: DispatchSourceRead?
    private var errSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<Result<Output, Error>, Never>?
    private var onKilled: (@Sendable () -> Void)?

    /// The leader's pid once spawned, 0 before. For tests.
    var processIdentifier: pid_t { queue.sync { pid } }

    /// Spawns `executable` and returns when it has exited and its output is in hand. Throws nothing:
    /// a spawn failure, or a `terminate()` that arrived before the spawn, comes back as `.failure`.
    ///
    /// - `stdin`: written to the command while its output drains, so neither side can fill a pipe
    ///   and wait on the other. nil or empty means `/dev/null`.
    /// - `mergeStderr`: stderr goes into the same pipe as stdout, interleaved as written; the
    ///   output's `stderr` is then empty.
    /// - `timeoutSeconds`: when it passes, the same ladder as `terminate()`, and `timedOut` is set.
    ///   Timed on this runner's own queue, not the cooperative pool, so a starved pool cannot
    ///   hold the kill back (#372).
    /// - `onKilled`: called on this runner's queue when the kill ladder has finished with a group
    ///   it spawned, just before the answer. For what lies beyond the group's reach — a one-off
    ///   `container run` whose container outlives its killed client — so that cleanup does not
    ///   wait for a pool thread either (#377). It must not block.
    func run(executable: String, arguments: [String], environment: [String: String]?,
             currentDirectory: String?, stdin: Data? = nil, mergeStderr: Bool = false,
             timeoutSeconds: Double? = nil, onKilled: (@Sendable () -> Void)? = nil) async -> Result<Output, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.onKilled = onKilled
                self.launch(executable: executable, arguments: arguments,
                            environment: environment, currentDirectory: currentDirectory,
                            stdin: stdin, mergeStderr: mergeStderr)
                if let timeoutSeconds, self.pid > 0 {
                    self.queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                        guard !self.finished, !self.terminating else { return }
                        self.timedOut = true
                        self.beginTermination()
                    }
                }
            }
        }
    }

    /// `run` that also answers task cancellation with `terminate()`: the shape every caller that
    /// is not `run_command` (which layers its own `withTimeout` on top) wants (#364).
    static func capture(executable: String, arguments: [String], environment: [String: String]?,
                        currentDirectory: String? = nil, stdin: Data? = nil, mergeStderr: Bool = false,
                        timeoutSeconds: Double?, onKilled: (@Sendable () -> Void)? = nil) async -> Result<Output, Error> {
        let runner = ProcessGroupRunner()
        return await withTaskCancellationHandler {
            await runner.run(executable: executable, arguments: arguments, environment: environment,
                             currentDirectory: currentDirectory, stdin: stdin, mergeStderr: mergeStderr,
                             timeoutSeconds: timeoutSeconds, onKilled: onKilled)
        } onCancel: {
            runner.terminate()
        }
    }

    /// SIGTERM to the whole group, then SIGKILL after `terminateGraceSeconds`. Safe from any
    /// thread and at any time: before the spawn it stops the spawn from happening, after the
    /// command has finished it does nothing.
    func terminate() {
        queue.async {
            guard self.pid > 0 else { self.cancelled = true; return }
            self.beginTermination()
        }
    }

    // MARK: - On `queue`

    private func beginTermination() {
        guard !finished, !terminating else { return }
        terminating = true
        signalGroup(SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.terminateGraceSeconds) {
            self.signalGroup(SIGKILL)
            self.groupKilled = true
            self.finishIfDone()
        }
    }

    private func launch(executable: String, arguments: [String], environment: [String: String]?,
                        currentDirectory: String?, stdin: Data?, mergeStderr: Bool) {
        guard !cancelled else { return resume(.failure(CancellationError())) }

        var fds: [Int32] = []
        func makePipe() -> [Int32]? {
            var p: [Int32] = [-1, -1]
            guard pipe(&p) == 0 else { return nil }
            fds += p
            return p
        }
        func fail() {
            let e = POSIXError.current
            fds.forEach { close($0) }
            resume(.failure(e))
        }
        guard let outFDs = makePipe() else { return fail() }
        let errFDs: [Int32]
        if mergeStderr { errFDs = outFDs } else {
            guard let p = makePipe() else { return fail() }
            errFDs = p
        }
        let inFDs: [Int32]?
        if let stdin, !stdin.isEmpty {
            guard let p = makePipe() else { return fail() }
            inFDs = p
        } else {
            inFDs = nil
        }
        // Close-on-exec, so a process some other part of the app spawns does not inherit a write
        // end and hold our end-of-file hostage.
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let inFDs {
            posix_spawn_file_actions_adddup2(&actions, inFDs[0], 0)
        } else {
            // Nothing types at a command: one that reads stdin gets EOF rather than the app's.
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETPGROUP with group 0: the child's own pid becomes its group. CLOEXEC_DEFAULT: only
        // 0, 1 and 2 cross into the child. SIGDEF/SIGMASK: no ignored or blocked signal of the
        // app's leaks into the command — an inherited SIG_IGN on SIGTERM would make it unkillable
        // but by the SIGKILL rung.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        let argv = Self.cStrings([executable] + arguments)
        let envp = Self.cStrings((environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" })
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attr, argv, envp)
        close(outFDs[1])
        if !mergeStderr { close(errFDs[1]) }
        if let inFDs { close(inFDs[0]) }
        guard rc == 0 else {
            close(outFDs[0])
            if !mergeStderr { close(errFDs[0]) }
            if let inFDs { close(inFDs[1]) }
            return resume(.failure(POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)))
        }
        pid = child
        outSource = drain(outFDs[0], isStdout: true)
        if !mergeStderr { errSource = drain(errFDs[0], isStdout: false) }
        if let inFDs, let stdin { inSource = feed(inFDs[1], stdin) }
        watchLeader(child)
    }

    /// Writes `data` as the command takes it. A command that exits, or closes stdin, without
    /// reading it all gets EPIPE rather than SIGPIPE to the app, and the rest is dropped.
    private func feed(_ fd: Int32, _ data: Data) -> DispatchSourceWrite {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        pendingInput = data
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            while inputOffset < pendingInput.count {
                let n = pendingInput.withUnsafeBytes {
                    write(fd, $0.baseAddress! + inputOffset, $0.count - inputOffset)
                }
                if n > 0 { inputOffset += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN { return }
                break
            }
            closeInput()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func closeInput() {
        inSource?.cancel()
        inSource = nil
        pendingInput = Data()
    }

    private func drain(_ fd: Int32, isStdout: Bool) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Retains `self` until the source is cancelled, which every path to `finishIfDone` does.
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    if isStdout { out.append(buffer, count: n) } else { err.append(buffer, count: n) }
                    continue
                }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN { return }
                // End of file, or an error that means the same thing for us.
                closeStream(isStdout: isStdout)
                finishIfDone()
                return
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func closeStream(isStdout: Bool) {
        if isStdout { outSource?.cancel(); outSource = nil } else { errSource?.cancel(); errSource = nil }
    }

    /// A thread of its own, blocked in `waitid` with `WNOWAIT`: told of the exit without reaping,
    /// so the pid stays reserved until `finishIfDone` has stopped signalling the group. A dispatch
    /// process source would not block a thread, but its behaviour on a child that has already
    /// exited by the time it is registered is not documented.
    private func watchLeader(_ child: pid_t) {
        let thread = Thread { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            queue.async { self.leaderDidExit() }
        }
        thread.name = "iris.process-group.wait"
        thread.start()
    }

    private func leaderDidExit() {
        leaderExited = true
        finishIfDone()
        guard !finished else { return }
        queue.asyncAfter(deadline: .now() + Self.strayGraceSeconds) {
            guard !self.finished else { return }
            self.signalGroup(SIGKILL)
            self.queue.asyncAfter(deadline: .now() + Self.abandonGraceSeconds) {
                guard !self.finished else { return }
                self.closeStream(isStdout: true)
                self.closeStream(isStdout: false)
                self.finishIfDone()
            }
        }
    }

    private func signalGroup(_ signal: Int32) {
        // Never once reaped: past that point the group id may belong to somebody else.
        guard pid > 0, !finished else { return }
        kill(-pid, signal)
    }

    private func finishIfDone() {
        guard !finished, leaderExited, outSource == nil, errSource == nil else { return }
        // A terminate runs its ladder to the end before the leader is reaped, so its SIGKILL
        // cannot land on a reused group id.
        guard !terminating || groupKilled else { return }
        finished = true
        closeInput()
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
        let signal = raw & 0x7f
        let status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
        if terminating { onKilled?() }
        onKilled = nil
        resume(.success(Output(stdout: out, stderr: err, status: status, timedOut: timedOut, killed: terminating)))
    }

    private func resume(_ result: Result<Output, Error>) {
        onKilled = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }
}

private extension POSIXError {
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
