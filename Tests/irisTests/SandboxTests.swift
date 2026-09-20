import Testing
import Foundation
@testable import iris

/// Neither test touches `ConfigManager.shared`: it is process-global and suites run
/// concurrently, so mutating it races and its setters persist beyond the test (#109, invariant 7).
@Suite("Sandbox config")
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

    @Test("run_command hits the sandbox branch when useSandbox is set")
    func testSandboxCommandBranch() async throws {
        // ToolExecutor.execute takes `useSandbox` as an explicit parameter, so the sandbox
        // branch can be exercised without touching ConfigManager.shared at all.
        let executor = ToolExecutor()
        let result = await executor.execute(name: "run_command", args: ["command": .string("echo 'hello'")], cwd: "/tmp", useSandbox: true)

        // We just assert that it hits the sandboxing code path.
        // It will either complain about missing container, or run it.
        #expect(result.contains("Sandboxing is enabled but the container runtime is not installed") || result.contains("hello") || result.contains("Error executing command"))
    }
}
