import Foundation

/// 5b §0.7: once a day, a card in Iris built from the run ledger — no model call, so it is free and
/// cannot invent anything. The first built-in job (§0.8).
///
/// Every word on the card is harness-owned, the briefing's rule (`Briefing`): job names go through
/// `Briefing.name`, failures and pauses through `Briefing.reason` / `pausedWord`, and no run's
/// `outcome` or `failureReason` text is ever copied. The card reaches Iris's history through
/// `deliverEvent`'s guard anyway; the rule holds regardless, because a guard is a second line, not
/// a licence to pass fetched words along under the harness's name.
struct DailyDigest: BuiltinJob {
    static let name = "daily_digest"

    /// Set once registration has happened, so a digest the owner deleted stays deleted (§0.8).
    static let digestRegisteredMetaKey = "daily_digest_registered"

    static let jobName = "Daily digest"
    /// Used only when `jobName` is already taken by a job of the owner's (names are unique).
    static let fallbackJobName = "Daily digest (built-in)"
    /// 10:00 local: the owner's laptop is most likely open then (§0.7).
    static let cronExpression = "0 10 * * *"

    /// A build from before 5b ignores `action` and would run this job's `prompt` as a model turn,
    /// so the prompt has to be harmless there: it asks for one fixed line and nothing else.
    static let downgradePrompt = "This is Iris's built-in daily digest; it runs without a model. If you are reading this, reply only: 'Daily digest skipped — this build cannot run built-in jobs.'"

    /// The whole outcome, in UTF-8 bytes. Never `String.count`: one letter carrying 50,000
    /// combining marks is one Character (#187 review).
    static let outcomeMaxBytes = 4_096

    /// The window when no digest has completed before.
    static let defaultWindow: TimeInterval = 24 * 3_600

    static let quietOutcome = "quiet: no job ran since the last digest"
    static let unreadableOutcome = "the daily digest could not read the run ledger"
    /// The failed row's `failureReason` when the ledger could not be read. A failure, not a
    /// completion: recording it as completed would close the next digest's window over runs this
    /// one never reported.
    static let unreadableReason = "daily digest: ledger unreadable"

    /// `config` is the runner's, so the budgets on the card are the ones admission enforces
    /// (`JobLimits.resolve`), not the process-global ones.
    func run(ledger: JobLedger, now: Date, calendar: Calendar, config: ConfigManager) async -> BuiltinResult {
        let jobs: [Job]
        let runs: [JobRun]
        let failures: [JobRun]
        var usage: [UUID: Int] = [:]
        do {
            let since = try ledger.lastCompletedRunStart(action: .builtin(Self.name), before: now)
                ?? now.addingTimeInterval(-Self.defaultWindow)
            runs = try ledger.digestRuns(since: since, until: now)
            // A quiet day posts nothing, whatever else is outstanding (§0.7).
            guard !runs.isEmpty else { return BuiltinResult(outcome: Self.quietOutcome, card: false) }
            jobs = try ledger.jobs()
            failures = try ledger.unacknowledgedFailures()
            for id in Set(runs.map(\.jobId)) {
                usage[id] = try ledger.usage(jobId: id, now: now, calendar: calendar).tokensToday
            }
        } catch {
            // Carded: a digest that silently stopped arriving is the failure it exists to prevent.
            return BuiltinResult(outcome: Self.unreadableOutcome, card: true,
                                 status: .failed(reason: Self.unreadableReason))
        }
        return BuiltinResult(outcome: Self.outcome(jobs: jobs, runs: runs, failures: failures,
                                                   tokensToday: usage, config: config),
                             card: true)
    }

    /// Pure, so the card's text can be pinned without a ledger. One line per job that ran in the
    /// window, in the order of first run; then the unacknowledged failures; then the paused jobs.
    static func outcome(jobs: [Job], runs: [JobRun], failures: [JobRun], tokensToday: [UUID: Int],
                        config: ConfigManager,
                        knownTools: Set<String> = IrisEngine.allDeclaredToolNames) -> String {
        let byId = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [UUID] = []
        var grouped: [UUID: [JobRun]] = [:]
        for run in runs {
            if grouped[run.jobId] == nil { order.append(run.jobId) }
            grouped[run.jobId, default: []].append(run)
        }
        var lines: [String] = order.map { id in
            let group = grouped[id] ?? []
            let job = byId[id]
            func count(_ status: JobRun.Status) -> Int { group.filter { $0.status == status }.count }
            // Quoted, as the briefing does: a bare name like `x: 9 completed` could pose as a count.
            var line = "\(Briefing.quoted(job?.name ?? group.first?.jobName ?? "")): "
                + "\(count(.completed)) completed, \(count(.failed)) failed"
            // Only when there are any, so the common line keeps its two counts.
            let blocked = count(.blockedOnApproval), interrupted = count(.interrupted)
            if blocked > 0 { line += ", \(blocked) blocked" }
            if interrupted > 0 { line += ", \(interrupted) interrupted" }
            if let job {
                let budget = JobLimits.resolve(job: job, config: config).dailyTokens
                // A zero budget is "no budget" (admission skips it), not a ceiling of zero.
                let ceiling = budget > 0 ? "\(budget)" : "unlimited"
                line += " · \(tokensToday[id] ?? 0)/\(ceiling) tokens today"
            }
            return line
        }
        lines += failures.map {
            "Unacknowledged failure: \(Briefing.quoted($0.jobName)) · \(Briefing.reason($0, knownTools: knownTools)) (run \(Briefing.short($0.id)))"
        }
        lines += jobs.filter { $0.pausedReason != nil }.map {
            "Paused: \(Briefing.quoted($0.name)) · \(Briefing.pausedWord($0.pausedReason)) (job \(Briefing.short($0.id)))"
        }
        return capped(lines)
    }

