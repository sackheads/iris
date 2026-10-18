import Testing
import Foundation
@testable import IrisKit

/// #521: a blocked run's card waited on Vibecop's verdict before it was saved, and a local engine's
/// verdict can take seconds. A CLI exit-now in that wait left a `blockedOnApproval` row, with its
/// call stored, and no card ever offering the approval. The card is saved first and the verdict
/// written onto it afterwards, unless the run was approved or dismissed meanwhile.
@MainActor
@Suite("A blocked run's card is saved before Vibecop's verdict (#521)", .timeLimit(.minutes(1)))
struct BlockedCardBeforeVerdictTests {

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-blockedcard-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let config = ConfigManager(store: store)
        config.enableVibecop = true
        return (config, {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    /// A run whose one tool call is refused for want of approval, then a closing reply.
    private func harness() throws -> (ConversationStore, AppState, IrisEngine, Job) {
        let command = "true --never-run-\(UUID().uuidString)"
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "run_command", args: ["command": .string(command)]))]))],
                           usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(text: "blocked.")]))], usageMetadata: nil),
        ]), protectionEnabled: false, sessionPeerCount: 0)
        let job = Job(name: "needs-hands", prompt: "Do the thing.",
                      trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        try store.ledger.upsert(job)
        return (store, state, engine, job)
    }

    /// Answers DENY, but only once released: a local model mid-inference.
    private final class HeldVibecop: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var entered = 0
        private var open = false
        var calls: Int { lock.withLock { entered } }
        func release() { lock.withLock { open = true } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { entered += 1 }
            let deadline = TestClock.deadline(20)
            while !lock.withLock({ open }), TestClock.now() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return #"{"decision":"DENY","reason":"this deletes things"}"#
        }
    }

    private func until(within seconds: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = TestClock.deadline(seconds)
        while !condition() {
            if TestClock.now() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func persistedCards(_ store: ConversationStore) throws -> [EventCard] {
        try store.loadAll().conversations.flatMap(\.messages).filter { $0.role == .event }
            .compactMap { EventCard.decode($0.content) }
    }

    private func cards(_ state: AppState) -> [EventCard] {
        state.conversations.flatMap(\.messages).filter { $0.role == .event }
            .compactMap { EventCard.decode($0.content) }
    }

    @Test("a CLI run's blocked card is in the store while the verdict is still being taken")
    func cardSavedBeforeVerdict() async throws {
        let (store, state, engine, job) = try harness()
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let stop = RunStop(grace: 5, terminateGroups: {})
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true }, stop: stop)
        let vibecop = HeldVibecop()
        defer { vibecop.release() }

        let fire = AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            Task { await runner.fire(job: job, origin: .manual) }
        }
        try #require(await until { vibecop.calls >= 1 }, "the verdict is being taken")
        // The Ctrl-C that would come before an exit-now. The run has already ended, so it stops nothing.
        _ = stop.request(reason: RunStop.reason(for: SIGINT))

        // What an exit-now here would leave on disk.
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .blockedOnApproval)
        #expect(run.blockedCall != nil)
        let saved = try persistedCards(store).filter { $0.runId == run.id }
        #expect(saved.count == 1, "the blocked row already has its card in the store")
        #expect(saved.first?.offersApproval == true)
        #expect(saved.first?.vibecopVerdict == nil, "the verdict is not in yet")

        vibecop.release()
        _ = try await value(of: fire)
        let final = try persistedCards(store).filter { $0.runId == run.id }
        #expect(final.count == 1, "the verdict rewrote the card rather than adding a second one")
        #expect(final.first?.vibecopVerdict == "DENY")
        #expect(final.first?.vibecopReason == "this deletes things")
    }

    @Test("an app run's blocked card is delivered before the verdict, and gets it afterwards")
    func appCardGetsTheVerdictLater() async throws {
        let (store, state, engine, job) = try harness()
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true })
        let vibecop = HeldVibecop()
        defer { vibecop.release() }

        let fire = AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            Task { await runner.fire(job: job, origin: .schedule) }
        }
        try #require(await until { vibecop.calls >= 1 }, "the verdict is being taken")
        #expect(cards(state).count == 1, "the card is already in the transcript")
        #expect(cards(state).first?.vibecopVerdict == nil)

        vibecop.release()
        _ = try await value(of: fire)
        #expect(cards(state).count == 1)
        #expect(cards(state).first?.vibecopVerdict == "DENY")
    }

    @Test("a verdict that lands after the run was approved does not rewrite its card")
    func approvedDuringVerdictKeepsTheCard() async throws {
        let (store, state, engine, job) = try harness()
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true })
        let vibecop = HeldVibecop()
        defer { vibecop.release() }

        let fire = AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            Task { await runner.fire(job: job, origin: .schedule) }
        }
        try #require(await until { vibecop.calls >= 1 }, "the verdict is being taken")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let before = try #require(state.conversations.flatMap(\.messages).first { $0.role == .event })
        // What "Approve and run" writes first: the one-shot claim, which also acknowledges the run.
        #expect(try store.ledger.markApproved(runId: run.id, at: Date()) == true)

        vibecop.release()
        _ = try await value(of: fire)
        let after = try #require(state.conversations.flatMap(\.messages).first { $0.id == before.id })
        #expect(after.content == before.content, "the card the person acted on is left as it was")
        #expect(cards(state).count == 1)
    }

    /// A click's ledger write is the runner's or a detached task's and can come after the verdict
    /// (review of #526). The click itself is recorded on the main actor as it lands. Here the
    /// click's runner is another store's, so its ledger write never reaches this one: only that
    /// record can stop the rewrite.
    @Test("a verdict that lands after the Approve click, before its ledger write, does not rewrite the card")
    func approveClickBeforeItsWriteKeepsTheCard() async throws {
        let (store, state, engine, job) = try harness()
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true })
        let elsewhere = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                                 tier3Provisioning: .provisioned)
        let vibecop = HeldVibecop()
        defer { vibecop.release() }

        let fire = AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            Task { await runner.fire(job: job, origin: .schedule) }
        }
        try #require(await until { vibecop.calls >= 1 }, "the verdict is being taken")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let before = try #require(state.conversations.flatMap(\.messages).first { $0.role == .event })
        state.installEngine(IrisEngine(state: elsewhere, client: FakeLLMClient(responses: []), protectionEnabled: false))
        state.approveBlockedCall(runId: run.id)
        #expect(state.runsActedOn.contains(run.id), "recorded at the click, before any hop")

        vibecop.release()
        _ = try await value(of: fire)
        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt == nil, "no ledger write reached this store")
        let after = try #require(state.conversations.flatMap(\.messages).first { $0.id == before.id })
        #expect(after.content == before.content, "the card the person clicked is left as it was")
        withExtendedLifetime(elsewhere) {}
    }

    @Test("Dismiss and Acknowledge record the run at the click, before their ledger write")
    func dismissRecordsAtTheClick() throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned)
        let id = UUID()
        _ = state.dismissEventCard(runId: id)
        #expect(state.runsActedOn.contains(id))
    }

    @Test("a verdict that lands after the run was dismissed does not rewrite its card")
    func dismissedDuringVerdictKeepsTheCard() async throws {
        let (store, state, engine, job) = try harness()
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: config, activity: RecordingActivity(), sandboxAvailable: { true })
        let vibecop = HeldVibecop()
        defer { vibecop.release() }

        let fire = AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            Task { await runner.fire(job: job, origin: .schedule) }
        }
        try #require(await until { vibecop.calls >= 1 }, "the verdict is being taken")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let before = try #require(state.conversations.flatMap(\.messages).first { $0.role == .event })
        try store.ledger.acknowledge(runId: run.id, at: Date())

        vibecop.release()
        _ = try await value(of: fire)
        let after = try #require(state.conversations.flatMap(\.messages).first { $0.id == before.id })
        #expect(after.content == before.content)
    }
}
