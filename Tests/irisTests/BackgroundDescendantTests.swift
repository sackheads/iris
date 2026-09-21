import Testing
import Foundation
@testable import iris

/// Fail-closed has to hold for everything a background run spawns, not just the run itself
/// (#187). A subagent used to be created `isBackground: false` whatever its parent was, so a job
/// run could delegate its way to `autoApproveTools` → Vibecop → a modal dialog nobody is there to
/// answer: either a local model approving a mutating command unattended, or a run parked forever.
@MainActor
@Suite("A descendant of a background run is background too")
struct BackgroundDescendantTests {

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func callResponse(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    /// Unique and inert by construction, so no allowlist on the machine running this can already
    /// hold it and a regression cannot run anything destructive.
    private var gatedCommand: String { "true --never-run-\(UUID().uuidString)" }

    @Test("a subagent spawned by a background run is background, and its denial lands on the run")
    func subagentInheritsBackground() async throws {
        let app = AppState()
        let parent = app.createNewConversation(isBackground: true, select: false)
        let client = FakeLLMClient(responses: [
            callResponse("run_command", ["command": .string(gatedCommand)]),
            callResponse("goal_complete", ["summary": .string("I could not do that.")]),
        ])

        let result = await SubagentManager.shared.runSubagent(
            role: "worker", task: "do the thing", effort: "easy",
            parentConversationId: parent, client: client, appState: app)
        #expect(result.status == .completed)

        let subagent = try #require(app.conversations.first { $0.isSubagent })
        #expect(subagent.isBackground, "a subagent of an unattended run is unattended too")
        #expect(app.pendingApprovals.isEmpty, "nothing may park on a dialog nobody is watching")

        // Recorded against the run, not the scratch conversation the run delegated into: the
        // ledger row and the card belong to the job.
        #expect(app.takeBackgroundDenials(for: subagent.id).isEmpty)
        let denials = app.takeBackgroundDenials(for: parent)
        #expect(denials.count == 1)
        #expect(denials.first?.toolName == "run_command")
    }

    @Test("a subagent of a foreground conversation is unchanged")
    func subagentOfForegroundIsForeground() async throws {
        let app = AppState()
        app.autoApproveTools = true
        let parent = app.createNewConversation(select: false)
        let client = FakeLLMClient(responses: [callResponse("goal_complete", ["summary": .string("done")])])

        _ = await SubagentManager.shared.runSubagent(
            role: "worker", task: "do the thing", effort: "easy",
            parentConversationId: parent, client: client, appState: app)

        let subagent = try #require(app.conversations.first { $0.isSubagent })
        #expect(!subagent.isBackground)
    }

    /// `GoalEvaluator` deletes its conversation as soon as it has graded, so the only moment the
    /// flag can be read is from inside the grader's own turn.
    private final class ProbingGrader: LLMClientProtocol, @unchecked Sendable {
        private let probe: @Sendable () async -> Bool?
        private let response: GeminiResponse
        private let lock = NSLock()
        private var seen: Bool??
        init(response: GeminiResponse, probe: @escaping @Sendable () async -> Bool?) {
            self.response = response
            self.probe = probe
        }
        var evaluatorWasBackground: Bool? { lock.withLock { seen ?? nil } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let observed = await probe()
            lock.withLock { if seen == nil { seen = observed } }
            return response
        }
    }

    @Test("the evaluator a background run triggers is background too")
    func evaluatorInheritsBackground() async throws {
        let app = AppState()
        let origin = app.createNewConversation(isBackground: true, select: false)
        let criterion = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let submit = callResponse("submit_evaluation", ["evaluations": .array([
            .object(["criterion_id": .string(criterion.id.uuidString),
                     "verdict": .string("met"), "evidence": .string("it does")])
        ])])
        let client = ProbingGrader(response: submit) {
            await MainActor.run { app.conversations.first { $0.title.hasPrefix("Evaluator") }?.isBackground }
        }

        _ = await GoalEvaluator.shared.evaluate(
            contract: GoalContract(objective: "obj", criteria: [criterion]),
            workspace: FileManager.default.currentDirectoryPath,
            originatingConversationId: origin, app: app, client: client)

        #expect(client.evaluatorWasBackground == true)
    }

    @Test("a job run that delegates a gated tool is blocked on approval, and the card names it")
    func delegatedDenialBlocksTheRun() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let userConversation = UUID()
        state.createNewConversation(id: userConversation)
        state.selectedConversationId = userConversation

        let client = FakeLLMClient(responses: [
            // The run delegates …
            callResponse("invoke_subagent", ["role": .string("worker"), "task": .string("clean up"),
                                             "effort": .string("easy")]),
            // … the subagent reaches for a gated tool and is refused …
            callResponse("run_command", ["command": .string(gatedCommand)]),
            callResponse("goal_complete", ["summary": .string("I could not do that.")]),
            // … and the run reports back.
            textResponse("the worker was blocked."),
        ])
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        // `mutating`, because delegation is one of the things a `readOnly` run may not do at all
        // (#187 §0.2) — a read-only job would be blocked on `invoke_subagent` and never reach the
        // descendant this test is about.
        let job = Job(name: "delegator", prompt: "Clean up.", trigger: .schedule(.interval(seconds: 60)),
                      profile: .mutating)
        try store.ledger.upsert(job)
        // A settings store of this test's own: the runner resolves job limits through a
        // `ConfigManager`, and the default is the process-global one (AGENTS invariant 7).
        let suite = "iris-bgdescendant-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
        }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               config: ConfigManager(store: defaults))

        await runner.fire(job: job, origin: .schedule)

        #expect(state.pendingApprovals.isEmpty, "an unattended run never parks on a dialog")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .blockedOnApproval)
        #expect(run.blockedTool == "run_command")

        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.status == .blockedOnApproval)
        #expect(card.headline.contains("run_command"))
    }
}
