import Testing
import Foundation
import Observation
@testable import IrisKit

/// #466: the sidebar's "needs you" mark. The rules are `NeedsHuman.derive`'s; `AppState.needsHuman`
/// must follow the state exactly, and change only when attention does, never per streamed token.
@MainActor
@Suite("Needs you (#466)", .timeLimit(.minutes(1)))
struct NeedsHumanTests {
    private func conversation(_ title: String = "c", pinned: Bool = false, archived: Bool = false,
                              background: Bool = false, contract: GoalContract? = nil) -> Conversation {
        var c = Conversation(id: UUID(), title: title)
        c.isPinned = pinned
        c.isArchived = archived
        c.isBackground = background
        c.goalContract = contract
        return c
    }

    private func blocked(_ job: String, destination: UUID? = nil, refused: Bool = false) -> LedgerAttention.Blocked {
        LedgerAttention.Blocked(runId: UUID(), jobId: UUID(), jobName: job, tool: "write_file",
                                refusedByProfile: refused, destinationConversationId: destination)
    }

    // MARK: the rules

    @Test("an approval marks the conversation it is charged to, and nothing hidden or archived is marked")
    func approvals() {
        let main = conversation("main"), archived = conversation(archived: true), hidden = conversation(background: true)
        let marks = NeedsHuman.derive(
            asks: [.init(root: main.id, toolName: "write_file"), .init(root: archived.id, toolName: "x"),
                   .init(root: hidden.id, toolName: "x"), .init(root: nil, toolName: "x")],
            conversations: [main, archived, hidden], blocked: [], pinnedId: nil)
        #expect(marks == [main.id: "approval: write_file"])
    }

    @Test("each goal wait marks its conversation, with the same phrase the session listing uses")
    func goalWaits() {
        var draft = GoalContract(objective: "o", criteria: [])
        draft.state = .draft
        var paused = GoalContract(objective: "o", criteria: [])
        paused.lock()
        paused.checkpointStatus = .pausedForReview
        var judge = GoalContract(objective: "o", criteria: [])
        judge.lock()
        judge.awaitingHumanJudgement = true
        var running = GoalContract(objective: "o", criteria: [])
        running.lock()
        let a = conversation(contract: draft), b = conversation(contract: paused),
            c = conversation(contract: judge), d = conversation(contract: running)
        let marks = NeedsHuman.derive(asks: [], conversations: [a, b, c, d], blocked: [], pinnedId: nil)
        #expect(marks == [a.id: "goal contract to review", b.id: "checkpoint review", c.id: "goal judgement"])
    }

    @Test("a blocked run marks its card's conversation: the destination, else the pinned Iris, else no row at all")
    func blockedRuns() {
        let iris = conversation("Iris", pinned: true), dest = conversation("dest"), gone = conversation(archived: true)
        let all = [iris, dest, gone]
        #expect(NeedsHuman.derive(asks: [], conversations: all, blocked: [blocked("j", destination: dest.id)],
                                  pinnedId: iris.id) == [dest.id: "blocked run: j"])
        #expect(NeedsHuman.derive(asks: [], conversations: all, blocked: [blocked("j")],
                                  pinnedId: iris.id) == [iris.id: "blocked run: j"])
        #expect(NeedsHuman.derive(asks: [], conversations: all, blocked: [blocked("j", destination: gone.id)],
                                  pinnedId: iris.id) == [iris.id: "blocked run: j"], "an archived destination falls back")
        #expect(NeedsHuman.derive(asks: [], conversations: all, blocked: [blocked("j", refused: true)],
                                  pinnedId: iris.id) == [iris.id: "refused by profile: j"])
        // No pinned Iris and no destination: the status menu still lists it, the sidebar marks nothing.
        #expect(NeedsHuman.derive(asks: [], conversations: [dest], blocked: [blocked("j")], pinnedId: nil).isEmpty)
    }

    @Test("an approval's reason wins a conversation's mark over a goal wait and a blocked run")
    func precedence() {
        var paused = GoalContract(objective: "o", criteria: [])
        paused.lock()
        paused.checkpointStatus = .pausedForReview
        let iris = conversation("Iris", pinned: true, contract: paused)
        let marks = NeedsHuman.derive(asks: [.init(root: iris.id, toolName: "run_command")], conversations: [iris],
                                      blocked: [blocked("j")], pinnedId: iris.id)
        #expect(marks == [iris.id: "approval: run_command"])
    }

    // MARK: AppState follows the state exactly

    private func makeApp() throws -> (ConversationStore, AppState) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                           createIfEmpty: false, emitLaunchNotices: false)
        return (store, app)
    }

    @Test("a goal wait marks the row the moment it is raised and clears the moment the person answers it")
    func goalWaitFollowsState() throws {
        let (_, app) = try makeApp()
        let id = app.createNewConversation(select: false)
        #expect(app.needsHuman[id] == nil)
        var contract = GoalContract(objective: "o", criteria: [])
        contract.lock()
        app.setGoalContract(for: id, contract)
        app.setCheckpointPaused(for: id)
        #expect(app.needsHuman[id] == "checkpoint review")
        app.holdCheckpoint(for: id, feedback: nil)
        #expect(app.needsHuman[id] == nil, "Send back answers it")
    }

    @Test("a blocked run marks the pinned Iris row, and acknowledging it clears the mark")
    func blockedRunFollowsLedger() async throws {
        let (store, app) = try makeApp()
        let iris = app.createNewConversation(select: false)
        if let i = app.conversations.firstIndex(where: { $0.id == iris }) { app.conversations[i].isPinned = true }
        let job = Job(name: "writer", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Date())
        try store.ledger.begin(run: run)
        try store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil, failureReason: nil,
                                blockedTool: "write_file", tokens: TokenUsage(), finishedAt: Date())
        try await value(of: app.refreshLedgerAttention())
        #expect(app.needsHuman[iris] == "blocked run: writer")

        try store.ledger.acknowledge(runId: run.id, at: Date())
        try await value(of: app.refreshLedgerAttention())
        #expect(app.needsHuman[iris] == nil)
    }

    // MARK: cost (#583)

    /// Whether `body` fires an observation of `read`.
    private func fires(_ read: @escaping () -> Void, after body: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var set = false }
        let flag = Flag()
        withObservationTracking(read) { flag.set = true }
        body()
        return flag.set
    }

    @Test("a streamed token, and a conversation write that changes no wait, never touch the mark")
    func tokensChangeNothing() throws {
        let (_, app) = try makeApp()
        let id = app.createNewConversation(select: false)
        let message = UUID()
        app.appendMessage(role: .agent, content: "Hel", id: message, to: id)
        #expect(!fires({ _ = app.needsHuman }) {
            app.updateMessageContent(id: message, content: "Hello wor", in: id, persist: false)
        }, "a streamed token")
        #expect(!fires({ _ = app.needsHuman }) {
            app.updateConversationTitle(id: id, title: "renamed")
        }, "a write that changes no wait")
    }

    @Test("an unchanged ledger snapshot is not reassigned, so nothing reading it re-renders")
    func unchangedSnapshotIsNotAssigned() async throws {
        let (_, app) = try makeApp()
        try await value(of: app.refreshLedgerAttention())
        final class Flag: @unchecked Sendable { var set = false }
        let fired = Flag()
        withObservationTracking({ _ = app.ledgerAttention }) { fired.set = true }
        try await value(of: app.refreshLedgerAttention())
        #expect(!fired.set)
    }
}
