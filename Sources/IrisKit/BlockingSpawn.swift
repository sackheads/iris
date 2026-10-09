import Foundation
import Darwin

/// `posix_spawn` plus `waitpid`, for the small helper commands a kill path runs (`pkill`, a
/// `container exec` group killer, `container delete`). Owes nothing to a run loop, a `Process`, or
/// the cooperative pool: the calling thread does the waiting, or a serial queue of its own does
/// (#372, #377).
///
/// stdin is `/dev/null` and stdout and stderr are discarded; the only answer is the exit status.
enum BlockingSpawn {
    /// How often a bounded wait checks whether the child has exited.
    static let pollInterval: useconds_t = 10_000

    /// Runs `path` with `arguments` and blocks until it exits. Returns its exit status, 128 + the
    /// signal number for a child killed by a signal, or nil when it could not be spawned.
    ///
    /// With `timeoutSeconds`, a child still running at the deadline is SIGKILLed and reaped, so a
    /// helper that hangs (a `container` daemon that never answers) cannot hold the caller's thread
    /// for good.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], timeoutSeconds: Double? = nil) -> Int32? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // Default dispositions and an empty mask: an ignored or blocked signal of the app's does
        // not leak into the helper.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attr, argv, environ) == 0 else { return nil }

        var raw: Int32 = 0
        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while true {
                let r = waitpid(pid, &raw, WNOHANG)
                if r == pid { return status(raw) }
                if r == -1, errno != EINTR { return nil }
                if Date() >= deadline { break }
                usleep(pollInterval)
            }
            kill(pid, SIGKILL)
        }
        while waitpid(pid, &raw, 0) == -1 {
            if errno != EINTR { return nil }
        }
        return status(raw)
    }

    /// `run` on a serial queue of its own, so the caller does not wait at all. Not
    /// `DispatchQueue.global()`, which does not overcommit: a queue made here targets one that
    /// does, so a burst of blocked waits elsewhere cannot delay this one. `then` gets the status
    /// on that queue.
    static func detached(_ path: String, _ arguments: [String], timeoutSeconds: Double?,
                         then: (@Sendable (Int32?) -> Void)? = nil) {
        DispatchQueue(label: "iris.blocking-spawn").async {
            let status = run(path, arguments, timeoutSeconds: timeoutSeconds)
            then?(status)
        }
    }

    private static func status(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }
}
