import Testing
import Foundation
import WebKit
@testable import IrisKit

/// #896 phase 1, spec section 6: a document carrying every subresource channel a hostile page
/// could try (`<img>`, `<link rel=stylesheet>`, `<form>`, `<meta refresh>`, CSS `url()` and
/// `@import`) all pointed at a loopback listener, loaded as the one trusted main-frame URL. If the
/// content rule list, the CSP and the navigation policy are doing their job together, the
/// listener accepts nothing. This never navigates the main frame anywhere but
/// `ViewerConfiguration.documentURL`, unlike a scheme-table test driving real top-level navigation
/// to an untrusted URL would — see the note in `ViewerContentRulesTests` for why that shape is
/// unsafe to write at all (it popped a LaunchServices dialog during this PR's own development).
@MainActor
@Suite("Viewer: zero connections from a hostile document (#896)", .timeLimit(.minutes(1)))
struct ViewerZeroConnectionsTests {
    @Test("a hostile document loaded as the trusted document opens zero connections to the loopback listener")
    func zeroConnections() async throws {
        let listener = try ConnectionCountingServer()
        defer { listener.close() }

        let html = """
        <html><head>
        <link rel="stylesheet" href="http://127.0.0.1:\(listener.port)/link.css">
        <meta http-equiv="refresh" content="0;url=http://127.0.0.1:\(listener.port)/refresh">
        <style>
        body { background: url(http://127.0.0.1:\(listener.port)/css-url); }
        @import url(http://127.0.0.1:\(listener.port)/import.css);
        </style>
        </head><body>
        <img src="http://127.0.0.1:\(listener.port)/img.png">
        <form action="http://127.0.0.1:\(listener.port)/form" method="post" id="f"></form>
        </body></html>
        """

        let id = "iris-view-test-\(UUID().uuidString)"
        let list = try await ViewerContentRules.compile(identifier: id)
        defer { WKContentRuleListStore.default()!.removeContentRuleList(forIdentifier: id) { _ in } }

        let handler = ViewerSchemeHandler(document: Data(html.utf8))
        let config = ViewerConfiguration.build(schemeHandler: handler)
        config.userContentController.add(list)

        let webView = WKWebView(frame: .zero, configuration: config)
        let waiter = TrustedOnlyNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: ViewerConfiguration.documentURL))
        await waiter.waitForFinish()

        // The meta refresh fires after load; give every channel, including it, a real window to
        // reach the loopback listener before asserting none did.
        try? await Task.sleep(for: .seconds(1))

        #expect(listener.acceptedCount == 0, "the loopback listener accepted a connection the viewer should have blocked")
    }
}

/// Only `ViewerConfiguration.documentURL` is ever allowed — see the note in `ViewerContentRulesTests`
/// on why a test must never let a real `WKWebView` attempt top-level navigation to anything else.
@MainActor
private final class TrustedOnlyNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let isAllowed = navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url == ViewerConfiguration.documentURL
        decisionHandler(isAllowed ? .allow : .cancel)
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

/// A TCP listener on loopback that counts connections and otherwise does nothing — modeled on
/// `NeverRespondingServer` (`ToolExecutorSearchWebTimeoutTests.swift`), but this test only needs
/// the count, not to hold a connection open.
/// Not `private`: reused by `ViewerDocumentInitiatedNavigationTests` for the same kind of check.
final class ConnectionCountingServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var count = 0
    private var stopped = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard listen(fd, 4) == 0 else { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        self.listenFD = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        startAccepting()
    }

    var acceptedCount: Int { lock.withLock { count } }

    private func startAccepting() {
        let thread = Thread { [self] in
            while true {
                let client = accept(self.listenFD, nil, nil)
                if client < 0 { return }
                self.lock.lock()
                if self.stopped { self.lock.unlock(); Darwin.close(client); return }
                self.count += 1
                self.lock.unlock()
                Darwin.close(client)
            }
        }
        thread.name = "iris-test.connection-counting-server"
        thread.start()
    }

    func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(listenFD)
    }
}
