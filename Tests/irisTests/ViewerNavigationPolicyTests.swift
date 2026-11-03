import Testing
import Foundation
@testable import IrisKit

/// #896 phase 1: the pure navigation-policy table from the spec (section 6). `WKNavigationAction`
/// has no public initializer, so the real decision function is a pure function over
/// (url, isMainFrame, alreadyLoaded) that the real delegate (PR 2, which has the window) calls —
/// this is what lets the table be asserted without a `WKWebView` at all.
@Suite("Viewer navigation policy (#896)")
struct ViewerNavigationPolicyTests {
    @Test("the first main-frame load of iris-view://doc is allowed")
    func firstLoadAllowed() {
        let decision = ViewerNavigationPolicy.decide(
            url: ViewerConfiguration.documentURL, isMainFrame: true, alreadyLoaded: false)
        #expect(decision == .allow)
    }

    @Test("the same URL again, after the first load, is cancelled")
    func secondLoadCancelled() {
        let decision = ViewerNavigationPolicy.decide(
            url: ViewerConfiguration.documentURL, isMainFrame: true, alreadyLoaded: true)
        #expect(decision == .cancel)
    }

    @Test("a subframe load of the document URL is cancelled (an <iframe> or srcdoc)")
    func subframeCancelled() {
        let decision = ViewerNavigationPolicy.decide(
            url: ViewerConfiguration.documentURL, isMainFrame: false, alreadyLoaded: false)
        #expect(decision == .cancel)
    }

    @Test("every other URL is cancelled, before and after the first load", arguments: [
        "about:blank",
        "iris-view://other",
        "iris-view://doc#fragment",
        "iris-view://doc/extra",
        "https://example.invalid/form-target",
        "https://example.invalid/meta-refresh-target",
        "https://example.invalid/clicked-link",
    ])
    func otherURLsCancelled(_ raw: String) {
        let url = URL(string: raw)!
        #expect(ViewerNavigationPolicy.decide(url: url, isMainFrame: true, alreadyLoaded: false) == .cancel)
        #expect(ViewerNavigationPolicy.decide(url: url, isMainFrame: true, alreadyLoaded: true) == .cancel)
    }
}
