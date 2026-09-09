import Foundation

/// Process-wide switch for headless (`--bench`) runs, set once by `BenchCLI` before any engine
/// work starts.
///
/// Deliberately **not** read from the process environment. This flag skips `InjectionGuard`'s
/// model-backed tiers, so an env var would let anything that can set the app's environment —
/// including a shell command the agent itself was talked into running — turn off the very
/// defense that exists to contain injected instructions. The only legitimate setter is in-process.
enum HeadlessMode {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _isEnabled = false

    static var isEnabled: Bool {
        lock.withLock { _isEnabled }
    }

    /// Called only from `BenchCLI.run` for a fake-client scenario, before `ConfigManager.shared`
    /// or `KeychainManager.shared` are first touched.
    static func enable() {
        lock.withLock { _isEnabled = true }
    }
}
