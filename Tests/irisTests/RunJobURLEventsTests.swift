import Testing
import AppKit
@testable import IrisKit

/// D2 (owner ruling C2): run-job links arrive as a `kAEGetURL` Apple Event, caught by a handler
/// installed in `applicationWillFinishLaunching`, never by SwiftUI, which opened a window per link.
@MainActor
@Suite("Run-job URL events (D6)")
struct RunJobURLEventsTests {
    private func event(_ text: String?) -> NSAppleEventDescriptor {
        let e = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                       targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
        if let text { e.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyDirectObject)) }
        return e
    }

    @Test("the link is the event's direct object")
    func urlFromEvent() {
        #expect(RunJobURLEvents.url(from: event("iris-dev://run-job/abc")) == URL(string: "iris-dev://run-job/abc"))
    }

    @Test("an event with no direct object, or one no URL can be made of, is nil")
    func noURL() {
        #expect(RunJobURLEvents.url(from: event(nil)) == nil)
        #expect(RunJobURLEvents.url(from: event("")) == nil)
    }

    @Test("the handler hands the link over, and only that")
    func handlerDelivers() {
        var got: [URL?] = []
        let handler = RunJobURLEvents { got.append($0) }
        handler.handleGetURL(event("iris-dev://run-job/abc"), withReply: NSAppleEventDescriptor.null())
        handler.handleGetURL(event(nil), withReply: NSAppleEventDescriptor.null())
        #expect(got == [URL(string: "iris-dev://run-job/abc"), nil])
    }

    /// Only the refusing half: installing for an `.app` would set the process-wide Apple Event
    /// handler under every other suite. `SurfaceInstall.isAppBundle`'s own tests cover the rest.
    @Test("outside a real .app nothing is installed (decision 8, the notifications predicate)")
    func appBundleOnly() {
        #expect(RunJobURLEvents.installForApp(bundleURL: URL(fileURLWithPath: "/Users/x/src/iris/.build/debug")) == nil)
        #expect(RunJobURLEvents.installForApp(bundleURL: Bundle.main.bundleURL) == nil, "a test runner is not an app")
    }

    @Test("no URL file logs anything: a log line would keep a live token")
    func nothingLogs() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/IrisKit")
        let banned = try Regex(#"\b(print|debugPrint|NSLog|os_log|dump|fputs)\(|\bLogger\(|FileHandle\.standardError"#)
        for file in ["RunJobURLEvents.swift", "RunJobURLIntake.swift", "RunJobURLHandling.swift",
                     "RunJobURL.swift", "LaunchLock.swift", "URLTriggerToken.swift", "URLTriggerLinkSheet.swift",
                     "LaunchGate.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(text.firstMatch(of: banned) == nil, "\(file) logs")
        }
    }
}
