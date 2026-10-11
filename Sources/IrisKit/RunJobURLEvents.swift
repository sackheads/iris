import AppKit

/// D2 (owner ruling, variant C2): run-job links arrive as a `kAEGetURL` Apple Event, caught here
/// rather than by SwiftUI. Task 24's spike: with `application(_:open:)` the `WindowGroup` opened
/// a chat window on every link, and `.handlesExternalEvents(matching: [])` sent the link to the
/// Diagnostics window instead. A handler installed in `applicationWillFinishLaunching` opens no
/// window at all, so a link that launches Iris starts it windowless.
///
/// Nothing here logs: the link carries a live token, and a log would keep it (plan note 17).
@MainActor
final class RunJobURLEvents: NSObject {
    private let deliver: @MainActor (URL?) -> Void

    init(deliver: @escaping @MainActor (URL?) -> Void) {
        self.deliver = deliver
    }

    /// The app's handler, delivering to `AppState.shared`. Here rather than in `AppDelegate` so the
    /// closure that carries the raw link sits in a file the no-logging test reads. A real `.app`
    /// only (decision 8), by the predicate notifications use: the bare binary registers no scheme,
    /// so nothing routes a link to it, and it installs nothing it cannot use.
    static func installForApp(bundleURL: URL = Bundle.main.bundleURL) -> RunJobURLEvents? {
        guard SurfaceInstall.isAppBundle(bundleURL) else { return nil }
        let events = RunJobURLEvents { url in AppState.shared.receiveRunJobURL(url) }
        events.install()
        return events
    }

    func install(on manager: NSAppleEventManager = .shared()) {
        manager.setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// The link in the event's direct object, or nil when there is none a URL can be made of.
    static func url(from event: NSAppleEventDescriptor) -> URL? {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return nil }
        return URL(string: text)
    }

    /// AppKit dispatches Apple Events on the main thread, as it does the launch callbacks; the
    /// class is main-actor isolated, so Swift checks that at the `@objc` entry.
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        deliver(Self.url(from: event))
    }
}
