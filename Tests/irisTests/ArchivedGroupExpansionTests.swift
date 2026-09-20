import Testing
import Foundation
@testable import iris

/// #182 §9 — the one genuinely new UI rule: an archived conversation can be selected (search
/// reveal, delete re-point, launch fallback), and a selected row inside a collapsed group is
/// invisible. The SwiftUI binding cannot be reached from a unit test here; the rule it evaluates
/// can, so that is what this pins.
@MainActor
@Suite("Archived group expansion (#182 §9)")
struct ArchivedGroupExpansionTests {

    private func archivedConversation(_ id: UUID) -> Conversation {
        var c = Conversation(id: id, title: "archived")
        c.isArchived = true
        return c
    }

    @Test("collapsed by default, and the user's toggle opens it")
    func userToggleWins() {
        let archived = [archivedConversation(UUID())]
        #expect(ChatView.archivedGroupIsExpanded(userToggle: false, archived: archived,
                                                 selection: UUID()) == false)
        #expect(ChatView.archivedGroupIsExpanded(userToggle: true, archived: archived,
                                                 selection: UUID()))
    }

    @Test("a selected archived conversation forces it open regardless of the toggle")
    func selectionForcesExpanded() {
        let id = UUID()
        #expect(ChatView.archivedGroupIsExpanded(userToggle: false,
                                                 archived: [archivedConversation(id)],
                                                 selection: id))
    }

    @Test("no selection and nothing archived leave it closed")
    func nothingToShow() {
        #expect(ChatView.archivedGroupIsExpanded(userToggle: false, archived: [],
                                                 selection: nil) == false)
    }
}
