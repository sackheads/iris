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

    @Test("assigning a held role moves it, clears the old holder's skills, and tells it")
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
        let lines = app.takePendingEventLines(for: a)
        #expect(lines.contains { $0.contains("planner") && $0.contains("no longer") })
        #expect(lines.contains { $0.contains("(\"new-planner\")") }, "the new holder's card name is quoted, like renderPeerList")
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
        SessionRoles.normalize(&all)
        #expect(all[0].role == nil && all[1].role == "planner")
        #expect(all[0].sessionCard?.skills.isEmpty == true)
        #expect(all[2].role == nil && all[3].role == nil)
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
