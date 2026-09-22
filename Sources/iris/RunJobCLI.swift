import Foundation

/// The lock file the running app holds beside the conversation store, so a `--run-job` from a
/// terminal refuses rather than races it (#187 spec §8, ruling R35).
///
/// GRDB's WAL would survive two writers, but `AppState` holds conversation state in memory: a CLI
/// write behind a live app desyncs the UI, and the app then saves its stale copy over the top.
/// Refusing costs the user one "quit the app first"; racing costs them conversations.
///
/// The file holds the holder's pid and nothing else, because the interesting failure is not the
/// app running — it is the app having *crashed*. A bare "the file exists" lock would then refuse
/// every run until someone found and deleted it. A pid the kernel no longer knows about is stale
/// and ignored. (Pid reuse can in principle resurrect a stale lock; the window is a reboot's worth
/// of pid wraparound, and the cost is the same recoverable refusal.)
///
/// Every write here is best-effort: a GUI that cannot create its lock must still launch. The worst
/// case is exactly today's behaviour, a CLI that does not know the app is up.
enum GUILock {
    /// What is holding the lock right now.
    enum State: Equatable {
        /// Nothing holds it: no file, or a file naming a process that is gone.
        case free
        case app(pid: Int32)
        /// A file that is there but says nothing a pid check can be made of. Held, not free:
        /// refusing is recoverable (delete it), and two writers at the store is not.
        case unreadable(path: String)
    }

