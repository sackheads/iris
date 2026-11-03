import Testing
import Foundation
import WebKit
@testable import IrisKit

/// #896 phase 1: the tripwire tests (spec section 6). A change that turns script or a network
/// load back on must fail one of these first.
@MainActor
@Suite("ViewerConfiguration (#896)", .timeLimit(.minutes(1)))
struct ViewerConfigurationTests {
    @Test("JavaScript is off, windows cannot be script-opened, nothing is kept")
    func fieldByField() {
        let handler = ViewerSchemeHandler(document: Data())
        let config = ViewerConfiguration.build(schemeHandler: handler)

        #expect(config.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(config.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(config.userContentController.userScripts.isEmpty)
        #expect(config.websiteDataStore.isPersistent == false)
        #expect(config.urlSchemeHandler(forURLScheme: ViewerConfiguration.scheme) != nil)
    }

    @Test("the one URL the viewer ever loads")
    func documentURL() {
        #expect(ViewerConfiguration.documentURL.absoluteString == "iris-view://doc")
    }

    @Test("the CSP blocks script a second, independent way and every network load")
    func cspString() {
        let csp = ViewerConfiguration.contentSecurityPolicy
        #expect(csp.contains("sandbox"))
        #expect(!csp.contains("allow-scripts"))
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("style-src 'unsafe-inline'"))
        #expect(csp.contains("img-src data:"))
        #expect(csp.contains("form-action 'none'"))
        #expect(csp.contains("base-uri 'none'"))
    }

    @Test("a <script> served with the CSP header does not run, even with JavaScript enabled at the app level")
    func cspBlocksScriptBehaviorally() async throws {
        let html = "<html><head><title>before</title></head><body><script>document.title='after'</script></body></html>"
        let handler = ViewerSchemeHandler(document: Data(html.utf8))

        // JavaScript deliberately ON here, unlike the real configuration: this isolates the CSP
        // header's own effect from the app-level `allowsContentJavaScript` toggle (spec section 6:
        // "a string proves nothing about WebKit").
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: ViewerConfiguration.scheme)
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = NavigationFinishWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await waiter.waitForFinish()

        // `evaluateJavaScript` itself throws "Cannot execute JavaScript in this document" here:
        // the CSP sandbox disables scripting for the whole document, not just the inline script,
        // so `webView.title` (set by WebKit from the parsed `<title>`, never by evaluating script)
        // is the read that doesn't beg the question. WebKit's title sync is a separate message
        // from the WebContent process and isn't guaranteed to have landed by `didFinish` under
        // load (seen flaking under the full suite's CPU contention): poll it on the main actor,
        // the thread `webView.title` requires, rather than read it once right after the signal.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while webView.title != "before", ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(webView.title == "before")
    }
}

/// Resolves once the main-frame navigation finishes (or fails), so the behavioural CSP test
/// doesn't poll. Suite-level `.timeLimit` is the bound (#435): a stuck load fails the suite
/// instead of hanging the run, and it lives on `.timeLimit`, not an added wall-clock wait, because
/// this work is inherently main-actor WebKit callback work (AGENTS.md: a bound must not itself hop
/// to the main actor, but it is fine to be the main actor's own work).
@MainActor
private final class NavigationFinishWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    /// Only `ViewerConfiguration.documentURL` is ever allowed, same as `ContentRuleWaiter` in
    /// `ViewerContentRulesTests` and for the same reason: anything else risks WebKit handing an
    /// unhandled scheme to LaunchServices, which pops a real dialog on whoever's desktop runs the
    /// suite (#896 PR 1 review). This waiter only ever loads the one safe URL today, but the
    /// policy decision is the right default for any WKWebView-driving test delegate regardless.
    // The async overload, not the completion-handler one: the SDK's completion-handler type is
    // `@MainActor @Sendable`, which a `@MainActor` class's plain override never exactly matches
    // ("nearly matches optional requirement of WKNavigationDelegate" — #901 review round 3), and
    // `nonisolated` only compounds it, since `navigationAction`'s own properties are main-actor.
    // The async form needs neither `nonisolated` nor `MainActor.assumeIsolated`.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isAllowed = navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url == ViewerConfiguration.documentURL
        if !isAllowed { resume() }
        return isAllowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume() }

    func waitForFinish() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    private func resume() {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
