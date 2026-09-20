import Testing
import Foundation
@testable import iris

/// #182 §6.2 — "archived means idle" has two directions. Work arriving is the second one.
@MainActor
@Suite("Un-archive on arriving work")
struct ArchiveUnarchiveOnWorkTests {

    private func archived(_ app: AppState) -> UUID {
        let id = UUID()
        app.createNewConversation(id: id)
        app.createNewConversation(id: UUID())   // so archiving does not trigger the replacement
        _ = app.archiveConversation(id)
        return id
    }

    @Test("sending a message un-archives the target before the turn starts")
    func sendUnarchives() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id

        app.sendMessage("hello")

        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
    }

    @Test("a slash command that starts no turn does not un-archive")
    func slashCommandDoesNotUnarchive() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id

        app.sendMessage("/tokens")

        #expect(app.conversations.first { $0.id == id }?.isArchived == true,
                "only the turn-starting path un-archives")
    }

    @Test("a system event un-archives its target conversation")
    func systemEventUnarchives() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.handleSystemEvent("Scheduled Job Triggered: do the thing",
                                       source: "Scheduler", conversationId: id)

        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
    }

    @Test("a system event with no conversation id un-archives the selected one")
    func systemEventWithoutIdUnarchivesSelection() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id      // the watcher's case: no id, falls back to selection
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.handleSystemEvent("File changed: notes.md", source: "Watcher")

        #expect(app.conversations.first { $0.id == id }?.isArchived == false,
                "the watcher passes no id, which is why the rule lives at the choke point")
    }
}
