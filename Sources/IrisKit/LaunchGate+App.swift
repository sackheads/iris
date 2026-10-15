import AppKit
import SwiftUI

/// The poll's timer, held between `startPolling` and `stopPolling`. A main-queue dispatch timer,
/// never `Task.sleep` (invariant 4).
@MainActor
final class GatePollTimer {
    private var timer: DispatchSourceTimer?

    func start(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { MainActor.assumeIsolated { tick() } }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Decision 13's "Iris is waiting" notice for a link's windowless cold start: a non-activating
/// panel, ordered front without taking focus from whatever the owner is doing.
@MainActor
final class WaitingNoticePanel {
    private var panel: NSPanel?

    /// While Iris waits every window shows `WaitingView`, so a visible one already says what the
    /// panel would: it is ordered front instead, and no second waiting surface opens beside it
    /// (#504). The panel is for when there is no such window, as on a link's cold start.
    func show(gate: LaunchGate, besides windows: [NSWindow]) {
        if let window = windows.first(where: { $0 !== panel && Self.showsWaitingView($0) }) {
            window.orderFrontRegardless()
            return
        }
        show(gate: gate)
    }

    /// A visible window SwiftUI made for a scene. Not the panel, the status item or an alert.
    static func showsWaitingView(_ window: NSWindow) -> Bool {
        window.isVisible && window.canBecomeMain && !(window is NSPanel) && window.alphaValue > 0
    }

    func show(gate: LaunchGate) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Iris is waiting"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: WaitingView(gate: gate))
            panel.center()
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

extension LaunchGate {
    /// The app's one gate. Built on first use, from `IrisApp.init`. Tests build their own.
    static let shared = LaunchGate(seams: .app())
}

extension LaunchGate.Seams {
    @MainActor
    static func app() -> LaunchGate.Seams {
        let poll = GatePollTimer()
        let notice = WaitingNoticePanel()
        let lock = IrisPaths.default.storeLockFile
        return LaunchGate.Seams(
            claim: { StoreLock.claim(at: lock, kind: .app) },
            openStore: { IrisApp.openStore() },
            finishLaunch: { links, dropped in
                // D2: a link's cold start opens no window, so `ChatView.onAppear` may never start
                // the engine; start it here. The window's own call is then a no-op.
                if AppState.isSetUp() {
                    AppState.shared.startOnce()
                } else {
                    AppState.shared.refuseRunJobURLsUntilSetUp()
                }
                for link in links { AppState.shared.receiveRunJobURL(link) }
                AppState.shared.noteLinksDroppedWhileWaiting(dropped)
            },
            deliver: { AppState.shared.receiveRunJobURL($0) },
            refuse: { refusal, hadLinks in
                let alert = NSAlert()
                alert.messageText = refusal.title
                alert.informativeText = refusal.message(hadLinks: hadLinks, lockPath: lock.path)
                alert.addButton(withTitle: "Quit")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                if let pid = refusal.holderPid {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                NSApp.terminate(nil)
            },
            startPolling: { interval, tick in poll.start(every: interval, tick) },
            stopPolling: { poll.stop() },
            showWaitingNotice: { notice.show(gate: LaunchGate.shared, besides: NSApp.windows) },
            hideWaitingNotice: { notice.hide() },
            activate: { NSApp.activate(ignoringOtherApps: true) },
            // Through the sink's handler on the one delegate, so there is a single path in.
            deliverNotification: { SystemNotificationCenter.shared?.onResponse?($0) })
    }
}
