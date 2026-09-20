import Testing
import Foundation
@testable import iris

/// #167: `deleteConversation` re-pointed the selection using the unfiltered conversation array,
/// so it could land on a subagent/evaluator scratch conversation the sidebar never renders
/// (`ChatView` lists `conversations.filter { !$0.isSubagent }`).
@MainActor
@Suite("deleteConversation selection (#167)")
struct DeleteConversationSelectionTests {

    @Test("deleting the selected conversation never selects a subagent conversation")
    func testSelectionSkipsSubagents() {
        let app = AppState()
        app.conversations.removeAll()

        let keep = UUID(), doomed = UUID(), scratch = UUID()
        app.createNewConversation(id: keep)
        app.createNewConversation(id: doomed)
        // The evaluator's scratch conversation is appended last, so it is `conversations.last`.
        app.createNewConversation(id: scratch, isSubagent: true)
        app.selectedConversationId = doomed

        app.deleteConversation(doomed)

        #expect(app.selectedConversationId != scratch,
                "selection landed on a conversation the sidebar does not render")
        #expect(app.selectedConversationId == keep)
    }

    @Test("a list holding only subagent conversations gets a fresh durable one")
    func testOnlySubagentsLeftCreatesDurable() {
        let app = AppState()
        app.conversations.removeAll()

        let doomed = UUID(), scratch = UUID()
        app.createNewConversation(id: doomed)
        app.createNewConversation(id: scratch, isSubagent: true)
        app.selectedConversationId = doomed

        app.deleteConversation(doomed)

        // `conversations` is not empty — the scratch one remains — but the sidebar would be, so
        // the user still needs somewhere to land.
        let durable = app.conversations.filter { !$0.isSubagent }
        #expect(durable.count == 1, "no durable conversation left for the user")
        #expect(app.selectedConversationId == durable.first?.id)
        #expect(app.selectedConversationId != scratch)
    }

    @Test("deleting an unselected conversation leaves the selection alone")
    func testUnrelatedDeleteKeepsSelection() {
        let app = AppState()
        app.conversations.removeAll()

        let keep = UUID(), other = UUID()
        app.createNewConversation(id: keep)
        app.createNewConversation(id: other)
        app.selectedConversationId = keep

        app.deleteConversation(other)

        #expect(app.selectedConversationId == keep)
    }
}
