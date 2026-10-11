import Foundation

/// When Iris may post (D6 decision 7). Permission is asked the first time a notification would be
/// posted, never at launch, and at most once per process. "Denied", by the user or by MDM, is a
/// normal answer: nothing is posted, nothing is retried, and nobody is asked again. A later
/// "authorized" (the owner changed System Settings) is honoured at the next post. Pure apart from
/// its three closures, so the whole ladder is testable without `UNUserNotificationCenter`.
@MainActor
final class NotificationPermission {
    enum Status: Sendable { case notDetermined, authorized, denied }

    private let current: @MainActor () async -> Status
    private let request: @MainActor () async -> Bool
    private let deliver: @MainActor (PlannedNotification) async -> Void
    private let settled: @MainActor (PlannedNotification) -> Void
    private var asked = false
    private var asking = false
    private var held: [PlannedNotification] = []

    init(current: @escaping @MainActor () async -> Status,
         request: @escaping @MainActor () async -> Bool,
         deliver: @escaping @MainActor (PlannedNotification) async -> Void,
         settled: @escaping @MainActor (PlannedNotification) -> Void = { _ in }) {
        self.current = current
        self.request = request
        self.deliver = deliver
        self.settled = settled
    }

    /// Returns once `notification` is delivered or dropped, unless it is held behind the prompt:
    /// then the post that is asking delivers or drops it. Either way `settled` is called for it
    /// exactly once, when nothing more will happen to it (or when it is withdrawn while held).
    func submit(_ notification: PlannedNotification) async {
        if asking { held.append(notification); return }
        let status = await current()
        // Re-checked after the await: another post may have started the prompt meanwhile.
        if asking { held.append(notification); return }
        switch status {
        case .authorized:
            await deliver(notification)
            settled(notification)
        case .denied:
            settled(notification)
        case .notDetermined:
            guard !asked else { settled(notification); return }
            asked = true
            asking = true
            held.append(notification)
            let granted = await request()
            asking = false
            let waiting = held
            held = []
            for planned in waiting {
                if granted { await deliver(planned) }
                settled(planned)
            }
        }
    }

    /// An ask that went while the prompt was up must not be posted afterwards.
    func withdraw(identifiers: [String]) {
        let gone = held.filter { identifiers.contains($0.identifier) }
        held.removeAll { identifiers.contains($0.identifier) }
        gone.forEach(settled)
    }
}
