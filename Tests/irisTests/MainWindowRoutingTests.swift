import Testing
import Foundation
@testable import IrisKit

/// D6 decision 4: every surface raises the main window through one `showMainWindow(selecting:)`,
/// and a row about a card lands on the card.
@MainActor
@Suite("Main window routing (D6)", .timeLimit(.minutes(1)))
struct MainWindowRoutingTests {
    private final class Raises { var count = 0 }

    private func makeApp() throws -> (ConversationStore, AppState, Raises) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let raises = Raises()
        app.raiseMainWindow = { raises.count += 1 }
        return (store, app, raises)
    }

    @Test("selects a conversation the sidebar can show, then raises once")
    func selectsAndRaises() throws {
        let (_, app, raises) = try makeApp()
        let id = app.createNewConversation(select: false)
        app.showMainWindow(selecting: id)
        #expect(app.selectedConversationId == id)
        #expect(raises.count == 1)
    }

    @Test("never selects a background run's transcript or an unknown id, and still raises")
    func refusesBackgroundAndUnknown() throws {
        let (_, app, raises) = try makeApp()
        let mine = app.createNewConversation()
        let background = app.createNewConversation(isBackground: true)
        app.showMainWindow(selecting: background)
        app.showMainWindow(selecting: UUID())
        app.showMainWindow(selecting: nil)
        #expect(app.selectedConversationId == mine)
        #expect(raises.count == 3)
    }

    @Test("never selects a subagent's scratch thread, which the sidebar does not show")
    func refusesSubagent() throws {
        let (_, app, raises) = try makeApp()
        let mine = app.createNewConversation()
        let scratch = app.createNewConversation(isSubagent: true, select: false)
        app.showMainWindow(selecting: scratch)
        #expect(app.selectedConversationId == mine)
        #expect(raises.count == 1)
    }

    @Test("revealCard opens Iris and scrolls to the card, when the job has no destination")
    func revealCardInIris() async throws {
        let (store, app, raises) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let runId = UUID()
        let card = EventCard(runId: runId, jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                             blockedTool: "run_command", startedAt: Date(), finishedAt: Date())
        let iris = app.activityConversationId()
        await app.deliverEvent(card, to: iris)
        let cardMessage = try #require(app.conversations.first { $0.id == iris }?.messages.last { $0.role == .event })

        await app.revealCard(runId: runId, jobId: job.id)

        #expect(app.selectedConversationId == iris)
        #expect(app.pendingScrollTarget == cardMessage.id)
        #expect(raises.count == 1)
    }

    @Test("after Iris rotates, a blocked run's card is found in the archived Iris and scrolled to")
    func revealCardAfterRotation() async throws {
        let (store, app, raises) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let runId = UUID()
        let card = EventCard(runId: runId, jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                             blockedTool: "run_command", startedAt: Date(), finishedAt: Date())
        let oldIris = app.activityConversationId()
        await app.deliverEvent(card, to: oldIris)
        let cardMessage = try #require(app.conversations.first { $0.id == oldIris }?.messages.last { $0.role == .event })
        // What `/new` on Iris leaves: the old one archived, a fresh one recorded as Iris.
        let idx = try #require(app.conversations.firstIndex { $0.id == oldIris })
        app.conversations[idx].isArchived = true
        let newIris = app.activityConversationId()
        #expect(newIris != oldIris)
        let elsewhere = app.createNewConversation()

        await app.revealCard(runId: runId, jobId: job.id)

        #expect(app.selectedConversationId == oldIris)
        #expect(app.selectedConversationId != elsewhere)
        #expect(app.pendingScrollTarget == cardMessage.id)
        #expect(app.conversations.first { $0.id == newIris }?.messages.isEmpty == true, "no line when the card was found")
        #expect(raises.count == 1)
    }

    @Test("a card found nowhere opens Iris with one line naming the /jobs ack that clears it")
    func revealCardGone() async throws {
        let (store, app, raises) = try makeApp()
        let dest = app.createNewConversation(select: false)
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)),
                      destinationConversationId: dest)
        try store.ledger.upsert(job)
        let runId = UUID()
        let card = EventCard(runId: runId, jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                             blockedTool: "run_command", startedAt: Date(), finishedAt: Date())
        await app.deliverEvent(card, to: dest)
        app.deleteConversation(dest)
        app.pendingScrollTarget = nil

        await app.revealCard(runId: runId, jobId: job.id)

        let iris = app.activityConversationId()
        #expect(app.selectedConversationId == iris)
        #expect(app.pendingScrollTarget == nil)
        let line = AppState.goneCardLine(jobName: "pr-sweep", runId: runId)
        #expect(line == "The card for pr-sweep's blocked run is gone; `/jobs ack \(runId.uuidString.lowercased().prefix(8))` clears it.")
        let lines = app.conversations.first { $0.id == iris }?.messages.filter { $0.content == line } ?? []
        #expect(lines.count == 1)
        #expect(raises.count == 1)
    }

    @Test("the card's destination is the one rule JobRunner delivers by (R4)")
    func cardDestinationRule() throws {
        let (_, app, _) = try makeApp()
        let dest = app.createNewConversation(select: false)
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)),
                      destinationConversationId: dest)
        #expect(app.cardDestination(for: job) == dest)
        #expect(app.cardDestination(for: nil) == app.activityConversationId())
        let idx = try #require(app.conversations.firstIndex { $0.id == dest })
        app.conversations[idx].isArchived = true
        #expect(app.cardDestination(for: job) == app.activityConversationId())
    }

    // MARK: - Menu rows

    @Test("an approvals row whose root is archived unarchives it and selects it")
    func approvalsRowUnarchivesRoot() async throws {
        let (_, app, raises) = try makeApp()
        let mine = app.createNewConversation()
        let root = app.createNewConversation(select: false)
        let idx = try #require(app.conversations.firstIndex { $0.id == root })
        app.conversations[idx].isArchived = true

        await app.openStatusRow(.conversation(root))

        #expect(app.selectedConversationId == root)
        #expect(app.conversations.first { $0.id == root }?.isArchived == false)
        #expect(app.selectedConversationId != mine)
        #expect(raises.count == 1)
    }

    @Test("an Iris row selects Iris; a card row reveals the card; a nowhere row does nothing")
    func otherRows() async throws {
        let (store, app, raises) = try makeApp()
        _ = app.createNewConversation()
        await app.openStatusRow(.iris)
        #expect(app.selectedConversationId == app.activityConversationId())
        #expect(raises.count == 1)

        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let runId = UUID()
        let card = EventCard(runId: runId, jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                             blockedTool: "run_command", startedAt: Date(), finishedAt: Date())
        await app.deliverEvent(card, to: app.activityConversationId())
        let other = app.createNewConversation()
        #expect(app.selectedConversationId == other)
        await app.openStatusRow(.card(runId: runId, jobId: job.id))
        #expect(app.selectedConversationId == app.activityConversationId())
        #expect(app.pendingScrollTarget != nil)
        #expect(raises.count == 2)

        app.selectedConversationId = other
        await app.openStatusRow(.nowhere)
        #expect(app.selectedConversationId == other)
        #expect(raises.count == 2)
    }
}

