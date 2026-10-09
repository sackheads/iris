import Testing
import Foundation
@testable import IrisKit

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
                           declareStateGatedTools: Bool = false,
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
                                factStore: factStore, sessionPeerCount: 0,
                                declareStateGatedTools: declareStateGatedTools)
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
        // #187 §0.5, invariant 6: search_conversations and read_conversation (like list_jobs/
        // get_job_run before them) are declared only in the pinned conversation, so a plain,
        // unpinned turn's count must not grow when either is added.
        #expect(!names.contains("search_conversations"))
        #expect(!names.contains("read_conversation"))
        #expect(!names.contains("list_jobs"))
        #expect(!names.contains("get_job_run"))
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

    /// 5a's tool-list experiment (spec §0.6): with the switch on, `manage_fact` is declared even on
    /// a turn that surfaced no facts, so a perf run can compare flapping against a stable list.
    /// The switch defaults off, so the turn above (no facts, no switch) proves normal use is unchanged.
    @Test("the tool-list experiment declares manage_fact on a turn with no facts")
    func experimentDeclaresStateGatedTools() async throws {
        let names = await toolNames(prompt: "Where does Brian live?", factStore: try FactStoreManager(inMemory: true),
                                    declareStateGatedTools: true)
        #expect(names.contains("manage_fact"))
    }

    /// The peer tools are state-gated too (spec §0.6): they appear whenever another session
    /// starts. Under the switch they are declared with the peer count pinned to 0, and the turn
    /// context still carries no Active Sessions line, since there are no peers to count.
    @Test("the tool-list experiment declares the peer tools with no peers, without an Active Sessions block")
    func experimentDeclaresPeerTools() async throws {
        let peerTools = ["list_sessions", "send_to_session", "set_session_card"]
        let gated = await toolNames(prompt: "hello", factStore: try FactStoreManager(inMemory: true))
        for name in peerTools { #expect(!gated.contains(name), Comment(rawValue: name)) }

        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                factStore: try FactStoreManager(inMemory: true), sessionPeerCount: 0,
                                declareStateGatedTools: true)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let request = try #require(client.requests.first)
        let names = request.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        for name in peerTools { #expect(names.contains(name), Comment(rawValue: name)) }
        let text = request.contents.flatMap(\.parts).compactMap(\.text).joined()
        #expect(!text.contains("Active Sessions"))
    }

    @Test("the experiment declares no peer tools to a subagent")
    func experimentPeerToolsMainOnly() async throws {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: .subagent, client: client, retryDelays: [],
                                factStore: try FactStoreManager(inMemory: true), sessionPeerCount: 0,
                                declareStateGatedTools: true)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let names = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        #expect(!names.contains("list_sessions"))
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

    /// 5b: the pinned conversation is exempt from rename on every path (spec §0.2), so a
    /// rename-trigger turn sent into it must not even declare the tool — invariant 6's "undeclared
    /// is the cheap half" for a tool a pinned turn may never use.
    @Test("rename_conversation is never declared on a rename-trigger turn in the pinned conversation")
    func renameNotDeclaredWhenPinned() async {
        let prompt = IrisEngine.renameTriggerPrefix + ": Evaluate the conversation history and use the `rename_conversation` tool to assign a short, descriptive title."
        let unpinned = await toolNames(prompt: prompt)
        #expect(unpinned.contains("rename_conversation"), "control: the declaration is normally offered on this trigger")

        let pinned = await toolNames(prompt: prompt) { app, id in
            guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
            app.conversations[idx].isPinned = true
        }
        #expect(!pinned.contains("rename_conversation"))
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
        #expect(!mem.contains("search_conversations"), "the pointer to the pinned-only tools costs every other turn's tokens for nothing (invariant 6)")

        // The watch declaration was two sentences (#187 deliverable 4, spec §5): what it does and
        // that its own writes are safe. The built-in ignore set, the ceiling and the
        // never-concurrent rule are said in the tool's result, not paid for on every turn. A third,
        // short sentence was added in the final-review fix wave (#187) — the same one-line approval
        // note `schedule_job`'s description carries — so the cap moved from 230 to 300 rather than
        // dropping the note; the ignore/ceiling/never-concurrent detail still stays out.
        let watch = try #require(decls["register_directory_watcher"])
        #expect(watch.count <= 300)
        #expect(watch.contains("quiet"))
        #expect(watch.contains("own file-tool writes"))
        #expect(watch.contains("asks the user"))
        #expect(!watch.contains(".git"))
    }

    /// Review, invariant 6: the pointer from `search_memory` to `search_conversations` and
    /// `read_conversation` is only true in the pinned conversation — those two tools are declared
    /// nowhere else (`jobToolDeclarations`). An unpinned model told to use them would try a tool it
    /// does not have.
    @Test("search_memory's description points to search_conversations only when pinned")
    func searchMemoryPointerOnlyWhenPinned() async {
        let capture = CapturingLLMClient(reply: "ok")
        let app = AppState(); let id = UUID(); app.createNewConversation(id: id)
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].isPinned = true
        }
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: capture, retryDelays: [],
                                sessionPeerCount: 0)
        await engine.processInput("hello", source: "UI", conversationId: id)
        let mem = capture.requests.first?.tools?.flatMap { $0.functionDeclarations }
            .first { $0.name == "search_memory" }?.description ?? ""
        #expect(mem.contains("search_conversations"))
        #expect(mem.contains("read_conversation"))
    }

    @Test("the shipped steering says an explicit request to remember is stored now, not at reflection")
    func steeringStoresOnRequest() {
        let steering = SystemSteering.shipped()
        #expect(steering.contains("asks you to remember"))
        #expect(steering.contains("store it now"))
    }

    // MARK: inlineDeclaredToolNames is exhaustive (#343)

    /// `IrisEngine.inlineDeclaredToolNames` is spelled out by hand (the same tradeoff as
    /// `toolsThatWriteNoPath` beside it), and `Briefing`/`DailyDigest` trust `allDeclaredToolNames`
    /// — which is built FROM it — to recognise a real tool name rather than reporting a model's
    /// well-formed but nonexistent call as a genuine block. A name missing from the set only
    /// under-reports (a real block prints as plain "blocked"), which fails safe, but it is still a
    /// defect worth catching before it ships.
    ///
    /// This drives a turn through every state that unlocks an inline declaration, unions the
    /// observed tool names, subtracts what `ToolExecutor` and `jobToolDeclarations` contribute
    /// (neither is part of this hand-maintained set — see the comment above
    /// `inlineDeclaredToolNames`), and asserts what's left is exactly the set. Remove any one name
    /// from `inlineDeclaredToolNames` by hand to see this fail — that's the "forgot to add it"
    /// case, reproduced.
    ///
    /// A new inline gate needs BOTH a set entry and a state line in this test that actually
    /// drives a turn through it — this test can only catch a mismatch between the two. A
    /// declaration added with neither (the "forgot both" case) is invisible to it: nothing here
    /// observes the new name, so there is nothing to compare against the set.
    @Test("inlineDeclaredToolNames covers every inline FunctionDeclaration the engine can produce")
    func inlineDeclaredToolNamesIsExhaustive() async throws {
        var observed: Set<String> = []

        // Plain turn: every unconditionally-appended inline declaration, plus set_workspace and
        // schedule_job (both gated on attended + main only, which a plain turn satisfies).
        observed.formUnion(await toolNames(prompt: "hello", factStore: try FactStoreManager(inMemory: true)))

        // manage_fact needs a surfaced fact.
        let factsStore = try FactStoreManager(inMemory: true)
        try factsStore.addFact(content: "Brian lives in Seattle", entity: "Brian")
        observed.formUnion(await toolNames(prompt: "Where does Brian live?", factStore: factsStore))

        // goal_complete needs an active goal.
        observed.formUnion(await toolNames(prompt: "carry on") { app, id in
            guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
            app.conversations[idx].activeGoal = "ship it"
        })

        // rename_conversation needs the rename-trigger prefix on an unpinned conversation.
        observed.formUnion(await toolNames(prompt: IrisEngine.renameTriggerPrefix + ": title it"))

        // propose_goal_contract needs the goal-draft trigger prefix.
        observed.formUnion(await toolNames(prompt: IrisEngine.goalDraftTriggerPrefix + ": draft it"))

        // amend_goal_contract needs a locked contract with no ladder.
        observed.formUnion(await toolNames(prompt: "carry on") { app, id in
            guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
            var contract = GoalContract(objective: "ship", criteria: [])
            contract.lock()
            app.conversations[idx].goalContract = contract
        })

        // reach_checkpoint / delegate_milestone need an active, non-final ladder checkpoint.
        observed.formUnion(await toolNames(prompt: "carry on") { app, id in
            guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
            var contract = GoalContract(objective: "ship", criteria: [])
            contract.milestones = [Milestone(title: "one", criterionIds: []),
                                   Milestone(title: "two", criterionIds: [])]
            contract.currentMilestone = 0
            contract.lock()
            app.conversations[idx].goalContract = contract
        })

        // waive_criterion needs a locked contract with at least one failed gate attempt.
        observed.formUnion(await toolNames(prompt: "carry on") { app, id in
            guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
            var contract = GoalContract(objective: "ship", criteria: [])
            contract.lock()
            contract.gateAttempts = 1
            app.conversations[idx].goalContract = contract
        })

        // list_sessions / send_to_session / set_session_card need a peer — the shared `toolNames`
        // helper pins `sessionPeerCount` to 0, so this one state is built by hand.
        do {
            let app = AppState()
            let id = UUID()
            app.createNewConversation(id: id)
            let client = CapturingLLMClient(reply: "ok")
            let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                    factStore: try FactStoreManager(inMemory: true), sessionPeerCount: 1)
            await engine.processInput("hello", source: "UI", conversationId: id)
            observed.formUnion(client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
        }

        // Subtract the two OTHER sources of declared tool names — this test is only about the
        // hand-maintained inline set, not the whole declared surface.
        let executorNames = Set(await ToolExecutor.shared.getTools(workspaceToolsEnabled: true).map(\.name))
        let jobToolNames = Set(IrisEngine.jobToolDeclarations(isPinned: true).map(\.name))
        let inlineObserved = observed.subtracting(executorNames).subtracting(jobToolNames)

        let missing = inlineObserved.subtracting(IrisEngine.inlineDeclaredToolNames)
        #expect(missing.isEmpty, "declared inline but missing from inlineDeclaredToolNames: \(missing)")

        // Coverage, so a broken state-setup above (one that stops exercising a tool at all) fails
        // loudly rather than letting the subset check above pass vacuously.
        #expect(inlineObserved == IrisEngine.inlineDeclaredToolNames,
                "observed \(inlineObserved.sorted()), expected \(IrisEngine.inlineDeclaredToolNames.sorted())")
    }
}
