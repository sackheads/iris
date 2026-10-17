import Testing
import AppKit
@testable import IrisKit

/// #520: while Iris waits, the notice raises a window already showing `WaitingView` and puts the
/// panel away, and only such a window counts.
@MainActor
@Suite("Waiting notice: which surface shows (#520)")
struct WaitingNoticeDecisionTests {
    typealias Facts = WaitingNoticePanel.WindowFacts
    static let waiting = Facts(isVisible: true, isOpaque: true, isPanel: false, showsWaitingView: true)
    /// Diagnostics, restored at launch: visible, main-capable, not a panel, never gated.
    static let diagnostics = Facts(isVisible: true, isOpaque: true, isPanel: false, showsWaitingView: false)

    @Test("no window: the panel")
    func noWindow() { #expect(WaitingNoticePanel.action(for: []) == .showPanel) }

    @Test("a visible window showing WaitingView is raised")
    func raisesTheWaitingWindow() { #expect(WaitingNoticePanel.action(for: [Self.waiting]) == .raise(0)) }

    @Test("a restored Diagnostics window does not swallow the notice")
    func diagnosticsDoesNotCount() {
        #expect(WaitingNoticePanel.action(for: [Self.diagnostics]) == .showPanel)
        #expect(WaitingNoticePanel.action(for: [Self.diagnostics, Self.waiting]) == .raise(1))
    }

    @Test("the panel itself, a hidden window and a refused launch's alpha-0 window do not count")
    func exclusions() {
        var panel = Self.waiting; panel.isPanel = true
        var hidden = Self.waiting; hidden.isVisible = false
        var refused = Self.waiting; refused.isOpaque = false
        #expect(WaitingNoticePanel.action(for: [panel, hidden, refused]) == .showPanel)
    }

    @Test("raising a window puts the panel away; showing the panel raises nothing")
    func respond() {
        var calls: [String] = []
        WaitingNoticePanel.respond(to: .raise(2), raise: { calls.append("raise \($0)") },
                                   showPanel: { calls.append("show") }, hidePanel: { calls.append("hide") })
        #expect(calls == ["raise 2", "hide"])
        calls = []
        WaitingNoticePanel.respond(to: .showPanel, raise: { calls.append("raise \($0)") },
                                   showPanel: { calls.append("show") }, hidePanel: { calls.append("hide") })
        #expect(calls == ["show"])
    }

    /// The cold start: the notice runs before `WaitingView` is in its window, so the panel goes up;
    /// then the view joins the window, and the panel must go away. `onJoin` is process-global, set
    /// only by the app's wiring; this test sets and restores it, and nothing else reads it.
    @Test("a window that starts waiting after the panel went up puts the panel away; past the gate it stops counting")
    func coldStartOrderAndGateOpen() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        var calls: [String] = []
        // Before the marker: nothing in the window says it is waiting, so the panel shows.
        WaitingNoticePanel.respond(to: WaitingNoticePanel.action(for: [WaitingNoticePanel.facts(window)]),
                                   raise: { calls.append("raise \($0)") },
                                   showPanel: { calls.append("show") }, hidePanel: { calls.append("hide") })
        let previous = WaitingWindows.onJoin
        defer { WaitingWindows.onJoin = previous }
        WaitingWindows.onJoin = { joined in if joined === window { calls.append("hide") } }
        let marker = WaitingWindowMarkerView()
        window.contentView?.addSubview(marker)
        #expect(calls == ["show", "hide"], "the panel went up, then away once the window was waiting")
        #expect(WaitingWindows.contains(window))
        // The gate opens: WaitingView leaves the window.
        marker.removeFromSuperview()
        #expect(!WaitingWindows.contains(window), "a window past the gate no longer counts")
    }
}
