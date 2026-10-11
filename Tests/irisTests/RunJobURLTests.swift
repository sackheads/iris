import Testing
import Foundation
import GRDB
@testable import IrisKit

/// D6 decisions 12 and 13: the link carries a token and nothing else, fires one opted-in job,
/// at most 3 times an hour, and every refusal is said in Iris in a line that a flood cannot
/// multiply.
@MainActor
@Suite("Run-job URL (D6)", .timeLimit(.minutes(1)))
struct RunJobURLTests {
    private let token = String(repeating: "A", count: 20) + "-_"

    private func parse(_ text: String, _ identity: BuildIdentity = .dev) -> Result<String, RunJobURL.Refusal> {
        RunJobURL.parse(URL(string: text)!, identity: identity)
    }

    @Test("a current-form link parses to its token; the host is matched in any case")
    func accepts() {
        #expect(parse("iris-dev://run-job/\(token)") == .success(token))
        #expect(parse("iris-dev://RUN-JOB/\(token)") == .success(token))
        #expect(parse("iris://run-job/\(token)", .release) == .success(token))
    }

    @Test("everything else is refused, with a reason that never echoes the link")
    func refuses() {
        #expect(parse("iris://run-job/\(token)") == .failure(.otherScheme))
        #expect(parse("iris-dev://run-job/\(token)", .release) == .failure(.otherScheme))
        #expect(parse("iris-dev://jobs/\(token)") == .failure(.wrongHost))
        #expect(parse("iris-dev://me@run-job/\(token)") == .failure(.wrongHost))
        #expect(parse("iris-dev://run-job:8080/\(token)") == .failure(.wrongHost))
        #expect(parse("iris-dev://run%2Djob/\(token)") == .failure(.wrongHost))
        #expect(parse("iris-dev:///\(token)") == .failure(.wrongHost))
        #expect(parse("iris-dev://run-job:/\(token)") == .failure(.wrongHost), "an empty port")
        #expect(parse("iris-dev://run-job./\(token)") == .failure(.wrongHost), "a trailing dot")
        #expect(parse("iris-dev://@run-job/\(token)") == .failure(.wrongHost), "an empty user")
        // Foundation folds a fullwidth host while building the URL, so what reaches the parser is
        // byte for byte the canonical link: there is nothing left to tell apart.
        let folded = URL(string: "iris-dev://\u{FF52}un-job/\(token)")
        if let folded, folded.absoluteString != RunJobURL.url(token: token, identity: .dev) {
            #expect(RunJobURL.parse(folded, identity: .dev) == .failure(.wrongHost))
        }
        #expect(parse("iris-dev://run-job/\(token)?prompt=hi") == .failure(.hasQuery))
        #expect(parse("iris-dev://run-job/\(token)?") == .failure(.hasQuery))
        #expect(parse("iris-dev://run-job/\(token)#x") == .failure(.hasFragment))
        #expect(parse("iris-dev://run-job/\(token)/more") == .failure(.wrongPath))
        #expect(parse("iris-dev://run-job/\(token)/") == .failure(.wrongPath))
        #expect(parse("iris-dev://run-job/") == .failure(.wrongPath))
        #expect(parse("iris-dev://run-job/\(UUID().uuidString)") == .failure(.malformedToken))
        #expect(parse("iris-dev://run-job/pr-sweep") == .failure(.malformedToken))
        #expect(parse("iris-dev://run-job/%41\(token.dropFirst(3))") == .failure(.malformedToken))
        for refusal in [RunJobURL.Refusal.otherScheme, .wrongHost, .hasQuery, .hasFragment, .wrongPath, .malformedToken] {
            #expect(!refusal.sentence.contains(token))
        }
    }

    // MARK: The handler

