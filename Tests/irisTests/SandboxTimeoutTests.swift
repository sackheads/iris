import Testing
import Foundation
@testable import iris

/// The per-command deadline, end to end: the child process that outlives it is killed and reaped,
/// the session manager reports it in the same words the host path uses, and `run_command`'s
/// `timeout_seconds` actually reaches the runtime on the sandboxed branch.
///
/// No test here goes near the `container` binary, a daemon, or a VM (invariant 7). The one test
/// that spawns anything spawns `/bin/sh`, its own child, through the same injected executable the
/// runtime uses, and asserts afterwards that nothing survived it.
@Suite("Sandbox command timeout")
struct SandboxTimeoutTests {

    // MARK: - The runner kills what it starts

    @Test("a child that outlives its deadline is killed, reaped, and reported as a timeout", .timeLimit(.minutes(1)))
    func childKilledOnDeadline() async throws {
        // A duration nothing else on this machine would be sleeping for, so `pgrep` below can
        // only match this test's own child.
        let marker = "31.\(Int.random(in: 100_000...999_999))"
        let runner = CLIProcessRunner(executable: "/bin/sh")
        let started = Date()
        var thrown: Error?
        do {
            _ = try await runner.run(["-c", "sleep \(marker)"], timeoutSeconds: 1)
        } catch {
            thrown = error
        }
        let wall = Date().timeIntervalSince(started)

        let error = try #require(thrown as? ContainerRuntimeError)
        guard case .timedOut(let elapsed) = error else {
            Issue.record("expected .timedOut, got \(error)")
            return
        }
        #expect(elapsed >= 1)
        #expect(elapsed < 10)
        // It came back on the deadline (plus the SIGTERM grace), not after the full 31 s sleep.
        #expect(wall < 10)
        // And it left nothing running. SIGTERM reaches `sleep` directly — `sh -c '<one command>'`
        // execs it rather than forking — so the grace period is enough and SIGKILL is the backstop.
        #expect(!Self.processExists(matching: "sleep \(marker)"))
    }

    @Test("a child that ignores SIGTERM is SIGKILLed after the grace period", .timeLimit(.minutes(1)))
    func childKilledAfterGrace() async throws {
        let marker = "iris-kill-\(UUID().uuidString)"
        // Perl rather than a shell: it ignores SIGTERM outright and sleeps in-process, so the
        // only way out is SIGKILL. A shell would fork its `sleep`, and killing that child is
        // enough to let the shell fall through — which would test the wrong thing. The marker is
        // there so `pgrep -f` can find this process and nothing else.
        let script = "$SIG{TERM} = 'IGNORE'; sleep 9;   # \(marker)"
        let started = Date()
        var thrown: Error?
        do {
            _ = try await CLIProcessRunner(executable: "/usr/bin/perl").run(["-e", script], timeoutSeconds: 1)
        } catch {
            thrown = error
        }
        let wall = Date().timeIntervalSince(started)

        let error = try #require(thrown as? ContainerRuntimeError)
        guard case .timedOut = error else {
            Issue.record("expected .timedOut, got \(error)")
            return
        }
        // SIGTERM was ignored, so it took the grace period plus SIGKILL — but not the full sleep.
        #expect(wall >= 1 + CLIProcessRunner.killGraceSeconds)
        #expect(wall < 9)
        #expect(!Self.processExists(matching: marker))
    }

    /// R26: the deadline wins the wait. An orphan that inherited the child's stdout keeps the
    /// write end of the pipe open after every process we can reach is dead, so anything that waits
    /// for end-of-file waits on a process nobody owns. The call must still come back on time.
    @Test("an orphan holding the pipes cannot outlast the deadline", .timeLimit(.minutes(1)))
    func orphanCannotOutlastDeadline() async throws {
        let marker = "60.\(Int.random(in: 100_000...999_999))"
        // `( … & )` puts the first sleep in a subshell that exits at once, so that sleep is
        // reparented away from us: `pkill -P` cannot reach it, and it holds the inherited pipe.
        let script = "(sleep \(marker) &) ; sleep \(marker)"
        defer { Self.killAll(matching: "sleep \(marker)") }

        let started = Date()
        var thrown: Error?
        do {
            _ = try await CLIProcessRunner(executable: "/bin/sh").run(["-c", script], timeoutSeconds: 1)
        } catch {
            thrown = error
        }
        let wall = Date().timeIntervalSince(started)

        let error = try #require(thrown as? ContainerRuntimeError)
        guard case .timedOut = error else {
            Issue.record("expected .timedOut, got \(error)")
            return
        }
        #expect(wall < 10)
    }

    @Test("a child that finishes inside its deadline returns normally", .timeLimit(.minutes(1)))
    func childUnderDeadline() async throws {
        let r = try await CLIProcessRunner(executable: "/bin/sh").run(["-c", "echo ok; exit 3"], timeoutSeconds: 30)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
        #expect(r.exitCode == 3)
    }

    @Test("with no deadline a short child still returns", .timeLimit(.minutes(1)))
    func childNoDeadline() async throws {
        let r = try await CLIProcessRunner(executable: "/bin/sh").run(["-c", "echo hi"], timeoutSeconds: nil)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        #expect(r.exitCode == 0)
    }

