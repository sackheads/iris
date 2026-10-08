import AppKit
import Observation
import Sparkle

/// Owns Sparkle's standard updater. Constructed only for the installed release app: a dev build
/// has no feed, no stable version and no business replacing itself.
///
/// The "automatically check" preference is Sparkle's own, persisted by Sparkle in UserDefaults,
/// and deliberately not mirrored in `ConfigManager`.
@MainActor
@Observable
final class UpdaterController: NSObject {
    static let shared: UpdaterController? = BuildIdentity.current == .release ? UpdaterController() : nil

    /// Mirrors `SPUUpdater.canCheckForUpdates` so menu items and buttons disable during a check.
    private(set) var canCheckForUpdates = false

    /// `SPUUpdater.delegate` is read-only in Sparkle 2, so the delegate is handed to the
    /// controller's initializer, which needs `self`: hence an implicitly unwrapped optional,
    /// assigned after `super.init()`. Do not "clean it up" into a `let`.
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private override init() {
        super.init()
        // Not started here: Sparkle wants to start after the app has finished launching.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // The KVO handler is a Sendable closure and SPUUpdater is main-actor isolated, so read the
        // value from the change record (`.initial` delivers it too) rather than from the updater.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.canCheckForUpdates = value } }
        }
    }

    /// Starts scheduled checking. Call once from `applicationDidFinishLaunching`.
    func start() { controller.startUpdater() }

    /// User-initiated. Activate first or Sparkle's window can open behind the frontmost app.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }

    /// Stored by Sparkle, not here, so observation is registered by hand: without it a Toggle
    /// bound to this would not redraw when it changes.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }
}

extension UpdaterController: SPUUpdaterDelegate {}
