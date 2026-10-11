import Testing
import Foundation
// Only to read back the translated categories and content; nothing here calls the center.
import UserNotifications
@testable import IrisKit

/// D6 decisions 7 and 8: permission is asked once, at the first post, and "denied" is a normal
/// answer; only a real `.app` bundle installs a sink; one file touches `UserNotifications`.
@MainActor
@Suite("Notification install (D6)", .timeLimit(.minutes(1)))
struct NotificationInstallTests {
    private final class Calls {
        var status: NotificationPermission.Status = .notDetermined
        var requests = 0
        var grant = true
        var delivered: [String] = []
        var held: CheckedContinuation<Void, Never>?
        var holdRequest = false
        /// The prompt was closed unanswered: the request returns false and nothing is decided.
        var dismissPrompt = false
    }

    /// The notification center as `UserNotificationSink` sees it, with an `add` that can be held.
    @MainActor
    private final class FakeCenter: NotificationCenterClient {
        var status: NotificationPermission.Status = .authorized
        var registered: [NotificationPolicy.CategorySpec]?
        var added: [String] = []
        var removed: [String] = []
        var holdAdd = false
        var heldAdd: CheckedContinuation<Void, Never>?
        var onResponse: (@MainActor (NotificationResponse) -> Void)?

        var grant = true
        var holdRequest = false
        var heldRequest: CheckedContinuation<Void, Never>?

        func authorizationStatus() async -> NotificationPermission.Status { status }
        func requestAuthorization() async -> Bool {
            if holdRequest { await withCheckedContinuation { heldRequest = $0 } }
            status = grant ? .authorized : .denied
            return grant
        }
        func register(categories: [NotificationPolicy.CategorySpec]) { registered = categories }
        func add(_ notification: PlannedNotification) async throws {
            if holdAdd { await withCheckedContinuation { heldAdd = $0 } }
            added.append(notification.identifier)
        }
        func remove(identifiers: [String]) { removed += identifiers }
    }

    @MainActor
    private final class FakeSink: NotificationSink {
        var posted: [PlannedNotification] = []
        func post(_ notification: PlannedNotification) { posted.append(notification) }
        func withdraw(identifiers: [String]) {}
    }

    private func gate(_ calls: Calls) -> NotificationPermission {
        NotificationPermission(
            current: { calls.status },
            request: {
                calls.requests += 1
                if calls.holdRequest { await withCheckedContinuation { calls.held = $0 } }
                calls.status = calls.grant ? .authorized : (calls.dismissPrompt ? .notDetermined : .denied)
                return calls.grant
            },
            deliver: { calls.delivered.append($0.identifier) })
    }

    private func note(_ id: String) -> PlannedNotification {
        PlannedNotification(identifier: id, kind: .jobNeedsYou, title: NotificationPolicy.jobTitle,
                            body: "Job “x” is blocked on “y”.", categoryId: NotificationPolicy.Category.blockedCard,
                            userInfo: [:])
    }

