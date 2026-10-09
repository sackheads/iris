import Testing
import Foundation
@testable import IrisKit

/// None of these touches `ConfigManager.shared`: it is process-global and suites run
/// concurrently, so mutating it races and its setters persist beyond the test (#109, invariant 7).
@Suite("Sandbox config", .timeLimit(.minutes(1)))
struct SandboxTests {
    @Test("sandbox config written by one ConfigManager is visible to another over the same store")
    func testSandboxConfigPersists() throws {
        let name = "iris-sandbox-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }

        let config = ConfigManager(store: store)
        #expect(config.enableSandboxing == false)
        #expect(config.sandboxImage == "ubuntu:latest")

        config.enableSandboxing = true
        config.sandboxImage = "alpine:3.18"

        // Simulates an app restart: a fresh instance reading the same backing store.
        let restarted = ConfigManager(store: store)
        #expect(restarted.enableSandboxing == true)
        #expect(restarted.sandboxImage == "alpine:3.18")
    }

    /// A stub `container` CLI in a temp directory: it prints each argument on its own line and
    /// then whatever `body` adds. The test used to boot a real VM through the installed runtime,
    /// so it passed or failed on the machine's VM, and on a machine without the runtime it could
    /// not pass at all — the message it accepted was not the one the branch returns (#374).
    private func stubContainer(_ body: String = "") throws -> (binary: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-sandbox-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("container")
        try "#!/bin/sh\nfor a in \"$@\"; do echo \"arg:$a\"; done\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(chmod(script.path, 0o755) == 0)
        return (script.path, dir)
    }

    @Test("run_command hits the sandbox branch when useSandbox is set")
    func testSandboxCommandBranch() async throws {
        // `useSandbox` is an explicit parameter and the binary is injected, so the sandbox branch
        // is exercised without ConfigManager.shared, the installed runtime or a VM.
        let stub = try stubContainer()
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let workspace = stub.dir.path
        var executor = ToolExecutor()
        executor.containerBinaryPath = { stub.binary }
        let result = await executor.execute(name: "run_command", args: ["command": .string("echo 'hello'")],
                                            cwd: workspace, useSandbox: true)

        let args = result.split(separator: "\n").filter { $0.hasPrefix("arg:") }.map { String($0.dropFirst(4)) }
        try #require(args.count == 12, "got: \(result)")
        #expect(Array(args[0...2]) == ["run", "--rm", "--name"], "got: \(result)")
        #expect(args[3].hasPrefix("iris-run-"))
        #expect(Array(args[4...7]) == ["-v", "\(workspace):\(workspace)", "--workdir", workspace])
        #expect(args[8] == ConfigManager.shared.sandboxImage)
        #expect(Array(args[9...11]) == ["bash", "-c", "echo 'hello'"])
    }

    @Test("with no container runtime the sandbox branch says so instead of running on the host")
    func testSandboxBranchWithoutRuntime() async {
        var executor = ToolExecutor()
        executor.containerBinaryPath = { nil }
        let result = await executor.execute(name: "run_command", args: ["command": .string("echo 'hello'")],
                                            cwd: "/tmp", useSandbox: true)
        #expect(result.hasPrefix("Error: sandboxing is on but the container runtime isn't installed"), "got: \(result)")
        #expect(!result.contains("hello"))
    }

    /// #377: the one-off container is deleted by the runner's kill ladder, once the client is dead,
    /// and its name is then given back to the sweep. The stub's `run` stands in for a client that
    /// never returns.
    @Test("a timed-out one-off container is deleted by the kill ladder, then released", .timeLimit(.minutes(1)))
    func ephemeralDeletedOnTimeout() async throws {
        let nap = "30.\(Int.random(in: 100_000...999_999))"
        let stub = try stubContainer("echo \"$*\" >> \"$(dirname \"$0\")/calls\"\n[ \"$1\" = run ] && exec sleep \(nap)\nexit 0")
        defer {
            try? FileManager.default.removeItem(at: stub.dir)
            RunCommandProcessGroupTests.killAll(nap)
        }
        // Exec'd once before the 1 s deadline starts: a new file's first exec can wait seconds on
        // the host's check of new executables, and the deadline then killed the stub before it had
        // logged its `run` (#387, as in `KillEscalationPoolStarvationTests`).
        #expect(BlockingSpawn.run(stub.binary, ["warm-up"], timeoutSeconds: 30) == 0)
        var executor = ToolExecutor()
        executor.containerBinaryPath = { stub.binary }
        let result = await executor.runCommand("true", cwd: stub.dir.path, useSandbox: true, timeoutSeconds: 1)
        #expect(result == ToolExecutor.commandTimedOutMessage(seconds: 1))

        let log = stub.dir.appendingPathComponent("calls")
        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        let name = try #require(calls().first { $0.hasPrefix("run ") }?.split(separator: " ").dropFirst(3).first.map(String.init))
        #expect(name.hasPrefix("iris-run-"))
        let deadline = Date().addingTimeInterval(1 + ProcessGroupRunner.terminateGraceSeconds + 5)
        while Date() < deadline {
            let registered = await EphemeralContainerRegistry.shared.current().contains(name)
            if calls().contains("delete --force \(name)"), !registered { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(calls().contains("delete --force \(name)"), "got: \(calls())")
        #expect(!(await EphemeralContainerRegistry.shared.current().contains(name)))
    }

    /// #377 review: a caller already cancelled never starts `withTimeout`'s work, so a name
    /// registered before it was never given back, and the sweep spared a container that did not
    /// exist for the rest of the process. Read through a registry of the test's own.
    @Test("a call cancelled before it starts leaves no name registered and spawns nothing")
    func cancelledCallLeavesNoName() async throws {
        let stub = try stubContainer("echo \"$*\" >> \"$(dirname \"$0\")/calls\"")
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        let registry = EphemeralContainerRegistry()
        var executor = ToolExecutor()
        executor.containerBinaryPath = { stub.binary }
        executor.ephemeralRegistry = registry
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await executor.runCommand("true", cwd: stub.dir.path, useSandbox: true, timeoutSeconds: 5)
        }
        _ = try await value(of: call)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await registry.current().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stub.dir.appendingPathComponent("calls").path))
    }

    @Test("a runtime that is installed but not started gets the setup hint, not its raw error")
    func testSandboxBranchRuntimeNotReady() async throws {
        let stub = try stubContainer("echo 'Error: unauthorized request' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: stub.dir) }
        var executor = ToolExecutor()
        executor.containerBinaryPath = { stub.binary }
        let result = await executor.execute(name: "run_command", args: ["command": .string("true")],
                                            cwd: stub.dir.path, useSandbox: true)
        #expect(result.contains("container system start"), "got: \(result)")
    }
}
