import Testing
import Foundation
@testable import IrisKit

/// D6 decision 12: `/jobs run` and a URL fire share one body. A URL fire records `url`, skips
/// the gate like any hand-started fire, meets overlap and the budgets, and costs Iris one line.
@MainActor
@Suite("Run job by hand (D6)", .timeLimit(.minutes(1)))
struct RunJobByHandTests {
    private func polled() -> Job {
        Job(name: "poller", prompt: "Reply with just the word tick.",
            trigger: .poll(PollSpec(schedule: .interval(seconds: 60), gate: .urlChanged(url: "https://example.invalid/f"))))
    }

    @Test("a URL fire records url, and the gate never decides it")
    func originTable() {
        #expect(FireOrigin.url.triggerKind == "url")
        #expect(!JobRunner.gateApplies(origin: .url, job: polled()))
        #expect(!JobRunner.gateApplies(origin: .queued(from: .url), job: polled()))
    }

    private final class GateCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    @Test("a URL fire of a gated job runs without asking the gate")
    func urlFireSkipsTheGate() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let client = FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(text: "tick")]))], usageMetadata: nil)])
        let engine = IrisEngine(state: state, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        let job = polled()
        try store.ledger.upsert(job)
        let name = "iris-byhand-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let calls = GateCalls()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: ConfigManager(store: defaults), protectionEnabled: false,
                               gateEvaluator: { _, _ in calls.bump(); return .unchanged(signal: "etag=aaa") })

        #expect(await runner.fire(job: job, origin: .url) == .run)

        #expect(calls.count == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    private func makeApp() throws -> (ConversationStore, AppState, UUID) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        return (store, app, app.activityConversationId())
    }

    private func systemLines(_ app: AppState, _ id: UUID) -> [String] {
        app.conversations.first { $0.id == id }?.messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    @Test("a URL fire posts one line, updated in place with what admission decided")
    func urlVoiceIsOneLine() async throws {
        let (store, app, iris) = try makeApp()
        // A built-in runs no model turn, so the fire is admitted without a paid call.
        let job = Job(name: "url-digest", prompt: "", trigger: .schedule(.interval(seconds: 86_400)),
                      action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)

        let task = try #require(app.runJobByHand(job: job, origin: .url, announceTo: iris))
        #expect(systemLines(app, iris) == [RunJobURL.firingLine("url-digest")])
        #expect(try await value(of: task) == .run)

        #expect(systemLines(app, iris) == [RunJobURL.firedLine("url-digest")])
        #expect(app.conversations.first { $0.id == iris }?.messages.contains { $0.role == .command } == false)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("a paused job is refused before anything fires, in one line")
    func pausedURLVoice() throws {
        let (store, app, iris) = try makeApp()
        let job = Job(name: "stopped", prompt: "", trigger: .schedule(.interval(seconds: 60)),
                      pausedReason: JobRunner.breakerReason(count: 6), action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)

        #expect(app.runJobByHand(job: job, origin: .url, announceTo: iris) == nil)
        #expect(systemLines(app, iris) == [RunJobURL.notStartedLine("stopped", "it is paused")])
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }
}
