import Testing
import Foundation
import Network
import WebKit
@testable import IrisKit

/// #912: the allow-list sanitizer that closes the viewer's dns-prefetch gap by construction
/// (docs/specs/2026-11-02-webkit-viewer.md section 1). Pure-function table tests pin the
/// tokenizer and the per-tag rules; `hintFormsFixture` below drives a fixture of real hostile
/// spellings, not the canonical one, through the same assertions. The oracle test at the bottom
/// is the one piece of this that reaches into WebKit and the SOCKS5h proxy (#904): dns-prefetch
/// itself cannot be observed there (that is the whole reason this sanitizer exists), but
/// preconnect can, so a correct stripper driving preconnect to zero through the proxy is the
/// closest thing to a live proof this sanitizer has — and it is mutation-checked, not just green.
@Suite("RawHTMLSanitizer (#912)")
struct RawHTMLSanitizerTests {
    @Test("plain text with no tags passes through byte-for-byte")
    func plainTextUnchanged() {
        let text = "hello, world — nothing here is a tag < or >"
        // `<` with no tag name after it (` or`) and `>` alone are not valid tag starts, so the
        // tokenizer must read them as text, not swallow them as a malformed tag.
        #expect(RawHTMLSanitizer.sanitize("hello, world — nothing here is a tag &lt; or &gt;")
                == "hello, world — nothing here is a tag &lt; or &gt;")
        _ = text
    }

    @Test("ordinary structural and text tags pass through with their safe attributes")
    func ordinaryTagsPassThrough() {
        let html = "<div class=\"card\"><p>hello <b>world</b></p></div>"
        #expect(RawHTMLSanitizer.sanitize(html) == html)
    }

    @Test("a disallowed tag is dropped, its text content kept")
    func disallowedTagDropsButKeepsText() {
        #expect(RawHTMLSanitizer.sanitize("<marquee>hello</marquee>") == "hello")
    }

    @Test("script is dropped tag and content")
    func scriptDroppedWithContent() {
        #expect(RawHTMLSanitizer.sanitize("before<script>alert(document.cookie)</script>after") == "beforeafter")
    }

    @Test("every on* event handler attribute is stripped, on every tag")
    func onHandlersStripped() {
        #expect(RawHTMLSanitizer.sanitize("<div onclick=\"exfil()\">hi</div>") == "<div>hi</div>")
        #expect(RawHTMLSanitizer.sanitize("<img src=\"data:image/gif;base64,AA==\" onerror=\"exfil()\">")
                == "<img src=\"data:image/gif;base64,AA==\">")
    }

    // MARK: - rel: the multi-token case a deny-list regex would miss

    @Test("link rel=dns-prefetch alone is dropped entirely")
    func linkDnsPrefetchDropped() {
        #expect(RawHTMLSanitizer.sanitize("<link rel=\"dns-prefetch\" href=\"//evil.example\">") == "")
    }

    @Test("link rel=preconnect alone is dropped entirely")
    func linkPreconnectDropped() {
        #expect(RawHTMLSanitizer.sanitize("<link rel=\"preconnect\" href=\"//evil.example\">") == "")
    }

    @Test("multi-token rel keeps the safe token and drops the speculative one")
    func multiTokenRelKeepsSafeToken() {
        let out = RawHTMLSanitizer.sanitize("<link rel=\"stylesheet dns-prefetch\" href=\"//evil.example/x.css\">")
        #expect(out.contains("rel=\"stylesheet\""))
        #expect(!out.lowercased().contains("dns-prefetch"))
    }

    @Test("every speculative rel token the spec names is stripped, individually")
    func everySpeculativeTokenStripped() {
        for token in ["dns-prefetch", "preconnect", "prerender", "prefetch", "preload", "modulepreload"] {
            let out = RawHTMLSanitizer.sanitize("<link rel=\"\(token)\" href=\"//evil.example\">")
            #expect(out.isEmpty, "rel=\(token) was not stripped: \(out)")
        }
    }

    @Test("a link with no rel at all is dropped (not a recognizable safe use)")
    func linkWithNoRelDropped() {
        #expect(RawHTMLSanitizer.sanitize("<link href=\"//evil.example\">") == "")
    }

    // MARK: - base, a, meta, img, form

    @Test("base href is always dropped, tag and all")
    func baseDropped() {
        #expect(RawHTMLSanitizer.sanitize("<base href=\"http://evil.example/\">") == "")
    }

    @Test("a href and ping are dropped, the element and its text stay")
    func anchorHrefAndPingDropped() {
        let out = RawHTMLSanitizer.sanitize("<a href=\"https://evil.example\" ping=\"https://evil.example/p\">click</a>")
        #expect(out == "<a>click</a>")
    }

    @Test("meta http-equiv is dropped entirely, refresh included")
    func metaHttpEquivDropped() {
        #expect(RawHTMLSanitizer.sanitize("<meta http-equiv=\"refresh\" content=\"0;url=http://evil.example\">") == "")
        #expect(RawHTMLSanitizer.sanitize("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src *\">") == "")
    }

    @Test("meta without http-equiv (charset, viewport-style name/content) passes through")
    func metaWithoutHttpEquivKept() {
        #expect(RawHTMLSanitizer.sanitize("<meta charset=\"utf-8\">") == "<meta charset=\"utf-8\">")
    }

    @Test("img src is kept only when it is a data: URL")
    func imgSrcDataOnly() {
        #expect(RawHTMLSanitizer.sanitize("<img src=\"http://evil.example/x.png\">") == "<img>")
        #expect(RawHTMLSanitizer.sanitize("<img src=\"data:image/gif;base64,AA==\">")
                == "<img src=\"data:image/gif;base64,AA==\">")
    }

    @Test("form action is dropped, the form stays")
    func formActionDropped() {
        #expect(RawHTMLSanitizer.sanitize("<form action=\"http://evil.example/submit\"></form>") == "<form></form>")
    }

    // MARK: - fixture of hint forms: real hostile spellings, not the canonical one

    @Test("hint forms fixture: casing, placement, multi-token, attribute order, whitespace variants")
    func hintFormsFixture() {
        let hostileForms = [
            "<LINK REL=\"DNS-PREFETCH\" HREF=\"//evil.example\">",
            "<Link Rel=\"Preconnect\" Href=\"//evil.example\">",
            "<link\n  rel = \"dns-prefetch\"\n  href = \"//evil.example\" >",
            "<link href=\"//evil.example\" rel=\"dns-prefetch\">",   // href before rel
            "<link rel='dns-prefetch' href='//evil.example'>",       // single-quoted
            "<link rel=dns-prefetch href=//evil.example>",           // unquoted value (bare token, no slashes issue here)
            "<link rel=\"  dns-prefetch   preconnect  \" href=\"//evil.example\">",   // extra whitespace, two speculative tokens
        ]
        for form in hostileForms {
            let out = RawHTMLSanitizer.sanitize(form)
            #expect(!out.lowercased().contains("evil.example"), "hostile form leaked a target: \(form) -> \(out)")
        }
    }

    @Test("a document mixing every hint form plus ordinary content sanitizes to only the ordinary content")
    func mixedDocumentFixture() {
        let html = """
        <html><head>
        <LINK REL=\"DNS-PREFETCH\" HREF=\"//a.evil.example\">
        <link rel="preconnect" href="//b.evil.example">
        <link rel = "prerender" href = "//c.evil.example" >
        <link rel='prefetch' href='//d.evil.example'>
        <link rel="preload" href="//e.evil.example">
        <link rel="modulepreload" href="//f.evil.example">
        <base href="http://g.evil.example/">
        <meta http-equiv="refresh" content="0;url=http://h.evil.example">
        </head><body>
        <p>hello, a real page</p>
        <a href="http://i.evil.example" ping="http://j.evil.example">a real link</a>
        </body></html>
        """
        let out = RawHTMLSanitizer.sanitize(html)
        #expect(!out.lowercased().contains("evil.example"))
        #expect(out.contains("hello, a real page"))
        #expect(out.contains("a real link"))
    }

    // MARK: - #915 review finding 1: rel splits on ASCII whitespace, not just space

    @Test("a tab, LF, FF or CR between rel tokens still splits them — a space-only split let the speculative token through")
    func relSplitsOnEveryASCIIWhitespaceCharacter() {
        for separator in ["\t", "\n", "\r", "\u{0C}", "\r\n"] {
            let out = RawHTMLSanitizer.sanitize("<link rel=\"foo\(separator)preconnect\" href=\"//evil.example\">")
            #expect(!out.lowercased().contains("preconnect"),
                    "separator \(separator.unicodeScalars.map(\.value)) did not split rel: \(out)")
        }
    }

    // MARK: - #915 review finding 2: a combining mark after a quote must not desync the parser

    @Test("a combining mark right after a closing quote does not let an attribute escape the allow-list")
    func combiningMarkAfterQuoteDoesNotBreakParsing() {
        // U+0301 (combining acute accent) right after the closing `"` — a Character-based
        // tokenizer treats `"` + U+0301 as one grapheme cluster that isn't `"`, so it kept
        // reading past the real end of the value. If that happened here, `onclick` would appear
        // as if it were a value inside `title`, rather than its own attribute to filter.
        let out = RawHTMLSanitizer.sanitize("<div title=\"a\"\u{301} onclick=\"evil()\" id=\"b\">hi</div>")
        #expect(!out.contains("onclick"), "the on* filter never saw onclick as its own attribute: \(out)")
    }

    @Test("a combining mark after a quote cannot smuggle a speculative rel past the allow-list")
    func combiningMarkCannotSmuggleSpeculativeRel() {
        let out = RawHTMLSanitizer.sanitize("<link href=\"//evil.example\"\u{301} rel=preconnect dummy=\" rel=\"stylesheet\">")
        #expect(!out.lowercased().contains("evil.example"), "a desynced parser let the preconnect link through: \(out)")
    }

    // MARK: - #915 review finding 3: channels that load with no speculative hint at all

    @Test("link href is kept only for a data: URL — an external stylesheet/icon href is dropped")
    func linkHrefDataOnly() {
        let out = RawHTMLSanitizer.sanitize("<link rel=\"stylesheet\" href=\"https://evil.example/x.css\">")
        #expect(!out.contains("evil.example"))
    }

    @Test("source srcset is dropped entirely, not value-checked")
    func sourceSrcsetDropped() {
        let out = RawHTMLSanitizer.sanitize("<source srcset=\"https://evil.example/x.png 1x\">")
        #expect(!out.contains("evil.example"))
    }

    @Test("style url() and image-set() to a non-fragment target are dropped; a same-document fragment is kept")
    func styleURLFunctionDropped() {
        let hostile = RawHTMLSanitizer.sanitize("<div style=\"background:url(https://evil.example/x.png)\">hi</div>")
        #expect(!hostile.contains("evil.example"))
        let imageSet = RawHTMLSanitizer.sanitize("<div style=\"background:image-set(url(https://evil.example/x.png) 1x)\">hi</div>")
        #expect(!imageSet.contains("evil.example"))
        let fragment = RawHTMLSanitizer.sanitize("<div style=\"clip-path:url(#clip)\">hi</div>")
        #expect(fragment.contains("url(#clip)"))
    }

    @Test("svg fill/stroke url() to a non-fragment target is dropped; a same-document fragment is kept")
    func svgFillStrokeURLFunctionDropped() {
        let hostile = RawHTMLSanitizer.sanitize("<path d=\"M0 0\" fill=\"url(https://evil.example/x.svg)\"></path>")
        #expect(!hostile.contains("evil.example"))
        let fragment = RawHTMLSanitizer.sanitize("<path d=\"M0 0\" fill=\"url(#gradient)\"></path>")
        #expect(fragment.contains("url(#gradient)"))
    }
}

