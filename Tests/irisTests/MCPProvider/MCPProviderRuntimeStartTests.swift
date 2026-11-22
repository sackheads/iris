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
                           artifactRoot: tempRoot(), report: { lines.add($0) }, makeGuestRegistry: { nil })
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
    func keychainLoadFailureIsReported() async throws {
        let lines = Lines()
        let runtime = Self.runtime(registry: Self.registry(readFailure: errSecIO), lines: lines)
        await runtime.start()
        guard case .failed(.keychainLoad(let reason)) = runtime.status else {
            Issue.record("expected .failed(.keychainLoad), got \(runtime.status)"); return
        }
        #expect(reason.count <= 120)
        #expect(lines.value.count == 1)
        let line = try #require(lines.value.first)
        #expect(line.contains("token store could not be read"))
        // Starting again does not pretend it worked.
        await runtime.start()
        guard case .failed(.keychainLoad) = runtime.status else { Issue.record("status changed to \(runtime.status)"); return }
    }

    @Test("a running provider owns the guest registry (reaper started), and stopping drops it (#1066)")
    func runtimeOwnsTheGuestRegistry() async throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guests = GuestSessionRegistry(state: app) { s, c in IrisEngine.makeGuestEngine(state: s, clientId: c, protectionEnabled: false) }
        let runtime = MCPProviderRuntime(isEnabled: { true }, makeRegistry: { Self.registry() }, configuredPort: { 0 },
                                         artifactRoot: Self.tempRoot(), report: { _ in }, makeGuestRegistry: { guests })
        #expect(runtime.guestSessions == nil)
        await runtime.start()
        guard case .running = runtime.status else { Issue.record("not running: \(runtime.status)"); return }
        #expect(runtime.guestSessions === guests)
        await runtime.stop()
        #expect(runtime.guestSessions == nil)
    }

    @Test("a running provider hands its guest driver to the server, and with the setting off a send starts nothing (#1066)")
    func serverGetsTheDriver() async throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guests = GuestSessionRegistry(state: app) { s, c in IrisEngine.makeGuestEngine(state: s, clientId: c, protectionEnabled: false) }
        let tokens = Self.registry()
        _ = try tokens.issueToken(forClientId: "dev-1")
        let runtime = MCPProviderRuntime(isEnabled: { true }, makeRegistry: { tokens }, configuredPort: { 0 },
                                         artifactRoot: Self.tempRoot(), report: { _ in }, makeGuestRegistry: { guests })
        await runtime.start()
        defer { Task { await runtime.stop() } }
        let driver = try #require(runtime.guestDriver)
        #expect(runtime.serverGuestDriver === driver)
        #expect(!driver.isActive, "the setting is off by default")
        #expect(await driver.submit(text: "hi", from: "dev-1") == .disabled)
        #expect(guests.liveCount == 0)
    }

    @Test("a running provider's guest driver keeps the day's spend in the app's store, so a restart does not refill it (#1135)")
    func driverSpendIsPersisted() async throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let guests = GuestSessionRegistry(state: app) { s, c in IrisEngine.makeGuestEngine(state: s, clientId: c, protectionEnabled: false) }
        let runtime = MCPProviderRuntime(isEnabled: { true }, makeRegistry: { Self.registry() }, configuredPort: { 0 },
                                         artifactRoot: Self.tempRoot(), report: { _ in }, makeGuestRegistry: { guests })
        await runtime.start()
        defer { Task { await runtime.stop() } }
        let driver = try #require(runtime.guestDriver)
        await driver.spend.add(1_234, for: "dev-1")
        // A restart: a new ledger over the same store sees it.
        #expect(await GuestSpendLedger(persistence: StoreGuestSpendPersistence(store: store)).todayTotal(for: "dev-1") == 1_234)
    }

    @Test("stopping the provider closes its live guest sessions (#1066)")
    func stopClosesLiveGuestSessions() async throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guests = GuestSessionRegistry(state: app) { s, c in IrisEngine.makeGuestEngine(state: s, clientId: c, protectionEnabled: false) }
        let runtime = MCPProviderRuntime(isEnabled: { true }, makeRegistry: { Self.registry() }, configuredPort: { 0 },
                                         artifactRoot: Self.tempRoot(), report: { _ in }, makeGuestRegistry: { guests })
        await runtime.start()
        let id = try guests.session(for: "dev-1")
        #expect(app.conversations.contains { $0.id == id })
        await runtime.stop()
        #expect(guests.liveCount == 0 && !app.conversations.contains { $0.id == id } && app.guestEngines[id] == nil)
    }

    @Test("revoking through the runtime clears the guest turns bucket as well as the session (#1066)")
    func revokeClearsTheTurnsBucket() async throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let guests = GuestSessionRegistry(state: app) { s, c in IrisEngine.makeGuestEngine(state: s, clientId: c, protectionEnabled: false) }
        let tokens = Self.registry()
        _ = try tokens.issueToken(forClientId: "dev-1")
        let runtime = MCPProviderRuntime(isEnabled: { true }, makeRegistry: { tokens }, configuredPort: { 0 },
                                         artifactRoot: Self.tempRoot(), report: { _ in }, makeGuestRegistry: { guests })
        await runtime.start()
        defer { Task { await runtime.stop() } }
        let gate = try #require(runtime.guestDriver).turnGate
        for _ in 0..<GuestSessionDriver.turnsPerHour { _ = await gate.admit(clientId: "dev-1") }
        #expect(await gate.admit(clientId: "dev-1") == .budgetExceeded)
        let id = try guests.session(for: "dev-1")
        try await runtime.revoke(clientId: "dev-1")
        #expect(!app.conversations.contains { $0.id == id })
        _ = try tokens.issueToken(forClientId: "dev-1")
        #expect(await gate.admit(clientId: "dev-1") == .admitted(clientId: "dev-1"), "a re-issued id starts with a fresh bucket")
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
        let line = try #require(lines.value.first)
        #expect(line.contains("127.0.0.1:\(taken)"))
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
        #expect(runtime.status == .off, "a stopped provider is not still reported running")
    }

    @Test("two overlapping starts build one server")
    func overlappingStartsAreOne() async throws {
        let lines = Lines()
        let runtime = Self.runtime(registry: Self.registry(), lines: lines)
        async let first: Void = runtime.start()
        async let second: Void = runtime.start()
        _ = await (first, second)
        #expect(runtime.startsBegun == 1, "the second start must not build a second server beside the first")
        guard case .running = runtime.status else { Issue.record("expected .running, got \(runtime.status)"); return }
        #expect(lines.value.isEmpty)
        // Once stopped, it can start again.
        await runtime.stop()
        await runtime.start()
        #expect(runtime.startsBegun == 2)
        await runtime.stop()
    }

    @Test("a reason is capped at 120 characters however long the error's domain is")
    func reasonIsBounded() {
        let long = NSError(domain: String(repeating: "d", count: 500), code: 42)
        #expect(MCPProviderRuntime.summary(of: long).count == 120)
        #expect(MCPProviderRuntime.summary(of: NSError(domain: "short", code: 7)) == "short 7")
    }
}
