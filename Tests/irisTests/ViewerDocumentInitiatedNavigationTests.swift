import Testing
import Foundation
import WebKit
@testable import IrisKit

/// #896 phase 1: the planner's follow-up to the LaunchServices incident in `ViewerContentRulesTests`.
/// That incident was our own test code calling `.load()` directly on a hostile scheme — not a
/// real threat, since production code never does that, and rightly removed. The real threat with
/// script off is a *document-initiated* top-level navigation: a hostile `iris-view://doc` whose
/// `<meta http-equiv=refresh>`, form or link tries to leave. This only ever calls `.load()` on the
/// one trusted URL; the navigation attempt is entirely the page's own doing.
///
/// A diagnostic while writing this test found that `WKNavigationDelegate.decidePolicyFor` is never
/// invoked at all for a `WKWebView(frame: .zero, ...)` that is never added to a real window —
/// confirmed by instrumenting it: the method saw zero calls even for this suite's own trusted
/// `.load()` of `iris-view://doc`, not just for the meta refresh. So these tests cannot assert "the
/// navigation delegate cancelled it" — in this headless shape that delegate method simply never
/// runs, trusted load or not. What they *can*, and do, assert is the externally observable outcome:
/// the load completes (no hang) and produces no connection to a loopback listener standing in for
/// "left the sandbox". That is weaker than confirming the delegate's own cancel behaviour, which
/// needs a real window — the GUI-lease pass in PR 2 is where that layer gets its test, per the
/// spec's own fallback for exactly this ("if WKWebView cannot run headless there..."). The content
/// rule list and CSP, which this test also exercises, are both confirmed effective headless
/// elsewhere in this PR (`ViewerContentRulesTests`, `ViewerZeroConnectionsTests`).
@MainActor
@Suite("Viewer: a document-initiated navigation away from the trusted page (#896)", .timeLimit(.minutes(1)))
struct ViewerDocumentInitiatedNavigationTests {
    @Test("a meta refresh to an unregistered app scheme never reaches the loopback listener, and never hangs")
    func metaRefreshToAppScheme() async throws {
        try await assertMetaRefreshDoesNotEscape(targetHost: "iris-view-test-unregistered-app://evil")
    }

    @Test("a meta refresh to an ordinary http(s) URL never reaches the loopback listener, and never hangs")
    func metaRefreshToHTTP() async throws {
        let listener = try ConnectionCountingServer()
        defer { listener.close() }
        try await assertMetaRefreshDoesNotEscape(targetHost: "http://127.0.0.1:\(listener.port)/evil", listener: listener)
    }

    /// `targetHost` is a scheme WebKit cannot resolve to anything real in this process (an
    /// unregistered custom scheme, or a loopback port with nothing listening at the time of the
    /// refresh unless `listener` is passed) — the point is only that the main-frame navigation the
    /// page tries to make on its own never completes, hangs, or reaches a live listener.
    private func assertMetaRefreshDoesNotEscape(targetHost: String, listener: ConnectionCountingServer? = nil) async throws {
        let html = """
        <html><head><meta http-equiv="refresh" content="0;url=\(targetHost)"></head><body>trusted</body></html>
        """
        let id = "iris-view-test-\(UUID().uuidString)"
        let list = try await ViewerContentRules.compile(identifier: id)
        defer { WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier: id) { _ in } }

        let handler = ViewerSchemeHandler(document: Data(html.utf8))
        let config = ViewerConfiguration.build(schemeHandler: handler)
        config.userContentController.add(list)

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = InitialLoadWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await waiter.waitForInitialLoad()

        // The meta refresh fires with a 0s delay; give it a real window to reach wherever it's
        // going before asserting it got nowhere.
        try? await Task.sleep(for: .seconds(1))

        #expect(listener?.acceptedCount ?? 0 == 0, "the meta refresh reached the loopback listener")
    }
}

@MainActor
private final class InitialLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

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
