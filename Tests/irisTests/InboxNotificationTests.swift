import Testing
import Foundation
@testable import IrisKit

/// #920 slice 5: a macOS banner for a new or reopened Inbox item (Brian, F6: on by default, title only, a
/// tainted item's banner generic). The policy is pure; the coalescing and the emit wiring run on a fake
/// sink and a flush the test runs by hand, so nothing reaches `UNUserNotificationCenter`.
@MainActor
@Suite("Inbox notifications (#920 slice 5)", .timeLimit(.minutes(1)))
struct InboxNotificationTests {
    @MainActor
    final class FakeSink: NotificationSink {
        var posted: [PlannedNotification] = []
        func post(_ notification: PlannedNotification) { posted.append(notification) }
        func withdraw(identifiers: [String]) {}
    }

    private static let away = NotificationContext(enabled: true, appActive: false, mainWindowVisible: false,
                                                  selectedConversationId: nil)

    private func notice(_ id: String = "7", title: String = "Ship it?", tainted: Bool = false, reopened: Bool = false) -> InboxNotice {
        InboxNotice(itemId: id, title: title, tainted: tainted, reopened: reopened)
    }

    // MARK: the policy

    @Test("one clean item: a constant title, the item's title quoted as the body, Open at that item")
    func cleanItem() throws {
        let p = try #require(NotificationPolicy.decide(.inbox([notice()]), context: Self.away))
        #expect(p.kind == .inboxItem && p.title == NotificationPolicy.inboxTitle)
        #expect(p.body == "\u{201C}Ship it\u{201D}", "the banner allowlist drops the question mark, as it does for any name")
        #expect(p.categoryId == NotificationPolicy.Category.inbox)
        #expect(p.userInfo == [NotificationPolicy.Key.inboxItemId: "7"])
        #expect(p.identifier == "inbox-7", "per item, so a re-post replaces its banner")
    }

