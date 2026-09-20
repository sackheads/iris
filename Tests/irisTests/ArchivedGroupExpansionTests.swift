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
        #expect(ChatView.archivedGroupExpansion(current: false, archived: archived,
                                                previous: nil, selection: UUID()) == false)
        #expect(ChatView.archivedGroupExpansion(current: true, archived: archived,
                                                previous: nil, selection: UUID()))
    }

    @Test("selecting an archived conversation opens the group")
    func selectionExpands() {
        let id = UUID()
        #expect(ChatView.archivedGroupExpansion(current: false,
                                                archived: [archivedConversation(id)],
                                                previous: UUID(), selection: id))
    }

    /// The bug this replaced: the old `userToggle || selectionIsArchived` getter pinned the group
    /// open while an archived row was selected, so the disclosure triangle visibly did nothing.
    /// §9 asks for an auto-expand, not a pin.
    @Test("an explicit collapse sticks while the same archived row stays selected")
    func collapseWinsForTheCurrentSelection() {
        let id = UUID()
        #expect(ChatView.archivedGroupExpansion(current: false,
                                                archived: [archivedConversation(id)],
                                                previous: id, selection: id) == false)
    }

    @Test("no selection and nothing archived leave it closed")
    func nothingToShow() {
        #expect(ChatView.archivedGroupExpansion(current: false, archived: [],
                                                previous: nil, selection: nil) == false)
    }
}
