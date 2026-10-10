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

    @Test("two links for a job at the limit's edge, arriving together, fire once")
    func concurrentAtTheEdge() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        try urlRows(2, for: job, store)
        // Back to back on the main actor: the first fire's task has not run, so its row is not
        // written when the second link is counted.
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .refused)
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(try store.ledger.urlFires(jobId: job.id, since: Date().addingTimeInterval(-RunJobURL.window)) == 3)
    }

    @Test("links racing from zero: three fire, the fourth is refused")
    func concurrentFromZero() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        let outcomes = (0..<4).map { _ in app.handleRunJobURL(link(minted), identity: .dev) }
        #expect(outcomes == [.fired(job.id), .fired(job.id), .fired(job.id), .refused])
        _ = try await value(of: try #require(app.urlFireTask))
    }

    @Test("a fire in flight whose row is already written is counted once, not twice")
    func inFlightRowIsNotDoubleCounted() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        let start = Date()
        app.urlClock = { start }
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        // The row that first fire writes, landing while it is still in flight.
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "url",
                         startedAt: start.addingTimeInterval(0.5), transcriptConversationId: UUID())
        try store.ledger.begin(run: run)
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .refused)
        _ = try await value(of: try #require(app.urlFireTask))
    }

    @Test("once every fire has settled, the rows alone are counted")
    func settledFiresFallBackToRows() async throws {
        let job = digest()
        let (store, app, _) = try makeApp([job])
        let minted = try optIn(job, store)
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        _ = try await value(of: try #require(app.urlFireTask))
        #expect(app.urlFireBatches[job.id] == nil)
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .fired(job.id))
        #expect(app.handleRunJobURL(link(minted), identity: .dev) == .refused)
        _ = try await value(of: try #require(app.urlFireTask))
    }
}
