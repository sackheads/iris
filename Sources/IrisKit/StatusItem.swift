import AppKit
import SwiftUI

/// The part of a window the tracker uses, so a test can drive the tracker with a fake.
@MainActor
protocol TrackableWindow: AnyObject {
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    /// Not covered by another window or off the active Space.
    var isUncovered: Bool { get }
    var isKeyWindow: Bool { get }
    func deminiaturize(_ sender: Any?)
    func makeKeyAndOrderFront(_ sender: Any?)
    func orderOut(_ sender: Any?)
}

extension NSWindow: TrackableWindow {
    var isUncovered: Bool { occlusionState.contains(.visible) }
}

/// Tracks the chat window by reference (plan note 3). An instance so a test builds its own over
/// fake windows and its own notification center; the app has exactly one, `MainWindow.tracking`.
@MainActor
final class MainWindowTracking {
    static let willCloseNotification = NSWindow.willCloseNotification

    private(set) weak var current: TrackableWindow?
    private let center: NotificationCenter
    private let appIsActive: @MainActor () -> Bool
    private let activate: @MainActor () -> Void
    private var closeObserver: NSObjectProtocol?

    init(center: NotificationCenter = .default,
         appIsActive: @escaping @MainActor () -> Bool,
         activate: @escaping @MainActor () -> Void) {
        self.center = center
        self.appIsActive = appIsActive
        self.activate = activate
    }

    func track(_ window: TrackableWindow?) {
        guard let window, window !== current else { return }
        current = window
        if let closeObserver { center.removeObserver(closeObserver) }
        // `queue: nil` delivers on the posting thread, and a window closes on the main thread,
        // so the forget happens before the close returns rather than on a later turn.
        closeObserver = center.addObserver(forName: Self.willCloseNotification, object: window,
                                           queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.current = nil }
        }
    }

    /// On screen and not covered: what decides whether an ask needs a banner (decision 6).
    var isVisible: Bool {
        guard let window = current else { return false }
        return window.isVisible && !window.isMiniaturized && window.isUncovered
    }

    var isFrontmost: Bool { appIsActive() && (current?.isKeyWindow ?? false) }

    /// Brings the tracked window forward, or opens the scene through `open` when it was closed.
    func raise(open: (@MainActor () -> Void)?) {
        activate()
        if let window = current {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }

    func hide() { current?.orderOut(nil) }

    /// The global hotkey: hide the chat window when it is in front, otherwise raise it the way
    /// every other surface does (D6 decision 4).
    func toggleFromHotkey(state: AppState) {
        if isFrontmost {
            hide()
        } else {
            state.showMainWindow(selecting: nil)
        }
    }
}

/// The chat window, tracked by reference (D6 decision 4). Never by title: `ChatView` sets
/// `.navigationTitle(conv.title)`, so the window is called "Iris" only while Iris or nothing is
/// selected, and the old title match fell back to "the first SwiftUI window", which can be
/// Diagnostics or the run log.
@MainActor
enum MainWindow {
    static let sceneId = "main"
    static let tracking = MainWindowTracking(appIsActive: { NSApp.isActive },
                                             activate: { NSApp.activate(ignoringOtherApps: true) })
    static var current: NSWindow? { tracking.current as? NSWindow }
    /// `ChatView`'s `openWindow`, for a surface with no SwiftUI environment of its own (a
    /// notification's Open) once the window has been closed.
    static var openAction: OpenWindowAction?

    static func track(_ window: NSWindow?) { tracking.track(window) }
    static var isVisible: Bool { tracking.isVisible }
    static var isFrontmost: Bool { tracking.isFrontmost }

    static func raise(fallback: OpenWindowAction? = nil) {
        guard let action = fallback ?? openAction else {
            tracking.raise(open: nil)
            return
        }
        tracking.raise(open: { action(id: sceneId) })
    }

    static func hide() { tracking.hide() }
}

/// Reports the window `ChatView` lives in to `MainWindow`.
struct MainWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainWindow.track(window)
        }
    }
}

/// The status item's label: the glyph `SurfaceAttention` asks for (D6 decision 4).
struct StatusItemLabel: View {
    let state: AppState

    var body: some View {
        let glyph = StatusGlyph.make(state.surfaceAttention, identity: .current)
        Group {
            if let text = glyph.text {
                Text("\(Image(systemName: glyph.symbol))\(text)")
            } else {
                Image(systemName: glyph.symbol)
            }
        }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}

/// The status item's menu: what is waiting, each row opening what it names, then the app's
/// own items.
struct StatusMenu: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = SurfaceAttention.menuRows(state.surfaceAttention, ledger: state.ledgerAttention,
                                             runningCount: state.runningJobs.count)
        ForEach(rows) { row in
            if row.target == .nowhere {
                Text(row.text)
            } else {
                Button(row.text) {
                    adoptOpenAction()
                    state.openStatusRow(row.target)
                }
            }
        }
        if !rows.isEmpty { Divider() }
        Button("Show Chat") {
            adoptOpenAction()
            state.showMainWindow(selecting: nil)
        }
        Divider()
        if let updater = UpdaterController.shared {
            CheckForUpdatesButton(updater: updater)
        }
        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    /// The menu has an environment of its own, so a closed window can reopen from here even
    /// before `ChatView` ever appeared to hand over its action.
    private func adoptOpenAction() {
        if MainWindow.openAction == nil { MainWindow.openAction = openWindow }
    }
}
