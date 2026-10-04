import Testing
import Foundation
@testable import iris

/// #353, inside the VM: killing the `container exec` client on the host leaves the command running
/// in the container, so `exec` records the command's process group there and, on a timeout or a
/// cancel, kills it with a second `exec`. Nothing here goes near the `container` binary
/// (invariant 7): the argv is recorded, and the two scripts are run by the host's own bash.
@Suite("container exec kills its group in the VM", .timeLimit(.minutes(1)))
struct ContainerExecGroupKillTests {

    /// Records every call; the first answers with `first`, the rest succeed.
    final class Launcher: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        private let first: Error?
        init(first: Error?) { self.first = first }
        var launch: CLIContainerRuntime.Launch {
            { [self] args, _ in
                let fail: Error? = lock.withLock { calls.append(args); return calls.count == 1 ? first : nil }
                if let fail { throw fail }
                return ("", "", 0)
            }
        }
        var argv: [[String]] { lock.withLock { calls } }
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
        _ = try await CLIContainerRuntime(launch: launcher.launch).exec(name: "iris-a", workdir: "/ws", command: "echo hi", timeoutSeconds: 5)
        let argv = try #require(launcher.argv.first)
        let pidFile = try #require(Self.pidFile(in: argv))
        #expect(argv == ["exec", "-w", "/ws", "iris-a", "bash", "-c", CLIContainerRuntime.recordingWrapper(pidFile), "iris-exec", "echo hi"])
        // An ordinary exit kills nothing.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(launcher.argv.count == 1)
    }

    @Test("a timeout or a cancel sends the group killer for the same note", arguments: [true, false])
    func killerFollowsTimeout(timedOut: Bool) async throws {
        let error: Error = timedOut ? ContainerRuntimeError.timedOut(elapsedSeconds: 1) : CancellationError()
        let launcher = Launcher(first: error)
        await #expect(throws: Error.self) {
            _ = try await CLIContainerRuntime(launch: launcher.launch).exec(name: "iris-a", workdir: "/ws", command: "sleep 99", timeoutSeconds: 1)
        }
        let deadline = Date().addingTimeInterval(5)
        while launcher.argv.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let calls = launcher.argv
        try #require(calls.count == 2, "no kill followed the \(timedOut ? "timeout" : "cancel")")
        let pidFile = try #require(Self.pidFile(in: calls[0]))
        #expect(calls[1] == ["exec", "iris-a", "bash", "-c", CLIContainerRuntime.groupKiller(pidFile)])
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
