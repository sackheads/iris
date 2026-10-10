import Testing
import Foundation
@testable import IrisKit

/// #353: a host `run_command` runs in a process group of its own, and timeout and Stop kill the
/// whole group — SIGTERM, then SIGKILL — not just the shell, whose forked children would otherwise
/// be reparented and run on. After a normal exit, a background job still holding the pipes is
/// killed rather than waited for.
///
/// Every sleep carries a duration nothing else on this machine would be sleeping for, so `pgrep -f`
/// matches only this test's processes, and every test kills its markers on the way out so a
/// failure does not leak a process into the next run.
@Suite("run_command process group", .timeLimit(.minutes(1)))
struct RunCommandProcessGroupTests {

    @Test("a compound command past its deadline returns on time and leaves no child behind")
    func compoundTimeoutKillsChild() async {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        let started = Date()
        // `; true` stops zsh exec'ing `sleep` in its own place: the shell forks it, so killing the
        // shell's pid alone would leak it. (`Process.terminate()` happened to signal the group, which
        // is undocumented; this pins the behaviour now that the runner does it on purpose.)
        let out = await ToolExecutor().runCommand("sleep \(nap); true", cwd: nil, timeoutSeconds: 1)
        let wall = Date().timeIntervalSince(started)

        #expect(out == ToolExecutor.commandTimedOutMessage(seconds: 1))
        #expect(wall < 3, "returned after \(wall)s; the deadline was 1s")
        #expect(await Self.gone("sleep \(nap)", within: 4), "sleep \(nap) outlived the timeout")
    }

    @Test("a backgrounded grandchild is killed with the rest of the group")
    func backgroundedGrandchildKilled() async {
        let bg = Self.marker(), fg = Self.marker()
        defer { Self.killAll(bg); Self.killAll(fg) }
        let out = await ToolExecutor().runCommand("(sleep \(bg) &); sleep \(fg)", cwd: nil, timeoutSeconds: 1)

        #expect(out == ToolExecutor.commandTimedOutMessage(seconds: 1))
        #expect(await Self.gone("sleep \(bg)", within: 4), "the backgrounded sleep \(bg) survived")
        #expect(await Self.gone("sleep \(fg)", within: 4), "the foreground sleep \(fg) survived")
    }

    @Test("cancelling the caller (Stop) kills the group")
    func cancelKillsGroup() async throws {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        let task = Task { await ToolExecutor().runCommand("sleep \(nap); true", cwd: nil, timeoutSeconds: 60) }
        #expect(await Self.appears("sleep \(nap)", within: 5), "the command never started")
        let cancelled = Date()
        task.cancel()
        _ = try await value(of: task)
        #expect(Date().timeIntervalSince(cancelled) < 2, "the cancelled call did not return promptly")
        #expect(await Self.gone("sleep \(nap)", within: 4), "sleep \(nap) outlived the cancel")
    }

