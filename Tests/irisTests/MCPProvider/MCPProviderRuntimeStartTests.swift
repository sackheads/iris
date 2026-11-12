import Testing
import Foundation
import Network
@testable import IrisKit

/// #1080: the two ways `MCPProviderRuntime.start()` fails closed are no longer silent. Each test
/// builds its own runtime over an in-memory Keychain, a temp artifact root and a recording sink,
/// so nothing reads a real setting, the real Keychain or the real home.
@MainActor
@Suite("MCPProviderRuntime start status (#1080)", .serialized, .timeLimit(.minutes(1)))
struct MCPProviderRuntimeStartTests {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var all: [String] = []
        func add(_ line: String) { lock.withLock { all.append(line) } }
        var value: [String] { lock.withLock { all } }
    }

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iris-mcp-runtime-\(UUID().uuidString)", isDirectory: true)
    }

    private static func registry(readFailure: OSStatus? = nil) -> ProviderTokenRegistry {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        if let readFailure { keychain.simulateReadFailure(readFailure) }
        return ProviderTokenRegistry(keychain: keychain)
    }

    private static func runtime(enabled: Bool = true, registry: ProviderTokenRegistry, port: UInt16 = 0,
                                lines: Lines) -> MCPProviderRuntime {
        MCPProviderRuntime(isEnabled: { enabled }, makeRegistry: { registry }, configuredPort: { port },
                           artifactRoot: tempRoot(), report: { lines.add($0) })
    }

    @Test("off by default: nothing starts, nothing is reported")
    func offStaysOffAndSilent() async {
        let lines = Lines()
        let runtime = Self.runtime(enabled: false, registry: Self.registry(), lines: lines)
        await runtime.start()
        #expect(runtime.status == .off)
        #expect(lines.value.isEmpty)
    }

    @Test("a token store that cannot be read is reported, with a bounded reason and no server")
    func keychainLoadFailureIsReported() async {
        let lines = Lines()
        let runtime = Self.runtime(registry: Self.registry(readFailure: errSecIO), lines: lines)
        await runtime.start()
        guard case .failed(.keychainLoad(let reason)) = runtime.status else {
            Issue.record("expected .failed(.keychainLoad), got \(runtime.status)"); return
        }
        #expect(reason.count <= 120)
        #expect(lines.value.count == 1)
        #expect(lines.value[0].contains("token store could not be read"))
        // Starting again does not pretend it worked.
        await runtime.start()
        guard case .failed(.keychainLoad) = runtime.status else { Issue.record("status changed to \(runtime.status)"); return }
    }

    @Test("a port already in use is reported, naming the port")
    func bindFailureIsReported() async throws {
        // Hold a real loopback port, then ask the runtime for the same one.
        let holder = LoopbackHTTPListener(port: 0) { _ in .ok() }
        try await holder.start()
        defer { holder.stop() }
        let taken = try #require(holder.boundPort)

        let lines = Lines()
        let runtime = Self.runtime(registry: Self.registry(), port: taken, lines: lines)
        await runtime.start()
        guard case .failed(.bind(let port, let reason)) = runtime.status else {
            Issue.record("expected .failed(.bind), got \(runtime.status)"); return
        }
        #expect(port == taken)
        #expect(reason.count <= 120)
        #expect(lines.value.count == 1)
        #expect(lines.value[0].contains("127.0.0.1:\(taken)"))
    }

    @Test("a successful start reports running on the bound port and says nothing")
    func successIsRunningAndSilent() async throws {
        let lines = Lines()
        let runtime = Self.runtime(registry: Self.registry(), lines: lines)
        await runtime.start()
        guard case .running(let port) = runtime.status else {
            Issue.record("expected .running, got \(runtime.status)"); return
        }
        #expect(port != 0, "an ephemeral request resolves to the real bound port")
        #expect(lines.value.isEmpty)
        await runtime.stop()
    }
}
