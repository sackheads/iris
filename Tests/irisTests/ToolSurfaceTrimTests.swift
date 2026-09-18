import Testing
import Foundation
@testable import iris

/// A plain chat turn sent 30 tool declarations, about 3,100 prompt tokens (61 % of the request).
/// Slice one of #133 removes the ones that cannot do anything on a plain turn: the Google
/// Workspace tools when no refresh token is configured, and the goal-contract tools outside the
/// goal-draft turn / a locked contract.
@MainActor
@Suite("tool surface trim (#133)")
struct ToolSurfaceTrimTests {
    static let googleTools = ["google_tasks_list_tasklists", "google_tasks_list_tasks", "google_tasks_create_task",
                              "google_calendar_list_events", "google_calendar_create_event", "google_docs_get",
                              "google_drive_search", "google_sheets_get", "gmail_list_unread", "gmail_send_email"]

    /// Drive one turn through a real engine against a capturing client and return the declared tool names.
    private func toolNames(prompt: String, source: String = "UI",
                           prepare: (AppState, UUID) -> Void = { _, _ in }) async -> [String] {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        prepare(app, id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [])
        await engine.processInput(prompt, source: source, conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    @Test("ToolExecutor omits the Google Workspace tools unless a refresh token is configured")
    func googleToolsGatedOnCredentials() async {
        let without = await ToolExecutor.shared.getTools(workspaceToolsEnabled: false).map(\.name)
        let with = await ToolExecutor.shared.getTools(workspaceToolsEnabled: true).map(\.name)
        for name in Self.googleTools {
            #expect(!without.contains(name), Comment(rawValue: name))
            #expect(with.contains(name), Comment(rawValue: name))
        }
        #expect(without.contains("run_command") && with.contains("run_command"))
    }

    @Test("a plain turn in a test process (no refresh token) carries no Google or goal-contract tools")
    func plainTurn() async {
        let names = await toolNames(prompt: "What is the capital of Australia?")
        for name in Self.googleTools { #expect(!names.contains(name), Comment(rawValue: name)) }
        #expect(!names.contains("propose_goal_contract"))
        #expect(!names.contains("amend_goal_contract"))
        #expect(names.contains("run_command"))
        #expect(names.count <= 18, "expected the plain-turn surface to shrink from 30; got \(names.count): \(names)")
    }

    @Test("the goal-draft trigger turn offers propose_goal_contract")
    func goalDraftTurnOffersPropose() async {
        let prompt = "System Event [Goal Contract Draft]: The user wants to start a goal loop with this goal: \"ship it\".\n\nBefore starting the loop, use the `propose_goal_contract` tool to draft a structured contract."
        let names = await toolNames(prompt: prompt, source: "System")
        #expect(names.contains("propose_goal_contract"))
    }

    @Test("amend_goal_contract is offered only while a locked contract exists")
    func amendOnlyWhenLocked() async {
        let locked = await toolNames(prompt: "carry on") { app, id in
            guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
            var contract = GoalContract(objective: "ship", criteria: [])
            contract.lock()
            app.conversations[idx].goalContract = contract
        }
        #expect(locked.contains("amend_goal_contract"))

        let draft = await toolNames(prompt: "carry on") { app, id in
            guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
            app.conversations[idx].goalContract = GoalContract(objective: "ship", criteria: [])
        }
        #expect(!draft.contains("amend_goal_contract"))
    }
}
