import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decision 16 with real signals. Each case is an exit test, a child process of its own,
/// because installing handlers in the shared test process would stop Ctrl-C from ending the run.
@Suite("CLI signals (#463)", .timeLimit(.minutes(1)))
struct CLISignalTests {
    /// Set from the signal source's queue, read by the exit test's body.
    final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.withLock { fired = true } }
        var value: Bool { lock.withLock { fired } }
    }

    /// SIG_DFL is 0 and SIG_IGN is 1; anything else is a handler.
    static func raw(_ signal: Int32) -> UInt {
        var now = sigaction()
        sigaction(signal, nil, &now)
        return unsafeBitCast(now.__sigaction_u, to: UInt.self)
    }

    @Test("the handler is a do-nothing catch with SA_RESTART, and the signal reaches its source")
    func installCatchesAndRestarts() async {
        await #expect(processExitsWith: .success) {
            let fired = Fired()
            let installation = CLISignals.install(onSignal: { if $0 == SIGHUP { fired.set() } })
            // Exit 5 also means this `swift test` itself started with SIGINT or SIGHUP ignored
            // (`nohup`, a non-interactive `&`): run it in the foreground.
            guard installation.installed == CLISignals.stopping else { exit(5) }
            for signal in CLISignals.stopping {
                guard CLISignalTests.raw(signal) > 1 else { exit(2) }
                var now = sigaction()
                sigaction(signal, nil, &now)
                guard now.sa_flags & SA_RESTART != 0 else { exit(3) }
            }
            kill(getpid(), SIGHUP)   // its default would end this process
            // Polled, not a semaphore wait: that warns in an async exit-test body (ruling P2).
            for _ in 0..<500 where !fired.value { try? await Task.sleep(nanoseconds: 10_000_000) }
            guard fired.value else { exit(4) }
            withExtendedLifetime(installation) {}
        }
    }

    @Test("nohup: an inherited ignore on SIGHUP or SIGINT is kept, and SIGTERM is caught anyway")
    func inheritedIgnoreIsKept() async {
        await #expect(processExitsWith: .success) {
            _ = signal(SIGHUP, SIG_IGN)
            _ = signal(SIGINT, SIG_IGN)
            _ = signal(SIGTERM, SIG_IGN)
            let installation = CLISignals.install(onSignal: { _ in })
            guard CLISignalTests.raw(SIGHUP) == 1, CLISignalTests.raw(SIGINT) == 1 else { exit(2) }
            guard CLISignalTests.raw(SIGTERM) > 1 else { exit(3) }
            guard installation.installed == [SIGTERM] else { exit(4) }
            kill(getpid(), SIGHUP)   // ignored: this process carries on
            withExtendedLifetime(installation) {}
        }
    }

    /// The `Process` half is the CLI's real configuration, not a check of the handler: Foundation
    /// resets dispositions in the child itself, so it passes with `SIG_IGN` installed too
    /// (measured, Task 14 mutation 5). The `ProcessGroupRunner` half is the check that bites.
    @Test("with the handlers installed a Process child dies of its own SIGTERM, and ProcessGroupRunner resets an inherited ignore")
    func childrenKeepTheDefaultDisposition() async {
        await #expect(processExitsWith: .success) {
            let installation = CLISignals.install(onSignal: { _ in })
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "kill -TERM $$; sleep 5"]
            guard (try? process.run()) != nil else { exit(2) }
            process.waitUntilExit()
            guard process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM else { exit(3) }
            // ProcessGroupRunner resets every disposition in the child (POSIX_SPAWN_SETSIGDEF), so it
            // is checked against a real inherited ignore: only that reset can make this child die.
            _ = signal(SIGTERM, SIG_IGN)
            let result = await ProcessGroupRunner(registry: LiveProcessGroups())
                .run(executable: "/bin/sh", arguments: ["-c", "kill -TERM $$; sleep 5"], environment: nil, currentDirectory: nil)
            guard case .success(let out) = result, out.status == 128 + SIGTERM else { exit(4) }
            withExtendedLifetime(installation) {}
        }
    }

    @Test("without handlers or an ignore, the shell child dies of its own SIGTERM: the probe itself is sound")
    func baselineWithoutHandlers() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "kill -TERM $$; sleep 5"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    @Test("a second SIGINT resets SIGINT, SIGKILLs the registered groups and _exits 130")
    func secondSignalKillsAndExits() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("iris-463-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        await #expect(processExitsWith: .exitCode(130)) { [path = pidFile.path as String] in
            let registry = LiveProcessGroups()
            let runner = ProcessGroupRunner(registry: registry)
            let running = Task { await runner.run(executable: "/bin/sleep", arguments: ["30"], environment: nil, currentDirectory: nil) }
            var waited = 0
            while runner.processIdentifier == 0, waited < 500 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
            }
            try? Data("\(runner.processIdentifier)".utf8).write(to: URL(fileURLWithPath: path))
            let stop = CLIStop(terminateGroups: { registry.terminateAll() }, killGroups: { registry.killAll() },
                               deleteContainers: {}, vacate: {},
                               exitNow: { code in
                                   // The real reset ran, once the second signal was delivered (#510).
                                   for _ in 0..<100 where CLISignalTests.raw(SIGINT) != 0 { usleep(10_000) }
                                   _exit(CLISignalTests.raw(SIGINT) == 0 ? code : 7)
                               })
            _ = stop.run.arm()
            let installation = CLISignals.install(onSignal: { stop.receive($0) })
            guard installation.installed.contains(SIGINT) else { exit(5) }   // run `swift test` in the foreground
            kill(getpid(), SIGINT)
            for _ in 0..<500 where stop.run.graceDeadline == nil { usleep(10_000) }
            kill(getpid(), SIGINT)   // exits from the signal queue
            for _ in 0..<500 { usleep(10_000) }
            withExtendedLifetime((running, installation)) {}
            exit(1)
        }
        let pid = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)))
        // A zombie until launchd reaps it, at most a moment. Polled off the pool.
        let gone = await polled(within: 2) { kill(pid, 0) == -1 && errno == ESRCH }
        #expect(gone, "the sleep's group was SIGKILLed before the exit")
    }

    /// Counts what the signal source hands on.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// A dispatch signal source coalesces: signals that land before its handler runs arrive as one
    /// event whose `data` is their count. The queue is suspended so both land first.
    @Test("two signals the source coalesces into one event are still two signals")
    func coalescedSignalsCountTwice() async {
        await #expect(processExitsWith: .success) {
            let queue = DispatchQueue(label: "iris.tests.signals")
            let tally = Tally()
            let installation = CLISignals.install([SIGTERM], queue: queue, onSignal: { _ in tally.bump() })
            queue.suspend()
            kill(getpid(), SIGTERM)
            kill(getpid(), SIGTERM)
            usleep(200_000)   // both are with the source before its queue runs
            queue.resume()
            for _ in 0..<500 where tally.value < 2 { usleep(10_000) }
            usleep(100_000)   // and no third
            withExtendedLifetime(installation) {}
            exit(tally.value == 2 ? 0 : 10 + Int32(min(tally.value, 9)))
        }
    }

    /// #510: a signal source hears a signal when it is posted, which can be before the kernel has
    /// delivered it to a thread (measured: 5 of 40 runs of a two-SIGINT repro). Exit-now used to
    /// reset SIGINT to its default from the source's handler, so the second SIGINT, the one that
    /// asked for the exit, could meet that default on its own delivery and end the CLI before the
    /// deletes and the vacate ran. Here the source's half of the second signal (`receive`) runs
    /// before its delivery: SIGINT must still be caught, and go to its default only once the
    /// second has been delivered, so the third is the one that ends the CLI.
    @Test("exit-now resets SIGINT on the second signal's delivery, not when its source hears it")
    func exitNowResetsOnDelivery() async {
        await #expect(processExitsWith: .exitCode(130)) {
            let deleting = Fired()
            let delivered = Fired()
            let stop = CLIStop(terminateGroups: {}, closeGroups: {}, drainGroups: { true }, killGroups: {},
                               deleteContainers: {
                                   deleting.set()
                                   // Longer than every check below, so a failed check exits first.
                                   for _ in 0..<1500 where !delivered.value { usleep(10_000) }
                               },
                               flush: {}, vacate: {}, exitNow: { _exit($0) })
            guard stop.run.arm() == nil else { exit(2) }
            // A queue of the test's own for the real signals, so `receive` below can block in the
            // deletes without holding up the source.
            let installation = CLISignals.install([SIGINT], queue: DispatchQueue(label: "iris.tests.510"),
                                                  onSignal: { stop.receive($0) })
            guard installation.installed == [SIGINT] else { exit(3) }   // run `swift test` in the foreground

            kill(getpid(), SIGINT)   // the clean stop, delivered
            for _ in 0..<500 where stop.run.graceDeadline == nil { usleep(10_000) }
            guard stop.run.graceDeadline != nil else { exit(4) }

            // The second signal as its source hears it, ahead of its delivery.
            DispatchQueue(label: "iris.tests.510.source").async { stop.receive(SIGINT) }
            for _ in 0..<300 where !deleting.value { usleep(10_000) }
            guard deleting.value else { exit(5) }
            guard CLISignalTests.raw(SIGINT) > 1 else { exit(6) }   // reset before the delivery
            kill(getpid(), SIGINT)   // now its delivery
            for _ in 0..<300 where CLISignalTests.raw(SIGINT) != 0 { usleep(10_000) }
            guard CLISignalTests.raw(SIGINT) == 0 else { exit(7) }   // and a third would end the CLI
            delivered.set()   // the deletes finish and exit-now `_exit`s with 130
            for _ in 0..<500 { usleep(10_000) }
            withExtendedLifetime(installation) {}
            exit(8)
        }
    }

    /// Blocks the calling thread on `gate`. Synchronous, so a pool thread can be held with it
    /// without the async-context warning.
    static func park(_ gate: DispatchSemaphore) { gate.wait() }

    /// Fix wave, finding 1: the first signal used to do nothing until the run's stop watcher got a
    /// pool thread, so under a held pool (#372) a Ctrl-C was lost. Every cooperative thread is
    /// parked on a semaphore (the probe task proves it), then a real SIGINT must still SIGTERM the
    /// registered group: the group drains at its SIGKILL rung, on the runner's queue.
    @Test("under a held cooperative pool, the first signal still SIGTERMs the run's host groups")
    func firstSignalActsOffThePool() async {
        await #expect(processExitsWith: .success) {
            let registry = LiveProcessGroups()
            let runner = ProcessGroupRunner(registry: registry)
            let running = Task { await runner.run(executable: "/bin/sleep", arguments: ["30"], environment: nil, currentDirectory: nil) }
            for _ in 0..<500 where runner.processIdentifier == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
            guard runner.processIdentifier > 0 else { exit(2) }
            let stop = CLIStop(terminateGroups: { registry.terminateAll() }, closeGroups: {}, drainGroups: { true },
                               killGroups: {}, deleteContainers: {}, resetInterrupt: { _ in }, flush: {}, vacate: {},
                               exitNow: { _ in _exit(3) })   // a first signal must not exit
            guard stop.run.arm() == nil else { exit(4) }
            let cancelled = Fired()
            stop.run.attachTurn { cancelled.set() }
            let installation = CLISignals.install([SIGINT], onSignal: { stop.receive($0) })
            guard installation.installed == [SIGINT] else { exit(5) }   // run `swift test` in the foreground

            // This body holds one pool thread; park every other, with spares.
            let gate = DispatchSemaphore(value: 0)
            let parked = Tally()
            let width = ProcessInfo.processInfo.activeProcessorCount
            for _ in 0..<(width + 4) { Task.detached { parked.bump(); CLISignalTests.park(gate) } }
            for _ in 0..<500 where parked.value < width - 1 { usleep(10_000) }
            let probe = Fired()
            Task.detached { probe.set() }
            usleep(300_000)
            guard !probe.value else { exit(6) }   // the pool is not held: the test proves nothing

            kill(getpid(), SIGINT)
            var drained = false
            for _ in 0..<800 { if registry.count == 0 { drained = true; break }; usleep(10_000) }   // rung at 2 s
            guard cancelled.value else { exit(7) }
            guard drained else { exit(8) }
            guard stop.run.graceDeadline != nil else { exit(9) }
            withExtendedLifetime((running, installation)) {}
            _exit(0)   // the parked threads never come back
        }
    }
}
