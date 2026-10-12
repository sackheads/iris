import AppKit

/// Which native surfaces this process gets (D6 decision 8, owner ruling 5). Called from the app's
/// launch (`AppDelegate`, `IrisApp.openStore`) and nothing else: `--run-job` never reaches it, and
/// a test's `AppState()` never has a sink. The status item needs no install; it is plain SwiftUI, so the bare binary has it.
@MainActor
enum SurfaceInstall {
    /// A real `.app` bundle, not just a bundle id: `UNUserNotificationCenter.current()` raises in
    /// an unbundled process, so this is asked before any call into the API.
    nonisolated static func isAppBundle(_ bundleURL: URL) -> Bool { bundleURL.pathExtension == "app" }

    /// `applicationWillFinishLaunching`: the notification center's delegate, before the store is
    /// open, so a click that launches Iris while it waits is held by the gate, not lost (#463).
    static func installNotificationDelegate(bundleURL: URL = Bundle.main.bundleURL) {
        guard isAppBundle(bundleURL) else { return }
        SystemNotificationCenter.installEarly(route: { LaunchGate.shared.receiveNotification($0) },
                                              presenting: { LaunchGate.shared.isOpen })
    }

    static func installNotifications(on state: AppState, bundleURL: URL = Bundle.main.bundleURL,
                                     config: ConfigManager = .shared) {
        guard isAppBundle(bundleURL) else { return }
        wire(state, sink: UserNotificationSink(state: state), config: config)
    }

    /// The sink and the context the policy reads, with Settings' "Notifications" row deciding
    /// `enabled` at each post. Split from the install so a test can wire a fake sink.
    static func wire(_ state: AppState, sink: any NotificationSink, config: ConfigManager,
                     appActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
                     mainWindowVisible: @escaping @MainActor () -> Bool = { MainWindow.isVisible }) {
        state.notificationSink = sink
        state.notificationContext = { [weak state] in
            NotificationContext(enabled: config.notificationMode == .needsAttention,
                                appActive: appActive(), mainWindowVisible: mainWindowVisible(),
                                selectedConversationId: state?.selectedConversationId)
        }
    }
}