    /// Kills anything whose argv matches `needle`, so a test that deliberately orphans a process
    /// takes it with it.
    private static func killAll(matching needle: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-f", needle]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// True when any process's argv matches `needle`. Its own `pgrep` is excluded by construction:
    /// the pattern is the sleep's argv, not this helper's.
    private static func processExists(matching needle: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", needle]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - The session manager reports it like the host does

    @Test("a timed-out exec reports the host's sentence and does not recreate the container")
    func sessionManagerReportsTimeout() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        _ = await m.run(command: "warm up", conversationId: id, workspace: "/ws")
        rt.nextExecError = ContainerRuntimeError.timedOut(elapsedSeconds: 30.4)

        let out = await m.run(command: "sleep 600", conversationId: id, workspace: "/ws", timeoutSeconds: 30)

        #expect(out == "Error: command timed out after 30 seconds")
        // A deadline is the command's answer, not a dead container: no recreate, no retry.
        #expect(rt.createdCount == 1)
        #expect(rt.removedNames.isEmpty)
        #expect(await m.hasSession(id))
    }

    @Test("a sandboxed timeout reads exactly like a host timeout")
    func sameShapeAsHost() {
        #expect(ToolExecutor.commandTimedOutMessage(seconds: 600) == "Error: command timed out after 600 seconds")
    }

    @Test("an exec that fails for any other reason still self-heals")
    func otherFailuresStillRetry() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        rt.failNextExec = true
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws", timeoutSeconds: 30)
        #expect(rt.createdCount == 2)
    }

    // MARK: - The session manager takes the mounts and the deadline

    @Test("extra mounts ride along with the workspace mount, workspace first")
    func extraMounts() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        _ = await m.run(command: "a", conversationId: UUID(), workspace: "/ws",
                        extraMounts: ["/data:/data:ro"], timeoutSeconds: 10)
        #expect(rt.createdMounts == [["/ws:/ws", "/data:/data:ro"]])
        #expect(rt.lastExecTimeout == 10)
    }

    @Test("a changed mount list recreates the container, like a changed workspace does")
    func mountChangeRecreates() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws", extraMounts: ["/data:/data:ro"])
        _ = await m.run(command: "b", conversationId: id, workspace: "/ws", extraMounts: ["/other:/other:ro"])
        #expect(rt.createdCount == 2)
        #expect(rt.removedNames.count == 1)
    }

    /// M3: the in-flight create barrier coalesces concurrent first-commands onto one create, and
    /// the winner's mounts are the ones the container got. The loser must not run in it — for a
    /// gate that would be its script running with another caller's mounts, once, silently.
    @Test("two callers racing with different mounts each get their own container")
    func racingMountsEachGetTheirOwn() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        await withTaskGroup(of: Void.self) { g in
            g.addTask { _ = await m.run(command: "a", conversationId: id, workspace: "/ws", extraMounts: ["/a:/a:ro"]) }
            g.addTask { _ = await m.run(command: "b", conversationId: id, workspace: "/ws", extraMounts: ["/b:/b:ro"]) }
            await g.waitForAll()
        }
        #expect(rt.createdMounts.contains(["/ws:/ws", "/a:/a:ro"]))
        #expect(rt.createdMounts.contains(["/ws:/ws", "/b:/b:ro"]))
    }

    /// L1: the reset notice is written once, by the call that recreated the container. A timeout
    /// on that very call must not be the thing that eats it — no later call can say it instead,
    /// because no later call is the one that recreated.
    @Test("a timeout on a just-recreated session still carries the reset notice")
    func timeoutKeepsResetNotice() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        await m.reapIdle(olderThan: 60, now: Date().addingTimeInterval(3600))
        rt.nextExecError = ContainerRuntimeError.timedOut(elapsedSeconds: 30.4)

        let out = await m.run(command: "b", conversationId: id, workspace: "/ws", timeoutSeconds: 30)

        #expect(out.hasPrefix("[sandbox]"))
        #expect(out.contains("reclaimed"))
        #expect(out.hasSuffix("Error: command timed out after 30 seconds"))
    }

    @Test("the same mount list reuses the container")
    func sameMountsReuse() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws", extraMounts: ["/data:/data:ro"])
        _ = await m.run(command: "b", conversationId: id, workspace: "/ws", extraMounts: ["/data:/data:ro"])
        #expect(rt.createdCount == 1)
    }

    // MARK: - run_command's timeout reaches the runtime

    /// Captures what the sandboxed branch of `run_command` hands the container session.
    private final class ForwardedTimeout: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func set(_ v: Int) { lock.withLock { value = v } }
        var seconds: Int? { lock.withLock { value } }
    }

    private func forwarded(args: [String: JSONValue]) async -> Int? {
        let captured = ForwardedTimeout()
        var executor = ToolExecutor()
        executor.sandboxSession = { _, _, _, timeoutSeconds in
            captured.set(timeoutSeconds)
            return "Success"
        }
        _ = await executor.execute(name: "run_command", args: args, cwd: "/ws",
                                   conversationId: UUID(), useSandbox: true)
        return captured.seconds
    }

    @Test("the sandboxed branch forwards run_command's timeout_seconds")
    func sandboxedBranchForwardsTimeout() async {
        #expect(await forwarded(args: ["command": .string("x"), "timeout_seconds": .int(45)]) == 45)
    }

    @Test("the forwarded timeout is the clamped one, not the model's raw number")
    func sandboxedBranchForwardsClampedTimeout() async {
        #expect(await forwarded(args: ["command": .string("x"), "timeout_seconds": .int(1)]) == 10)
        #expect(await forwarded(args: ["command": .string("x"), "timeout_seconds": .int(99_999)]) == 3600)
        #expect(await forwarded(args: ["command": .string("x"), "timeout_seconds": .double(90.5)]) == 90)
    }

    @Test("with no timeout_seconds the sandboxed branch forwards the default")
    func sandboxedBranchForwardsDefault() async {
        #expect(await forwarded(args: ["command": .string("x")]) == 600)
    }
}