/// The chat window, tracked by reference (plan note 3), over fake windows: the tracker is an
/// instance of its own, so nothing here touches `MainWindow`'s process-wide one.
@MainActor
@Suite("Main window tracker (D6)", .timeLimit(.minutes(1)))
struct MainWindowTrackerTests {
    private final class FakeWindow: TrackableWindow {
        var isVisible = true
        var isMiniaturized = false
        var isUncovered = true
        var isKeyWindow = false
        var calls: [String] = []
        func deminiaturize(_ sender: Any?) { calls.append("deminiaturize"); isMiniaturized = false }
        func makeKeyAndOrderFront(_ sender: Any?) { calls.append("front"); isKeyWindow = true }
        func orderOut(_ sender: Any?) { calls.append("out"); isVisible = false }
    }

    private final class App { var active = false; var activations = 0 }

    private func makeTracker() -> (MainWindowTracking, App, NotificationCenter) {
        let center = NotificationCenter()
        let app = App()
        let tracker = MainWindowTracking(center: center, appIsActive: { app.active },
                                         activate: { app.activations += 1; app.active = true })
        return (tracker, app, center)
    }

    @Test("tracks the window it is handed, ignores nil, and forgets it when it closes")
    func tracksAndForgets() {
        let (tracker, _, center) = makeTracker()
        let window = FakeWindow()
        tracker.track(window)
        tracker.track(nil)
        #expect(tracker.current === window)

        // Another window closing is not ours closing.
        center.post(name: MainWindowTracking.willCloseNotification, object: FakeWindow())
        #expect(tracker.current === window)

        center.post(name: MainWindowTracking.willCloseNotification, object: window)
        #expect(tracker.current == nil)
    }

