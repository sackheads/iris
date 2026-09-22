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

    @Test("pause, resume and run each take the rest of the line as the job name")
    func parsePauseResumeRun() {
        #expect(JobsCommand.parse("/jobs pause pr-sweep") == .pause(name: "pr-sweep"))
        #expect(JobsCommand.parse("/jobs resume pr-sweep") == .resume(name: "pr-sweep"))
        #expect(JobsCommand.parse("/jobs run pr-sweep") == .run(name: "pr-sweep"))
        #expect(JobsCommand.parse("/jobs run  nightly digest ") == .run(name: "nightly digest"))
        #expect(JobsCommand.parse("/jobs pause") == .usage)
        #expect(JobsCommand.parse("/jobs resume  ") == .usage)
        #expect(JobsCommand.parse("/jobs run") == .usage)
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

    @Test("the usage text names every form")
    func usageTextSpellsEveryForm() {
        #expect(JobsCommand.usageText == "Usage: /jobs · /jobs ack <run id> · /jobs pause <name> · "
                + "/jobs resume <name> · /jobs run <name> · /jobs delete <name>")
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
        let out = JobsCommand.render(jobs: [], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: Date())
        #expect(out == "No jobs.")
    }

    @Test("one job renders a table row with its trigger, next fire and last status")
    func renderOneJob() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(180))
        let last = run(j, status: .completed)
        let out = JobsCommand.render(jobs: [j], lastRuns: [j.id: last], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| Job | Trigger | Policy | Next | Last | Tokens today | Runs/h |"))
        #expect(out.contains("| pr-sweep | every 60 s | default | in 3 m | completed | — | — |"))
    }

    @Test("a job that has never run says never")
    func renderNeverRun() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(7_200))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| pr-sweep | every 60 s | default | in 2 h | never | — | — |"))
    }

    @Test("a job part-way up the retry ladder says where it is")
    func renderRetryAttempt() {
        let now = Date()
        var j = job(nextFireAt: now.addingTimeInterval(300))
        j.retryAttempt = 2
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("in 5 m · retry 2/3"))
        // And a job that is not retrying says nothing about retries at all.
        let clean = JobsCommand.render(jobs: [job(nextFireAt: now.addingTimeInterval(300))],
                                       lastRuns: [:], usage: .empty, unacknowledged: [],
                                       unreadableJobs: 0, now: now)
        #expect(!clean.contains("retry"))
    }

    @Test("a paused job shows its reason in place of a next fire")
    func renderPaused() {
        let now = Date()
        let j = job(nextFireAt: nil, pausedReason: "no matching time in the next year")
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("paused: no matching time in the next year"))
    }

    @Test("a disabled job says so rather than promising a fire")
    func renderDisabled() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(60), enabled: false)
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| pr-sweep | every 60 s | default | disabled | never | — | — |"))
    }

    @Test("a filesystem watch has no next fire")
    func renderFSEvent() {
        let now = Date()
        let j = job("inbox", trigger: .fsEvent(FSWatch(path: "/tmp/in")))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| inbox | watch /tmp/in | default | — | never | — | — |"))
        // The watch line sits beneath the table (a table row cannot carry a second line): no
        // row with a summary yet, and no coordinator handed in, so both halves say so.
        #expect(out.contains("`inbox` — last burst: nothing fired yet · absorbed since launch: —"))
    }

    // MARK: The watch line and the policy column (#187 deliverable 4, spec §6)

    @Test("the watch line reads the last burst from the ledger and the absorbed totals from the coordinator")
    func watchLineWithBothHalves() throws {
        let now = Date()
        let j = job("notes", trigger: .fsEvent(FSWatch(path: "/tmp/notes")))
        let burst = WatchSummary(delivered: 12, changed: 12, coalesced: 30, noise: 3, ownWrites: 1,
                                 ceilingFired: true)
        let absorbed = AbsorbedCounts(noise: 41, ownWrites: 7, whilePaused: 3)
        let expected = "`notes` — last burst: 12 changes · 3 noise · 1 own writes (cut at 30 s) · "
            + "absorbed since launch: 41 noise · 7 own writes · 3 while paused"
        #expect(JobsCommand.watchLine(job: j, lastBurst: burst, absorbed: absorbed,
                                      hasCoordinator: true) == expected)

        // Through `render`, the line follows the table and precedes the daily footer.
        let usage = JobsCommand.UsageSnapshot(
            perJob: [:], global: JobsCommand.GlobalUsage(tokensToday: 10, dailyBudget: 100))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: usage, unacknowledged: [],
                                     unreadableJobs: 0, now: now,
                                     lastBursts: [j.id: burst], absorbed: [j.id: absorbed])
        let table = try #require(out.range(of: "| notes |"))
        let line = try #require(out.range(of: expected))
        let footer = try #require(out.range(of: "Tokens today, all jobs:"))
        #expect(table.lowerBound < line.lowerBound && line.lowerBound < footer.lowerBound)

        // A live coordinator that has absorbed nothing says zero; with no coordinator at all
        // the half is a dash, since "0" would be a claim the process cannot make.
        #expect(JobsCommand.watchLine(job: j, lastBurst: nil, absorbed: nil, hasCoordinator: true)
                == "`notes` — last burst: nothing fired yet · absorbed since launch: "
                   + "0 noise · 0 own writes · 0 while paused")
        #expect(JobsCommand.watchLine(job: j, lastBurst: nil, absorbed: nil, hasCoordinator: false)
                == "`notes` — last burst: nothing fired yet · absorbed since launch: —")
    }

    @Test("two watch lines are separate paragraphs, not one run-on line")
    func twoWatchLinesStayApart() throws {
        // Seen on screen: the block is markdown, and a single newline between two watch lines
        // renders as a space, so `/jobs` showed "… 0 while paused `sub` — last burst: …" as one
        // sentence. Each watch gets its own paragraph.
        let a = job("alpha", trigger: .fsEvent(FSWatch(path: "/tmp/alpha")))
        let b = job("beta", trigger: .fsEvent(FSWatch(path: "/tmp/beta")))
        let out = JobsCommand.render(jobs: [a, b], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: Date())
        let first = try #require(out.range(of: "`alpha` — last burst:"))
        let second = try #require(out.range(of: "`beta` — last burst:"))
        let between = out[first.upperBound..<second.lowerBound]
        #expect(between.contains("\n\n"), "the two lines were joined by a single newline:\n\(out)")
    }

    @Test("a wider quiet window shows in the policy column and in the ceiling the line prints")
    func watchLineWithAWiderWindow() {
        let j = job("notes", trigger: .fsEvent(FSWatch(path: "/tmp/notes", quietWindowSeconds: 10)))
        #expect(JobsCommand.policySummary(for: j) == "quiet 10 s")
        let line = JobsCommand.watchLine(job: j, lastBurst: WatchSummary(changed: 2, ceilingFired: true),
                                         absorbed: nil, hasCoordinator: false)
        #expect(line.contains("last burst: 2 changes (cut at 100 s)"))
        // The default window is the default: nothing to say in the policy column.
        #expect(JobsCommand.policySummary(for: job("x", trigger: .fsEvent(FSWatch(path: "/tmp/x"))))
                == "default")
    }

    @Test("the policy column counts the watch's own ignore globs")
    func ignoreCountInThePolicyColumn() {
        var j = job("notes", trigger: .fsEvent(FSWatch(path: "/tmp/notes", ignore: ["*.log", "build/"])))
        #expect(JobsCommand.policySummary(for: j) == "2 ignore")
        j.profile = .mutating
        j.trigger = .fsEvent(FSWatch(path: "/tmp/notes", quietWindowSeconds: 10, ignore: ["*.log", "build/"]))
        #expect(JobsCommand.policySummary(for: j) == "mutating · quiet 10 s · 2 ignore")
    }

    @Test("a fire already due, and one days out, both read as time")
    func renderDueAndDistant() {
        let now = Date()
        let due = job("due", nextFireAt: now.addingTimeInterval(-5))
        let far = job("far", nextFireAt: now.addingTimeInterval(3 * 86_400))
        let out = JobsCommand.render(jobs: [due, far], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| due | every 60 s | default | due | never | — | — |"))
        #expect(out.contains("| far | every 60 s | default | in 3 d | never | — | — |"))
    }

    @Test("an unacknowledged failure gets its own line under the table")
    func renderFailureLine() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(60))
        let failed = run(j, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000001")!,
                         status: .failed, outcome: "could not reach the API")
        let out = JobsCommand.render(jobs: [j], lastRuns: [j.id: failed], usage: .empty, unacknowledged: [failed],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("⚠️ pr-sweep · failed · 1a2b3c4d · could not reach the API"))
    }

    @Test("a blocked run names the failure reason when it produced no outcome")
    func renderBlockedLine() {
        let now = Date()
        let j = job()
        let blocked = run(j, id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!,
                          status: .blockedOnApproval, failureReason: "run_command needed approval")
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [blocked],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("⚠️ pr-sweep · blocked on approval · deadbeef · run_command needed approval"))
    }

    @Test("a failure with neither outcome nor reason still lists, without a dangling separator")
    func renderBareFailureLine() {
        let j = job()
        let failed = run(j, id: UUID(uuidString: "0BADF00D-0000-0000-0000-000000000001")!, status: .failed)
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [failed],
                                     unreadableJobs: 0, now: Date())
        #expect(out.contains("⚠️ pr-sweep · failed · 0badf00d"))
        #expect(!out.contains("0badf00d · \n") && !out.hasSuffix("· "))
    }

    @Test("unreadable rows are counted out loud rather than silently dropped")
    func renderUnreadableCount() {
        let out = JobsCommand.render(jobs: [], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 2, now: Date())
        #expect(out.contains("2 unreadable job row(s)"))
        let clean = JobsCommand.render(jobs: [], lastRuns: [:], usage: .empty, unacknowledged: [],
                                       unreadableJobs: 0, now: Date())
        #expect(!clean.contains("unreadable"))
    }

    @Test("a pipe in a job name cannot forge an extra table column")
    func renderEscapesPipes() {
        let now = Date()
        let j = job("evil | name", nextFireAt: now.addingTimeInterval(60))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("evil \\| name"))
        let row = out.split(separator: "\n").first { $0.contains("evil") } ?? ""
        #expect(row.components(separatedBy: " | ").count == 7, "still seven columns: \(row)")
    }

    // MARK: observability (§0.1, §9)

    /// Fixed figures, so the columns are pinned to numbers rather than to whatever this machine's
    /// settings and ledger happen to hold (invariant 7).
    private func figures(tokens: Int = 620_000, runs: Int = 2, dailyTokens: Int = 1_000_000,
                         maxRunsPerHour: Int = 6, globalDailyTokens: Int = 3_000_000)
        -> JobsCommand.JobFigures {
        JobsCommand.JobFigures(
            tokensToday: tokens, runsLastHour: runs,
            limits: JobLimits(maxRunsPerHour: maxRunsPerHour, dailyTokens: dailyTokens,
                              globalDailyTokens: globalDailyTokens, perRunTokens: 200_000,
                              runTimeoutSeconds: 600))
    }

    @Test("a job prints what it has spent today and how hard it has been running")
    func renderUsageColumns() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(180))
        let out = JobsCommand.render(
            jobs: [j], lastRuns: [:],
            usage: JobsCommand.UsageSnapshot(perJob: [j.id: figures()], global: nil),
            unacknowledged: [], unreadableJobs: 0, now: now)
        #expect(out.contains("| Job | Trigger | Policy | Next | Last | Tokens today | Runs/h |"))
        #expect(out.contains("| 620k / 1M (62%) | 2 / 6 |"))
    }

    @Test("a job whose figures could not be read still lists, with nothing invented")
    func renderUsageMissing() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(180))
        let out = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| pr-sweep | every 60 s | default | in 3 m | never | — | — |"))
    }

    @Test("a zero budget or breaker reads as unlimited rather than as a percentage of nothing")
    func renderUnlimitedFigures() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(180))
        let out = JobsCommand.render(
            jobs: [j], lastRuns: [:],
            usage: JobsCommand.UsageSnapshot(
                perJob: [j.id: figures(tokens: 500, runs: 3, dailyTokens: 0, maxRunsPerHour: 0)],
                global: nil),
            unacknowledged: [], unreadableJobs: 0, now: now)
        #expect(out.contains("| 500 / unlimited | 3 / unlimited |"))
    }

    @Test("the footer carries the whole unattended system's spend for the day")
    func renderGlobalFooter() {
        let now = Date()
        let j = job(nextFireAt: now.addingTimeInterval(180))
        let out = JobsCommand.render(
            jobs: [j], lastRuns: [:],
            usage: JobsCommand.UsageSnapshot(
                perJob: [j.id: figures()],
                global: JobsCommand.GlobalUsage(tokensToday: 1_200_000, dailyBudget: 3_000_000)),
            unacknowledged: [], unreadableJobs: 0, now: now)
        #expect(out.contains("Tokens today, all jobs: 1.2M / 3M (40%)"))
        // And no footer at all when the ledger could not answer.
        let quiet = JobsCommand.render(jobs: [j], lastRuns: [:], usage: .empty, unacknowledged: [],
                                       unreadableJobs: 0, now: now)
        #expect(!quiet.contains("all jobs"))
    }

    @Test("a job on the default policy says so, and every departure from it is named")
    func renderPolicyColumn() {
        let now = Date()
        #expect(JobsCommand.policySummary(for: job()) == "default")

        var loud = Job(name: "loud", prompt: "go",
                       trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                               gate: .urlChanged(url: "https://example.com"))),
                       profile: .mutating)
        loud.policy.overlap = .queue
        loud.policy.catchUp = .replay(cap: 5)
        // The gate is the Trigger column's to print — `poll every 60 s (url gate)` — so the policy
        // cell does not print it a second time.
        #expect(JobsCommand.policySummary(for: loud) == "mutating · overlap queue · catch-up replay 5")

        var quiet = job()
        quiet.policy.catchUp = .skip
        #expect(JobsCommand.policySummary(for: quiet) == "catch-up skip")

        let out = JobsCommand.render(jobs: [loud], lastRuns: [:], usage: .empty, unacknowledged: [],
                                     unreadableJobs: 0, now: now)
        #expect(out.contains("| mutating · overlap queue · catch-up replay 5 |"))
        #expect(out.contains("| poll every 60 s (url gate) |"), "and the gate is named once, by the trigger")
    }

    @Test("the snapshot's figures are the ledger's own sums, read through the same seams admission uses")
    func usageSnapshotReadsTheLedger() throws {
        let store = try ConversationStore.inMemory()
        let name = "iris-jobs-usage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: defaults)
        config.jobDailyTokenBudget = 50_000
        config.jobMaxRunsPerHour = 9
        config.jobGlobalDailyTokenBudget = 400_000

        let now = Date()
        let j = job()
        try store.ledger.upsert(j)
        for tokens in [1_000, 2_500] {
            let r = JobRun(jobId: j.id, jobName: j.name, triggerKind: "schedule", startedAt: now,
                           transcriptConversationId: UUID())
            try store.ledger.begin(run: r)
            try store.ledger.finish(runId: r.id, status: .completed, outcome: "did it",
                                    failureReason: nil, blockedTool: nil,
                                    tokens: TokenUsage(promptTokenCount: tokens, candidatesTokenCount: 0,
                                                       totalTokenCount: tokens),
                                    finishedAt: now)
        }

        let snapshot = JobsCommand.usageSnapshot(jobs: [j], ledger: store.ledger, config: config,
                                                 now: now, calendar: .current)
        let figures = try #require(snapshot.perJob[j.id])
        #expect(figures.tokensToday == 3_500)
        #expect(figures.runsLastHour == 2)
        #expect(figures.limits.dailyTokens == 50_000)
        #expect(figures.limits.maxRunsPerHour == 9)
        #expect(snapshot.global == JobsCommand.GlobalUsage(tokensToday: 3_500, dailyBudget: 400_000))

        let rendered = JobsCommand.render(jobs: [j], lastRuns: [:], usage: snapshot,
                                          unacknowledged: [], unreadableJobs: 0, now: now)
        #expect(rendered.contains("| 4k / 50k (7%) | 2 / 9 |"))
    }

    @Test("the usage line names every form the command takes")
    func usageTextNamesEveryForm() {
        for form in ["/jobs ack", "/jobs pause", "/jobs resume", "/jobs run", "/jobs delete"] {
            #expect(JobsCommand.usageText.contains(form), "usage text is missing \(form)")
        }
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
    func listCommand() async {
        let j = job(nextFireAt: Date().addingTimeInterval(120))
        let (app, id) = makeApp(with: [j])

        app.sendMessage("/jobs")

        // The listing is one hop away: it awaits the watch coordinator for the absorbed totals
        // before it renders (spec §6), so the transcript fills in a moment after the send.
        #expect(await eventually { output(app, id).contains("pr-sweep") })
        #expect(app.conversations.first { $0.id == id }?.history.isEmpty == true,
                "a deterministic command never enters the model's history")
    }

    /// Polls the main actor until `condition` holds or `timeoutMs` passes.
    private func eventually(_ timeoutMs: Int = 3000, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
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
