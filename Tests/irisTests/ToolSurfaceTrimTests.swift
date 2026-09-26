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
                           factStore: FactStoreManager? = nil,
                           prepare: (AppState, UUID) -> Void = { _, _ in }) async -> [String] {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        prepare(app, id)
        let client = CapturingLLMClient(reply: "ok")
        // `AppState()` auto-creates a blank conversation when its store is empty (or loads
        // whatever is already on disk), so this harness always has a second conversation besides
        // the one just created — #185's session-tools gate would see a peer and this suite's
        // counts predate that feature entirely. Pin it off; this suite is not testing sessions.
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                factStore: factStore, sessionPeerCount: 0)
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
    func plainTurn() async throws {
        let names = await toolNames(prompt: "What is the capital of Australia?",
                                    factStore: try FactStoreManager(inMemory: true))
        for name in Self.googleTools { #expect(!names.contains(name), Comment(rawValue: name)) }
        #expect(!names.contains("propose_goal_contract"))
        #expect(!names.contains("amend_goal_contract"))
        #expect(names.contains("run_command"))
        #expect(names.count <= 18, "expected the plain-turn surface to shrink from 30; got \(names.count): \(names)")
    }

    /// #168: `manage_fact` needs a fact id, and the only ids the model sees come from the facts
    /// injected into the turn. A turn that surfaced none must not carry the declaration.
    @Test("manage_fact is offered only on a turn that surfaced facts")
    func manageFactGatedOnInjectedFacts() async throws {
        let store = try FactStoreManager(inMemory: true)
        let empty = await toolNames(prompt: "Where does Brian live?", factStore: store)
        #expect(!empty.contains("manage_fact"))

        try store.addFact(content: "Brian lives in Seattle", entity: "Brian")
        let withFacts = await toolNames(prompt: "Where does Brian live?", factStore: store)
        #expect(withFacts.contains("manage_fact"))
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

    /// #133 slice 2: the second eagerness set traced every remaining unprompted or missed call to
    /// a description that either invited a call on a mention or failed to invite one on a request.
    @Test("tool descriptions state when to call, not just what the tool is (#133 slice 2)")
    func descriptionsStateTriggers() async throws {
        let names = await toolNames(prompt: "hello")
        _ = names
        let capture = CapturingLLMClient(reply: "ok")
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: capture, retryDelays: [])
        await engine.processInput("hello", source: "UI", conversationId: id)
        let decls = Dictionary(uniqueKeysWithValues: (capture.requests.first?.tools?.flatMap { $0.functionDeclarations } ?? []).map { ($0.name, $0.description) })

        let ws = decls["set_workspace"] ?? ""
        #expect(ws.contains("explicitly asks"))
        #expect(!ws.contains("when the user says they are working"))
        #expect(ws.contains("mentioned in passing"))

        let fact = decls["save_fact"] ?? ""
        #expect(fact.contains("asked you to remember"))
        #expect(!fact.contains("Continuously groom"))

        let profile = decls["update_user_profile"] ?? ""
        #expect(profile.contains("asks you to remember"))
        #expect(profile.contains("keeping its existing content"))

        let job = decls["schedule_job"] ?? ""
        #expect(job.contains("asks to be reminded"))
        #expect(job.contains("Never use shell cron"))
        #expect(job.contains("intervalSeconds"), "the parameter rules stay")
        #expect(job.contains("unless the job was created with a grant that covers it"))
        #expect(!job.contains("stops and says so."), "the old absolute sentence is gone")

        let mem = decls["search_memory"] ?? ""
        #expect(mem.contains("not present in the current context"))
        #expect(!mem.contains("JIT injection"))

        // The watch declaration is two sentences (#187 deliverable 4, spec §5): what it does and
        // that its own writes are safe. The built-in ignore set, the ceiling and the
        // never-concurrent rule are said in the tool's result, not paid for on every turn.
        let watch = try #require(decls["register_directory_watcher"])
        #expect(watch.count <= 230)
        #expect(watch.contains("quiet"))
        #expect(watch.contains("own file-tool writes"))
        #expect(!watch.contains(".git"))
    }

    @Test("the shipped steering says an explicit request to remember is stored now, not at reflection")
    func steeringStoresOnRequest() {
        let steering = SystemSteering.shipped()
        #expect(steering.contains("asks you to remember"))
        #expect(steering.contains("store it now"))
    }
}
