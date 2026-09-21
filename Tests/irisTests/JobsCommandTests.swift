import Testing
import Foundation
@testable import iris

/// #187 §9 — `/jobs` is the deterministic surface: it works in every conversation, never wakes a
/// model turn, and is the only way to acknowledge a failure or delete a job by hand. Parsing and
/// rendering are pure so the table, the failure lines and the run-id matching can be pinned
/// exactly; the handlers are driven through a real in-memory `AppState`.
@MainActor
@Suite("/jobs (#187)")
struct JobsCommandTests {

    // MARK: Fixtures

    private func job(_ name: String = "pr-sweep",
                     trigger: Trigger = .schedule(.interval(seconds: 60)),
                     nextFireAt: Date? = nil,
                     enabled: Bool = true,
                     pausedReason: String? = nil) -> Job {
        Job(name: name, prompt: "do the thing", trigger: trigger, enabled: enabled,
            nextFireAt: nextFireAt, pausedReason: pausedReason)
    }

    private func run(_ job: Job, id: UUID = UUID(), status: JobRun.Status = .completed,
                     startedAt: Date = Date(), outcome: String? = nil,
                     failureReason: String? = nil, acknowledgedAt: Date? = nil) -> JobRun {
        var run = JobRun(id: id, jobId: job.id, jobName: job.name, triggerKind: job.trigger.kind,
                         startedAt: startedAt, status: status)
        run.outcome = outcome
        run.failureReason = failureReason
        run.acknowledgedAt = acknowledgedAt
        return run
    }

    // MARK: parse

    @Test("a bare /jobs lists")
    func parseList() {
        #expect(JobsCommand.parse("/jobs") == .list)
        #expect(JobsCommand.parse("  /jobs  ") == .list)
    }

    @Test("ack takes one run id")
    func parseAck() {
        #expect(JobsCommand.parse("/jobs ack 1a2b3c4d") == .ack(runId: "1a2b3c4d"))
        let full = UUID().uuidString
        #expect(JobsCommand.parse("/jobs ack \(full)") == .ack(runId: full))
    }

    @Test("delete takes the rest of the line as the job name")
    func parseDelete() {
        #expect(JobsCommand.parse("/jobs delete pr-sweep") == .delete(name: "pr-sweep"))
        #expect(JobsCommand.parse("/jobs delete  nightly digest ") == .delete(name: "nightly digest"))
    }

    @Test("an incomplete or unknown subcommand is a usage line, never a silent no-op")
    func parseUsage() {
        #expect(JobsCommand.parse("/jobs ack") == .usage)
        #expect(JobsCommand.parse("/jobs ack  ") == .usage)
        #expect(JobsCommand.parse("/jobs ack a b") == .usage, "a run id is one token")
        #expect(JobsCommand.parse("/jobs delete") == .usage)
        #expect(JobsCommand.parse("/jobs delete   ") == .usage)
        #expect(JobsCommand.parse("/jobs frobnicate") == .usage)
        #expect(JobsCommand.parse("/jobsy") == .usage)
        #expect(JobsCommand.parse("not a command") == .usage)
    }

    @Test("the usage text names all three forms")
    func usageTextSpellsEveryForm() {
        #expect(JobsCommand.usageText == "Usage: /jobs · /jobs ack <run id> · /jobs delete <name>")
    }

    // MARK: matchRun

    @Test("a full uuid matches exactly, in any case")
    func matchFullUUID() {
        let j = job()
        let a = run(j), b = run(j)
        #expect(JobsCommand.matchRun(a.id.uuidString, in: [a, b]) == .found(a.id))
        #expect(JobsCommand.matchRun(a.id.uuidString.lowercased(), in: [a, b]) == .found(a.id))
    }

