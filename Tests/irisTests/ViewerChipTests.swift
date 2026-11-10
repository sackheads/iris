import Testing
import Foundation
import AppKit
import WebKit
@testable import IrisKit

/// #896 PR 2, spec section 6: "a document over 1 MB is refused with the message and not
/// truncated, and ... a streaming block has no chip." Both are pure functions, so neither test
/// renders a view.
@Suite("Viewer chip and cap (#896)")
struct ViewerChipPolicyTests {
    /// #896 PR 2: `ViewerChipPolicy.shouldOffer` is deliberately gate-free (it's a pure per-block
    /// check, tested on its own below); the one place that decides whether the chip is reachable
    /// at all is `ViewerFeatureGate`, wired at the `ChatView` call site. #904 flipped it on after
    /// #912's allow-list sanitizer closed dns-prefetch by construction (#915, three review rounds).
    /// This is the tripwire in the other direction: the gate is on, and the chip's one production
    /// path sanitizes, so turning either off or adding a second, unsanitized path fails here.
    @Test("the viewer is reachable, through exactly one call site that sanitizes first")
    func gateIsOnAndTheOnlyPathSanitizes() throws {
        #expect(ViewerFeatureGate.isEnabled == true)
        let root = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        let chat = try String(contentsOf: root.appendingPathComponent("ChatView.swift"), encoding: .utf8)
        #expect(chat.contains("onOpenViewer: ViewerFeatureGate.isEnabled ? {"), "the chip must stay behind the gate")
        #expect(chat.contains("content: RawHTMLSanitizer.sanitize(configuration.content)"), "the document is built from sanitized HTML")
        // Every Swift file under Sources/ and App/, subdirectories included (#1049): a flat listing of
        // `Sources/IrisKit` missed anything in `A2A/` or `Eval/`, so a site planted there passed.
        let repo = PerfPaths.repoRoot()
        var sites: [String] = []
        for top in ["Sources", "App"] {
            let base = repo.appendingPathComponent(top)
            guard let walker = FileManager.default.enumerator(atPath: base.path) else {
                Issue.record("cannot walk \(base.path)"); continue
            }
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                let text = try String(contentsOf: base.appendingPathComponent(relative), encoding: .utf8)
                if text.contains("ViewerDocument(") { sites.append("\(top)/\(relative)") }
            }
        }
        #expect(sites == ["Sources/IrisKit/ChatView.swift"], "a second ViewerDocument construction site would bypass the sanitizer: \(sites)")
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
    /// What the live pass saw on a right-click over selected text (#904), by title.
    private func webKitDefaultMenu() -> NSMenu {
        let menu = NSMenu()
        for title in ["Look Up", "Translate", "Search with Google", "Copy", "Share\u{2026}", "Speech", "Services"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if title == "Services" || title == "Speech" { item.submenu = NSMenu(title: title) }
            menu.addItem(item)
            if title == "Translate" { menu.addItem(.separator()) }
        }
        return menu
    }

    @Test("keeps only items titled Copy, case-insensitively, and drops separators and submenus")
    func keepsOnlyCopy() {
        let menu = webKitDefaultMenu()
        menu.addItem(NSMenuItem(title: "COPY", action: nil, keyEquivalent: ""))
        ClosedSurfaceWebView.restrictToCopy(menu)
        #expect(menu.items.map(\.title) == ["Copy", "COPY"])
    }

    @Test("no Copy item at all: an empty menu")
    func noCopyMeansEmpty() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Link", action: nil, keyEquivalent: ""))
        ClosedSurfaceWebView.restrictToCopy(menu)
        #expect(menu.items.isEmpty)
    }

    @Test("the menu WebKit hands willOpenMenu is restricted to Copy before it shows (#904 live pass)")
    func willOpenMenuRestricts() {
        let webView = ClosedSurfaceWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = webKitDefaultMenu()
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        webView.willOpenMenu(menu, with: event)
        #expect(menu.items.map(\.title) == ["Copy"], "left: \(menu.items.map(\.title))")
    }

    @Test("willOpenMenu switches the context-menu plug-ins off, which is what keeps Services and Share out (#904 live pass)")
    func willOpenMenuSwitchesPlugInsOff() {
        let webView = ClosedSurfaceWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = true
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        webView.willOpenMenu(menu, with: event)
        #expect(menu.allowsContextMenuPlugIns == false)
    }

    @Test("the viewer's web view is a requestor for no service, for any pasteboard type")
    func noServiceRequestor() {
        let webView = ClosedSurfaceWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(webView.validRequestor(forSendType: .string, returnType: nil) == nil)
        #expect(webView.validRequestor(forSendType: .string, returnType: .string) == nil)
        #expect(webView.validRequestor(forSendType: nil, returnType: nil) == nil)
    }

    @Test("the shipped web view class overrides willOpenMenu, the hook WebKit presents its menu through")
    func overrideIsPresent() throws {
        let source = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/ViewerWindow.swift"), encoding: .utf8)
        #expect(source.contains("override func willOpenMenu(_ menu: NSMenu, with event: NSEvent)"))
        #expect(source.contains("let webView = ClosedSurfaceWebView(frame: bounds, configuration: config)"),
                "the viewer host must build the restricting subclass, not a bare WKWebView")
    }
}
