import AppKit
import Network
import SwiftUI
import WebKit

/// #896 PR 2: a model-authored document, shown in its own window, opened only by a person's click
/// on the fence's "Open in viewer" chip (spec section 1 rule 6, section 2). Not persisted (no new
/// `Codable` field — Invariant 1 has nothing to protect), not restored at launch, one document per
/// window, released when the window closes (spec section 4). See `ViewerConfiguration` (PR 1) for
/// the script/network block every window in this file relies on, and
/// docs/specs/2026-11-02-webkit-viewer.md for the full threat model.
struct ViewerDocument: Equatable {
    /// 1 MB of raw document bytes (spec decision 1): a code constant, not a setting.
    static let byteCap = 1_000_000

    let conversationId: UUID
    let messageId: UUID
    let html: Data

    init(conversationId: UUID, messageId: UUID, content: String) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.html = Data(content.utf8)
    }

    var isOverCap: Bool { html.count > Self.byteCap }
}

/// Whether a fenced code block offers the chip: a pure function so #896's tripwire ("a streaming
/// block never gets a chip, because an open fence is not a document yet") is a table test with no
/// view rendered (spec section 6).
enum ViewerChipPolicy {
    static func shouldOffer(language: String?, isStreaming: Bool) -> Bool {
        guard !isStreaming, let language else { return false }
        return language.lowercased() == "html"
    }
}

/// Gates whether the viewer is reachable at all, independent of language/streaming. A code
/// constant, not a `Settings` toggle: the spec's DNS zero-lookup result was a ship blocker ("the
/// window does not ship unless that shows zero lookups") — PR 2 landed the window, chip and
/// banner with the chip off; #904 then verified zero lookups with a SOCKS5h "resolver we control"
/// (`SOCKS5ProxyTestHelper`), both headless (`ViewerZeroLookupTests`) and in a real, on-screen
/// window under the gui-test-lease (`ViewerGUIZeroLookupTests` — PR 1 found `decidePolicyFor`
/// never fires offscreen, and the same gap could apply to WebKit's speculative-loading heuristics,
/// so an offscreen-only result would not have been trustworthy here). Both came back clean: every
/// hostname a hostile document's dns-prefetch/preconnect/subresource channels tried stayed at
/// zero, against a proxy a positive control confirmed does intercept a real, unblocked network
/// load. This flips to `true` on that green result.
enum ViewerFeatureGate {
    static let isEnabled = true
}

/// Opens one window per document, AppKit-managed rather than a SwiftUI `Scene`: a `WindowGroup`
/// opts into state restoration, and a model-authored page must never reappear at launch without a
/// click (spec section 2, "An open window is not restored at launch"). Multiple windows may be
/// open at once, no cap in v1 (spec decision 2); each is independent and releases its view (and the
/// WebContent process behind it) when it closes.
@MainActor
final class ViewerWindowController: NSObject, NSWindowDelegate {
    /// Keeps each controller alive only as long as its window is open — nothing else holds a
    /// reference, since `NSWindow`'s own `delegate` is weak.
    private static var openControllers: [ObjectIdentifier: ViewerWindowController] = [:]

    private var window: NSWindow?

    static func open(document: ViewerDocument, conversationTitle: String, isTainted: Bool) {
        let controller = ViewerWindowController()
        controller.show(document: document, conversationTitle: conversationTitle, isTainted: isTainted)
        openControllers[ObjectIdentifier(controller)] = controller
    }

    /// For a test that needs the window itself (the live `decidePolicyFor` acceptance pass):
    /// returns it without stashing a second strong reference beyond what showing already keeps.
    /// `proxyConfigurations` is a test-only seam (#904's live zero-lookup pass needs a real,
    /// on-screen window, not an offscreen one, to trust the result the same way PR 1 found
    /// `decidePolicyFor` itself needed one) — production code never calls this overload with one.
    @discardableResult
    static func openForTesting(
        document: ViewerDocument,
        conversationTitle: String = "",
        isTainted: Bool,
        proxyConfigurations: [ProxyConfiguration]? = nil
    ) -> NSWindow {
        let controller = ViewerWindowController()
        controller.show(document: document, conversationTitle: conversationTitle, isTainted: isTainted, proxyConfigurations: proxyConfigurations)
        openControllers[ObjectIdentifier(controller)] = controller
        return controller.window!
    }

    private func show(document: ViewerDocument, conversationTitle: String, isTainted: Bool, proxyConfigurations: [ProxyConfiguration]? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // Carries the conversation's title (spec section 2), not a bare constant.
        window.title = conversationTitle.isEmpty ? "Viewer" : "\(conversationTitle) — Viewer"
        // Released on close (spec section 4): nothing else should reach for it afterward.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ViewerWindowView(document: document, isTainted: isTainted, proxyConfigurations: proxyConfigurations))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers[ObjectIdentifier(self)] = nil
    }
}

