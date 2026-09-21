import Testing
import Foundation
@testable import iris

/// #182 §6.2 — "archived means idle" has two directions. Work arriving is the second one.
@MainActor
@Suite("Un-archive on arriving work")
struct ArchiveUnarchiveOnWorkTests {

    private func archived(_ app: AppState) -> UUID {
        let id = UUID()
        app.createNewConversation(id: id)
        app.createNewConversation(id: UUID())   // so archiving does not trigger the replacement
        _ = app.archiveConversation(id)
        return id
    }

    @Test("sending a message un-archives the target before the turn starts")
    func sendUnarchives() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id

        app.sendMessage("hello")

        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
    }

    @Test("a slash command that starts no turn does not un-archive")
    func slashCommandDoesNotUnarchive() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id

        app.sendMessage("/tokens")

        #expect(app.conversations.first { $0.id == id }?.isArchived == true,
                "only the turn-starting path un-archives")
    }

    @Test("a system event un-archives its target conversation")
    func systemEventUnarchives() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.handleSystemEvent("Scheduled Job Triggered: do the thing",
                                       source: "Scheduler", conversationId: id)

        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
    }

    @Test("a system event with no conversation id un-archives the selected one")
    func systemEventWithoutIdUnarchivesSelection() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id      // the watcher's case: no id, falls back to selection
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.handleSystemEvent("File changed: notes.md", source: "Watcher")

        #expect(app.conversations.first { $0.id == id }?.isArchived == false,
                "the watcher passes no id, which is why the rule lives at the choke point")
    }

    @Test("/goal un-archives: the drafting turn is a turn, and it returns above sendMessage's tail")
    func goalCommandUnarchives() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id

        app.sendMessage("/goal build a snake game")

        #expect(app.conversations.first { $0.id == id }?.isArchived == false,
                "approving the draft would otherwise leave a goal loop running inside the archive")
    }

    @Test("the panel-approve kickoff un-archives its conversation")
    func goalKickoffUnarchives() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        let idx = app.conversations.firstIndex { $0.id == id }!
        app.conversations[idx].goalContract = GoalContract(
            objective: "ship it",
            criteria: [Criterion(text: "it ships", kind: .qualitative)])

        app.sendGoalKickoff(for: id)

        #expect(app.conversations.first { $0.id == id }?.isArchived == false,
                "GoalContractPanel calls this directly; it reaches neither old choke point")
    }

    @Test("an arrival's system line names the un-archive")
    func arrivalNamesTheUnarchive() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.handleSystemEvent("Scheduled Job Triggered: do the thing",
                                       source: "Scheduler", conversationId: id)

        let line = app.conversations.first { $0.id == id }?.messages
            .first { $0.role == .system && $0.content.contains("Scheduled Job Triggered") }
        #expect(line?.content.contains("Un-archived") == true,
                "the row reappears while the user is elsewhere; the line has to say so")
        #expect(line?.content.contains("Scheduled Job Triggered: do the thing") == true)
    }

    @Test("an arrival into a conversation that was never archived says nothing about archiving")
    func arrivalIntoActiveIsSilent() async {
        let app = AppState(); app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.handleSystemEvent("File changed: notes.md", source: "FileWatcher",
                                       conversationId: id)

        let messages = app.conversations.first { $0.id == id }?.messages ?? []
        #expect(messages.contains { $0.content.contains("Un-archived") } == false)
    }

    @Test("an arrival un-archive does not move selection")
    func arrivalDoesNotMoveSelection() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        let reading = UUID()
        app.createNewConversation(id: reading)
        app.selectedConversationId = reading
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient(responses: []))

        await engine.handleSystemEvent("Background subagent result:\nok",
                                       source: "SubagentManager", conversationId: id)

        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
        #expect(app.selectedConversationId == reading,
                "resurfacing a row is not a reason to yank the user out of what they are reading")
    }

    // MARK: - The refusal must see engine-started turns (#182 §6.1)

    private func textResponse(_ text: String) -> GeminiResponse {
        let part = Part(text: text, functionCall: nil, functionResponse: nil,
                        thought_signature: nil, thoughtSignature: nil)
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                              usageMetadata: nil)
    }

    /// Waits for `hasTurnInFlight` to go true, yielding the MainActor so the engine's turn can
    /// make progress. Bounded so a regression fails the test instead of hanging the suite.
    private func awaitTurnInFlight(_ app: AppState, _ id: UUID) async -> Bool {
        for _ in 0..<400 {
            if app.hasTurnInFlight(for: id) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// The gap this closes: a scheduled job, a watcher event or a subagent post-back runs through
    /// `IrisEngine.processInput` directly, which registers nothing in `activeTasks`. Before the
    /// fix `archiveRefusal` returned nil throughout such a turn, so the Archive menu item was
    /// enabled and `/archive` succeeded — the agent kept executing inside a collapsed section,
    /// which is exactly what §6.1 exists to prevent.
    @Test("an arrival turn in flight refuses the archive")
    func arrivalTurnRefusesArchive() async {
        let app = AppState(); app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        app.createNewConversation(id: UUID())   // so a successful archive would not spawn a replacement
        // No goal: the refusal's other condition cannot cover for a missing in-flight signal.
        #expect(app.conversations.first { $0.id == id }?.activeGoal == nil)

        // Latency holds the turn open long enough to observe it from the outside.
        let client = FakeLLMClient(responses: [textResponse("working on it")],
                                   latency: .init(minMs: 300, maxMs: 300))
        let engine = IrisEngine(state: app, tier: .medium, client: client)
        let turn = Task { await engine.handleSystemEvent("Scheduled Job Triggered: do the thing",
                                                         source: "Scheduler", conversationId: id) }

        #expect(await awaitTurnInFlight(app, id), "the engine's own turn has to be visible per conversation")
        #expect(app.archiveRefusal(for: id) == .turnInFlight)
        #expect(app.archiveConversation(id) == .turnInFlight)
        #expect(app.conversations.first { $0.id == id }?.isArchived == false,
                "the agent must not end up running tools inside a collapsed section")

        await turn.value

        // And the refusal clears, so the turn cannot leave the conversation un-archivable.
        #expect(app.hasTurnInFlight(for: id) == false)
        #expect(app.archiveRefusal(for: id) == nil)
        #expect(app.archiveConversation(id) == nil)
        #expect(app.conversations.first { $0.id == id }?.isArchived == true)
    }

    /// Re-entrancy: the counter, not a flag. Two overlapping turns on one conversation, and the
    /// first end must not clear the second's registration.
    @Test("overlapping engine turns keep the refusal until the last one ends")
    func overlappingEngineTurnsAreCounted() {
        let app = AppState(); app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        app.createNewConversation(id: UUID())

        app.beginEngineTurn(for: id)
        app.beginEngineTurn(for: id)
        app.endEngineTurn(for: id)
        #expect(app.hasTurnInFlight(for: id), "the second turn is still running")
        #expect(app.archiveConversation(id) == .turnInFlight)

        app.endEngineTurn(for: id)
        #expect(app.hasTurnInFlight(for: id) == false)
        #expect(app.archiveConversation(id) == nil)
    }
}
