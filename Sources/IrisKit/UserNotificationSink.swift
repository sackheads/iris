import Foundation
import UserNotifications

/// The notification center as `UserNotificationSink` uses it, in Iris's own types, so a test can
/// stand in for it without touching `UNUserNotificationCenter`.
@MainActor
protocol NotificationCenterClient: AnyObject {
    func authorizationStatus() async -> NotificationPermission.Status
    func requestAuthorization() async -> Bool
    func register(categories: [NotificationPolicy.CategorySpec])
    func add(_ notification: PlannedNotification) async throws
    /// Removes both pending and delivered requests.
    func remove(identifiers: [String])
    /// Where a tap on a delivered banner goes, already reduced to strings.
    var onResponse: (@MainActor (NotificationResponse) -> Void)? { get set }
}

/// The one file that touches `UserNotifications` (D6 decisions 7 and 8). Built only by
/// `SurfaceInstall.installNotifications`, after the `.app` bundle check:
/// `UNUserNotificationCenter.current()` raises in a process without one. The system client is
/// the center's delegate from `applicationWillFinishLaunching` (`SurfaceInstall.installNotificationDelegate`),
/// before the store may be open, so a click that cold-launches the app is still delivered, even
/// while it waits for a `--run-job` (#463). This sink reuses that one client.
@MainActor
final class UserNotificationSink: NotificationSink {
    private let center: any NotificationCenterClient
    private var permission: NotificationPermission?
    /// Posts not yet settled with the center, counted per id. A withdraw empties an id's entry,
    /// which tells a post still on its way not to add, or to remove what its add just put up.
    /// This assumes an id is never re-posted after it is withdrawn: ids are run and ask UUIDs,
    /// each posted once. A re-post racing an older post's add could otherwise be removed by it.
    private var unsettled: [String: Int] = [:]
    var unsettledCountForTesting: Int { unsettled.count }

    convenience init(state: AppState) {
        // A free lock opens the store in `IrisApp.init`, before will-finish: the client is made
        // here then, with the same gate route, and will-finish reuses it.
        self.init(state: state, center: SurfaceInstall.notificationDelegate())
    }

    init(state: AppState, center: any NotificationCenterClient) {
        self.center = center
        permission = NotificationPermission(
            current: { await center.authorizationStatus() },
            request: { await center.requestAuthorization() },
            deliver: { [weak self] in await self?.deliver($0) },
            settled: { [weak self] in self?.settle($0.identifier) })
        center.register(categories: NotificationPolicy.categories)
        center.onResponse = { [weak state] in _ = state?.handleNotificationResponse($0) }
    }

    func post(_ notification: PlannedNotification) {
        submit(notification)
    }

    /// `post`, returning the work so a test can await it.
    @discardableResult
    func submit(_ notification: PlannedNotification) -> Task<Void, Never> {
        let id = notification.identifier
        unsettled[id, default: 0] += 1
        return Task { [weak self] in await self?.permission?.submit(notification) }
    }

    func withdraw(identifiers: [String]) {
        permission?.withdraw(identifiers: identifiers)
        for id in identifiers { unsettled[id] = nil }
        center.remove(identifiers: identifiers)
    }

    private func settle(_ id: String) {
        guard let count = unsettled[id] else { return }
        unsettled[id] = count > 1 ? count - 1 : nil
    }

    private func deliver(_ planned: PlannedNotification) async {
        let id = planned.identifier
        guard unsettled[id] != nil else { return }   // withdrawn before it reached the center
        do {
            try await center.add(planned)
        } catch {
            print("[Notifications] could not post \(id): \(error)")
        }
        // Withdrawn while the add was in flight: its remove ran before the request existed.
        if unsettled[id] == nil { center.remove(identifiers: [id]) }
    }

    nonisolated static func content(for planned: PlannedNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = planned.title
        content.body = planned.body
        content.categoryIdentifier = planned.categoryId
        content.userInfo = planned.userInfo
        // `.timeSensitive` needs an entitlement this app does not have (decision 7).
        content.interruptionLevel = .active
        return content
    }

