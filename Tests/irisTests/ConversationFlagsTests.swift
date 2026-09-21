import Testing
import Foundation
@testable import iris

@Suite("Conversation flags: isBackground / isPinned")
struct ConversationFlagsTests {
    @Test("both flags round-trip through the store and default to false when absent")
    func roundTrip() throws {
        let store = try ConversationStore.inMemory()
        var a = Conversation(id: UUID(), title: "bg"); a.isBackground = true
        var b = Conversation(id: UUID(), title: "pin"); b.isPinned = true
        let c = Conversation(id: UUID(), title: "plain")
        for conv in [a, b, c] {
            var cs = ChangeSet(); cs.created = true; cs.metadata = true
            try store.apply([ConversationWrite(id: conv.id, snapshot: conv, changes: cs)])
        }
        let back = try store.loadAll().conversations
        #expect(back.first { $0.id == a.id }?.isBackground == true && back.first { $0.id == a.id }?.isPinned == false)
        #expect(back.first { $0.id == b.id }?.isPinned == true)
        #expect(back.first { $0.id == c.id }?.isBackground == false && back.first { $0.id == c.id }?.isPinned == false)
    }

    @Test("Conversation decodes with both flags false when the keys are absent")
    func lenientDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","messages":[],"history":[],"tokenUsage":{},"messageCountSinceReflection":0,"goalIterationCount":0}"#
        let conv = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(conv.isBackground == false && conv.isPinned == false)
    }

    @Test("sidebar ordering: pinned first, background and subagent hidden, archived separate")
    func ordering() {
        var p = Conversation(id: UUID(), title: "p"); p.isPinned = true
        var bg = Conversation(id: UUID(), title: "bg"); bg.isBackground = true
        var sub = Conversation(id: UUID(), title: "sub"); sub.isSubagent = true
        var arch = Conversation(id: UUID(), title: "arch"); arch.isArchived = true
        let x = Conversation(id: UUID(), title: "x"), y = Conversation(id: UUID(), title: "y")
        let all = [x, bg, arch, sub, p, y]
        #expect(SidebarOrdering.visible(all).map(\.title) == ["p", "x", "y"])
        #expect(SidebarOrdering.archived(all).map(\.title) == ["arch"])
    }

    @Test("meta get/set by key")
    func meta() throws {
        let store = try ConversationStore.inMemory()
        #expect(try store.metaValue(forKey: "k") == nil)
        try store.setMetaValue("v1", forKey: "k"); try store.setMetaValue("v2", forKey: "k")
        #expect(try store.metaValue(forKey: "k") == "v2")
    }

    @Test("activityConversationId creates once, pinned, unselected, and is stable across calls")
    @MainActor func activity() throws {
        let app = AppState()
        let before = app.selectedConversationId
        let id1 = app.activityConversationId()
        let id2 = app.activityConversationId()
        #expect(id1 == id2)
        let conv = app.conversations.first { $0.id == id1 }
        #expect(conv?.title == AppState.activityConversationTitle && conv?.isPinned == true && conv?.isBackground == false)
        #expect(app.selectedConversationId == before)
        #expect(try app.store.metaValue(forKey: AppState.activityConversationMetaKey) == id1.uuidString)
    }

    @Test("/clear refuses a pinned conversation and leaves its messages alone")
    @MainActor func clearRefused() {
        let app = AppState()
        let id = app.activityConversationId()
        app.appendMessage(role: .system, content: "keep me", to: id)
        #expect(app.clearRefusal(for: id) == .pinned)
        app.handleClearCommand(convId: id)
        #expect(app.conversations.first { $0.id == id }?.messages.contains { $0.content == "keep me" } == true)
    }
}
