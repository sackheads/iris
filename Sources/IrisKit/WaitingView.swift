import SwiftUI
import AppKit

/// What every scene shows until the gate is open (#463 decision 10). Reads the gate only.
struct WaitingView: View {
    let gate: LaunchGate

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(verbatim: gate.sentence)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let held = LaunchGate.heldLine(links: gate.heldLinkCount, clicks: gate.heldNotificationCount,
                                              dropped: gate.droppedCount) {
                Text(verbatim: held)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Quit Iris") { NSApp.terminate(nil) }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 160)
        .background(WaitingWindowMarker())
    }
}

/// The windows showing `WaitingView` right now, which is what the waiting notice's raise needs
/// to know (#520). Recorded by the view itself rather than guessed from a window's traits: any
/// main-capable window used to count, so a state-restored Diagnostics window took the raise and
/// the notice never showed.
@MainActor
enum WaitingWindows {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    /// Told each time a window starts showing `WaitingView`. A cold start's notice can run before
    /// SwiftUI has put `WaitingView` in its window, so the panel goes up first and the window
    /// appears beside it; the app wires this to put the panel away (#520).
    static var onJoin: (@MainActor (NSWindow) -> Void)?
    static func contains(_ window: NSWindow) -> Bool { windows.contains(window) }
    fileprivate static func add(_ window: NSWindow) {
        windows.add(window)
        onJoin?(window)
    }
    /// Once the gate opens, `WaitingView` leaves the window and it stops counting.
    fileprivate static func remove(_ window: NSWindow) { windows.remove(window) }
}

/// Puts its window in `WaitingWindows` while it is in one. Internal for tests.
final class WaitingWindowMarkerView: NSView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window { WaitingWindows.remove(window) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { WaitingWindows.add(window) }
    }
}

private struct WaitingWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> WaitingWindowMarkerView { WaitingWindowMarkerView() }
    func updateNSView(_ view: WaitingWindowMarkerView, context: Context) {}
}

/// A scene's content, or the waiting view until the store is open. `content` is built only in
/// the open branch, so `ChatView()`'s `AppState.shared` default is never evaluated while waiting.
struct GatedContent<Content: View>: View {
    let gate: LaunchGate
    @ViewBuilder let content: () -> Content

    var body: some View {
        if gate.isOpen {
            content()
        } else if case .refused = gate.state {
            RefusedWindowHider()   // the alert says it all; no window flashes behind it
        } else {
            WaitingView(gate: gate)
        }
    }
}

/// A refused launch's window: made invisible and click-through before it is first drawn. The app
/// quits once the alert is dismissed, so it never needs to come back.
private struct RefusedWindowHider: NSViewRepresentable {
    final class HidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }

    func makeNSView(context: Context) -> NSView { HidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The status item's menu while waiting: the sentence and Quit.
struct WaitingMenu: View {
    let gate: LaunchGate

    var body: some View {
        Text(verbatim: gate.sentence)
        Divider()
        Button("Quit Iris") { NSApp.terminate(nil) }
    }
}

/// The status item's menu: `StatusMenu` once open, `WaitingMenu` until then. A view of its own so
/// the branch is re-evaluated when the gate changes, which a `Scene` body's closure may not be.
struct GatedStatusMenu: View {
    let gate: LaunchGate

    var body: some View {
        if gate.isOpen { StatusMenu(state: AppState.shared) } else { WaitingMenu(gate: gate) }
    }
}

/// The status item's label: the hourglass while waiting, `StatusItemLabel` once open. It adopts
/// the label's `openWindow` in both branches, so the waiting notice can open before any window.
struct GatedStatusLabel: View {
    let gate: LaunchGate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if gate.isOpen {
            StatusItemLabel(state: AppState.shared)
        } else {
            let _ = MainWindow.adoptOpenAction(openWindow, from: .label)
            Image(systemName: "hourglass")
                .accessibilityLabel("Iris is waiting")
        }
    }
}
