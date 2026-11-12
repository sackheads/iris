import Testing
import Foundation
@testable import IrisKit

/// #1066 Phase 2, Task 1: an external MCP guest's session is a new kind of `Conversation`:
/// ephemeral (never persisted), hidden (never user-facing, never selectable), and addressable by
/// another session only as the target of a reply. Nothing here gives a guest a tool or a turn; it is
/// the kind and where the kind is filtered.
@MainActor
@Suite("Guest conversation kind (#1066)")
struct GuestConversationTests {
    private func guest(_ clientId: String = "dev-1") -> Conversation {
        var c = Conversation(id: UUID(), title: "Guest")
        c.isGuest = true
        c.guestClientId = clientId
        return c
    }

    @Test("a guest is neither user-facing nor selectable, and is a reply target; the other kinds keep their meaning")
    func kindPredicates() {
        let g = guest()
        #expect(!g.isUserFacing)
        #expect(!g.isSelectable)
        #expect(g.isReplyTarget)

        let normal = Conversation(id: UUID(), title: "n")
        #expect(normal.isUserFacing && normal.isSelectable && normal.isReplyTarget)
        var sub = Conversation(id: UUID(), title: "s"); sub.isSubagent = true
        var bg = Conversation(id: UUID(), title: "b"); bg.isBackground = true
        #expect(!sub.isReplyTarget && !bg.isReplyTarget, "only a guest widens reply targeting")
    }

    @Test("a guest is never persisted: durableConversations drops it, and a flush writes no row for it")
    func neverPersisted() throws {
        let g = guest()
        let normal = Conversation(id: UUID(), title: "main")
        #expect(AppState.durableConversations([normal, g]).map(\.id) == [normal.id])

        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let keep = app.createNewConversation(title: "keeper")
        let guestId = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        app.flushSave()
        let saved = try store.loadAll().conversations.map(\.id)
        #expect(saved.contains(keep))
        #expect(!saved.contains(guestId), "a guest row on disk would outlive its token and its TTL")
    }

    @Test("isGuest and guestClientId are never encoded, and a row without them decodes as a normal conversation")
    func codableExcludesGuestFields() throws {
        let data = try JSONEncoder().encode(guest("dev-1"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["isGuest"] == nil && json["guestClientId"] == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("dev-1"), "the client id must not reach a persisted blob")

        // A row written before this change (no such keys) still decodes, as a normal conversation.
        var old = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Conversation(id: UUID(), title: "old"))) as? [String: Any])
        old.removeValue(forKey: "isGuest"); old.removeValue(forKey: "guestClientId")
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(!decoded.isGuest && decoded.guestClientId == nil)
        // And a round trip of a guest comes back as a normal conversation: the kind does not survive a restart.
        let roundTrip = try JSONDecoder().decode(Conversation.self, from: data)
        #expect(!roundTrip.isGuest && roundTrip.guestClientId == nil)
    }

    @Test("createNewConversation makes a guest unselected, profile-less and stamped, and a non-guest ignores the client id")
    func creation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1066-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = AgentProfileStore(paths: IrisPaths(root: root))
        try FileManager.default.createDirectory(at: profiles.directory, withIntermediateDirectories: true)
        try Data("---\nrole: reviewer\n---\nYou review pull requests.\n".utf8)
            .write(to: profiles.directory.appendingPathComponent("reviewer.md"))
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.agentProfiles = profiles
        // The fixture is real: the same profile applies to a normal conversation.
        let normal = app.createNewConversation(title: "normal", agentProfile: "reviewer")
        #expect(app.conversations.first { $0.id == normal }?.agentProfile != nil)
        app.conversations.removeAll()
        let open = app.createNewConversation(title: "open")
        app.selectedConversationId = open
        let id = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest", agentProfile: "reviewer")
        let g = app.conversations.first { $0.id == id }
        #expect(g?.isGuest == true && g?.guestClientId == "dev-1")
        #expect(g?.agentProfile == nil, "a guest never runs under an agent profile")
        #expect(app.selectedConversationId == open, "creating a guest must not steal the person's selection")
        let plain = app.createNewConversation(guestClientId: "dev-1", title: "plain")
        #expect(app.conversations.first { $0.id == plain }?.guestClientId == nil)
    }

    @Test("a guest is not addressable: resolve by id says inactive, and it is in no peer or role listing")
    func notAddressable() {
        let app = AppState(); app.conversations.removeAll()
        let me = app.createNewConversation(title: "me")
        let id = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        #expect(SessionDirectory.resolve(id.uuidString, in: app.conversations, excluding: me) == .failure(.inactive))
        #expect(!SessionDirectory.peers(in: app.conversations, excluding: me, busy: { _ in false }).peers.contains { $0.id == id })
        #expect(!SessionDirectory.activePeers(in: app.conversations, excluding: me).contains { $0.id == id })
        #expect(SessionRoles.holder(of: "reviewer", in: app.conversations) == nil)
    }

    @Test("an idle sweep never archives a guest, even one that carries a card and a stale touch time")
    func sweepSkipsGuests() {
        let app = AppState(); app.conversations.removeAll()
        _ = app.activityConversationId()
        app.createNewConversation(title: "open")
        let id = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest", select: false)
        app.setSessionCard(for: id, SessionCard(name: "guest", description: "x", lane: nil, skills: []))
        let now = Date()
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].lastTouchedAt = now.addingTimeInterval(-30 * 86_400)
        }
        #expect(app.sweepIdleSessions(days: 14, now: now).isEmpty)
        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
    }

    @Test("a guest cannot host a loop")
    func loopRefused() {
        let app = AppState(); app.conversations.removeAll()
        let id = app.createNewConversation(isGuest: true, guestClientId: "dev-1", title: "guest")
        let conv = app.conversations.first { $0.id == id }!
        #expect(app.loopRefusal(conv) != nil)
    }
}
