import AppKit

/// The system's Reduce Motion setting, as the ambient animations read it (#538): the spectrum
/// line, the welcome glow and the typing dots. Injected, so a test flips one of its own rather
/// than reading, or depending on, the Mac's.
@MainActor
final class ReduceMotion {
    static let system = ReduceMotion(read: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
                                     center: NSWorkspace.shared.notificationCenter,
                                     name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)

    private let read: () -> Bool
    private let center: NotificationCenter
    private let name: Notification.Name

    init(read: @escaping () -> Bool, center: NotificationCenter, name: Notification.Name) {
        self.read = read
        self.center = center
        self.name = name
    }

    var isOn: Bool { read() }

    /// Calls `change` whenever the setting may have changed, until the returned token is passed
    /// to `stopObserving`.
    func observe(_ change: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { change() }
        }
    }

    func stopObserving(_ token: NSObjectProtocol) { center.removeObserver(token) }
}