// MARK: - Live oracle: preconnect through the SOCKS5h proxy (#904), mutation-checked

/// Dns-prefetch cannot be observed through the proxy (#904 review finding 1 — exactly why this
/// sanitizer exists instead of an observation). Preconnect can, so it is the oracle: a correct
/// stripper must drive it to zero, and a broken stripper must let it through, through the SAME
/// proxy instrument #904 built and verified reliable for this one hint type.
@MainActor
@Suite("RawHTMLSanitizer live oracle: preconnect through the proxy (#912)", .timeLimit(.minutes(1)))
struct RawHTMLSanitizerLiveOracleTests {
    private func socksProxyConfiguration(port: UInt16) -> ProxyConfiguration {
        ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    private func load(html: String, proxy: SOCKS5ProxyTestHelper) async throws {
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [socksProxyConfiguration(port: proxy.port)]
        config.websiteDataStore = store

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = SanitizerOracleNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: URL(string: "http://iris-sanitizer-oracle-base.invalid.example/"))
        await waiter.waitForFinish()
        try? await Task.sleep(for: .seconds(2))
    }

    @Test("sanitized preconnect never reaches the proxy")
    func sanitizedPreconnectReachesZero() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let hostile = "<html><head><link rel=\"preconnect\" href=\"//iris-sanitizer-oracle-preconnect.invalid.example\"></head><body>hi</body></html>"
        let sanitized = RawHTMLSanitizer.sanitize(hostile)
        try await load(html: sanitized, proxy: proxy)