/// The window's content: the banner first, always visible and outside the web view (spec section 1
/// rule 5 — a hostile page cannot cover or move it), then either the refusal message (over the
/// byte cap) or the web view itself. Never truncates the document (spec section 2).
struct ViewerWindowView: View {
    let document: ViewerDocument
    let isTainted: Bool
    var proxyConfigurations: [ProxyConfiguration]? = nil

    var body: some View {
        VStack(spacing: 0) {
            ViewerBannerView(isTainted: isTainted)
            Divider()
            if document.isOverCap {
                ViewerTooLargeView(byteCount: document.html.count)
            } else {
                ViewerWebView(document: document, proxyConfigurations: proxyConfigurations)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// Drawn in Swift, outside the web view, so a page cannot cover it, move it, or draw over it (spec
/// section 1 rule 5). The second sentence names the same taint #813 already tracks on the
/// conversation (`hasUntrustedToolOutput`): the viewer reads nothing back from the page, but the
/// document it is showing may itself have come from something untrusted the model read earlier.
///
/// Says exactly "cannot run" and "no network connections" — not "nothing here can send anything",
/// which would misstate drag-out: WebKit's drag source is private machinery this view cannot
/// reach (confirmed; see `ClosedSurfaceWebView`'s doc comment), so Iris does not claim to block
/// it. A drag of visible, inert content is the same risk class as the Copy button this view
/// already offers; the property that matters — no network egress — is what the banner claims.
struct ViewerBannerView: View {
    let isTainted: Bool

    /// The exact wording is a pure function (#905 review finding 4), since nothing here could
    /// otherwise be pinned by a test without a real window-server capture — which this session
    /// could not take (see the PR body: these test-process windows never registered with
    /// `CGWindowList` or System Events, so there was nothing to screenshot).
    static let alwaysLine = "Model-generated content. It cannot run, and makes no network connections."
    static let taintedLine = "This conversation has read untrusted content."

    static func lines(isTainted: Bool) -> [String] {
        isTainted ? [alwaysLine, taintedLine] : [alwaysLine]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.alwaysLine)
                .font(.caption)
            if isTainted {
                Text(Self.taintedLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// What a document over `ViewerDocument.byteCap` shows instead of a render (spec section 2: "the
/// HTML is never truncated; a cut in the middle of a tag is worse than a refusal").
struct ViewerTooLargeView: View {
    let byteCount: Int

    var body: some View {
        VStack {
            Spacer()
            Text(Self.message(byteCount: byteCount))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func message(byteCount: Int) -> String {
        "content too large to display (\(byteCount / 1000) KB > 1 MB)"
    }
}

/// Hosts the real `WKWebView`. Builds `ViewerConfiguration` fresh, compiles the deny-all content
/// rule list and adds it before ever loading — if it fails to compile, the view refuses to load
/// and shows the error instead (spec section 1 rule 3) — then restricts the surfaces
/// `ViewerConfiguration` itself does not reach: the context menu (Copy only), drag-out, and
/// `isInspectable`.
struct ViewerWebView: NSViewRepresentable {
    let document: ViewerDocument
    var proxyConfigurations: [ProxyConfiguration]? = nil

    func makeNSView(context: Context) -> ViewerWebViewHost {
        ViewerWebViewHost(document: document, proxyConfigurations: proxyConfigurations)
    }

    func updateNSView(_ nsView: ViewerWebViewHost, context: Context) {}
}

@MainActor
final class ViewerWebViewHost: NSView {
    let navigationDelegate = ViewerNavigationDelegate()
    private(set) var webView: ClosedSurfaceWebView?
    private var loadTask: Task<Void, Never>?

    init(document: ViewerDocument, proxyConfigurations: [ProxyConfiguration]? = nil) {
        super.init(frame: .zero)
        loadTask = Task { [weak self] in await self?.load(document: document, proxyConfigurations: proxyConfigurations) }
    }

    required init?(coder: NSCoder) { fatalError("ViewerWebViewHost is created in code only") }

    deinit { loadTask?.cancel() }

    private func load(document: ViewerDocument, proxyConfigurations: [ProxyConfiguration]? = nil) async {
        let handler = ViewerSchemeHandler(document: document.html)
        let config = ViewerConfiguration.build(schemeHandler: handler, proxyConfigurations: proxyConfigurations)
        do {
            let list = try await ViewerContentRules.compile()
            config.userContentController.add(list)
        } catch {
            showRefusal()
            return
        }
        guard !Task.isCancelled else { return }

        let webView = ClosedSurfaceWebView(frame: bounds, configuration: config)
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = navigationDelegate
        webView.isInspectable = false
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        self.webView = webView
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
    }

    /// The rule list failed to compile: the view never loads without it (spec section 1 rule 3).
    private func showRefusal() {
        let label = NSTextField(labelWithString: "This document could not be shown safely and was not loaded.")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }
}

/// Closes the surfaces `ViewerConfiguration` does not reach (spec section 1 rule 3): the context
/// menu is cut down to its own "Copy" items (filtering WebKit's default menu, not guessing its
/// internal action names). Drag-in of a file is already covered by the navigation policy, which
/// cancels any load that isn't the one trusted document.
///
/// Drag-OUT of an image or link has no code-level block: WebKit's drag source is private
/// machinery inside the web view, not something `NSView`'s own `NSDraggingSource` override point
/// reaches (confirmed: `draggingSession(_:sourceOperationMaskFor:)` never overrides anything on
/// `WKWebView`, so a subclass override here would be dead code, not a fix). Planner ruling (#896
/// PR 2): accepted rather than blocking on it — dragging visible, inert content out is the same
/// risk class as the Copy button this view already offers, and the property that actually
/// matters (no network egress) is covered independently by the content rule list, the CSP and
/// #904's DNS verification. The banner is worded to match: it never claims Iris prevents drag-out.
/// The GUI pass records whether a drag attempt actually leaves the window, as evidence either way.
final class ClosedSurfaceWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? {
        super.menu(for: event).flatMap(Self.copyOnly)
    }

    /// Pure, so a test can assert the filter itself without a live `NSMenu` from a real context
    /// menu event (which needs a window): keeps only items titled "Copy" (WebKit's own, not
    /// guessed), and returns nil — no menu at all — when the default menu had none.
    static func copyOnly(_ defaultMenu: NSMenu) -> NSMenu? {
        let copyItems = defaultMenu.items.filter { $0.title.caseInsensitiveCompare("Copy") == .orderedSame }
        guard !copyItems.isEmpty else { return nil }
        let menu = NSMenu()
        // An `NSMenuItem` can only ever belong to one menu at a time (AppKit throws if it's
        // still in `defaultMenu` when added here) — remove it from the default menu first, which
        // is about to be discarded anyway.
        for item in copyItems {
            defaultMenu.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }
}

/// Allows exactly the one navigation `ViewerNavigationPolicy` allows, never opens a second web
/// view (`createWebViewWith`, e.g. `window.open` or a `target=_blank` link — spec section 1 rule
/// 3), and never lets a response become a download (defence in depth: nothing but the trusted
/// document's `text/html` response is ever allowed to reach this far, but a response-level refusal
/// means no download can start even if a future change loosened the request-level one).
@MainActor
final class ViewerNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var hasAllowedOnce = false
    /// How many times `decidePolicyFor` actually ran — only observable proof, in a live window,
    /// that the delegate engaged at all (PR 1 found it never fires for an offscreen web view).
    private(set) var decisionCount = 0
    /// The pure policy, injectable only for the mutation-check suite (`ViewerGUINavigationTests`):
    /// substituting an always-`.allow` function there exercises this exact class — the production
    /// `decisionCount`/`hasAllowedOnce` bookkeeping included — rather than a parallel stub
    /// delegate that proves nothing about what ships (#905 review finding 1).
    private let decide: (URL, Bool, Bool) -> ViewerNavigationPolicy.Decision

    init(decide: @escaping (URL, Bool, Bool) -> ViewerNavigationPolicy.Decision = ViewerNavigationPolicy.decide) {
        self.decide = decide
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        decisionCount += 1
        // A request with no URL cancels outright rather than substituting the trusted URL
        // (#905 review finding 2): the substitution made an unreadable request count as the
        // trusted one — allowed if it was first, and otherwise burning `hasAllowedOnce` so the
        // real load that follows gets cancelled instead.
        guard let url = navigationAction.request.url else { return .cancel }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        let decision = decide(url, isMainFrame, hasAllowedOnce)
        // Flips on ALLOW, not on `didFinish`: a fast `<meta http-equiv="refresh">` can fire its
        // second navigation before the first one finishes loading, and a flag set only at
        // `didFinish` would still read "not loaded yet" for that race (#896 PR 2 review).
        if decision == .allow { hasAllowedOnce = true }
        return decision == .allow ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.response.url == ViewerConfiguration.documentURL ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    /// Nothing should ever reach here — the response-level policy above only ever allows the
    /// trusted document's own response, never `.download` — but WebKit can decide a response is a
    /// download on its own for some content types regardless of the policy returned, so this is
    /// defence in depth, not the primary gate (spec section 1 rule 3: "the download delegate
    /// cancels every download").
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel()
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel()
    }
}
