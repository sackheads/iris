import Testing
import Foundation
import AppKit
@testable import IrisKit

/// #703: Cmd-C on a selected reply beeped because the selection had been cleared under the person,
/// by an append or by another conversation's delete moving the active index.
@MainActor
@Suite("The transcript's selection survives what isn't the person's doing (#703)")
struct MessageSelectionTests {
    private let reply = ChatMessage(role: .agent, content: "the reply to copy")
    private let pill1 = ChatMessage(role: .system, content: "[TOOL_CALL] one")
    private let pill2 = ChatMessage(role: .system, content: "[TOOL_CALL] two")

    @Test("an append keeps every selected item still in the conversation, a grown group included")
    func appendKeeps() {
        let before = MessageItem.group([reply, pill1])
        let groupId = before[1].id
        let selected: Set<UUID> = [reply.id, groupId]
        let after = MessageItem.group([reply, pill1, pill2, ChatMessage(role: .agent, content: "a card")])
        #expect(MessageSelection.apply(.messagesChanged(after), to: selected) == selected)
    }

    @Test("an item no longer in the conversation is dropped, and only it")
    func goneIsDropped() {
        let selected: Set<UUID> = [reply.id, UUID()]
        #expect(MessageSelection.apply(.messagesChanged(MessageItem.group([reply])), to: selected) == [reply.id])
    }

    @Test("a copy takes the selected messages in transcript order, a group's all of them")
    func copyTakes() {
        let items = MessageItem.group([reply, pill1, pill2])
        #expect(MessageSelection.messages([items[1].id, reply.id], in: items).map(\.id) == [reply.id, pill1.id, pill2.id])
        #expect(MessageSelection.messages([], in: items).isEmpty)
    }

    @Test("switching conversations clears it")
    func switchClears() {
        #expect(MessageSelection.apply(.conversationSwitched, to: [reply.id]).isEmpty)
    }

    /// Why the view keys its clear on the conversation: deleting an earlier hidden conversation (a
    /// job's pruned transcript) moves the active index but not the selected conversation.
    @Test("deleting an earlier hidden conversation moves the index, not the selected conversation")
    func earlierDeleteKeepsTheConversation() throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let hidden = state.createNewConversation(isBackground: true, select: false)
        let shown = state.createNewConversation(isBackground: false, select: true)
        let indexBefore = state.activeConversationIndex
        state.deleteConversation(hidden)
        #expect(state.selectedConversationId == shown, "what the selection clear is keyed on")
        #expect(state.activeConversationIndex != indexBefore, "what it was keyed on, which fired")
    }
}

/// #703: the transcript's focus anchor finds its own table, by frame, not the sidebar's.
@MainActor
@Suite("The transcript focus anchor finds the right table (#703)")
struct TranscriptFocusAnchorTests {
    private func table(in frame: NSRect, of root: NSView) -> NSTableView {
        let scroll = NSScrollView(frame: frame)
        let table = NSTableView(frame: NSRect(origin: .zero, size: frame.size))
        table.addTableColumn(NSTableColumn(identifier: .init("c")))   // a table with none refuses focus
        scroll.documentView = table
        root.addSubview(scroll)
        return table
    }

    @Test("a click finds the table under it, and none outside every table")
    func findsByFrame() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        let sidebar = table(in: NSRect(x: 0, y: 0, width: 200, height: 600), of: root)
        let transcript = table(in: NSRect(x: 200, y: 100, width: 600, height: 500), of: root)
        let find = TranscriptFocusAnchor.AnchorView.table(containing:in:)
        #expect(find(NSPoint(x: 400, y: 300), root) === transcript)
        #expect(find(NSPoint(x: 100, y: 300), root) === sidebar)
        #expect(find(NSPoint(x: 400, y: 50), root) == nil, "the composer's strip, below the transcript")
    }

    @Test("a click inside the transcript hands focus from a text view to the table; outside it, or a drag that ends inside, doesn't")
    func handsFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        let transcript = table(in: NSRect(x: 200, y: 100, width: 600, height: 500), of: root)
        let anchor = TranscriptFocusAnchor.AnchorView(frame: NSRect(x: 200, y: 100, width: 600, height: 500))
        root.addSubview(anchor)
        let composer = NSTextView(frame: NSRect(x: 200, y: 0, width: 600, height: 80))
        root.addSubview(composer)
        #expect(window.makeFirstResponder(composer))
        func click(_ down: NSPoint, _ up: NSPoint) { anchor.mouseWentDown(at: down); anchor.focusTable(clickedAt: up) }
        click(NSPoint(x: 400, y: 50), NSPoint(x: 400, y: 50))
        #expect(window.firstResponder === composer, "a click in the composer leaves it focused")
        click(NSPoint(x: 400, y: 50), NSPoint(x: 400, y: 300))
        #expect(window.firstResponder === composer, "a drag from the composer that ends in the transcript isn't a click there")
        click(NSPoint(x: 400, y: 300), NSPoint(x: 400, y: 300))
        #expect(window.firstResponder === transcript)

        // A text field inside the transcript that the click focused keeps its focus.
        let field = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 30))
        transcript.addSubview(field)
        #expect(window.makeFirstResponder(field))
        click(NSPoint(x: 400, y: 300), NSPoint(x: 400, y: 300))
        #expect(window.firstResponder === field, "a row's own control isn't robbed of focus")
    }
}
