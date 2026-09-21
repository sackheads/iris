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
                                                previousArchivedSelection: nil, selection: UUID()) == false)
        #expect(ChatView.archivedGroupExpansion(current: true, archived: archived,
                                                previousArchivedSelection: nil, selection: UUID()))
    }

    @Test("selecting an archived conversation opens the group")
    func selectionExpands() {
        let id = UUID()
        #expect(ChatView.archivedGroupExpansion(current: false,
                                                archived: [archivedConversation(id)],
                                                previousArchivedSelection: UUID(), selection: id))
    }

    /// The bug this replaced: the old `userToggle || selectionIsArchived` getter pinned the group
    /// open while an archived row was selected, so the disclosure triangle visibly did nothing.
    /// §9 asks for an auto-expand, not a pin.
    @Test("an explicit collapse sticks while the same archived row stays selected")
    func collapseWinsForTheCurrentSelection() {
        let id = UUID()
        #expect(ChatView.archivedGroupExpansion(current: false,
                                                archived: [archivedConversation(id)],
                                                previousArchivedSelection: id, selection: id) == false)
    }

    /// The N2 regression: `/archive` and the context menu on the conversation you are looking at
    /// move no selection at all, so a rule keyed on selection changing left the user on a row
    /// inside a collapsed group — exactly what §9 exists to prevent, reached through §8.
    @Test("archiving the selected conversation expands the group")
    func archivingTheSelectionExpands() {
        let id = UUID()
        #expect(ChatView.archivedGroupExpansion(current: false,
                                                archived: [archivedConversation(id)],
                                                previousArchivedSelection: nil, selection: id),
                "it was not archived a moment ago, so this is a new trigger")
    }

    /// The collapse holds against everything that is not a trigger: archiving some *other*
    /// conversation while the user sits on an already-archived, deliberately hidden row.
    @Test("an explicit collapse survives another conversation being archived")
    func collapseSurvivesUnrelatedArchiving() {
        let id = UUID()
        let other = UUID()
        #expect(ChatView.archivedGroupExpansion(
            current: false, archived: [archivedConversation(id), archivedConversation(other)],
            previousArchivedSelection: id, selection: id) == false)
    }

    @Test("un-archiving the selected conversation leaves the group alone")
    func unarchivingTheSelectionDoesNotExpand() {
        let id = UUID()
        #expect(ChatView.archivedGroupExpansion(current: false, archived: [],
                                                previousArchivedSelection: id,
                                                selection: id) == false)
    }

    @Test("no selection and nothing archived leave it closed")
    func nothingToShow() {
        #expect(ChatView.archivedGroupExpansion(current: false, archived: [],
                                                previousArchivedSelection: nil, selection: nil) == false)
    }
}