        #expect(
            !proxy.recordedTargets.map(\.host).contains("iris-sanitizer-oracle-preconnect.invalid.example"),
            "a sanitized document still reached the proxy for its preconnect host"
        )
    }

    @Test("MUTATION CHECK: the same unsanitized document reaches the proxy — proves the oracle itself can observe a real preconnect")
    func unsanitizedPreconnectReachesTheProxy() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let hostile = "<html><head><link rel=\"preconnect\" href=\"//iris-sanitizer-oracle-preconnect-unsanitized.invalid.example\"></head><body>hi</body></html>"
        try await load(html: hostile, proxy: proxy)   // NOT run through the sanitizer

        #expect(
            proxy.recordedTargets.map(\.host).contains("iris-sanitizer-oracle-preconnect-unsanitized.invalid.example"),
            "the oracle itself never saw an unsanitized preconnect — a green result above would be vacuous"
        )
    }

    // MARK: - #915 review finding 4: live cases for findings 1 and 2, each with its own control

    @Test("a tab-split rel sanitizes to zero through the proxy")
    func tabSplitRelSanitizesToZero() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let hostile = "<html><head><link rel=\"foo\tpreconnect\" href=\"//iris-sanitizer-oracle-tabsplit.invalid.example\"></head><body>hi</body></html>"
        try await load(html: RawHTMLSanitizer.sanitize(hostile), proxy: proxy)

        #expect(!proxy.recordedTargets.map(\.host).contains("iris-sanitizer-oracle-tabsplit.invalid.example"))
    }

    @Test("MUTATION CHECK: the same tab-split rel, unsanitized, reaches the proxy")
    func tabSplitRelUnsanitizedReachesTheProxy() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let hostile = "<html><head><link rel=\"foo\tpreconnect\" href=\"//iris-sanitizer-oracle-tabsplit-unsanitized.invalid.example\"></head><body>hi</body></html>"
        try await load(html: hostile, proxy: proxy)   // NOT run through the sanitizer

        #expect(proxy.recordedTargets.map(\.host).contains("iris-sanitizer-oracle-tabsplit-unsanitized.invalid.example"),
                "the oracle itself never saw the unsanitized tab-split preconnect — a green result above would be vacuous")
    }

    @Test("a combining-mark-after-quote injection sanitizes to zero through the proxy")
    func combiningMarkInjectionSanitizesToZero() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let hostile = "<html><head><link href=\"//iris-sanitizer-oracle-combining.invalid.example\"\u{301} rel=preconnect dummy=\" rel=\"stylesheet\"></head><body>hi</body></html>"
        try await load(html: RawHTMLSanitizer.sanitize(hostile), proxy: proxy)

        #expect(!proxy.recordedTargets.map(\.host).contains("iris-sanitizer-oracle-combining.invalid.example"))
    }

    @Test("MUTATION CHECK: the same combining-mark-after-quote injection, unsanitized, reaches the proxy")
    func combiningMarkInjectionUnsanitizedReachesTheProxy() async throws {
        let proxy = try SOCKS5ProxyTestHelper(holdOpen: false)
        defer { proxy.close() }

        let hostile = "<html><head><link href=\"//iris-sanitizer-oracle-combining-unsanitized.invalid.example\"\u{301} rel=preconnect dummy=\" rel=\"stylesheet\"></head><body>hi</body></html>"
        try await load(html: hostile, proxy: proxy)   // NOT run through the sanitizer

        #expect(proxy.recordedTargets.map(\.host).contains("iris-sanitizer-oracle-combining-unsanitized.invalid.example"),
                "the oracle itself never saw the unsanitized combining-mark injection — a green result above would be vacuous")
    }
}

@MainActor
private final class SanitizerOracleNavigationWaiter: NSObject, WKNavigationDelegate {
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

    /// Bounded, not a bare `await withCheckedContinuation` (AGENTS.md #428/#435, the exact shape
    /// #904's own waiters document hanging on for real).
    func waitForFinish() async {
        if finished { return }
        let task = Task<Void, Never> { await withCheckedContinuation { self.continuation = $0 } }
        _ = try? await irisTests.value(of: task, within: 10)
    }
}
