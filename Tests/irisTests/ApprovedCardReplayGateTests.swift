import Testing
import Foundation
@testable import IrisKit

/// #1260 (follow-up to #1222/#1259): the memory-tier write gate on the approved-card replay,
/// `IrisEngine.executeApprovedCall`, pinned on the live route. A card is recorded when a run is
/// blocked; the click comes later through `JobRunner.runApproved`, which reopens the job's
/// conversation under the job's stamped access profile and calls the engine. The binding a card is
/// clicked under is not necessarily the one it was recorded under (the profile can be re-pointed or
/// narrowed in between), so the gate reads it fresh. Driven through `runApproved`, read back from
/// the ledger run and USER.md, never by calling `executeApprovedCall` directly (#1217's lesson).
@MainActor
@Suite("An approved card's memory write meets the tier gate at click time (#1260)", .serialized, .timeLimit(.minutes(2)))
struct ApprovedCardReplayGateTests {
    private struct World {
        let root: URL
        let paths: IrisPaths
        let store: ConversationStore
        let runner: JobRunner
        let state: AppState      // the runner holds these weakly
        let engine: IrisEngine
        let teardown: () -> Void
    }

    private func world() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1260-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        // `update_user_profile` needs `.full`; `.task` is below it.
        try #"{"memoryWrite":1}"#.write(to: paths.profilesDir.appendingPathComponent("narrow.json"), atomically: true, encoding: .utf8)
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0,
                                memory: MemoryManager(paths: paths), accessProfileStore: AccessProfileStore(paths: paths))
        let name = "iris-1260-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let config = ConfigManager(store: defaults)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               now: { Date(timeIntervalSince1970: 1_700_000_000) }, config: config,
                               sandboxAvailable: { true })
        return World(root: root, paths: paths, store: store, runner: runner, state: state, engine: engine, teardown: {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
            try? FileManager.default.removeItem(at: root)
        })
    }

    /// A job, and a blocked run holding an approvable `update_user_profile` call for it.
    private func blocked(_ w: World, accessProfileId: String?) throws -> JobRun {
        let job = Job(name: "writer", prompt: "x", trigger: .schedule(.interval(seconds: 60)), profile: .mutating, accessProfileId: accessProfileId)
        try w.store.ledger.upsert(job)
        let call = BlockedCall(toolName: "update_user_profile", args: ["content": .string("1260 planted profile")], cwd: nil)
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                         startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try w.store.ledger.begin(run: run)
        try w.store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil,
                                  failureReason: "needs approval: update_user_profile",
                                  blockedTool: call.toolName, tokens: TokenUsage(),
                                  finishedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try w.store.ledger.setBlockedCall(runId: run.id, call)
        return try #require(try w.store.ledger.run(id: run.id))
    }

    private func profile(_ w: World) -> String? { try? String(contentsOf: w.paths.userMd, encoding: .utf8) }

    @Test("a card recorded for a job later bound to a narrow profile is refused on the click and writes nothing")
    func narrowedBindingRefusesTheReplay() async throws {
        let w = try world(); defer { w.teardown() }
        let run = try blocked(w, accessProfileId: "narrow")
        let outcome = await w.runner.runApproved(runId: run.id)
        guard case .dispatched(let approvedId) = outcome else {
            Issue.record("the click was not dispatched: \(outcome)"); return
        }
        let approved = try #require(try w.store.ledger.run(id: approvedId))
        #expect(approved.outcome == MemoryBindingGate.refusal)
        #expect(profile(w) != "1260 planted profile", "the narrowed replay must not have written USER.md")
    }

    /// The owner's card is not refused by the gate: it passes through to the executor, which has no
    /// handler for a memory writer (those run in the engine's own dispatch, so a card for one is
    /// defence in depth rather than a live write path -- the gate is what must hold if that changes).
    /// That the outcome is not the refusal is the positive control for the test above.
    @Test("control: the same card on an unstamped (owner) job is not refused by the gate")
    func ownerReplayWrites() async throws {
        let w = try world(); defer { w.teardown() }
        let run = try blocked(w, accessProfileId: nil)
        let outcome = await w.runner.runApproved(runId: run.id)
        guard case .dispatched(let approvedId) = outcome else {
            Issue.record("the click was not dispatched: \(outcome)"); return
        }
        let approved = try #require(try w.store.ledger.run(id: approvedId))
        #expect(approved.outcome != MemoryBindingGate.refusal)
        #expect(approved.outcome?.contains("Unknown tool") == true, Comment(rawValue: approved.outcome ?? "nil outcome"))
    }
}
