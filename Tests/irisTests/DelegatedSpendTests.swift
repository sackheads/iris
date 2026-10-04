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
    /// ("subagent role: **ROLE**"), an evaluator is the engine offered `submit_evaluation`, and
    /// anything else is the job run itself. Each queue replays in order and then answers with a
    /// usage-free text reply, so a straggling extra round costs nothing and the figures under test
    /// are exactly the scripted ones. Parent and subagents share one client, as `invoke_subagent`
    /// passes the parent engine's client through.
    final class RoutingClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [GeminiResponse]]
        private var calls: [String: Int] = [:]
        /// Parks a role's Nth call (1-based) until the test opens the gate.
        private let gates: [String: (call: Int, gate: JobSchedulerTests.Gate)]

        init(_ queues: [String: [GeminiResponse]],
             gates: [String: (call: Int, gate: JobSchedulerTests.Gate)] = [:]) {
            self.queues = queues
            self.gates = gates
        }

        static let parent = "PARENT"
        static let evaluator = "EVALUATOR"

        private func role(of request: GeminiRequest) -> String {
            if request.tools?.contains(where: { $0.functionDeclarations.contains { $0.name == "submit_evaluation" } }) == true {
                return Self.evaluator
            }
            let prompt = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            guard let range = prompt.range(of: "subagent role: **") else { return Self.parent }
            let rest = prompt[range.upperBound...]
            return String(rest.prefix { $0 != "*" })
        }

        private func next(for role: String) -> (GeminiResponse, Int) {
            lock.lock(); defer { lock.unlock() }
            calls[role, default: 0] += 1
            let n = calls[role]!
            if var queue = queues[role], !queue.isEmpty {
                let response = queue.removeFirst()
                queues[role] = queue
                return (response, n)
            }
            return (GeminiResponse(candidates: [Candidate(content: Content(
                role: "model", parts: [Part(text: "done")]))], usageMetadata: nil), n)
        }

        func callCount(_ role: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return calls[role] ?? 0
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let role = role(of: request)
            let (response, n) = next(for: role)
            if let parked = gates[role], parked.call == n { await parked.gate.arriveAndWait() }
            return response
        }
    }

    /// Records every figure a usage sink is handed.
    final class RecordingSink: TurnUsageSink, @unchecked Sendable {
        private let lock = NSLock()
        private var figures: [Int] = []
        var recorded: [Int] { lock.withLock { figures } }
        func record(_ tokens: TokenUsage) async {
            lock.withLock { figures.append(tokens.totalTokenCount) }
        }
    }

    private func usage(_ total: Int) -> UsageMetadata {
        UsageMetadata(promptTokenCount: total - 1, candidatesTokenCount: 1, totalTokenCount: total)
    }

    private func calls(_ list: [(String, [String: JSONValue])], total: Int) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: list.map { Part(functionCall: FunctionCall(name: $0.0, args: $0.1)) }))],
                       usageMetadata: usage(total))
    }

    private func text(_ text: String, total: Int) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: total > 0 ? usage(total) : nil)
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
        // 5c: weighted at the isolated config's provider (Gemini): 117 prompt + 3 output × 5.
        #expect(card.weightedTokens == 117 + 15)
        #expect(card.weightedTokens == CostWeights.weighted(run.components, provider: run.provider),
                "and the card's weighted figure is the row's, priced the same way")
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

    @Test("an evaluator grading a delegated unit is charged to the run")
    func evaluatorSpendIsCharged() async throws {
        let criteria: JSONValue = .array([.object(["text": .string("it is done"), "kind": .string("qualitative")])])
        let client = RoutingClient([
            RoutingClient.parent: [
                calls([("invoke_subagent", ["role": .string("worker"), "task": .string("Do it."),
                                            "effort": .string("easy"), "criteria": criteria])], total: 10),
                text("ok", total: 5)],
            "WORKER": [calls([finish("worked")], total: 100)],
            RoutingClient.evaluator: [calls([("submit_evaluation", ["evaluations": .array([])])], total: 900)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("graded")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(client.callCount(RoutingClient.evaluator) >= 1, "the unit was graded")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.totalTokens == 10 + 100 + 900 + 5)
    }

    // MARK: The budget bounds delegation

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
        #expect(run.failureReason == TurnBudget.weightedTokensExceeded)
        #expect(run.totalTokens == 110)
    }

    /// 5c decision 5, end to end: a subagent's cache-heavy round costs 10_010 raw tokens but
    /// 100 + 9_900 × 0.1 + 10 × 5 = 1_140 weighted on Anthropic, so a 5_000 budget lets the run go
    /// on. Counted raw, the subagent's second round would have been refused.
    @Test("a cache-heavy run is not stopped by a budget its raw total would have tripped")
    func cacheHeavySpendIsWeighted() async throws {
        let heavy = UsageMetadata(promptTokenCount: 10_000, candidatesTokenCount: 10, totalTokenCount: 10_010,
                                  cacheReadTokens: 9_900, cacheWriteTokens: 0)
        var probe = calls([("noop_probe", [:])], total: 0)
        probe.usageMetadata = heavy
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 10), text("all done", total: 5)],
            "WORKER": [probe, calls([finish("worked")], total: 1)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("cache-reader", perRunBudget: 5_000)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.primaryProvider = LLMProvider.anthropic.rawValue

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(client.callCount("WORKER") == 2, "the subagent's second round was not refused")
        #expect(client.callCount(RoutingClient.parent) == 2)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .completed)
        #expect(run.provider == "Anthropic")
        #expect(run.totalTokens > 5_000, "raw, it is over the budget")
        #expect(CostWeights.weighted(run.components, provider: run.provider) < 5_000)
    }

    @Test("a subagent whose own rounds spend the run's budget is refused its next round")
    func subagentIsStoppedAtTheRunBudget() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 10), text("never reached", total: 1)],
            "WORKER": [calls([("noop_probe", [:])], total: 120), calls([finish("worked")], total: 1)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("deep-spender", perRunBudget: 100)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(client.callCount("WORKER") == 1, "10 + 120 is past 100: the subagent makes no second call")
        #expect(client.callCount(RoutingClient.parent) == 1, "and neither does the run")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == TurnBudget.weightedTokensExceeded)
        #expect(run.totalTokens == 130, "the overrun is on the row")
    }

    @Test("a delegated round writes the run's total to its row before the run's next round")
    func delegatedRoundsReachTheRow() async throws {
        let gate = JobSchedulerTests.Gate()
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 10), text("all done", total: 5)],
            "WORKER": [calls([("noop_probe", [:])], total: 50), calls([finish("worked")], total: 1)],
        ], gates: ["WORKER": (call: 2, gate: gate)])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("meter")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        let jobRunner = runner(store, state, engine, config)
        let fire = Task { await jobRunner.fire(job: job, origin: .schedule) }
        await gate.waitForEntry()

        // Parked in the subagent's second call: the parent has made no round since delegating.
        let midRun = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(midRun.status == .running)
        #expect(midRun.totalTokens == 60, "the subagent's first round is on the row while it is still working")

        await gate.open()
        await fire.value
        let finished = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(finished.totalTokens == 66)
    }

    @Test("an attended conversation that delegates has no budget and no sink")
    func attendedDelegationIsUnchanged() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("worker")], total: 10), text("ok", total: 5)],
            "WORKER": [calls([("noop_probe", [:])], total: 10_000), calls([finish("worked")], total: 1)],
        ])
        let (store, state, engine) = try harness(client: client)
        let attended = try #require(state.selectedConversationId)

        await engine.processInput("Delegate it.", source: "UI", conversationId: attended)

        #expect(client.callCount("WORKER") == 2, "no budget stopped the subagent")
        #expect(state.runUsage(for: attended).totalTokenCount == 15,
                "an attended conversation is charged its own tokens only, as before")
        #expect(state.registeredRun(for: attended) == nil)
        #expect(try store.ledger.weightedTokensToday(jobId: nil, calendar: utc, now: Date()) == 0)
    }

    // MARK: After the run

    @Test("what a subagent spends after its run has ended is charged to nothing, and writes no row")
    func spendAfterTheRunIsNotCharged() async throws {
        let client = RoutingClient([
            "STRAGGLER": [calls([("noop_probe", [:])], total: 5_000), text("late", total: 0)],
        ])
        let (_, state, _) = try harness(client: client)
        let run = state.createNewConversation(isBackground: true, select: false)
        let sink = RecordingSink()
        state.registerRun(run, budget: TurnBudget(maxTokens: 100, deadline: Date().addingTimeInterval(600)),
                          sink: sink)
        let straggler = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(straggler, of: run)

        // The run ends: the same drain `JobRunner.readTurn` does.
        _ = state.takeBackgroundDenials(for: run)

        let engine = IrisEngine(state: state, tier: .easy, principal: .subagent, roleLabel: "straggler",
                                client: client, protectionEnabled: false, sessionPeerCount: 0)
        await engine.setSystemPrompt(text: SubagentManager.shared.generateRolePrompt(role: "straggler"))
        await engine.processInput("Keep going.", source: "System", conversationId: straggler)

        #expect(state.conversations.first { $0.id == straggler }?.tokenUsage.totalTokenCount == 5_000,
                "the straggler did spend")
        #expect(client.callCount("STRAGGLER") == 2, "and was not held to the ended run's budget")
        #expect(state.runUsage(for: run).totalTokenCount == 0, "none of it is charged to the run")
        #expect(sink.recorded.isEmpty, "and nothing is written to the run's row")
    }

    @Test("a grandchild spawned by a subagent that outlived its run accrues under no key")
    func orphanedGrandchildAccruesNowhere() throws {
        let (_, state, _) = try harness(client: RoutingClient([:]))
        let run = state.createNewConversation(isBackground: true, select: false)
        state.registerRun(run, budget: TurnBudget(maxTokens: 0, deadline: Date().addingTimeInterval(600)),
                          sink: RecordingSink())
        let child = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(child, of: run)
        _ = state.takeBackgroundDenials(for: run)

        // The lingering child delegates again, after the drain: it is its own root now.
        let grandchild = state.createNewConversation(isSubagent: true, isBackground: true, select: false)
        state.linkBackgroundDescendant(grandchild, of: child)
        state.updateTokenUsage(for: grandchild, usage: usage(700))

        #expect(state.runUsage(for: child).totalTokenCount == 0,
                "an unregistered root collects nothing, so there is no bucket left to leak")
        #expect(state.runUsage(for: run).totalTokenCount == 0)
    }

    // MARK: Background delegation

    @Test("an unattended run is refused background delegation; it would outlive the run's budget")
    func backgroundDelegationIsRefusedUnattended() async throws {
        let client = RoutingClient([
            RoutingClient.parent: [calls([delegate("straggler", background: true)], total: 30),
                                   text("ok", total: 20)],
            "STRAGGLER": [calls([finish("late")], total: 5_000)],
        ])
        let (store, state, engine) = try harness(client: client)
        let job = self.job("tries-background")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        await runner(store, state, engine, config).fire(job: job, origin: .schedule)

        #expect(client.callCount("STRAGGLER") == 0, "no subagent was spawned")
        #expect(!state.conversations.contains { $0.title == "Subagent: straggler" })
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let transcript = try #require(state.conversations.first { $0.id == run.transcriptConversationId })
        let results = transcript.history.flatMap(\.parts).compactMap(\.functionResponse)
        #expect(results.contains { $0.response.values.contains { $0.stringValue.contains(IrisEngine.unattendedBackgroundDelegationRefusal) } })
        #expect(run.totalTokens == 50)
    }

    // MARK: The day's budget

    @Test("the day's weighted tokens count delegated spend once: subagents have no run rows of their own")
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

        // Raw 120 = prompt 29 + 69 + 19 and output 3; weighted at the isolated config's provider
        // (Gemini, nothing cached): 117 + 3 × 5 = 132.
        #expect(try store.ledger.weightedTokensToday(jobId: job.id, calendar: utc, now: Date()) == 132)
        #expect(try store.ledger.weightedTokensToday(jobId: nil, calendar: utc, now: Date()) == 132,
                "the all-jobs sum sees the subagent's tokens once, on the run's row")
        let worker = try #require(state.conversations.first { $0.title == "Subagent: worker" })
        #expect(worker.tokenUsage.totalTokenCount == 70,
                "the subagent's own conversation still shows only its own spend")
    }
}
