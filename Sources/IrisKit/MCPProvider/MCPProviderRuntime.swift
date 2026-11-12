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
        // A registry that failed to load its durable token store can authenticate nobody
        // correctly (every `clientId(forToken:)` lookup runs against whatever partial/empty
        // state construction left behind) — fail closed rather than silently start broken.
        guard tokenRegistry.keychainLoadError == nil else { return }

        let mailbox = ProviderMailbox(registry: tokenRegistry)
        let artifactRoot = IrisPaths.default.root.appendingPathComponent("mcp-provider-artifacts", isDirectory: true)
        let artifactStore = ProviderArtifactStore(root: artifactRoot, isRegistered: { tokenRegistry.isRegistered(clientId: $0) })
        let door = SelfReportDoor.live()
        let doorGate = ProviderRequestGate(registry: tokenRegistry, capacity: Self.doorGateCapacity, refillInterval: Self.refillInterval(forCapacity: Self.doorGateCapacity))
        let mailboxGate = ProviderRequestGate(registry: tokenRegistry, capacity: Self.mailboxGateCapacity, refillInterval: Self.refillInterval(forCapacity: Self.mailboxGateCapacity))
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
