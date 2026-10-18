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
        notificationDelegate()
    }

    /// The one `SystemNotificationCenter`, whichever of will-finish and the sink asks first. Only
    /// after the `.app` check: `UNUserNotificationCenter.current()` raises without a bundle.
    @discardableResult
    static func notificationDelegate() -> SystemNotificationCenter {
        SystemNotificationCenter.installEarly(route: { LaunchGate.shared.receiveNotification($0) },
                                              presenting: { LaunchGate.shared.isOpen })
    }

    static func installNotifications(on state: AppState, bundleURL: URL = Bundle.main.bundleURL,
                                     config: ConfigManager = .shared) {
        // What the person is looking at, and the observers that clear an unread dot, for every
        // build (#592); the notification sink below only for an `.app`.
        wireContext(state, config: config)
        installUnreadClearing(on: state)
        guard isAppBundle(bundleURL) else { return }
        wire(state, sink: UserNotificationSink(state: state), config: config)
    }

    /// The sink and the context the policy reads, with Settings' "Notifications" row deciding
    /// `enabled` at each post. Split from the install so a test can wire a fake sink.
    static func wire(_ state: AppState, sink: any NotificationSink, config: ConfigManager,
                     appActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
                     mainWindowVisible: @escaping @MainActor () -> Bool = { MainWindow.isVisible }) {
        state.notificationSink = sink
        wireContext(state, config: config, appActive: appActive, mainWindowVisible: mainWindowVisible)
    }

    /// What the person is looking at, for every build, `.app` or not: the notification policy reads
    /// it, and so does the unread-reply dot (#592), which a bare `swift run` has too. With no
    /// context every reply would count as unseen.
    static func wireContext(_ state: AppState, config: ConfigManager = .shared,
                            appActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
                            mainWindowVisible: @escaping @MainActor () -> Bool = { MainWindow.isVisible }) {
        state.notificationContext = { [weak state] in
            NotificationContext(enabled: config.notificationMode == .needsAttention,
                                appActive: appActive(), mainWindowVisible: mainWindowVisible(),
                                selectedConversationId: state?.selectedConversationId)
        }
    }

    /// The app becoming active, or a window key, is the person looking again: the selected
    /// conversation's unread dot clears then (#592). Process-lifetime observers, installed once.
    static func installUnreadClearing(on state: AppState) {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak state] _ in
                MainActor.assumeIsolated { state?.clearUnreadIfLooking() }
            }
        }
    }
}