    static func state(at url: URL) -> State {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .free }
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            return .unreadable(path: url.path)
        }
        // Signal 0 asks the kernel whether the process exists without sending anything. `EPERM`
        // means it exists and belongs to somebody else — still alive, still holding the store.
        if kill(pid, 0) == 0 { return .app(pid: pid) }
        return errno == ESRCH ? .free : .app(pid: pid)
    }

    /// Claims the lock for this process. Called once, at app launch.
    static func acquire(at url: URL = IrisPaths.default.guiLockFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: url, options: .atomic)
    }

    /// Gives it back, if it is ours to give: a lock file naming another live process belongs to
    /// another app instance, and this one must not delete it on its way out.
    static func release(at url: URL = IrisPaths.default.guiLockFile) {
        guard case .app(let pid) = state(at: url),
              pid == ProcessInfo.processInfo.processIdentifier else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// `iris --run-job <id-or-name> [--dry-run] [--json]` (#187 spec §0.5, §8, ruling R35): one job,
/// fired once, headless, against the real store, printing the ledger row it wrote.
///
/// What it is for: measuring a job before trusting it. Run a new job or a new gate on demand and
/// read its row — status, tokens, duration, gate signal — without waiting for its cadence; feed a
/// gate's verdicts to an eval harness; debug a misbehaving job from a terminal under exactly the
/// rules it has unattended. It is **not** a way to run jobs in production: no scheduler is
/// started, no watchers, no window, and the process exits the moment the run returns.
///
/// Fail-closed by construction (§8): no `HeadlessMode`, no volatile defaults, and
/// `autoApproveTools` left off — a tool call that needs a human in a CLI run is blocked and
/// recorded exactly as it would be at 3 a.m. with nobody at the keyboard. The sleep assertion is
/// the run's own (`JobRunner` takes and releases one per run), so the CLI keeps the Mac awake for
/// the run and not a second longer.
enum RunJobCLI {
    static let usage = "usage: iris --run-job <id-or-name> [--dry-run] [--json]"

    /// The exit codes, spelled once (§8). A script reads these; nothing else may drift from them.
    enum Exit {
        /// The run completed — or, with `--dry-run`, the gate says something changed.
        static let completed: Int32 = 0
        /// Usage, a job nobody has, a store that would not open, or the app holding the lock.
        static let usage: Int32 = 1
        /// The run did not complete: `failed`, `blocked on approval`, an admission refusal, or a
        /// gate that could not answer.
        static let notCompleted: Int32 = 2
        /// The gate looked and nothing had moved.
        static let gateUnchanged: Int32 = 3
    }

    /// What the command line said. A parse never fails outright: `--run-job` with something
    /// unusable after it is still this command being asked for, and `run` is what prints the usage
    /// line and exits 1 — so `nil` from `parse` keeps its single meaning, "this is a normal app
    /// launch".
    struct Invocation: Equatable, Sendable {
        var target: String?
        var dryRun = false
        var json = false
        /// Why `target` is unusable, as a person reads it. `nil` when the invocation is fine.
        var problem: String?
    }

    /// Returns `nil` when `--run-job` is absent, which is every ordinary launch (see `main.swift`).
    static func parse(arguments: [String]) -> Invocation? {
        guard let flag = arguments.firstIndex(of: "--run-job") else { return nil }
        var invocation = Invocation()
        var targets: [String] = []
        for argument in arguments[(flag + 1)...] {
            switch argument {
            case "--dry-run": invocation.dryRun = true
            case "--json": invocation.json = true
            default:
                if argument.hasPrefix("--") {
                    // The first problem wins: reporting the last one would hide the typo that
                    // came before it.
                    invocation.problem = invocation.problem ?? "unknown option \(argument)"
                } else {
                    targets.append(argument)
                }
            }
        }
        if targets.count == 1 {
            invocation.target = targets[0]
        } else if targets.isEmpty {
            invocation.problem = invocation.problem ?? "--run-job needs a job id or name"
        } else {
            // A job name comes from `schedule_job` and may contain spaces, so it has to arrive as
            // one argument. Two bare words are a missing pair of quotes, and running the first
            // would run a job the caller did not name.
            invocation.problem = invocation.problem
                ?? "unexpected argument '\(targets[1])' — quote a job name that contains spaces"
        }
        return invocation
    }

    // MARK: Running

    /// The whole command. Everything it touches is injected so the tests can drive it against an
    /// in-memory store, a fake client and a lock path of their own (AGENTS invariant 7).
    ///
    /// `store` is an autoclosure because the order matters: usage and the lock are decided
    /// *before* anything opens a database file, so a run refused behind a live app never touches
    /// the store at all. `runner` is nil in production — the CLI builds the same `AppState`,
    /// engine and `JobRunner` the app fires through.
    @MainActor
    static func run(_ invocation: Invocation,
                    store openStore: @autoclosure () throws -> ConversationStore,
                    client: any LLMClientProtocol,
                    runner injectedRunner: JobRunner? = nil,
                    lockPath: URL = IrisPaths.default.guiLockFile,
                    protectionEnabled: Bool? = nil,
                    gate: (@Sendable (Gate, String?) async -> GateResult)? = nil,
                    out: (String) -> Void = { print($0) },
                    err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        async -> Int32 {
        guard let target = invocation.target, invocation.problem == nil else {
            err("iris --run-job: \(invocation.problem ?? "--run-job needs a job id or name")\n\(usage)")
            return Exit.usage
        }
        switch GUILock.state(at: lockPath) {
        case .free:
            break
        case .app(let pid):
            err("iris --run-job: the Iris app is running (pid \(pid)); quit it and try again — "
                + "the CLI will not write to the store behind a live app.")
            return Exit.usage
        case .unreadable(let path):
            err("iris --run-job: the Iris app is running, or left \(path) behind; the CLI will not "
                + "write to the store behind a live app. Delete that file if the app is not running.")
            return Exit.usage
        }

        let store: ConversationStore
        do {
            store = try openStore()
        } catch {
            err("iris --run-job: could not open the conversation store: \(error)")
            return Exit.usage
        }
        let ledger = store.ledger
        let job: Job?
        do {
            job = try lookUp(target, in: ledger)
        } catch {
            err("iris --run-job: could not read the jobs table: \(error)")
            return Exit.usage
        }
        guard let job else {
            err("iris --run-job: no job with the id or name '\(target)'.")
            return Exit.usage
        }

        if invocation.dryRun {
            return await dryRun(job: job, ledger: ledger, json: invocation.json, gate: gate,
                                out: out, err: err)
        }
        return await fire(job: job, store: store, client: client, runner: injectedRunner,
                          protectionEnabled: protectionEnabled, json: invocation.json,
                          out: out, err: err)
    }

    /// A full UUID names a job directly; anything else is a name. Both, because a card and `/jobs`
    /// show different things and either should be pasteable.
    static func lookUp(_ target: String, in ledger: JobLedger) throws -> Job? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: trimmed), let job = try ledger.job(id: id) { return job }
        return try ledger.job(named: trimmed)
    }

    /// The ordinary run: one fire, with origin `.manual`.
    ///
    /// `.manual` is what `/jobs run` uses, and it means the same thing here — a person asked for
    /// this fire now. It obeys admission (paused, overlap, breaker, budgets) and skips the gate,
    /// which a person asking for a run does not get outvoted by (R29); `--dry-run` is where the
    /// gate is the question.
    @MainActor
    private static func fire(job: Job, store: ConversationStore, client: any LLMClientProtocol,
                             runner injectedRunner: JobRunner?, protectionEnabled: Bool?,
                             json: Bool, out: (String) -> Void, err: (String) -> Void)
        async -> Int32 {
        let ledger = store.ledger
        let runner: JobRunner
        // Held for the length of the run: `JobRunner` keeps both weakly, and a run whose engine
        // was collected halfway through closes its row as `interrupted`.
        var state: AppState?
        var engine: IrisEngine?
        if let injectedRunner {
            runner = injectedRunner
        } else {
            let appState = AppState(store: store)
            // Spelled out rather than left to the default, because it is the whole of §8's
            // "approvals fail closed exactly as unattended": with this on, every tool call in a
            // CLI run would be auto-approved and the measurement would be of a different system.
            appState.autoApproveTools = false
            let irisEngine = IrisEngine(state: appState, client: client,
                                        protectionEnabled: protectionEnabled)
            guard let built = await irisEngine.jobRunner() else {
                err("iris --run-job: could not bring up the job runner.")
                return Exit.notCompleted
            }
            runner = built
            state = appState
            engine = irisEngine
        }

        // What the newest row was before the fire, so the row this run wrote can be told from the
        // one a previous run left — an admission refusal writes no row at all, and printing the
        // last run's would report a fire that never happened as if it had.
        let previousRunId = (try? ledger.runs(jobId: job.id, limit: 1))?.first?.id
        let admission = await runner.fire(job: job, origin: .manual)
        // The card, the transcript and the run's own conversation are in `AppState`'s debounced
        // save queue; the app flushes at terminate (`AppDelegate`) and so must this, or "the
        // Activity conversation shows it next time the app opens" (§8) is not true of a CLI run.
        state?.flushSave()
        // Explicit, not incidental: both were kept alive across the fire because `JobRunner` holds
        // them weakly, and an engine collected mid-turn closes the row as `interrupted`.
        withExtendedLifetime(engine) {}

        guard let admission else {
            err("iris --run-job: '\(job.name)' is no longer in the jobs table.")
            return Exit.usage
        }
        var row: JobRun?
        if let newest = (try? ledger.runs(jobId: job.id, limit: 1))?.first, newest.id != previousRunId {
            row = newest
        }
        if let row {
            out(json ? renderJSON(row: row) : render(row: row))
        } else {
            let refusal = JobRunner.refusalText(admission) ?? "admission refused the fire"
            out(json ? renderJSON(job: job, refusal: refusal)
                     : "\(job.name) was not started: \(refusal).")
        }
        if case .gateUnchanged = admission { return Exit.gateUnchanged }
        guard let row else { return Exit.notCompleted }
        return row.status == .completed ? Exit.completed : Exit.notCompleted
    }

    /// `--dry-run`: ask the gate, print what it said, write nothing.
    ///
    /// No row, deliberately. A dry run is a measurement of the gate — "would this job have work to
    /// do?" — and a row would be indistinguishable in `/jobs`, in the breaker count and in the
    /// retention sweep from a cadence tick that really happened. The signal it prints is also
    /// deliberately not stored: storing it would answer the *next* real tick's question with a
    /// look nobody scheduled.
    @MainActor
    private static func dryRun(job: Job, ledger: JobLedger, json: Bool,
                               gate: (@Sendable (Gate, String?) async -> GateResult)?,
                               out: (String) -> Void, err: (String) -> Void) async -> Int32 {
        guard let jobGate = job.trigger.gate else {
            err("iris --run-job: '\(job.name)' has no gate to evaluate; run it without --dry-run.")
            return Exit.usage
        }
        let previous = (try? ledger.lastGateSignal(jobId: job.id)) ?? nil
        let evaluate = gate ?? JobRunner.liveGateEvaluator(
            sandboxAvailable: { SandboxPolicy.mutatingJobCanRun(config: .shared) },
            image: { MainActor.assumeIsolated { ConfigManager.shared.sandboxImage } })
        let result = await evaluate(jobGate, previous)

        let verdict: String
        var signal: String?
        var detail: String?
        var code: Int32
        switch result {
        case .changed(let s, _): verdict = "changed"; signal = s; code = Exit.completed
        case .unchanged(let s): verdict = "unchanged"; signal = s; code = Exit.gateUnchanged
        case .error(let d): verdict = "error"; detail = d; code = Exit.notCompleted
        }
        if json {
            out(jsonLine([
                "job": job.name, "jobId": job.id.uuidString, "dryRun": true,
                "gate": jobGate.summary, "verdict": verdict,
                "signal": signal ?? NSNull(), "previousSignal": previous ?? NSNull(),
                "detail": detail ?? NSNull(), "wroteRunRow": false,
            ]))
        } else {
            var lines = ["job: \(job.name)", "gate: \(jobGate.summary)", "verdict: \(verdict)"]
            if let signal { lines.append("signal: \(signal)") }
            if let previous { lines.append("previous signal: \(previous)") }
            if let detail { lines.append("detail: \(detail)") }
            lines.append("(a dry run asks the gate only: no run, no row, no card)")
            out(lines.joined(separator: "\n"))
        }
        return code
    }

    // MARK: Rendering the row

    /// The ledger row as a person reads it: the fields §8 names — status, reason, tokens,
    /// duration, gate signal — one per line, so `grep` and a human get the same thing.
    static func render(row: JobRun) -> String {
        var lines = [
            "job: \(row.jobName)",
            "run: \(row.id.uuidString.lowercased())",
            "status: \(row.status.text)",
            "trigger: \(row.triggerKind)",
            "started: \(iso(row.startedAt))",
            "duration: \(durationText(row))",
            "tokens: \(row.totalTokens) total (prompt \(row.promptTokens), output \(row.candidateTokens))",
            "gate: \(row.gateSignal ?? "—")",
        ]
        if let outcome = row.outcome { lines.append("outcome: \(outcome)") }
        if let reason = row.failureReason { lines.append("reason: \(reason)") }
        if let tool = row.blockedTool { lines.append("blocked tool: \(tool)") }
        return lines.joined(separator: "\n")
    }

    static func renderJSON(row: JobRun) -> String {
        jsonLine([
            "job": row.jobName,
            "jobId": row.jobId.uuidString,
            "runId": row.id.uuidString,
            "status": row.status.rawValue,
            "triggerKind": row.triggerKind,
            "startedAt": iso(row.startedAt),
            "finishedAt": row.finishedAt.map { iso($0) } ?? NSNull(),
            "durationSeconds": row.finishedAt.map { $0.timeIntervalSince(row.startedAt) } ?? NSNull(),
            "promptTokens": row.promptTokens,
            "candidateTokens": row.candidateTokens,
            "totalTokens": row.totalTokens,
            "gateSignal": row.gateSignal ?? NSNull(),
            "outcome": row.outcome ?? NSNull(),
            "failureReason": row.failureReason ?? NSNull(),
            "blockedTool": row.blockedTool ?? NSNull(),
            "transcriptConversationId": row.transcriptConversationId?.uuidString ?? NSNull(),
            "dryRun": false,
        ])
    }

    /// A fire admission refused: there is no row to print, and saying nothing would read as a run
    /// that quietly worked.
    static func renderJSON(job: Job, refusal: String) -> String {
        jsonLine([
            "job": job.name, "jobId": job.id.uuidString, "refused": refusal, "dryRun": false,
        ])
    }

    private static func durationText(_ row: JobRun) -> String {
        guard let finished = row.finishedAt else { return "—" }
        return String(format: "%.1f s", finished.timeIntervalSince(row.startedAt))
    }

    /// One line, keys sorted: a `--json` run is something a script pipes into `jq`, and an
    /// unstable key order makes two runs of the same job diff against each other.
    private static func jsonLine(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is not `Sendable`, and a row is printed
    /// once per process, so a shared one would be a concurrency hazard bought for nothing.
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
