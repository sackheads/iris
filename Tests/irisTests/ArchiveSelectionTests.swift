import Testing
import Foundation
@testable import iris

/// #182 §5 — the same-list design dissolves the "selected but not rendered" class for delete and
/// search. The launch path picks by `position`, not by what the user touched, so it needs a rule.
@MainActor
@Suite("Archive and selection")
struct ArchiveSelectionTests {

    @Test("delete re-points to an active conversation, never an archived one")
    func deletePrefersActive() {
        let app = AppState(); app.conversations.removeAll()
        let keep = UUID(), archivedOne = UUID(), doomed = UUID()
        app.createNewConversation(id: keep)
        app.createNewConversation(id: archivedOne)
        app.createNewConversation(id: doomed)
        _ = app.archiveConversation(archivedOne)
        app.selectedConversationId = doomed

        app.deleteConversation(doomed)

        #expect(app.selectedConversationId == keep)
        #expect(app.selectedConversationId != archivedOne)
    }

    @Test("deleting the last active conversation creates a new one rather than landing in the archive")
    func deleteLastActiveCreates() {
        let app = AppState(); app.conversations.removeAll()
        let archivedOne = UUID(), doomed = UUID()
        app.createNewConversation(id: archivedOne)
        app.createNewConversation(id: doomed)
        _ = app.archiveConversation(archivedOne)
        app.selectedConversationId = doomed

        app.deleteConversation(doomed)

        let active = app.conversations.filter { !$0.isSubagent && !$0.isArchived }
        #expect(active.count == 1)
        #expect(active.first?.id != archivedOne)
        #expect(app.selectedConversationId == active.first?.id)
    }

    @Test("launch selection prefers the last non-archived conversation")
    func launchPrefersActive() {
        // `selectLaunchConversation` is the extracted rule; `loadConversations` calls it.
        let active = Conversation(id: UUID(), title: "active")
        var archivedOne = Conversation(id: UUID(), title: "archived")
        archivedOne.isArchived = true
        #expect(AppState.selectLaunchConversation([active, archivedOne])?.id == active.id)
        #expect(AppState.selectLaunchConversation([archivedOne])?.id == archivedOne.id,
                "falls back only when there is nothing else")
        #expect(AppState.selectLaunchConversation([]) == nil)
    }
}
