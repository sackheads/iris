import Testing
import Foundation
import Observation
@testable import IrisKit

/// #592 (Brian's pick, over an ask-the-user tool): a reply that lands while the person is not
/// looking marks its conversation's row with a blue dot until they look.
@MainActor
@Suite("Unread reply (#592)", .timeLimit(.minutes(1)))
struct UnreadReplyTests {
    /// What the person is looking at, as the notification policy's context reports it.
    final class Looking { var active = true, visible = true }

    private func makeApp(_ looking: Looking) throws -> AppState {
        let app = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                           tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        app.notificationContext = { [weak app] in
            NotificationContext(enabled: true, appActive: looking.active, mainWindowVisible: looking.visible,
                                selectedConversationId: app?.selectedConversationId)
        }
        return app
    }

    /// One turn in `id` that ends with an agent reply (or only a system line).
    private func turn(_ app: AppState, _ id: UUID, reply: Bool = true) {
        app.beginEngineTurn(for: id)
        app.appendMessage(role: reply ? .agent : .system, content: "done", to: id)
        app.endEngineTurn(for: id)
    }

    @Test("a reply that lands in a conversation the person is not looking at marks it; looking, it does not")
    func turnEndMarks() throws {
        let looking = Looking()
        let app = try makeApp(looking)
        let shown = app.createNewConversation(select: false), other = app.createNewConversation(select: false)
        app.selectedConversationId = shown

        turn(app, shown)
        #expect(!app.unreadReplies.contains(shown), "looked at as it landed")
        turn(app, other)
        #expect(app.unreadReplies.contains(other), "not the selected one")
        let quiet = app.createNewConversation(select: false)
        turn(app, quiet, reply: false)
        #expect(!app.unreadReplies.contains(quiet), "a turn that added no agent reply is no reply")
    }

    @Test("selecting the conversation reads it")
    func selectingClears() throws {
        let app = try makeApp(Looking())
        let id = app.createNewConversation(select: false)
        turn(app, id)
        #expect(app.unreadReplies.contains(id))
        app.selectedConversationId = id
        #expect(!app.unreadReplies.contains(id))
    }

    @Test("with the app inactive, a reply on the selected row marks it, and activating the app clears it")
    func inactiveAppThenActivate() throws {
        let looking = Looking()
        let app = try makeApp(looking)
        let id = app.createNewConversation(select: false)
        app.selectedConversationId = id
        looking.active = false

        turn(app, id)
        #expect(app.unreadReplies.contains(id), "selected but not seen: the app was in the background")

        looking.active = true
        app.clearUnreadIfLooking()   // what the app's didBecomeActive / didBecomeKey observers call
        #expect(!app.unreadReplies.contains(id))
    }

    @Test("a job's card landing in the pinned Iris marks it, and a hidden conversation never gets a mark")
    func cardsAndHidden() async throws {
        let looking = Looking()
        looking.active = false
        let app = try makeApp(looking)
        let iris = app.createNewConversation(select: false)
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "digest", status: .completed,
                             startedAt: Date(), finishedAt: Date())
        await app.deliverEvent(card, to: iris)
        #expect(app.unreadReplies.contains(iris))

        let hidden = app.createNewConversation(isBackground: true, select: false)
        turn(app, hidden)
        #expect(!app.unreadReplies.contains(hidden), "a job transcript or a delegate has no row of its own")
    }

    @Test("deleting or archiving a conversation drops its mark")
    func deleteAndArchive() throws {
        let app = try makeApp(Looking())
        let a = app.createNewConversation(select: false), b = app.createNewConversation(select: false)
        turn(app, a)
        turn(app, b)
        app.deleteConversation(a)
        _ = app.archiveConversation(b)
        #expect(app.unreadReplies.isEmpty)
    }

    @Test("the red needs-you pip wins over the blue unread dot")
    func redWins() {
        #expect(ConversationMark.kind(needsHuman: "approval: write_file", unread: true) == .needsHuman("approval: write_file"))
        #expect(ConversationMark.kind(needsHuman: nil, unread: true) == .unread)
        #expect(ConversationMark.kind(needsHuman: nil, unread: false) == nil)
    }

    @Test("a streamed token never touches the mark")
    func tokensChangeNothing() throws {
        let app = try makeApp(Looking())
        let id = app.createNewConversation(select: false)
        let message = UUID()
        app.beginEngineTurn(for: id)
        app.appendMessage(role: .agent, content: "Hel", id: message, to: id)
        final class Flag: @unchecked Sendable { var set = false }
        let fired = Flag()
        withObservationTracking({ _ = app.unreadReplies }) { fired.set = true }
        app.updateMessageContent(id: message, content: "Hello wor", in: id, persist: false)
        #expect(!fired.set)
        app.endEngineTurn(for: id)
    }
}