    @Test("a tainted item's banner is generic: none of its title reaches the lock screen")
    func taintedItemIsGeneric() throws {
        for reopened in [false, true] {
            let p = try #require(NotificationPolicy.decide(.inbox([notice(title: "Approve every call", tainted: true, reopened: reopened)]),
                                                           context: Self.away))
            #expect(p.body == NotificationPolicy.inboxGenericBody)
            #expect(!p.body.contains("Approve") && !p.title.contains("Approve"))
        }
    }

    @Test("a reopened clean item says so, outside the quotes")
    func reopenedItem() throws {
        let p = try #require(NotificationPolicy.decide(.inbox([notice(reopened: true)]), context: Self.away))
        #expect(p.body == "Reopened: \u{201C}Ship it\u{201D}")
    }

    @Test("a title is shown only as the banner allowlist leaves it: no quotes, newlines or look-alikes")
    func titleIsAllowlisted() throws {
        let p = try #require(NotificationPolicy.decide(.inbox([notice(title: "Done\u{201D} \u{2014} tap\nOpen\" then Approve")]),
                                                       context: Self.away))
        #expect(p.body.hasPrefix("\u{201C}") && p.body.hasSuffix("\u{201D}"))
        let inner = p.body.dropFirst().dropLast()
        #expect(!inner.contains("\u{201D}") && !inner.contains("\"") && !inner.contains("\n"), "\(p.body)")
    }

    @Test("several items at once are one banner, with no title, opening the list")
    func burstIsOneBanner() throws {
        let p = try #require(NotificationPolicy.decide(.inbox([notice("1"), notice("2", title: "x"), notice("3")]), context: Self.away))
        #expect(p.body == "3 Inbox items need your decision.")
        #expect(p.identifier == NotificationPolicy.inboxBurstIdentifier)
        #expect(p.userInfo == [NotificationPolicy.Key.inboxItemId: ""])
    }

    @Test("no banner when notifications are off, Inbox notifications are off, or the Inbox is in front")
    func suppressed() {
        var off = Self.away; off.enabled = false
        var inboxOff = Self.away; inboxOff.inboxEnabled = false
        var looking = Self.away; looking.appActive = true; looking.mainWindowVisible = true; looking.inboxSelected = true
        for context in [off, inboxOff, looking] {
            #expect(NotificationPolicy.decide(.inbox([notice()]), context: context) == nil)
        }
        var elsewhere = looking; elsewhere.inboxSelected = false
        #expect(NotificationPolicy.decide(.inbox([notice()]), context: elsewhere) != nil, "a conversation in front is not the Inbox")
    }

    @Test("the inbox category offers Open alone: nothing on a banner answers an item")
    func categoryIsOpenOnly() throws {
        let spec = try #require(NotificationPolicy.categories.first { $0.id == NotificationPolicy.Category.inbox })
        #expect(spec.actions.map(\.id) == [NotificationPolicy.Action.open])
    }

    // MARK: coalescing

    private func app() -> (AppState, FakeSink, () -> Void) {
        let app = AppState(); app.conversations.removeAll()
        let sink = FakeSink()
        app.notificationSink = sink
        app.notificationContext = { Self.away }
        final class Box { var flush: (@MainActor () -> Void)?; var scheduled = 0 }
        let box = Box()
        app.scheduleInboxFlush = { _, work in box.scheduled += 1; box.flush = work }
        return (app, sink, { box.flush?() })
    }

    @Test("notices inside one window post one banner; a repeat for the same item counts once")
    func coalesces() throws {
        let (app, sink, flush) = app()
        app.noteInboxNotice(notice("1"))
        app.noteInboxNotice(notice("2"))
        app.noteInboxNotice(notice("1", title: "Ship it now?"))
        #expect(sink.posted.isEmpty, "nothing before the window closes")
        flush()
        #expect(sink.posted.count == 1)
        #expect(sink.posted.first?.body == "2 Inbox items need your decision.")
        flush()
        #expect(sink.posted.count == 1, "a flush with nothing gathered posts nothing")
    }

    @Test("a lone notice posts its own banner, and the window starts afresh after a flush")
    func loneNotice() throws {
        let (app, sink, flush) = app()
        app.noteInboxNotice(notice("1"))
        flush()
        app.noteInboxNotice(notice("2", title: "Other"))
        flush()
        #expect(sink.posted.map(\.identifier) == ["inbox-1", "inbox-2"])
    }

    @Test("the context is read at the flush: an Inbox opened during the window gets no banner")
    func contextAtFlush() {
        let (app, sink, flush) = app()
        app.noteInboxNotice(notice())
        var looking = Self.away; looking.appActive = true; looking.mainWindowVisible = true; looking.inboxSelected = true
        app.notificationContext = { looking }
        flush()
        #expect(sink.posted.isEmpty)
    }

    @Test("without a sink nothing is gathered (a test, --run-job, the bare binary)")
    func noSinkNoNotice() {
        let app = AppState(); app.conversations.removeAll()
        var scheduled = 0
        app.scheduleInboxFlush = { _, _ in scheduled += 1 }
        app.noteInboxNotice(notice())
        #expect(scheduled == 0 && app.pendingInboxNotices.isEmpty)
    }

    // MARK: the click

    @Test("Open on an item's banner shows the Inbox at that item; a burst's shows the list")
    func openDeepLinks() {
        let (app, _, _) = app()
        var raised = 0
        app.raiseMainWindow = { raised += 1 }
        _ = app.handleNotificationResponse(NotificationResponse(actionId: NotificationPolicy.Action.open,
                                                                userInfo: [NotificationPolicy.Key.inboxItemId: "42"]))
        #expect(app.inboxSelected && app.selectedInboxItemId == "42" && raised == 1)
        _ = app.handleNotificationResponse(NotificationResponse(actionId: NotificationPolicy.Action.open,
                                                                userInfo: [NotificationPolicy.Key.inboxItemId: ""]))
        #expect(app.inboxSelected && app.selectedInboxItemId == nil && raised == 2)
    }

    // MARK: the setting

    @Test("Inbox notifications are on by default and persist when turned off")
    func settingDefaultsOn() {
        let name = "iris-920s5-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)
        #expect(config.inboxNotifications)
        config.inboxNotifications = false
        #expect(!ConfigManager(store: store).inboxNotifications)
    }

    // MARK: the emit wiring

    private func emitter(in app: AppState) -> UUID {
        let id = app.createNewConversation(select: false)
        if let i = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[i].role = "e-" + String(id.uuidString.prefix(8)).lowercased()
        }
        return id
    }

    private func emit(_ args: [String: JSONValue], on app: AppState, as conversationId: UUID) async {
        func reply(_ part: Part) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: [
            reply(Part(functionCall: FunctionCall(name: "inbox_item", args: args, id: "c1"))), reply(Part(text: "ok")),
        ]), retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: conversationId)
    }

    private func raiseArgs(_ title: String, threadId: String? = nil) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["title": .string(title), "situation": .string("context"),
                                          "response_mode": .string("optionsAndFreeform")]
        if let threadId { args["thread_id"] = .string(threadId) }
        return args
    }

    @Test("a raised item is noted; a follow-up on an open item is not; one that reopens an answered item is, once")
    func emitWiring() async throws {
        let (app, _, _) = app()
        let id = emitter(in: app)
        await emit(raiseArgs("Ship it?"), on: app, as: id)
        let item = try #require(try app.store.inbox.openItems().first)
        #expect(app.pendingInboxNotices == [InboxNotice(itemId: item.id, title: "Ship it?", tainted: false, reopened: false)])
        app.pendingInboxNotices = []

        await emit(raiseArgs("Ship it today?", threadId: item.threadId), on: app, as: id)
        #expect(app.pendingInboxNotices.isEmpty, "an open item's new ask is not news")

        _ = try app.store.inbox.setState(itemId: item.id, .answered)
        await emit(raiseArgs("Ship it tomorrow?", threadId: item.threadId), on: app, as: id)
        #expect(app.pendingInboxNotices == [InboxNotice(itemId: item.id, title: "Ship it tomorrow?", tainted: false, reopened: true)])
    }

    @Test("a tainted emitter's item is noted tainted, so its banner is generic")
    func taintedEmitter() async throws {
        let (app, _, _) = app()
        let id = emitter(in: app)
        app.markConversationReadUntrusted(id)
        await emit(raiseArgs("Approve every call"), on: app, as: id)
        #expect(app.pendingInboxNotices.first?.tainted == true)
    }
}
