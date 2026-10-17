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

    /// A visible window already showing `WaitingView` says what the panel would: it is ordered
    /// front instead, and the panel, if a cold start put it up first, is put away, so two waiting
    /// surfaces never stand side by side (#504, #520). The panel is for when there is no such
    /// window, as on a link's cold start.
    func show(gate: LaunchGate, besides windows: [NSWindow]) {
        Self.respond(to: Self.action(for: windows.map(Self.facts)),
                     raise: { windows[$0].orderFrontRegardless() },
                     showPanel: { self.show(gate: gate) },
                     hidePanel: { self.hide() })
    }

    /// What `show(gate:besides:)` needs to know about a window, without AppKit.
    struct WindowFacts: Equatable {
        var isVisible: Bool
        var isOpaque: Bool          // alpha above 0: a refused launch's window is visible at alpha 0
        var isPanel: Bool
        var showsWaitingView: Bool  // `WaitingWindows`: the view says so itself (#520)
    }

    enum Action: Equatable { case raise(Int), showPanel }

    static func facts(_ window: NSWindow) -> WindowFacts {
        WindowFacts(isVisible: window.isVisible, isOpaque: window.alphaValue > 0,
                    isPanel: window is NSPanel, showsWaitingView: WaitingWindows.contains(window))
    }

    /// The first visible window showing `WaitingView`, else the panel. A window that only looks
    /// like a scene's — Diagnostics, restored at launch and never gated — does not count (#520).
    static func action(for windows: [WindowFacts]) -> Action {
        if let index = windows.firstIndex(where: { $0.isVisible && $0.isOpaque && !$0.isPanel && $0.showsWaitingView }) {
            return .raise(index)
        }
        return .showPanel
    }

    static func respond(to action: Action, raise: (Int) -> Void, showPanel: () -> Void, hidePanel: () -> Void) {
        switch action {
        case .raise(let index):
            raise(index)
            hidePanel()
        case .showPanel:
            showPanel()
        }
    }

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
        // A window that starts showing `WaitingView` after the panel went up says the same thing:
        // put the panel away (#520).
        WaitingWindows.onJoin = { _ in notice.hide() }
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
            deliverNotification: { SystemNotificationCenter.shared?.onResponse?($0) },
            noteDroppedNotifications: { AppState.shared.noteNotificationsDroppedWhileWaiting($0) })
    }
}
