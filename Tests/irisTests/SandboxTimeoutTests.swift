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
        // `/bin/sh`, and nothing outside the base system: the shell traps SIGTERM so the ladder's
        // second rung is the only way out of it. The sleep is inside a loop on purpose — the rung
        // before SIGTERM kills the shell's children, and a shell waiting on a single `sleep` would
        // fall straight through when that one died, which is not what this is testing. The nap is
        // a duration nothing else would be sleeping for, so the teardown below can find any child
        // orphaned between the last `pkill -P` and the SIGKILL, and reaches nothing of anyone
        // else's. The marker is in the shell's own argv alone, so the assertion is about the shell.
        let nap = "9.\(Int.random(in: 100_000...999_999))"
        let script = "trap '' TERM; while :; do sleep \(nap); done   # \(marker)"
        defer { Self.killAll(matching: "sleep \(nap)") }
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
        // SIGTERM was ignored, so it took the grace period plus SIGKILL — but not the full sleep.
        #expect(wall >= 1 + CLIProcessRunner.killGraceSeconds)
        #expect(wall < 9)
        #expect(!Self.processExists(matching: marker), "the shell that would not take SIGTERM is gone")
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

    /// H1: the same orphan, but the child does not hang around to keep it company. The process is
    /// reaped within milliseconds while the pipe it handed on stays open, so "is the child still
    /// running?" is exactly the wrong question to ask about whether anyone has been answered.
    @Test("a child that exits and leaves an orphan on the pipes cannot outlast the deadline", .timeLimit(.minutes(1)))
    func exitedChildWithOrphanCannotOutlastDeadline() async throws {
        let marker = "60.\(Int.random(in: 100_000...999_999))"
        let script = "(sleep \(marker) &) ; echo done"
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

    /// R27: a call with no deadline at all — `exec` takes an optional one, and a session command
    /// that declares none gets here — still must not wait on a stranger's file descriptor. The
    /// child exits; whatever is still holding the read open gets the post-exit grace and no more.
    @Test("a call with no deadline returns after its child exits, orphan or no orphan", .timeLimit(.minutes(1)))
    func unboundedCallReturnsAfterExit() async throws {
        let marker = "60.\(Int.random(in: 100_000...999_999))"
        let script = "(sleep \(marker) &) ; echo created"
        defer { Self.killAll(matching: "sleep \(marker)") }

        let started = Date()
        let r = try await CLIProcessRunner(executable: "/bin/sh").run(["-c", script], timeoutSeconds: nil)
        #expect(r.stdout.contains("created"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// H1: a call entered on a task that was *already* cancelled. Swift runs a cancellation
    /// handler's `onCancel` before the operation in that case, so the kill ladder has already been
    /// down and up against a process that does not exist. The launch must then not happen at all:
    /// a child started after its own ladder has nobody reading its pipes, no deadline, and a caller
    /// who has already been told the call was cancelled.
    @Test("a call entered on an already-cancelled task launches nothing", .timeLimit(.minutes(1)))
    func preCancelledCallLaunchesNothing() async throws {
        let marker = "41.\(Int.random(in: 100_000...999_999))"
        defer { Self.killAll(matching: "sleep \(marker)") }
        let task = Task {
            // Enters `run` only once the cancellation has landed, so this is the already-cancelled
            // case every time rather than whenever the scheduler happens to oblige.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return try await CLIProcessRunner(executable: "/bin/sh").run(["-c", "sleep \(marker)"])
        }
        task.cancel()

        let started = Date()
        var thrown: Error?
        do { _ = try await task.value } catch { thrown = error }

        #expect(thrown is CancellationError)
        #expect(Date().timeIntervalSince(started) < 10, "and it says so promptly")
        #expect(!Self.processExists(matching: "sleep \(marker)"),
                "the child was never launched, so there is nothing to outlive the call")
    }

    /// H1, the other half: the ladder must not signal a pid that is not a pid. `kill(0, …)` is not
    /// a no-op — it reaches every process in Iris's own process group, which is the app and, under
    /// `scripts/run-dev.sh`, the shell that started it. Driven through the ladder's own seam, so
    /// nothing real is signalled even when the guard is missing.
    @Test("the kill ladder signals nothing while there is no pid to signal", .timeLimit(.minutes(1)))
    func ladderNeverSignalsPidZero() async {
        let signalled = Locked<[Int32]>([])
        let children = Locked<[pid_t]>([])
        let terminated = Locked(0)
        let child = CLIProcessRunner.Child(
            pid: { 0 },
            // The window the guard exists for: a process that reads as running while its pid is
            // still 0, which is where the old code reached `kill(0, SIGKILL)`.
            isRunning: { true },
            terminate: { terminated.mutate { $0 += 1 } },
            killChildren: { pid in children.mutate { $0.append(pid) } },
            signal: { _, sig in signalled.mutate { $0.append(sig) } })
        let answered = Locked<Error?>(nil)

        await CLIProcessRunner.enforce({ CancellationError() }, on: child,
                                       hasAnswered: { false },
                                       fail: { error in answered.mutate { $0 = error } })

        #expect(children.value.isEmpty, "no pkill -P 0")
        #expect(signalled.value.isEmpty, "and no kill(0, SIGKILL)")
        #expect(terminated.value == 0)
        #expect(answered.value is CancellationError, "the caller is still answered")
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

    /// R31: a create that outlives its own ceiling arrives as an ordinary timeout, and is said in
    /// minutes rather than as the error's description.
    @Test("a create that times out is reported in words, not as a Swift error")
    func createTimeoutReadsAsASentence() async {
        let rt = MockRuntime()
        rt.nextCreateError = ContainerRuntimeError.timedOut(elapsedSeconds: 1_200.4)
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })

        let out = await m.run(command: "a", conversationId: UUID(), workspace: "/ws")

        #expect(out.contains("did not start within 20 minutes"))
        #expect(!out.contains("timedOut"))
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
    @Test("two callers racing with different mounts each get their own container",
          .timeLimit(.minutes(1)))
    func racingMountsEachGetTheirOwn() async {
        // A create that parks, so the second caller is genuinely coalesced onto the first's
        // barrier rather than arriving after it has already finished — which is what an
        // instantaneous mock made this test do most of the time, passing on the sequential path.
        let rt = HeldCreateRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()

        async let first = m.run(command: "a", conversationId: id, workspace: "/ws",
                                extraMounts: ["/a:/a:ro"])
        await rt.waitUntilParked()
        async let second = m.run(command: "b", conversationId: id, workspace: "/ws",
                                 extraMounts: ["/b:/b:ro"])
        try? await Task.sleep(nanoseconds: 150_000_000)   // the second joins the barrier behind it
        rt.release()
        _ = await (first, second)

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

    /// L11: two callers settle on the first retry, but the retry can itself be coalesced onto a
    /// third caller's create. Every caller either runs in the mounts it asked for or does not run.
    @Test("three callers racing with three mount sets never run in another's mounts",
          .timeLimit(.minutes(1)))
    func threeWayMountRace() async {
        // Held, for the same reason as the two-way race: with an instantaneous create the three
        // callers mostly run one after another and never contend at all.
        let rt = HeldCreateRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        let sets = ["/a:/a:ro", "/b:/b:ro", "/c:/c:ro"]
        let outcomes = await withTaskGroup(of: String.self) { g -> [String] in
            for mount in sets {
                g.addTask { await m.run(command: "x", conversationId: id, workspace: "/ws", extraMounts: [mount]) }
            }
            await rt.waitUntilParked()
            try? await Task.sleep(nanoseconds: 150_000_000)   // the other two reach the barrier
            rt.release()
            var all: [String] = []
            for await o in g { all.append(o) }
            return all
        }
        // Whatever each caller got, it was its own mounts or nothing at all.
        for outcome in outcomes {
            #expect(outcome == "ok" || outcome == SandboxSessionManager.mountsContendedError)
        }
        // And every container that was built was built for one of the three, never a blend.
        for built in rt.createdMounts {
            #expect(sets.contains { built == ["/ws:/ws", $0] })
        }
    }

    /// A runtime whose first create parks until the test releases it, and which says when it has
    /// parked, so the interleaving the mount agreement exists for happens on purpose rather than
    /// when the scheduler obliges. A continuation rather than a polled flag: `waitUntilParked`
    /// then means "the barrier is occupied", which is the precondition every test below needs and
    /// a sleep can only hope for.
    private final class HeldCreateRuntime: ContainerRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var held = false
        private var released = false
        private var parked = false
        private var gate: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private(set) var created: [[String]] = []
        private(set) var removed: [String] = []

        /// Lets the parked create finish. Safe before anything has parked: the next create through
        /// simply does not stop.
        func release() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { gate = nil }
                return gate
            }
            waiting?.resume()
        }

        /// Suspends until the first create is inside the barrier.
        func waitUntilParked() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let already = lock.withLock { () -> Bool in
                    if parked { return true }
                    arrival = cont
                    return false
                }
                if already { cont.resume() }
            }
        }

        func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws {
            let first = lock.withLock { () -> Bool in
                if held { return false }
                held = true
                return true
            }
            if first {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    var goOn = false
                    var arrived: CheckedContinuation<Void, Never>?
                    lock.withLock {
                        parked = true
                        arrived = arrival
                        arrival = nil
                        if released { goOn = true } else { gate = cont }
                    }
                    arrived?.resume()
                    if goOn { cont.resume() }
                }
            }
            lock.withLock { created.append(mounts) }
        }
        func ensureIsolatedNetwork(named name: String) async throws {}
        func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws
            -> (stdout: String, stderr: String, exitCode: Int32) { ("ok", "", 0) }
        func remove(name: String) async { lock.withLock { removed.append(name) } }
        func list(prefix: String) async -> [String] { [] }

        var createdMounts: [[String]] { lock.withLock { created } }
        var removedNames: [String] { lock.withLock { removed } }
    }

    /// L19: the refusal branch, forced rather than hoped for. The winner parks inside its create;
    /// the loser joins the barrier behind it and is handed a container with somebody else's
    /// mounts. It must be refused — and, per L16, it must not take the winner's container down on
    /// its way out, which would cost a caller that did nothing wrong a recreate and a reset notice.
    @Test("a caller that cannot have its own mounts is refused and leaves the winner's container alone",
          .timeLimit(.minutes(1)))
    func contendedMountsRefuseWithoutCollateral() async {
        let rt = HeldCreateRuntime()
        // One attempt, so the first disagreement is the give-up branch. Two racing callers reach it
        // only on a bad day; this test is about what happens when they do.
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" }, mountAgreementAttempts: 1)
        let id = UUID()

        async let winner = m.run(command: "w", conversationId: id, workspace: "/ws",
                                 extraMounts: ["/a:/a:ro"])
        await rt.waitUntilParked()                           // the winner is inside its create
        async let loser = m.run(command: "l", conversationId: id, workspace: "/ws",
                                extraMounts: ["/b:/b:ro"])
        try? await Task.sleep(nanoseconds: 150_000_000)      // the loser joins the barrier behind it
        rt.release()
        let outcomes = await (winner, loser)

        #expect(outcomes.0 == "ok")
        #expect(outcomes.1 == SandboxSessionManager.mountsContendedError,
                "the loser ran nothing rather than running in the winner's mounts")
        #expect(rt.createdMounts == [["/ws:/ws", "/a:/a:ro"]], "and no second container was built")
        #expect(rt.removedNames.isEmpty, "the winner's container is still standing")
        #expect(await m.hasSession(id), "and its session with it")
    }

    /// L13: a cancelled command is not a dead container, and it says so in its own words rather
    /// than borrowing the timeout's.
    @Test("a cancelled exec reports cancellation and keeps the session")
    func cancelledExecKeepsSession() async {
        let rt = MockRuntime()
        let m = SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" })
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        rt.nextExecError = CancellationError()

        let out = await m.run(command: "b", conversationId: id, workspace: "/ws", timeoutSeconds: 30)

        #expect(out == "Error: the command was cancelled.")
        #expect(rt.createdCount == 1)
        #expect(rt.removedNames.isEmpty)
        #expect(await m.hasSession(id))
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
        executor.sandboxSession = { _, _, _, _, _, timeoutSeconds in
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

    // MARK: - run_command's sandboxed branch mounts the grant (#282 §0.10)

    /// What the sandboxed branch handed the session: the workspace, the extra mounts, the network.
    private final class CapturedSession: @unchecked Sendable {
        private let lock = NSLock()
        private var workspace: String?; private var mounts: [String] = []; private var network: NetworkMode = .default
        func set(_ w: String?, _ m: [String], _ n: NetworkMode) { lock.withLock { workspace = w; mounts = m; network = n } }
        var value: (workspace: String?, mounts: [String], network: NetworkMode) { lock.withLock { (workspace, mounts, network) } }
    }

    private func capturingExecutor() -> (ToolExecutor, CapturedSession) {
        let captured = CapturedSession()
        var executor = ToolExecutor()
        executor.sandboxSession = { _, _, workspace, extraMounts, network, _ in
            captured.set(workspace, extraMounts, network); return "Success"
        }
        return (executor, captured)
    }

    @Test("the sandboxed branch mounts exactly the grant: its working directory, the rest as extras, its network")
    func sandboxedBranchMountsTheGrant() async {
        let (executor, captured) = capturingExecutor()
        let grant = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", target: "/gh", readOnly: true)])
        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/p",
                                   conversationId: UUID(), useSandbox: true, grant: grant)
        #expect(captured.value.workspace == "/p")
        #expect(captured.value.mounts == ["/q:/gh:ro"], "the working directory is mounted by mountList; only the rest ride as extras")
        #expect(captured.value.network == .isolated)

        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/p",
                                   conversationId: UUID(), useSandbox: true, grant: JobGrant(mounts: grant.mounts, network: true))
        #expect(captured.value.network == .default)

        // No read-write mount: the working directory is `/` (§0.6), whatever cwd says.
        let ro = JobGrant(mounts: [ContainerMount(source: "/q", readOnly: true)])
        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/somewhere",
                                   conversationId: UUID(), useSandbox: true, grant: ro)
        #expect(captured.value.workspace == nil && captured.value.mounts == ["/q:ro"])

        _ = await executor.execute(name: "run_command", args: ["command": .string("x")], cwd: "/ws",
                                   conversationId: UUID(), useSandbox: true)
        #expect(captured.value.workspace == "/ws" && captured.value.mounts.isEmpty && captured.value.network == .default, "no grant, no change")
    }

    @Test("a granted conversation whose workspacePath was moved still mounts only the grant (§0.10)")
    func movedWorkspaceDoesNotMoveTheMount() async {
        let (executor, captured) = capturingExecutor()
        let grant = JobGrant(mounts: [ContainerMount(source: "/Users/me/proj")])
        // `cwd` is what the dispatcher hands over from `conversation.workspacePath`; here it has
        // been pointed at home. The container must not see it.
        _ = await executor.execute(name: "run_command", args: ["command": .string("cat ~/.ssh/id_rsa")], cwd: "/Users/me",
                                   conversationId: UUID(), useSandbox: true, grant: grant)
        #expect(captured.value.workspace == "/Users/me/proj")
        #expect(captured.value.mounts.isEmpty)
    }
}
