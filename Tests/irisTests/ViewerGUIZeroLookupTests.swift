import Testing
import Foundation
import AppKit
import Network
import WebKit
@testable import IrisKit

/// #904: `ViewerZeroLookupTests` (headless) proves the production config makes zero lookups on an
/// offscreen `WKWebView(frame: .zero, ...)` for `rel=preconnect` and ordinary network loads — but
/// PR 1 already found `decidePolicyFor` never fires offscreen, and the same gap could apply to
/// WebKit's speculative-loading heuristics too. This is the authoritative pass the spec calls for
/// (section 1: "PR 1 observes DNS ... with a hostile page"): the same SOCKS5h "resolver we
/// control", in a REAL, on-screen window.
///
/// Built directly from `WKWebView`/`NSWindow` (not `ViewerWindowController.openForTesting`'s
/// SwiftUI/`NSHostingView` chain, which an earlier cut of this file used and which reliably
/// crashed the test process with SIGSEGV the moment a second proxy-backed session ran in the same
/// binary, concurrently or sequentially). dev-2's #904 review probe ran both arms this way, back
/// to back, in one process, with no crash — the SwiftUI window chrome, not proxy-backed `WKWebView`
/// sessions in general, looks like the actual trigger.
///
/// Carries the same control `ViewerZeroLookupTests.hintChannelsControl` does headless, and for the
/// same reason (#904 review finding 1 and 2, dev-2): without it, a zero result below is
/// meaningless noise, since this instrument cannot observe `rel=dns-prefetch`/`rel=prefetch` at
/// all, in a real window any more than offscreen.
///
/// Gated on `IRIS_VIEWER_GUI_TEST=1`, same convention as `ViewerGUINavigationTests` (AGENTS.md):
/// `swift test` and CI never run it. Run only under the gui-test-lease.
@MainActor
@Suite("Viewer GUI: zero DNS lookups on a real window (#904, opt-in)", .timeLimit(.minutes(1)))
struct ViewerGUIZeroLookupTests {
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.environment["IRIS_VIEWER_GUI_TEST"] == "1" }

    private func socksProxyConfiguration(port: UInt16) -> ProxyConfiguration {
        ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    private func realWindow(configuration: WKWebViewConfiguration) -> (window: NSWindow, webView: WKWebView) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        return (window, webView)
    }

    static let hintHTML = """
    <html><head>
    <link rel="dns-prefetch" href="//iris-gui-hint-dnsprefetch-probe.invalid.example">
    <link rel="preconnect" href="//iris-gui-hint-preconnect-probe.invalid.example">
    <link rel="prefetch" href="http://iris-gui-hint-prefetch-probe.invalid.example/x">
    </head><body>hello</body></html>
    """

    @Test(
        "hint channels, unmitigated, in a real window: preconnect is observable, dns-prefetch and prefetch are not",
        .enabled(if: isEnabled)
    )
    func hintChannelsControlInARealWindow() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [socksProxyConfiguration(port: proxy.port)]
        config.websiteDataStore = store
        let (window, webView) = realWindow(configuration: config)
        defer { window.close() }

        webView.loadHTMLString(Self.hintHTML, baseURL: URL(string: "http://iris-gui-hint-base-probe.invalid.example/"))
        try? await Task.sleep(for: .seconds(5))

        let hosts = proxy.recordedTargets.map(\.host)
        #expect(hosts.contains("iris-gui-hint-preconnect-probe.invalid.example"),
                "the proxy no longer sees an unmitigated preconnect in a real window — the instrument itself may have regressed")
        #expect(!hosts.contains("iris-gui-hint-dnsprefetch-probe.invalid.example"),
                "dns-prefetch became observable through the proxy in a real window — re-check whether the gate can now rely on it")
        #expect(!hosts.contains("iris-gui-hint-prefetch-probe.invalid.example"),
                "prefetch became observable through the proxy in a real window — re-check whether the gate can now rely on it")
    }

    @Test(
        "the production viewer, in a real on-screen window, makes zero lookups for preconnect and every ordinary network channel",
        .enabled(if: isEnabled)
    )
    func productionWindowMakesZeroLookups() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let html = """
        <html><head>
        <link rel="dns-prefetch" href="//iris-gui-dns-prefetch-probe.invalid.example">
        <link rel="preconnect" href="//iris-gui-preconnect-probe.invalid.example">
        <link rel="stylesheet" href="http://iris-gui-link-probe.invalid.example/link.css">
        <style>
        body { background: url(http://iris-gui-cssurl-probe.invalid.example/css-url); }
        @import url(http://iris-gui-cssimport-probe.invalid.example/import.css);
        </style>
        </head><body>
        <img src="http://iris-gui-img-probe.invalid.example/img.png">
        <form action="http://iris-gui-form-probe.invalid.example/form" method="post" id="f"></form>
        </body></html>
        """

        let id = "iris-view-gui-test-zero-lookup-\(UUID().uuidString)"
        let list = try await ViewerContentRules.compile(identifier: id)
        defer { WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier: id) { _ in } }

        let handler = ViewerSchemeHandler(document: Data(html.utf8))
        let config = ViewerConfiguration.build(schemeHandler: handler, proxyConfigurations: [socksProxyConfiguration(port: proxy.port)])
        config.userContentController.add(list)
        let (window, webView) = realWindow(configuration: config)
        defer { window.close() }

        webView.load(URLRequest(url: ViewerConfiguration.documentURL))

        // Opportunistic prefetch/preconnect hints are not synchronous with the main load, and a
        // real window needs a real moment on screen before a speculative load would fire —
        // mirrors ViewerZeroConnectionsTests/ViewerZeroLookupTests' own wait, extended since this
        // runs on an actual window rather than offscreen.
        try? await Task.sleep(for: .seconds(5))

        #expect(
            proxy.recordedTargets.isEmpty,
            "the production viewer let a hostname reach the proxy in a real window: \(proxy.recordedTargets.map(\.description))"
        )
    }
}
