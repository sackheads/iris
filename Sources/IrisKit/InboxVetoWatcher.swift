import Foundation
import AppKit

/// Drives the inbox's timed-veto check (#920 Task 4): once at start (a veto that came due while
/// Iris was not running), on a dispatch timer, and when the Mac wakes (the timer stops in sleep, so
/// a veto that came due meanwhile fires at the wake, not up to one interval later). The deadline
/// itself is a wall-clock time ("by 5pm"), a schedule, so the check compares `Date()`, not
/// `UptimeClock`; this only decides when to look. A dispatch timer, never `Task.sleep` (Invariant 4).
final class InboxVetoWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "iris.inbox.veto", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var observer: (center: NotificationCenter, token: NSObjectProtocol)?

    /// Idempotent: a second start replaces the first. `center` is injectable so a test never posts
    /// the real wake notification, which every other observer in the process would also see.
    func start(interval: TimeInterval = 30,
               center: NotificationCenter = NSWorkspace.shared.notificationCenter,
               evaluate: @escaping @Sendable () async -> Void) {
        stop()
        Task { await evaluate() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { Task { await evaluate() } }
        t.resume()
        let token = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            Task { await evaluate() }
        }
        lock.withLock { timer = t; observer = (center, token) }
    }

    func stop() {
        let (t, o) = lock.withLock { () -> (DispatchSourceTimer?, (center: NotificationCenter, token: NSObjectProtocol)?) in
            defer { timer = nil; observer = nil }
            return (timer, observer)
        }
        t?.cancel()
        if let o { o.center.removeObserver(o.token) }
    }

    deinit { stop() }
}