    private func makeApp(_ jobs: [Job]) throws -> (ConversationStore, AppState, UUID) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        for job in jobs { try store.ledger.upsert(job) }
        return (store, app, app.activityConversationId())
    }

    /// A built-in, so an admitted fire runs no model turn.
    private func digest(_ name: String = "url-digest", pausedReason: String? = nil, enabled: Bool = true) -> Job {
        Job(name: name, prompt: "", trigger: .schedule(.interval(seconds: 86_400)), enabled: enabled,
            pausedReason: pausedReason, action: .builtin(DailyDigest.name))
    }

    private func optIn(_ job: Job, _ store: ConversationStore) throws -> String {
        let minted = try #require(URLTriggerToken.generate())
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: URLTriggerToken.digest(minted))
        return minted
    }

    private func link(_ token: String) -> URL { URL(string: RunJobURL.url(token: token, identity: .dev))! }

    private func systemLines(_ app: AppState, _ iris: UUID) -> [String] {
        app.conversations.first { $0.id == iris }?.messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    @Test("a current token fires its job, and the row says url")
    func acceptedFires() async throws {
        let job = digest()
        let (store, app, iris) = try makeApp([job])
        let minted = try optIn(job, store)

        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        _ = try await value(of: try #require(app.urlFireTask))

        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
        #expect(systemLines(app, iris) == [RunJobURL.firedLine("url-digest")])
    }

    @Test("every kind of bad link is refused with a line, writes no row, and never echoes a token")
    func refusalsWriteNoRow() throws {
        let job = digest(), paused = digest("stopped", pausedReason: JobRunner.gateFailingReason),
            disabled = digest("switched-off", enabled: false)
        let (store, app, iris) = try makeApp([job, paused, disabled])
        let minted = try optIn(job, store)
        let pausedToken = try optIn(paused, store), disabledToken = try optIn(disabled, store)
        let rotatedOut = minted
        let current = try optIn(job, store)          // `on` again: `minted` is now rotated out
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: nil)   // and `off`: `current` is dead too

        let unmatched = [
            URL(string: "iris-dev://run-job/\(job.id.uuidString)")!,
            URL(string: "iris-dev://run-job/url-digest")!,
            URL(string: "iris-dev://run-job/\(current)?x=1")!,
            URL(string: "iris-dev://run-job/\(current)#x")!,
            URL(string: "iris-dev://run-job/\(current)/x")!,
            URL(string: "iris://run-job/\(current)")!,
            link(try #require(URLTriggerToken.generate())),
            link(rotatedOut),
            link(current),
        ]
        for url in unmatched { #expect(app.handleRunJobURL(url, identity: .dev) == .refused, "\(url)") }
        #expect(app.handleRunJobURL(link(pausedToken), identity: .dev) == .refused)
        #expect(app.handleRunJobURL(link(disabledToken), identity: .dev) == .refused)

        for owner in [job, paused, disabled] {
            #expect(try store.ledger.runs(jobId: owner.id, limit: 5).isEmpty)
        }
        let lines = systemLines(app, iris)
        #expect(lines.count == 3, "one coalesced line for unmatched links, one per refused job: \(lines)")
        #expect(lines.contains { $0.hasPrefix("Refused \(unmatched.count) URL fires in the last hour.") })
        #expect(lines.contains { $0.contains("stopped") && $0.contains("paused") })
        #expect(lines.contains { $0.contains("switched-off") && $0.contains("disabled") })
        for line in lines {
            for t in [minted, current, pausedToken, disabledToken] { #expect(!line.contains(t)) }
            #expect(!line.contains("://") && !line.contains(job.id.uuidString), "a refusal echoes the link: \(line)")
        }
    }

    private func urlRows(_ count: Int, for job: Job, _ store: ConversationStore) throws {
        for i in 0..<count {
            let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "url",
                             startedAt: Date().addingTimeInterval(-Double(60 * (i + 1))),
                             transcriptConversationId: UUID())
            try store.ledger.begin(run: run)
            try store.ledger.finish(runId: run.id, status: .completed, outcome: "ok", failureReason: nil,
                                    blockedTool: nil, tokens: TokenUsage(), finishedAt: run.startedAt)
        }
    }

    @Test("the third URL fire in an hour is admitted")
    func thirdIsAdmitted() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        try urlRows(2, for: job, store)
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        _ = try await value(of: try #require(app.urlFireTask))
    }

    @Test("the fourth is refused before admission: no row, no breaker count, no pause")
    func fourthIsRefused() throws {
        let job = digest()
        let (store, app, iris) = try makeApp([job])
        let minted = try optIn(job, store)
        try urlRows(3, for: job, store)
        let before = try store.ledger.usage(jobId: job.id, now: Date(), calendar: .current).runsLastHour

        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .refused)

        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 3)
        #expect(try store.ledger.usage(jobId: job.id, now: Date(), calendar: .current).runsLastHour == before)
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil)
        #expect(systemLines(app, iris).last?.contains(RunJobURL.overLimitReason) == true)
    }

    @Test("a flood over the limit is one line with a running count")
    func overLimitFloodIsOneLine() throws {
        let job = digest()
        let (store, app, iris) = try makeApp([job])
        let minted = try optIn(job, store)
        try urlRows(3, for: job, store)
        for _ in 0..<5 { app.handleRunJobURL(link(minted), identity: .dev) }
        let lines = systemLines(app, iris)
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("Refused 5 URL fires of url-digest in the last hour.") == true)
    }

    @Test("a page opening garbage links in a loop costs Iris one line")
    func garbageFloodIsOneLine() throws {
        let (_, app, iris) = try makeApp([])
        for i in 0..<20 { app.handleRunJobURL(URL(string: "iris-dev://run-job/junk\(i)")!, identity: .dev) }
        #expect(systemLines(app, iris) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.Refusal.malformedToken.sentence, count: 20)])
    }

    @Test("after an hour, a refusal starts a new line")
    func windowRolls() throws {
        let (_, app, iris) = try makeApp([])
        let start = Date()
        app.urlClock = { start }
        app.handleRunJobURL(URL(string: "iris-dev://run-job/junk")!, identity: .dev)
        app.urlClock = { start.addingTimeInterval(RunJobURL.window + 1) }
        app.handleRunJobURL(URL(string: "iris-dev://run-job/junk")!, identity: .dev)
        #expect(systemLines(app, iris).count == 2)
    }

    @Test("a token whose job has the flag off finds nothing, even with its digest still stored")
    func flagOffDigestKept() throws {
        let job = digest()
        let (store, app, iris) = try makeApp([job])
        let minted = try optIn(job, store)
        // Not a state `setURLTrigger` can leave; the lookup must not trust that.
        try store.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET urlTrigger = 0 WHERE id = ?", arguments: [job.id.uuidString])
        }
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .refused)
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
        #expect(systemLines(app, iris) == [RunJobURL.refusalLine(subject: nil, reason: RunJobURL.unknownTokenReason, count: 1)])

        var off = job
        off.urlTrigger = false
        #expect(app.urlFireRefusal(for: off) == RunJobURL.triggerOffReason(job.name),
                "and a job read with the flag off is refused on its own, too")
    }

    @Test("a flood of links to a paused or a disabled job is one line per job")
    func stoppedFloodIsOneLinePerJob() throws {
        let paused = digest("stopped", pausedReason: JobRunner.gateFailingReason)
        let disabled = digest("switched-off", enabled: false)
        let (store, app, iris) = try makeApp([paused, disabled])
        let pausedToken = try optIn(paused, store), disabledToken = try optIn(disabled, store)
        for _ in 0..<4 {
            #expect(app.handleRunJobURL(link(pausedToken), identity: .dev) == .refused)
            #expect(app.handleRunJobURL(link(disabledToken), identity: .dev) == .refused)
        }
        #expect(systemLines(app, iris) == [
            RunJobURL.refusalLine(subject: "stopped", reason: RunJobURL.pausedReason(paused), count: 4),
            RunJobURL.refusalLine(subject: "switched-off", reason: RunJobURL.disabledReason, count: 4),
        ])
        for job in [paused, disabled] { #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty) }
    }

    // MARK: Concurrency: the count and the fire are one step on the main actor

    /// One link, and the fire task it started if it fired, so a test can await every one.
    private func open(_ app: AppState, _ token: String, into tasks: inout [Task<JobRunner.Admission?, Never>]) -> AppState.RunJobURLOutcome {
        let before = app.urlFireTask
        let outcome = app.handleRunJobURL(link(token), identity: .dev)
        if case .fired = outcome, let task = app.urlFireTask, task != before { tasks.append(task) }
        return outcome
    }

    private func settle(_ tasks: [Task<JobRunner.Admission?, Never>]) async throws -> [JobRunner.Admission?] {
        var out: [JobRunner.Admission?] = []
        for task in tasks { out.append(try await value(of: task)) }
        return out
    }

    @Test("two links for a job at the limit's edge, arriving together, fire once")
    func concurrentAtTheEdge() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        try urlRows(2, for: job, store)
        var tasks: [Task<JobRunner.Admission?, Never>] = []
        // Back to back on the main actor: the first fire's task has not run, so its row is not
        // written when the second link is counted.
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .refused)
        _ = try await settle(tasks)
        #expect(try store.ledger.urlFires(jobId: job.id, since: Date().addingTimeInterval(-RunJobURL.window)) == 3)
    }

    @Test("links racing from zero: three fire, the fourth is refused")
    func concurrentFromZero() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        var tasks: [Task<JobRunner.Admission?, Never>] = []
        let outcomes = (0..<4).map { _ in open(app, minted, into: &tasks) }
        #expect(outcomes == [.fired(job.id), .fired(job.id), .fired(job.id), .refused])
        #expect(tasks.count == 3)
        _ = try await settle(tasks)
    }

    @Test("a fire in flight whose row is already written is counted once, not twice")
    func inFlightRowIsNotDoubleCounted() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        let start = Date()
        app.urlClock = { start }
        var tasks: [Task<JobRunner.Admission?, Never>] = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        // The row that first fire writes, landing while it is still in flight.
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "url",
                         startedAt: start.addingTimeInterval(0.5), transcriptConversationId: UUID())
        try store.ledger.begin(run: run)
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .refused)
        _ = try await settle(tasks)
    }

    @Test("once every fire has settled, the rows alone are counted")
    func settledFiresFallBackToRows() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        var tasks: [Task<JobRunner.Admission?, Never>] = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        _ = try await settle(tasks)
        #expect(app.urlFireBatches[job.id] == nil)
        tasks = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .refused)
        _ = try await settle(tasks)
    }

    @Test("while a batch is open its fires all count, even ones sent more than an hour ago")
    func openBatchCountsEveryDispatch() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        let start = Date()
        app.urlClock = { start }
        var tasks: [Task<JobRunner.Admission?, Never>] = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        // Still outstanding (no task has run), and now sent over an hour ago: a fire that has not
        // started its run has not left the hour.
        app.urlClock = { start.addingTimeInterval(RunJobURL.window + 1) }
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .refused)
        _ = try await settle(tasks)
    }

    // MARK: The queue policy (re-ruled note 11): a held URL fire is a URL fire

    /// Every model call parks until the test lets one through, so a run can be held in flight
    /// for as many cycles as a test needs.
    final class TurnstileClient: LLMClientProtocol, @unchecked Sendable {
        actor Turnstile {
            private var arrived = 0
            private var released = 0
            private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
            private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

            func arrive() async {
                arrived += 1
                let n = arrived
                for (i, (want, waiter)) in arrivalWaiters.enumerated().reversed() where arrived >= want {
                    waiter.resume()
                    arrivalWaiters.remove(at: i)
                }
                if n <= released { return }
                await withCheckedContinuation { parked[n] = $0 }
            }

            func release() {
                released += 1
                parked.removeValue(forKey: released)?.resume()
            }

            func arrivals(_ n: Int) async {
                if arrived >= n { return }
                await withCheckedContinuation { arrivalWaiters.append((n, $0)) }
            }
        }

        let turnstile = Turnstile()
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            await turnstile.arrive()
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "tick")]))],
                                  usageMetadata: nil)
        }

        /// Returns once `n` calls have arrived, or fails the test (#435).
        func waitForArrivals(_ n: Int) async throws {
            let t = turnstile
            _ = try await value(of: Task { await t.arrivals(n) })
        }
    }

    private func queueApp() throws -> (ConversationStore, AppState, Job, TurnstileClient, String) {
        let job = Job(name: "url-queue", prompt: "Reply with just the word tick.",
                      trigger: .schedule(.interval(seconds: 86_400)), policy: JobPolicy(overlap: .queue))
        let (store, app, _) = try makeApp([job])
        app.autoApproveTools = true
        let client = TurnstileClient()
        app.installEngine(IrisEngine(state: app, tier: .medium, client: client,
                                     protectionEnabled: false, sessionPeerCount: 0))
        return (store, app, job, client, try optIn(job, store))
    }

    private func urlRunsLastHour(_ job: Job, _ store: ConversationStore) throws -> Int {
        try store.ledger.urlFires(jobId: job.id, since: Date().addingTimeInterval(-RunJobURL.window))
    }

    @Test("a queue-policy job held in flight: across run cycles no more than 3 URL runs start in an hour")
    func queuedURLFiresAreCounted() async throws {
        let (store, app, job, client, minted) = try queueApp()
        var tasks: [Task<JobRunner.Admission?, Never>] = []

        // Cycle 1: one run in flight, two links held behind it (one held fire), the 4th refused.
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        try await client.waitForArrivals(1)
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .refused)
        await client.turnstile.release()
        try await client.waitForArrivals(2)           // the held fire's run
        await client.turnstile.release()
        let admissions = try await settle(tasks)
        #expect(admissions == [.run, .queued, .queued])
        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.triggerKind == "url" }, "the held re-fire records url: \(runs.map(\.triggerKind))")

        // Cycle 2: one more run fits the hour, and then nothing does.
        tasks = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        try await client.waitForArrivals(3)
        #expect(open(app, minted, into: &tasks) == .refused)
        await client.turnstile.release()
        _ = try await settle(tasks)
        #expect(open(app, minted, into: &tasks) == .refused)

        #expect(try urlRunsLastHour(job, store) == 3)
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil, "no pause from three URL runs")
    }

    @Test("links riding the owner's run: the held URL fire is counted and the 4th link is refused")
    func ridingTheOwnersRun() async throws {
        let (store, app, job, client, minted) = try queueApp()
        let runner = try #require(await app.engine.jobRunner())
        let owner = Task { await runner.fire(job: job, origin: .manual) }
        try await client.waitForArrivals(1)

        var tasks: [Task<JobRunner.Admission?, Never>] = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        // Settled as `.queued` before the next link: held, not running, and still counted.
        #expect(try await settle(tasks) == [.queued])
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(open(app, minted, into: &tasks) == .refused)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).isEmpty == false)

        await client.turnstile.release()
        try await client.waitForArrivals(2)
        await client.turnstile.release()
        _ = try await value(of: owner)
        _ = try await settle(tasks)

        let kinds = try store.ledger.runs(jobId: job.id, limit: 10).map(\.triggerKind).sorted()
        #expect(kinds == ["manual", "url"], "one held run for three links, recorded as url")
        // Its run started, so the rows alone count again: two more links fit the hour.
        tasks = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        try await client.waitForArrivals(3)
        await client.turnstile.release()
        _ = try await settle(tasks)
        tasks = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        try await client.waitForArrivals(4)
        await client.turnstile.release()
        _ = try await settle(tasks)
        #expect(open(app, minted, into: &tasks) == .refused)
        #expect(try urlRunsLastHour(job, store) == 3)
    }

    @Test("a busy queue job: an hour after a held link ran, three fresh links are admitted though a fire is held")
    func busyQueueJobReopensAfterAnHour() async throws {
        let (store, app, job, client, minted) = try queueApp()
        let runner = try #require(await app.engine.jobRunner())
        let owner = Task { await runner.fire(job: job, origin: .manual) }
        try await client.waitForArrivals(1)

        // H: held behind the owner's run.
        var tasks: [Task<JobRunner.Admission?, Never>] = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(try await settle(tasks) == [.queued])
        await client.turnstile.release()
        try await client.waitForArrivals(2)           // H's re-fire is running, as url
        // And a non-URL fire is held during that run: the job is never without one.
        #expect(await runner.fire(job: job, origin: .manual) == .queued)
        #expect(try store.ledger.job(id: job.id)?.queuedFire != nil)

        app.urlClock = { Date().addingTimeInterval(RunJobURL.window + 1) }
        tasks = []
        for _ in 0..<3 { #expect(open(app, minted, into: &tasks) == .fired(job.id)) }
        #expect(open(app, minted, into: &tasks) == .refused)

        await client.turnstile.release()
        try await client.waitForArrivals(3)           // the held fire: the manual one and the three links
        await client.turnstile.release()
        _ = try await value(of: owner)
        _ = try await settle(tasks)
    }

    @Test("a link that starts an idle queue job's long loop is settled on its own answer, not when the loop ends")
    func longLoopSettlesOnDecision() async throws {
        let (store, app, job, client, minted) = try queueApp()
        let runner = try #require(await app.engine.jobRunner())
        var tasks: [Task<JobRunner.Admission?, Never>] = []

        // L1 starts the job: its `fire` is now the job's loop.
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        try await client.waitForArrivals(1)
        #expect(app.urlFireBatches[job.id] == nil, "settled once its row was begun, with its run still going")
        // Every run, a manual fire is held, so the loop keeps going.
        var others: [JobRunner.Admission?] = []
        others.append(await runner.fire(job: job, origin: .manual))
        await client.turnstile.release()
        try await client.waitForArrivals(2)
        others.append(await runner.fire(job: job, origin: .manual))
        #expect(others == [.queued, .queued])
        #expect(app.urlFireBatches[job.id] == nil, "L1's run began: nothing of it is outstanding")

        // An hour later, with L1's loop still running: three fresh links are admitted.
        app.urlClock = { Date().addingTimeInterval(RunJobURL.window + 1) }
        for _ in 0..<3 { #expect(open(app, minted, into: &tasks) == .fired(job.id)) }
        #expect(open(app, minted, into: &tasks) == .refused)

        await client.turnstile.release()
        try await client.waitForArrivals(3)
        await client.turnstile.release()
        _ = try await settle(tasks)
        _ = try store.ledger.runs(jobId: job.id, limit: 10)
    }

    @Test("a held run that is itself held again leaves its links waiting in the new hold")
    func reheldPassKeepsItsLinks() async throws {
        let job = Job(name: "url-rehold", prompt: "Reply with just the word tick.",
                      trigger: .fsEvent(FSWatch(path: "/tmp/rehold")), policy: JobPolicy(overlap: .queue))
        let (store, app, _) = try makeApp([job])
        app.autoApproveTools = true
        let client = TurnstileClient()
        app.installEngine(IrisEngine(state: app, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0))
        let minted = try optIn(job, store)
        let runner = try #require(await app.engine.jobRunner())
        // Parks the held pass between being taken and being admitted, so another fire can start.
        let gate = JobSchedulerTests.Gate()
        await runner.setHeldPathsSource { _ in await gate.arriveAndWait(); return ([], nil) }

        let owner = Task { await runner.fire(job: job, origin: .watcher(paths: ["/tmp/rehold/a"])) }
        try await client.waitForArrivals(1)
        #expect(await runner.fire(job: job, origin: .watcher(paths: ["/tmp/rehold/b"])) == .queued)
        var tasks: [Task<JobRunner.Admission?, Never>] = []
        #expect(open(app, minted, into: &tasks) == .fired(job.id))
        #expect(try await settle(tasks) == [.queued])
        #expect(app.urlFireBatches[job.id]?.held.map(\.generation) == [0])

        await client.turnstile.release()           // the owner's run ends; hold 0 is taken
        try await gate.waitForEntry()
        let intruder = Task { await runner.fire(job: job, origin: .manual) }
        try await client.waitForArrivals(2)         // it runs, so the held pass will be held again
        await gate.open()
        _ = try await value(of: owner)              // the held pass was answered `.queued`
        #expect(app.urlFireBatches[job.id]?.held.map(\.generation) == [0],
                "the link waits in hold 1 now: its run has not begun")

        await client.turnstile.release()
        try await client.waitForArrivals(3)         // hold 1: the watch and the link, as url
        await client.turnstile.release()
        _ = try await value(of: intruder)
        #expect(app.urlFireBatches[job.id] == nil)
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).contains { $0.triggerKind == "url" })
    }

    @Test("a URL fire merged into a held watch fire keeps both: the watch's paths and the url row")
    func mergedHoldKeepsTheURL() async throws {
        for urlFirst in [false, true] {
            let job = Job(name: "url-watch", prompt: "Reply with just the word tick.",
                          trigger: .fsEvent(FSWatch(path: "/tmp/w")), policy: JobPolicy(overlap: .queue))
            let (store, app, _) = try makeApp([job])
            app.autoApproveTools = true
            let client = TurnstileClient()
            let engine = IrisEngine(state: app, tier: .medium, client: client, protectionEnabled: false, sessionPeerCount: 0)
            let suite = "iris-urlmerge-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer {
                defaults.removePersistentDomain(forName: suite)
                IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
            }
            let runner = JobRunner(state: app, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                                   config: ConfigManager(store: defaults), protectionEnabled: false)
            let first = Task { await runner.fire(job: job, origin: .schedule) }
            try await client.waitForArrivals(1)
            if urlFirst {
                #expect(await runner.fire(job: job, origin: .url) == .queued)
                #expect(await runner.fire(job: job, origin: .watcher(paths: ["/tmp/w/a"])) == .queued)
            } else {
                #expect(await runner.fire(job: job, origin: .watcher(paths: ["/tmp/w/a"])) == .queued)
                #expect(await runner.fire(job: job, origin: .url) == .queued)
            }
            await client.turnstile.release()
            try await client.waitForArrivals(2)
            await client.turnstile.release()
            _ = try await value(of: first)

            let runs = try store.ledger.runs(jobId: job.id, limit: 10)
            let held = try #require(runs.first { $0.triggerKind != "schedule" }, "urlFirst=\(urlFirst)")
            #expect(held.triggerKind == "url", "urlFirst=\(urlFirst)")
            let transcript = try #require(app.conversations.first { $0.id == held.transcriptConversationId })
            let prompt = transcript.history.first?.parts.compactMap(\.text).joined() ?? ""
            #expect(prompt.contains("/tmp/w/a"), "the watch's paths survive the merge, urlFirst=\(urlFirst)")
        }
    }

    @Test("a held fire is released when the held run of its hold begins, and not by a later hold's")
    func heldFireResolution() throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        _ = try optIn(job, store)
        let now = Date()
        app.urlClock = { now }
        let d1 = now.addingTimeInterval(-600), d2 = d1.addingTimeInterval(1), d3 = d1.addingTimeInterval(2)
        func current() throws -> Job { try #require(try store.ledger.job(id: job.id)) }

        // d1 waits in hold 4, d2 in hold 5 (joined after hold 4 was taken).
        app.urlFireBatches[job.id] = URLFireBatch(since: d1, dispatched: [d1, d2, d3], pending: 0,
                                                  held: [HeldURLFire(sent: d1, generation: 4),
                                                         HeldURLFire(sent: d2, generation: 5)])
        // Url rows landing (another fire's) release nothing: only the held run's own report does.
        try urlRows(2, for: job, store)
        #expect(app.urlFireRefusal(for: try current()) == RunJobURL.overLimitReason)

        app.heldURLFireDecided(jobId: job.id, generation: 4)
        #expect(app.urlFireBatches[job.id]?.held == [HeldURLFire(sent: d2, generation: 5)])
        #expect(app.urlFireRefusal(for: try current()) == RunJobURL.overLimitReason, "d2 is still waiting")

        app.heldURLFireDecided(jobId: job.id, generation: 5)
        #expect(app.urlFireBatches[job.id] == nil, "nothing outstanding: the rows alone count")
        #expect(app.urlFireRefusal(for: try current()) == nil)
    }

    @Test("a held fire whose run never reports is counted until it leaves the hour")
    func heldFireWithoutARow() throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        _ = try optIn(job, store)
        let now = Date()
        app.urlClock = { now }
        let d1 = now.addingTimeInterval(-600)
        app.urlFireBatches[job.id] = URLFireBatch(since: d1, dispatched: [d1, d1, d1], pending: 0,
                                                  held: [HeldURLFire(sent: d1, generation: 0)])
        // Its held run has not reported (not begun yet, or dropped): either way it errs strict.
        #expect(app.urlFireRefusal(for: try #require(try store.ledger.job(id: job.id))) == RunJobURL.overLimitReason)

        // Once out of the window it is let go, so a dropped hold cannot block links for ever, even
        // while the job holds something else.
        try store.ledger.setQueuedFire(jobId: job.id, at: now)
        app.urlClock = { now.addingTimeInterval(RunJobURL.window) }
        #expect(app.urlFireRefusal(for: try #require(try store.ledger.job(id: job.id))) == nil)
        #expect(app.urlFireBatches[job.id] == nil)
    }

    @Test("a held origin carrying a URL fire records url at any depth")
    func heldOriginKinds() {
        #expect(FireOrigin.queued(from: .url).triggerKind == "url")
        #expect(FireOrigin.queued(from: .queued(from: .url)).triggerKind == "url")
        #expect(FireOrigin.held(.watcher(paths: ["/a"]), byURL: true).triggerKind == "url")
        #expect(FireOrigin.held(.watcher(paths: ["/a"]), byURL: true).isWatcher)
        #expect(FireOrigin.held(.schedule, byURL: false).triggerKind == "queued")
        #expect(FireOrigin.queued(from: .queuedWithURL(from: .schedule)).triggerKind == "url")
    }
}
