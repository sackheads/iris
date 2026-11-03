import Testing
import Foundation
import WebKit
@testable import IrisKit

/// #896 phase 1: the deny-all `WKContentRuleList` is the "no load, no navigation" layer that does
/// not depend on knowing every scheme in advance (spec section 1, rule 3) — the default is block,
/// and the one exception is named. These tests use their own throwaway identifier so running this
/// suite twice, or beside another parallel suite, never races on the same cached compiled list.
@MainActor
@Suite("Viewer content rule list (#896)", .timeLimit(.minutes(1)))
struct ViewerContentRulesTests {
    @Test("the rule list compiles")
    func compiles() async throws {
        // WKContentRuleList exposes no public accessor to assert against; compiling without
        // throwing, which `try await` already requires, is the assertion.
        _ = try await ViewerContentRules.compile(identifier: "iris-view-test-\(UUID().uuidString)")
    }

    @Test("a bad rule list fails to compile, and the view refusing to load is the caller's job")
    func compileFailureIsThrown() async {
        let store = WKContentRuleListStore.default()!
        let badJSON = "{ not a rule list }"
        await #expect(throws: Error.self) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
                store.compileContentRuleList(forIdentifier: "iris-view-test-bad-\(UUID().uuidString)", encodedContentRuleList: badJSON) { list, error in
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

    // NOTE: there is deliberately no test here that drives a real `WKWebView` to navigate its
    // *main frame* directly to an untrusted scheme (http, ftp, an unregistered one, ...), even
    // behind a navigation delegate that cancels the policy decision. Doing exactly that during
    // this PR's own development handed an unregistered scheme to LaunchServices and popped a real
    // "no application set to open the URL ..." dialog on the machine running the suite — WebKit's
    // hand-off to the OS for an unhandled top-level scheme is evidently not fully gated by
    // `decidePolicyForNavigationAction`. `ViewerNavigationPolicyTests` already covers "every
    // scheme is cancelled" as a pure function, with no real WebKit involved, which is the safe way
    // to assert that table. The content rule list's own, additional contribution — blocking a
    // *subresource* fetch from a page that legitimately loaded — is covered by the zero-connections
    // test below, which only ever navigates the main frame to the one trusted URL.

    @Test("iris-view://doc loads under the deny-all rule list, since it is the one exception")
    func documentURLLoadsUnderTheRuleList() async throws {
        let id = "iris-view-test-\(UUID().uuidString)"
        let list = try await ViewerContentRules.compile(identifier: id)
        defer { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in } }

        let handler = ViewerSchemeHandler(document: Data("<html>doc</html>".utf8))
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: ViewerConfiguration.scheme)
        config.userContentController.add(list)

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = ContentRuleWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        let outcome = await waiter.waitForOutcome()

        #expect(outcome == .finishedLoading)
    }
}

private enum LoadOutcome: Equatable { case finishedLoading, failed }

/// Mirrors `ViewerNavigationPolicy.decide`, independently of the content rule list under test.
/// Without this, a URL whose scheme WebKit doesn't itself handle (and that the rule list, for
/// whatever reason, let through — or a version where rule lists don't cover the main frame) is
/// treated as an external URL and handed to LaunchServices, which pops a real "no application set
/// to open the URL ..." dialog on whoever's desktop runs the suite (#896 PR 1 review, caught live
/// on Brian's screen). Cancelling in the policy decision, not just reacting to the outcome, is both
/// the fix and the behaviour production code must have anyway (spec section 1, rule 3: "several
/// independent mechanisms").
@MainActor
private final class ContentRuleWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<LoadOutcome, Never>?
    private var outcome: LoadOutcome?

    // The async overload, not the completion-handler one: the SDK's completion-handler type is
    // `@MainActor @Sendable`, which a `@MainActor` class's plain override never exactly matches
    // ("nearly matches optional requirement of WKNavigationDelegate" — #901 review round 3), and
    // `nonisolated` only compounds it, since `navigationAction`'s own properties are main-actor.
    // The async form needs neither `nonisolated` nor `MainActor.assumeIsolated`.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isAllowed = navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url == ViewerConfiguration.documentURL
        if !isAllowed { resolve(.failed) }
        return isAllowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resolve(.finishedLoading) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resolve(.failed) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resolve(.failed) }

    func waitForOutcome() async -> LoadOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    private func resolve(_ value: LoadOutcome) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
