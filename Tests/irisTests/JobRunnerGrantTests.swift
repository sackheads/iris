import Testing
import Foundation
@testable import iris

/// #282 §2 — what a granted fire does before its turn: stamps the hidden conversation, checks the
/// disk and the network, and ends its container when it is over. Every runtime touch is injected;
/// nothing here starts a container or reaches `SandboxSessionManager.shared` (invariant 7).
@MainActor
@Suite("JobRunner with a grant (#282)")
struct JobRunnerGrantTests {
    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-grantrun-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func harness(_ responses: [GeminiResponse]) throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let user = UUID()
        state.createNewConversation(id: user)
        state.selectedConversationId = user
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: responses),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine)
    }

    private func tempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-grantrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func grantedJob(_ dir: URL, network: Bool = false, name: String = "deploy",
                            profile: JobProfile = .mutating) -> Job {
        var policy = JobPolicy()
        policy.grants = JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(dir.path))], network: network)
        return Job(name: name, prompt: "Do it.", trigger: .schedule(.interval(seconds: 60)),
                   profile: profile, policy: policy)
    }

    /// Records which conversations had their session ended.
    private final class Ended: @unchecked Sendable {
        private let lock = NSLock(); private var ids: [UUID] = []
        func add(_ id: UUID) { lock.withLock { ids.append(id) } }
        var all: [UUID] { lock.withLock { ids } }
    }

    private func runner(_ state: AppState, _ engine: IrisEngine, _ store: ConversationStore, config: ConfigManager,
                        now: (@Sendable () -> Date)? = nil, ended: Ended? = nil,
                        network: @escaping @Sendable () async -> String? = { nil }) -> JobRunner {
        JobRunner(state: state, engine: engine, ledger: store.ledger,
                  endSandboxSession: { ended?.add($0) }, ensureIsolatedNetwork: network,
                  now: now ?? Date.init, config: config, sandboxAvailable: { true })
    }

    @Test("the fire stamps the working directory, the grant and the sandbox pin on the hidden conversation")
    func fireStampsWorkspaceGrantAndPin() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([textResponse("done")])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        await runner(state, engine, store, config: config).fire(job: job, origin: .schedule)

        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.workspacePath == IrisPaths.canonicalPath(dir.path))
        #expect(background.sandboxGrant == job.policy.grants)
        #expect(background.mainAgentSandbox == .sandboxed)
        #expect(background.jobProfile == .mutating)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)

        // The card names whether the run could reach the network (#282 §5): off for this grant,
        // on for one made with `network: true`.
        let activityId = state.activityConversationId()
        let card = try #require(state.conversations.first { $0.id == activityId }?
            .messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.network == false)

        let openJob = grantedJob(dir, network: true, name: "open")
        try store.ledger.upsert(openJob)
        await runner(state, engine, store, config: config).fire(job: openJob, origin: .schedule)
        let openCard = try #require(state.conversations.first { $0.id == activityId }?
            .messages.compactMap { EventCard.decode($0.content) }.last)
        #expect(openCard.network == true)
    }

    @Test("an ungranted mutating job still gets no workspace and no grant, and never asks for the isolated network")
    func ungrantedFireIsUnchanged() async throws {
        let (store, state, engine) = try harness([textResponse("done")])
        let job = Job(name: "plain", prompt: "p", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        await runner(state, engine, store, config: config, network: { "must not be asked" }).fire(job: job, origin: .schedule)
        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.workspacePath == nil && background.sandboxGrant == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("a hand-edited read-only row carrying a grant is run ungranted: no workspace, no grant, no drift check (L1)")
    func readOnlyRowWithAGrantIsNotStamped() async throws {
        let dir = try tempDirectory()
        let (store, state, engine) = try harness([textResponse("done")])
        let job = grantedJob(dir, profile: .readOnly)
        try store.ledger.upsert(job)
        try FileManager.default.removeItem(at: dir)     // would be drift, if the grant were honoured
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        await runner(state, engine, store, config: config, network: { "must not be asked" }).fire(job: job, origin: .schedule)
        let background = try #require(state.conversations.first { $0.isBackground })
        #expect(background.workspacePath == nil && background.sandboxGrant == nil && background.mainAgentSandbox == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("a source that moved fails the fire with the exact reason and walks the retry ladder to a pause")
    func driftFailsAndWalksTheLadder() async throws {
        let dir = try tempDirectory()
        let (store, state, engine) = try harness([textResponse("never reached")])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        try FileManager.default.removeItem(at: dir)          // the grant was made on a directory that is now gone
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let r = runner(state, engine, store, config: config, now: { clock })
        let expected = JobRunner.grantSourceUnavailableReason(IrisPaths.canonicalPath(dir.path))
        #expect(expected == "grant source unavailable: \(IrisPaths.canonicalPath(dir.path))")

        for attempt in 0..<JobRunner.backoff.count {
            await r.fire(job: try #require(try store.ledger.job(id: job.id)), origin: .schedule)
            let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
            #expect(run.status == .failed && run.failureReason == expected)
            let stored = try #require(try store.ledger.job(id: job.id))
            #expect(stored.retryAttempt == attempt + 1)
            #expect(stored.nextFireAt == clock.addingTimeInterval(JobRunner.backoff[attempt]))
            #expect(stored.pausedReason == nil)
        }
        // The ladder as it exists: three retries, and the fourth consecutive failure pauses.
        await r.fire(job: try #require(try store.ledger.job(id: job.id)), origin: .schedule)
        #expect(try store.ledger.job(id: job.id)?.pausedReason == JobRunner.retriesExhaustedReason)
        #expect(state.conversations.filter { $0.isBackground }.count == JobRunner.backoff.count + 1)
    }

    @Test("the pause card carries network like the run cards: the four card sites read the same L1 rule")
    func pauseCardCarriesNetwork() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([textResponse("tick"), textResponse("tick")])
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        config.jobMaxRunsPerHour = 1
        let job = grantedJob(dir, network: true)
        try store.ledger.upsert(job)
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let r = runner(state, engine, store, config: config, now: { clock })
        await r.fire(job: job, origin: .schedule)                                                  // the one run the hour allows
        await r.fire(job: try #require(try store.ledger.job(id: job.id)), origin: .schedule)     // over the line: the breaker pauses
        #expect(try store.ledger.job(id: job.id)?.pausedReason == JobRunner.breakerReason(count: 1))
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let cards = activity.messages.compactMap { EventCard.decode($0.content) }
        #expect(cards.count == 2 && cards.last?.status == .interrupted)
        #expect(cards.allSatisfy { $0.network }, "the pause card says what the job was granted, as the run card does")
    }

    @Test("a symlink swapped under a source is drift too, and a source that became a file is drift")
    func driftRules() throws {
        let real = try tempDirectory(); defer { try? FileManager.default.removeItem(at: real) }
        let link = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-grantlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(JobGrant.drift(JobGrant(mounts: [ContainerMount(source: link.path)]))
                == JobRunner.grantSourceUnavailableReason(link.path))
        #expect(JobGrant.drift(JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(real.path))])) == nil)
        let file = real.appendingPathComponent("f"); try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(JobGrant.drift(JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(file.path))]))
                == JobRunner.grantSourceUnavailableReason(IrisPaths.canonicalPath(file.path)))
        #expect(JobGrant.drift(JobGrant(network: true)) == nil, "no mounts, nothing to drift")
    }

    @Test("an isolated network that cannot be created fails the fire closed with the detail on the row")
    func networkFailureFailsClosed() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([textResponse("never reached")])
        let job = grantedJob(dir, network: false)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let r = runner(state, engine, store, config: config, network: { "network create exited 1: permission denied" })
        await r.fire(job: job, origin: .schedule)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == "isolated network unavailable: network create exited 1: permission denied")
        #expect(try store.ledger.job(id: job.id)?.retryAttempt == 1, "the same ladder as any failure")

        // network: true never asks for the isolated network.
        let open = grantedJob(dir, network: true, name: "open")
        try store.ledger.upsert(open)
        await r.fire(job: open, origin: .schedule)
        #expect(try store.ledger.runs(jobId: open.id, limit: 1).first?.status == .completed)
    }

    @Test("the run's container is ended when the run closes — on completion and on a refused fire")
    func endSessionAtClose() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([textResponse("done")])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let ended = Ended()
        let r = runner(state, engine, store, config: config, ended: ended)
        await r.fire(job: job, origin: .schedule)
        let first = try #require(state.conversations.first { $0.isBackground })
        #expect(ended.all == [first.id])
        try FileManager.default.removeItem(at: dir)
        await r.fire(job: job, origin: .schedule)
        #expect(ended.all.count == 2, "a fire refused before its turn ends the session it opened too")
    }

    @Test("Approve and run reopens with the same grant, ends its session, and drift refuses the click without spending the approval")
    func approvedCallReopensWithTheGrant() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness([])
        let job = grantedJob(dir)
        try store.ledger.upsert(job)
        let target = dir.appendingPathComponent("out.md").path
        let call = BlockedCall(toolName: "write_file", args: ["path": .string(target), "content": .string("hi")],
                               cwd: IrisPaths.canonicalPath(dir.path))
        func blocked(at seconds: TimeInterval) throws -> JobRun {
            let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                             startedAt: Date(timeIntervalSince1970: seconds), transcriptConversationId: nil)
            try store.ledger.begin(run: run)
            try store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil,
                                    failureReason: "needs approval: write_file", blockedTool: "write_file",
                                    tokens: TokenUsage(), finishedAt: Date(timeIntervalSince1970: seconds + 1))
            try store.ledger.setBlockedCall(runId: run.id, call)
            return run
        }
        let first = try blocked(at: 1_700_000_000)
        let (config, teardown) = isolatedConfig(); defer { teardown() }
        let ended = Ended()
        let r = runner(state, engine, store, config: config, ended: ended)

        let outcome = await r.runApproved(runId: first.id)
        guard case .dispatched(let approvedId) = outcome else { Issue.record("\(outcome)"); return }
        let approved = try #require(state.conversations.first { $0.isBackground && $0.title.contains("approved") })
        #expect(approved.sandboxGrant == job.policy.grants)
        #expect(approved.workspacePath == IrisPaths.canonicalPath(dir.path))
        #expect(approved.mainAgentSandbox == .sandboxed)
        #expect(try store.ledger.run(id: approvedId)?.status == .completed)
        #expect(FileManager.default.fileExists(atPath: target), "the approved write landed on the host")
        #expect(ended.all == [approved.id])

        let again = try blocked(at: 1_700_000_100)
        try FileManager.default.removeItem(at: dir)
        let refused = await r.runApproved(runId: again.id)
        #expect(refused == .refused(JobRunner.grantSourceUnavailableReason(IrisPaths.canonicalPath(dir.path))))
        #expect(try store.ledger.run(id: again.id)?.approvedAt == nil)
    }
}