    /// The policy's categories, action for action, with no custom dismiss action: swiping a
    /// banner away acknowledges nothing.
    static func categories(_ specs: [NotificationPolicy.CategorySpec]) -> Set<UNNotificationCategory> {
        Set(specs.map { spec in
            UNNotificationCategory(identifier: spec.id, actions: spec.actions.map { action in
                var options: UNNotificationActionOptions = []
                if action.destructive { options.insert(.destructive) }
                if action.foreground { options.insert(.foreground) }
                if action.authenticationRequired { options.insert(.authenticationRequired) }
                return UNNotificationAction(identifier: action.id, title: action.title, options: options)
            }, intentIdentifiers: [], options: [])
        })
    }

    /// A click on the banner itself is Open. Every other id passes through, and
    /// `handleNotificationResponse` ignores any it does not know.
    nonisolated static func actionId(for raw: String) -> String {
        raw == UNNotificationDefaultActionIdentifier ? NotificationPolicy.Action.open : raw
    }
}

/// The real center. `UNUserNotificationCenter` is not `Sendable`, so it is never stored or
/// captured across isolation: each call asks `.current()` itself, and the async ones do so from
/// a nonisolated helper.
@MainActor
final class SystemNotificationCenter: NSObject, NotificationCenterClient, UNUserNotificationCenterDelegate {
    /// The one delegate, from will-finish. The center does not retain its delegate.
    private(set) static var shared: SystemNotificationCenter?

    var onResponse: (@MainActor (NotificationResponse) -> Void)?
    /// Where a click goes first, when set: `LaunchGate`, which holds it until Iris is open
    /// (#463). Touches no `AppState`.
    private var route: (@MainActor (NotificationResponse) -> Void)?
    /// Whether a banner may be shown: not while Iris waits, since nothing it names can open.
    private var presenting: @MainActor () -> Bool = { true }

    /// Private: `installEarly` is the only way in, so there is never a second delegate.
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// The one delegate: built on the first call, returned on every later one. Touches no
    /// `AppState`, so it can run before anything has built one.
    @discardableResult
    static func installEarly(route: @escaping @MainActor (NotificationResponse) -> Void,
                             presenting: @escaping @MainActor () -> Bool) -> SystemNotificationCenter {
        if let shared { return shared }
        let center = SystemNotificationCenter()
        center.route = route
        center.presenting = presenting
        shared = center
        return center
    }

    func authorizationStatus() async -> NotificationPermission.Status { await Self.currentStatus() }

    func requestAuthorization() async -> Bool { await Self.requestPermission() }

    func register(categories: [NotificationPolicy.CategorySpec]) {
        UNUserNotificationCenter.current().setNotificationCategories(UserNotificationSink.categories(categories))
    }

    func add(_ notification: PlannedNotification) async throws { try await Self.add(notification) }

    func remove(identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private nonisolated static func add(_ planned: PlannedNotification) async throws {
        let request = UNNotificationRequest(identifier: planned.identifier,
                                            content: UserNotificationSink.content(for: planned), trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    private nonisolated static func currentStatus() async -> NotificationPermission.Status {
        // `.ephemeral` is iOS-only (`UNNotificationSettings.h`: unavailable on macOS).
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    private nonisolated static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        // Reduced to strings here, off the main actor, so nothing non-Sendable crosses the hop.
        let actionId = UserNotificationSink.actionId(for: response.actionIdentifier)
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let reply = NotificationResponse(actionId: actionId, userInfo: info)
        await MainActor.run {
            if let route = self.route { route(reply) } else { self.onResponse?(reply) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The policy already decided whether a banner is worth showing; show what it posted.
        // While Iris waits for the store nothing it posted can be acted on, so show nothing.
        await MainActor.run { self.presenting() } ? [.banner, .list] : []
    }
}
