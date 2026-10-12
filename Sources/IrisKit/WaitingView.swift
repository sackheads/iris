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
            Button("Quit Iris") { NSApp.terminate(nil) }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 160)
    }
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
