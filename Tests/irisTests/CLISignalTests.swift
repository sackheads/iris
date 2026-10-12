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
            let installation = CLISignals.install(onSignal: { _ in })
            let stop = CLIStop(terminateGroups: { registry.terminateAll() }, killGroups: { registry.killAll() },
                               deleteContainers: {}, vacate: {},
                               exitNow: { code in _exit(CLISignalTests.raw(SIGINT) == 0 ? code : 7) })   // the real reset ran
            _ = stop.run.arm()
            stop.receive(SIGINT)
            stop.receive(SIGINT)   // exits here
            withExtendedLifetime((running, installation)) {}
            exit(1)
        }
        let pid = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)))
        var gone = false
        for _ in 0..<200 {   // a zombie until launchd reaps it, at most a moment
            if kill(pid, 0) == -1 && errno == ESRCH { gone = true; break }
            usleep(10_000)
        }
        #expect(gone, "the sleep's group was SIGKILLed before the exit")
    }
}
