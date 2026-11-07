import Testing
import Foundation
import AppKit
import Network
import WebKit
@testable import IrisKit

/// #904: `ViewerZeroLookupTests` (headless) proves the production config makes zero lookups on an
/// offscreen `WKWebView(frame: .zero, ...)`, including its own real-network-load sanity control —
/// but PR 1 already found `decidePolicyFor` never fires offscreen, and WebKit's own
/// speculative-loading heuristics (what `<link rel=dns-prefetch>` actually triggers) are
/// undocumented enough that the same gap could apply here too. This is the authoritative pass the
/// spec calls for (section 1: "PR 1 observes DNS ... with a hostile page"): the SOCKS5h "resolver
/// we control" wired to a REAL, on-screen window via `ViewerWindowController.openForTesting`'s
/// test-only `proxyConfigurations` seam.
///
/// No repeated sanity control here — a second `WKWebView`+proxy session in the same test process,
/// run either concurrently or sequentially after this one, reliably crashed the process with
/// SIGSEGV (confirmed: this test alone passed every time, in 3.3s, with zero lookups). That smells
/// like fragility in running two proxy-backed data stores in one test binary, not a finding about
/// the production code, and the headless suite already proves the plumbing works; one real window
/// is enough to answer PR 1's actual gap (does this fire at all outside an offscreen view).
///
/// Gated on `IRIS_VIEWER_GUI_TEST=1`, same convention as `ViewerGUINavigationTests` (AGENTS.md):
/// `swift test` and CI never run it. Run only under the gui-test-lease.
@MainActor
@Suite("Viewer GUI: zero DNS lookups on a real window (#904, opt-in)", .timeLimit(.minutes(1)))
struct ViewerGUIZeroLookupTests {
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.environment["IRIS_VIEWER_GUI_TEST"] == "1" }

    @Test(
        "the production viewer, in a real on-screen window, makes zero lookups for every DNS-only and network channel",
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
        let document = ViewerDocument(conversationId: UUID(), messageId: UUID(), content: html)
        let proxyConfig = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!))

        let window = ViewerWindowController.openForTesting(document: document, isTainted: false, proxyConfigurations: [proxyConfig])
        defer { window.close() }

        // Opportunistic prefetch/preconnect hints are not synchronous with the main load, and a
        // real window needs a real moment on screen before a speculative load would fire —
        // mirrors ViewerZeroConnectionsTests/ViewerZeroLookupTests' own wait, extended since this
        // runs on an actual window rather than offscreen.
        try? await Task.sleep(for: .seconds(3))

        #expect(
            proxy.recordedTargets.isEmpty,
            "the production viewer let a hostname reach the proxy in a real window: \(proxy.recordedTargets.map(\.description))"
        )
    }
}
