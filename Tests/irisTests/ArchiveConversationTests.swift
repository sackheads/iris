import Testing
import Foundation
@testable import iris

/// #182. Archiving is a list-management gesture: it must never change what the agent is doing,
/// and must never leave the user without somewhere to type.
@MainActor
@Suite("Archive conversations")
struct ArchiveConversationTests {

    @Test("archiving is refused while a turn is in flight")
    func refusedWithTurnInFlight() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID()
        app.createNewConversation(id: a)
        app.selectedConversationId = a

        // sendMessage starts a turn asynchronously; the task is added to activeTasks immediately.
        // In this synchronous test, the async task hasn't completed yet, so hasTurnInFlight is true.
        app.sendMessage("test message")

        #expect(app.archiveRefusal(for: a) == .turnInFlight)
        #expect(app.archiveConversation(a) == .turnInFlight)
        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
    }

    @Test("archiving is refused while a goal is active")
    func refusedWithActiveGoal() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.setGoal(for: a, goal: "ship it")

        #expect(app.archiveRefusal(for: a) == .goalActive)
        #expect(app.archiveConversation(a) == .goalActive)
        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
    }

    @Test("archiving moves the conversation and leaves selection alone when others remain")
    func archivesAndKeepsSelection() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.selectedConversationId = a

        #expect(app.archiveConversation(a) == nil)
        #expect(app.conversations.first { $0.id == a }?.isArchived == true)
        #expect(app.selectedConversationId == a, "an archived conversation is still rendered, so it stays valid")
    }

    @Test("archiving the last active conversation creates one and selects it")
    func lastActiveGetsReplacement() {
        let app = AppState(); app.conversations.removeAll()
        let only = UUID()
        app.createNewConversation(id: only)
        app.selectedConversationId = only

        #expect(app.archiveConversation(only) == nil)
        let active = app.conversations.filter { !$0.isSubagent && !$0.isArchived }
        #expect(active.count == 1, "the user needs somewhere to type")
        #expect(active.first?.id != only)
        #expect(app.selectedConversationId == active.first?.id, "selection follows the replacement")
    }

    @Test("unarchiving returns it to the active set")
    func unarchiveRestores() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        _ = app.archiveConversation(a)

        app.unarchiveConversation(a)
        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
    }
}
