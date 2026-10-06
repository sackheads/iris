import Testing
import Foundation
import Darwin
@testable import iris

/// #372: the kill ladder must not need the Swift cooperative pool. A deadline that is a
/// `Task.sleep` fires only when a pool thread is free, and a pool held by blocking work has none:
/// `run_command`'s timeout (through `withTimeout`) and the container runner's deadline and cancel
/// ladder all stalled for as long as the pool was held. `ProcessGroupRunner`'s own SIGTERM →
/// SIGKILL rung was already on a dispatch queue and passes on main; it is pinned here so it stays
/// that way.
///
/// Each scenario runs in an exit test — a child process of its own — because holding every pool
/// thread for seconds in the shared test process would stall whatever other suite was running
/// beside it (invariant 7). In the child, every pool thread is held by a blocking wait, a probe
/// task confirms nothing else can be scheduled, and the command is then watched from that blocked
/// thread with plain syscalls: nothing the check itself does needs the pool either.
@Suite("Kill escalation with the cooperative pool held", .timeLimit(.minutes(1)))
struct KillEscalationPoolStarvationTests {

    @Test("run_command's timeout SIGKILLs a SIGTERM-ignoring command while the pool is held")
    func runCommandTimeoutOffPool() async {
        await #expect(processExitsWith: .success) {
            await Starvation.runCommandTimeout()
        }
    }

    @Test("ProcessGroupRunner.terminate SIGKILLs after the grace while the pool is held")
    func runnerTerminateOffPool() async {
        await #expect(processExitsWith: .success) {
            await Starvation.runnerTerminate()
        }
    }

    @Test("the container runner's deadline SIGKILLs a SIGTERM-ignoring child while the pool is held")
    func containerRunnerDeadlineOffPool() async {
        await #expect(processExitsWith: .success) {
            await Starvation.containerRunnerDeadline()
        }
    }

    @Test("cancelling a container runner SIGKILLs a SIGTERM-ignoring child while the pool is held")
    func containerRunnerCancelOffPool() async {
        await #expect(processExitsWith: .success) {
            await Starvation.containerRunnerCancel()
        }
    }
}

/// The scenarios, run inside the exit-test child. Each exits the process itself: 0 when the
/// command was gone in time, 1 when it was not, 2 when the pool could not be held (the scenario
/// would then prove nothing).
enum Starvation {
    static let timeout: Double = 1

    static func runCommandTimeout() async {
        let nap = marker()
        let started = Date()
        let call = Task.detached {
            await ToolExecutor().runCommand("trap '' TERM; sleep \(nap); true", cwd: nil, timeoutSeconds: timeout)
        }
        await watch(nap: nap, deadline: started.addingTimeInterval(timeout + ProcessGroupRunner.terminateGraceSeconds + 2))
        _ = call
    }

    static func runnerTerminate() async {
        let nap = marker()
        let runner = ProcessGroupRunner()
        let call = Task.detached {
            await runner.run(executable: "/bin/zsh", arguments: ["-c", "trap '' TERM; sleep \(nap); true"],
                             environment: nil, currentDirectory: nil)
        }
        await watch(nap: nap, deadline: nil) {
            runner.terminate()
            return Date().addingTimeInterval(ProcessGroupRunner.terminateGraceSeconds + 2)
        }
        _ = call
    }

    static func containerRunnerDeadline() async {
        let nap = marker()
        let started = Date()
        let call = Task.detached {
            try await CLIProcessRunner(executable: "/bin/sh")
                .run(["-c", loop(nap)], timeoutSeconds: Int(timeout))
        }
        await watch(nap: nap, target: shellMarker(nap), deadline: started.addingTimeInterval(timeout + CLIProcessRunner.killGraceSeconds + 2))
        _ = call
    }

