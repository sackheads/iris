import Testing
import Foundation
import Network
import WebKit
@testable import IrisKit

/// #904: the spec's DNS ship blocker (docs/specs/2026-11-02-webkit-viewer.md, section 1) — a
/// `<link rel=dns-prefetch>`/`rel=preconnect` can carry data in the hostname without loading
/// anything, so "nothing here can send anything" is a claim to be proven, not assumed. This is
/// the "resolver we control" the spec calls for: `SOCKS5ProxyTestHelper` sits where WebKit's own
/// network stack would otherwise go via `WKWebsiteDataStore.proxyConfigurations`. It proved
/// reliable for `rel=preconnect` and ordinary network loads — see `hintChannelsControl` below —
/// but NOT for `rel=dns-prefetch`/`rel=prefetch`, which never show up here whether or not WebKit
/// actually resolves them, which is why dns-prefetch is closed by construction (`RawHTMLSanitizer`, #912) and not by this instrument (dev-2's #904 review finding 1); `ViewerFeatureGate` is on as of #904's flip.
@MainActor
@Suite("Viewer: zero DNS lookups (#904)", .timeLimit(.minutes(1)))
struct ViewerZeroLookupTests {
    private func socksProxyConfiguration(port: UInt16) -> ProxyConfiguration {
        ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    /// Without this control, a zero-lookup result below would be meaningless: it could just as
    /// easily mean "nothing tried the network" as "the proxy wiring itself does not see what the
    /// real network stack sees" (the same failure shape as #905's offscreen `decidePolicyFor`
    /// gap). No CSP, no rule list, no scheme-handler restriction — only the proxy is wired in.
    @Test("sanity: the proxy wiring intercepts a real, unblocked network load")
    func proxyInterceptsAnUnblockedLoad() async throws {
        // holdOpen: false — nothing here blocks the image load, so held open with no response it
        // would never finish or fail, the page's `load` event would never fire, and `didFinish`
        // never would either (the bug that hung this test for real; see the waiter below).
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [socksProxyConfiguration(port: proxy.port)]
        config.websiteDataStore = store

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = AllowEverythingNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(
            "<html><body><img src=\"http://iris-proxy-sanity-probe.invalid.example/x.png\"></body></html>",
            baseURL: URL(string: "http://iris-proxy-sanity-base.invalid.example/")
        )
        await waiter.waitForFinish()
        try? await Task.sleep(for: .seconds(1))

        #expect(
            proxy.recordedTargets.map(\.host).contains("iris-proxy-sanity-probe.invalid.example"),
            "the SOCKS5 harness never saw the control image load reach it — a zero-lookup result elsewhere would prove nothing"
        )
    }

