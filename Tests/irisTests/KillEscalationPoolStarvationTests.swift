import Testing
import Foundation
import Darwin
@testable import IrisKit

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

    /// #377: the one-off `container run`'s delete is started by the runner's ladder, not by a
    /// `Task` after `run_command` returns. A stub stands in for the `container` binary, so no VM
    /// is involved; the in-VM group kill on a real VM is `SandboxRealVMTests`.
    @Test("a timed-out one-off container is deleted while the pool is held")
    func ephemeralDeleteOffPool() async {
        await #expect(processExitsWith: .success) {
            await Starvation.ephemeralDelete()
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

    static func ephemeralDelete() async {
        let nap = marker()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-377-\(UUID().uuidString)")
        let log = dir.appendingPathComponent("calls").path
        let stub = dir.appendingPathComponent("container").path
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "#!/bin/sh\necho \"$*\" >> '\(log)'\n[ \"$1\" = run ] && exec sleep \(nap)\nexit 0\n"
                .write(toFile: stub, atomically: true, encoding: .utf8)
            guard chmod(stub, 0o755) == 0 else { throw POSIXError(.EPERM) }
        } catch {
            finish(1, nap, "could not write the stub: \(error)")
        }
        // Run once before the clock starts. The first exec of a file this new waits on the host's
        // check of new executables, which takes about 0.1 s alone and handles one file at a time:
        // with other new binaries queued for it, the stub did not start for 3 s, the 1 s deadline
        // killed it before `sleep` ran, and this exited "the command never started" (#387). Once
        // checked, the stub execs in milliseconds.
        guard BlockingSpawn.run(stub, ["warm-up"], timeoutSeconds: 30) == 0 else {
            finish(1, nap, "the stub would not run")
        }
        let started = Date()
        let call = Task.detached {
            var executor = ToolExecutor()
            executor.containerBinaryPath = { stub }
            return await executor.runCommand("true", cwd: nil, useSandbox: true, timeoutSeconds: timeout)
        }
        // The deadline, the runner's SIGTERM grace, then the delete's own spawn.
        await watch(nap: nap, deadline: started.addingTimeInterval(timeout + ProcessGroupRunner.terminateGraceSeconds + 2),
                    done: { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("delete --force iris-run-") },
                    what: "the one-off container's delete")
        _ = call
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
    /// With `done`, polls for that to hold instead of for `target` to be gone.
    private static func watch(nap: String, target: String? = nil, deadline: Date?,
                              act: () -> Date = { .distantFuture },
                              done: (() -> Bool)? = nil, what: String? = nil) async {
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
        let pending = done.map { d in { !d() } } ?? { exists(needle) }
        while pending(), Date() < until { usleep(50_000) }
        let survived = pending()
        hold.release()
        finish(survived ? 1 : 0, nap, survived ? "\(what ?? needle) outlived its kill deadline with the pool held" : "")
    }

    private static func finish(_ code: Int32, _ nap: String, _ message: String) -> Never {
        _ = spawnAndWait("/usr/bin/pkill", ["-9", "-f", shellMarker(nap)])
        _ = spawnAndWait("/usr/bin/pkill", ["-9", "-f", "sleep \(nap)"])
        if !message.isEmpty { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        exit(code)
    }

    private static func marker() -> String { "30.\(Int.random(in: 100_000...999_999))" }

    static func exists(_ pattern: String) -> Bool { spawnAndWait("/usr/bin/pgrep", ["-f", pattern]) == 0 }

    /// `BlockingSpawn` rather than `Process`, so the check owes nothing to a run loop or a queue:
    /// it is the blocked thread itself that waits.
    static func spawnAndWait(_ path: String, _ arguments: [String]) -> Int32 {
        BlockingSpawn.run(path, arguments) ?? -1
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
