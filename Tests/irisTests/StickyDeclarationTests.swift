import Testing
import Foundation
@testable import IrisKit

/// 5c §0.1: a state-gated tool, once declared, stays declared for the conversation, and a hard
/// strip (unattended turn, non-main principal) always wins over the sticky set.
///
/// Three layers keep a sticky name out of a turn that may not have it, and they overlap:
/// 1. `stickyApplies`: the set is read only on attended `.main` turns;
/// 2. each gate's own predicates (`principal == .main`, the unattended checks), plus the read-only
///    allowlist after them;
/// 3. the `hardStrip` call.
/// Deleting any one layer leaves every test here green. Each comment below says which layer, or
/// which combination, a test pins.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct StickyDeclarationTests {
    /// One turn through a real engine against a capturing client. Returns the declared names.
    private func names(_ app: AppState, _ id: UUID, prompt: String = "carry on",
                       principal: Principal = .main, factStore: FactStoreManager,
                       sticky: Bool = true) async -> [String] {
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], factStore: factStore, protectionEnabled: false,
                                sessionPeerCount: 0, stickyTools: sticky)
        await engine.processInput(prompt, source: "UI", conversationId: id)
        return client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
    }

    private func app() throws -> (AppState, UUID) {
        let app = AppState(store: try ConversationStore.inMemory())
        let id = UUID()
        app.createNewConversation(id: id)
        return (app, id)
    }

    /// Pins the gate's `|| sticky.contains("manage_fact")` clause and the recording after the strip.
    @Test func manageFactStaysAfterFactsStopSurfacing() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")
        #expect(await names(app, id, prompt: "Where does Brian live?", factStore: facts).contains("manage_fact"))
        #expect(await names(app, id, prompt: "What is two plus two?", factStore: facts).contains("manage_fact"))
        #expect(app.stickyTools.names(for: id).contains("manage_fact"))
    }

    /// Pins the `stickyTools:` init seam (`stickyToolsEnabled`, part of layer 1).
    @Test func switchedOffItFlapsAsBefore() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Brian lives in Seattle", entity: "Brian")
        _ = await names(app, id, prompt: "Where does Brian live?", factStore: facts, sticky: false)
        #expect(!(await names(app, id, prompt: "What is two plus two?", factStore: facts, sticky: false)).contains("manage_fact"))
    }

    /// Pins the sticky clauses on the amend, reach_checkpoint/delegate_milestone and goal_complete
    /// gates.
    @Test func ladderToolsStayAfterTheGoalEnds() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        let a = Criterion(text: "parser works", kind: .qualitative, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship the parser", criteria: [a, b])
        c.milestones = [Milestone(title: "Parser", criterionIds: [a.id]),
                        Milestone(title: "Integration", criterionIds: [b.id])]
        app.setGoalContract(for: id, c)
        let during = await names(app, id, factStore: facts)
        for n in ["amend_goal_contract", "reach_checkpoint", "delegate_milestone", "goal_complete"] {
            #expect(during.contains(n), Comment(rawValue: n))
        }
        app.clearGoal(for: id)
        let after = await names(app, id, factStore: facts)
        for n in ["amend_goal_contract", "reach_checkpoint", "delegate_milestone", "goal_complete"] {
            #expect(after.contains(n), Comment(rawValue: n))
        }
    }

    /// Review focus 1. A strip always wins over stickiness. No single layer is pinned here:
    /// - the read-only arm is held by layer 2's allowlist alone;
    /// - the mutating arm fails only with layers 1 and 3 both broken;
    /// - the subagent arm fails only with layers 1 and 3 broken and a gate's `principal == .main`
    ///   (layer 2) removed too.
    /// So deleting the `hardStrip` call alone leaves this green; `hardStripIsPure` pins the
    /// function, not its call site.
    @Test func stickyNeverSurvivesHardStrips() async throws {
        let all = StickyTools.eligible.union(["set_workspace", "schedule_job", "register_directory_watcher"])
        let facts = try FactStoreManager(inMemory: true)

        // Unattended: a background (job-run) conversation, read-only profile.
        let (bg, bgId) = try app()
        if let i = bg.conversations.firstIndex(where: { $0.id == bgId }) {
            bg.conversations[i].isBackground = true
            bg.conversations[i].jobProfile = .readOnly
        }
        bg.stickyTools.record(all, for: bgId)
        let unattended = await names(bg, bgId, factStore: facts)
        #expect(!unattended.isEmpty, "the turn must have sent a request")
        for n in IrisEngine.unattendedNeverDeclared { #expect(!unattended.contains(n), Comment(rawValue: n)) }
        for n in unattended {
            #expect(!JobProfile.readOnlyDenies(n, sandboxedRunCommand: false, readOnlyMCPTools: []),
                    Comment(rawValue: n))
        }

        // Unattended with a mutating profile: no read-only allowlist runs after the hard strip, so
        // this arm is the one that shows the strip itself holding.
        let (mut, mutId) = try app()
        if let i = mut.conversations.firstIndex(where: { $0.id == mutId }) {
            mut.conversations[i].isBackground = true
            mut.conversations[i].jobProfile = .mutating
        }
        mut.stickyTools.record(all, for: mutId)
        let mutating = await names(mut, mutId, factStore: facts)
        #expect(!mutating.isEmpty, "the turn must have sent a request")
        for n in IrisEngine.unattendedNeverDeclared { #expect(!mutating.contains(n), Comment(rawValue: n)) }
        #expect(mut.stickyTools.names(for: mutId) == StickyTools.eligible, "an unattended turn records nothing new")

        // A subagent principal: the main-only tools never appear, whatever the set says.
        let (sub, subId) = try app()
        sub.stickyTools.record(all, for: subId)
        let subNames = await names(sub, subId, principal: .subagent, factStore: facts)
        #expect(!subNames.isEmpty, "the turn must have sent a request")
        for n in IrisEngine.mainOnlyDeclared { #expect(!subNames.contains(n), Comment(rawValue: n)) }
    }

    /// Pins `hardStrip` itself (layer 3's function), not that the turn builder calls it.
    @Test func hardStripIsPure() {
        let decls = ["run_command", "set_workspace", "send_to_session", "schedule_job", "manage_fact", "reach_checkpoint"]
            .map { FunctionDeclaration(name: $0, description: $0, parameters: nil) }
        let unattended = IrisEngine.hardStrip(decls, isUnattended: true, principal: .main).map(\.name)
        #expect(unattended == ["run_command", "manage_fact", "reach_checkpoint"])
        let sub = IrisEngine.hardStrip(decls, isUnattended: false, principal: .subagent).map(\.name)
        // A subagent keeps set_workspace: that's today's behaviour, unchanged by hardStrip.
        #expect(sub == ["run_command", "set_workspace", "manage_fact"])
    }

    /// Pins plan note 5: the pinned-only job tools are outside `StickyTools.eligible`.
    @Test func jobToolsAreNotStickyAfterUnpin() async throws {
        let (app, id) = try app()
        let facts = try FactStoreManager(inMemory: true)
        if let i = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[i].isPinned = true }
        #expect(await names(app, id, factStore: facts).contains("list_jobs"))
        if let i = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[i].isPinned = false }
        #expect(!(await names(app, id, factStore: facts)).contains("list_jobs"))
    }
}
