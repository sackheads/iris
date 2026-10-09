import Testing
import Foundation
import Darwin
import os
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
        let log: String = Starvation.messageFile()
        await #expect(processExitsWith: .success) { [log = log as String] in
            await Starvation.runCommandTimeout(log: log)
        }
        Starvation.report(log)
    }

    @Test("ProcessGroupRunner.terminate SIGKILLs after the grace while the pool is held")
    func runnerTerminateOffPool() async {
        let log: String = Starvation.messageFile()
        await #expect(processExitsWith: .success) { [log = log as String] in
            await Starvation.runnerTerminate(log: log)
        }
        Starvation.report(log)
    }

    @Test("the container runner's deadline SIGKILLs a SIGTERM-ignoring child while the pool is held")
    func containerRunnerDeadlineOffPool() async {
        let log: String = Starvation.messageFile()
        await #expect(processExitsWith: .success) { [log = log as String] in
            await Starvation.containerRunnerDeadline(log: log)
        }
        Starvation.report(log)
    }

    @Test("cancelling a container runner SIGKILLs a SIGTERM-ignoring child while the pool is held")
    func containerRunnerCancelOffPool() async {
        let log: String = Starvation.messageFile()
        await #expect(processExitsWith: .success) { [log = log as String] in
            await Starvation.containerRunnerCancel(log: log)
        }
        Starvation.report(log)
    }

    /// #377: the one-off `container run`'s delete is started by the runner's ladder, not by a
    /// `Task` after `run_command` returns. A stub stands in for the `container` binary, so no VM
    /// is involved; the in-VM group kill on a real VM is `SandboxRealVMTests`.
    @Test("a timed-out one-off container is deleted while the pool is held")
    func ephemeralDeleteOffPool() async {
        let log: String = Starvation.messageFile()
        await #expect(processExitsWith: .success) { [log = log as String] in
            await Starvation.ephemeralDelete(log: log)
        }
        Starvation.report(log)
    }
}

/// The scenarios, run inside the exit-test child. Each exits the process itself: 0 when the
/// command was gone in time, 1 when it was not, 2 when the pool could not be held (the scenario
/// would then prove nothing).
enum Starvation {
    static let timeout: Double = 1

    /// Where `finish` writes its message, and when the scenario began. Set once, first thing, in
    /// the exit-test child, which runs nothing but this one scenario.
    nonisolated(unsafe) private static var messagePath: String?
    nonisolated(unsafe) private static var began = Date()

    private static func begin(_ log: String) {
        messagePath = log
        began = Date()
    }

