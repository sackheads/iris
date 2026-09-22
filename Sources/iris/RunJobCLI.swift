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
        /// A live Iris process holds it — the app, or another `--run-job`. The file carries a pid
        /// and nothing else, so which of the two it is cannot be known from here; the refusal
        /// says both rather than sending the user hunting for an app that is not running.
        case held(pid: Int32)
        /// A file that is there but says nothing a pid check can be made of. Held, not free:
        /// refusing is recoverable (delete it), and two writers at the store is not.
        case unreadable(path: String)
    }

    static func state(at url: URL) -> State {
        // Existence and readability are two questions, and `try?` answers both with the same nil:
        // no file, a file that is not valid UTF-8, and a file this user may not read all looked
        // alike, and only the first of them is free.
        guard FileManager.default.fileExists(atPath: url.path) else { return .free }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            return .unreadable(path: url.path)
        }
        // Signal 0 asks the kernel whether the process exists without sending anything. `EPERM`
        // means it exists and belongs to somebody else — still alive, still holding the store.
        if kill(pid, 0) == 0 { return .held(pid: pid) }
        return errno == ESRCH ? .free : .held(pid: pid)
    }

    /// What an exclusive claim came back with.
    enum Claim: Equatable, Sendable {
        /// The file is this process's: it was created by this call, and `release` will remove it.
        case acquired
        /// A live Iris process — the app, or another `--run-job` — already has it.
        case held(pid: Int32)
        /// The file is there and says nothing a pid check can be made of, or could not be created
        /// at all. `detail` is what the kernel said, when it said anything.
        case blocked(detail: String?)
    }

    /// Claims the lock for a process that must **refuse** rather than race: the CLI.
    ///
    /// Create-with-content, in one atomic step: the pid is written to a private file in the same
    /// directory and then `link(2)`ed to the lock path, which either succeeds — nothing was there
    /// and the file now exists *already holding the pid* — or fails `EEXIST`. Checking
    /// `state(at:)` and then writing cannot do that: two `--run-job` started at the same instant
    /// both read `.free`, both write, both open the store, and the documented eval-harness use
    /// (`xargs -P 4 iris --run-job …`) is precisely that shape. Nor can `O_CREAT | O_EXCL` on its
    /// own: between the create and the `write` the file exists and says nothing, so a loser
    /// reading it in that window sees a lock with no pid in it and tells the user to delete a file
    /// that is about to be perfectly valid.
    ///
    /// A leftover from a crash still has to be recoverable, so `EEXIST` is not the end of it: a
    /// file naming a pid the kernel no longer knows about is taken over and the link tried **once**
    /// more. Once, not in a loop — a second `EEXIST` means another process got the file in
    /// between, and that process is alive by construction, so this one is the loser.
    ///
    /// The takeover is a `rename(2)` of the stale file to a private aside name, never an `unlink`
    /// of the lock path. Of two processes taking over the same stale file exactly one rename
    /// succeeds; the other gets `ENOENT` and goes straight to its own link attempt. An `unlink`
    /// gives them both a success and lets the second one delete the *live* lock the first has just
    /// created in the gap — the crash-recovery path handing out the double claim it exists to
    /// prevent.
    static func acquireExclusively(at url: URL) -> Claim {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for attempt in 0...1 {
            // Same directory, so the link cannot cross a filesystem, and a name no other process
            // will pick, so two claims in flight cannot share a staging file.
            let staged = directory.appendingPathComponent(Self.privateName(beside: url, "pid"))
            let pid = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            guard (try? pid.write(to: staged)) != nil else {
                return .blocked(detail: "could not write \(staged.path)")
            }
            defer { try? FileManager.default.removeItem(at: staged) }

            if link(staged.path, url.path) == 0 { return .acquired }
            // Anything other than "it is already there" is this process's own problem — a
            // directory it may not write, a full disk — and it is still a refusal: a CLI that
            // cannot take the lock cannot know whether the app has it, and two writers at one
            // store is the thing this exists to prevent.
            guard errno == EEXIST else { return .blocked(detail: String(cString: strerror(errno))) }
            switch state(at: url) {
            case .held(let pid): return .held(pid: pid)
            case .unreadable: return .blocked(detail: nil)
            case .free:
                guard attempt == 0 else { return .blocked(detail: nil) }
                let aside = directory.appendingPathComponent(Self.privateName(beside: url, "stale"))
                // `ENOENT` is somebody else having got there first, and is not a failure: this
                // process simply tries the link like any other claimant on the next pass.
                if rename(url.path, aside.path) == 0 {
                    try? FileManager.default.removeItem(at: aside)
                }
            }
        }
        return .blocked(detail: nil)
    }

    /// A name beside the lock file that belongs to this claim and no other: hidden, so a user
    /// listing `~/.iris` never sees it, and carrying the pid and a UUID, so two claims racing in
    /// one process (the tests do exactly that) cannot stage over each other.
    private static func privateName(beside url: URL, _ purpose: String) -> String {
        ".\(url.lastPathComponent).\(purpose).\(ProcessInfo.processInfo.processIdentifier)."
            + UUID().uuidString
    }

    /// Claims the lock for this process, whatever was there before. Called once, at app launch.
    ///
    /// The app overwrites rather than claiming exclusively, and deliberately: it is the owner of
    /// the store, and a lock file left behind by a killed build must never stop it launching.
    /// `--run-job` is the side that has to yield, and it does — see `acquireExclusively`.
    static func acquire(at url: URL = IrisPaths.default.guiLockFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: url, options: .atomic)
    }

    /// Gives it back, if it is ours to give: a lock file naming another live process belongs to
    /// another app instance, and this one must not delete it on its way out.
    static func release(at url: URL = IrisPaths.default.guiLockFile) {
        guard case .held(let pid) = state(at: url),
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
    /// the store at all. The lock is then *taken* for the length of the run, which is what keeps
    /// two CLI runs off one store. `runner` is nil in production — the CLI builds the same
    /// `AppState`, engine and `JobRunner` the app fires through.
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
        func refuse(_ message: String, appendingUsage: Bool = false) -> Int32 {
            fail(message, code: Exit.usage, json: invocation.json, dryRun: invocation.dryRun,
                 usage: appendingUsage, out: out, err: err)
        }
        guard let target = invocation.target, invocation.problem == nil else {
            return refuse(invocation.problem ?? "--run-job needs a job id or name",
                          appendingUsage: true)
        }
        // Claim the lock, rather than check it and then take it: the two have to be one syscall or
        // two `--run-job` invocations started together both read "free" and both build an
        // `AppState` over the same file — the two in-memory copies of one store that this exists
        // to prevent, for as long as a model turn. It does not close the other direction: the GUI
        // never checks, it overwrites, so an app launched *during* a run still races (and,
        // acquiring second, keeps the lock — `release` below is pid-guarded and will not take the
        // app's).
        switch GUILock.acquireExclusively(at: lockPath) {
        case .acquired:
            break
        case .held(let pid):
            // Named as what the lock file can actually prove: a live Iris process. It is the app
            // most of the time, but a second `--run-job` takes the same lock and writes the same
            // bare pid, and telling that user to quit an app that is not running is worse than
            // telling them the truth. The file is named too, because a pid the kernel has since
            // handed to something else entirely leaves nothing to wait for and no app to quit.
            return refuse("another Iris process holds the store (pid \(pid)) — the app, or another "
                          + "--run-job. Wait for it to finish, or quit the app, and try again; the "
                          + "CLI will not write to the store behind a live one. If nothing "
                          + "Iris-shaped is running, that pid belongs to something else now: "
                          + "delete \(lockPath.path).")
        case .blocked(let detail):
            return refuse("another Iris process holds the store, or left \(lockPath.path) behind"
                          + (detail.map { " (\($0))" } ?? "") + "; the CLI will not write to the "
                          + "store behind a live one. Delete that file if nothing is running.")
        }
        defer { GUILock.release(at: lockPath) }

        let store: ConversationStore
        do {
            store = try openStore()
        } catch {
            return refuse("could not open the conversation store: \(error)")
        }
        let ledger = store.ledger
        let job: Job?
        do {
            job = try lookUp(target, in: ledger)
        } catch {
            return refuse("could not read the jobs table: \(error)")
        }
        guard let job else {
            return refuse("no job with the id or name '\(target)'.")
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

    /// The `AppState` a CLI run fires through: the real one, over the store the caller opened,
    /// minus the two things about a launch that are the *window's* and not the run's.
    ///
    /// `autoApproveTools` is spelled out rather than left to the default, because it is the whole
    /// of §8's "approvals fail closed exactly as unattended": with it on, every tool call in a CLI
    /// run would be auto-approved and the measurement would be of a different system. A separate
    /// function so a test can read the flag back off it — set-and-never-verified is how a default
    /// that changes underneath you goes unnoticed.
    ///
    /// The launch notices and the empty-store conversation are suppressed: they are UI
    /// affordances, and `flushSave()` at the end of a run would commit them to the user's real
    /// store. A command whose whole purpose is measuring must not leave a "New Conversation" and a
    /// guard-provisioning notice behind. Nothing about the fire, the row, the card or the approval
    /// path depends on either.
    @MainActor
    static func makeState(store: ConversationStore) -> AppState {
        let state = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        state.autoApproveTools = false
        return state
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
            let appState = makeState(store: store)
            let irisEngine = IrisEngine(state: appState, client: client,
                                        protectionEnabled: protectionEnabled)
            guard let built = await irisEngine.jobRunner() else {
                return fail("could not bring up the job runner.", code: Exit.notCompleted,
                            json: json, dryRun: false, out: out, err: err)
            }
            runner = built
            state = appState
            engine = irisEngine
        }

        // What the newest row was before the fire, so the row this run wrote can be told from the
        // one a previous run left — an admission refusal writes no row at all, and printing the
        // last run's would report a fire that never happened as if it had. A read that *failed*
        // is not "there was none": swallowing it to nil would make an earlier row satisfy the
        // `!=` below and print exactly the fiction this exists to prevent, so it is remembered
        // and suppresses the attribution entirely.
        var previousRunId: UUID?
        var previousKnown = true
        do {
            previousRunId = try ledger.runs(jobId: job.id, limit: 1).first?.id
        } catch {
            previousKnown = false
        }
        let admission = await runner.fire(job: job, origin: .manual)
        // The card, the transcript and the run's own conversation are in `AppState`'s debounced
        // save queue; the app flushes at terminate (`AppDelegate`) and so must this, or "the
        // Activity conversation shows it next time the app opens" (§8) is not true of a CLI run.
        state?.flushSave()
        // Explicit, not incidental: both were kept alive across the fire because `JobRunner` holds
        // them weakly, and an engine collected mid-turn closes the row as `interrupted`.
        withExtendedLifetime(engine) {}

        guard let admission else {
            return fail("'\(job.name)' is no longer in the jobs table.", code: Exit.usage,
                        json: json, dryRun: false, out: out, err: err)
        }
        var row: JobRun?
        if previousKnown, let newest = (try? ledger.runs(jobId: job.id, limit: 1))?.first,
           newest.id != previousRunId {
            row = newest
        }
        if let row {
            out(json ? renderJSON(row: row) : render(row: row))
        } else if !previousKnown {
            let detail = "the ledger could not be read before the fire, so this run's row cannot "
                + "be told apart from an earlier one; read it with /jobs in the app"
            out(json ? renderJSON(job: job, refusal: detail) : "\(job.name): \(detail).")
        } else {
            let refusal = JobRunner.refusalText(admission) ?? "admission refused the fire"
            out(json ? renderJSON(job: job, refusal: refusal)
                     : "\(job.name) was not started: \(refusal).")
        }
        // Unreachable by construction, and kept as a belt: this fire is `.manual`, and
        // `JobRunner.gateApplies` gives a gate a say only over a fresh cadence fire (R29). If that
        // rule ever widens to a hand-started run, the exit code is already right.
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
            return fail("'\(job.name)' has no gate to evaluate; run it without --dry-run.",
                        code: Exit.usage, json: json, dryRun: true, out: out, err: err)
        }
        let previous = (try? ledger.lastGateSignal(jobId: job.id)) ?? nil
        // Exactly as `JobRunner` builds it (`liveGateEvaluator`'s own default): the closure it
        // hands back is nonisolated `@Sendable`, so awaiting it from here hops off the main actor
        // and anything inside it that asserted main-actor isolation would trap. `ConfigManager` is
        // `@unchecked Sendable`, so it is read bare, from wherever the evaluation runs.
        let evaluate = gate ?? JobRunner.liveGateEvaluator(
            sandboxAvailable: { SandboxPolicy.mutatingJobCanRun(config: .shared) },
            image: { ConfigManager.shared.sandboxImage })
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

    /// Every way this command can refuse, said once. The prose goes to stderr, where an error
    /// belongs; under `--json` the same sentence also goes to stdout as one object, because the
    /// docs tell a script to read stdout and handing it nothing but an exit code on the failure
    /// paths would make that a half-truth.
    @discardableResult
    private static func fail(_ message: String, code: Int32, json: Bool, dryRun: Bool,
                             usage appendUsage: Bool = false,
                             out: (String) -> Void, err: (String) -> Void) -> Int32 {
        err("iris --run-job: \(message)" + (appendUsage ? "\n\(usage)" : ""))
        if json {
            out(jsonLine(["error": message, "exitCode": Int(code), "dryRun": dryRun]))
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