    @Test("a newer window goes in front, and only the closed window is forgotten")
    func retrack() {
        let (tracker, _, center) = makeTracker()
        let first = FakeWindow(), second = FakeWindow()
        tracker.track(first)
        tracker.track(second)
        center.post(name: MainWindowTracking.willCloseNotification, object: first)
        #expect(tracker.current === second)
        center.post(name: MainWindowTracking.willCloseNotification, object: second)
        #expect(tracker.current == nil)
    }

    @Test("raise activates the app and brings the tracked window back, never opening another")
    func raiseTracked() {
        let (tracker, app, _) = makeTracker()
        let window = FakeWindow()
        window.isMiniaturized = true
        tracker.track(window)
        var opened = 0
        tracker.raise(open: { opened += 1 })
        #expect(app.activations == 1)
        #expect(window.calls == ["deminiaturize", "front"])
        #expect(opened == 0)
    }

    @Test("closing the tracked one of two windows raises the other, minimized or not, and opens nothing")
    func fallsBackToOpenWindow() {
        let (tracker, _, center) = makeTracker()
        let other = FakeWindow(), tracked = FakeWindow()
        other.isMiniaturized = true
        tracker.track(other)
        tracker.track(tracked)
        #expect(tracker.current === tracked)

        center.post(name: MainWindowTracking.willCloseNotification, object: tracked)
        var opened = 0
        tracker.raise(open: { opened += 1 })

        #expect(opened == 0)
        #expect(other.calls == ["deminiaturize", "front"])
        #expect(tracked.calls.isEmpty)
    }

    @Test("the fallback is the most recently key chat window still open")
    func fallbackIsMostRecentlyKey() {
        let (tracker, _, center) = makeTracker()
        let a = FakeWindow(), b = FakeWindow(), c = FakeWindow()
        tracker.track(a)
        tracker.track(b)
        tracker.track(c)
        center.post(name: MainWindowTracking.didBecomeKeyNotification, object: a)
        #expect(tracker.current === a)

        center.post(name: MainWindowTracking.willCloseNotification, object: a)
        #expect(tracker.current === c)
        center.post(name: MainWindowTracking.willCloseNotification, object: c)
        #expect(tracker.current === b)
    }

    @Test("once every chat window has closed, raise opens one")
    func opensWhenAllClosed() {
        let (tracker, _, center) = makeTracker()
        let a = FakeWindow(), b = FakeWindow()
        tracker.track(a)
        tracker.track(b)
        center.post(name: MainWindowTracking.willCloseNotification, object: a)
        center.post(name: MainWindowTracking.willCloseNotification, object: b)
        var opened = 0
        tracker.raise(open: { opened += 1 })
        #expect(opened == 1)
        #expect(a.calls.isEmpty && b.calls.isEmpty)
    }

    @Test("raise with no window opens the scene")
    func raiseClosed() {
        let (tracker, app, _) = makeTracker()
        var opened = 0
        tracker.raise(open: { opened += 1 })
        #expect(opened == 1)
        #expect(app.activations == 1)
    }

    @Test("visible means on screen, not minimized and not covered")
    func visibility() {
        let (tracker, _, _) = makeTracker()
        #expect(!tracker.isVisible)
        let window = FakeWindow()
        tracker.track(window)
        #expect(tracker.isVisible)
        window.isUncovered = false
        #expect(!tracker.isVisible)
        window.isUncovered = true
        window.isMiniaturized = true
        #expect(!tracker.isVisible)
    }

    @Test("the hotkey hides the frontmost window and otherwise raises through showMainWindow")
    func hotkey() throws {
        let (tracker, app, _) = makeTracker()
        let window = FakeWindow()
        tracker.track(window)
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        var raises = 0
        state.raiseMainWindow = { raises += 1 }

        // Key but the app is not active: another app is in front, so the hotkey shows.
        window.isKeyWindow = true
        tracker.toggleFromHotkey(state: state)
        #expect(raises == 1)
        #expect(!window.calls.contains("out"))

        app.active = true
        #expect(tracker.isFrontmost)
        tracker.toggleFromHotkey(state: state)
        #expect(raises == 1)
        #expect(window.calls.last == "out")

        // Active, but another of the app's windows is key (Diagnostics): show, do not hide.
        window.isKeyWindow = false
        tracker.toggleFromHotkey(state: state)
        #expect(raises == 2)
    }
}
