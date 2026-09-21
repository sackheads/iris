# Agency Deliverable 3: Runtime — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** READY — spec §0 decided 2026-09-21 morning (all recommendations accepted, plus an observability requirement: budget/breaker/retry figures in `/jobs`, `list_jobs`, and pause cards — folded into Task 2 (queries), Task 3 (cards) and Task 10 (rendering)). Written 2026-09-21 overnight.

**Goal:** Make unattended jobs safe over time: policies on the job (overlap, catch-up, retry, budgets, timeout) enforced by the runner; a persisted blocked call that a card can approve and run; gates that decide whether a run is needed; `iris --run-job` to measure a job before trusting it.

**Architecture:** One additive migration (`v10_job_policy`); `JobPolicy` on `Job`; admission logic in `JobRunner` (pure `admit` decision + ledger queries), covering scheduled and watcher fires; a `TurnBudget` the engine honours through its existing soft-stop path; `BlockedCall` persisted on the run and re-dispatched by `runApproved`; `Gate` evaluated before the run (built-ins on the host, scripts in the container through an extended runtime API); a `--run-job` CLI branch that opens the real store.

**Tech Stack:** Swift 6 strict concurrency, GRDB, `ProcessInfo.beginActivity`, `apple/container` CLI runtime, Swift Testing.

**Spec:** `docs/specs/2026-09-21-agency-runtime.md`. Facts: `.superpowers/briefs/agency-d3-facts.md` (main checkout). Prior slices: #252 (D1), #253 (D2).

## Global Constraints

- Every new persisted field decodes leniently with a default (invariant 1); `policy` NULL → `JobPolicy()`; an old `PollSpec.gate` string decodes as `.script(command:, mounts: [], timeoutSeconds: 60)`.
- Admission order is fixed: paused → in flight → breaker → daily budgets → gate. Each refusal that the spec says writes a row writes exactly one row.
- Budgets are computed from `job_runs` sums for the local calendar day, never from in-memory counters.
- "Approve and run" executes exactly the persisted call, once (`approvedAt` set atomically, and that is the whole one-shot — ruling R21 removed the in-memory `approvedCalls` grant as dead code), never resumes a model turn. The card renders the full call, and Vibecop's verdict on it is shown beside the button; a click overrides a DENY rather than skipping the evaluation.
- A script gate signals by a `CHANGED`/`UNCHANGED` token on stdout's last line, never by exit code; a gate "unchanged" writes a `completed` row with outcome "gate: no change" and no card.
- Script gates and `mutating` jobs run only in the container; creation is refused when the runtime is not installed.
- `--run-job` never sets `HeadlessMode` or volatile defaults; it opens the real store and refuses when the GUI's lock file exists.
- Tests: Swift Testing; in-memory store; injected clock; fake `ContainerRuntime` and a protocol-wrapped activity API; no `~/.iris`, network, or `ConfigManager.shared` mutation (new keys are read through the injected `ConfigManager(store:)` pattern where a test needs a non-default).
- `swift test; echo exit=$?` = 0 and zero `with [1-9][0-9]* failures` before each commit; conventional commits with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer; never `git add` `.superpowers/` or `.claude/`.

---

### Task 1: `JobPolicy`, migration `v10_job_policy`, ledger queries

**Files:** Create `Sources/iris/JobPolicy.swift`; Modify `Sources/iris/Job.swift` (`policy`, `retryAttempt`, `queuedFire`, `PollSpec.gate: Gate` with lenient string decode), `Sources/iris/ConversationStore.swift` (migration), `Sources/iris/JobLedger.swift` (columns + queries), `Sources/iris/AppState.swift` (`Conversation.jobProfile: JobProfile?`); Tests `Tests/irisTests/JobPolicyTests.swift`, `Tests/irisTests/JobLedgerPolicyTests.swift`.

