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
