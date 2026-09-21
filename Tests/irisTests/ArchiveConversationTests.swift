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

    @Test("/archive archives the current conversation")
    func slashArchive() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.selectedConversationId = a

        app.sendMessage("/archive")

        #expect(app.conversations.first { $0.id == a }?.isArchived == true)
    }

    @Test("/archive reports the refusal rather than archiving")
    func slashArchiveRefused() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.setGoal(for: a, goal: "ship it")
        app.selectedConversationId = a

        app.sendMessage("/archive")

        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
        let messages = app.conversations.first { $0.id == a }?.messages ?? []
        #expect(messages.contains { $0.content.contains("goal is active") })
    }

    @Test("archiving an id that is not loaded is refused, not silently reported as done")
    func unknownIdRefused() {
        let app = AppState(); app.conversations.removeAll()
        app.createNewConversation(id: UUID())
        let stale = UUID()

        #expect(app.archiveRefusal(for: stale) == .noSuchConversation)
        #expect(app.archiveConversation(stale) == .noSuchConversation,
                "nil here would tell the caller a conversation was archived when none was")
    }

    @Test("/unarchive is handled as a command, not sent to the model")
    func slashUnarchiveIsACommand() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        _ = app.archiveConversation(a)
        app.selectedConversationId = a

        app.sendMessage("/unarchive")

        // `isArchived == false` alone proves nothing: falling through would reach the turn path,
        // which un-archives too (§6.2). The absent user bubble is what says it was a command.
        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
        #expect(app.conversations.first { $0.id == a }?.messages.contains { $0.role == .user } == false,
                "the literal text would otherwise become a real LLM turn")
        #expect(app.isThinking == false)
    }

    @Test("/archive on an already-archived conversation confirms rather than doing nothing")
    func slashArchiveAlreadyArchived() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        _ = app.archiveConversation(a)
        app.selectedConversationId = a

        app.sendMessage("/archive")

        #expect(app.conversations.first { $0.id == a }?.isArchived == true)
        let messages = app.conversations.first { $0.id == a }?.messages ?? []
        #expect(messages.contains { $0.role == .system && $0.content == "Already archived." },
                "a silent no-op reads as a command that was not understood")
        #expect(messages.contains { $0.role == .user } == false)
    }

    @Test("/unarchive on an active conversation confirms rather than doing nothing")
    func slashUnarchiveNotArchived() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID()
        app.createNewConversation(id: a)
        app.selectedConversationId = a

        app.sendMessage("/unarchive")

        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
        let messages = app.conversations.first { $0.id == a }?.messages ?? []
        #expect(messages.contains { $0.role == .system && $0.content == "Not archived." })
        #expect(messages.contains { $0.role == .user } == false)
    }
}
