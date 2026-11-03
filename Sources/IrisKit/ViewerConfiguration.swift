import Foundation
import WebKit

/// #896 phase 1: a `WKWebView` that can show model-written HTML and SVG but has no way to run
/// script or load a network resource, by several independent mechanisms. See
/// docs/specs/2026-11-02-webkit-viewer.md for the full threat model; this file is the tripwire
/// the spec calls for (section 6) — a change that turns script or a network load back on fails
/// `ViewerConfigurationTests` first.
enum ViewerConfiguration {
    /// Applied to every `iris-view://doc` response by `ViewerSchemeHandler`. `sandbox` with no
    /// `allow-scripts` is a second, independent script block; `default-src 'none'` blocks every
    /// network load the page tries, but does not cover `form-action` or `base-uri`, so both are
    /// spelled out.
    static let contentSecurityPolicy =
        "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'"

    /// Disables Safari's opportunistic DNS lookups for `<link rel=dns-prefetch>` /
    /// `rel=preconnect`, which the CSP and the content rule list do not cover (section 1 of the
    /// spec: DNS can carry data in the hostname without loading anything).
    static let dnsPrefetchControlHeader = "off"

    static let scheme = "iris-view"
    static let documentHost = "doc"

    /// The one URL the viewer ever loads. `WKURLSchemeHandler` serves exactly this path; anything
    /// else is a 404 (`ViewerSchemeHandler`), and the navigation policy allows exactly this URL,
    /// once, as the main frame (`ViewerNavigationPolicy`).
    static var documentURL: URL { URL(string: "\(scheme)://\(documentHost)")! }

    /// Built fresh per window. No script, no bridge to the page, nothing kept between windows.
    @MainActor
    static func build(schemeHandler: WKURLSchemeHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()

        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false
        config.defaultWebpagePreferences = pagePreferences

        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Fresh, empty: no `add(_:name:)` is ever called on it, so there is no bridge from the
        // page to Iris, and no user script is ever added.
        config.userContentController = WKUserContentController()

        config.websiteDataStore = .nonPersistent()

        config.setURLSchemeHandler(schemeHandler, forURLScheme: scheme)

        return config
    }
}

/// Thrown when the deny-all rule list fails to compile. The spec requires the view to refuse to
/// load rather than show a page with no rule list at all.
enum ViewerError: Error, Equatable {
    case contentRuleListCompileFailed
}

/// A compiled `WKContentRuleList` that blocks every URL except `iris-view://doc`, by name rather
/// than by scheme: a scheme nobody thought of (an app-registered one, `applewebdata`, a future
/// one) is blocked too, because the default is block and the one exception is named.
enum ViewerContentRules {
    static let identifier = "iris-view-deny-all"

    static let encodedRuleList = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^iris-view://doc$"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    /// Compiles the rule list, using WebKit's own store by default. A real window always uses
    /// the shared store; tests may inject one scoped to a throwaway identifier so compiling twice
    /// in the same process (or in parallel suites) never races on the same cached entry.
    @MainActor
    static func compile(
        identifier: String = identifier,
        store: WKContentRuleListStore = .default()
    ) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encodedRuleList) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: ViewerError.contentRuleListCompileFailed)
                }
            }
        }
    }
}

/// A pure function over (request, is-main-frame, already-loaded), so the policy table in the spec
/// (section 6) can be asserted without a real `WKWebView`. The real navigation delegate calls this
/// and translates `allow`/`cancel` into `decisionHandler(.allow)` / `.cancel`.
enum ViewerNavigationPolicy {
    enum Decision: Equatable { case allow, cancel }

    /// Allows exactly one navigation: the main frame, to `ViewerConfiguration.documentURL`, before
    /// anything has loaded yet. Every subframe (`<iframe>`, `srcdoc`), every other URL
    /// (`about:blank`, `iris-view://other`, a fragment link, a form target, a `meta refresh`
    /// target, a clicked link) and any navigation after the first is cancelled.
    static func decide(url: URL, isMainFrame: Bool, alreadyLoaded: Bool) -> Decision {
        guard isMainFrame, !alreadyLoaded, url == ViewerConfiguration.documentURL else {
            return .cancel
        }
        return .allow
    }
}

/// Serves exactly one document, held by the handler instance rather than a shared registry, so
/// one window can never be asked for another's page (section 1, rule 2). One instance per window.
final class ViewerSchemeHandler: NSObject, WKURLSchemeHandler {
    private let document: Data

    init(document: Data) {
        self.document = document
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url == ViewerConfiguration.documentURL else {
            task.didReceive(Self.response(for: task.request.url, statusCode: 404, contentLength: 0))
            task.didFinish()
            return
        }
        task.didReceive(Self.response(for: url, statusCode: 200, contentLength: document.count))
        task.didReceive(document)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Nothing in flight to cancel: the whole document is handed over in one `didReceive`.
    }

    private static func response(for url: URL?, statusCode: Int, contentLength: Int) -> HTTPURLResponse {
        var headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(contentLength)",
            "X-DNS-Prefetch-Control": ViewerConfiguration.dnsPrefetchControlHeader,
        ]
        if statusCode == 200 {
            headers["Content-Security-Policy"] = ViewerConfiguration.contentSecurityPolicy
        }
        return HTTPURLResponse(
            url: url ?? ViewerConfiguration.documentURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