**Interfaces (produces):**
```swift
struct JobPolicy: Codable, Equatable, Sendable { /* spec §3 */ }
enum Gate: Codable, Equatable, Sendable { case urlChanged(url: String), pathChanged(path: String), script(command: String, mounts: [String], timeoutSeconds: Int) }
// Job: var policy: JobPolicy; var retryAttempt: Int; var queuedFire: Date?
// Conversation: var jobProfile: JobProfile?   (nullable column; decodeIfPresent)
// JobLedger additions
func runsStarted(jobId: UUID, since: Date) throws -> Int
func tokensToday(jobId: UUID?, calendar: Calendar, now: Date) throws -> Int      // nil jobId = all jobs
func setRetry(jobId: UUID, attempt: Int, nextFireAt: Date?) throws
func setQueuedFire(jobId: UUID, at: Date?) throws
func setBlockedCall(runId: UUID, _ call: BlockedCall?) throws
func markApproved(runId: UUID, at: Date) throws -> Bool                            // false if already approved (atomic UPDATE … WHERE approvedAt IS NULL)
func setGateSignal(runId: UUID, _ signal: String?) throws
func lastGateSignal(jobId: UUID) throws -> String?
```
Migration `v10_job_policy`: `jobs` + `policy TEXT`, `retryAttempt INTEGER NOT NULL DEFAULT 0`, `queuedFire DATETIME`; `job_runs` + `blockedCall TEXT`, `approvedAt DATETIME`, `parentRunId TEXT`; `conversations` + `jobProfile TEXT`.

- [ ] Tests first: `JobPolicy` decode of `{}` → defaults; `replay(cap:)` encode/decode; `Job` with NULL policy → default; old `PollSpec` string → `.script`; v9 fixture → v10 with rows intact; `runsStarted` boundary; `tokensToday` across a local-midnight boundary with a fixed calendar and time zone; `markApproved` returns true once then false; `lastGateSignal` returns the newest row's signal.
- [ ] Implement; run `swift test --filter "JobPolicyTests|JobLedgerPolicyTests|JobLedgerTests|JobRunLedgerTests|ConversationStore"`; full suite; commit `feat(jobs): JobPolicy, Gate, migration v10_job_policy, and the ledger's budget/breaker/approval queries (#187)`.

### Task 2: Admission in the runner (overlap incl. watchers, queue, breaker, daily budgets) **[§0.1]**

