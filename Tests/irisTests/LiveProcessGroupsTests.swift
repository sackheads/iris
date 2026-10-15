import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decision 17: every `ProcessGroupRunner` group is recorded at spawn and dropped once its
/// leader is reaped, so a stopping CLI can end them. Each test has a registry of its own: the
/// shared one belongs to whatever else is running in this process (invariant 7).
@Suite("LiveProcessGroups (#463)", .timeLimit(.minutes(1)))
struct LiveProcessGroupsTests {
    /// `waitUntilEmpty`, off the pool: it blocks its caller with a `usleep` poll.
    private func drained(_ registry: LiveProcessGroups, within seconds: TimeInterval) async -> Bool {
        await offPool { registry.waitUntilEmpty(within: seconds) }
    }

    private func spawn(_ registry: LiveProcessGroups, _ script: String)
        async throws -> (ProcessGroupRunner, Task<Result<ProcessGroupRunner.Output, Error>, Never>) {
        let runner = ProcessGroupRunner(registry: registry)
        let task = Task { await runner.run(executable: "/bin/sh", arguments: ["-c", script], environment: nil, currentDirectory: nil) }
        var waited = 0
        while runner.processIdentifier == 0, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        try #require(runner.processIdentifier > 0, "spawned")
        return (runner, task)
    }

    /// A group whose SIGTERM is ignored, returned only once the shell has run its `trap`: a pid
    /// alone does not mean the trap is set, and a SIGTERM that beats it ends the group at rung one.
    /// `script` maps the readiness file's path to the command, which writes it once its trap is set.
    private func spawnIgnoringTerm(_ registry: LiveProcessGroups,
                                   _ script: (String) -> String = { "trap '' TERM; : > '\($0)'; sleep 30" })
        async throws -> (ProcessGroupRunner, Task<Result<ProcessGroupRunner.Output, Error>, Never>) {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("iris-lpg-\(UUID().uuidString)").path
        defer { unlink(ready) }
        let spawned = try await spawn(registry, script(ready))
        var waited = 0
        while !FileManager.default.fileExists(atPath: ready), waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        try #require(FileManager.default.fileExists(atPath: ready), "trap set")
        return spawned
    }

    @Test("a running group is registered, and leaves the registry when it finishes")
    func registeredWhileRunning() async throws {
        let registry = LiveProcessGroups()
        // Long enough that no load can reap it before the count is read; ended by the test.
        let (runner, task) = try await spawn(registry, "sleep 30")
        #expect(registry.count == 1)
        runner.terminate()
        _ = try await value(of: task, within: 10)
        // Bounded, not read at once: the drain is the runner's to finish (#490 review).
        #expect(await drained(registry, within: 5))
    }

    @Test("waitUntilEmpty returns true once the groups drain, and false at its bound while one lives")
    func waitUntilEmptyIsBounded() async throws {
        let registry = LiveProcessGroups()
        #expect(await drained(registry, within: 0.1), "an empty registry is already drained")
        let (runner, task) = try await spawnIgnoringTerm(registry)
        let started = Date()
        #expect(await drained(registry, within: 0.3) == false)
        #expect(Date().timeIntervalSince(started) >= 0.3)
        runner.terminate()   // SIGTERM is ignored, so this drains at the SIGKILL rung, 2 s on
        #expect(await drained(registry, within: 5))
        _ = try await value(of: task, within: 10)
    }

    @Test("a group stays registered until its SIGKILL rung, though its leader died at SIGTERM")
    func leavesOnlyAfterTheLadder() async throws {
        let registry = LiveProcessGroups()
        // The leader dies at SIGTERM; its child ignores it and holds no pipe. The stray rung
        // SIGKILLs the child about 1 s on, but the group stays listed until the ladder's SIGKILL
        // rung at 2 s.
        let (runner, task) = try await spawnIgnoringTerm(registry) {
            "(trap '' TERM; : > '\($0)'; exec sleep 30) >/dev/null 2>&1 & wait"
        }
        runner.terminate()
        #expect(await drained(registry, within: 1) == false, "the SIGKILL rung is 2 s on: the group must still be listed")
        #expect(await drained(registry, within: 5))
        guard case .success(let out) = try await value(of: task, within: 10) else { Issue.record("spawn failed"); return }
        #expect(out.status == 128 + SIGTERM)
    }

    @Test("terminateAll ends every group with SIGTERM, through each runner's own ladder")
    func terminateAllEndsThemAll() async throws {
        let registry = LiveProcessGroups()
        let (_, a) = try await spawn(registry, "sleep 30")
        let (_, b) = try await spawn(registry, "sleep 30")
        #expect(registry.count == 2)
        registry.terminateAll()
        for task in [a, b] {
            guard case .success(let out) = try await value(of: task, within: 10) else { Issue.record("spawn failed"); continue }
            #expect(out.status == 128 + SIGTERM)
            #expect(out.killed)
        }
        #expect(await drained(registry, within: 5))
    }

    @Test("terminateAll reaches a group that ignores SIGTERM with the SIGKILL rung")
    func terminateAllEscalates() async throws {
        let registry = LiveProcessGroups()
        let (_, task) = try await spawnIgnoringTerm(registry)
        registry.terminateAll()
        guard case .success(let out) = try await value(of: task, within: 10) else { Issue.record("spawn failed"); return }
        #expect(out.status == 128 + SIGKILL)
    }

    @Test("killAll SIGKILLs every group before it returns")
    func killAllIsImmediate() async throws {
        let registry = LiveProcessGroups()
        let (runner, task) = try await spawnIgnoringTerm(registry)
        let pid = runner.processIdentifier
        registry.killAll()
        guard case .success(let out) = try await value(of: task, within: 5) else { Issue.record("spawn failed"); return }
        #expect(out.status == 128 + SIGKILL)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    /// Fix round 1: a runner the kill could not see must not spawn behind it. Closing and the
    /// snapshot are one lock, and a runner is admitted just before its spawn, so after the kill a
    /// runner is refused and nothing runs.
    @Test("a closed registry refuses a runner, and no process appears")
    func closedRegistryRefusesARunner() async throws {
        let registry = LiveProcessGroups()
        registry.killAll()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("iris-lpg-closed-\(UUID().uuidString)").path
        defer { unlink(marker) }
        let runner = ProcessGroupRunner(registry: registry)
        let task = Task { await runner.run(executable: "/usr/bin/touch", arguments: [marker], environment: nil, currentDirectory: nil) }
        let result = try await value(of: task, within: 10)
        guard case .failure(let error) = result else { Issue.record("it ran: \(result)"); return }
        #expect(error is CancellationError)
        #expect(runner.processIdentifier == 0)
        #expect(!FileManager.default.fileExists(atPath: marker), "nothing was spawned")
        #expect(registry.count == 0)
    }
}
