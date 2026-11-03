import Testing
import Foundation
import WebKit
@testable import IrisKit

/// #896 phase 1: the scheme handler serves exactly `iris-view://doc`, and holds its document
/// itself rather than through a shared registry, so one window can never be asked for another's
/// page (spec section 1, rule 2).
@MainActor
@Suite("Viewer scheme handler (#896)")
struct ViewerSchemeHandlerTests {
    @Test("the document path returns 200 with the CSP header and the exact bytes")
    func documentPathServesTheDocument() {
        let body = "<html>one</html>"
        let handler = ViewerSchemeHandler(document: Data(body.utf8))
        let task = RecordingSchemeTask(url: ViewerConfiguration.documentURL)

        handler.webView(WKWebView(), start: task)

        #expect(task.response?.statusCode == 200)
        #expect(task.response?.value(forHTTPHeaderField: "Content-Security-Policy") == ViewerConfiguration.contentSecurityPolicy)
        #expect(task.response?.value(forHTTPHeaderField: "X-DNS-Prefetch-Control") == "off")
        #expect(task.receivedData == Data(body.utf8))
        #expect(task.finished)
        #expect(task.failedWithError == nil)
    }

    @Test("any other path gets a 404, never the document")
    func otherPathsGet404() {
        let handler = ViewerSchemeHandler(document: Data("secret".utf8))
        let other = URL(string: "iris-view://other")!
        let task = RecordingSchemeTask(url: other)

        handler.webView(WKWebView(), start: task)

        #expect(task.response?.statusCode == 404)
        #expect(task.response?.value(forHTTPHeaderField: "Content-Security-Policy") == nil)
        #expect(task.receivedData == nil || task.receivedData?.isEmpty == true)
        #expect(task.finished)
    }

    @Test("two windows, each with its own document, each asked for the other's path, never cross-serve")
    func twoWindowsDoNotShareARegistry() {
        let handlerA = ViewerSchemeHandler(document: Data("A's document".utf8))
        let handlerB = ViewerSchemeHandler(document: Data("B's document".utf8))

        let taskForA = RecordingSchemeTask(url: ViewerConfiguration.documentURL)
        let taskForB = RecordingSchemeTask(url: ViewerConfiguration.documentURL)

        handlerA.webView(WKWebView(), start: taskForA)
        handlerB.webView(WKWebView(), start: taskForB)

        #expect(taskForA.receivedData == Data("A's document".utf8))
        #expect(taskForB.receivedData == Data("B's document".utf8))
    }
}

/// `WKURLSchemeTask` is a protocol, so a test double can capture what the handler sends without a
/// real `WKWebView` round trip (mirrors the `CodeBlockPasteboard` seam in #894).
private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: HTTPURLResponse?
    private(set) var receivedData: Data?
    private(set) var finished = false
    private(set) var failedWithError: Error?

    init(url: URL) {
        self.request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) {
        self.response = response as? HTTPURLResponse
    }

    func didReceive(_ data: Data) {
        receivedData = (receivedData ?? Data()) + data
    }

    func didFinish() {
        finished = true
    }

    func didFailWithError(_ error: Error) {
        failedWithError = error
    }
}