    /// A file for the child's `finish` message. The message names which way a scenario failed —
    /// "never started" or "outlived", and when — and the parent cannot read the child's stderr
    /// once the exit test has failed: `#expect(processExitsWith:)` returns nil then (#421).
    static func messageFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("iris-421-\(UUID().uuidString)").path
    }

    /// In the parent: records the child's message, if it left one, and removes the file.
    static func report(_ log: String) {
        defer { try? FileManager.default.removeItem(atPath: log) }
        guard let text = try? String(contentsOfFile: log, encoding: .utf8), !text.isEmpty else { return }
        Issue.record("exit-test child: \(text)")
    }

    /// When the call's task first ran. Every clock the product starts — `withTimeout`'s, the
    /// runner's watchdog — starts inside the call, so that is where a kill deadline is measured
    /// from. Measured from before `Task.detached` instead, it also charged the product for the
    /// pool scheduling the test's own task late: under load the call began 2.5 s in, and a kill
    /// that came on time by the product's clock was reported as outliving its deadline (#421).
    private static let callBegan = OSAllocatedUnfairLock<Date?>(initialState: nil)
    static func noteCallBegan() { callBegan.withLock { $0 = Date() } }
    private static func callBeganText() -> String {
        callBegan.withLock { $0 }.map { String(format: "call began at %.2f s", $0.timeIntervalSince(began)) }
            ?? "call not begun"
    }

    private static func elapsed() -> String { String(format: "%.2f s", Date().timeIntervalSince(began)) }

    static func runCommandTimeout(log: String) async {
        begin(log)
        let nap = marker()
        let call = Task.detached {
            noteCallBegan()
            return await ToolExecutor().runCommand("trap '' TERM; sleep \(nap); true", cwd: nil, timeoutSeconds: timeout)
        }
        await watch(nap: nap, budget: timeout + ProcessGroupRunner.terminateGraceSeconds + 2)
        _ = call
    }

    static func runnerTerminate(log: String) async {
        begin(log)
        let nap = marker()
        let runner = ProcessGroupRunner()
        let call = Task.detached {
            await runner.run(executable: "/bin/zsh", arguments: ["-c", "trap '' TERM; sleep \(nap); true"],
                             environment: nil, currentDirectory: nil)
        }
        await watch(nap: nap, budget: nil) {
            runner.terminate()
            return Date().addingTimeInterval(ProcessGroupRunner.terminateGraceSeconds + 2)
        }
        _ = call
    }

    static func containerRunnerDeadline(log: String) async {
        begin(log)
        let nap = marker()
        let call = Task.detached {
            noteCallBegan()
            return try await CLIProcessRunner(executable: "/bin/sh")
                .run(["-c", loop(nap)], timeoutSeconds: Int(timeout))
        }
        await watch(nap: nap, target: shellMarker(nap), budget: timeout + CLIProcessRunner.killGraceSeconds + 2)
        _ = call
    }

    static func containerRunnerCancel(log: String) async {
        begin(log)
        let nap = marker()
        let call = Task.detached {
            try await CLIProcessRunner(executable: "/bin/sh")
                .run(["-c", loop(nap)], timeoutSeconds: 60)
        }
        await watch(nap: nap, target: shellMarker(nap), budget: nil) {
            // Cancelled from the blocked thread: `onCancel` runs here, synchronously, and anything
            // it hands to the pool will not run until the hold is released.
            call.cancel()
            return Date().addingTimeInterval(CLIProcessRunner.killGraceSeconds + 2)
        }
    }

    static func ephemeralDelete(log: String) async {
        begin(log)
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
        let call = Task.detached {
            noteCallBegan()
            var executor = ToolExecutor()
            executor.containerBinaryPath = { stub }
            return await executor.runCommand("true", cwd: nil, useSandbox: true, timeoutSeconds: timeout)
        }
        // The deadline, the runner's SIGTERM grace, then the delete's own spawn.
        await watch(nap: nap, budget: timeout + ProcessGroupRunner.terminateGraceSeconds + 2,
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
    /// the deadline passes. `budget` is that deadline in seconds from when the call began
    /// (`noteCallBegan`); nil leaves it to `act`.
    /// With `done`, polls for that to hold instead of for `target` to be gone.
    private static func watch(nap: String, target: String? = nil, budget: Double?,
                              act: () -> Date = { .distantFuture },
                              done: (() -> Bool)? = nil, what: String? = nil) async {
        let started = "^sleep \(nap)"
        let appeared = Date().addingTimeInterval(5)
        while !exists(started), Date() < appeared { usleep(20_000) }
        guard exists(started) else { finish(1, nap, "the command never started (gave up at \(elapsed()), \(callBeganText()))") }
        let appearedAt = elapsed()
        let needle = target ?? started

        let hold = PoolHold()
        hold.engage()
        guard hold.isHeld() else {
            hold.release()
            finish(2, nap, "could not hold the cooperative pool")
        }
        let acted = act()
        // The command was seen, so the call that spawned it has begun and noted when.
        let until = budget.map { (callBegan.withLock { $0 } ?? began).addingTimeInterval($0) } ?? acted
        let pending = done.map { d in { !d() } } ?? { exists(needle) }
        while pending(), Date() < until { usleep(50_000) }
        let survived = pending()
        hold.release()
        finish(survived ? 1 : 0, nap, survived
               ? "\(what ?? needle) outlived its kill deadline with the pool held (command seen at \(appearedAt), gave up at \(elapsed()), \(callBeganText()))"
               : "")
    }

    private static func finish(_ code: Int32, _ nap: String, _ message: String) -> Never {
        _ = spawnAndWait("/usr/bin/pkill", ["-9", "-f", shellMarker(nap)])
        _ = spawnAndWait("/usr/bin/pkill", ["-9", "-f", "sleep \(nap)"])
        if !message.isEmpty {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            if let messagePath { try? message.write(toFile: messagePath, atomically: true, encoding: .utf8) }
        }
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
