import Testing
import Foundation
@testable import iris

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
    func cancelKillsGroup() async {
        let nap = Self.marker()
        defer { Self.killAll(nap) }
        let task = Task { await ToolExecutor().runCommand("sleep \(nap); true", cwd: nil, timeoutSeconds: 60) }
        #expect(await Self.appears("sleep \(nap)", within: 5), "the command never started")
        let cancelled = Date()
        task.cancel()
        _ = await task.value
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
    func sigtermIgnoredThenKilled() async {
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
        let result = await running.value
        let wall = Date().timeIntervalSince(started)
        #expect(wall >= ProcessGroupRunner.terminateGraceSeconds - 0.2, "SIGTERM should not have ended it")
        #expect(wall < ProcessGroupRunner.terminateGraceSeconds + 2)
        if case .success(let output) = result {
            #expect(output.status == 128 + SIGKILL)
        } else {
            Issue.record("expected the killed leader's status, got \(result)")
        }
        #expect(!Self.exists("sleep \(nap)"))
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
        #expect(!Self.exists("sleep \(nap)"))
    }

    @Test("a normal command's output is unchanged")
    func outputUnchanged() async {
        let out = await ToolExecutor().runCommand("echo out; echo err >&2; exit 3", cwd: nil, timeoutSeconds: 10)
        #expect(out == "out\n\nStderr: err\n")
        #expect(await ToolExecutor().runCommand("true", cwd: nil, timeoutSeconds: 10) == "Success")
        // `/private/tmp`, as `Process` reported it too: zsh resolves the symlink.
        #expect(await ToolExecutor().runCommand("pwd", cwd: "/tmp", timeoutSeconds: 10) == "/private/tmp\n")
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
        let started = Date()
        let out = await ToolExecutor().runCommand("(sleep \(nap) >/dev/null 2>&1 &); echo started", cwd: nil, timeoutSeconds: 20)
        #expect(out == "started\n")
        #expect(Date().timeIntervalSince(started) < ProcessGroupRunner.strayGraceSeconds)
        #expect(Self.exists("sleep \(nap)"), "a server started with its output redirected must outlive the call")
    }

    @Test("a plain command leaves no process behind")
    func plainCommandLeavesNothing() async {
        let nap = "0.\(Int.random(in: 100_000...999_999))"
        defer { Self.killAll(nap) }
        let out = await ToolExecutor().runCommand("sleep \(nap); echo ok", cwd: nil, timeoutSeconds: 10)
        #expect(out == "ok\n")
        #expect(!Self.exists("sleep \(nap)"))
    }

    // MARK: - Helpers

    private static func marker() -> String { "30.\(Int.random(in: 100_000...999_999))" }

    private static func gone(_ needle: String, within seconds: Double) async -> Bool {
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
