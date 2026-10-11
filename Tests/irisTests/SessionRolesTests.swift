import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Session roles", .timeLimit(.minutes(1)))
struct SessionRolesTests {
    private func app(_ ids: [UUID]) -> AppState {
        let app = AppState(); app.conversations.removeAll()
        for id in ids { app.createNewConversation(id: id) }
        return app
    }

    @Test("role names are lowercased and restricted; reserved names refused")
    func names() {
        #expect(SessionRoles.normalizedName("PR-Minder") == "pr-minder")
        #expect(SessionRoles.normalizedName("  planner ") == "planner")
        #expect(SessionRoles.normalizedName("pr minder") == nil)
        #expect(SessionRoles.normalizedName("-x") == nil)
        #expect(SessionRoles.normalizedName(String(repeating: "a", count: 33)) == nil)
        #expect(SessionRoles.normalizedName("iris") == nil)
        #expect(SessionRoles.normalizedName("clear") == nil)
    }

    /// #480 review item 2: one canonicalizer for the uniqueness check AND `name:` resolution —
    /// both go through `sessions(named:)`, so proving the clash here also proves `name:` would
    /// resolve the look-alike to the same session.
    @Test("a look-alike quote and a hidden zero-width space both clash with the plain name")
    func canonicalNameClash() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        app.setSessionCard(for: a, SessionCard(name: "O\"Brien", description: "x"))
        // `O"Brien` (ASCII double quote) vs `O'Brien` (apostrophe): `flattenCardField` maps `"`
        // to `'` for both, so the canonical keys match.
        #expect(SessionRoles.sessions(named: "O'Brien", in: app.conversations, excluding: b) == [a])

