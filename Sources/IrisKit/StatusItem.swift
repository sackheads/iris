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

/// Tracks the chat windows by reference (plan note 3). Every chat window registers (weakly),
/// most recently key first, so closing one of several leaves the raise a window to bring back
/// rather than opening another. An instance so a test builds its own over fake windows and its
/// own notification center; the app has exactly one, `MainWindow.tracking`.
@MainActor
final class MainWindowTracking {
    static let willCloseNotification = NSWindow.willCloseNotification
    static let didBecomeKeyNotification = NSWindow.didBecomeKeyNotification

    private struct Entry {
        weak var window: TrackableWindow?
        let observers: [NSObjectProtocol]
    }

    /// Most recently key (or registered) first.
    private var entries: [Entry] = []
    private let center: NotificationCenter
    private let appIsActive: @MainActor () -> Bool
    private let activate: @MainActor () -> Void

    init(center: NotificationCenter = .default,
         appIsActive: @escaping @MainActor () -> Bool,
         activate: @escaping @MainActor () -> Void) {
        self.center = center
        self.appIsActive = appIsActive
        self.activate = activate
    }

    /// The chat window a raise brings back: the most recently key one still open.
    var current: TrackableWindow? { entries.lazy.compactMap(\.window).first }

    func track(_ window: TrackableWindow?) {
        guard let window else { return }
        if entries.contains(where: { $0.window === window }) {
            moveToFront(ObjectIdentifier(window))
            return
        }
        // `queue: nil` delivers on the posting thread, and a window closes and becomes key on
        // the main thread, so the registry is current before the notification returns.
        let id = ObjectIdentifier(window)
        let closed = center.addObserver(forName: Self.willCloseNotification, object: window,
                                        queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(id) }
        }
        let keyed = center.addObserver(forName: Self.didBecomeKeyNotification, object: window,
                                       queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveToFront(id) }
        }
        prune()
        entries.insert(Entry(window: window, observers: [closed, keyed]), at: 0)
    }

    /// By identifier, so the observers capture no window. A live entry's identifier is unique;
    /// a dead entry's window is nil and never matches.
    private func index(of id: ObjectIdentifier) -> Int? {
        entries.firstIndex { $0.window.map(ObjectIdentifier.init) == id }
    }

    private func moveToFront(_ id: ObjectIdentifier) {
        guard let idx = index(of: id), idx > 0 else { return }
        entries.insert(entries.remove(at: idx), at: 0)
    }

    private func forget(_ id: ObjectIdentifier) {
        guard let idx = index(of: id) else { return }
        entries.remove(at: idx).observers.forEach(center.removeObserver)
        prune()
    }

    /// Drops entries whose window went away without a close notification.
    private func prune() {
        entries.removeAll { entry in
            guard entry.window == nil else { return false }
            entry.observers.forEach(center.removeObserver)
            return true
        }
    }

    /// On screen and not covered: what decides whether an ask needs a banner (decision 6).
    var isVisible: Bool {
        guard let window = current else { return false }
        return window.isVisible && !window.isMiniaturized && window.isUncovered
    }

    var isFrontmost: Bool { appIsActive() && (current?.isKeyWindow ?? false) }

    /// Brings the most recently key chat window forward, or opens the scene through `open` only
    /// when no chat window is left: never a second window while one still exists.
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
///
/// One image, never a symbol plus text. `MenuBarExtra` keeps a single element of its label: a
/// `Text` with an interpolated `Image` came out as the bare count with no symbol (the GUI pass on
/// #473), so a counted glyph is drawn into one template `NSImage` here. Idle stays the plain symbol.
struct StatusItemLabel: View {
    let state: AppState

    var body: some View {
        let glyph = StatusGlyph.make(state.surfaceAttention, identity: .current)
        if let image = StatusItemImage.make(glyph) {
            Image(nsImage: image)
                .accessibilityLabel(glyph.accessibilityLabel)
        } else {
            Image(systemName: glyph.symbol)
                .accessibilityLabel(glyph.accessibilityLabel)
        }
    }
}

/// Draws a counted glyph — the symbol, then `N` or `!N` — as one template image, so the menu bar
/// tints it for light and dark like any status item.
enum StatusItemImage {
    /// The gap between the symbol and the count, in points.
    static let spacing: CGFloat = 2

    /// Nil for a glyph with no text (idle), which the label draws as the bare symbol, and for a
    /// symbol this system does not have.
    @MainActor
    static func make(_ glyph: StatusGlyph) -> NSImage? {
        guard let text = glyph.text else { return nil }
        let font = NSFont.menuBarFont(ofSize: 0)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let height = ceil(max(symbol.size.height, textSize.height))
        let size = NSSize(width: ceil(symbol.size.width + spacing + textSize.width), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            string.draw(at: NSPoint(x: symbol.size.width + spacing, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glyph.accessibilityLabel
        return image
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
                    Task { await state.openStatusRow(row.target) }
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