    /// #904 review finding 1 (dev-2): the proxy is NOT a reliable instrument for every DNS-only
    /// hint. Unmitigated — no scheme handler, no CSP, no rule list, only the proxy wired — it
    /// records `rel=preconnect`'s host every time, but never `rel=dns-prefetch`'s or
    /// `rel=prefetch`'s, even given a real window and a real wait. That means WebKit either never
    /// resolves those two in this setup, or resolves them through the system resolver, bypassing
    /// `WKWebsiteDataStore.proxyConfigurations` entirely — this instrument cannot tell those
    /// apart. dns-prefetch/prefetch are therefore closed by construction (`RawHTMLSanitizer`, #912)
    /// rather than observed: see `productionConfigMakesZeroLookups` below, whose zero for them is
    /// not proof of anything, only its zero for preconnect and ordinary loads is, and
    /// `shippedPathMakesZeroLookups`, which runs the sanitized page through the same config.
    @Test("hint channels, unmitigated: preconnect is observable through the proxy, dns-prefetch and prefetch are not")
    func hintChannelsControl() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let html = """
        <html><head>
        <link rel="dns-prefetch" href="//iris-hint-dnsprefetch-probe.invalid.example">
        <link rel="preconnect" href="//iris-hint-preconnect-probe.invalid.example">
        <link rel="prefetch" href="http://iris-hint-prefetch-probe.invalid.example/x">
        </head><body>hello</body></html>
        """

        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [socksProxyConfiguration(port: proxy.port)]
        config.websiteDataStore = store

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = AllowEverythingNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: URL(string: "http://iris-hint-base-probe.invalid.example/"))
        await waiter.waitForFinish()
        try? await Task.sleep(for: .seconds(2))

        let hosts = proxy.recordedTargets.map(\.host)
        #expect(hosts.contains("iris-hint-preconnect-probe.invalid.example"),
                "the proxy no longer sees an unmitigated preconnect — the instrument itself may have regressed")
        #expect(!hosts.contains("iris-hint-dnsprefetch-probe.invalid.example"),
                "dns-prefetch became observable through the proxy — if WebKit changed this, re-check whether the gate can now rely on it")
        #expect(!hosts.contains("iris-hint-prefetch-probe.invalid.example"),
                "prefetch became observable through the proxy — if WebKit changed this, re-check whether the gate can now rely on it")
    }

    @Test("the production viewer config makes zero lookups for every DNS-only and network channel")
    func productionConfigMakesZeroLookups() async throws {
        let proxy = try SOCKS5ProxyTestHelper()
        defer { proxy.close() }

        let html = """
        <html><head>
        <link rel="dns-prefetch" href="//iris-dns-prefetch-probe.invalid.example">
        <link rel="preconnect" href="//iris-preconnect-probe.invalid.example">
        <link rel="stylesheet" href="http://iris-link-probe.invalid.example/link.css">
        <meta http-equiv="refresh" content="0;url=http://iris-refresh-probe.invalid.example/refresh">
        <style>
        body { background: url(http://iris-cssurl-probe.invalid.example/css-url); }
        @import url(http://iris-cssimport-probe.invalid.example/import.css);
        </style>
        </head><body>
        <img src="http://iris-img-probe.invalid.example/img.png">
        <form action="http://iris-form-probe.invalid.example/form" method="post" id="f"></form>
        </body></html>
        """

        let id = "iris-view-test-zero-lookup-\(UUID().uuidString)"
        let list = try await ViewerContentRules.compile(identifier: id)
        defer { WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier: id) { _ in } }

        let handler = ViewerSchemeHandler(document: Data(html.utf8))
        let config = ViewerConfiguration.build(schemeHandler: handler, proxyConfigurations: [socksProxyConfiguration(port: proxy.port)])
        config.userContentController.add(list)

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = TrustedOnlyNavigationWaiterForZeroLookup()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await waiter.waitForFinish()

        // Mirrors ViewerZeroConnectionsTests: the meta refresh fires after load, and dns-prefetch/
        // preconnect are opportunistic, not synchronous with it — give every channel a real
        // window to reach the proxy before asserting on what it recorded.
        try? await Task.sleep(for: .seconds(1))

        #expect(
            proxy.recordedTargets.isEmpty,
            "the production viewer config let a hostname reach the proxy: \(proxy.recordedTargets.map(\.description))"
        )
    }

    /// #904's flip: the page the user's click really loads is `RawHTMLSanitizer.sanitize(model HTML)`
    /// in the production config, not the raw page. This runs that composition against the proxy
    /// with every hint #912 strips, so the evidence is for the shipped path and not for the two
    /// halves measured apart (the sanitizer changed after #911 measured).
    @Test("the shipped path (sanitized page, production config) makes zero lookups")
    func shippedPathMakesZeroLookups() async throws {
        let proxy = try SOCKS5ProxyTestHelper()
        defer { proxy.close() }

        let hostile = """
        <html><head>
        <link rel="dns-prefetch" href="//iris-s-dnsprefetch.invalid.example">
        <link rel="stylesheet dns-prefetch" href="//iris-s-multirel.invalid.example/a.css">
        <link rel="PRECONNECT" href="//iris-s-preconnect.invalid.example">
        <link rel="prefetch" href="//iris-s-prefetch.invalid.example/x">
        <link rel="preload" as="image" href="http://iris-s-preload.invalid.example/p.png">
        <base href="http://iris-s-base.invalid.example/">
        <meta http-equiv="refresh" content="0;url=http://iris-s-refresh.invalid.example/r">
        </head><body>
        <a href="http://iris-s-a.invalid.example/" ping="http://iris-s-ping.invalid.example/p">x</a>
        <img src="http://iris-s-img.invalid.example/i.png">
        </body></html>
        """
        let shipped = RawHTMLSanitizer.sanitize(hostile)
        for needle in ["dns-prefetch", "preconnect", "prefetch", "preload", "<base", "ping=", "http-equiv"] {
            #expect(!shipped.lowercased().contains(needle), "the sanitizer let \(needle) through: \(shipped)")
        }

        let id = "iris-view-test-shipped-\(UUID().uuidString)"
        let list = try await ViewerContentRules.compile(identifier: id)
        defer { WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier: id) { _ in } }

        let handler = ViewerSchemeHandler(document: Data(shipped.utf8))
        let config = ViewerConfiguration.build(schemeHandler: handler, proxyConfigurations: [socksProxyConfiguration(port: proxy.port)])
        config.userContentController.add(list)

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = TrustedOnlyNavigationWaiterForZeroLookup()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await waiter.waitForFinish()
        try? await Task.sleep(for: .seconds(1))

        #expect(proxy.recordedTargets.isEmpty,
                "the shipped path let a hostname reach the proxy: \(proxy.recordedTargets.map(\.description))")
    }
}

@MainActor
private final class AllowEverythingNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    private func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    /// Bounded, not a bare `await withCheckedContinuation`: a continuation ignores `.timeLimit`'s
    /// cancellation same as the bare-task case `value(of:within:)` exists for (AGENTS.md #428,
    /// #435) — this hung for real when the proxy held a resource fetch open with no response, so
    /// `didFinish` never fired and the 2-minute suite `.timeLimit` never got a chance to end it.
    func waitForFinish() async {
        if finished { return }
        let task = Task<Void, Never> { await withCheckedContinuation { self.continuation = $0 } }
        _ = try? await irisTests.value(of: task, within: 10)
    }
}

/// Same shape as `TrustedOnlyNavigationWaiter` in `ViewerZeroConnectionsTests.swift` (that one is
/// `private` to its own file) — only the trusted document is ever allowed.
@MainActor
private final class TrustedOnlyNavigationWaiterForZeroLookup: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isAllowed = navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url == ViewerConfiguration.documentURL
        return isAllowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    private func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    /// Bounded for the same reason as `AllowEverythingNavigationWaiter.waitForFinish` above.
    func waitForFinish() async {
        if finished { return }
        let task = Task<Void, Never> { await withCheckedContinuation { self.continuation = $0 } }
        _ = try? await irisTests.value(of: task, within: 10)
    }
}