    @Test("a command that ignores SIGTERM is still gone after a timeout")
    func timeoutEscalatesToSigkill() async {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        let started = Date()
        let out = await ToolExecutor().runCommand("trap '' TERM; sleep \(nap); true", cwd: nil, timeoutSeconds: 1)
        #expect(out == ToolExecutor.commandTimedOutMessage(seconds: 1))
        #expect(Date().timeIntervalSince(started) < 3)
        // `Process.terminate()` sent SIGTERM and nothing after it, so this one used to run its full 30 s.
        #expect(await Self.gone("sleep \(nap)", within: ProcessGroupRunner.terminateGraceSeconds + 3),
                "sleep \(nap) survived the SIGKILL rung")
    }

    @Test("a group that ignores SIGTERM is SIGKILLed after the grace")
    func sigtermIgnoredThenKilled() async throws {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        let runner = ProcessGroupRunner()
        // `trap '' TERM` is inherited by `sleep` as SIG_IGN, so only the SIGKILL rung ends either.
        let running = Task {
            await runner.run(executable: "/bin/zsh", arguments: ["-c", "trap '' TERM; sleep \(nap); true"],
                             environment: nil, currentDirectory: nil)
        }
        // Anchored, so it matches `sleep` itself and not the shell's argv: the trap must be set
        // before the SIGTERM lands, and the shell only forks `sleep` after setting it.
        #expect(await Self.appears("^sleep \(nap)", within: 5), "the command never started")
        let started = Date()
        runner.terminate()
        let result = try await value(of: running)
        let wall = Date().timeIntervalSince(started)
        #expect(wall >= ProcessGroupRunner.terminateGraceSeconds - 0.2, "SIGTERM should not have ended it")
        #expect(wall < ProcessGroupRunner.terminateGraceSeconds + 2)
        if case .success(let output) = result {
            #expect(output.status == 128 + SIGKILL)
        } else {
            Issue.record("expected the killed leader's status, got \(result)")
        }
        #expect(await Self.gone("sleep \(nap)", within: 2))
    }

    @Test("terminate before the launch means no launch, and no crash")
    func terminateBeforeLaunch() async {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        let runner = ProcessGroupRunner()
        runner.terminate()
        let result = await runner.run(executable: "/bin/sleep", arguments: [nap], environment: nil, currentDirectory: nil)
        guard case .failure(let error) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(error is CancellationError)
        #expect(runner.processIdentifier == 0)
        #expect(await Self.gone("sleep \(nap)", within: 2))
    }

    @Test("a normal command's output is unchanged")
    func outputUnchanged() async {
        let out = await ToolExecutor().runCommand("echo out; echo err >&2; exit 3", cwd: nil, timeoutSeconds: 10)
        #expect(out == "out\n\nStderr: err\n")
        #expect(await ToolExecutor().runCommand("true", cwd: nil, timeoutSeconds: 10) == "Success")
        // `/private/tmp`, as `Process` reported it too: zsh resolves the symlink.
        #expect(await ToolExecutor().runCommand("pwd", cwd: "/tmp", timeoutSeconds: 10) == "/private/tmp\n")
        // #275: `cwd` must go through `IrisEngine.expandTilde`, not `expandingTildeInPath` — under
        // `swift test` `~/.iris` routes to this process's own temp home (`IrisPaths.default`), never
        // the real one. `expandingTildeInPath` would instead expand to the developer's actual
        // `~/.iris`, which this test must never touch (invariant 7) and which would answer with a
        // different directory than the one asserted below.
        // `realpath(3)`, not `resolvingSymlinksInPath()`: Foundation's deliberately leaves `/var`
        // (and `/tmp`, `/etc`) unresolved for compatibility, which is not what `pwd` — asking the
        // kernel via `chdir` — actually reports (the `/tmp` case above is the same thing).
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let expectedHome = String(cString: realpath(IrisPaths.default.root.path, &buffer))
        #expect(await ToolExecutor().runCommand("pwd", cwd: "~/.iris", timeoutSeconds: 10) == expectedHome + "\n")
        // Nothing types at a command: stdin is at end of file, not the app's.
        #expect(await ToolExecutor().runCommand("cat; echo eof", cwd: nil, timeoutSeconds: 10) == "eof\n")
        #expect(await ToolExecutor().runCommand("echo hi", cwd: "/nonexistent-iris-353", timeoutSeconds: 10)
                    .hasPrefix("Error executing command:"))
    }

    @Test("output larger than the pipe buffer arrives whole")
    func largeOutput() async {
        let out = await ToolExecutor().runCommand("head -c 300000 /dev/zero | tr '\\0' a", cwd: nil, timeoutSeconds: 10)
        #expect(out.count == 300_000)
    }

    @Test("a command that exits on its own leaves nothing holding its pipes")
    func normalExitKillsPipeHolder() async {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        let started = Date()
        // The background sleep inherits stdout; before #353 its read blocked until the deadline.
        let out = await ToolExecutor().runCommand("(sleep \(nap) &); echo done", cwd: nil, timeoutSeconds: 20)
        let wall = Date().timeIntervalSince(started)
        #expect(out == "done\n")
        #expect(wall < ProcessGroupRunner.strayGraceSeconds + 2, "returned after \(wall)s")
        #expect(await Self.gone("sleep \(nap)", within: 3), "sleep \(nap) was left running")
    }

    @Test("a background job detached from the pipes is the command's to keep")
    func detachedBackgroundSurvives() async {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        // Through `ProcessGroupRunner` directly, not `ToolExecutor.runCommand`: that wraps the
        // runner in `withTimeout`, which races it against a timer inside an *unstructured*
        // `Task {}` (deliberately, so a cancel is never held up waiting for work it no longer
        // needs — see `Timeout.swift`). Under heavy load that `Task` can sit unscheduled on the
        // cooperative pool for seconds before it ever reaches the runner, and a clock started
        // before it — as this test's used to be — charges that pool-start latency against the
        // product (#429; the mechanism #427 found in the starvation scenarios). None of that
        // latency is between this call and the runner's own work, so starting the clock here
        // measures the real property: the runner returns once the leader exits, without waiting
        // on a background job that no longer holds its pipes.
        let runner = ProcessGroupRunner()
        let started = Date()
        let result = await runner.run(executable: "/bin/zsh",
                                       arguments: ["-c", "(sleep \(nap) >/dev/null 2>&1 &); echo started"],
                                       environment: BinaryResolver.commandEnvironment(base: ProcessInfo.processInfo.environment),
                                       currentDirectory: nil)
        let wall = Date().timeIntervalSince(started)
        #expect(wall < ProcessGroupRunner.strayGraceSeconds, "returned after \(wall)s; looks like it paid the stray grace")
        guard case .success(let output) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(String(data: output.stdout, encoding: .utf8) == "started\n")
        // Polled: the call returns once the shell has forked the job, which may not have exec'd
        // `sleep` yet. Appearing a moment after the return still proves it outlived the call.
        #expect(await Self.appears("sleep \(nap)", within: 3), "a server started with its output redirected must outlive the call")
    }

    @Test("ToolExecutor.runCommand leaves a detached background job alive")
    func runCommandLeavesDetachedBackgroundAlive() async {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        // Same shape as `detachedBackgroundSurvives`, but through `ToolExecutor.runCommand` itself:
        // that test moved to calling `ProcessGroupRunner` directly for its timing (#429), which
        // dropped coverage at this layer for the property that matters — if `runCommand` ever
        // killed the group on return, it would take a detached background job with it, and
        // nothing at this layer would notice.
        let started = Date()
        let out = await ToolExecutor().runCommand("(sleep \(nap) >/dev/null 2>&1 &); echo started",
                                                    cwd: nil, timeoutSeconds: 10)
        // Generous, not tight: this is a liveness check, not a timing measurement (#429).
        #expect(Date().timeIntervalSince(started) < 20, "runCommand should not have hung")
        #expect(out == "started\n")
        #expect(await Self.appears("sleep \(nap)", within: 3),
                "a detached background job must survive runCommand's return")
    }

    @Test("a plain command leaves no process behind")
    func plainCommandLeavesNothing() async {
        let nap = "0.\(Int.random(in: 100_000...999_999))"
        defer { Self.killAll(nap) }
        let out = await ToolExecutor().runCommand("sleep \(nap); echo ok", cwd: nil, timeoutSeconds: 10)
        #expect(out == "ok\n")
        #expect(await Self.gone("sleep \(nap)", within: 2))
    }

    // MARK: - Helpers

    static func marker() -> String { "30.\(Int.random(in: 100_000...999_999))" }

    static func gone(_ needle: String, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !exists(needle) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !exists(needle)
    }

    static func appears(_ needle: String, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if exists(needle) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return exists(needle)
    }

    static func exists(_ needle: String) -> Bool { tool("/usr/bin/pgrep", ["-f", needle]) == 0 }

    static func killAll(_ nap: String) { _ = tool("/usr/bin/pkill", ["-9", "-f", "sleep \(nap)"]) }

    private static func tool(_ path: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