    @Test("an 8-character prefix is enough when it is unique")
    func matchPrefix() {
        let j = job()
        let a = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!)
        let b = run(j, id: UUID(uuidString: "99999999-0000-0000-0000-000000000002")!)
        #expect(JobsCommand.matchRun("1a2b3c4d", in: [a, b]) == .found(a.id))
        #expect(JobsCommand.matchRun("1A2B3C4D-0000", in: [a, b]) == .found(a.id))
    }

    @Test("a prefix shorter than eight characters matches nothing, however unique it looks")
    func matchTooShort() {
        let j = job()
        let a = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!)
        #expect(JobsCommand.matchRun("1a2b3c", in: [a]) == .none)
        #expect(JobsCommand.matchRun("", in: [a]) == .none)
    }

    @Test("two runs sharing a prefix are ambiguous rather than acknowledging the wrong one")
    func matchAmbiguous() {
        let j = job()
        let a = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!)
        let b = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000002")!)
        #expect(JobsCommand.matchRun("1a2b3c4d", in: [a, b]) == .ambiguous)
        #expect(JobsCommand.matchRun(a.id.uuidString, in: [a, b]) == .found(a.id),
                "a full id is never ambiguous, even when a shorter prefix would be")
    }

    @Test("an unknown id matches nothing")
    func matchNone() {
        let j = job()
        #expect(JobsCommand.matchRun(UUID().uuidString, in: [run(j)]) == .none)
    }

    @Test("hyphens are ignored on both sides, so a paste that lost them still matches")
    func matchIgnoresHyphens() {
        let j = job()
        let a = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!)
        #expect(JobsCommand.matchRun("1a2b3c4d0000", in: [a]) == .found(a.id))
        #expect(JobsCommand.matchRun("1a2b3c4d000000000000000000000001", in: [a]) == .found(a.id))
        #expect(JobsCommand.normalizedRunId(" 1A2B-3C4D ") == "1a2b3c4d")
    }

    // MARK: resolveRun — the shared, window-free lookup

    @Test("a full id resolves by primary key, whatever else is in the table")
    func resolveFullId() throws {
        let store = try ConversationStore.inMemory()
        let j = job()
        try store.ledger.upsert(j)
        let target = run(j, status: .running, startedAt: Date(timeIntervalSince1970: 1))
        try store.ledger.begin(run: target)
        #expect(try JobsCommand.resolveRun(target.id.uuidString, in: store.ledger) == .found(target.id))
        #expect(try JobsCommand.resolveRun(UUID().uuidString, in: store.ledger) == .none)
    }

    /// An unacknowledged failure is exempt from retention, so it can be older than anything a
    /// recency window would return — and it is exactly the run somebody needs to acknowledge. The
    /// resolver reads by prefix instead, so how much has happened since cannot hide it.
    @Test("a failure older than any recent-runs window is still resolvable and ackable")
    func resolveBeyondAnyWindow() throws {
        let store = try ConversationStore.inMemory()
        let j = job()
        try store.ledger.upsert(j)
        let old = run(j, status: .running, startedAt: Date(timeIntervalSince1970: 1))
        try store.ledger.begin(run: old)
        try store.ledger.finish(runId: old.id, status: .failed, outcome: nil, failureReason: "boom",
                                blockedTool: nil, tokens: TokenUsage(),
                                finishedAt: Date(timeIntervalSince1970: 2))
        // Comfortably past the 500-row window the first cut of this read used.
        for i in 1...600 {
            try store.ledger.begin(run: run(j, status: .completed,
                                            startedAt: Date(timeIntervalSince1970: 1_000 + Double(i))))
        }
        #expect(try !store.ledger.runs(jobId: j.id, limit: 500).contains { $0.id == old.id })

        let prefix = String(old.id.uuidString.lowercased().prefix(8))
        #expect(try JobsCommand.resolveRun(prefix, in: store.ledger) == .found(old.id))
        #expect(try JobsCommand.resolveRun(old.id.uuidString, in: store.ledger) == .found(old.id))
    }

    @Test("a prefix that is too short, or that two runs share, resolves to nothing actionable")
    func resolveShortAndAmbiguous() throws {
        let store = try ConversationStore.inMemory()
        let j = job()
        try store.ledger.upsert(j)
        let a = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!, status: .running)
        let b = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000002")!, status: .running)
        for r in [a, b] { try store.ledger.begin(run: r) }

        #expect(try JobsCommand.resolveRun("1a2b3c", in: store.ledger) == .none)
        #expect(try JobsCommand.resolveRun("1a2b3c4d", in: store.ledger) == .ambiguous)
        #expect(try JobsCommand.resolveRun(a.id.uuidString, in: store.ledger) == .found(a.id))
    }

    // MARK: render

    @Test("no jobs says so")
    func renderEmpty() {
        let out = JobsCommand.render(jobs: [], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 0, now: Date())
        #expect(out == "No jobs.")
    }

    @Test("one job renders a table row with its trigger, next fire and last status")
    func renderOneJob() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(180))
        let last = run(j, status: .completed)
        let out = JobsCommand.render(jobs: [j], lastRuns: [j.id: last], unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| Job | Trigger | Next | Last |"))
        #expect(out.contains("| pr-sweep | every 60 s | in 3 m | completed |"))
    }

    @Test("a job that has never run says never")
    func renderNeverRun() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(7_200))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| pr-sweep | every 60 s | in 2 h | never |"))
    }

    @Test("a paused job shows its reason in place of a next fire")
    func renderPaused() {
        let now = Date()
        let j = job(nextFireAt: nil, pausedReason: "no matching time in the next year")
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("paused: no matching time in the next year"))
    }

    @Test("a disabled job says so rather than promising a fire")
    func renderDisabled() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(60), enabled: false)
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| pr-sweep | every 60 s | disabled | never |"))
    }

    @Test("a filesystem watch has no next fire")
    func renderFSEvent() {
        let now = Date()
        let j = job("inbox", trigger: .fsEvent(FSWatch(path: "/tmp/in")))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| inbox | watch /tmp/in | — | never |"))
    }

    @Test("a fire already due, and one days out, both read as time")
    func renderDueAndDistant() {
        let now = Date()
        let due = job("due", nextFireAt: now.addingTimeInterval(-5))
        let far = job("far", nextFireAt: now.addingTimeInterval(3 * 86_400))
        let out = JobsCommand.render(jobs: [due, far], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| due | every 60 s | due | never |"))
        #expect(out.contains("| far | every 60 s | in 3 d | never |"))
    }

    @Test("an unacknowledged failure gets its own line under the table")
    func renderFailureLine() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(60))
        let failed = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!,
                         status: .failed, outcome: "could not reach the API")
        let out = JobsCommand.render(jobs: [j], lastRuns: [j.id: failed], unacknowledged: [failed],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("⚠️ pr-sweep · failed · 1a2b3c4d · could not reach the API"))
    }

    @Test("a blocked run names the failure reason when it produced no outcome")
    func renderBlockedLine() {
        let now = Date()
        let j = job()
        let blocked = run(j, id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!,
                          status: .blockedOnApproval, failureReason: "run_command needed approval")
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], unacknowledged: [blocked],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("⚠️ pr-sweep · blocked on approval · deadbeef · run_command needed approval"))
    }

    @Test("a failure with neither outcome nor reason still lists, without a dangling separator")
    func renderBareFailureLine() {
        let j = job()
        let failed = run(j, id: UUID(uuidString: "0BADF00D-0000-0000-0000-000000000001")!, status: .failed)
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], unacknowledged: [failed],
                                     unreadableJobs: 0, now: Date())
        #expect(out.contains("⚠️ pr-sweep · failed · 0badf00d"))
        #expect(!out.contains("0badf00d · \n") && !out.hasSuffix("· "))
    }

    @Test("unreadable rows are counted out loud rather than silently dropped")
    func renderUnreadableCount() {
        let out = JobsCommand.render(jobs: [], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 2, now: Date())
        #expect(out.contains("2 unreadable job row(s)"))
        let clean = JobsCommand.render(jobs: [], lastRuns: [:], unacknowledged: [],
                                       unreadableJobs: 0, now: Date())
        #expect(!clean.contains("unreadable"))
    }

    @Test("a pipe in a job name cannot forge an extra table column")
    func renderEscapesPipes() {
        let now = Date()
        let j = job("evil | name", nextFireAt: now.addingTimeInterval(60))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("evil \\| name"))
        let row = out.split(separator: "\n").first { $0.contains("evil") } ?? ""
        #expect(row.components(separatedBy: " | ").count == 4, "still four columns: \(row)")
    }

    // MARK: handlers

    private func makeApp(with jobs: [Job]) -> (AppState, UUID) {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        for job in jobs { try? app.store.ledger.upsert(job) }
        return (app, id)
    }

    private func output(_ app: AppState, _ id: UUID) -> String {
        (app.conversations.first { $0.id == id }?.messages ?? [])
            .filter { $0.role == .command }.map(\.content).joined(separator: "\n")
    }

    @Test("/jobs lists the ledger's jobs in the current conversation, without a model turn")
    func listCommand() {
        let j = job(nextFireAt: Date().addingTimeInterval(120))
        let (app, id) = makeApp(with: [j])

        app.sendMessage("/jobs")

        #expect(output(app, id).contains("pr-sweep"))
        #expect(app.conversations.first { $0.id == id }?.history.isEmpty == true,
                "a deterministic command never enters the model's history")
    }

    @Test("/jobs ack clears the failure from the unacknowledged list")
    func ackCommand() throws {
        let j = job()
        let (app, id) = makeApp(with: [j])
        let ledger = app.store.ledger
        let failed = run(j, status: .running)
        try ledger.begin(run: failed)
        try ledger.finish(runId: failed.id, status: .failed, outcome: "boom", failureReason: nil,
                          blockedTool: nil, tokens: TokenUsage(), finishedAt: Date())

        app.sendMessage("/jobs ack \(failed.id.uuidString.prefix(8))")

        #expect(try ledger.unacknowledgedFailures().isEmpty)
        #expect(try ledger.run(id: failed.id)?.acknowledgedAt != nil)
        #expect(output(app, id).lowercased().contains("acknowledged"))
    }

    @Test("an ack naming no run says so rather than reporting success")
    func ackUnknownRun() {
        let (app, id) = makeApp(with: [job()])

        app.sendMessage("/jobs ack abc")

        #expect(output(app, id).contains("No run matching 'abc'."))
    }

    @Test("an ambiguous prefix acknowledges neither run")
    func ackAmbiguousPrefix() throws {
        let j = job()
        let (app, id) = makeApp(with: [j])
        let ledger = app.store.ledger
        let a = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!, status: .running)
        let b = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000002")!, status: .running)
        for r in [a, b] {
            try ledger.begin(run: r)
            try ledger.finish(runId: r.id, status: .failed, outcome: nil, failureReason: "boom",
                              blockedTool: nil, tokens: TokenUsage(), finishedAt: Date())
        }

        app.sendMessage("/jobs ack 1a2b3c4d")

        #expect(output(app, id).contains("Ambiguous run id prefix."))
        #expect(try ledger.unacknowledgedFailures().count == 2)
    }

    @Test("/jobs delete removes the job and cascades its runs")
    func deleteCommand() throws {
        let j = job()
        let (app, id) = makeApp(with: [j])
        let ledger = app.store.ledger
        let r = run(j, status: .running)
        try ledger.begin(run: r)
        try ledger.finish(runId: r.id, status: .completed, outcome: nil, failureReason: nil,
                          blockedTool: nil, tokens: TokenUsage(), finishedAt: Date())

        app.sendMessage("/jobs delete pr-sweep")

        #expect(try ledger.job(named: "pr-sweep") == nil)
        #expect(try ledger.run(id: r.id) == nil, "a run cannot outlive its job")
        #expect(output(app, id).contains("pr-sweep"))
        #expect(output(app, id).contains("1 run(s)"), "say how much evidence went with it")
    }

    /// Deleting the job under a run in flight cascades away the very row that run is about to
    /// `finish`, which fails with `unknownRun` and tells the person nothing about the work they
    /// interrupted. Refusing is the recoverable half: the run ends, or the next launch interrupts
    /// it, and then the delete goes through.
    @Test("/jobs delete refuses while a run is still in flight")
    func deleteRefusedWhileRunning() throws {
        let j = job()
        let (app, id) = makeApp(with: [j])
        let ledger = app.store.ledger
        let inFlight = run(j, status: .running)
        try ledger.begin(run: inFlight)

        app.sendMessage("/jobs delete pr-sweep")

        #expect(output(app, id).contains("'pr-sweep' is running; wait for it to finish or let it be interrupted at next launch."))
        #expect(try ledger.job(named: "pr-sweep") != nil, "nothing was deleted")
        #expect(try ledger.run(id: inFlight.id) != nil)
    }

    @Test("once that run has finished the same delete goes through")
    func deleteAllowedAfterRunFinishes() throws {
        let j = job()
        let (app, id) = makeApp(with: [j])
        let ledger = app.store.ledger
        let r = run(j, status: .running)
        try ledger.begin(run: r)
        try ledger.finish(runId: r.id, status: .completed, outcome: "done", failureReason: nil,
                          blockedTool: nil, tokens: TokenUsage(), finishedAt: Date())

        app.sendMessage("/jobs delete pr-sweep")

        #expect(try ledger.job(named: "pr-sweep") == nil)
        #expect(output(app, id).contains("1 run(s)"))
    }

    @Test("deleting a job that is not there names it rather than reporting a deletion")
    func deleteUnknownJob() throws {
        let (app, id) = makeApp(with: [job()])

        app.sendMessage("/jobs delete nightly")

        #expect(output(app, id).contains("No job named 'nightly'."))
        #expect(try app.store.ledger.job(named: "pr-sweep") != nil)
    }

    @Test("a malformed /jobs prints the usage line")
    func usageCommand() {
        let (app, id) = makeApp(with: [])

        app.sendMessage("/jobs ack")

        #expect(output(app, id).contains(JobsCommand.usageText))
    }

    @Test("/jobs is offered in the slash-command palette")
    func inPalette() {
        #expect(SlashCommandItem.allCommands.map(\.command).contains("/jobs"))
    }
}