    private func makeApp() throws -> (ConversationStore, AppState) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        return (store, app)
    }

    @Test("the first post asks, once; later posts are delivered without asking")
    func asksOnce() async {
        let calls = Calls(), permission = gate(calls)
        await permission.submit(note("a"))
        await permission.submit(note("b"))
        #expect(calls.requests == 1)
        #expect(calls.delivered == ["a", "b"])
    }

    @Test("denied, by the user or by MDM, posts nothing and never asks again")
    func deniedNeverAsksAgain() async {
        let calls = Calls(), permission = gate(calls)
        calls.grant = false
        for id in ["a", "b", "c"] { await permission.submit(note(id)) }
        #expect(calls.requests == 1)
        #expect(calls.delivered.isEmpty)

        calls.status = .authorized   // the owner turned it on in System Settings
        await permission.submit(note("d"))
        #expect(calls.delivered == ["d"])
        #expect(calls.requests == 1)
    }

    @Test("a prompt closed unanswered stays undecided, and is still never asked again")
    func dismissedPromptNeverAsksAgain() async {
        let calls = Calls(), permission = gate(calls)
        calls.grant = false
        calls.dismissPrompt = true
        for id in ["a", "b", "c"] { await permission.submit(note(id)) }
        #expect(calls.status == .notDetermined, "nothing was decided")
        #expect(calls.requests == 1, "and the owner is not asked again in this process")
        #expect(calls.delivered.isEmpty)
    }

    @Test("a post that arrives while the prompt is up is held, and withdrawn if its ask goes")
    func heldWhileAsking() async throws {
        let calls = Calls(), permission = gate(calls)
        calls.holdRequest = true
        let first = Task { @MainActor in await permission.submit(note("a")) }
        var spins = 0
        while calls.held == nil, spins < 10_000 { await Task.yield(); spins += 1 }
        await permission.submit(note("b"))
        await permission.submit(note("c"))
        permission.withdraw(identifiers: ["c"])
        calls.held?.resume()
        try await value(of: first)
        #expect(calls.requests == 1)
        #expect(calls.delivered == ["a", "b"])
    }

    @Test("a prompt that never returns: a decided status ends the wait at the next post", arguments: [true, false])
    func stuckPromptEndsOnDecidedStatus(allowed: Bool) async throws {
        let calls = Calls(), permission = gate(calls)
        calls.holdRequest = true
        let first = Task { @MainActor in await permission.submit(note("a")) }
        var spins = 0
        while calls.held == nil, spins < 10_000 { await Task.yield(); spins += 1 }
        try #require(calls.held != nil)
        await permission.submit(note("b"))
        #expect(calls.delivered.isEmpty, "still undecided: held")

        calls.status = allowed ? .authorized : .denied   // answered, but the request never returned
        await permission.submit(note("c"))
        #expect(calls.delivered == (allowed ? ["a", "b", "c"] : []))

        // The prompt's late return finds nothing left to deliver, and asks nothing again.
        calls.grant = allowed
        calls.held?.resume()
        try await value(of: first)
        await permission.submit(note("d"))
        #expect(calls.delivered == (allowed ? ["a", "b", "c", "d"] : []))
        #expect(calls.requests == 1)
    }

    @Test("through the sink, a stuck prompt ends on a decided status, without the cards acknowledged meanwhile")
    func sinkStuckPromptDropsAcknowledged() async throws {
        let (_, app) = try makeApp()
        let center = FakeCenter()
        center.status = .notDetermined
        center.holdRequest = true
        let sink = UserNotificationSink(state: app, center: center)
        let first = sink.submit(note("a"))
        var spins = 0
        while center.heldRequest == nil, spins < 10_000 { await Task.yield(); spins += 1 }
        try #require(center.heldRequest != nil)
        try await value(of: sink.submit(note("run-1")))
        sink.withdraw(identifiers: ["run-1"])   // what acknowledging the run does

        center.status = .authorized
        try await value(of: sink.submit(note("b")))
        #expect(center.added == ["a", "b"])
        #expect(sink.unsettledCountForTesting == 0)

        center.heldRequest?.resume()
        try await value(of: first)
        #expect(center.added == ["a", "b"], "the late return adds nothing twice")
    }

    @Test("only a real .app bundle gets a sink")
    func bundleGuard() {
        #expect(SurfaceInstall.isAppBundle(URL(fileURLWithPath: "/Applications/Iris Dev.app")))
        #expect(!SurfaceInstall.isAppBundle(URL(fileURLWithPath: "/Users/me/src/iris/.build/debug")))
        #expect(!SurfaceInstall.isAppBundle(URL(fileURLWithPath: "/usr/bin")))
        #expect(!SurfaceInstall.isAppBundle(Bundle.main.bundleURL), "a test runner is not an app")
    }

    @Test("installing outside a bundle leaves no sink and touches no notification API")
    func installOutsideABundle() throws {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        SurfaceInstall.installNotifications(on: app, bundleURL: URL(fileURLWithPath: "/usr/bin"))
        #expect(app.notificationSink == nil)
    }

    @Test("UserNotificationSink.swift is the only file that imports UserNotifications")
    func oneImporter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        let importers = try files.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("import UserNotifications")
        }.map(\.lastPathComponent)
        #expect(importers == ["UserNotificationSink.swift"])
    }

    @Test("the setting defaults to Needs attention and persists")
    func setting() {
        let name = "iris-notify-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)
        #expect(config.notificationMode == .needsAttention)
        config.notificationMode = .off
        #expect(ConfigManager(store: store).notificationMode == .off)
    }

    @Test("Off posts nothing; Needs attention posts")
    func settingGatesPosting() async throws {
        let name = "iris-notify-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: defaults)
        let (store, app) = try makeApp()
        let sink = FakeSink()
        SurfaceInstall.wire(app, sink: sink, config: config, appActive: { false }, mainWindowVisible: { false })
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let iris = app.activityConversationId()
        func blocked() -> EventCard {
            EventCard(runId: UUID(), jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                      blockedTool: "run_command", startedAt: Date(), finishedAt: Date())
        }

        config.notificationMode = .off
        await app.deliverEvent(blocked(), to: iris)
        #expect(sink.posted.isEmpty, "Off posts nothing")

        config.notificationMode = .needsAttention
        await app.deliverEvent(blocked(), to: iris)
        #expect(sink.posted.map(\.kind) == [.jobNeedsYou])
    }

    @Test("categories are registered exactly as the policy specifies: Dismiss needs an unlock, nothing approves")
    func registeredCategories() throws {
        let (_, app) = try makeApp()
        let center = FakeCenter()
        _ = UserNotificationSink(state: app, center: center)
        #expect(center.registered == NotificationPolicy.categories)

        let system = UserNotificationSink.categories(NotificationPolicy.categories)
        #expect(Set(system.map(\.identifier)) == Set(NotificationPolicy.categories.map(\.id)))
        for spec in NotificationPolicy.categories {
            let category = try #require(system.first { $0.identifier == spec.id })
            #expect(category.actions.map(\.identifier) == spec.actions.map(\.id))
            #expect(category.actions.map(\.title) == spec.actions.map(\.title))
            for (action, want) in zip(category.actions, spec.actions) {
                #expect(action.options.contains(.authenticationRequired) == want.authenticationRequired)
                #expect(action.options.contains(.destructive) == want.destructive)
                #expect(action.options.contains(.foreground) == want.foreground)
            }
        }
        let dismiss = try #require(system.flatMap(\.actions).first { $0.identifier == NotificationPolicy.Action.dismiss })
        #expect(dismiss.options.contains(.authenticationRequired))
        #expect(!system.flatMap(\.actions).contains {
            $0.identifier.localizedCaseInsensitiveContains("approve")
                || $0.title.localizedCaseInsensitiveContains("approve")
        })
    }

    @Test("a banner click is Open; other action ids pass through untouched")
    func defaultActionIsOpen() {
        #expect(UserNotificationSink.actionId(for: UNNotificationDefaultActionIdentifier) == NotificationPolicy.Action.open)
        #expect(UserNotificationSink.actionId(for: NotificationPolicy.Action.deny) == NotificationPolicy.Action.deny)
        #expect(UserNotificationSink.actionId(for: "iris.approve") == "iris.approve",
                "unknown ids reach handleNotificationResponse, which ignores them")
    }

    @Test("content is .active, never .timeSensitive, and carries the planned strings")
    func contentIsActive() {
        let planned = note("a")
        let content = UserNotificationSink.content(for: planned)
        #expect(content.interruptionLevel == .active)
        #expect(content.title == planned.title)
        #expect(content.body == planned.body)
        #expect(content.categoryIdentifier == planned.categoryId)
    }

    @Test("a withdraw that lands while add is in flight removes the request once add returns")
    func withdrawDuringAdd() async throws {
        let (_, app) = try makeApp()
        let center = FakeCenter()
        center.holdAdd = true
        let sink = UserNotificationSink(state: app, center: center)
        let posting = sink.submit(note("a"))
        var spins = 0
        while center.heldAdd == nil, spins < 10_000 { await Task.yield(); spins += 1 }
        try #require(center.heldAdd != nil, "add must be in flight before the withdraw")
        sink.withdraw(identifiers: ["a"])
        #expect(center.removed == ["a"])
        center.heldAdd?.resume()
        try await value(of: posting)
        #expect(center.added == ["a"])
        #expect(center.removed == ["a", "a"], "removed again after the add, or the banner would stay up")
    }

    @Test("a withdraw before the post reaches the center means it is never added")
    func withdrawBeforeAdd() async throws {
        let (_, app) = try makeApp()
        let center = FakeCenter()
        let sink = UserNotificationSink(state: app, center: center)
        let posting = sink.submit(note("a"))
        sink.withdraw(identifiers: ["a"])
        try await value(of: posting)
        #expect(center.added.isEmpty)

        // A later post of something else is unaffected.
        try await value(of: sink.submit(note("b")))
        #expect(center.added == ["b"])
        #expect(center.removed == ["a"])
    }

    @Test("through the sink, a post held behind the prompt is still added once it is granted")
    func sinkDeliversHeldPosts() async throws {
        let (_, app) = try makeApp()
        let center = FakeCenter()
        center.status = .notDetermined
        center.holdRequest = true
        let sink = UserNotificationSink(state: app, center: center)
        let first = sink.submit(note("a"))
        var spins = 0
        while center.heldRequest == nil, spins < 10_000 { await Task.yield(); spins += 1 }
        try #require(center.heldRequest != nil, "the prompt must be up before the second post")
        try await value(of: sink.submit(note("b")))
        center.heldRequest?.resume()
        try await value(of: first)
        #expect(center.added == ["a", "b"])
        #expect(sink.unsettledCountForTesting == 0)
    }

    @Test("through the sink, denied posts leave nothing behind")
    func sinkDeniedSettles() async throws {
        let (_, app) = try makeApp()
        let center = FakeCenter()
        center.status = .notDetermined
        center.grant = false
        let sink = UserNotificationSink(state: app, center: center)
        for id in ["a", "b", "c"] { try await value(of: sink.submit(note(id))) }
        #expect(center.added.isEmpty)
        #expect(sink.unsettledCountForTesting == 0, "a never-withdrawn id must not be kept forever")
    }

    @Test("a response from the center reaches handleNotificationResponse")
    func responseIsHandled() throws {
        let (_, app) = try makeApp()
        var raises = 0
        app.raiseMainWindow = { raises += 1 }
        let center = FakeCenter()
        let sink = UserNotificationSink(state: app, center: center)
        center.onResponse?(NotificationResponse(actionId: NotificationPolicy.Action.open, userInfo: [:]))
        #expect(raises == 1)
        withExtendedLifetime(sink) {}
    }
}
