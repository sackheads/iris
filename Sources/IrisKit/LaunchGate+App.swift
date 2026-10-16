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
    static let width: CGFloat = 380
    private var panel: NSPanel?
    private var gate: LaunchGate?

    func show(gate: LaunchGate) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 180),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Iris is waiting"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            // A fixed width, so the height is measured with the text wrapped: sized by the hosting
            // view, the panel was measured for one long line and clipped the icon and Quit (#493).
            let hosting = NSHostingView(rootView: Self.content(gate))
            hosting.sizingOptions = []   // `fit` sizes the panel; left on, it sized it unwrapped
            panel.contentView = hosting
            self.panel = panel
            self.gate = gate
            fit()
            panel.center()
            follow(gate)
        }
        panel?.orderFrontRegardless()
    }

    private static func content(_ gate: LaunchGate) -> some View {
        WaitingView(gate: gate).frame(width: width)
    }

    /// The content's height at the fixed width, keeping the top edge where it is. Measured on a
    /// view of its own: the panel's, with its sizing off, reports no fitting size.
    private func fit() {
        guard let panel, let gate else { return }
        let height = NSHostingView(rootView: Self.content(gate)).fittingSize.height
        guard abs(panel.contentLayoutRect.height - height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: Self.width, height: height))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    /// Refits whenever what the view shows changes: the sentence, or the held line (#493).
    private func follow(_ gate: LaunchGate) {
        withObservationTracking {
            _ = gate.sentence
            _ = gate.heldLinkCount
            _ = gate.heldNotificationCount
            _ = gate.droppedCount
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.fit()
                    self?.follow(gate)
                }
            }
        }
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
            showWaitingNotice: { notice.show(gate: LaunchGate.shared) },
            hideWaitingNotice: { notice.hide() },
            activate: { NSApp.activate(ignoringOtherApps: true) },
            // Through the sink's handler on the one delegate, so there is a single path in.
            deliverNotification: { SystemNotificationCenter.shared?.onResponse?($0) },
            noteDroppedNotifications: { AppState.shared.noteNotificationsDroppedWhileWaiting($0) })
    }
}
