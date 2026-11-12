import Foundation
import os

/// The app's one composition root for the loopback MCP provider (#1067, Task 8). Reads
/// `ConfigManager.shared.mcpProviderEnabled` once, at `start()`, not reactively: there is no
/// existing `didSet`-driven start/stop pattern anywhere in `ConfigManager`/`GuardedSettings` to
/// mirror (`enableSandboxing` only persists), so toggling the setting while Iris is running takes
/// effect on the next launch. Flagged for the task reviewer, per the plan's own Step 14 allowance.
@MainActor
final class MCPProviderRuntime {
    static let shared = MCPProviderRuntime()

    /// Where the provider stands, so a person who turned the feature on can tell "not listening,
    /// and why" from "working" (#1080). Both start failures are deliberate fail-closed choices (a
    /// provider that cannot authenticate anyone, or cannot bind, must not half-start); this only
    /// makes them visible. Not a `DiagnosticEventRing` event: the ring is read through the very
    /// provider that failed to start.
    enum Status: Equatable, Sendable {
        /// The feature is off (the default), or `start()` has not run.
        case off
        case running(port: UInt16)
        case failed(Failure)
    }

    enum Failure: Equatable, Sendable {
        /// The token store could not be read, so no token can be trusted.
        case keychainLoad(String)
        /// The loopback listener could not bind (a port already in use, say).
        case bind(port: UInt16, reason: String)
    }

    private(set) var status: Status = .off
    private var server: IrisMCPProviderServer?

    private let isEnabled: @MainActor () -> Bool
    private let makeRegistry: @MainActor () -> ProviderTokenRegistry
    private let configuredPort: @MainActor () -> UInt16
    private let artifactRoot: URL
    private let report: @MainActor (String) -> Void

    /// Production defaults read the real settings, Keychain and home; a test injects its own.
    init(isEnabled: @escaping @MainActor () -> Bool = { ConfigManager.shared.mcpProviderEnabled },
         makeRegistry: @escaping @MainActor () -> ProviderTokenRegistry = { ProviderTokenRegistry() },
         configuredPort: @escaping @MainActor () -> UInt16 = { UInt16(clamping: ConfigManager.shared.mcpProviderPort) },
         artifactRoot: URL = IrisPaths.default.root.appendingPathComponent("mcp-provider-artifacts", isDirectory: true),
         report: @escaping @MainActor (String) -> Void = MCPProviderRuntime.logToConsole) {
        self.isEnabled = isEnabled
        self.makeRegistry = makeRegistry
        self.configuredPort = configuredPort
        self.artifactRoot = artifactRoot
        self.report = report
    }

    /// One line per failure, readable in Console.app or `log stream --predicate 'subsystem ==
    /// "com.bnaylor.iris"'`, in every build. The subsystem matches the rest of the codebase.
    nonisolated private static let logger = Logger(subsystem: "com.bnaylor.iris", category: "mcp-provider")
    nonisolated static func logToConsole(_ line: String) { logger.error("\(line, privacy: .public)") }

    /// Call from `AppDelegate.applicationDidFinishLaunching`. A no-op when the feature is off.
    func start() async {
        guard isEnabled() else { return }
        guard server == nil else { return }

        let tokenRegistry = makeRegistry()
        // A registry that failed to load its durable token store can authenticate nobody
        // correctly (every `clientId(forToken:)` lookup runs against whatever partial/empty
        // state construction left behind) — fail closed rather than silently start broken.
        if let loadError = tokenRegistry.keychainLoadError {
            fail(.keychainLoad(Self.summary(of: loadError)),
                 "MCP provider not started: the token store could not be read (\(Self.summary(of: loadError))), so no client can authenticate")
            return
        }

        let mailbox = ProviderMailbox(registry: tokenRegistry)
        let artifactStore = ProviderArtifactStore(root: artifactRoot, isRegistered: { tokenRegistry.isRegistered(clientId: $0) })
        let door = SelfReportDoor.live()
        let doorGate = ProviderRequestGate(registry: tokenRegistry, capacity: Self.doorGateCapacity, refillInterval: Self.refillInterval(forCapacity: Self.doorGateCapacity))
        let mailboxGate = ProviderRequestGate(registry: tokenRegistry, capacity: Self.mailboxGateCapacity, refillInterval: Self.refillInterval(forCapacity: Self.mailboxGateCapacity))
        let port = configuredPort()

        let server = IrisMCPProviderServer(tokenRegistry: tokenRegistry, mailbox: mailbox, artifactStore: artifactStore,
                                           door: door, doorGate: doorGate, mailboxGate: mailboxGate, port: port)
        do {
            try await server.start()
            self.server = server
            status = .running(port: server.boundPort ?? port)
        } catch {
            // Loopback-only, best-effort: a port already in use (another Iris process, or a
            // stale listener) must not block the rest of app launch, but it is no longer silent.
            fail(.bind(port: port, reason: Self.summary(of: error)),
                 "MCP provider not started: could not listen on 127.0.0.1:\(port) (\(Self.summary(of: error)))")
        }
    }

    private func fail(_ failure: Failure, _ line: String) {
        status = .failed(failure)
        report(line)
    }

    /// A bounded, secret-free description of an error: its domain and code, never a payload.
    private static func summary(of error: Error) -> String {
        let ns = error as NSError
        return String("\(ns.domain) \(ns.code)".prefix(120))
    }

    /// Call from `AppDelegate.applicationWillTerminate`, before `_exit`.
    func stop() async {
        await server?.stop()
        server = nil
        if case .running = status { status = .off }
    }

    /// Mirrors `AppState.sweepArtifacts`'s own cadence (called beside it in
    /// `IrisEngine.applyRetention(ledger:)`). A no-op when the provider was never started.
    func sweepExpired() async {
        await server?.sweepExpired()
    }

    /// Sustained requests per minute before each gate refuses — distinct budgets (Task 3's
    /// Global Constraints: each gate's capacity is independent). `ProviderRequestGate`'s
    /// `refillInterval` is the time to refill *one* token, not the window `capacity` is spent
    /// over, so a 120/minute sustained rate needs one token every 1/120 of a minute, not
    /// `capacity: 120, refillInterval: .seconds(60)` (which refills to only 1/minute once the
    /// initial burst of 120 is spent).
    static let doorGateCapacity = 120
    static let mailboxGateCapacity = 60
    nonisolated static func refillInterval(forCapacity capacity: Int) -> Duration {
        .seconds(60) / capacity
    }
}
