import Testing
import Foundation
@testable import IrisKit

/// #960: persistent sidebar teams. A group is not a visual folder — it survives a relaunch
/// (Invariant 1: `decodeIfPresent` AND a `ConversationStore` column), and its members never
/// auto-archive on their own (see `AutoArchiveTests.teamMemberNeverAgesOut` for that half).
@MainActor
@Suite("Sidebar teams (#960)")
struct SidebarTeamsTests {
    private func app() -> AppState {
        let app = AppState(); app.conversations.removeAll()
        return app
    }

    // MARK: Persistence (Invariant 1)

    @Test("a group and a member's grouping survive a relaunch")
    func persistsAcrossRelaunch() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(select: false)
        let groupId = try #require(app.createSidebarGroup(name: "overseer team"))
        app.moveConversation(id, toGroup: groupId)
        app.flushSave()

        let groups = try store.loadSidebarGroups()
        #expect(groups == [SidebarGroup(id: groupId, name: "overseer team", position: 0)])
        let reloaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(reloaded.sidebarGroupId == groupId)
    }

    @Test("a conversation persisted before #960 decodes ungrouped")
    func legacyDecodesUngrouped() throws {
        let json = #"{"title":"old"}"#
        let c = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(c.sidebarGroupId == nil)
    }

    @Test("renaming and deleting a group persist, and deleting ungroups its members in the store too")
    func renameAndDeletePersist() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(select: false)
        let groupId = try #require(app.createSidebarGroup(name: "a"))
        app.moveConversation(id, toGroup: groupId)
        app.renameSidebarGroup(groupId, to: "b")
        app.flushSave()
        #expect(try store.loadSidebarGroups().first?.name == "b")

        app.deleteSidebarGroup(groupId)
        app.flushSave()
        #expect(try store.loadSidebarGroups().isEmpty)
        let reloaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(reloaded.sidebarGroupId == nil)
    }

    @Test("#1281 review: a conversation whose group row is gone is reconciled on load, not left invisible and sweep-exempt forever")
    func danglingGroupReconciledOnLoad() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(select: false)
        let groupId = try #require(app.createSidebarGroup(name: "team"))
        app.moveConversation(id, toGroup: groupId)
        app.flushSave()

        // Only the group row is gone — not through deleteSidebarGroup, which would have ungrouped
        // the member too. This is what a quit between the in-memory ungroup and the row delete, or
        // an unreadable group row loadSidebarGroups skipped, leaves behind.
        try store.deleteSidebarGroup(id: groupId)

        let reloaded = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        #expect(reloaded.conversations.first { $0.id == id }?.sidebarGroupId == nil, "the dangling reference is cleared")
        #expect(SidebarOrdering.ungrouped(reloaded.conversations).contains { $0.id == id }, "visible again, not lost between both lists")

        reloaded.flushSave()
        let persisted = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(persisted.sidebarGroupId == nil, "the repair is persisted, not just in memory")
    }

    @Test("#1281 review, round 2: a groups read that fails as a whole does not ungroup anyone")
    func groupsReadFailureDoesNotUngroup() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let id = app.createNewConversation(select: false)
        let groupId = try #require(app.createSidebarGroup(name: "team"))
        app.moveConversation(id, toGroup: groupId)
        app.flushSave()

        try store.rawWrite("DROP TABLE sidebar_groups")

        let reloaded = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        #expect(reloaded.conversations.first { $0.id == id }?.sidebarGroupId == groupId,
               "a read that fails as a whole must not be mistaken for \"no groups\" and ungroup the member")
        #expect(reloaded.sidebarGroups.isEmpty)
    }

    // MARK: Live mechanism: reorder and move, driven through AppState

    @Test("drag-reordering a team's members persists the new order through a reload")
    func reorderConversationsPersists() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let groupId = try #require(app.createSidebarGroup(name: "team"))
        let a = app.createNewConversation(title: "a", select: false)
        let b = app.createNewConversation(title: "b", select: false)
        let c = app.createNewConversation(title: "c", select: false)
        for id in [a, b, c] { app.moveConversation(id, toGroup: groupId) }

        app.reorderConversations([c, a, b], within: groupId)
        let members = SidebarOrdering.teams(app.conversations, groups: app.sidebarGroups).first?.members.map(\.id)
        #expect(members == [c, a, b])

        app.flushSave()
        let reloadedOrder = try store.loadAll().conversations.filter { [a, b, c].contains($0.id) }.map(\.id)
        #expect(reloadedOrder == [c, a, b], "position must have been persisted, not just reordered in memory")
    }

    @Test("reordering refuses a list that is not exactly the bucket's current members")
    func reorderRefusesPartialOrWrongBucket() throws {
        let app = app()
        let groupId = try #require(app.createSidebarGroup(name: "team"))
        let a = app.createNewConversation(select: false)
        let b = app.createNewConversation(select: false)
        app.moveConversation(a, toGroup: groupId)
        app.moveConversation(b, toGroup: groupId)

        // Partial list: refused, order unchanged.
        app.reorderConversations([a], within: groupId)
        #expect(SidebarOrdering.teams(app.conversations, groups: app.sidebarGroups).first?.members.map(\.id) == [a, b])

        // An id from the wrong bucket: refused.
        let outsider = app.createNewConversation(select: false)
        app.reorderConversations([a, b, outsider], within: groupId)
        #expect(SidebarOrdering.teams(app.conversations, groups: app.sidebarGroups).first?.members.map(\.id) == [a, b])
    }

    @Test("dragging a conversation between a team and the ungrouped list moves it there and nowhere else")
    func moveConversationBetweenBuckets() throws {
        let app = app()
        let teamA = try #require(app.createSidebarGroup(name: "a"))
        let teamB = try #require(app.createSidebarGroup(name: "b"))
        let id = app.createNewConversation(select: false)
        #expect(SidebarOrdering.ungrouped(app.conversations).contains { $0.id == id })

        app.moveConversation(id, toGroup: teamA)
        #expect(!SidebarOrdering.ungrouped(app.conversations).contains { $0.id == id })
        #expect(SidebarOrdering.teams(app.conversations, groups: app.sidebarGroups).first { $0.group.id == teamA }?.members.map(\.id) == [id])

        app.moveConversation(id, toGroup: teamB)
        #expect(SidebarOrdering.teams(app.conversations, groups: app.sidebarGroups).first { $0.group.id == teamA }?.members.isEmpty == true)
        #expect(SidebarOrdering.teams(app.conversations, groups: app.sidebarGroups).first { $0.group.id == teamB }?.members.map(\.id) == [id])

        app.moveConversation(id, toGroup: nil)
        #expect(SidebarOrdering.ungrouped(app.conversations).contains { $0.id == id })
    }

    @Test("a pinned conversation is never grouped")
    func pinnedNeverGrouped() throws {
        let app = app()
        let groupId = try #require(app.createSidebarGroup(name: "team"))
        let id = app.createNewConversation(select: false)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { Issue.record("missing"); return }
        app.conversations[idx].isPinned = true
        app.moveConversation(id, toGroup: groupId)
        #expect(app.conversations.first { $0.id == id }?.sidebarGroupId == nil, "pinned conversations refuse grouping")
    }

    @Test("reordering teams themselves persists the new order through a reload")
    func reorderGroupsPersists() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let a = try #require(app.createSidebarGroup(name: "a"))
        let b = try #require(app.createSidebarGroup(name: "b"))
        let c = try #require(app.createSidebarGroup(name: "c"))

        app.reorderSidebarGroups([c, a, b])
        #expect(app.sidebarGroups.map(\.id) == [c, a, b])

        app.flushSave()
        let reloaded = try store.loadSidebarGroups()
        #expect(reloaded.map(\.id) == [c, a, b])
    }

    @Test("an empty name creates nothing and renames nothing")
    func emptyNamesRefused() throws {
        let app = app()
        #expect(app.createSidebarGroup(name: "   ") == nil)
        let groupId = try #require(app.createSidebarGroup(name: "real"))
        app.renameSidebarGroup(groupId, to: "  ")
        #expect(app.sidebarGroups.first?.name == "real")
    }

    @Test("an empty group persists until explicitly deleted")
    func emptyGroupPersists() throws {
        let app = app()
        let groupId = try #require(app.createSidebarGroup(name: "empty team"))
        #expect(SidebarOrdering.teams(app.conversations, groups: app.sidebarGroups).contains { $0.group.id == groupId && $0.members.isEmpty })
        app.deleteSidebarGroup(groupId)
        #expect(!app.sidebarGroups.contains { $0.id == groupId })
    }
}