**Files:** Modify `Sources/iris/JobRunner.swift`, `Sources/iris/JobScheduler.swift` (remove `firing`; call `runner.fire(job:reason:changedPaths:)`), `Sources/iris/iris.swift` (watcher callback → the same entry), `Sources/iris/ConfigManager.swift` (`jobMaxRunsPerHour`, `jobDailyTokenBudget`, `jobGlobalDailyTokenBudget`, `jobPerRunTokenBudget`, `jobRunTimeoutSeconds` with the #208 `0 = default` pattern); Tests `Tests/irisTests/JobAdmissionTests.swift`.

**Interfaces:**
```swift
extension JobRunner {
    enum Admission: Equatable, Sendable { case run, dropPaused, skipInFlight, queued, pauseBreaker(count: Int), pauseBudget(scope: String, used: Int, limit: Int) }
    static func admit(job: Job, inFlight: Bool, runsLastHour: Int, tokensTodayJob: Int, tokensTodayAll: Int, limits: JobLimits) -> Admission   // pure
    func fire(job: Job, reason: String, changedPaths: [String] = []) async         // admit → act (rows, pauses, cards) → run → post-run (queue, retry)
}
struct JobLimits: Equatable, Sendable { let maxRunsPerHour: Int; let dailyTokens: Int; let globalDailyTokens: Int; let perRunTokens: Int; let runTimeoutSeconds: Int; static func resolve(job: Job, config: ConfigManager) -> JobLimits }
```
- [ ] Tests first: table-driven `admit` for every branch and the order; `fire` with a fake ledger/clock: skip writes one `interrupted` row; `queue` sets `queuedFire` and fires exactly once after the run; breaker on the (N+1)th run within the hour pauses with the reason and a card; job and global daily budgets pause with distinct reasons; a watcher-driven `fire` while in flight is skipped (D2-R9 regression); `JobSchedulerTests` still green with `firing` removed.
- [ ] Implement; commit `feat(jobs): admission in the runner — overlap for every fire, queue, breaker, daily budgets (#187)`.

### Task 3: Turn budget, run timeout, sleep assertion, retry and pause **[§0.1]**

**Files:** Modify `Sources/iris/iris.swift` (`processInput(..., turnBudget:)`, check before each model round → soft stop with `"budget: tokens exceeded"` / `"budget: time exceeded"`), `Sources/iris/JobRunner.swift` (pass the budget; `ActivityHolder` around the run; post-run retry/pause; `/jobs pause|resume` support), `Sources/iris/JobsCommand.swift` (`pause`, `resume`, `run` forms); Create `Sources/iris/SleepAssertion.swift` (`protocol ActivityAPI { func begin(reason:) -> Token; func end(_:) }`, `ProcessInfoActivity`, `NoopActivity` for tests); Tests `Tests/irisTests/TurnBudgetTests.swift`, `Tests/irisTests/JobRetryTests.swift`, `Tests/irisTests/JobsCommandTests.swift` additions.

**Interfaces:**
```swift
struct TurnBudget: Sendable, Equatable { let maxTokens: Int; let deadline: Date }
// JobRunner
static let backoff: [TimeInterval] = [60, 300, 1500]
static func retryDecision(status: JobRun.Status, attempt: Int, retryEnabled: Bool, now: Date) -> RetryDecision   // .none | .retry(at:) | .pause(reason:)
```
- [ ] Tests first: a scripted three-round turn with `maxTokens` below the second round's cumulative usage ends after round one via the soft-stop path with the budget reason, and the row is `failed`; a deadline in the past ends before the first model call; `retryDecision` table (failed×attempt 0..3, blocked → none, completed → reset); a failed run's card says "retrying in 1 m" and `nextFireAt == now + 60`; the fourth failure pauses; `resume` clears both fields and recomputes the next fire; the activity token is begun before `processInput` and ended after (fake API records the order) and ended by the deadline when the turn overruns.
- [ ] Implement; commit `feat(jobs): per-run token and time budget through the soft-stop path, sleep assertion, retry with backoff, /jobs pause|resume|run (#187)`.

### Task 4: Read-only tool-surface narrowing and profile denials **[§0.2]**

**Files:** Modify `Sources/iris/iris.swift` (tool-list builder omits the denylist when `conversation.jobProfile == .readOnly`; the dispatch path fails closed with `BlockedCall.Reason.profile` for a denied name), `Sources/iris/AppState.swift` (`recordBackgroundDenial(call:)` replaces the name-only record; `BlockedCall` type from spec §6), `Sources/iris/ScheduleJobArguments.swift` (`profile: mutating` now accepted; refused only when the container runtime is missing); Tests `Tests/irisTests/JobProfileTests.swift`.

- [ ] Tests first: `JobProfile.readOnly.deniedTools` membership per §0.2; a capturing client shows a read-only run's request lacks `write_file` and has `read_file`; a scripted `write_file` call in a read-only run is blocked with `reason: .profile`, the row is `blockedOnApproval`, and the card names the call; a `mutating` job's conversation is sandboxed and its request includes `write_file`; creation of `mutating` refused when the runtime is absent (inject the availability).
- [ ] Implement; commit `feat(jobs): read-only runs lose the mutating tool surface; mutating jobs are creatable and sandboxed (#187)`.

### Task 5: Persisted blocked call and "Approve and run" **[§0.3]**

**Files:** Modify `Sources/iris/EventCard.swift` (+`blockedCall`), `Sources/iris/EventCardView.swift` (renders the full blocked call — tool, arguments, 500-char body preview — the Vibecop verdict and reason, Approve and run / Dismiss), `Sources/iris/AppState.swift` (`recordBackgroundDenial` takes the whole call; no approval grant — R21), `Sources/iris/iris.swift` (`executeApprovedCall(_ call: BlockedCall, conversationId:) async -> String` — internal wrapper over `executeToolWithHooks`), `Sources/iris/JobRunner.swift` (`runApproved(runId:) async`); Tests `Tests/irisTests/ApproveAndRunTests.swift`.

- [ ] Tests first: a blocked run persists the full call (name, args, cwd, reason); `runApproved` creates a row with `triggerKind == "approval"` and `parentRunId`, a fresh hidden conversation, executes exactly that call once through the tool executor (fake executor records it), finishes `completed` with the result's first line, delivers a follow-up card; a second `runApproved` for the same run is refused (`markApproved` false) with no new row; a deleted job is refused; Vibecop IS consulted when the card is built and its verdict is on the card (spy), and a human approval proceeds even on DENY; the approved call's own conversation is not left pre-authorised (R21); the approved call in a `mutating` job runs sandboxed.
- [ ] Implement; commit `feat(jobs): the blocked call is persisted; Approve and run dispatches it once as its own tracked run (#187)`.

### Task 6: Container runtime timeout and mounts (prerequisite for gates) **[§0.4]**

**Files:** Modify `Sources/iris/ContainerRuntime.swift` (`createDetached(name:image:mounts: [String], workdir:)`, `exec(..., timeoutSeconds: Int?)` with process termination on deadline), `Sources/iris/SandboxSessionManager.swift` (`run(command:conversationId:workspace:extraMounts:timeoutSeconds:)`), `Sources/iris/ToolExecutor.swift` (pass the already-clamped `run_command` timeout on the sandboxed branch — a bug fix); Tests `Tests/irisTests/ContainerRuntimeTests.swift` (fake CLI runner), `Tests/irisTests/SandboxTimeoutTests.swift`.

- [ ] Tests first: mounts are rendered as one `--mount` per entry; a command exceeding the timeout is terminated and reported as a timeout error; the sandboxed `run_command` branch forwards `timeout_seconds`; existing sandbox tests unchanged.
- [ ] Implement; commit `fix(sandbox): the container runtime takes a mount list and a timeout; run_command's timeout is honoured when sandboxed (#187)`.

### Task 7: Gates and the `.poll` trigger **[§0.4]**

**Files:** Create `Sources/iris/GateEvaluator.swift` (`evaluate(_ gate: Gate, previous: String?, runtime: ContainerRuntime?, http: URLSession, fileManager:) async -> GateResult` with `.changed(signal:)`, `.unchanged(signal:)`, `.error(String)`); Modify `Sources/iris/JobRunner.swift` (admission step 5; signal recorded; "unchanged" → row, no card; three consecutive errors → pause `"gate failing"`), `Sources/iris/ScheduleJobArguments.swift` (`gate_url`, `gate_path`, `gate_script`, `gate_mounts`, `gate_timeout_seconds`; Vibecop review of a script at creation via the existing `consultVibecop` shape; runtime-missing refusal), `Sources/iris/iris.swift` (tool declaration parameters and description); Tests `Tests/irisTests/GateEvaluatorTests.swift`, `Tests/irisTests/GateCreationTests.swift`.

- [ ] Tests first: `urlChanged` against a `URLProtocol` stub (ETag change, Last-Modified change, no change, 404 → error); `pathChanged` on temp files (mtime, size+hash, directory newest-mtime); `script` through a fake runtime (last stdout line `CHANGED` / `UNCHANGED` / anything else → changed / unchanged / error; non-zero exit or timeout → error; mounts and timeout forwarded; payload truncated to 4,000 and passed through the guard under `gate_output`); the runner writes `gateSignal`, skips the card on unchanged, pauses after three errors; creation refuses a script gate without the runtime and on Vibecop `DENY`, asks on `ESCALATE` (inject the decision).
- [ ] Implement; commit `feat(jobs): gates — url, path and sandboxed script — decide whether a run is needed; poll jobs are creatable (#187)`.

### Task 8: Catch-up policy **[§0.1 cap]**

**Files:** Modify `Sources/iris/JobScheduler.swift` (apply `catchUp` when `nextFireAt` is more than one cadence in the past; `replay(cap)` iterates occurrences through the runner's admission); Tests `Tests/irisTests/CatchUpTests.swift`.

- [ ] Tests first (fixed clock, an 8-hour sleep over a 15-minute cron): `coalesce` → one fire, reschedule from now; `skip` → no fire, next future occurrence; `replay(cap: 5)` → five fires in order, one card note "27 earlier occurrences skipped", reschedule from the last replayed slot; `replay` respects `maxFiresPerTick` across ticks.
- [ ] Implement; commit `feat(jobs): catch-up policy after sleep — coalesce, skip, or replay up to a cap (#187)`.

### Task 9: `iris --run-job` **[§0.5]**

**Files:** Create `Sources/iris/RunJobCLI.swift` (`parse(arguments:) -> Invocation?`, `run(_:store:client:runner:) async -> Int32`), Modify `Sources/iris/main.swift` (third branch), `Sources/iris/AppState.swift` or `IrisPaths` (GUI lock file beside the store, created at launch, removed at exit); Tests `Tests/irisTests/RunJobCLITests.swift`.

- [ ] Tests first: argument parsing (id, name, `--dry-run`, `--json`, bad input → usage exit 1); with an injected in-memory store and fake client: a completed run exits 0 and prints the row; a blocked run exits 2; `--dry-run` evaluates only the gate and exits 3 on unchanged; the lock file present → exit 1 with the message; no `HeadlessMode`/volatile defaults are touched (assert the flags).
- [ ] Implement; commit `feat(cli): iris --run-job runs one job headlessly against the real store and prints its ledger row (#187)`.

### Task 10: Settings, `/jobs` forms, docs

**Files:** Modify `Sources/iris/SettingsView.swift` (five steppers in Advanced, #208 pattern), `Sources/iris/JobsCommand.swift` (policy column; `pause`/`resume`/`run` usage text; per-job `tokens today used / budget (pct%)`, `runs last hour n / max`, `retry k/3`, and a global daily footer — spec §9; tested in `JobsCommandTests` with fixed figures), `Sources/iris/iris.swift` (`list_jobs` carries the same numbers), `README.md`, `docs/jobs.md` (policies, budgets, breaker, retry, gates, Approve and run, `--run-job`, the read-only denylist), `docs/agency/agency.md` (deliverable 3 landed), the spec status line.

- [ ] Falsify the docs first (grep for "not built yet", "deliverable 3", "read-only" claims); rewrite; `swift build`; full suite; commit `docs(jobs): policies, budgets, gates, Approve and run, and --run-job; deliverable 3 landed (#187)`.

---

## Self-review

- **Spec coverage:** §3 → T1; §4 before-run → T2, during → T3, narrowing → T4, after-run → T3; §5 → T8; §6 → T5; §7 → T6 (prerequisite) + T7; §8 → T9; §9 → T10; §10 tests distributed; §11 rulings honoured (overlap in the runner T2; ledger-sum budgets T2; re-dispatch not resume T5; no card on unchanged T7; lock file T9; one migration T1).
- **Placeholders:** none; every task names files, signatures, and its test list. Code blocks are lighter than D1/D2's plans on purpose: §0 may move numbers and the denylist, and the affected tasks are tagged.
- **Type consistency:** `BlockedCall` (spec §6) is used by T1 (column), T4 (record), T5 (dispatch); `Gate` (T1) by T7; `JobLimits` (T2) by T3 (`runTimeoutSeconds`, `perRunTokens`); `Admission` (T2) by T7 (gate step) and T8 (replay through admission).
- **Slicing note:** T1–T3 are one PR-sized unit (policy + enforcement), T4–T5 a second (profile + approval), T6–T7 a third (gates), T8–T10 a fourth. Recommend four PRs, not one.
