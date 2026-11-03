import Testing
import Foundation
import AppKit
import WebKit
@testable import IrisKit

/// #896 PR 2: PR 1 found that `decidePolicyFor` never fires for a `WKWebView(frame: .zero, ...)`
/// that is never added to a real window — so every headless test in this repo that asserts "the
/// navigation delegate cancelled it" is, in that specific shape, asserting something it cannot
/// observe. This suite is the real acceptance test the spec's own fallback calls for: a REAL,
/// on-screen `NSWindow`, and a MUTATION CHECK (layered-rules-shadow-the-test) — the same
/// navigation run twice, once with a delegate that cancels and once with one that always allows,
/// so a pass that would happen either way (because some *other* layer, not the delegate, is what
/// actually blocks it) is caught rather than reported as a win.
///
/// Gated on `IRIS_VIEWER_GUI_TEST=1`, like `IRIS_REAL_VM` and `IRIS_ONNX_TEST_BUNDLE` (AGENTS.md):
/// `swift test` and CI never run it. It opens and closes real `NSWindow`s on whatever Mac runs it,
/// so run it only under the gui-test-lease (AGENTS.md: "GUI testing: take the lease first"), and
/// only ever against a target this process itself controls (a loopback listener, or a path inside
/// our own `iris-view://` scheme) — never a target that could still be unhandled when a mutation
/// arm's delegate allows it through, which is exactly how PR 1's own development popped a real
/// LaunchServices "no application set to open the URL ..." dialog on the machine running the
/// suite. `iris-view://other` substitutes for "an app scheme nothing handles" here: still a
/// navigation the policy must refuse, still caught by our own `WKURLSchemeHandler` (a 404, not a
/// LaunchServices hand-off) if a mutation arm lets it through.
@MainActor
@Suite("Viewer GUI: decidePolicyFor on a real window (#896, opt-in)", .timeLimit(.minutes(2)))
struct ViewerGUINavigationTests {
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.environment["IRIS_VIEWER_GUI_TEST"] == "1" }

    @Test("a production window, with every real layer in place, drives decidePolicyFor and blocks every hostile channel",
          .enabled(if: isEnabled))
    func productionWindowBlocksEverything() async throws {
        let listener = try ConnectionCountingServer()
        defer { listener.close() }

        let html = Self.hostileDocument(refreshTarget: "http://127.0.0.1:\(listener.port)/refresh",
                                         subresourceHost: "http://127.0.0.1:\(listener.port)")
        let document = ViewerDocument(conversationId: UUID(), messageId: UUID(), content: html)
        let window = ViewerWindowController.openForTesting(document: document, isTainted: false)
        defer { window.close() }

        let host = try await Self.findHost(in: window)
        try await Self.waitForWebView(on: host)
        try? await Task.sleep(for: .seconds(2))  // the meta refresh and every subresource fire with a 0s delay

        #expect(host.navigationDelegate.decisionCount > 0,
                "decidePolicyFor never fired — this is exactly the offscreen gap PR 1 found; a real window must not reproduce it")
        #expect(listener.acceptedCount == 0, "a hostile channel reached the loopback listener through a real, on-screen production window")
        #expect(host.webView?.isInspectable == false)
    }

    @Test("MUTATION CHECK: with no content rule list, a cancelling delegate blocks the refresh and an allowing delegate lets it through",
          .enabled(if: isEnabled))
    func delegateAloneIsWhatBlocksIt() async throws {
        let blockedListener = try ConnectionCountingServer()
        defer { blockedListener.close() }
        let escapedListener = try ConnectionCountingServer()
        defer { escapedListener.close() }

        // No rule list, no CSP: the only thing standing between the refresh and the network is
        // whatever `decidePolicyFor` returns. If this still blocked with the delegate allowing,
        // the delegate would not be what the first test's pass actually depended on.
        //
        // The ground truth here is the listener's accepted-connection count, not `webView.url`:
        // `ConnectionCountingServer` accepts and closes the connection with no HTTP response, so
        // the provisional navigation fails and `webView.url` never flips away from the trusted
        // document even when the TCP connection genuinely got through (found live: the first cut
        // of this test asserted on `webView.url` and failed even though the listener had in fact
        // accepted a connection — the escape was real, the assertion measuring it was not).
        _ = try await Self.runMetaRefresh(to: "http://127.0.0.1:\(blockedListener.port)/evil", delegateDecision: .cancel)
        #expect(blockedListener.acceptedCount == 0)

        _ = try await Self.runMetaRefresh(to: "http://127.0.0.1:\(escapedListener.port)/evil", delegateDecision: .allow)
        #expect(escapedListener.acceptedCount > 0, "an always-allowing delegate reached nothing — the mutation arm itself is broken, not the thing it's supposed to prove")
    }

    @Test("MUTATION CHECK: the content rule list alone, with the delegate always allowing, still blocks the refresh",
          .enabled(if: isEnabled))
    func ruleListAloneBlocksItEvenIfTheDelegateWouldnt() async throws {
        let listener = try ConnectionCountingServer()
        defer { listener.close() }

        _ = try await Self.runMetaRefresh(
            to: "http://127.0.0.1:\(listener.port)/evil", delegateDecision: .allow, includeRuleList: true)
        #expect(listener.acceptedCount == 0, "the rule list let an always-allowing delegate's navigation through")
    }

    @Test("MUTATION CHECK: the same-scheme escape (iris-view://other) is cancelled by the delegate, and reaches our own 404 if allowed",
          .enabled(if: isEnabled))
    func delegateBlocksASameSchemeEscape() async throws {
        let cancelled = try await Self.runMetaRefreshToOtherScheme(delegateDecision: .cancel)
        #expect(cancelled == .documentURL)

        let escaped = try await Self.runMetaRefreshToOtherScheme(delegateDecision: .allow)
        #expect(escaped == .other, "an always-allowing delegate did not escape to iris-view://other")
    }

    // MARK: - Fixtures

    private static func hostileDocument(refreshTarget: String, subresourceHost: String) -> String {
        """
        <html><head>
        <link rel="stylesheet" href="\(subresourceHost)/link.css">
        <meta http-equiv="refresh" content="0;url=\(refreshTarget)">
        <style>
        body { background: url(\(subresourceHost)/css-url); }
        @import url(\(subresourceHost)/import.css);
        </style>
        </head><body>
        <img src="\(subresourceHost)/img.png">
        <form action="\(subresourceHost)/form" method="post" id="f"></form>
        </body></html>
        """
    }

    private enum NavigationOutcome { case documentURL, other }

    /// Builds the minimal config a mutation arm needs by hand (never through
    /// `ViewerWindowController`, which always wires the full production stack): JS off via
    /// `ViewerConfiguration.build`, the rule list only when `includeRuleList` asks for it, and a
    /// delegate that always returns the same `WKNavigationActionPolicy` regardless of what it's
    /// asked about — isolating exactly one layer's contribution per the mutation check above.
    private static func runMetaRefresh(to target: String, delegateDecision: FixedDecision,
                                        includeRuleList: Bool = false) async throws -> NavigationOutcome {
        let html = "<html><head><meta http-equiv=\"refresh\" content=\"0;url=\(target)\"></head><body>trusted</body></html>"
        let handler = ViewerSchemeHandler(document: Data(html.utf8), includeCSP: false)
        let config = ViewerConfiguration.build(schemeHandler: handler)
        if includeRuleList {
            let id = "iris-view-test-gui-\(UUID().uuidString)"
            let list = try await ViewerContentRules.compile(identifier: id)
            config.userContentController.add(list)
        }

        let webView = ClosedSurfaceWebView(frame: .zero, configuration: config)
        let delegate = FixedDecisionDelegate(decision: delegateDecision)
        webView.navigationDelegate = delegate

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await delegate.waitForInitialLoad()
        try? await Task.sleep(for: .seconds(1))  // the refresh fires with a 0s delay

        return webView.url == ViewerConfiguration.documentURL ? .documentURL : .other
    }

    private static func runMetaRefreshToOtherScheme(delegateDecision: FixedDecision) async throws -> NavigationOutcome {
        try await runMetaRefresh(to: "\(ViewerConfiguration.scheme)://other", delegateDecision: delegateDecision)
    }

    /// Finds the `ViewerWebViewHost` inside the production window's SwiftUI content view, so this
    /// suite can exercise `ViewerWindowController.open` end to end rather than rebuilding it.
    private static func findHost(in window: NSWindow) async throws -> ViewerWebViewHost {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let host = window.contentView?.firstDescendant(ofType: ViewerWebViewHost.self) {
                return host
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.hostNotFound
    }

    private static func waitForWebView(on host: ViewerWebViewHost) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while host.webView == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard host.webView != nil else { throw TestFailure.webViewNeverAppeared }
    }

    private enum TestFailure: Error { case hostNotFound, webViewNeverAppeared }
}

private enum FixedDecision { case allow, cancel }

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}

/// A navigation delegate that always returns the same decision, regardless of the request —
/// the mutation check's "what if this layer weren't here" arm.
@MainActor
private final class FixedDecisionDelegate: NSObject, WKNavigationDelegate {
    private let decision: WKNavigationActionPolicy
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    /// The fixed decision applies to the SECOND navigation (the meta refresh under test), not
    /// the first: the first is always allowed, so the trusted page actually loads and gets a
    /// chance to attempt the refresh. Applying the fixed decision to every navigation — including
    /// the first — hung the cancel arm forever, since the initial load never got to `didFinish`.
    private var hasAllowedFirstNavigation = false

    init(decision: FixedDecision) {
        self.decision = decision == .allow ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard hasAllowedFirstNavigation else {
            hasAllowedFirstNavigation = true
            return .allow
        }
        return decision
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume() }

    func waitForInitialLoad() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    private func resume() {
        guard !finished else { return }
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