        app.setSessionCard(for: b, SessionCard(name: "swift\u{200B}worker", description: "x"))
        // U+200B ZERO WIDTH SPACE is category Cf; stripped, "swift\u{200B}worker" canonicalizes
        // to the same key as "swiftworker".
        #expect(SessionRoles.sessions(named: "swiftworker", in: app.conversations, excluding: a) == [b])
    }

    @Test("name: resolves a card with a look-alike quote to a single session")
    func nameResolvesCanonical() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        app.setSessionCard(for: a, SessionCard(name: "O\"Brien", description: "x"))
        #expect(SessionDirectory.resolve("name:o'brien", in: app.conversations, excluding: b) == .success(a))
    }

    /// Routed like `closeRequestsToGone`/`deliverEvent`: the queue `takePendingEventLines` reads
    /// only drains at the destination's next model round, so an idle previous holder — the usual
    /// case — would never see a line left only there. It must land in the transcript and
    /// straight into history instead.
    @Test("assigning a held role moves it, clears the old holder's skills, and tells it via history, not only the queue")
    func moveRole() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        #expect(app.assignRole("planner", to: a) == .assigned(role: "planner", movedFrom: nil))
        app.setSessionCard(for: a, SessionCard(name: "p", description: "d",
                                               skills: [AgentSkill(id: "s", name: "S", description: "")]))
        app.setSessionCard(for: b, SessionCard(name: "new-planner", description: "d2"))
        #expect(app.assignRole("planner", to: b) == .assigned(role: "planner", movedFrom: a))
        let old = app.conversations.first { $0.id == a }!
        #expect(old.role == nil)
        #expect(old.sessionCard?.skills.isEmpty == true)
        #expect(app.conversations.first { $0.id == b }?.role == "planner")
        #expect(app.takePendingEventLines(for: a).isEmpty, "an idle old holder must not need its next turn to see this")
        let messages = old.messages
        #expect(messages.contains { $0.role == .system && $0.content.contains("planner") && $0.content.contains("no longer") })
        let history = old.history.flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
        #expect(history.contains("planner") && history.contains("no longer"),
                "an idle old holder gets the line straight into history")
        #expect(history.contains("(\"new-planner\")"), "the new holder's card name is quoted, like renderPeerList")
    }

    @Test("assigning a held role queues the notice for a BUSY old holder's own turn instead")
    func moveRoleQueuesForBusyHolder() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        #expect(app.assignRole("planner", to: a) == .assigned(role: "planner", movedFrom: nil))
        app.beginEngineTurn(for: a)
        #expect(app.assignRole("planner", to: b) == .assigned(role: "planner", movedFrom: a))
        let old = app.conversations.first { $0.id == a }!
        #expect(old.messages.contains { $0.role == .system && $0.content.contains("planner") },
                "the transcript line is unconditional, busy or not")
        #expect(old.history.isEmpty, "must not cut into the running turn's history")
        #expect(app.takePendingEventLines(for: a).contains { $0.contains("planner") && $0.contains("no longer") })
    }

    @Test("a session's own skills do not survive it being moved to a different role")
    func ownRoleChangeClearsSkills() {
        let a = UUID()
        let app = app([a])
        _ = app.assignRole("scout", to: a)
        app.setSessionCard(for: a, SessionCard(name: "a", description: "d",
                                               skills: [AgentSkill(id: "s", name: "S", description: "")]))
        #expect(app.assignRole("lookout", to: a) == .assigned(role: "lookout", movedFrom: nil))
        let c = app.conversations.first { $0.id == a }!
        #expect(c.role == "lookout")
        #expect(c.sessionCard?.skills.isEmpty == true)
    }

    @Test("the pinned Iris cannot hold a role")
    func pinnedRefused() {
        let a = UUID()
        let app = app([a])
        app.conversations[0].isPinned = true
        guard case .refused = app.assignRole("planner", to: a) else { Issue.record("expected refusal"); return }
        #expect(app.conversations[0].role == nil)
    }

    @Test("archiving a role-holder is refused until the role is released")
    func archiveRefused() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        _ = app.assignRole("overseer", to: a)
        #expect(app.archiveConversation(a) == .holdsRole("overseer"))
        #expect(app.clearRole(for: a) == "overseer")
        #expect(app.archiveConversation(a) == nil)
    }

    @Test("load-time normalization keeps one holder per role, the most recently updated, and clears the loser's skills")
    func normalize() {
        var older = Conversation(title: "old"); older.role = "planner"; older.updatedAt = Date(timeIntervalSince1970: 1)
        older.sessionCard = SessionCard(name: "o", description: "d", skills: [AgentSkill(id: "s", name: "S", description: "")])
        var newer = Conversation(title: "new"); newer.role = "planner"; newer.updatedAt = Date(timeIntervalSince1970: 2)
        var archived = Conversation(title: "arch"); archived.role = "bug-minder"; archived.isArchived = true
        var pinned = Conversation(title: "Iris"); pinned.role = "x"; pinned.isPinned = true
        var all = [older, newer, archived, pinned]
        let changed = SessionRoles.normalize(&all)
        #expect(all[0].role == nil && all[1].role == "planner")
        #expect(all[0].sessionCard?.skills.isEmpty == true)
        #expect(all[2].role == nil && all[3].role == nil)
        // #480 review item 5: the load path needs this set back to `markChanged` the ids it
        // repaired, so the store stays in sync with what the in-memory array now says.
        #expect(changed == [older.id, archived.id, pinned.id])
    }

    /// #480 review item 5. Two conversations with the SAME role are written straight to the
    /// store — bypassing `assignRole`, which never allows this — the way a duplicate could reach
    /// disk from an old build or a hand edit. `sanitizeLoaded` already repaired this in memory
    /// before #480; the bug was that the repair stopped there; the loser's stale role was never
    /// written back, so it could resurface the duplicate at the very next launch.
    @Test("a duplicate role persisted to the store is repaired on load, and the repair reaches disk")
    func loadRepairsDuplicateRoleOnDisk() throws {
        let store = try ConversationStore.inMemory()
        var older = Conversation(id: UUID(), title: "o"); older.role = "overseer"
        older.updatedAt = Date(timeIntervalSince1970: 1)
        var newer = Conversation(id: UUID(), title: "n"); newer.role = "overseer"
        newer.updatedAt = Date(timeIntervalSince1970: 2)
        func created(_ c: Conversation) -> ConversationWrite {
            var s = ChangeSet(); s.add(.created)
            return ConversationWrite(id: c.id, snapshot: c, changes: s)
        }
        try store.apply([created(older), created(newer)])

        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        #expect(app.conversations.first { $0.id == older.id }?.role == nil, "repaired in memory on load")
        app.flushSave()

        let rows = try store.loadAll().conversations
        #expect(rows.first { $0.id == older.id }?.role == nil, "and the repair reached disk")
        #expect(rows.first { $0.id == newer.id }?.role == "overseer", "the more recently updated holder keeps it")
    }

    @Test("a role loaded from the store that doesn't normalize to itself is cleared, with its skills")
    func normalizeInvalidRoleCharset() {
        var bad = Conversation(title: "b"); bad.role = "Not Valid!"
        bad.sessionCard = SessionCard(name: "b", description: "d", skills: [AgentSkill(id: "s", name: "S", description: "")])
        var all = [bad]
        SessionRoles.normalize(&all)
        #expect(all[0].role == nil)
        #expect(all[0].sessionCard?.skills.isEmpty == true)
    }

    private func lastSystemLine(_ app: AppState, _ id: UUID) -> String {
        app.conversations.first { $0.id == id }?.messages.last?.content ?? ""
    }

    @Test("/role assigns, reports, and clears")
    func roleCommand() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        app.selectedConversationId = a
        app.sendMessage("/role")
        #expect(lastSystemLine(app, a).contains("No role"))
        app.sendMessage("/role Planner")
        #expect(app.conversations.first { $0.id == a }?.role == "planner")
        #expect(lastSystemLine(app, a).contains("planner"))
        app.selectedConversationId = b
        app.sendMessage("/role planner")
        #expect(lastSystemLine(app, b).contains("moved from"))
        app.sendMessage("/role clear")
        #expect(app.conversations.first { $0.id == b }?.role == nil)
    }

    @Test("/role in Iris refuses")
    func roleInIris() {
        let a = UUID()
        let app = app([a])
        app.conversations[0].isPinned = true
        app.selectedConversationId = a
        app.sendMessage("/role planner")
        #expect(app.conversations[0].role == nil)
        #expect(lastSystemLine(app, a).contains("Iris can't hold a role"))
    }
}