    /// Whole lines while they fit, then a count of the rest — so a cut never leaves half a line
    /// that reads as a different fact. Every line is already short (names are capped at 90 bytes),
    /// but there can be any number of them.
    static func capped(_ lines: [String]) -> String {
        let all = lines.joined(separator: "\n")
        guard all.utf8.count > outcomeMaxBytes else { return all }
        // Room for the longest marker this can write.
        let reserve = "\n… and \(lines.count) more lines".utf8.count
        var kept: [String] = []
        var used = 0
        for line in lines {
            let cost = line.utf8.count + (kept.isEmpty ? 0 : 1)
            if used + cost > outcomeMaxBytes - reserve { break }
            kept.append(line)
            used += cost
        }
        let marker = "… and \(lines.count - kept.count) more lines"
        let body = kept.isEmpty ? marker : kept.joined(separator: "\n") + "\n" + marker
        // Belt and braces: a single line can never exceed the cap above, but the cap is the promise.
        return ConversationReader.utf8Prefix(body, maxBytes: outcomeMaxBytes)
    }
}

extension DailyDigest {
    /// The digest as it is first registered: 10:00 in `timeZone`, coalescing missed mornings into
    /// one, delivered to Iris. No destination id on purpose: `JobRunner.destination` sends a job
    /// with none to `activityConversationId()`, which follows Iris across `/new`'s rotation —
    /// a fixed id would keep posting into the archived Iris.
    static func job(timeZone: TimeZone, name: String = jobName) -> Job {
        Job(name: name, prompt: downgradePrompt,
            trigger: .schedule(.cron(CronSchedule(expression: cronExpression, timeZone: timeZone.identifier))),
            policy: JobPolicy(catchUp: .coalesce),
            action: .builtin(Self.name))
    }

    /// The marker's values. `pending`: claimed, the job may not exist yet. `registered`: the job
    /// was scheduled. `adopted`: a digest job was found without a marker. Any value but `pending`
    /// means registration is over for this store.
    static let markerPending = "pending"
    static let markerRegistered = "registered"
    static let markerAdopted = "adopted"

    /// Registers the digest the first time it is ever called on this store, and never again
    /// (§0.8): once the marker says `registered`, a deleted digest stays deleted.
    ///
    /// Three steps, so no crash between them loses the digest: the marker is *claimed* as
    /// `pending` atomically (two launches racing — `AppState.start` can run more than once — cannot
    /// both win the claim), then the job is scheduled, then the marker is set to `registered`. A
    /// launch that finds `pending` and no digest job — a crash before the schedule, or a schedule
    /// that failed — schedules it then; `pending` with a digest job only finishes the marker. The
    /// marker is never removed, so a launch whose schedule loses a race (the jobs table's unique
    /// name lets only one digest in) cannot reopen registration. A digest job found with no marker
    /// at all is adopted, not doubled.
    static func registerDigestOnce(ledger: JobLedger, store: ConversationStore,
                                   scheduler: JobScheduler, timeZone: TimeZone) async {
        do {
            let marker = try store.metaValue(forKey: digestRegisteredMetaKey)
            if let marker, marker != markerPending { return }
            let existing = try ledger.jobs()
            if existing.contains(where: { $0.action == .builtin(Self.name) }) {
                if marker == nil {
                    _ = try store.insertMetaValueIfAbsent(markerAdopted, forKey: digestRegisteredMetaKey)
                } else {
                    try store.setMetaValue(markerRegistered, forKey: digestRegisteredMetaKey)
                }
                return
            }
            if marker == nil {
                guard try store.insertMetaValueIfAbsent(markerPending, forKey: digestRegisteredMetaKey) else { return }
            }
            let taken = Set(existing.map(\.name))
            let name = taken.contains(jobName) ? fallbackJobName : jobName
            do {
                try await scheduler.schedule(job(timeZone: timeZone, name: name))
                try store.setMetaValue(markerRegistered, forKey: digestRegisteredMetaKey)
            } catch {
                // The marker stays `pending`, so the next launch tries again.
                print("[DailyDigest] could not register the daily digest: \(error)")
            }
        } catch {
            print("[DailyDigest] could not check the daily digest's registration: \(error)")
        }
    }
}