    static func containerRunnerCancel() async {
        let nap = marker()
        let call = Task.detached {
            try await CLIProcessRunner(executable: "/bin/sh")
                .run(["-c", loop(nap)], timeoutSeconds: 60)
        }
        await watch(nap: nap, target: shellMarker(nap), deadline: nil) {
            // Cancelled from the blocked thread: `onCancel` runs here, synchronously, and anything
            // it hands to the pool will not run until the hold is released.
            call.cancel()
            return Date().addingTimeInterval(CLIProcessRunner.killGraceSeconds + 2)
        }
    }

    /// The container runner's ladder kills direct children, then the process, as it always has, so
    /// a loop in the shell can fork one more `sleep` in between and orphan it; the in-VM group
    /// killer is what reaches that one in production. What the ladder owns is the shell, so that is
    /// what these scenarios watch, by a marker only the shell's argv carries.
    private static func loop(_ nap: String) -> String { "trap '' TERM; while :; do sleep \(nap); done   # \(shellMarker(nap))" }
    private static func shellMarker(_ nap: String) -> String { "iris-372-\(nap)" }

    /// Waits for `sleep <nap>` to start, holds the pool, runs `act` (which may set the deadline),
    /// then polls for `target` (the sleep by default) from this blocked thread until it is gone or
    /// the deadline passes.
    private static func watch(nap: String, target: String? = nil, deadline: Date?,
                              act: () -> Date = { .distantFuture }) async {
        let started = "^sleep \(nap)"
        let appeared = Date().addingTimeInterval(5)
        while !exists(started), Date() < appeared { usleep(20_000) }
        guard exists(started) else { finish(1, nap, "the command never started") }
        let needle = target ?? started

        let hold = PoolHold()
        hold.engage()
        guard hold.isHeld() else {
            hold.release()
            finish(2, nap, "could not hold the cooperative pool")
        }
        let acted = act()
        let until = deadline ?? acted
        while exists(needle), Date() < until { usleep(50_000) }
        let survived = exists(needle)
        hold.release()
        finish(survived ? 1 : 0, nap, survived ? "\(needle) outlived its kill deadline with the pool held" : "")
    }

    private static func finish(_ code: Int32, _ nap: String, _ message: String) -> Never {
        _ = spawnAndWait("/usr/bin/pkill", ["-9", "-f", shellMarker(nap)])
        _ = spawnAndWait("/usr/bin/pkill", ["-9", "-f", "sleep \(nap)"])
        if !message.isEmpty { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        exit(code)
    }

    private static func marker() -> String { "30.\(Int.random(in: 100_000...999_999))" }

    static func exists(_ pattern: String) -> Bool { spawnAndWait("/usr/bin/pgrep", ["-f", pattern]) == 0 }

    /// `posix_spawn` and `waitpid` rather than `Process`, so the check owes nothing to a run loop
    /// or a queue: it is the blocked thread itself that waits.
    static func spawnAndWait(_ path: String, _ arguments: [String]) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, nil, argv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }
}

/// Holds every thread of the cooperative pool with a blocking wait — far more tasks than the pool
/// is wide, so whatever is not running is queued behind the ones that are.
final class PoolHold: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let count = ProcessInfo.processInfo.activeProcessorCount * 4
    private let lock = NSLock()
    private var running = 0

    func engage() {
        for _ in 0..<count {
            Task.detached {
                self.hold()
            }
        }
    }

    /// Synchronous, so the blocking wait is allowed: holding the thread is the point.
    private func hold() {
        lock.withLock { running += 1 }
        gate.wait()
    }

    /// True when the pool's threads are all taken: a fresh task does not get to run.
    func isHeld() -> Bool {
        // Let the holders take their threads first.
        let settle = Date().addingTimeInterval(2)
        var last = -1
        while Date() < settle {
            let now = lock.withLock { running }
            if now == last, now > 0 { break }
            last = now
            usleep(100_000)
        }
        let probe = Probe()
        Task.detached { probe.set() }
        usleep(300_000)
        return !probe.isSet
    }

    func release() { for _ in 0..<count { gate.signal() } }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
