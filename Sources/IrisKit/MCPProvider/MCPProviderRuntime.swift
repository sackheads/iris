import Foundation

/// The app's one composition root for the loopback MCP provider (#1067, Task 8). Reads
/// `ConfigManager.shared.mcpProviderEnabled` once, at `start()`, not reactively: there is no
/// existing `didSet`-driven start/stop pattern anywhere in `ConfigManager`/`GuardedSettings` to
/// mirror (`enableSandboxing` only persists), so toggling the setting while Iris is running takes
/// effect on the next launch. Flagged for the task reviewer, per the plan's own Step 14 allowance.
@MainActor
final class MCPProviderRuntime {
    static let shared = MCPProviderRuntime()

    private var server: IrisMCPProviderServer?

    /// Call from `AppDelegate.applicationDidFinishLaunching`. A no-op when the feature is off.
    func start() async {
        guard ConfigManager.shared.mcpProviderEnabled else { return }
        guard server == nil else { return }

        let tokenRegistry = ProviderTokenRegistry()
        let mailbox = ProviderMailbox(registry: tokenRegistry)
        let artifactRoot = IrisPaths.default.root.appendingPathComponent("mcp-provider-artifacts", isDirectory: true)
        let artifactStore = ProviderArtifactStore(root: artifactRoot, isRegistered: { tokenRegistry.isRegistered(clientId: $0) })
        let door = SelfReportDoor.live()
        let doorGate = ProviderRequestGate(registry: tokenRegistry, capacity: Self.doorGateCapacity, refillInterval: Self.gateRefillInterval)
        let mailboxGate = ProviderRequestGate(registry: tokenRegistry, capacity: Self.mailboxGateCapacity, refillInterval: Self.gateRefillInterval)
        let port = UInt16(clamping: ConfigManager.shared.mcpProviderPort)

        let server = IrisMCPProviderServer(tokenRegistry: tokenRegistry, mailbox: mailbox, artifactStore: artifactStore,
                                           door: door, doorGate: doorGate, mailboxGate: mailboxGate, port: port)
        do {
            try await server.start()
            self.server = server
        } catch {
            // Loopback-only, best-effort: a port already in use (another Iris process, or a
            // stale listener) should not block the rest of app launch.
        }
    }

    /// Call from `AppDelegate.applicationWillTerminate`, before `_exit`.
    func stop() async {
        await server?.stop()
        server = nil
    }

    /// Mirrors `AppState.sweepArtifacts`'s own cadence (called beside it in
    /// `IrisEngine.applyRetention(ledger:)`). A no-op when the provider was never started.
    func sweepExpired() async {
        await server?.sweepExpired()
    }

    /// Requests per minute before the self-report door refuses — distinct from the mailbox's own
    /// budget (Task 3's Global Constraints: each gate's capacity is independent).
    private static let doorGateCapacity = 120
    private static let mailboxGateCapacity = 60
    private static let gateRefillInterval: Duration = .seconds(60)
}
