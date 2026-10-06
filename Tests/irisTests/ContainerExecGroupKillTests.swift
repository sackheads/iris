import Testing
import Foundation
@testable import iris

/// #353, inside the VM: killing the `container exec` client on the host leaves the command running
/// in the container, so `exec` records the command's process group there and, on a timeout or a
/// cancel, kills it with a second `exec`. Since #377 that second `exec` is fired by the client's
/// kill ladder (`Launch`'s `onKill`), not by `exec` after the launch throws. Nothing here goes
/// near the `container` binary (invariant 7): the argv is recorded, and the two scripts are run
/// by the host's own bash.
@Suite("container exec kills its group in the VM", .timeLimit(.minutes(1)))
struct ContainerExecGroupKillTests {

    /// Records every launch and every fire. The first launch answers with `first`, after running
    /// its `onKill` when `ladderKills` — what `CLIProcessRunner` does when its ladder had to kill
    /// the client; the rest succeed.
    final class Launcher: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        private var fired: [(args: [String], timeout: Int)] = []
        private let first: Error?
        private let ladderKills: Bool
        init(first: Error?, ladderKills: Bool = true) { self.first = first; self.ladderKills = ladderKills }
        var launch: CLIContainerRuntime.Launch {
            { [self] args, _, onKill in
                let fail: Error? = lock.withLock { calls.append(args); return calls.count == 1 ? first : nil }
                if let fail {
                    if ladderKills { onKill?() }
                    throw fail
                }
                return ("", "", 0)
            }
        }
        var fire: CLIContainerRuntime.Fire {
            { [self] args, timeout in lock.withLock { fired.append((args, timeout)) } }
        }
        var argv: [[String]] { lock.withLock { calls } }
        var fires: [(args: [String], timeout: Int)] { lock.withLock { fired } }
        func runtime() -> CLIContainerRuntime { CLIContainerRuntime(launch: launch, fire: fire) }
    }

    private static func pidFile(in argv: [String]) -> String? {
        guard let script = argv.firstIndex(of: "-c").map({ argv[$0 + 1] }),
              let range = script.range(of: #"/tmp/\.iris-exec-[0-9A-F-]+\.pid"#, options: .regularExpression)
        else { return nil }
        return String(script[range])
    }

    @Test("the command runs under the recording wrapper, as its first argument")
    func execArgv() async throws {
        let launcher = Launcher(first: nil)
        _ = try await launcher.runtime().exec(name: "iris-a", workdir: "/ws", command: "echo hi", timeoutSeconds: 5)
        let argv = try #require(launcher.argv.first)
        let pidFile = try #require(Self.pidFile(in: argv))
        #expect(argv == ["exec", "-w", "/ws", "iris-a", "bash", "-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "echo hi"])
        // An ordinary exit kills nothing.
        #expect(launcher.argv.count == 1)
        #expect(launcher.fires.isEmpty)
    }

    @Test("a ladder kill on a timeout or a cancel fires the group killer for the same note", arguments: [true, false])
    func killerFollowsLadder(timedOut: Bool) async throws {
        let error: Error = timedOut ? ContainerRuntimeError.timedOut(elapsedSeconds: 1) : CancellationError()
        let launcher = Launcher(first: error)
        await #expect(throws: Error.self) {
            _ = try await launcher.runtime().exec(name: "iris-a", workdir: "/ws", command: "sleep 99", timeoutSeconds: 1)
        }
        // Fired by the ladder before the launch threw: nothing for a pool thread to start later.
        let fires = launcher.fires
        try #require(fires.count == 1, "no kill followed the \(timedOut ? "timeout" : "cancel")")
        let pidFile = try #require(Self.pidFile(in: launcher.argv[0]))
        #expect(fires[0].args == ["exec", "iris-a", "bash", "-c", CLIContainerRuntime.groupKiller(pidFile)])
        #expect(fires[0].timeout == CLIContainerRuntime.housekeepingTimeoutSeconds)
        // Fired, not launched: the killer is not awaited through the pool-bound path.
        #expect(launcher.argv.count == 1)
    }

    @Test("an error the ladder did not kill for fires no killer")
    func noKillerWithoutLadder() async throws {
        let launcher = Launcher(first: ContainerRuntimeError.timedOut(elapsedSeconds: 1), ladderKills: false)
        await #expect(throws: Error.self) {
            _ = try await launcher.runtime().exec(name: "iris-a", workdir: "/ws", command: "sleep 99", timeoutSeconds: 1)
        }
        #expect(launcher.fires.isEmpty)
        #expect(launcher.argv.count == 1)
    }

    @Test("housekeeping calls pass no kill hook")
    func housekeepingHasNoHook() async throws {
        final class Hooks: @unchecked Sendable {
            let lock = NSLock(); var seen: [Bool] = []
        }
        let hooks = Hooks()
        let rt = CLIContainerRuntime(launch: { _, _, onKill in
            hooks.lock.withLock { hooks.seen.append(onKill != nil) }
            return ("[]", "", 0)
        }, fire: { _, _ in })
        try await rt.createDetached(name: "iris-a", image: "img", mounts: [], workdir: "/")
        _ = await rt.list(prefix: "iris-")
        await rt.remove(name: "iris-a")
        _ = try await rt.exec(name: "iris-a", workdir: "/", command: "true", timeoutSeconds: 1)
        #expect(hooks.lock.withLock { hooks.seen } == [false, false, false, false, true])
    }

    /// The ladder fires the killer twice (#377). `late`: the cancel lands before the command has
    /// recorded its group, so the first kill finds no note and the second must still reach the
    /// group. Not `late`: the group is recorded first, the first kill takes the note and ends it,
    /// and the second must find no note, so it signals nothing — the id may be reused by then.
    ///
    /// A stub `container` stands in for the CLI: for the command's `exec` it starts the wrapper
    /// (a second late when `late`) detached from the client and as a group leader (`set -m`), the
    /// way the VM runs it apart from the client; for the killer's `exec` it logs whether the note
    /// is there, then runs the killer on the host.
    @Test("each of the ladder's two kills signals the group only if it holds the note", .timeLimit(.minutes(1)),
          arguments: [true, false])
    func twoKillsOneNote(late: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-377-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nap = "30.\(Int.random(in: 100_000...999_999))"
        let clientNap = "30.\(Int.random(in: 100_000...999_999))"
        defer { RunCommandProcessGroupTests.killAll(nap); RunCommandProcessGroupTests.killAll(clientNap) }
        let stub = dir.appendingPathComponent("container").path
        let log = dir.appendingPathComponent("killers").path
        try """
        #!/bin/bash
        [ "$1" = exec ] || exit 0
        shift; [ "$1" = -w ] && shift 2; shift
        if [ "$4" = iris-exec ]; then
            ( ( trap '' TERM; sleep \(late ? 1 : 0); trap - TERM; set -m; "$@" & ) & ) </dev/null >/dev/null 2>&1
            sleep \(clientNap)
        else
            pf=$(printf %s "$3" | grep -o '/tmp/[.]iris-exec-[A-Za-z0-9-]*[.]pid' | head -1)
            if [ -s "$pf" ]; then echo note >> '\(log)'; else echo none >> '\(log)'; fi
            exec "$@"
        fi
        """.write(toFile: stub, atomically: true, encoding: .utf8)
        #expect(chmod(stub, 0o755) == 0)

        final class Fires: @unchecked Sendable {
            let lock = NSLock(); var count = 0
        }
        let fires = Fires()
        let rt = CLIContainerRuntime(
            launch: { args, timeout, onKill in
                try await CLIProcessRunner(executable: stub).run(args, timeoutSeconds: timeout, onKill: onKill)
            },
            fire: { args, timeout in
                fires.lock.withLock { fires.count += 1 }
                BlockingSpawn.detached(stub, args, timeoutSeconds: Double(timeout))
            })
        let call = Task { try await rt.exec(name: "iris-a", workdir: "/", command: "sleep \(nap); true", timeoutSeconds: 60) }
        #expect(await RunCommandProcessGroupTests.appears("sleep \(clientNap)", within: 5))
        if !late { #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5)) }
        call.cancel()
        _ = try? await call.value
        // Late, the wrapper records its group about a second after the launch, after the first kill.
        if late { #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5), "the late group never started") }
        let deadline = Date().addingTimeInterval(CLIProcessRunner.killGraceSeconds * 2 + 3)
        while RunCommandProcessGroupTests.exists("^sleep \(nap)"), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!RunCommandProcessGroupTests.exists("^sleep \(nap)"), "the group outlived both kills")
        // The second fire comes a grace after the first, however soon the group died.
        let killersDeadline = Date().addingTimeInterval(CLIProcessRunner.killGraceSeconds + 3)
        func killers() -> [String] {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        while killers().count < 2, Date() < killersDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(fires.lock.withLock { fires.count } == 2)
        #expect(killers() == (late ? ["none", "note"] : ["note", "none"]))
    }

    /// The pgid-reuse half of #377, without the race of the two fires: a killer in its grace has
    /// already taken the note, so a second killer exits at once and signals nothing.
    @Test("a killer takes the note before its grace, so a second killer signals nothing")
    func killerTakesNote() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-377-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("g.pid").path
        let nap = "30.\(Int.random(in: 100_000...999_999))"
        defer { RunCommandProcessGroupTests.killAll(nap) }
        // Ignores SIGTERM, so the first killer is still in its grace when the second runs.
        let command = Task {
            await ProcessGroupRunner().run(
                executable: "/bin/bash",
                arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "trap '' TERM; sleep \(nap); true"],
                environment: nil, currentDirectory: nil)
        }
        #expect(await RunCommandProcessGroupTests.appears("^sleep \(nap)", within: 5))
        BlockingSpawn.detached("/bin/bash", ["-c", CLIContainerRuntime.groupKiller(pidFile)], timeoutSeconds: 30)
        let taken = Date().addingTimeInterval(1)
        while FileManager.default.fileExists(atPath: pidFile), Date() < taken { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!FileManager.default.fileExists(atPath: pidFile), "the note was still there during the grace")
        #expect(RunCommandProcessGroupTests.exists("^sleep \(nap)"), "the first killer's grace should not be over yet")
        let started = Date()
        #expect(BlockingSpawn.run("/bin/bash", ["-c", CLIContainerRuntime.groupKiller(pidFile)], timeoutSeconds: 10) == 0)
        #expect(Date().timeIntervalSince(started) < 1, "the second killer waited out a grace: it signalled something")
        _ = await command.value
        #expect(!RunCommandProcessGroupTests.exists("^sleep \(nap)"))
    }

    @Test("the wrapper passes output and status through, and clears its note")
    func wrapperIsTransparent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-353-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("g.pid").path
        let result = await ProcessGroupRunner().run(
            executable: "/bin/bash",
            arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "echo out; echo err >&2; exit 3"],
            environment: nil, currentDirectory: nil)
        let output = try result.get()
        #expect(String(data: output.stdout, encoding: .utf8) == "out\n")
        #expect(String(data: output.stderr, encoding: .utf8) == "err\n")
        #expect(output.status == 3)
        #expect(!FileManager.default.fileExists(atPath: pidFile))
    }

    @Test("the killer ends the whole recorded group, grandchildren included")
    func killerEndsGroup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-353-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("g.pid").path
        let bg = "30.\(Int.random(in: 100_000...999_999))", fg = "30.\(Int.random(in: 100_000...999_999))"
        defer { RunCommandProcessGroupTests.killAll(bg); RunCommandProcessGroupTests.killAll(fg) }
        // Stands in for `container exec`, which makes the wrapper a group leader in the VM.
        let command = Task {
            await ProcessGroupRunner().run(
                executable: "/bin/bash",
                arguments: ["-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "(sleep \(bg) &); sleep \(fg); true"],
                environment: nil, currentDirectory: nil)
        }
        #expect(await RunCommandProcessGroupTests.appears("^sleep \(fg)", within: 5))
        let killer = await ProcessGroupRunner().run(executable: "/bin/bash", arguments: ["-c", CLIContainerRuntime.groupKiller(pidFile)],
                                                     environment: nil, currentDirectory: nil)
        #expect((try? killer.get().status) == 0)
        _ = await command.value
        #expect(!RunCommandProcessGroupTests.exists("sleep \(bg)"))
        #expect(!RunCommandProcessGroupTests.exists("sleep \(fg)"))
        #expect(!FileManager.default.fileExists(atPath: pidFile))
    }
}
