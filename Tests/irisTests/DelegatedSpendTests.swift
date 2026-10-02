import Testing
import Foundation
@testable import iris

/// #313 — a job run is charged for what its delegated subagents spend while the run is active,
/// recursively, and for nothing they spend after it has ended. Before this, subagents accrued
/// usage only on their own conversations, so the run row, the mid-run `TurnBudget` check and the
/// day's `tokensToday` all missed delegated spend.
@MainActor
@Suite("Delegated spend is charged to the run (#313)")
struct DelegatedSpendTests {

    // MARK: Fixtures

    /// Routes each model call by who is asking: a subagent's system prompt names its role
    /// ("subagent role: **ROLE**"), the job run's does not. Each queue replays in order and then
    /// answers with a usage-free text reply, so a straggling extra round costs nothing and the
    /// figures under test are exactly the scripted ones. Parent and subagents share one client,
    /// as `invoke_subagent` passes the parent engine's client through.
    final class RoutingClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [GeminiResponse]]
        private(set) var calls: [String: Int] = [:]
        /// Parks the first call for a role until the test opens it.
        private let gates: [String: JobSchedulerTests.Gate]

        init(_ queues: [String: [GeminiResponse]], gates: [String: JobSchedulerTests.Gate] = [:]) {
            self.queues = queues
            self.gates = gates
        }

        static let parent = "PARENT"

        private func role(of request: GeminiRequest) -> String {
            let prompt = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            guard let range = prompt.range(of: "subagent role: **") else { return Self.parent }
            let rest = prompt[range.upperBound...]
            return String(rest.prefix { $0 != "*" })
        }

        private func next(for role: String) -> (GeminiResponse, Bool) {
            lock.lock(); defer { lock.unlock() }
            calls[role, default: 0] += 1
            let first = calls[role] == 1
            if var queue = queues[role], !queue.isEmpty {
                let response = queue.removeFirst()
                queues[role] = queue
                return (response, first)
            }
            return (GeminiResponse(candidates: [Candidate(content: Content(
                role: "model", parts: [Part(text: "done")]))], usageMetadata: nil), first)
        }

        func callCount(_ role: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return calls[role] ?? 0
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let role = role(of: request)
            let (response, first) = next(for: role)
            if first, let gate = gates[role] { await gate.arriveAndWait() }
            return response
        }
    }

    private func usage(_ total: Int) -> UsageMetadata {
        UsageMetadata(promptTokenCount: total - 1, candidatesTokenCount: 1, totalTokenCount: total)
    }

    private func call(_ name: String, _ args: [String: JSONValue], total: Int) -> GeminiResponse {
        calls([(name, args)], total: total)
    }

    private func calls(_ list: [(String, [String: JSONValue])], total: Int) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: list.map { Part(functionCall: FunctionCall(name: $0.0, args: $0.1)) }))],
                       usageMetadata: usage(total))
    }

    private func text(_ text: String, total: Int) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: usage(total))
    }

    private func delegate(_ role: String, background: Bool = false) -> (String, [String: JSONValue]) {
        var args: [String: JSONValue] = ["role": .string(role), "task": .string("Do the \(role) part."),
                                         "effort": .string("easy")]
        if background { args["background"] = .string("true") }
        return ("invoke_subagent", args)
    }

    private func finish(_ summary: String) -> (String, [String: JSONValue]) {
        ("goal_complete", ["summary": .string(summary)])
    }

    private func harness(client: any LLMClientProtocol)
        throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let conversation = UUID()
        state.createNewConversation(id: conversation)
        state.selectedConversationId = conversation
        return (store, state, IrisEngine(state: state, tier: .medium, client: client,
                                         protectionEnabled: false, sessionPeerCount: 0))
    }

    /// A settings store of this suite's own (AGENTS invariant 7).
    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-delegatedspend-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    /// `mutating`, with a VM to run in: a read-only job refuses delegation outright (#187 §0.2).
    private func job(_ name: String, perRunBudget: Int? = nil) -> Job {
        var job = Job(name: name, prompt: "Work.", trigger: .schedule(.interval(seconds: 60)),
                      profile: .mutating)
        if let perRunBudget { job.policy.perRunTokenBudget = perRunBudget }
        return job
    }

    private func runner(_ store: ConversationStore, _ state: AppState, _ engine: IrisEngine,
                        _ config: ConfigManager) -> JobRunner {
        JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                  config: config, activity: RecordingActivity(), sandboxAvailable: { true })
    }

    private let utc = Calendar(identifier: .gregorian)

    // MARK: The run row

    @Test("a run that delegates records its own tokens plus the subagent's")
    func rowIncludesSubagentSpend() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 30), text("all done", total: 20)],
            "WORKER": [calls([finish("worked")], total: 70)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("delegator")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(client.callCount("WORKER") >= 1, "the subagent actually ran")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .completed)
        #expect(run.totalTokens == 30 + 70 + 20)
        #expect(run.promptTokens == 29 + 69 + 19)
        #expect(run.candidateTokens == 3)
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.totalTokens == 120, "the card shows the same figure as the row")
    }

    @Test("parallel subagents in one tool batch are each charged once")
    func parallelSubagentsAllCount() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("alpha"), delegate("beta")], total: 10), text("ok", total: 5)],
            "ALPHA": [calls([finish("a")], total: 100)],
            "BETA": [calls([finish("b")], total: 1_000)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("fan-out")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.totalTokens == 10 + 100 + 1_000 + 5)
    }

    @Test("nested delegation counts: a subagent's own subagent is charged to the run")
    func nestedDelegationCounts() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("outer")], total: 10), text("ok", total: 5)],
            "OUTER": [calls([delegate("inner")], total: 200), calls([finish("outer done")], total: 300)],
            "INNER": [calls([finish("inner done")], total: 4_000)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("nested")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(client.callCount("INNER") >= 1, "the grandchild actually ran")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.totalTokens == 10 + 200 + 4_000 + 300 + 5)
    }

    // MARK: The mid-run budget

    @Test("the per-run budget trips on parent + subagent, though neither alone reaches it")
    func budgetCountsDelegatedSpend() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 40), text("never reached", total: 1)],
            "WORKER": [calls([finish("worked")], total: 70)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("overspender", perRunBudget: 100)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(client.callCount(RoutingClient.parent) == 1,
                "40 + 70 is past 100, so the parent makes no second model call")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == TurnBudget.tokensExceeded)
        #expect(run.totalTokens == 110)
    }

    // MARK: After the run

    @Test("what a subagent spends after its run has ended is not charged to that run")
    func spendAfterTheRunIsNotCharged() async throws {
        let gate = JobSchedulerTests.Gate()
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("straggler", background: true)], total: 30),
                                   text("left it running", total: 20)],
            "STRAGGLER": [calls([finish("late")], total: 5_000)],
        ], gates: ["STRAGGLER": gate])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("leaves-a-straggler")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status != .running, "the run is over")
        #expect(run.totalTokens == 50)

        // Now the straggler spends, after the run has been closed.
        await gate.waitForEntry()
        await gate.open()
        let straggler = try #require(state.conversations.first { $0.title == "Subagent: straggler" })
        for _ in 0..<200 {
            if state.conversations.first(where: { $0.id == straggler.id })?.tokenUsage.totalTokenCount == 5_000 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(state.conversations.first { $0.id == straggler.id }?.tokenUsage.totalTokenCount == 5_000,
                "the straggler did spend")
        #expect(state.runUsage(for: run.transcriptConversationId!).totalTokenCount ==
                state.conversations.first { $0.id == run.transcriptConversationId }?.tokenUsage.totalTokenCount,
                "nothing delegated is left accruing against the ended run")
        let after = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(after.totalTokens == 50)
        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: utc, now: Date()) == 50)
    }

    // MARK: The day's budget

    @Test("tokensToday counts delegated spend once: subagents have no run rows of their own")
    func noDoubleCountingInTokensToday() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 30), text("all done", total: 20)],
            "WORKER": [calls([finish("worked")], total: 70)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("counted-once")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(try store.ledger.tokensToday(jobId: job.id, calendar: utc, now: Date()) == 120)
        #expect(try store.ledger.tokensToday(jobId: nil, calendar: utc, now: Date()) == 120,
                "the all-jobs sum sees the subagent's tokens once, on the run's row")
        let worker = try #require(state.conversations.first { $0.title == "Subagent: worker" })
        #expect(worker.tokenUsage.totalTokenCount == 70,
                "the subagent's own conversation still shows only its own spend")
    }
}
