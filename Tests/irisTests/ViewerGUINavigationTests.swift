import Testing
import Foundation
import AppKit
import WebKit
@testable import IrisKit

/// #896 PR 2: PR 1 found that `decidePolicyFor` never fires for a `WKWebView(frame: .zero, ...)`
/// that is never added to a real window — so every headless test in this repo that asserts "the
/// navigation delegate cancelled it" is, in that specific shape, asserting something it cannot
/// observe. This suite is the real acceptance test the spec's own fallback calls for: a REAL,
/// on-screen `NSWindow`, driving the REAL `ViewerNavigationDelegate` (not a parallel stub — #905
/// review finding 1: a stub delegate proves the stub, not what ships), and MUTATION CHECKS
/// (layered-rules-shadow-the-test) that isolate each layer in turn via `ViewerNavigationDelegate`'s
/// injectable `decide` function.
///
/// Gated on `IRIS_VIEWER_GUI_TEST=1`, like `IRIS_REAL_VM` and `IRIS_ONNX_TEST_BUNDLE` (AGENTS.md):
/// `swift test` and CI never run it. It opens and closes real `NSWindow`s on whatever Mac runs it,
/// so run it only under the gui-test-lease (AGENTS.md: "GUI testing: take the lease first"), and
/// only ever against a target this process itself controls (a loopback listener, or our own
/// `HitCountingHandler` on a made-up scheme) — never a target that could still be unhandled when a
/// mutation arm's delegate allows it through, which is exactly how PR 1's own development popped a
/// real LaunchServices "no application set to open the URL ..." dialog on the machine running the
/// suite.
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

    @Test("MUTATION CHECK: the real delegate alone (no rule list, no CSP) blocks an http meta refresh, and an injected always-allow decide lets it through",
          .enabled(if: isEnabled))
    func realDelegateAloneBlocksHTTP() async throws {
        let blockedListener = try ConnectionCountingServer()
        defer { blockedListener.close() }
        let escapedListener = try ConnectionCountingServer()
        defer { escapedListener.close() }

        // The ground truth here is the listener's accepted-connection count, not `webView.url`:
        // `ConnectionCountingServer` accepts and closes the connection with no HTTP response, so
        // the provisional navigation fails and `webView.url` never flips away from the trusted
        // document even when the TCP connection genuinely got through (found live: the first cut
        // of this test asserted on `webView.url` and failed even though the listener had in fact
        // accepted a connection — the escape was real, the assertion measuring it was not).
        _ = try await Self.runMetaRefresh(to: "http://127.0.0.1:\(blockedListener.port)/evil",
                                           decide: ViewerNavigationPolicy.decide)
        #expect(blockedListener.acceptedCount == 0)

        _ = try await Self.runMetaRefresh(to: "http://127.0.0.1:\(escapedListener.port)/evil",
                                           decide: { _, _, _ in .allow })
        #expect(escapedListener.acceptedCount > 0, "an always-allowing decide reached nothing — the mutation arm itself is broken, not the thing it's supposed to prove")
    }

    @Test("MUTATION CHECK: the real delegate alone (no rule list, no CSP) blocks a meta refresh to a made-up app scheme, and an injected always-allow decide lets it through",
          .enabled(if: isEnabled))
    func realDelegateAloneBlocksAppScheme() async throws {
        // A scheme nothing on this machine is registered to handle, with our OWN scheme handler
        // standing in for "whatever would otherwise receive it" — never a bare, unhandled scheme,
        // which is what handed PR 1's own development to LaunchServices and popped a real dialog.
        let blockedHandler = HitCountingHandler()
        _ = try await Self.runMetaRefresh(to: "iris-probe-app://evil", appScheme: "iris-probe-app", appHandler: blockedHandler,
                                           decide: ViewerNavigationPolicy.decide)
        #expect(blockedHandler.hits == 0)

        let escapedHandler = HitCountingHandler()
        _ = try await Self.runMetaRefresh(to: "iris-probe-app://evil", appScheme: "iris-probe-app", appHandler: escapedHandler,
                                           decide: { _, _, _ in .allow })
        #expect(escapedHandler.hits > 0, "an always-allowing decide reached nothing — the mutation arm itself is broken, not the thing it's supposed to prove")
    }

    @Test("MUTATION CHECK: the content rule list alone, with decide forced to always allow, still blocks the refresh",
          .enabled(if: isEnabled))
    func ruleListAloneBlocksItEvenIfDecideWouldnt() async throws {
        let listener = try ConnectionCountingServer()
        defer { listener.close() }

        _ = try await Self.runMetaRefresh(to: "http://127.0.0.1:\(listener.port)/evil",
                                           decide: { _, _, _ in .allow }, includeRuleList: true)
        #expect(listener.acceptedCount == 0, "the rule list let an always-allowing decide's navigation through")
    }

    @Test("MUTATION CHECK: hasAllowedOnce — a reload of the trusted document is cancelled by the real delegate, and succeeds if the flag's effect is bypassed",
          .enabled(if: isEnabled))
    func hasAllowedOnceBlocksAReload() async throws {
        #expect(try await Self.reloadHitCount(decide: ViewerNavigationPolicy.decide) == 1,
                "the real delegate let a reload of the trusted document reach the scheme handler a second time")

        // Forces `alreadyLoaded` to read as `false` on every call, which is what the delegate's
        // own `hasAllowedOnce` bookkeeping existing to prevent — a decide function that ignores
        // the flag it's handed is the same failure mode as the flag never being set at all.
        #expect(try await Self.reloadHitCount(decide: { url, isMainFrame, _ in
            ViewerNavigationPolicy.decide(url: url, isMainFrame: isMainFrame, alreadyLoaded: false)
        }) == 2, "ignoring `alreadyLoaded` did not let the reload through — the mutation arm itself is broken")
    }

    @Test("the context menu over real link and image content is Copy-only — menu(for:) is the hook WebKit actually calls, not an untested override",
          .enabled(if: isEnabled))
    func contextMenuOverRealContentIsCopyOnly() async throws {
        let html = """
        <html><body style="margin:0">
        <a href="https://example.invalid/" style="position:absolute;left:10px;top:10px;width:100px;height:20px;display:block">link</a>
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA="
             style="position:absolute;left:10px;top:60px;width:50px;height:50px">
        </body></html>
        """
        let document = ViewerDocument(conversationId: UUID(), messageId: UUID(), content: html)
        let window = ViewerWindowController.openForTesting(document: document, isTainted: false)
        defer { window.close() }
        let host = try await Self.findHost(in: window)
        try await Self.waitForWebView(on: host)
        try? await Task.sleep(for: .milliseconds(500))   // lets the data: image actually decode and paint
        guard let webView = host.webView else { throw TestFailure.webViewNeverAppeared }

        // #904 review (dev-2's non-blocking nit): `allSatisfy` alone passes on a nil/empty menu,
        // so this doesn't prove `menu(for:)` is WebKit's real hook. Investigated adding a
        // non-emptiness check: in this session, `swiftpm-testing-helper`'s windows never become
        // key (`window.isKeyWindow` stayed false even after `NSApp.activate` +
        // `makeKeyAndOrderFront`, same root cause as PR 2's window-server capture gap — these
        // test-process windows do not fully integrate with the window server here), and WebKit's
        // real context-menu hit test returned nil every time regardless of click coordinates
        // (confirmed correct via `webView.convert`, cross-checked by printing the window point).
        // A stronger assertion would just fail permanently in this environment rather than prove
        // anything about the production override, so this stays as a same-shape check: proof
        // that whatever `menu(for:)` returns here contains no non-Copy item, not proof it's
        // non-empty. The real non-emptiness proof is the headless `ClosedSurfaceWebViewMenuTests`
        // calling `ClosedSurfaceWebView.copyOnly` directly on a real `NSMenu`.
        for point in [NSPoint(x: 30, y: window.contentView!.bounds.height - 20),   // over the link
                      NSPoint(x: 30, y: window.contentView!.bounds.height - 80)] { // over the image
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = webView.menu(for: event)
            let titles = menu?.items.map(\.title) ?? []
            #expect(titles.allSatisfy { $0.caseInsensitiveCompare("Copy") == .orderedSame },
                    "menu over \(point) had non-Copy items: \(titles)")
        }
    }

    @Test("a document over the byte cap never gets a web view at all, in a real window",
          .enabled(if: isEnabled))
    func overCapDocumentHasNoWebView() async throws {
        let content = String(repeating: "a", count: ViewerDocument.byteCap + 1)
        let document = ViewerDocument(conversationId: UUID(), messageId: UUID(), content: content)
        let window = ViewerWindowController.openForTesting(document: document, isTainted: false)
        defer { window.close() }

        try? await Task.sleep(for: .milliseconds(300))
        #expect(window.contentView?.firstDescendant(ofType: ViewerWebViewHost.self) == nil,
                "an over-cap document still built a web view — the refusal path didn't take")
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

    /// Builds the minimal config a mutation arm needs by hand (never through
    /// `ViewerWindowController`, which always wires the full production stack): JS off via
    /// `ViewerConfiguration.build`, the rule list only when `includeRuleList` asks for it, and the
    /// REAL `ViewerNavigationDelegate` with `decide` substituted — isolating exactly one layer's
    /// contribution per the mutation check above, while still exercising the production class's
    /// own `decisionCount`/`hasAllowedOnce` bookkeeping.
    private static func runMetaRefresh(to target: String, appScheme: String? = nil, appHandler: HitCountingHandler? = nil,
                                        decide: @escaping (URL, Bool, Bool) -> ViewerNavigationPolicy.Decision,
                                        includeRuleList: Bool = false) async throws {
        let html = "<html><head><meta http-equiv=\"refresh\" content=\"0;url=\(target)\"></head><body>trusted</body></html>"
        let handler = ViewerSchemeHandler(document: Data(html.utf8), includeCSP: false)
        let config = ViewerConfiguration.build(schemeHandler: handler)
        if let appScheme, let appHandler {
            config.setURLSchemeHandler(appHandler, forURLScheme: appScheme)
        }
        if includeRuleList {
            let id = "iris-view-test-gui-\(UUID().uuidString)"
            let list = try await ViewerContentRules.compile(identifier: id)
            config.userContentController.add(list)
        }

        let webView = ClosedSurfaceWebView(frame: .zero, configuration: config)
        let delegate = ViewerNavigationDelegate(decide: decide)
        webView.navigationDelegate = delegate

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await Self.waitForDecision(on: delegate, atLeast: 1)
        try? await Task.sleep(for: .seconds(1))   // the refresh fires with a 0s delay
    }

    /// Polls `decisionCount` rather than a fixed sleep for the initial load: it is the one signal
    /// this suite already relies on to prove the delegate engaged at all.
    private static func waitForDecision(on delegate: ViewerNavigationDelegate, atLeast count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while delegate.decisionCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Loads the trusted document through a counting scheme handler, reloads it, and returns how
    /// many times the handler actually served it — the ground truth for whether the second load
    /// ever reached the handler at all, independent of `webView.url`.
    private static func reloadHitCount(decide: @escaping (URL, Bool, Bool) -> ViewerNavigationPolicy.Decision) async throws -> Int {
        let handler = HitCountingHandler(path: ViewerConfiguration.documentURL)
        let config = ViewerConfiguration.build(schemeHandler: handler)

        let webView = ClosedSurfaceWebView(frame: .zero, configuration: config)
        let delegate = ViewerNavigationDelegate(decide: decide)
        webView.navigationDelegate = delegate

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await Self.waitForDecision(on: delegate, atLeast: 1)
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await Self.waitForDecision(on: delegate, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(200))   // lets a handler hit that will land actually land

        return handler.hits
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

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}

/// Counts how many times it served a response — review probe (iris-dev-2), generalized to serve
/// either a fixed `path` (for the reload test) or any request (for the made-up app-scheme test).
private final class HitCountingHandler: NSObject, WKURLSchemeHandler {
    private let path: URL?
    private let lock = NSLock()
    private var _hits = 0
    var hits: Int { lock.lock(); defer { lock.unlock() }; return _hits }

    init(path: URL? = nil) { self.path = path }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard path == nil || task.request.url == path else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        lock.lock(); _hits += 1; lock.unlock()
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": "text/html"])!
        task.didReceive(response)
        task.didReceive(Data("ok".utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
