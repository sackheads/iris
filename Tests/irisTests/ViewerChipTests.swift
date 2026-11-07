import Testing
import Foundation
import AppKit
@testable import IrisKit

/// #896 PR 2, spec section 6: "a document over 1 MB is refused with the message and not
/// truncated, and ... a streaming block has no chip." Both are pure functions, so neither test
/// renders a view.
@Suite("Viewer chip and cap (#896)")
struct ViewerChipPolicyTests {
    /// #896 PR 2: `ViewerChipPolicy.shouldOffer` is deliberately gate-free (it's a pure per-block
    /// check, tested on its own below); the one place that decides whether the chip is reachable
    /// at all is `ViewerFeatureGate`, wired at the `ChatView` call site. #904 flipped this on
    /// after a clean zero-DNS-lookup result, both headless and in a real on-screen window under
    /// the gui-test-lease (see `ViewerZeroLookupTests`/`ViewerGUIZeroLookupTests`). This test is
    /// the tripwire the other direction now: turning it back off is a real decision, never a side
    /// effect of refactoring this file.
    @Test("the viewer is reachable: #904 confirmed zero DNS lookups")
    func gateIsOnAfterDNSWasVerified() {
        #expect(ViewerFeatureGate.isEnabled == true)
    }

    @Test("html, not streaming: offered")
    func offered() {
        #expect(ViewerChipPolicy.shouldOffer(language: "html", isStreaming: false))
        #expect(ViewerChipPolicy.shouldOffer(language: "HTML", isStreaming: false))
    }

    @Test("still streaming: never offered, even for html")
    func notOfferedWhileStreaming() {
        #expect(!ViewerChipPolicy.shouldOffer(language: "html", isStreaming: true))
    }

    @Test("every other language: never offered")
    func notOfferedForOtherLanguages() {
        for language in [nil, "swift", "json", "bash", "markdown", ""] {
            #expect(!ViewerChipPolicy.shouldOffer(language: language, isStreaming: false))
        }
    }
}

@Suite("ViewerDocument byte cap (#896)")
struct ViewerDocumentCapTests {
    @Test("a document under the cap is not over it")
    func underCap() {
        let doc = ViewerDocument(conversationId: UUID(), messageId: UUID(), content: "<html></html>")
        #expect(!doc.isOverCap)
    }

    @Test("a document over the cap is over it, and the refusal names its real size")
    func overCap() {
        let content = String(repeating: "a", count: ViewerDocument.byteCap + 1)
        let doc = ViewerDocument(conversationId: UUID(), messageId: UUID(), content: content)
        #expect(doc.isOverCap)
        #expect(doc.html.count == ViewerDocument.byteCap + 1)
        #expect(ViewerTooLargeView.message(byteCount: doc.html.count).contains("KB > 1 MB"))
    }

    @Test("exactly at the cap is not over it")
    func exactlyAtCap() {
        let content = String(repeating: "a", count: ViewerDocument.byteCap)
        let doc = ViewerDocument(conversationId: UUID(), messageId: UUID(), content: content)
        #expect(!doc.isOverCap)
    }
}

/// #905 review finding 4: pins the banner's exact wording and the `isTainted` branch without a
/// window-server capture (none was taken — see the PR body for why). `@MainActor`: `ViewerBannerView`
/// conforms to `View`, so Swift infers its whole type (including these static lets) main-actor
/// isolated.
@MainActor
@Suite("ViewerBannerView wording (#896)")
struct ViewerBannerViewTests {
    @Test("untainted: only the always-shown line")
    func untainted() {
        #expect(ViewerBannerView.lines(isTainted: false) == [ViewerBannerView.alwaysLine])
    }

    @Test("tainted: the always-shown line plus the taint line")
    func tainted() {
        #expect(ViewerBannerView.lines(isTainted: true) == [ViewerBannerView.alwaysLine, ViewerBannerView.taintedLine])
    }

    @Test("the always-shown line claims no network connections and never mentions drag")
    func wordingClaims() {
        let line = ViewerBannerView.alwaysLine.lowercased()
        #expect(line.contains("cannot run"))
        #expect(line.contains("no network connections"))
        #expect(!line.contains("drag"))
        #expect(!line.contains("send"), "a 'send' claim would misstate drag-out, which Iris does not block")
    }
}

@MainActor
@Suite("ClosedSurfaceWebView context menu filter (#896)")
struct ClosedSurfaceWebViewMenuTests {
    @Test("keeps only items titled Copy, case-insensitively")
    func keepsOnlyCopy() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Link", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "COPY", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Download Image", action: nil, keyEquivalent: ""))

        let filtered = ClosedSurfaceWebView.copyOnly(menu)
        #expect(filtered?.items.map(\.title) == ["COPY"])
    }

    @Test("no Copy item at all: no menu")
    func noCopyMeansNoMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Link", action: nil, keyEquivalent: ""))

        #expect(ClosedSurfaceWebView.copyOnly(menu) == nil)
    }
}
