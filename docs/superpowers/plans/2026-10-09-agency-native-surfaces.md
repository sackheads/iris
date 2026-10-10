# Agency Deliverable 6, Native Surfaces: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Iris four native surfaces over state the harness already owns: a menu bar status item that tells idle, running and action required apart, notifications for blocked or paused jobs and for live asks (none of which can approve), an owner-only `iris://run-job/<token>` link, and a Run Log window.

**Architecture:**
- One derived value, `SurfaceAttention`, is computed from four inputs: `pendingApprovals`, the session statuses, a new observed `AppState.runningJobs` (keyed by job id, fed by `JobRunner` through one actor hop), and a cached `AppState.ledgerAttention` snapshot. The snapshot is refreshed after each write that can change it and is never polled. The status item draws `SurfaceAttention`, and the Run Log refreshes when the snapshot changes.
- Notifications run in a pure `NotificationPolicy` that builds every string from fixed words plus a quoted, flattened job or tool name. A `NotificationSink` protocol sits on `AppState` and is nil by default. `UserNotificationSink`, the only file that imports `UserNotifications`, is installed by `IrisApp.init`, and only inside a real `.app` bundle. The policy is asked in two places: after `deliverEvent`'s append, and in a `didSet` on `pendingApprovals`.
- The URL trigger is an owner-only opt-in. `/jobs url <job> on` mints a 128-bit token, prints it once, and stores only its SHA-256 digest through a dedicated `setURLTrigger` write. `upsert` never writes either column, and it clears both when a job's prompt, profile or policy changes.
- A link is parsed by a pure `RunJobURL`, looked up by digest, rate-limited (3 per job per rolling hour, refusal-only, no ledger row), deferred while a foreign `--run-job` holds the store, and fired through `runJobByHand`, the body that `/jobs run` used to own, with a new `FireOrigin.url`.

**Tech Stack:** Swift 6, SwiftUI (`MenuBarExtra`, `Window`, `Table`), AppKit (`NSApplicationDelegate`, `NSWindow`), UserNotifications, CryptoKit and Security (`SHA256`, `SecRandomCopyBytes`), GRDB (`ConversationStore`, `JobLedger`), Swift Testing. No new dependencies.

**Spec:** `docs/specs/2026-10-09-agency-native-surfaces.md` (merged in #462, binding). Read it in full before any task. "Decision N" below means spec §0.N. The review on #462 (iris-86, two rounds) is folded into the spec. Its second-round notes (policy in the compared set, and the three reasons the `on` reply's token stays out of model reach) are tests in Tasks 17 and 18. The design brief is `.superpowers/sdd/agency-6-design-brief.md`. Where this plan departs from the spec, see **Plan notes**. Each departure is a proposed ruling for the owner.

**Scope:** spec §4, all five PRs: A (Tasks 1-6), B (Tasks 7-11), C (Tasks 12-16), D1 (Tasks 17-23) and D2 (Tasks 24-28). Every line number below was read on `main` at `8268d37`. Re-read the cited lines before editing, because an earlier PR in this plan moves them.

## Global Constraints

- **Code lives in `Sources/IrisKit/`**, not `Sources/iris/` (that holds only `main.swift`). Tests live in `Tests/irisTests/` and import `@testable import IrisKit`.
- **Notification text, verbatim from decision 6:**
  - The title is a fixed constant per kind: `Iris: a job needs you` for a blocked or paused job, and `Iris: approval waiting` for a live ask.
  - The body may carry only the quoted job name (flattened and capped with `IrisEngine.flattenCardField` and `IrisEngine.cardNameCap`), the quoted tool name (flattened the same way), and fixed words, e.g. `Job “pr-sweep” is blocked on “run_command”.`
  - Neither the title nor the body may use a run's `outcome`, an ask's `details`, a conversation title or a Vibecop reason.
- **Decision 1: a notification never approves.** The only actions are Open, Deny (live asks) and Dismiss (blocked cards). No category is registered with an approve action, and `handleNotificationResponse` ignores any action id it does not know.
- **Interruption level `.active`.** Never `.timeSensitive`, which needs an entitlement. `App/Iris.entitlements` stays an empty dict.
- **Permission** is requested the first time a notification would be posted, never at launch. "Denied", including denied by MDM, is a normal state: no re-prompt and no retry.
- **Only a real `.app` bundle gets notifications or the URL scheme** (decision 8): the check is `Bundle.main.bundleURL.pathExtension == "app"`, and it runs before any `UNUserNotificationCenter` call. `IrisApp.init` is the only installer. `--run-job` never installs a sink, and neither does `AppState()` in a test.
- **The URL, verbatim from decisions 10, 12 and 13:**
  - The form is `iris://run-job/<token>` for release and `iris-dev://run-job/<token>` for dev.
  - It accepts no query, no fragment, no other host or path, and no job id or slug.
  - The token is 128 bits from `SecRandomCopyBytes`, base64url-encoded (22 characters, no padding).
  - Only its SHA-256 digest is stored, in `jobs.urlTokenHash`. Each `on` rotates the token, and `off` deletes the digest.
  - The limit is 3 URL fires per job per rolling hour, counted from that job's `triggerKind = 'url'` rows. An over-limit fire is refused before admission, writes no ledger row, never counts toward the breaker and never pauses the job.
- **Decision 14's deferral:** re-check a live foreign lock holder every 5 s, and give up after 10 minutes with "try again after the other Iris process finishes". The timers run on dispatch queues, never `Task.sleep` (the invariant 4 rule).
- **Migration** `v19_job_url_trigger`: a nullable `urlTrigger` boolean (NULL means false) and a nullable `urlTokenHash TEXT` with a unique index. `main` has no `v19_*`, and no open PR claims one (checked with `gh pr list --state open` on 2026-10-09). Check again before Task 17.
- **The status item** is the existing `MenuBarExtra`. The base symbol is `sparkles` for release and `hammer` for dev. Idle shows the base symbol alone, running adds the count, and action required adds `!` and the count. Scenes: `WindowGroup("Iris", id: "main")`, `Window("Diagnostics", id: "diagnostics")` and `Window("Run Log", id: "run-log")`.
- **Settings:** "Notifications: Off / Needs attention" defaults to Needs attention and is stored through `ConfigManager` (`NOTIFICATION_MODE`).
- **`JobLedger.onJobsChanged` is installed exactly once**, by the watch layer (`iris.swift:3326`). The status item's refresh is one added call inside that closure, never a second hook. A second hook silently replaces the watch resync.
- **Invariants:**
  - 1: `Job.urlTrigger` decodes with `decodeIfPresent ?? false`, and `job(from:)` reads the column with `?? false`.
  - 2: no `@Published`.
  - 5 (pattern): `runningJobs`, `ledgerAttention` and every URL bookkeeping field are transient, never on a `Codable` type.
  - 6: no new tool. Only `list_jobs`' description changes.
  - 7: inject `ConversationStore.inMemory()`, `ConfigManager(store:)` over a suite of the test's own, a fake `NotificationSink`, and the URL seams. Never mutate `ConfigManager.shared` or `AppState.shared`.
  - 8: nothing is added to the composer's `VStack`.
  - 9: each PR ends with a task that greps for what it made untrue.
- **Bounded tests.**
  - Await every unstructured task through `value(of:within:)` (`Tests/irisTests/BoundedWait.swift`), never bare.
  - Every new suite that starts a task carries `.timeLimit(.minutes(1))`.
  - Run focused tests as `timeout 300 scripts/test-filter.sh <TypeName>` and quote the count it ran.
  - The full suite is `timeout 900 swift test`. It is green only on all three: exit 0, the Swift Testing line `Test run with N tests … passed`, and XCTest's `Executed N tests, with 0 failures`.
  - If a `timeout` fires, sweep any orphaned `swiftpm-testing-helper` (`pkill -f swiftpm-testing-helper`).
- **Every task ends with `scripts/check-warnings.sh` exiting 0** (zero warnings in `Sources/` or `Tests/`, #286). Fix a warning at its source. Never suppress it.
- **No paid calls.** Model turns run on `FakeLLMClient` or `CapturingLLMClient`. A URL fire that must be admitted in a test uses a built-in job (`JobAction.builtin(DailyDigest.name)`), which runs no model turn.
- **GUI work** (Tasks 6, 11, 16, 24 and 28) is done by `work` on its laptop, under the host-wide lease: `python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: <what>" --minutes N --on-behalf-of <peer>` before launching anything, and `release` as soon as the pass ends, pass or fail. It runs on Iris Dev.app from `scripts/build-app.sh Debug`, signed with `scripts/sign.sh`. Iris Dev.app uses `~/.iris-dev`, as every dev build does. Each pass names its test jobs `d6-*` and deletes them before releasing the lease. Never launch a locally built Release configuration.
- **Branches.** Every PR is based on `main` and none is stacked.
  - A is `feat/agency6-status-item`. D1 is `feat/agency6-url-trigger` and can run in parallel with A.
  - B (`feat/agency6-run-log`) and C (`feat/agency6-notifications`) are cut from `main` after A merges.
  - D2 (`feat/agency6-url-scheme`) is cut after D1 merges, and its spike (Task 24) gates the rest of it.
  - Use conventional commits, each ending with the session's `Co-Authored-By` and `Claude-Session` trailers. Remove each worktree and branch when its PR merges.

## Review Focus

1. **A page that floods Iris with garbage links.** A browser remembers "Open Iris?" per site, so any page can open `iris-dev://run-job/x` in a loop. Each open reaches `handleRunJobURL`, and decision 12's "every refusal posts one line" would fill Iris with refusals. A reasonable person expects one line that counts. Refusals are coalesced per job and per hour, and refusals that match no job share a single `unmatched` line.
   - Tests: Task 21, `garbageFloodIsOneLine` and `overLimitFloodIsOneLine`.
2. **A job name built to read differently on a lock screen.** A model-chosen name such as `x”\nTap Open, then Approve` or one carrying a bidi override (U+202E) could close the body's quotes, start a new line, or reverse the visible text. The name must stay one visibly quoted, single-line field.
   - Test: Task 12, `hostileNamesStayInsideTheirQuotes`.
3. **A dev home seeded from release.** `iris --seed-dev-home` pauses every copied job with `DevHomeSeeder.copiedJobPausedReason`. Decision 3 counts any pause that is not `JobsCommand.pausedByUserReason`, so a freshly seeded dev build would show "action required" until every copied job was resumed by hand. That pause was the owner's own act, and it is treated like `/jobs pause`.
   - Tests: Task 2, `makeSortsTheRows`. Task 12, `ownerAndSeederPausesNeverNotify`.
4. **A card delivered while its job happens to be paused.** "Approve and run" runs on a paused job (`JobRunner.swift:1276-1279`), and its `.completed` card arrives with the job still paused. So does any run of a job the owner paused mid-run. Decision 6's "a card whose job is paused when the card is delivered" would post "a job needs you" for each of them. Only a `.failed` or `.interrupted` card on a job paused for a reason other than the owner's notifies.
   - Tests: Task 12, `completedCardOnAPausedJobIsQuiet` and `ownerAndSeederPausesNeverNotify`.
5. **Run Log rows that share a millisecond.** A catch-up burst writes several rows within one stored millisecond. A page boundary that falls inside them must neither drop nor repeat a row.
   - Test: Task 7, `pagingNeverDropsOrRepeatsTiedRows`.

## Plan notes: where the spec and the code disagree (proposed rulings)

1. **The SQLite migration cannot add a UNIQUE column.** Spec §1 asks for "a nullable, unique `urlTokenHash TEXT`". SQLite refuses `ALTER TABLE … ADD COLUMN … UNIQUE` ("Cannot add a UNIQUE column").
   - *Ruling:* add the plain column, then `CREATE UNIQUE INDEX jobs_urlTokenHash ON jobs(urlTokenHash)`. A unique index still allows any number of NULLs (Task 17).
2. **`upsert` compares only the gate today.** Decision 11 says it "compares the stored prompt, profile and policy … as it already does for the gate (`JobLedger.swift:105-112`)". The code reads only the stored `trigger`.
   - *Ruling:* in the same write transaction, `upsert` reads `trigger, prompt, profile, policy, urlTrigger` and clears the flag and digest when the job is URL-enabled and any of the three differs. The policy is compared as a decoded `JobPolicy`, which covers the grant and every budget field (Task 17).
3. **The hotkey cannot find the window by title.** It matches `$0.title == "Iris"` (`iris.swift:5221`), but `ChatView` sets `.navigationTitle(conv.title)` (`ChatView.swift:398`). The window is called "Iris" only while Iris or nothing is selected. Otherwise the hotkey falls back to "the first SwiftUI window", which can be Diagnostics or, after PR B, the Run Log.
   - *Ruling:* `MainWindow` tracks the chat window by reference, through an `NSViewRepresentable` in `ChatView`, and the hotkey, the status item and notifications all use it (Task 4).
4. **`WindowGroup("Iris")` has no id**, so nothing can reopen it once it is closed, which is why "Show Chat" was a placeholder.
   - *Ruling:* it becomes `WindowGroup("Iris", id: "main")`. `ChatView` hands its `openWindow` action to `MainWindow` for surfaces with no SwiftUI environment. The first launch after this change may forget the window's saved frame once.
5. **Notifying on a paused job is narrowed** (Review Focus 4). A card notifies when its job is paused at delivery only if the card is `.failed` or `.interrupted` and the pause reason is not the owner's own (`pausedByUserReason` or `copiedJobPausedReason`).
6. **The seeder's pause counts as an owner pause** (Review Focus 3), both for the icon and for notifications. One set, `LedgerAttention.ownerPauseReasons`, holds both reasons.
7. **Spec §2 wants the `schedule_job` and `register_directory_watcher` descriptions to say that a re-schedule or an update turns the URL trigger off.** Neither declaration describes re-scheduling or updating today: the `name` parameter says only "Optional short name", and `ToolExecutor.watchDescription` is two sentences by design. So no sentence is falsified, and adding one would cost prompt tokens on every turn of every conversation (invariant 6).
   - *Ruling:* the fact goes where the model reads it when it happens. The tool's result says so (`ScheduleJobArguments.urlTriggerClearedNote`), and Iris gets decision 11's line. `list_jobs`' description, which already lists every field, gains `urlTrigger` (Tasks 18 and 19).
8. **Refusal coalescing is widened from over-limit refusals to all of them** (Review Focus 1). Decision 13 coalesces over-limit refusals per job per hour. Decision 12 says every refusal posts a line, which a garbage flood turns into a flood of lines.
   - *Ruling:* every refusal goes through one coalescer. The key is the job id for a job-specific refusal, and `unmatched` for a parse failure or an unknown token (Task 21).
9. **A URL fire costs one line, not two.** `/jobs run` prints "Starting …" and then the answer. A URL fire prints `Firing <job> from a URL …` and updates that same line in place with the answer (`updateMessageContent`), so that every fire posts one line, as decision 12 says. `/jobs run`'s lines are unchanged.
10. **One pending deferral per job.** A second link for the same job while one waits joins the wait. It adds no second line and no second fire (Task 22).
11. **A URL fire that the `queue` overlap policy holds is recorded as `queued`** (`FireOrigin.queued(from:)`'s `triggerKind`), so the URL limit does not count it. The `queue` policy holds one fire at most, so the gap is bounded at one extra fire. It is accepted and not fixed.
12. **The token's exclusion test covers a fourth path.** `summarizeForRotation` sends `.user`, `.agent` and `.event` messages to a model (`iris.swift:1497`). A `.command` reply is outside it today. Task 18 pins it beside the three that #462's re-review named (model history, FTS, `read_conversation`).
13. **D1 ships `/jobs url` before anything can open the link.** The scheme is registered in D2. D1's reply and docs therefore say that the link opens once D2 lands (`JobsCommand.urlSchemePendingNote`), and D2's Task 26 deletes that note. That deletion is the falsifying half of invariant 9, made explicit.
14. **B is ordered after A.** Spec §4 lets B land on its own. This plan has B call A's `showMainWindow(selecting:)`, `revealCard(runId:jobId:)` and `acknowledgeRun(_:)` rather than write second copies, so B is cut from `main` after A merges. D1 keeps its independence.
15. **The Run Log also refreshes when the running count changes.** Decision 15 refreshes the log on appear and on a `LedgerAttention` change. A completed run changes neither, so a row would show "running" until the next event. The plan adds `.onChange(of: state.runningJobs.count)`.
16. **`LedgerAttention` reads paused jobs through a new `JobLedger.pausedJobs()`**, not `jobs()`. `jobs()` is the one read that publishes `unreadableJobCount` (`JobLedger.swift:190-200`), and a background refresh must not move a figure that `/jobs` reports.

---

## PR A: attention, running jobs and the status item

Branch: `feat/agency6-status-item`, based on `main`. Spec decisions 2-5 and 16.

### Task 1: `runningJobs`, observed and keyed by job id

**Files:**
- Create: `Sources/IrisKit/RunningJob.swift`
- Modify: `Sources/IrisKit/AppState.swift:375` (after `transcriptSheetConversationId`)
- Modify: `Sources/IrisKit/JobRunner.swift:434`, `:444`, `:468` (`fire`), `:750` (helper beside `forget`), `:1280-1416` (`runApproved` split at `:1297`)
- Test: `Tests/irisTests/RunningJobsTests.swift` (new)

**Interfaces:**
- Produces:
  - `struct RunningJob: Equatable, Sendable { let name: String; var activities: Int }`.
  - `AppState.runningJobs: [UUID: RunningJob]` (`private(set)`, observed).
  - `AppState.adjustRunningJob(id: UUID, name: String, by delta: Int)`.
  - `AppState.runningJobsDidChange: (([UUID: RunningJob]) -> Void)?`, a test seam.
  - `JobRunner.reportRunning(_ job: Job, _ delta: Int) async` (private).

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/RunningJobsTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 5: `AppState.runningJobs` holds a job while any of its activities is in flight —
/// a run, a gate being asked, a built-in, an approved call — and lets it go on every way out.
@MainActor
@Suite("Running jobs (D6)", .timeLimit(.minutes(1)))
struct RunningJobsTests {
    private func harness(_ responses: [GeminiResponse] = [], autoApprove: Bool = true)
        throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = autoApprove
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: responses),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine)
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-running-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func text(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))],
                       usageMetadata: nil)
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    private func job(_ name: String = "pr-sweep", profile: JobProfile = .readOnly) -> Job {
        Job(name: name, prompt: "Reply with just the word tick.",
            trigger: .schedule(.interval(seconds: 60)), profile: profile)
    }

    /// Every value `runningJobs` took for one job, as its activity count (0 = absent).
    private final class Transitions { var counts: [Int] = [] }

    private func watch(_ state: AppState, _ jobId: UUID) -> Transitions {
        let seen = Transitions()
        state.runningJobsDidChange = { seen.counts.append($0[jobId]?.activities ?? 0) }
        return seen
    }

    @Test("two activities of one job are one entry, which goes only when both have ended")
    func countsActivitiesPerJob() throws {
        let (_, state, _) = try harness()
        let id = UUID()
        state.adjustRunningJob(id: id, name: "pr-sweep", by: 1)
        state.adjustRunningJob(id: id, name: "pr-sweep", by: 1)
        #expect(state.runningJobs.count == 1, "the menu counts jobs, not runs")
        state.adjustRunningJob(id: id, name: "pr-sweep", by: -1)
        #expect(state.runningJobs[id] == RunningJob(name: "pr-sweep", activities: 1),
                "one ending leaves the other running")
        state.adjustRunningJob(id: id, name: "pr-sweep", by: -1)
        #expect(state.runningJobs[id] == nil)
        state.adjustRunningJob(id: id, name: "pr-sweep", by: -1)
        #expect(state.runningJobs[id] == nil, "a stray decrement never leaves a negative count behind")
    }

    @Test("a completed run is running for its length, and cleared after")
    func completedRun() async throws {
        let (store, state, engine) = try harness([text("tick")])
        let job = self.job()
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .completed)
    }

    @Test("a failed run is cleared")
    func failedRun() async throws {
        let (store, state, engine) = try harness([])   // no responses queued: the model call fails
        let job = self.job()
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .failed)
    }

    @Test("a blocked run is cleared")
    func blockedRun() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-running-\(UUID().uuidString).txt").path
        let (store, state, engine) = try harness([
            call("write_file", ["path": .string(path), "content": .string("nope")]),
            text("I could not do that."),
        ])
        let job = self.job(name: "wants-to-write")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .blockedOnApproval)
    }

    @Test("a gate counts as running while it is asked, and its refusal clears it")
    func gateRefusal() async throws {
        let (store, state, engine) = try harness([text("tick")])
        let job = Job(name: "poller", prompt: "Reply with just the word tick.",
                      trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                              gate: .urlChanged(url: "https://example.invalid/f"))))
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config, protectionEnabled: false,
                               gateEvaluator: { _, _ in .unchanged(signal: "etag=aaa") })
        let seen = watch(state, job.id)

        let admission = await runner.fire(job: job, origin: .cadence(kind: "poll"))

        #expect(admission == .gateUnchanged)
        #expect(seen.counts == [1, 0])
    }

    @Test("a built-in, which runs no engine turn, still counts")
    func builtinRun() async throws {
        let (store, state, engine) = try harness()
        let job = Job(name: "mystery", prompt: "", trigger: .schedule(.interval(seconds: 60)),
                      action: .builtin("no-such-builtin"))
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        await runner.fire(job: job, origin: .schedule)

        #expect(seen.counts == [1, 0])
    }

    @Test("a fire admission refuses (its interrupted row) is never counted as running")
    func breakerRefusalNeverRuns() async throws {
        let (store, state, engine) = try harness()
        var job = self.job(name: "thrasher")
        job.policy.maxRunsPerHour = 1
        try store.ledger.upsert(job)
        let previous = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                              startedAt: Date().addingTimeInterval(-60), transcriptConversationId: UUID())
        try store.ledger.begin(run: previous)
        try store.ledger.finish(runId: previous.id, status: .completed, outcome: "did a thing",
                                failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                finishedAt: Date().addingTimeInterval(-59))
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config)
        let seen = watch(state, job.id)

        let admission = await runner.fire(job: job, origin: .schedule)

        #expect(admission == .pauseBreaker(count: 1))
        #expect(seen.counts.isEmpty)
    }

    @Test("an approved call counts for its length, including a refusal")
    func approvedCall() async throws {
        let dir = try tempDirectory(prefix: "iris-running")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness(autoApprove: false)
        let job = self.job(name: "writer", profile: .mutating)
        try store.ledger.upsert(job)
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(dir.appendingPathComponent("a.txt").path),
                                      "content": .string("once")], cwd: dir.path)
        let blocked = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.ledger.begin(run: blocked)
        try store.ledger.finish(runId: blocked.id, status: .blockedOnApproval, outcome: nil,
                                failureReason: "needs approval: write_file", blockedTool: "write_file",
                                tokens: TokenUsage(), finishedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try store.ledger.setBlockedCall(runId: blocked.id, call)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in }, config: config, sandboxAvailable: { true })
        let seen = watch(state, job.id)

        guard case .dispatched = await runner.runApproved(runId: blocked.id) else {
            Issue.record("the approval was refused")
            return
        }
        #expect(seen.counts == [1, 0])

        seen.counts = []
        #expect(await runner.runApproved(runId: blocked.id) == .refused(JobRunner.alreadyApprovedRefusal))
        #expect(seen.counts == [1, 0], "a refused click is bracketed too, so nothing is left behind")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh RunningJobsTests`. Expected: the build fails with "value of type 'AppState' has no member 'runningJobsDidChange'".

- [ ] **Step 3: Implement.** Create `Sources/IrisKit/RunningJob.swift`:

```swift
import Foundation

/// One job with work in flight right now (D6 decision 5). Keyed by job id on
/// `AppState.runningJobs`, so a scheduled run and an approved call of the same job are one entry
/// with two activities, and the status item counts jobs, not runs. Transient: never on a
/// `Codable` type and never persisted (the invariant 5 pattern).
struct RunningJob: Equatable, Sendable {
    let name: String
    var activities: Int
}
```

In `AppState.swift`, after `var transcriptSheetConversationId: UUID?` (`:375`):

```swift
    /// Job id → what of that job is in flight (D6 decision 5). Observed, so the status item
    /// redraws. Written only by `adjustRunningJob`, which `JobRunner` reaches through one hop.
    private(set) var runningJobs: [UUID: RunningJob] = [:]
    /// Test seam: every value `runningJobs` takes, in order, so a test can see an entry that came
    /// and went inside one `await`.
    @ObservationIgnored var runningJobsDidChange: (([UUID: RunningJob]) -> Void)?

    /// Counts one activity of job `id` in (`delta` 1) or out (-1). An entry at zero is removed,
    /// and a stray decrement never leaves a negative count behind.
    func adjustRunningJob(id: UUID, name: String, by delta: Int) {
        let activities = (runningJobs[id]?.activities ?? 0) + delta
        runningJobs[id] = activities > 0 ? RunningJob(name: name, activities: activities) : nil
        runningJobsDidChange?(runningJobs)
    }
```

In `JobRunner.swift`, beside `forget(jobId:)` (`:750`):

```swift
    /// D6 decision 5: one activity of `job` began (`+1`) or ended (`-1`), told to
    /// `AppState.runningJobs` in one hop (the actor-helper rule). Keyed by the job id, so a gate, a
    /// built-in and an approved call all count, which `engineTurnCounts` never sees.
    private func reportRunning(_ job: Job, _ delta: Int) async {
        guard let state else { return }
        let id = job.id, name = job.name
        await MainActor.run { state.adjustRunningJob(id: id, name: name, by: delta) }
    }
```

In `fire`, put one call after the insert and one after each removal:

```swift
            inFlight.insert(current.id)
            await reportRunning(current, +1)
```

```swift
            case .refuse(let refusal):
                inFlight.remove(current.id)
                await reportRunning(current, -1)
```

```swift
            inFlight.remove(current.id)
            await reportRunning(current, -1)
```

Split `runApproved(runId:)` at `guard let job = stored` (`:1297`). Everything from `guard call.reason != .profile` to the final `return .dispatched(runId: approved.id)` moves, unchanged, into the new private method:

```swift
        guard let job = stored else { return await refuse(Self.missingJobRefusal, for: nil) }
        // D6 decision 5: the click is running work for this job for as long as the call lasts.
        await reportRunning(job, +1)
        let outcome = await runApproved(job: job, blocked: blocked, call: call, runId: runId)
        await reportRunning(job, -1)
        return outcome
    }

    /// `runApproved(runId:)` once the run and its job are known. Split out only so the running
    /// count brackets every exit below.
    private func runApproved(job: Job, blocked: JobRun, call: BlockedCall, runId: UUID) async -> ApprovalOutcome {
        guard call.reason != .profile else {
            return await refuse(Self.profileNotApprovableRefusal, for: job)
        }
        // … the rest of the old body, unchanged …
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 8 tests passed. Quote the count.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, then restore.
  - Delete the `reportRunning(current, -1)` after the gate's refusal: `gateRefusal` fails with `[1]`.
  - Delete the decrement in `runApproved(runId:)`: `approvedCall` fails.

- [ ] **Step 6: Run the neighbours and the warnings check.**
  - Run `timeout 300 scripts/test-filter.sh 'JobRunnerTests|ApproveAndRunTests|GateEvaluatorTests|JobRetryTests'`. Expected: every test passes. Quote the count.
  - Run `scripts/check-warnings.sh`. Expected: `check-warnings: no warnings in Sources/ or Tests/`.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/RunningJob.swift Sources/IrisKit/AppState.swift Sources/IrisKit/JobRunner.swift Tests/irisTests/RunningJobsTests.swift`, then `git commit -m "feat(jobs): observe running jobs by job id (D6 decision 5)"`.

### Task 2: `ledgerAttention`, refreshed after every write that moves it

**Files:**
- Create: `Sources/IrisKit/LedgerAttention.swift`
- Modify: `Sources/IrisKit/JobLedger.swift:221` (add `pausedJobs()` after `dueJobs`)
- Modify: `Sources/IrisKit/AppState.swift`: the stored properties after Task 1's; `dismissEventCard` (`:3075-3084`); `/jobs` `ack` (`:3795`), `pause` (`:3811`), `resume` (`:3824`) and `delete` (`:3934`)
- Modify: `Sources/IrisKit/EventDelivery.swift:38` (`deliverEvent`)
- Modify: `Sources/IrisKit/iris.swift:3326-3333` (one call in the `onJobsChanged` closure, plus a helper) and `:5203` (the launch refresh in `IrisApp.init`)
- Test: `Tests/irisTests/LedgerAttentionTests.swift` (new)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `struct LedgerAttention: Equatable, Sendable` with `blocked: [Blocked]`, `failedCount: Int`, `attentionPaused: [Paused]` and `ownerPausedCount: Int`. `Blocked` has `runId`, `jobId`, `jobName` and `tool: String?`. `Paused` has `jobId`, `name` and `reason`.
  - `static let empty`, `static let ownerPauseReasons: Set<String>`, `static func make(unacknowledged: [JobRun], paused: [Job]) -> LedgerAttention` and `static func read(_ ledger: JobLedger) throws -> LedgerAttention`.
  - `JobLedger.pausedJobs() throws -> [Job]`.
  - `AppState.ledgerAttention` (`private(set)`, observed).
  - `AppState.refreshLedgerAttention() -> Task<Void, Never>` (`@discardableResult`).
  - `AppState.ledgerAttentionRefresh: Task<Void, Never>?`, a test seam.
  - `AppState.ledgerAttentionReader: @Sendable (JobLedger) async throws -> LedgerAttention`, a test seam.
  - `AppState.acknowledgeRun(_ runId: UUID) -> Task<Void, Never>` (`@discardableResult`). `dismissEventCard(runId:)` now returns the same task, `@discardableResult`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/LedgerAttentionTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 16: the ledger's half of the status item is a cached snapshot, refreshed after
/// every write that can move it and never polled.
@MainActor
@Suite("Ledger attention (D6)", .timeLimit(.minutes(1)))
struct LedgerAttentionTests {
    private func makeApp() throws -> (ConversationStore, AppState, UUID) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation()
        app.selectedConversationId = id
        return (store, app, id)
    }

    private func job(_ name: String, pausedReason: String? = nil) -> Job {
        Job(name: name, prompt: "do it", trigger: .schedule(.interval(seconds: 60)), pausedReason: pausedReason)
    }

    @discardableResult
    private func row(_ job: Job, _ status: JobRun.Status, tool: String? = nil,
                     ledger: JobLedger) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Date())
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: status, outcome: nil, failureReason: nil,
                          blockedTool: tool, tokens: TokenUsage(), finishedAt: Date())
        return try #require(try ledger.run(id: run.id))
    }

    /// The refresh the code under test started, awaited, so a test never asserts on a snapshot
    /// that has not landed yet.
    private func landed(_ app: AppState) async throws {
        try await value(of: try #require(app.ledgerAttentionRefresh, "no refresh was started"))
    }

    @Test("blocked and failed rows, attention pauses and owner pauses each land in their own bucket")
    func makeSortsTheRows() {
        let jobId = UUID()
        var blocked = JobRun(jobId: jobId, jobName: "pr-sweep", triggerKind: "schedule",
                             startedAt: Date(), status: .blockedOnApproval)
        blocked.blockedTool = "run_command"
        let failed = JobRun(jobId: jobId, jobName: "pr-sweep", triggerKind: "schedule",
                            startedAt: Date(), status: .failed)
        let paused = [job("budgeted", pausedReason: JobRunner.budgetReason(scope: "job", used: 10, limit: 5)),
                      job("mine", pausedReason: JobsCommand.pausedByUserReason),
                      job("copied", pausedReason: DevHomeSeeder.copiedJobPausedReason)]

        let a = LedgerAttention.make(unacknowledged: [blocked, failed], paused: paused)

        #expect(a.blocked == [LedgerAttention.Blocked(runId: blocked.id, jobId: jobId,
                                                     jobName: "pr-sweep", tool: "run_command")])
        #expect(a.failedCount == 1)
        #expect(a.attentionPaused.map(\.name) == ["budgeted"])
        #expect(a.ownerPausedCount == 2,
                "a pause the owner made, by /jobs pause or by seeding the dev home, waits on nobody")
    }

    @Test("pausedJobs lists only paused jobs, and leaves the published unreadable count alone")
    func pausedJobsQuery() throws {
        let (store, _, _) = try makeApp()
        try store.ledger.upsert(job("running"))
        try store.ledger.upsert(job("stopped", pausedReason: JobRunner.gateFailingReason))
        _ = try store.ledger.jobs()
        let before = store.ledger.unreadableJobCount
        #expect(try store.ledger.pausedJobs().map(\.name) == ["stopped"])
        #expect(store.ledger.unreadableJobCount == before)
    }

    @Test("a delivered card refreshes the snapshot")
    func deliverRefreshes() async throws {
        let (store, app, _) = try makeApp()
        let j = job("pr-sweep")
        try store.ledger.upsert(j)
        let run = try row(j, .blockedOnApproval, tool: "run_command", ledger: store.ledger)
        let card = EventCard(runId: run.id, jobId: j.id, jobName: j.name, status: .blockedOnApproval,
                             blockedTool: "run_command", startedAt: Date(), finishedAt: Date())

        await app.deliverEvent(card, to: app.activityConversationId())
        try await landed(app)

        #expect(app.ledgerAttention.blocked.map(\.runId) == [run.id])
    }

    @Test("Dismiss acknowledges the run and clears it from the snapshot")
    func dismissRefreshes() async throws {
        let (store, app, _) = try makeApp()
        let j = job("pr-sweep")
        try store.ledger.upsert(j)
        let run = try row(j, .blockedOnApproval, tool: "run_command", ledger: store.ledger)
        try await value(of: app.refreshLedgerAttention())
        #expect(app.ledgerAttention.blocked.count == 1)

        try await value(of: app.dismissEventCard(runId: run.id))

        #expect(app.ledgerAttention.blocked.isEmpty)
        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt != nil)
    }

    @Test("/jobs ack refreshes the snapshot")
    func ackRefreshes() async throws {
        let (store, app, _) = try makeApp()
        let j = job("pr-sweep")
        try store.ledger.upsert(j)
        let run = try row(j, .failed, ledger: store.ledger)
        try await value(of: app.refreshLedgerAttention())
        #expect(app.ledgerAttention.failedCount == 1)

        app.sendMessage("/jobs ack \(run.id.uuidString.prefix(8))")
        try await landed(app)

        #expect(app.ledgerAttention.failedCount == 0)
    }

    @Test("/jobs pause, resume and delete refresh the snapshot")
    func jobsVerbsRefresh() async throws {
        let (store, app, _) = try makeApp()
        try store.ledger.upsert(job("nightly"))
        try store.ledger.upsert(job("thrasher", pausedReason: JobRunner.breakerReason(count: 6)))

        app.sendMessage("/jobs pause nightly")
        try await landed(app)
        #expect(app.ledgerAttention.ownerPausedCount == 1)
        #expect(app.ledgerAttention.attentionPaused.map(\.name) == ["thrasher"])

        app.sendMessage("/jobs resume nightly")
        try await landed(app)
        #expect(app.ledgerAttention.ownerPausedCount == 0)

        app.sendMessage("/jobs delete thrasher")
        try await landed(app)
        #expect(app.ledgerAttention.attentionPaused.isEmpty)
    }

    /// Holds the first read until released; every later read answers at once.
    private actor HeldRead {
        private var calls = 0
        private var held: CheckedContinuation<Void, Never>?
        private(set) var firstIsHeld = false

        func read(older: LedgerAttention, newer: LedgerAttention) async -> LedgerAttention {
            calls += 1
            guard calls == 1 else { return newer }
            await withCheckedContinuation { held = $0; firstIsHeld = true }
            return older
        }

        func release() { held?.resume(); held = nil }
    }

    @Test("an older read that finishes last never overwrites a newer one")
    func staleReadIsDropped() async throws {
        let (_, app, _) = try makeApp()
        let gate = HeldRead()
        let older = LedgerAttention(failedCount: 7), newer = LedgerAttention(failedCount: 1)
        app.ledgerAttentionReader = { _ in await gate.read(older: older, newer: newer) }

        let first = app.refreshLedgerAttention()
        var spins = 0
        while !(await gate.firstIsHeld), spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(await gate.firstIsHeld, "the first read must be parked before the second starts")
        let second = app.refreshLedgerAttention()
        try await value(of: second)
        #expect(app.ledgerAttention.failedCount == 1)

        await gate.release()
        try await value(of: first)
        #expect(app.ledgerAttention.failedCount == 1, "the older read finished last and was dropped")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh LedgerAttentionTests`. Expected: the build fails with "cannot find 'LedgerAttention' in scope".

- [ ] **Step 3: Implement.** Create `Sources/IrisKit/LedgerAttention.swift`:

```swift
import Foundation

/// What the ledger says is waiting on the owner (D6 decision 16): blocked runs nobody has
/// acknowledged, plain failures, and paused jobs split by whose doing the pause was. Cached on
/// `AppState.ledgerAttention` and refreshed after the writes that move it, never polled.
struct LedgerAttention: Equatable, Sendable {
    struct Blocked: Equatable, Sendable {
        let runId: UUID
        let jobId: UUID
        let jobName: String
        let tool: String?
    }

    struct Paused: Equatable, Sendable {
        let jobId: UUID
        let name: String
        let reason: String
    }

    var blocked: [Blocked] = []
    var failedCount = 0
    /// Paused by a breaker, a budget, the retry ladder, a failing gate, a vanished folder: each
    /// needs `/jobs resume`, so each lights the icon (owner ruling 3).
    var attentionPaused: [Paused] = []
    /// Paused by the owner, a count in the menu only.
    var ownerPausedCount = 0

    static let empty = LedgerAttention()

    /// The pauses the owner made: `/jobs pause`, and the seeder's pause of every job it copied
    /// into a dev home. Neither waits on anyone, so neither lights the icon or notifies.
    static let ownerPauseReasons: Set<String> = [JobsCommand.pausedByUserReason,
                                                 DevHomeSeeder.copiedJobPausedReason]

    static func make(unacknowledged: [JobRun], paused: [Job]) -> LedgerAttention {
        var out = LedgerAttention()
        for run in unacknowledged {
            switch run.status {
            case .blockedOnApproval:
                out.blocked.append(Blocked(runId: run.id, jobId: run.jobId, jobName: run.jobName,
                                           tool: run.blockedTool))
            case .failed:
                out.failedCount += 1
            case .running, .completed, .interrupted:
                break
            }
        }
        for job in paused {
            guard let reason = job.pausedReason else { continue }
            if ownerPauseReasons.contains(reason) {
                out.ownerPausedCount += 1
            } else {
                out.attentionPaused.append(Paused(jobId: job.id, name: job.name, reason: reason))
            }
        }
        return out
    }

    static func read(_ ledger: JobLedger) throws -> LedgerAttention {
        make(unacknowledged: try ledger.unacknowledgedFailures(), paused: try ledger.pausedJobs())
    }
}
```

In `JobLedger.swift`, after `dueJobs(at:)` (`:221`):

```swift
    /// The jobs with a `pausedReason`, oldest first: the status item's pause counts (D6 decision
    /// 16). Does not publish `unreadableJobCount`, which only `jobs()` does, for `/jobs`.
    func pausedJobs() throws -> [Job] {
        try decodeAll(sql: "SELECT * FROM jobs WHERE pausedReason IS NOT NULL ORDER BY createdAt, rowid",
                      arguments: []).jobs
    }
```

In `AppState.swift`, after Task 1's `adjustRunningJob`:

```swift
    /// D6 decision 16: what the ledger says is waiting on the owner, cached for the status item
    /// and the run log. Assigned only by `refreshLedgerAttention`. Never polled.
    private(set) var ledgerAttention = LedgerAttention.empty
    /// How the snapshot is read. A seam so a test can hold one read back and show that a slower,
    /// older read never overwrites a newer one.
    @ObservationIgnored var ledgerAttentionReader: @Sendable (JobLedger) async throws -> LedgerAttention = {
        try LedgerAttention.read($0)
    }
    /// Test seam: the most recent refresh, so a test awaits it rather than polling.
    @ObservationIgnored private(set) var ledgerAttentionRefresh: Task<Void, Never>?
    @ObservationIgnored private var ledgerAttentionGeneration = 0

    /// Reads the snapshot off the main actor and assigns it on it. Called at launch, after
    /// `deliverEvent`, after each acknowledge path, after `/jobs pause|resume|delete`, and from
    /// the watch layer's `onJobsChanged` closure.
    @discardableResult
    func refreshLedgerAttention() -> Task<Void, Never> {
        ledgerAttentionGeneration += 1
        let generation = ledgerAttentionGeneration
        let ledger = store.ledger
        let read = ledgerAttentionReader
        let task = Task { [weak self] in
            let snapshot = await Task.detached { try? await read(ledger) }.value
            // Only the newest read lands: two refreshes can finish out of order, and the older
            // one would put back a count the newer one had already cleared.
            guard let self, let snapshot, generation == self.ledgerAttentionGeneration else { return }
            self.ledgerAttention = snapshot
        }
        ledgerAttentionRefresh = task
        return task
    }
```

Replace `dismissEventCard(runId:)` (`:3069-3084`, its doc comment included):

```swift
    /// Marks a failed or blocked run seen. The card's Dismiss, the run log's Acknowledge and a
    /// notification's Dismiss all land here. The status item's snapshot is refreshed once the row
    /// is written (D6 decision 16). The card itself stays in the transcript: it is a record of
    /// what happened, not a notification to be cleared.
    ///
    /// Off the main actor, like every other write to the store.
    @discardableResult
    func acknowledgeRun(_ runId: UUID) -> Task<Void, Never> {
        let ledger = store.ledger
        return Task { [weak self] in
            let written = await Task.detached { () -> Bool in
                do {
                    try ledger.acknowledge(runId: runId, at: Date())
                    return true
                } catch {
                    print("[AppState] could not acknowledge run \(runId): \(error)")
                    return false
                }
            }.value
            guard written, let self else { return }
            await self.refreshLedgerAttention().value
        }
    }

    /// The card's "Dismiss".
    @discardableResult
    func dismissEventCard(runId: UUID) -> Task<Void, Never> { acknowledgeRun(runId) }
```

In `handleJobsCommand`, add one call after each write:
- `.ack`: after `try ledger.acknowledge(runId: id, at: Date())`, add `refreshLedgerAttention()`.
- `.pause`: after `try ledger.setPaused(jobId: job.id, reason: JobsCommand.pausedByUserReason)`, add `refreshLedgerAttention()`.
- `.resume`: after `try ledger.setRetry(jobId: job.id, attempt: 0, nextFireAt: next)`, add `refreshLedgerAttention()`.
- `.delete`: after `try ledger.delete(jobId: job.id)`, add `refreshLedgerAttention()`.

The `onJobsChanged` closure calls it too, but a test has no watch layer, and a refresh costs one read.

In `EventDelivery.swift`, make the first line of `deliverEvent(_:to:)`:

```swift
        // D6 decision 16: every pause, block and failure reaches the owner through here, so the
        // status item re-reads the ledger once the card is in, on every path out.
        defer { refreshLedgerAttention() }
```

In `iris.swift`, change the `onJobsChanged` closure (`:3326-3333`) to:

```swift
        ledger.onJobsChanged { [weak self, weak ledger] in
            // A task, because the hook runs on whatever thread finished the write and must not
            // wait on an actor — least of all one whose fire handler writes to this same ledger.
            Task {
                guard let self, let ledger else { return }
                await self.scheduleWatchSync(ledger: ledger).value
                // D6 decision 16: the status item's pause count moves with the jobs table too.
                // One call added to this hook, never a second hook: the ledger holds one, and a
                // second install would silently replace the watch resync above.
                await self.refreshStateLedgerAttention()
            }
        }
```

Add the helper beside `scheduleWatchSync`:

```swift
    /// The status item's ledger snapshot, refreshed on the main actor (the actor-helper rule).
    private func refreshStateLedgerAttention() async {
        let state = self.state
        await MainActor.run { _ = state?.refreshLedgerAttention() }
    }
```

In `IrisApp.init`, replace `:5203` with:

```swift
        MainActor.assumeIsolated {
            AppState.shared.installGuardHealthSink()
            // D6 decision 16: the snapshot at launch. Here and not in `AppState.init`, which a
            // test suite runs hundreds of times.
            AppState.shared.refreshLedgerAttention()
        }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 7 tests passed. Quote the count.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, then restore.
  - Delete the `defer` in `deliverEvent`: `deliverRefreshes` fails on "no refresh was started".
  - Delete `generation == self.ledgerAttentionGeneration` from the guard: `staleReadIsDropped` fails with 7.
  - Delete `DevHomeSeeder.copiedJobPausedReason` from `ownerPauseReasons`: `makeSortsTheRows` fails.

- [ ] **Step 6: Run the neighbours and the warnings check.**
  - Run `timeout 300 scripts/test-filter.sh 'EventDeliveryTests|JobsCommandTests|WatcherManagerSyncTests|WatchCoordinatorTests|WatcherJobsTests|EventCardTests'`. Expected: every test passes, so the watch resync still works through the edited hook. Quote the count.
  - Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/LedgerAttention.swift Sources/IrisKit/JobLedger.swift Sources/IrisKit/AppState.swift Sources/IrisKit/EventDelivery.swift Sources/IrisKit/iris.swift Tests/irisTests/LedgerAttentionTests.swift`, then `git commit -m "feat(jobs): cache the ledger's attention snapshot, refreshed on write (D6 decision 16)"`.

### Task 3: `SurfaceAttention`, the glyph and the menu's rows

**Files:**
- Create: `Sources/IrisKit/SurfaceAttention.swift`
- Modify: `Sources/IrisKit/BuildIdentity.swift:28` (add `statusSymbol` after `hotkeyName`)
- Test: `Tests/irisTests/SurfaceAttentionTests.swift` (new)

**Interfaces:**
- Consumes: `RunningJob` and `AppState.runningJobs` (Task 1), `LedgerAttention` and `AppState.ledgerAttention` (Task 2).
- Produces:
  - `enum SurfaceAttention: Equatable, Sendable { case actionRequired([Reason]), running(Int), idle }`.
  - `SurfaceAttention.Reason` has four cases: `.approvals(count:conversationId:)`, `.goalWait(conversationId:title:phrase:)`, `.blocked(LedgerAttention.Blocked)` and `.paused(label:jobs:)`.
  - `SurfaceAttention.Ask(id:root:requestedAt:)` and `SurfaceAttention.Wait(conversationId:title:phrase:)`.
  - `static func derive(asks:waits:runningJobs:ledger:) -> SurfaceAttention`, `var actionCount: Int` and `static func pauseLabel(_ reason: String) -> String`.
  - `struct StatusMenuRow: Identifiable, Equatable, Sendable` with `id`, `text` and `target`. `Target` is `.conversation(UUID)`, `.card(runId:jobId:)`, `.iris` or `.nowhere`.
  - `static func menuRows(_:ledger:runningCount:) -> [StatusMenuRow]`.
  - `struct StatusGlyph: Equatable, Sendable` with `symbol`, `text: String?` and `accessibilityLabel`, plus `static func make(_:identity:)`.
  - `BuildIdentity.statusSymbol: String`.
  - `AppState.surfaceAttention: SurfaceAttention` (computed).

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/SurfaceAttentionTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 2-4: one derived value answers "does Iris need me?" for every surface. Plain
/// failures and the owner's own pauses never light the icon.
@MainActor
@Suite("Surface attention (D6)", .timeLimit(.minutes(1)))
struct SurfaceAttentionTests {
    private let jobId = UUID()

    private func blocked(_ name: String = "pr-sweep") -> LedgerAttention.Blocked {
        LedgerAttention.Blocked(runId: UUID(), jobId: jobId, jobName: name, tool: "run_command")
    }

    private func paused(_ reason: String, _ name: String = "pr-sweep") -> LedgerAttention.Paused {
        LedgerAttention.Paused(jobId: UUID(), name: name, reason: reason)
    }

    private func ask(root: UUID?, at offset: TimeInterval = 0) -> SurfaceAttention.Ask {
        SurfaceAttention.Ask(id: UUID(), root: root, requestedAt: Date(timeIntervalSince1970: 1_000 + offset))
    }

    @Test("each input on its own, and the precedence between them")
    func table() {
        let root = UUID(), running = [jobId: RunningJob(name: "pr-sweep", activities: 1),
                                      UUID(): RunningJob(name: "digest", activities: 1)]
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: .empty) == .idle)
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: running, ledger: .empty) == .running(2))

        let asks = SurfaceAttention.derive(asks: [ask(root: root, at: 5), ask(root: UUID(), at: 1)],
                                           waits: [], runningJobs: running, ledger: .empty)
        guard case .actionRequired(let reasons) = asks else { Issue.record("\(asks)"); return }
        if case .approvals(let n, _) = reasons.first { #expect(n == 2) } else { Issue.record("\(reasons)") }
        #expect(asks.actionCount == 2, "an ask outranks running jobs")

        let wait = SurfaceAttention.Wait(conversationId: root, title: "Ship it", phrase: "checkpoint review")
        #expect(SurfaceAttention.derive(asks: [], waits: [wait], runningJobs: [:], ledger: .empty)
                == .actionRequired([.goalWait(conversationId: root, title: "Ship it", phrase: "checkpoint review")]))

        let b = blocked()
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: LedgerAttention(blocked: [b]))
                == .actionRequired([.blocked(b)]))
    }

    @Test("plain failures and the owner's own pauses never produce action required")
    func failuresAndOwnerPausesStayQuiet() {
        let quiet = LedgerAttention(failedCount: 3, ownerPausedCount: 2)
        #expect(SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: quiet) == .idle)
        #expect(SurfaceAttention.derive(asks: [], waits: [],
                                        runningJobs: [jobId: RunningJob(name: "x", activities: 1)],
                                        ledger: quiet) == .running(1))
    }

    @Test("attention pauses are grouped by label, and each paused job counts")
    func pausesGroup() {
        let ledger = LedgerAttention(attentionPaused: [
            paused(JobRunner.budgetReason(scope: "job", used: 9, limit: 5), "a"),
            paused(JobRunner.budgetReason(scope: "global", used: 9, limit: 5), "b"),
            paused(JobRunner.breakerReason(count: 6), "c"),
        ])
        let attention = SurfaceAttention.derive(asks: [], waits: [], runningJobs: [:], ledger: ledger)
        guard case .actionRequired(let reasons) = attention else { Issue.record("\(attention)"); return }
        let labels = reasons.compactMap { r -> String? in
            if case .paused(let label, let jobs) = r { return "\(label):\(jobs.count)" }
            return nil
        }
        #expect(labels == ["breaker:1", "budget:2"])
        #expect(attention.actionCount == 3)
    }

    @Test("every pause reason the runner writes has its label")
    func pauseLabels() {
        #expect(SurfaceAttention.pauseLabel(JobRunner.breakerReason(count: 6)) == "breaker")
        #expect(SurfaceAttention.pauseLabel(JobRunner.budgetReason(scope: "job", used: 1, limit: 1)) == "budget")
        #expect(SurfaceAttention.pauseLabel(JobRunner.legacyBudgetReasonPrefix + " (job)") == "budget")
        #expect(SurfaceAttention.pauseLabel(JobRunner.retriesExhaustedReason) == "retries used up")
        #expect(SurfaceAttention.pauseLabel(JobRunner.gateFailingReason) == "gate failing")
        #expect(SurfaceAttention.pauseLabel(JobRunner.unknownBuiltinReason("x")) == "unknown built-in")
        #expect(SurfaceAttention.pauseLabel(JobScheduler.unmatchableReason) == "schedule never matches")
        #expect(SurfaceAttention.pauseLabel("watched folder is gone: /tmp/x") == "needs /jobs resume")
    }

    @Test("the three states differ in shape, and dev and release differ in symbol")
    func glyphs() {
        let idle = StatusGlyph.make(.idle, identity: .dev)
        let running = StatusGlyph.make(.running(2), identity: .dev)
        let action = StatusGlyph.make(.actionRequired([.blocked(blocked()), .blocked(blocked())]), identity: .dev)
        #expect(idle.text == nil)
        #expect(running.text == "2")
        #expect(action.text == "!2")
        #expect(Set([idle.symbol, running.symbol, action.symbol]) == ["hammer"])
        #expect(StatusGlyph.make(.idle, identity: .release).symbol == "sparkles")
        #expect(BuildIdentity.release.statusSymbol != BuildIdentity.dev.statusSymbol)
    }

    @Test("the menu says what is waiting, flattened, with secondary counts below")
    func menuRows() {
        let root = UUID()
        let b = blocked("pr\nsweep")
        let ledger = LedgerAttention(blocked: [b], failedCount: 3,
                                     attentionPaused: [paused(JobRunner.budgetReason(scope: "job", used: 9, limit: 5))],
                                     ownerPausedCount: 1)
        let attention = SurfaceAttention.derive(asks: [ask(root: root), ask(root: root)], waits: [],
                                                runningJobs: [:], ledger: ledger)
        let rows = SurfaceAttention.menuRows(attention, ledger: ledger, runningCount: 1)
        #expect(rows.map(\.text) == ["2 approvals waiting", "pr sweep blocked: run_command",
                                     "1 job paused (budget)", "1 job running", "3 failed runs",
                                     "1 job paused by you"])
        #expect(rows[0].target == .conversation(root))
        #expect(rows[1].target == .card(runId: b.runId, jobId: b.jobId))
        #expect(rows[3].target == .nowhere)
    }

    // MARK: Wiring

    private func makeApp() throws -> AppState {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        return app
    }

    @Test("a delegate's ask is charged to the conversation it works for")
    func delegateAskChargedToRoot() async throws {
        let app = try makeApp()
        let parent = app.createNewConversation(), child = app.createNewConversation(isSubagent: true)
        app.linkDelegate(child, of: parent)
        let ask = Task { @MainActor in
            await app.enqueueUserApproval(toolName: "run_command", details: "make test", workspace: nil,
                                          conversationId: child, origin: "test")
        }
        var spins = 0
        while app.pendingApprovals.isEmpty, spins < 10_000 { await Task.yield(); spins += 1 }

        guard case .actionRequired(let reasons) = app.surfaceAttention else {
            Issue.record("\(app.surfaceAttention)"); return
        }
        #expect(reasons.first == .approvals(count: 1, conversationId: parent))

        app.resolveApproval(id: app.pendingApprovals[0].id, .deny)
        #expect(try await value(of: ask) == false)
        #expect(app.surfaceAttention == .idle)
    }

    @Test("a goal draft lights the icon only in a user-facing, unarchived conversation")
    func draftScope() throws {
        let app = try makeApp()
        let id = app.createNewConversation(title: "Ship it")
        app.setDraftContract(for: id, GoalContract(objective: "ship it",
                                                  criteria: [Criterion(text: "tests pass", kind: .qualitative)]))
        #expect(app.surfaceAttention == .actionRequired([
            .goalWait(conversationId: id, title: "Ship it", phrase: "goal contract to review")]))

        let idx = try #require(app.conversations.firstIndex { $0.id == id })
        app.conversations[idx].isArchived = true
        #expect(app.surfaceAttention == .idle, "an archived conversation's draft never lights the icon")

        app.conversations[idx].isArchived = false
        app.conversations[idx].isBackground = true
        #expect(app.surfaceAttention == .idle, "nor does a background run's")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh SurfaceAttentionTests`. Expected: the build fails with "cannot find 'SurfaceAttention' in scope".

- [ ] **Step 3: Implement.** In `BuildIdentity.swift`, after `hotkeyName`:

```swift
    /// The status item's base symbol (D6 decision 4): two running builds can be told apart in
    /// the menu bar, as their hotkeys already can.
    var statusSymbol: String { self == .release ? "sparkles" : "hammer" }
```

Create `Sources/IrisKit/SurfaceAttention.swift`:

```swift
import Foundation

/// The one answer to "does Iris need me?" (D6 decision 2), computed from four inputs and never
/// stored: the live asks, the goal waits of the user's own conversations, the jobs in flight,
/// and the ledger's snapshot. The status item draws it, and the run log refreshes from its
/// ledger half. Action required outranks running, which outranks idle.
enum SurfaceAttention: Equatable, Sendable {
    case actionRequired([Reason])
    case running(Int)
    case idle

    /// Something waiting on the owner that a click resolves (owner ruling 3).
    enum Reason: Equatable, Sendable {
        /// Every live ask, wherever it is charged. `conversationId` is the delegation root of the
        /// oldest one, which is where Open goes.
        case approvals(count: Int, conversationId: UUID?)
        /// An unarchived, user-facing conversation waiting on a goal decision.
        case goalWait(conversationId: UUID, title: String, phrase: String)
        case blocked(LedgerAttention.Blocked)
        /// Jobs paused for a reason that needs `/jobs resume`, grouped by `pauseLabel`.
        case paused(label: String, jobs: [LedgerAttention.Paused])
    }

    struct Ask: Equatable, Sendable {
        let id: UUID
        /// The delegation root the ask is charged to; nil for an ask with no conversation.
        let root: UUID?
        let requestedAt: Date
    }

    struct Wait: Equatable, Sendable {
        let conversationId: UUID
        let title: String
        let phrase: String
    }

    static func derive(asks: [Ask], waits: [Wait], runningJobs: [UUID: RunningJob],
                       ledger: LedgerAttention) -> SurfaceAttention {
        var reasons: [Reason] = []
        if let oldest = asks.min(by: { $0.requestedAt < $1.requestedAt }) {
            reasons.append(.approvals(count: asks.count, conversationId: oldest.root))
        }
        reasons += waits.map { .goalWait(conversationId: $0.conversationId, title: $0.title, phrase: $0.phrase) }
        reasons += ledger.blocked.map(Reason.blocked)
        let byLabel = Dictionary(grouping: ledger.attentionPaused) { pauseLabel($0.reason) }
        reasons += byLabel.keys.sorted().map { .paused(label: $0, jobs: byLabel[$0] ?? []) }
        if !reasons.isEmpty { return .actionRequired(reasons) }
        if !runningJobs.isEmpty { return .running(runningJobs.count) }
        return .idle
    }

    /// How many things are waiting: each ask, each wait, each blocked run, each paused job.
    var actionCount: Int {
        guard case .actionRequired(let reasons) = self else { return 0 }
        return reasons.reduce(0) { sum, reason in
            switch reason {
            case .approvals(let count, _): return sum + count
            case .goalWait, .blocked: return sum + 1
            case .paused(_, let jobs): return sum + jobs.count
            }
        }
    }

    /// The menu's word for why a job is paused. Matched against the reasons the runner and the
    /// scheduler write; `SurfaceAttentionTests.pauseLabels` pins each one, so a reworded reason
    /// fails a test rather than falling through to the catch-all.
    static func pauseLabel(_ reason: String) -> String {
        if reason.hasPrefix("breaker:") { return "breaker" }
        if reason.hasPrefix("daily weighted-token budget reached")
            || reason.hasPrefix(JobRunner.legacyBudgetReasonPrefix) { return "budget" }
        if reason == JobRunner.retriesExhaustedReason { return "retries used up" }
        if reason == JobRunner.gateFailingReason { return "gate failing" }
        if reason.hasPrefix(JobRunner.unknownBuiltinReason) { return "unknown built-in" }
        if reason == JobScheduler.unmatchableReason { return "schedule never matches" }
        return "needs /jobs resume"
    }
}

/// One line of the status item's menu, and where clicking it goes.
struct StatusMenuRow: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case conversation(UUID)
        case card(runId: UUID, jobId: UUID)
        case iris
        case nowhere
    }

    let id: String
    let text: String
    let target: Target
}

extension SurfaceAttention {
    static let menuTitleCap = 40

    /// The menu's rows: what is waiting, then the counts that never change the icon (decision 3).
    /// Model-chosen names are flattened and capped as the briefing does.
    static func menuRows(_ attention: SurfaceAttention, ledger: LedgerAttention,
                         runningCount: Int) -> [StatusMenuRow] {
        var rows: [StatusMenuRow] = []
        if case .actionRequired(let reasons) = attention {
            for reason in reasons {
                switch reason {
                case .approvals(let count, let root):
                    rows.append(StatusMenuRow(id: "approvals", text: "\(count) approval\(plural(count)) waiting",
                                              target: root.map(StatusMenuRow.Target.conversation) ?? .nowhere))
                case .goalWait(let id, let title, let phrase):
                    rows.append(StatusMenuRow(id: "wait-\(id)",
                                              text: "\(phrase.prefix(1).uppercased() + phrase.dropFirst()) in “\(field(title, cap: menuTitleCap))”",
                                              target: .conversation(id)))
                case .blocked(let b):
                    rows.append(StatusMenuRow(id: "blocked-\(b.runId)",
                                              text: "\(field(b.jobName)) blocked: \(field(b.tool ?? "a tool"))",
                                              target: .card(runId: b.runId, jobId: b.jobId)))
                case .paused(let label, let jobs):
                    rows.append(StatusMenuRow(id: "paused-\(label)",
                                              text: "\(jobs.count) job\(plural(jobs.count)) paused (\(label))",
                                              target: .iris))
                }
            }
        }
        if runningCount > 0 {
            rows.append(StatusMenuRow(id: "running", text: "\(runningCount) job\(plural(runningCount)) running",
                                      target: .nowhere))
        }
        if ledger.failedCount > 0 {
            rows.append(StatusMenuRow(id: "failed", text: "\(ledger.failedCount) failed run\(plural(ledger.failedCount))",
                                      target: .iris))
        }
        if ledger.ownerPausedCount > 0 {
            rows.append(StatusMenuRow(id: "owner-paused",
                                      text: "\(ledger.ownerPausedCount) job\(plural(ledger.ownerPausedCount)) paused by you",
                                      target: .nowhere))
        }
        return rows
    }

    private static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    private static func field(_ value: String, cap: Int = IrisEngine.cardNameCap) -> String {
        IrisEngine.flattenCardField(value, cap: cap)
    }
}

/// What the menu bar draws (D6 decision 4). Menu bar images are template-rendered, so the states
/// differ in shape: the base symbol alone, the symbol and a count, the symbol and `!` and a count.
struct StatusGlyph: Equatable, Sendable {
    let symbol: String
    let text: String?
    let accessibilityLabel: String

    static func make(_ attention: SurfaceAttention, identity: BuildIdentity) -> StatusGlyph {
        let base = identity.statusSymbol
        switch attention {
        case .idle:
            return StatusGlyph(symbol: base, text: nil, accessibilityLabel: "Iris: idle")
        case .running(let n):
            return StatusGlyph(symbol: base, text: "\(n)",
                               accessibilityLabel: "Iris: \(n) job\(n == 1 ? "" : "s") running")
        case .actionRequired:
            let n = attention.actionCount
            return StatusGlyph(symbol: base, text: "!\(n)",
                               accessibilityLabel: "Iris: \(n) thing\(n == 1 ? "" : "s") waiting on you")
        }
    }
}

extension AppState {
    /// D6 decision 2, over this app's state. An ask is counted wherever it is charged. A goal wait
    /// counts only in an unarchived, user-facing conversation (the `list_sessions` filter) that
    /// has no ask of its own, since that ask is already counted.
    var surfaceAttention: SurfaceAttention {
        let asks = pendingApprovals.map {
            SurfaceAttention.Ask(id: $0.id, root: $0.conversationId.map(delegationRoot(of:)),
                                 requestedAt: $0.requestedAt)
        }
        let askRoots = Set(asks.compactMap(\.root))
        let waits = conversations.compactMap { c -> SurfaceAttention.Wait? in
            guard !c.isArchived, c.isUserFacing, !askRoots.contains(c.id),
                  case .waiting(let on, _) = sessionStatus(for: c) else { return nil }
            return SurfaceAttention.Wait(conversationId: c.id, title: c.title, phrase: on)
        }
        return .derive(asks: asks, waits: waits, runningJobs: runningJobs, ledger: ledgerAttention)
    }
}
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 9 tests passed. Quote the count.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, then restore.
  - In `derive`, add `if ledger.failedCount > 0 { reasons.append(.paused(label: "failed", jobs: [])) }`: `failuresAndOwnerPausesStayQuiet` fails.
  - Remove `!c.isArchived` from `surfaceAttention`: `draftScope` fails.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/SurfaceAttention.swift Sources/IrisKit/BuildIdentity.swift Tests/irisTests/SurfaceAttentionTests.swift`, then `git commit -m "feat(ui): one derived attention value, its glyph and menu rows (D6 decisions 2-4)"`.

### Task 4: `showMainWindow`, the window tracker, and the live status item

**Files:**
- Create: `Sources/IrisKit/StatusItem.swift` (`MainWindow`, `MainWindowTracker`, `StatusItemLabel`, `StatusMenu`)
- Modify: `Sources/IrisKit/AppState.swift` (`raiseMainWindow`, `showMainWindow(selecting:)` and `revealCard(runId:jobId:)`, after Task 2's properties)
- Modify: `Sources/IrisKit/ChatView.swift:489-495` (the root `.onAppear`) and the view it is attached to (`.background(MainWindowTracker())`)
- Modify: `Sources/IrisKit/iris.swift:5203` (raise wiring), `:5220-5235` (hotkey), `:5239` (`WindowGroup` id), `:5259-5277` (`MenuBarExtra`)
- Test: `Tests/irisTests/MainWindowRoutingTests.swift` (new)

**Interfaces:**
- Consumes: `SurfaceAttention`, `StatusMenuRow`, `StatusGlyph` and `AppState.surfaceAttention` (Task 3). `AppState.ledgerAttention` (Task 2). `AppState.runningJobs` (Task 1).
- Produces:
  - `AppState.raiseMainWindow: @MainActor () -> Void`.
  - `AppState.showMainWindow(selecting: UUID?)`.
  - `AppState.revealCard(runId: UUID, jobId: UUID)`.
  - `@MainActor enum MainWindow` with `sceneId = "main"`, `current: NSWindow?`, `openAction: OpenWindowAction?`, `isVisible`, `isFrontmost`, `track(_:)`, `raise(fallback:)` and `hide()`.
  - Views: `MainWindowTracker`, `StatusItemLabel(state:)` and `StatusMenu(state:)`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/MainWindowRoutingTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 4: every surface raises the main window through one `showMainWindow(selecting:)`,
/// and a row about a card lands on the card.
@MainActor
@Suite("Main window routing (D6)", .timeLimit(.minutes(1)))
struct MainWindowRoutingTests {
    private final class Raises { var count = 0 }

    private func makeApp() throws -> (ConversationStore, AppState, Raises) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let raises = Raises()
        app.raiseMainWindow = { raises.count += 1 }
        return (store, app, raises)
    }

    @Test("selects a conversation the sidebar can show, then raises once")
    func selectsAndRaises() throws {
        let (_, app, raises) = try makeApp()
        let id = app.createNewConversation(select: false)
        app.showMainWindow(selecting: id)
        #expect(app.selectedConversationId == id)
        #expect(raises.count == 1)
    }

    @Test("never selects a background run's transcript or an unknown id, and still raises")
    func refusesBackgroundAndUnknown() throws {
        let (_, app, raises) = try makeApp()
        let mine = app.createNewConversation()
        let background = app.createNewConversation(isBackground: true)
        app.showMainWindow(selecting: background)
        app.showMainWindow(selecting: UUID())
        app.showMainWindow(selecting: nil)
        #expect(app.selectedConversationId == mine)
        #expect(raises.count == 3)
    }

    @Test("revealCard opens Iris and scrolls to the card, when the job has no destination")
    func revealCardInIris() async throws {
        let (store, app, raises) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let runId = UUID()
        let card = EventCard(runId: runId, jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                             blockedTool: "run_command", startedAt: Date(), finishedAt: Date())
        let iris = app.activityConversationId()
        await app.deliverEvent(card, to: iris)
        let cardMessage = try #require(app.conversations.first { $0.id == iris }?.messages.last { $0.role == .event })

        app.revealCard(runId: runId, jobId: job.id)

        #expect(app.selectedConversationId == iris)
        #expect(app.pendingScrollTarget == cardMessage.id)
        #expect(raises.count == 1)
    }

    @Test("revealCard falls back to Iris for an archived destination or a deleted job")
    func revealCardFallsBack() throws {
        let (store, app, _) = try makeApp()
        let gone = app.createNewConversation()
        let idx = try #require(app.conversations.firstIndex { $0.id == gone })
        app.conversations[idx].isArchived = true
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)),
                      destinationConversationId: gone)
        try store.ledger.upsert(job)

        app.revealCard(runId: UUID(), jobId: job.id)
        #expect(app.selectedConversationId == app.activityConversationId())

        app.selectedConversationId = gone
        app.revealCard(runId: UUID(), jobId: UUID())
        #expect(app.selectedConversationId == app.activityConversationId())
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh MainWindowRoutingTests`. Expected: the build fails with "value of type 'AppState' has no member 'raiseMainWindow'".

- [ ] **Step 3: Implement the state half.** In `AppState.swift`, after Task 2's properties:

```swift
    /// How the main window is brought forward. `IrisApp` sets it to `MainWindow.raise()`; a test
    /// counts it. Nothing else may raise the window (D6 decision 4).
    @ObservationIgnored var raiseMainWindow: @MainActor () -> Void = {}

    /// The one way any surface raises the main window: the status item's rows and "Show Chat", a
    /// notification's Open, the run log's transcript, and the hotkey. Selects `conversationId`
    /// first when the sidebar can show it; a background run's transcript is never selected.
    func showMainWindow(selecting conversationId: UUID?) {
        if let conversationId, conversations.contains(where: { $0.id == conversationId && !$0.isBackground }) {
            selectedConversationId = conversationId
        }
        raiseMainWindow()
    }

    /// Opens the conversation a job's card was delivered to and scrolls to the card. The same
    /// rule `JobRunner.destination(for:)` delivers by: the job's destination while it exists
    /// unarchived, otherwise Iris, which also covers a job deleted since.
    func revealCard(runId: UUID, jobId: UUID) {
        let wanted = (try? store.ledger.job(id: jobId))?.destinationConversationId
        let target = wanted.flatMap { id in
            conversations.contains { $0.id == id && !$0.isArchived } ? id : nil
        } ?? activityConversationId()
        if let message = conversations.first(where: { $0.id == target })?.messages.last(where: {
            $0.role == .event && EventCard.decode($0.content)?.runId == runId
        }) {
            pendingScrollTarget = message.id
        }
        showMainWindow(selecting: target)
    }
```

- [ ] **Step 4: Run the tests and watch them pass.** Run the same filter. Expected: 4 tests passed. Quote the count.

- [ ] **Step 5: Implement the AppKit half.** Create `Sources/IrisKit/StatusItem.swift`:

```swift
import AppKit
import SwiftUI

/// The chat window, tracked by reference (D6 decision 4). Never by title: `ChatView` sets
/// `.navigationTitle(conv.title)`, so the window is called "Iris" only while Iris or nothing is
/// selected, and the old title match fell back to "the first SwiftUI window", which can be
/// Diagnostics or the run log.
@MainActor
enum MainWindow {
    static let sceneId = "main"
    private(set) static weak var current: NSWindow?
    /// `ChatView`'s `openWindow`, for a surface with no SwiftUI environment of its own (a
    /// notification's Open) once the window has been closed.
    static var openAction: OpenWindowAction?
    private static var closeObserver: NSObjectProtocol?

    static func track(_ window: NSWindow?) {
        guard let window, window !== current else { return }
        current = window
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { current = nil }
        }
    }

    /// On screen and not covered: what decides whether an ask needs a banner (decision 6).
    static var isVisible: Bool {
        guard let window = current else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    static var isFrontmost: Bool { NSApp.isActive && (current?.isKeyWindow ?? false) }

    static func raise(fallback: OpenWindowAction? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = current {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let open = fallback ?? openAction {
            open(id: sceneId)
        }
    }

    static func hide() { current?.orderOut(nil) }
}

/// Reports the window `ChatView` lives in to `MainWindow`.
struct MainWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainWindow.track(window)
        }
    }
}

/// The status item's label: the glyph `SurfaceAttention` asks for (D6 decision 4).
struct StatusItemLabel: View {
    let state: AppState

    var body: some View {
        let glyph = StatusGlyph.make(state.surfaceAttention, identity: .current)
        Group {
            if let text = glyph.text {
                Text("\(Image(systemName: glyph.symbol))\(text)")
            } else {
                Image(systemName: glyph.symbol)
            }
        }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}

/// The status item's menu: what is waiting, each row opening what it names, then the app's
/// own items.
struct StatusMenu: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = SurfaceAttention.menuRows(state.surfaceAttention, ledger: state.ledgerAttention,
                                             runningCount: state.runningJobs.count)
        ForEach(rows) { row in
            if row.target == .nowhere {
                Text(row.text)
            } else {
                Button(row.text) { open(row.target) }
            }
        }
        if !rows.isEmpty { Divider() }
        Button("Show Chat") { show(selecting: nil) }
        Divider()
        if let updater = UpdaterController.shared {
            CheckForUpdatesButton(updater: updater)
        }
        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    private func open(_ target: StatusMenuRow.Target) {
        adoptOpenAction()
        switch target {
        case .conversation(let id): state.showMainWindow(selecting: id)
        case .card(let runId, let jobId): state.revealCard(runId: runId, jobId: jobId)
        case .iris: state.showMainWindow(selecting: state.activityConversationId())
        case .nowhere: break
        }
    }

    private func show(selecting id: UUID?) {
        adoptOpenAction()
        state.showMainWindow(selecting: id)
    }

    /// The menu has an environment of its own, so a closed window can reopen from here even
    /// before `ChatView` ever appeared to hand over its action.
    private func adoptOpenAction() {
        if MainWindow.openAction == nil { MainWindow.openAction = openWindow }
    }
}
```

In `ChatView.swift`, change the body's root `.onAppear` (`:489`) so it starts with the action handover, and attach the tracker directly before it:

```swift
        .background(MainWindowTracker())
        .onAppear {
            MainWindow.openAction = openWindow
            let hasCompletedSetup = IrisDefaults.store.bool(forKey: "HAS_COMPLETED_SETUP")
```

In `IrisApp.init`, extend Task 2's `MainActor.assumeIsolated` block with `AppState.shared.raiseMainWindow = { MainWindow.raise() }`. Replace the hotkey closure (`:5220-5235`) with:

```swift
        // D6 decision 4: the raise goes through `showMainWindow`, like every other surface's.
        KeyboardShortcuts.onKeyUp(for: .toggleIris) {
            if MainWindow.isFrontmost {
                MainWindow.hide()
            } else {
                AppState.shared.showMainWindow(selecting: nil)
            }
        }
```

In `body`, change `WindowGroup("Iris") {` to `WindowGroup("Iris", id: MainWindow.sceneId) {`, and replace the whole `MenuBarExtra("Iris", systemImage: "sparkles") { … }` block, its placeholder comments included, with:

```swift
        MenuBarExtra {
            StatusMenu(state: AppState.shared)
        } label: {
            StatusItemLabel(state: AppState.shared)
        }
```

- [ ] **Step 6: Build, and run the neighbours.**
  - Run `swift build`. Expected: it succeeds.
  - Run `timeout 300 scripts/test-filter.sh 'MainWindowRoutingTests|SurfaceAttentionTests|SidebarSearchResultsTests'`. Expected: every test passes, `pendingScrollTarget` included. Quote the count.
  - Run `scripts/check-warnings.sh`. Expected: no warnings. If `NSView` or the observer closure draws an isolation warning, fix its isolation at the source. Do not suppress it.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/StatusItem.swift Sources/IrisKit/AppState.swift Sources/IrisKit/ChatView.swift Sources/IrisKit/iris.swift Tests/irisTests/MainWindowRoutingTests.swift`, then `git commit -m "feat(ui): a live status item, a working Show Chat, one window raiser (D6 decision 4)"`.

### Task 5: Invariant 9 sweep, and open PR A

**Files:**
- Modify: `README.md:266` and its feature list
- Modify: `docs/jobs.md`, section "Event cards and the Iris conversation" (`:752`)

- [ ] **Step 1: Search, do not compose.** Run `grep -n -i "menu bar\|status item\|MenuBarExtra\|Show Chat\|hotkey" README.md docs/*.md` and `grep -rn -i "menu bar\|status item" Sources/IrisKit/*.swift | grep -v StatusItem.swift`, and read every hit.
  - README:266 ("Check by hand with … the menu bar item") stays true, because the menu keeps Check for Updates. Leave it.
  - A sentence that calls the menu bar item static, or that says "Show Chat" does nothing, is now false. Fix it.
  - Record what you found in the commit body, "nothing falsified" included.

- [ ] **Step 2: Add what is new.** In the README's feature list, after the jobs bullet:

```markdown
- **Menu bar status**: the menu bar item (a sparkle, or a hammer for a dev build) shows a count while background jobs run, and `!` with a count when something is waiting on you: an approval, a goal draft or checkpoint to review, a run blocked on a call, or a job paused by a limit. Its menu lists each one and opens it. Failed runs and jobs you paused yourself are listed but never change the icon.
```

In `docs/jobs.md`, at the end of "Event cards and the Iris conversation":

```markdown
The menu bar item carries the same news without opening the window. A blocked run that nobody has
acknowledged, and a job paused by its breaker, a budget, its retry ladder, a failing gate or a
vanished folder, each turn the icon to `!` with a count until the run is dismissed or the job is
resumed. A plain failure, including one still on its retry ladder, and a job you paused with
`/jobs pause` are counts in the menu only. While a job is running, the icon shows how many.
```

- [ ] **Step 3: Full suite.** Run `timeout 900 swift test`. Expected: exit 0, the Swift Testing line, and `Executed N tests, with 0 failures`. Then run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 4: Commit, push and open PR A.**
  - Run `git add README.md docs/jobs.md`, then `git commit -m "docs: the menu bar status item (D6)"`, then `git push -u origin feat/agency6-status-item`.
  - Write the PR body to a temp file in the scratchpad. It lists Tasks 1-5, says Task 6's GUI pass is pending, links the spec and this plan, and ends with the session's PR attribution lines.
  - Run `gh api repos/sackheads/iris/pulls -f base=main -f head=feat/agency6-status-item -f title="feat: agency D6 PR A, attention and the status item" -F body=@<file>`.

### Task 6: GUI pass for PR A (`work`, under the lease)

Run on `work`'s laptop, on PR A's branch, before the PR merges. Post each numbered result on the PR.

1. Run `pgrep -fl "Iris Dev|\.build/debug/iris"`. Expected: no output. Quit anything it lists first, because two processes on one `~/.iris-dev` both run jobs.
2. Run `python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: D6 PR A status item" --minutes 45 --on-behalf-of <requesting peer>`. Expected: exit 0. On exit 1, message the holder it names, or rerun with `--wait 600`.
3. Run `scripts/build-app.sh Debug`, then `scripts/sign.sh "<the .app path it printed>"`, then `open "<that path>"`. Expected: the menu bar shows a hammer with no text beside it.
4. Click the hammer. Expected: no reason rows. "Show Chat", "Settings..." and "Quit" are listed.
5. Close the chat window with Cmd-W, then click the hammer and choose "Show Chat". Expected: the chat window reopens.
6. Open Diagnostics (the chat window's diagnostics button), then select a conversation other than Iris in the chat window. Press Cmd-Shift-Option-Space twice. Expected: the first press hides the chat window and the second brings back the same chat window, not Diagnostics.
7. In a normal conversation, ask: "Schedule a job named d6-slow every 10 minutes: write a 600-word story about a lighthouse, then reply done." Then type `/jobs run d6-slow`. Expected: within a few seconds the label reads hammer + `1`, and the menu shows "1 job running". When the card arrives, the label goes back to the hammer alone.
8. Ask: "Schedule a read-only job named d6-blocked every 10 minutes that uses write_file to write hi to /tmp/d6-blocked.txt." Then type `/jobs run d6-blocked`. Expected: after the card, the label reads hammer + `!1`, and the menu shows "d6-blocked blocked: write_file".
9. Click that row. Expected: the chat window comes forward on Iris, scrolled to d6-blocked's card.
10. Click the card's Dismiss. Expected: within a second, the label goes back to the hammer alone.
11. A plain failure. If the Sandbox settings tab shows a container runtime: ask "Schedule a mutating job named d6-fail every 10 minutes that replies ok", turn "Enable sandboxing" off, type `/jobs run d6-fail`, then turn sandboxing back on and type `/jobs delete d6-fail`. Expected: d6-fail's card says it failed (sandbox unavailable) and is retrying, the label is unchanged, and the menu gains "1 failed run". Without a runtime, record "skipped: no container runtime".
12. If the installed release Iris.app is already running, compare the two items. Expected: a sparkle for release and a hammer for dev. Do not launch the release app for this step. If it is not running, record "release not running".
13. Type `/jobs delete d6-slow` and `/jobs delete d6-blocked`, quit Iris Dev, and run `python3 ~/.claude/skills/gui-test-lease/lease.py release`. Expected: the lease is released.

---

## PR B: the Run Log window

Branch: `feat/agency6-run-log`, cut from `main` after PR A merges (plan note 14). Spec decision 15.

### Task 7: `JobLedger.runLog(...)`, paged by `(startedAt, rowid)`

**Files:**
- Modify: `Sources/IrisKit/JobLedger.swift`, in the runs extension after `recentRuns(limit:)` (`:560-575`). It must live in this file, because it decodes with the file-private `run(from:)`.
- Test: `Tests/irisTests/RunLogQueryTests.swift` (new)

**Interfaces:**
- Produces:
  - `JobLedger.RunLogCursor: Equatable, Sendable` with `startedAt: Date` and `rowid: Int64`.
  - `JobLedger.RunLogPage: Equatable, Sendable` with `runs: [JobRun]` and `next: RunLogCursor?`.
  - `JobLedger.runLog(limit: Int, before: RunLogCursor? = nil, jobId: UUID? = nil, status: JobRun.Status? = nil, includeGateUnchanged: Bool = false) throws -> RunLogPage`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/RunLogQueryTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 15: the run log reads every row the ledger holds, newest first, in pages that
/// neither drop nor repeat a row, gate checks hidden unless asked for.
@Suite("Run log query (D6)")
struct RunLogQueryTests {
    private func makeLedger() throws -> JobLedger { try ConversationStore.inMemory().ledger }

    private func job(_ name: String = "pr-sweep", action: JobAction = .prompt) -> Job {
        Job(name: name, prompt: "do it", trigger: .schedule(.interval(seconds: 60)), action: action)
    }

    @discardableResult
    private func row(_ job: Job, at startedAt: Date, status: JobRun.Status = .completed,
                     outcome: String? = "done", transcript: UUID? = UUID(),
                     ledger: JobLedger) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: startedAt,
                         transcriptConversationId: transcript)
        try ledger.begin(run: run)
        if status != .running {
            try ledger.finish(runId: run.id, status: status, outcome: outcome, failureReason: nil,
                              blockedTool: nil, tokens: TokenUsage(), finishedAt: startedAt)
        }
        return run
    }

    @Test("running rows, built-ins and stillborn rows are all in the log")
    func includesWhatRecentRunsHides() throws {
        let ledger = try makeLedger()
        let j = job(), digest = job("Daily digest", action: .builtin(DailyDigest.name))
        try ledger.upsert(j); try ledger.upsert(digest)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let running = try row(j, at: base, status: .running, ledger: ledger)
        let builtin = try row(digest, at: base.addingTimeInterval(1), transcript: nil, ledger: ledger)
        let stillborn = try row(j, at: base.addingTimeInterval(2), status: .interrupted,
                                outcome: nil, transcript: nil, ledger: ledger)

        let ids = try ledger.runLog(limit: 10).runs.map(\.id)
        #expect(Set(ids) == [running.id, builtin.id, stillborn.id])
        #expect(try ledger.recentRuns(limit: 10).isEmpty, "recentRuns hides all three, which is why the log has its own query")
    }

    @Test("gate-unchanged rows are hidden unless asked for, the catch-up variant included")
    func gateRowsToggle() throws {
        let ledger = try makeLedger()
        let j = job(); try ledger.upsert(j)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try row(j, at: base, outcome: JobRunner.gateUnchangedOutcome, transcript: nil, ledger: ledger)
        try row(j, at: base.addingTimeInterval(1),
                outcome: JobRunner.gateUnchangedOutcome + " (27 earlier occurrences skipped)", transcript: nil, ledger: ledger)
        let real = try row(j, at: base.addingTimeInterval(2), ledger: ledger)

        #expect(try ledger.runLog(limit: 10).runs.map(\.id) == [real.id])
        #expect(try ledger.runLog(limit: 10, includeGateUnchanged: true).runs.count == 3)
    }

    @Test("paging never drops or repeats rows that share a millisecond")
    func pagingNeverDropsOrRepeatsTiedRows() throws {
        let ledger = try makeLedger()
        let j = job(); try ledger.upsert(j)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var written: [UUID] = []
        written.append(try row(j, at: base, ledger: ledger).id)
        for _ in 0..<3 { written.append(try row(j, at: base.addingTimeInterval(5), ledger: ledger).id) }
        written.append(try row(j, at: base.addingTimeInterval(9), ledger: ledger).id)

        var seen: [UUID] = []
        var cursor: JobLedger.RunLogCursor?
        repeat {
            let page = try ledger.runLog(limit: 2, before: cursor)
            seen += page.runs.map(\.id)
            cursor = page.next
        } while cursor != nil

        #expect(seen.count == 5)
        #expect(Set(seen) == Set(written), "no row dropped")
        // Newest first; within the tied millisecond, the later insert first.
        #expect(seen == [written[4], written[3], written[2], written[1], written[0]])
    }

    @Test("the job and status filters narrow the log")
    func filters() throws {
        let ledger = try makeLedger()
        let a = job("a"), b = job("b")
        try ledger.upsert(a); try ledger.upsert(b)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let failed = try row(a, at: base, status: .failed, ledger: ledger)
        try row(a, at: base.addingTimeInterval(1), ledger: ledger)
        try row(b, at: base.addingTimeInterval(2), status: .failed, ledger: ledger)

        #expect(try ledger.runLog(limit: 10, jobId: a.id).runs.count == 2)
        #expect(try ledger.runLog(limit: 10, jobId: a.id, status: .failed).runs.map(\.id) == [failed.id])
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh RunLogQueryTests`. Expected: the build fails with "value of type 'JobLedger' has no member 'runLog'".

- [ ] **Step 3: Implement.** In `JobLedger.swift`, after `recentRuns(limit:)`:

```swift
    /// Where the next run-log page starts: the last row of the page before it (D6 decision 15).
    /// Both halves, because a catch-up burst writes several rows in one stored millisecond, and a
    /// cursor on `startedAt` alone would drop or repeat them at a page boundary.
    struct RunLogCursor: Equatable, Sendable {
        let startedAt: Date
        let rowid: Int64
    }

    struct RunLogPage: Equatable, Sendable {
        let runs: [JobRun]
        /// nil when this page reached the oldest matching row.
        let next: RunLogCursor?
    }

    /// The run log, newest first, with every kind of row: running rows, built-ins, and the
    /// stillborn skip and pause rows that `recentRuns` hides. Gate-unchanged completions are left
    /// out unless `includeGateUnchanged`, matched by prefix as `recentRuns` matches them.
    func runLog(limit: Int, before: RunLogCursor? = nil, jobId: UUID? = nil,
                status: JobRun.Status? = nil, includeGateUnchanged: Bool = false) throws -> RunLogPage {
        var conditions: [String] = []
        var arguments = StatementArguments()
        if let before {
            conditions.append("(startedAt < ? OR (startedAt = ? AND rowid < ?))")
            arguments += [before.startedAt, before.startedAt, before.rowid]
        }
        if let jobId {
            conditions.append("jobId = ?")
            arguments += [jobId.uuidString]
        }
        if let status {
            conditions.append("status = ?")
            arguments += [status.rawValue]
        }
        if !includeGateUnchanged {
            conditions.append("NOT (status = ? AND outcome IS NOT NULL AND outcome LIKE ?)")
            arguments += [JobRun.Status.completed.rawValue, JobRunner.gateUnchangedOutcome + "%"]
        }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        arguments += [limit + 1]
        let rows = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT rowid AS logRowid, * FROM job_runs \(filter)
                ORDER BY startedAt DESC, rowid DESC LIMIT ?
                """, arguments: arguments)
        }
        let kept = rows.prefix(limit)
        let runs = Self.decodeRuns(Array(kept))
        // The cursor comes from the raw row, not the decoded run: an unreadable last row must
        // still move the page on rather than end the log early.
        var next: RunLogCursor?
        if rows.count > limit, let last = kept.last,
           let startedAt = Date.fromDatabaseValue(last["startedAt"] as DatabaseValue),
           let rowid = Int64.fromDatabaseValue(last["logRowid"] as DatabaseValue) {
            next = RunLogCursor(startedAt: startedAt, rowid: rowid)
        }
        return RunLogPage(runs: runs, next: next)
    }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 4 tests passed. Quote the count.

- [ ] **Step 5: Mutation check.** Replace the cursor condition with `startedAt < ?` (with one argument): `pagingNeverDropsOrRepeatsTiedRows` fails. Restore it.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/JobLedger.swift Tests/irisTests/RunLogQueryTests.swift`, then `git commit -m "feat(jobs): a paged run-log query over every ledger row (D6 decision 15)"`.

### Task 8: `RunLogRow`, `RunLogModel` and the transcript opener

**Files:**
- Create: `Sources/IrisKit/RunLogModel.swift`
- Modify: `Sources/IrisKit/AppState.swift` (`openTranscript(_:)` and `transcriptExists(_:)`, beside Task 4's `revealCard`)
- Test: `Tests/irisTests/RunLogModelTests.swift` (new)

**Interfaces:**
- Consumes:
  - `JobLedger.runLog(...)`, `RunLogCursor` and `RunLogPage` (Task 7).
  - `AppState.acknowledgeRun(_:)` and `AppState.ledgerAttention` (Task 2).
  - `AppState.showMainWindow(selecting:)` (Task 4).
- Produces:
  - `struct RunLogRow: Identifiable, Equatable, Sendable` with `id`, `jobId`, `started`, `duration: TimeInterval?`, `jobName`, `triggerKind`, `status`, `weightedTokens`, `outcome: String?`, `canAcknowledge`, `opensCard` and `transcript: Transcript`. `Transcript` is `.none`, `.live(UUID)` or `.pruned`.
  - `static func make(_ run: JobRun, transcriptExists: (UUID) -> Bool) -> RunLogRow`.
  - `@MainActor @Observable final class RunLogModel` with `init(ledger:pageSize:transcriptExists:)`, `rows`, `hasMore`, `jobFilter: UUID?`, `statusFilter: JobRun.Status?` and `showGateChecks`. `reload()` and `loadMore()` each return `Task<Void, Never>` (`@discardableResult`).
  - `AppState.openTranscript(_ conversationId: UUID)` and `AppState.transcriptExists(_ conversationId: UUID) -> Bool`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/RunLogModelTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 15: a run log row says what the row says, offers Acknowledge exactly where a run
/// still waits on someone, links a blocked run to its card, and opens a live transcript in the
/// app's one sheet.
@MainActor
@Suite("Run log model (D6)", .timeLimit(.minutes(1)))
struct RunLogModelTests {
    private func run(_ status: JobRun.Status, acknowledged: Bool = false,
                     transcript: UUID? = nil, finishedAfter: TimeInterval? = 42) -> JobRun {
        var run = JobRun(jobId: UUID(), jobName: "pr-sweep", triggerKind: "url",
                         startedAt: Date(timeIntervalSince1970: 1_700_000_000), status: status,
                         transcriptConversationId: transcript)
        run.finishedAt = finishedAfter.map { run.startedAt.addingTimeInterval($0) }
        run.acknowledgedAt = acknowledged ? Date() : nil
        run.promptTokens = 100
        run.candidateTokens = 10
        run.totalTokens = 110
        return run
    }

    @Test("a row carries the columns, and Acknowledge only where a run still waits on someone")
    func rowColumns() {
        let live = UUID()
        let failed = RunLogRow.make(run(.failed, transcript: live), transcriptExists: { $0 == live })
        #expect(failed.duration == 42)
        #expect(failed.triggerKind == "url")
        #expect(failed.weightedTokens > 0)
        #expect(failed.canAcknowledge)
        #expect(failed.transcript == .live(live))
        #expect(!failed.opensCard)

        let blocked = RunLogRow.make(run(.blockedOnApproval), transcriptExists: { _ in false })
        #expect(blocked.canAcknowledge && blocked.opensCard, "a blocked row links to its card, never to an approval")

        #expect(!RunLogRow.make(run(.failed, acknowledged: true), transcriptExists: { _ in false }).canAcknowledge)
        #expect(!RunLogRow.make(run(.completed), transcriptExists: { _ in false }).canAcknowledge)
        #expect(RunLogRow.make(run(.running, finishedAfter: nil), transcriptExists: { _ in false }).duration == nil)
        #expect(RunLogRow.make(run(.completed, transcript: UUID()), transcriptExists: { _ in false }).transcript == .pruned)
        #expect(RunLogRow.make(run(.completed), transcriptExists: { _ in true }).transcript == .none)
    }

    private func seeded(_ count: Int) throws -> (ConversationStore, Job) {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        for i in 0..<count {
            let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
            try store.ledger.begin(run: run)
            try store.ledger.finish(runId: run.id, status: i == 0 ? .failed : .completed, outcome: "r\(i)",
                                    failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                    finishedAt: run.startedAt)
        }
        return (store, job)
    }

    @Test("reload replaces, loadMore appends, and a filter reloads from the top")
    func paging() async throws {
        let (store, _) = try seeded(5)
        let model = RunLogModel(ledger: store.ledger, pageSize: 2, transcriptExists: { _ in false })

        try await value(of: model.reload())
        #expect(model.rows.map(\.outcome) == ["r4", "r3"])
        #expect(model.hasMore)
        try await value(of: model.loadMore())
        try await value(of: model.loadMore())
        #expect(model.rows.map(\.outcome) == ["r4", "r3", "r2", "r1", "r0"])
        #expect(!model.hasMore)

        model.statusFilter = .failed
        try await value(of: model.reload())
        #expect(model.rows.map(\.outcome) == ["r0"])
    }

    @Test("Acknowledge stamps the row and clears the menu's failure count")
    func acknowledge() async throws {
        let (store, _) = try seeded(1)
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let model = RunLogModel(ledger: store.ledger, pageSize: 10, transcriptExists: { _ in false })
        try await value(of: model.reload())
        let row = try #require(model.rows.first)
        #expect(row.canAcknowledge)

        try await value(of: app.acknowledgeRun(row.id))
        try await value(of: model.reload())

        #expect(try store.ledger.run(id: row.id)?.acknowledgedAt != nil)
        #expect(model.rows.first?.canAcknowledge == false)
        #expect(app.ledgerAttention.failedCount == 0)
    }

    @Test("a live transcript opens in the main window's one sheet")
    func opensTranscript() throws {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        final class Raises { var count = 0 }
        let raises = Raises()
        app.raiseMainWindow = { raises.count += 1 }
        let transcript = app.createNewConversation(isBackground: true)

        #expect(app.transcriptExists(transcript))
        #expect(!app.transcriptExists(UUID()))
        app.openTranscript(transcript)

        #expect(app.transcriptSheetConversationId == transcript)
        #expect(raises.count == 1)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh RunLogModelTests`. Expected: the build fails with "cannot find 'RunLogRow' in scope".

- [ ] **Step 3: Implement.** Create `Sources/IrisKit/RunLogModel.swift`:

```swift
import Foundation
import Observation

/// One row of the Run Log window (D6 decision 15).
struct RunLogRow: Identifiable, Equatable, Sendable {
    enum Transcript: Equatable, Sendable {
        /// The run recorded no transcript: a built-in, a gate check, a stillborn row.
        case none
        case live(UUID)
        /// Recorded, and since removed by retention.
        case pruned
    }

    let id: UUID
    let jobId: UUID
    let started: Date
    /// nil while the run is still going.
    let duration: TimeInterval?
    let jobName: String
    let triggerKind: String
    let status: JobRun.Status
    let weightedTokens: Int
    /// Shown as plain text in the window, and never sent to a model or a notification: it is the
    /// run's own words, which no human read before they arrived.
    let outcome: String?
    /// An unacknowledged failure or blocked run: the one-click clear owner ruling 3 needs.
    let canAcknowledge: Bool
    /// A blocked run links to its card, where the call and its verdict are. No Approve here.
    let opensCard: Bool
    let transcript: Transcript

    static func make(_ run: JobRun, transcriptExists: (UUID) -> Bool) -> RunLogRow {
        let waits = run.status == .failed || run.status == .blockedOnApproval
        let transcript: Transcript
        if let id = run.transcriptConversationId {
            transcript = transcriptExists(id) ? .live(id) : .pruned
        } else {
            transcript = .none
        }
        return RunLogRow(
            id: run.id, jobId: run.jobId, started: run.startedAt,
            duration: run.finishedAt.map { $0.timeIntervalSince(run.startedAt) },
            jobName: run.jobName, triggerKind: run.triggerKind, status: run.status,
            weightedTokens: CostWeights.weighted(run.components, provider: run.provider, model: run.model),
            outcome: run.outcome, canAcknowledge: waits && run.acknowledgedAt == nil,
            opensCard: run.status == .blockedOnApproval, transcript: transcript)
    }
}

/// The Run Log window's rows, paged from the ledger off the main actor.
@MainActor
@Observable
final class RunLogModel {
    private(set) var rows: [RunLogRow] = []
    private(set) var hasMore = false
    var jobFilter: UUID?
    var statusFilter: JobRun.Status?
    var showGateChecks = false

    @ObservationIgnored private var next: JobLedger.RunLogCursor?
    @ObservationIgnored private let ledger: JobLedger
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let transcriptExists: @MainActor (UUID) -> Bool
    @ObservationIgnored private var generation = 0

    init(ledger: JobLedger, pageSize: Int = 100, transcriptExists: @escaping @MainActor (UUID) -> Bool) {
        self.ledger = ledger
        self.pageSize = pageSize
        self.transcriptExists = transcriptExists
    }

    @discardableResult
    func reload() -> Task<Void, Never> { load(after: nil) }

    @discardableResult
    func loadMore() -> Task<Void, Never> {
        guard let next else { return Task {} }
        return load(after: next)
    }

    private func load(after cursor: JobLedger.RunLogCursor?) -> Task<Void, Never> {
        generation += 1
        let generation = self.generation
        let ledger = self.ledger, limit = pageSize
        let (jobId, status, gate) = (jobFilter, statusFilter, showGateChecks)
        return Task { [weak self] in
            let page = await Task.detached {
                try? ledger.runLog(limit: limit, before: cursor, jobId: jobId, status: status,
                                   includeGateUnchanged: gate)
            }.value
            // A reload started since makes this page stale: its filters or its cursor are gone.
            guard let self, let page, generation == self.generation else { return }
            let made = page.runs.map { RunLogRow.make($0, transcriptExists: self.transcriptExists) }
            self.rows = cursor == nil ? made : self.rows + made
            self.next = page.next
            self.hasMore = page.next != nil
        }
    }
}
```

In `AppState.swift`, beside `revealCard`:

```swift
    /// The run log's transcript button (D6 decision 15): the app's one transcript sheet, on the
    /// main window, raised first so the sheet has a window to appear on.
    func openTranscript(_ conversationId: UUID) {
        showMainWindow(selecting: nil)
        transcriptSheetConversationId = conversationId
    }

    /// Whether a run's transcript conversation is still here, or retention has pruned it.
    func transcriptExists(_ conversationId: UUID) -> Bool {
        conversations.contains { $0.id == conversationId }
    }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 4 tests passed. Quote the count.

- [ ] **Step 5: Mutation check.** Drop `&& run.acknowledgedAt == nil` from `canAcknowledge`: `rowColumns` and `acknowledge` fail. Restore it.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/RunLogModel.swift Sources/IrisKit/AppState.swift Tests/irisTests/RunLogModelTests.swift`, then `git commit -m "feat(jobs): run log rows, paging model and transcript opener (D6 decision 15)"`.

### Task 9: The Run Log window, and the menu's way in

**Files:**
- Create: `Sources/IrisKit/RunLogView.swift`
- Modify: `Sources/IrisKit/iris.swift`, the scene list (`Window("Run Log", id: "run-log")` after the Diagnostics `Window`)
- Modify: `Sources/IrisKit/StatusItem.swift` (`StatusMenu`: "Open Run Log…", and the `.runLog` target)
- Modify: `Sources/IrisKit/SurfaceAttention.swift` (`StatusMenuRow.Target.runLog`, used by the failed-runs row)
- Test: `Tests/irisTests/SurfaceAttentionTests.swift` (`menuRows`)

**Interfaces:**
- Consumes: `RunLogModel` and `RunLogRow` (Task 8). `AppState.acknowledgeRun`, `revealCard`, `openTranscript` and `transcriptExists`.
- Produces: `RunLogView(state:)`, `StatusMenuRow.Target.runLog`, and the scene id `"run-log"`.

- [ ] **Step 1: Change the test.** In `SurfaceAttentionTests.menuRows`, add `#expect(rows[4].target == .runLog, "failed runs are cleared from the log, so that is where the row goes")`.

- [ ] **Step 2: Run it and watch it fail.** Run `timeout 300 scripts/test-filter.sh SurfaceAttentionTests`. Expected: the build fails with "type 'StatusMenuRow.Target' has no member 'runLog'".

- [ ] **Step 3: Implement.** In `SurfaceAttention.swift`, add `case runLog` to `StatusMenuRow.Target`, and give the failed-runs row `target: .runLog`.

In `StatusMenu.open(_:)`, add the case:

```swift
        case .runLog: openRunLog()
```

In `StatusMenu.body`, after "Show Chat", add:

```swift
        Button("Open Run Log…") { openRunLog() }
```

Then add the method:

```swift
    private func openRunLog() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "run-log")
    }
```

Create `Sources/IrisKit/RunLogView.swift`:

```swift
import SwiftUI

/// The Run Log window (D6 decision 15): every ledger row, newest first, with the transcript one
/// click away. Acknowledge is offered where a run still waits on someone. Approve is never
/// offered: the call and its verdict live on the card, which a blocked row links to.
struct RunLogView: View {
    let state: AppState
    @State private var model: RunLogModel
    @State private var jobs: [Job] = []

    private static let statuses: [JobRun.Status] = [.running, .completed, .failed, .blockedOnApproval, .interrupted]

    init(state: AppState) {
        self.state = state
        _model = State(initialValue: RunLogModel(ledger: state.store.ledger,
                                                 transcriptExists: { [weak state] in
                                                     state?.transcriptExists($0) ?? false
                                                 }))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Table(model.rows) {
                TableColumn("Started") { row in
                    Text(row.started, format: .dateTime.month().day().hour().minute().second())
                }
                TableColumn("Duration") { row in Text(verbatim: Self.durationText(row.duration)) }
                TableColumn("Job") { row in Text(verbatim: row.jobName) }
                TableColumn("Trigger") { row in Text(verbatim: row.triggerKind) }
                TableColumn("Status") { row in Text(verbatim: Self.statusText(row.status)) }
                TableColumn("Tokens") { row in Text(verbatim: "\(row.weightedTokens)") }
                TableColumn("Outcome") { row in
                    Text(verbatim: row.outcome ?? "").lineLimit(1).help(row.outcome ?? "")
                }
                TableColumn("") { row in actions(row) }
            }
            if model.hasMore {
                Button("Load more") { model.loadMore() }.padding(8)
            }
        }
        .frame(minWidth: 860, minHeight: 360)
        .onAppear {
            jobs = (try? state.store.ledger.jobs()) ?? []
            model.reload()
        }
        .onChange(of: state.ledgerAttention) { _, _ in model.reload() }
        // Plan note 15: a run that completes moves neither the snapshot nor anything else.
        .onChange(of: state.runningJobs.count) { _, _ in model.reload() }
        .onChange(of: model.jobFilter) { _, _ in model.reload() }
        .onChange(of: model.statusFilter) { _, _ in model.reload() }
        .onChange(of: model.showGateChecks) { _, _ in model.reload() }
    }

    private var controls: some View {
        HStack {
            Picker("Job", selection: $model.jobFilter) {
                Text("All jobs").tag(UUID?.none)
                ForEach(jobs) { job in Text(verbatim: job.name).tag(UUID?.some(job.id)) }
            }
            .frame(maxWidth: 240)
            Picker("Status", selection: $model.statusFilter) {
                Text("Any status").tag(JobRun.Status?.none)
                ForEach(Self.statuses, id: \.self) { status in
                    Text(verbatim: Self.statusText(status)).tag(JobRun.Status?.some(status))
                }
            }
            .frame(maxWidth: 220)
            Toggle("Show gate checks", isOn: $model.showGateChecks)
            Spacer()
            Button("Refresh") { model.reload() }
        }
        .padding(8)
    }

    @ViewBuilder
    private func actions(_ row: RunLogRow) -> some View {
        HStack(spacing: 6) {
            if row.canAcknowledge {
                Button("Acknowledge") { state.acknowledgeRun(row.id) }
            }
            if row.opensCard {
                Button("Show card") { state.revealCard(runId: row.id, jobId: row.jobId) }
            }
            switch row.transcript {
            case .live(let id): Button("Transcript") { state.openTranscript(id) }
            case .pruned: Text("transcript pruned").foregroundStyle(.secondary)
            case .none: EmptyView()
            }
        }
    }

    private static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "running" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        return "\(Int(seconds / 60)) min \(Int(seconds) % 60) s"
    }

    private static func statusText(_ status: JobRun.Status) -> String {
        status == .blockedOnApproval ? "blocked on approval" : status.rawValue
    }
}
```

In `iris.swift`'s scene list, after the Diagnostics `Window`:

```swift
        Window("Run Log", id: "run-log") {
            RunLogView(state: AppState.shared)
        }
```

- [ ] **Step 4: Build and test.**
  - Run `swift build`. Expected: it succeeds. `Job` is `Identifiable`, so `ForEach(jobs)` needs nothing more.
  - Run `timeout 300 scripts/test-filter.sh 'SurfaceAttentionTests|RunLogModelTests|RunLogQueryTests'`. Expected: every test passes. Quote the count.
  - Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 5: Commit.** `git add Sources/IrisKit/RunLogView.swift Sources/IrisKit/iris.swift Sources/IrisKit/StatusItem.swift Sources/IrisKit/SurfaceAttention.swift Tests/irisTests/SurfaceAttentionTests.swift`, then `git commit -m "feat(ui): the Run Log window, opened from the menu bar (D6 decision 15)"`.

### Task 10: Invariant 9 sweep, and open PR B

**Files:**
- Modify: `docs/jobs.md` (the `/jobs ack` row in "`/jobs`" at `:1061`, and "The run ledger" at `:729`)
- Modify: `README.md` (the feature list)

- [ ] **Step 1: Search, do not compose.** Run `grep -n -i "jobs ack\|acknowledg\|only way to\|run log\|recent runs" README.md docs/jobs.md Sources/IrisKit/JobsCommand.swift Sources/IrisKit/EventCard.swift Sources/IrisKit/iris.swift`, and read every hit.
  - `JobsCommandTests.swift:5-6` says `/jobs` "is the only way to acknowledge a failure or delete a job by hand". That is now false: the Run Log acknowledges too. Fix the doc comment to say "a way".
  - `JobsCommand.swift:1-6` says `/jobs` gives "a way to clear it that cannot itself fail", which stays true. Leave it.
  - Record what you found in the commit body.

- [ ] **Step 2: Fix and add.**
  - In the `docs/jobs.md` `/jobs ack` row, append "The Run Log window's Acknowledge does the same in one click."
  - At the end of "The run ledger", add:

```markdown
**The Run Log window** (the menu bar item, then **Open Run Log…**) shows every row, newest first,
running rows and built-ins included: started, duration, job, trigger kind, status, weighted tokens
and outcome. Gate checks that found nothing are hidden unless **Show gate checks** is on. A failed
or blocked run nobody has acknowledged offers **Acknowledge**, the one-click way to clear a plain
failure from the menu's count. A blocked run offers **Show card**, because the call and Vibecop's
verdict are on the card and the log never approves anything. A run whose transcript is still kept
opens it in the main window; one that retention has pruned says so.
```

  - In the README's feature list, after the menu bar bullet: `- **Run Log**: a window listing every background run, with its transcript one click away and Acknowledge for failures.`

- [ ] **Step 3: Full suite.** Run `timeout 900 swift test` (all three markers), then `scripts/check-warnings.sh`.

- [ ] **Step 4: Commit, push and open PR B.** Run `git commit -am "docs: the Run Log window (D6)"` and `git push -u origin feat/agency6-run-log`. Then run `gh api repos/sackheads/iris/pulls -f base=main -f head=feat/agency6-run-log -f title="feat: agency D6 PR B, the Run Log window" -F body=@<file>`. The body lists Tasks 7-10, says Task 11 is pending, and ends with the PR attribution lines.

### Task 11: GUI pass for PR B (`work`, under the lease)

1. Run `pgrep -fl "Iris Dev|\.build/debug/iris"`. Expected: no output.
2. Run `python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: D6 PR B run log" --minutes 30 --on-behalf-of <requesting peer>`. Expected: exit 0.
3. Build, sign and open Iris Dev.app as in Task 6 step 3.
4. Ask: "Schedule a job named d6-log every 10 minutes that replies pong." Type `/jobs run d6-log`, then repeat Task 6 step 8 to create and run `d6-blocked`.
5. Click the hammer, then "Open Run Log…". Expected: a window titled "Run Log" with columns Started, Duration, Job, Trigger, Status, Tokens and Outcome. The d6-log and d6-blocked rows are at the top, with trigger `manual`. No row shows an Approve button.
6. Click d6-log's "Transcript". Expected: the chat window comes forward with the read-only transcript sheet showing d6-log's run.
7. Click d6-blocked's "Show card". Expected: the chat window comes forward on Iris, scrolled to the card.
8. Click d6-blocked's "Acknowledge". Expected: the button disappears from the row, and the menu bar label goes back to the hammer alone.
9. Toggle "Show gate checks" on and off, and set the Job picker to d6-log. Expected: the rows narrow to d6-log's, and nothing errors.
10. Run `scripts/run-dev.sh` only after quitting Iris Dev. Expected: the bare binary launches with no crash. Its menu bar item works, "Open Run Log…" included. Quit it.
11. Type `/jobs delete d6-log` and `/jobs delete d6-blocked` (in either build), quit, and release the lease.

---

## PR C: notifications

Branch: `feat/agency6-notifications`, cut from `main` after PR A merges. It does not depend on B. Spec decisions 1 and 6-8.

### Task 12: `NotificationPolicy`, pure, with fixed titles and no approve action

**Files:**
- Create: `Sources/IrisKit/NotificationPolicy.swift`
- Test: `Tests/irisTests/NotificationPolicyTests.swift` (new)

**Interfaces:**
- Consumes: `LedgerAttention.ownerPauseReasons` (Task 2), `EventCard`, `IrisEngine.flattenCardField` and `IrisEngine.cardNameCap`.
- Produces:
  - `struct PlannedNotification: Equatable, Sendable` with `identifier`, `kind: Kind` (`.jobNeedsYou` or `.approvalWaiting`), `title`, `body`, `categoryId` and `userInfo: [String: String]`.
  - `struct NotificationContext: Equatable, Sendable` with `enabled`, `appActive`, `mainWindowVisible` and `selectedConversationId`, plus `static let off`.
  - `enum NotificationEvent: Sendable` with `.card(EventCard, destination: UUID, jobPausedReason: String?)` and `.ask(id: UUID, toolName: String, details: String, root: UUID?)`.
  - `enum NotificationPolicy` with `jobTitle` and `approvalTitle`, the namespaces `Category`, `Action` and `Key`, the types `ActionSpec` and `CategorySpec`, `categories`, `decide(_:context:) -> PlannedNotification?` and `quoted(_:) -> String`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/NotificationPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 1 and 6: which events notify, when a banner is pointless, and what a banner may
/// say. A banner is lock-screen text, so every model-, script- or page-written field stays out
/// of it, and no action on it can authorise anything.
@Suite("Notification policy (D6)")
struct NotificationPolicyTests {
    private let destination = UUID()
    private let on = NotificationContext(enabled: true, appActive: false, mainWindowVisible: false,
                                         selectedConversationId: nil)

    private func card(_ status: JobRun.Status, name: String = "pr-sweep", tool: String? = nil,
                      outcome: String? = nil, vibecopReason: String? = nil,
                      kind: String = "job_run") -> EventCard {
        EventCard(kind: kind, runId: UUID(), jobId: UUID(), jobName: name, status: status,
                  outcome: outcome, blockedTool: tool, startedAt: Date(), finishedAt: Date(),
                  vibecopReason: vibecopReason)
    }

    private func decide(_ card: EventCard, paused: String? = nil,
                        context: NotificationContext? = nil) -> PlannedNotification? {
        NotificationPolicy.decide(.card(card, destination: destination, jobPausedReason: paused),
                                  context: context ?? on)
    }

    private func ask(tool: String = "run_command", details: String = "make test",
                     context: NotificationContext? = nil) -> PlannedNotification? {
        NotificationPolicy.decide(.ask(id: UUID(), toolName: tool, details: details, root: destination),
                                  context: context ?? on)
    }

    @Test("a blocked card, a card whose job a limit paused, and a live ask notify")
    func notifies() throws {
        let blocked = try #require(decide(card(.blockedOnApproval, tool: "run_command")))
        #expect(blocked.title == "Iris: a job needs you")
        #expect(blocked.body == "Job “pr-sweep” is blocked on “run_command”.")
        #expect(blocked.categoryId == NotificationPolicy.Category.blockedCard)
        #expect(blocked.userInfo[NotificationPolicy.Key.conversationId] == destination.uuidString)

        for status in [JobRun.Status.failed, .interrupted] {
            let paused = try #require(decide(card(status), paused: JobRunner.breakerReason(count: 6)))
            #expect(paused.body == "Job “pr-sweep” is paused and waits for /jobs resume.")
            #expect(paused.categoryId == NotificationPolicy.Category.pausedCard)
        }

        let live = try #require(ask())
        #expect(live.title == "Iris: approval waiting")
        #expect(live.body == "“run_command” is waiting for your approval.")
        #expect(live.categoryId == NotificationPolicy.Category.ask)
    }

    @Test("completed, interrupted, retrying, reflection and digest cards are quiet")
    func quietCards() {
        #expect(decide(card(.completed)) == nil)
        #expect(decide(card(.interrupted)) == nil, "an interrupted run that paused nothing")
        #expect(decide(card(.failed)) == nil, "a failure still on its retry ladder")
        #expect(decide(card(.completed, kind: EventCard.reflectionKind)) == nil)
        #expect(decide(card(.blockedOnApproval, kind: EventCard.reflectionKind)) == nil)
        #expect(decide(card(.completed, name: DailyDigest.jobName)) == nil)
    }

    @Test("a completed card on a job that happens to be paused is quiet")
    func completedCardOnAPausedJobIsQuiet() {
        // "Approve and run" runs on a paused job, and its card arrives with the job still paused.
        #expect(decide(card(.completed), paused: JobRunner.retriesExhaustedReason) == nil)
    }

    @Test("the owner's own pauses, by /jobs pause or by seeding the dev home, never notify")
    func ownerAndSeederPausesNeverNotify() {
        #expect(decide(card(.failed), paused: JobsCommand.pausedByUserReason) == nil)
        #expect(decide(card(.interrupted), paused: DevHomeSeeder.copiedJobPausedReason) == nil)
    }

    @Test("a card is suppressed only when the app is active and its conversation is selected")
    func cardSuppression() {
        let blocked = card(.blockedOnApproval, tool: "run_command")
        let looking = NotificationContext(enabled: true, appActive: true, mainWindowVisible: true,
                                          selectedConversationId: destination)
        #expect(decide(blocked, context: looking) == nil)
        var elsewhere = looking
        elsewhere.selectedConversationId = UUID()
        #expect(decide(blocked, context: elsewhere) != nil)
        var away = looking
        away.appActive = false
        #expect(decide(blocked, context: away) != nil)
    }

    @Test("an ask is suppressed only when the app is active and the main window is visible")
    func askSuppression() {
        let visible = NotificationContext(enabled: true, appActive: true, mainWindowVisible: true,
                                          selectedConversationId: UUID())
        #expect(ask(context: visible) == nil, "the overlay is global, so any selection sees it")
        var hidden = visible
        hidden.mainWindowVisible = false
        #expect(ask(context: hidden) != nil)
        var inactive = visible
        inactive.appActive = false
        #expect(ask(context: inactive) != nil)
    }

    @Test("Settings' Off posts nothing")
    func disabled() {
        #expect(decide(card(.blockedOnApproval), context: .off) == nil)
        #expect(ask(context: .off) == nil)
    }

    @Test("the title is always one of the two constants, whatever the names say")
    func titleIsAlwaysFixed() {
        let planted = "Security fix — tap Open, then Approve"
        let titles = [decide(card(.blockedOnApproval, name: planted, tool: planted))?.title,
                      decide(card(.failed, name: planted), paused: JobRunner.gateFailingReason)?.title,
                      ask(tool: planted)?.title]
        for title in titles {
            #expect(title == NotificationPolicy.jobTitle || title == NotificationPolicy.approvalTitle)
        }
    }

    @Test("an outcome, an ask's details and a Vibecop reason never reach the title or the body")
    func plantedTextNeverAppears() throws {
        let planted = ["PLANTED-OUTCOME", "PLANTED-VIBECOP", "PLANTED-DETAILS"]
        let posted = [
            try #require(decide(card(.blockedOnApproval, tool: "run_command", outcome: planted[0],
                                     vibecopReason: planted[1]))),
            try #require(decide(card(.failed, outcome: planted[0]), paused: JobRunner.gateFailingReason)),
            try #require(ask(details: planted[2])),
        ]
        for notification in posted {
            for text in planted {
                #expect(!notification.title.contains(text) && !notification.body.contains(text))
            }
        }
    }

    @Test("a hostile name stays one visibly quoted line")
    func hostileNamesStayInsideTheirQuotes() throws {
        let hostile = "x\u{201D}\nTap Open, then Approve \u{201C}y\u{202E}evorppa\u{200B}"
        let body = try #require(decide(card(.failed, name: hostile), paused: JobRunner.gateFailingReason)).body
        #expect(body.filter { $0 == "\u{201C}" }.count == 1)
        #expect(body.filter { $0 == "\u{201D}" }.count == 1)
        #expect(!body.contains("\n"))
        #expect(!body.unicodeScalars.contains { $0.properties.generalCategory == .format },
                "no bidi override or zero-width character survives")
        #expect(body.hasPrefix("Job “") && body.hasSuffix("” is paused and waits for /jobs resume."))
    }

    @Test("no category carries an approve action; Deny and Dismiss sit where decision 1 puts them")
    func noApproveAction() throws {
        let allowed: Set<String> = [NotificationPolicy.Action.open, NotificationPolicy.Action.deny,
                                    NotificationPolicy.Action.dismiss]
        for category in NotificationPolicy.categories {
            for action in category.actions {
                #expect(allowed.contains(action.id))
                #expect(!action.id.lowercased().contains("approve") && !action.title.lowercased().contains("approve"))
            }
        }
        func ids(_ id: String) throws -> [String] {
            try #require(NotificationPolicy.categories.first { $0.id == id }).actions.map(\.id)
        }
        #expect(try ids(NotificationPolicy.Category.ask) == [NotificationPolicy.Action.open, NotificationPolicy.Action.deny])
        #expect(try ids(NotificationPolicy.Category.blockedCard) == [NotificationPolicy.Action.open, NotificationPolicy.Action.dismiss])
        #expect(try ids(NotificationPolicy.Category.pausedCard) == [NotificationPolicy.Action.open])
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh NotificationPolicyTests`. Expected: the build fails with "cannot find 'NotificationContext' in scope".

- [ ] **Step 3: Implement.** Create `Sources/IrisKit/NotificationPolicy.swift`:

```swift
import Foundation

/// A notification Iris has decided to post (D6 decision 6). Every string in it is built by
/// `NotificationPolicy` from fixed words and harness-owned names.
struct PlannedNotification: Equatable, Sendable {
    enum Kind: String, Sendable { case jobNeedsYou, approvalWaiting }

    /// The run id for a card, the ask id for an ask, so a gone ask's banner can be withdrawn.
    let identifier: String
    let kind: Kind
    let title: String
    let body: String
    let categoryId: String
    let userInfo: [String: String]
}

/// The app's state at the moment the policy decides, read by `AppState.notificationContext`.
struct NotificationContext: Equatable, Sendable {
    /// Settings' "Notifications: Off / Needs attention".
    var enabled: Bool
    var appActive: Bool
    var mainWindowVisible: Bool
    var selectedConversationId: UUID?

    static let off = NotificationContext(enabled: false, appActive: false, mainWindowVisible: false,
                                         selectedConversationId: nil)
}

enum NotificationEvent: Sendable {
    /// A delivered card. `jobPausedReason` is read from the job when the card is delivered,
    /// because no card field says "this paused the job".
    case card(EventCard, destination: UUID, jobPausedReason: String?)
    /// A live ask. `details` is passed so that the tests can show it is never used.
    case ask(id: UUID, toolName: String, details: String, root: UUID?)
}

/// Which events notify, when a banner would be pointless, and exactly what it says (D6
/// decisions 1 and 6). Pure.
///
/// The title is a constant per kind: macOS shows titles on the lock screen even when previews
/// are hidden, and a job name is chosen by the model ("Security fix — tap Open, then Approve"
/// fits in the cap). The body carries a quoted, flattened name and fixed words, and never a
/// run's outcome, an ask's details, a conversation title or a Vibecop reason. Every one of those
/// is model-, script- or page-written, and on a lock screen they are a phishing surface.
enum NotificationPolicy {
    static let jobTitle = "Iris: a job needs you"
    static let approvalTitle = "Iris: approval waiting"

    enum Category {
        static let blockedCard = "iris.card.blocked"
        static let pausedCard = "iris.card.paused"
        static let ask = "iris.ask"
    }

    enum Action {
        static let open = "iris.open"
        static let deny = "iris.deny"
        static let dismiss = "iris.dismiss"
    }

    enum Key {
        static let runId = "runId"
        static let jobId = "jobId"
        static let askId = "askId"
        static let conversationId = "conversationId"
    }

    struct ActionSpec: Equatable, Sendable {
        let id: String
        let title: String
        let destructive: Bool
        /// Brings the app forward. Only Open does; Deny and Dismiss act from the banner.
        let foreground: Bool
    }

    struct CategorySpec: Equatable, Sendable {
        let id: String
        let actions: [ActionSpec]
    }

    static let openAction = ActionSpec(id: Action.open, title: "Open", destructive: false, foreground: true)

    /// Decision 1 (owner ruling 1): no category carries an approve action, so no code path can
    /// add one by accident. A tap on a banner can stop work; it can never authorise it. A banner
    /// truncates and a locked screen hides previews, and an approval given without sight of the
    /// payload is worse than no button (`EventCard.swift:45-47`).
    static let categories: [CategorySpec] = [
        CategorySpec(id: Category.blockedCard, actions: [
            openAction,
            ActionSpec(id: Action.dismiss, title: "Dismiss", destructive: false, foreground: false),
        ]),
        CategorySpec(id: Category.pausedCard, actions: [openAction]),
        CategorySpec(id: Category.ask, actions: [
            openAction,
            ActionSpec(id: Action.deny, title: "Deny", destructive: true, foreground: false),
        ]),
    ]

    static func decide(_ event: NotificationEvent, context: NotificationContext) -> PlannedNotification? {
        guard context.enabled else { return nil }
        switch event {
        case .card(let card, let destination, let pausedReason):
            guard !card.isReflection else { return nil }
            // Already on screen: the card is in the conversation the owner is looking at.
            if context.appActive, context.selectedConversationId == destination { return nil }
            let info = [Key.runId: card.runId.uuidString, Key.jobId: card.jobId.uuidString,
                        Key.conversationId: destination.uuidString]
            if card.status == .blockedOnApproval {
                return PlannedNotification(
                    identifier: card.runId.uuidString, kind: .jobNeedsYou, title: jobTitle,
                    body: "Job \(quoted(card.jobName)) is blocked on \(quoted(card.blockedTool ?? "a tool")).",
                    categoryId: Category.blockedCard, userInfo: info)
            }
            // Plan note 5: only a card that ended badly on a job a limit has stopped. A completed
            // card on a paused job (an approved call), or a run of a job the owner paused, is not
            // a job waiting on anyone.
            guard card.status == .failed || card.status == .interrupted, let pausedReason,
                  !LedgerAttention.ownerPauseReasons.contains(pausedReason) else { return nil }
            return PlannedNotification(
                identifier: card.runId.uuidString, kind: .jobNeedsYou, title: jobTitle,
                body: "Job \(quoted(card.jobName)) is paused and waits for /jobs resume.",
                categoryId: Category.pausedCard, userInfo: info)

        case .ask(let id, let toolName, _, let root):
            // The overlay is global: any visible main window is already showing it.
            if context.appActive, context.mainWindowVisible { return nil }
            var info = [Key.askId: id.uuidString]
            if let root { info[Key.conversationId] = root.uuidString }
            return PlannedNotification(
                identifier: id.uuidString, kind: .approvalWaiting, title: approvalTitle,
                body: "\(quoted(toolName)) is waiting for your approval.",
                categoryId: Category.ask, userInfo: info)
        }
    }

    /// A name as a banner may show it: flattened and capped as the briefing does, with every
    /// character a reader could not see removed (controls, bidi overrides, zero-width spaces,
    /// line and paragraph separators, the set #334's `containsHiddenCharacters` names). Curly
    /// quotes are turned into straight ones, so the name cannot close its own quotation marks.
    static func quoted(_ field: String) -> String {
        let flat = IrisEngine.flattenCardField(field, cap: IrisEngine.cardNameCap)
        var scalars = flat.unicodeScalars
        scalars.removeAll { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
        let visible = String(scalars)
            .replacingOccurrences(of: "\u{201C}", with: "'")
            .replacingOccurrences(of: "\u{201D}", with: "'")
        return "\u{201C}\(visible)\u{201D}"
    }
}
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 11 tests passed. Quote the count.

- [ ] **Step 5: Mutation checks (the security rules).** Make each change, run the filter, see the named test fail, then restore.
  - Use `card.jobName` as the card title: `titleIsAlwaysFixed` fails.
  - Append ` \(card.outcome ?? "")` to the blocked body: `plantedTextNeverAppears` fails.
  - Add `ActionSpec(id: "iris.approve", title: "Approve", destructive: false, foreground: false)` to the ask category: `noApproveAction` fails.
  - Delete `.format` from `quoted`'s removal set: `hostileNamesStayInsideTheirQuotes` fails.
  - Delete `!LedgerAttention.ownerPauseReasons.contains(pausedReason)`: `ownerAndSeederPausesNeverNotify` fails.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/NotificationPolicy.swift Tests/irisTests/NotificationPolicyTests.swift`, then `git commit -m "feat(notify): a pure notification policy with fixed titles and no approve action (D6 decisions 1, 6)"`.

### Task 13: The sink seam, the two places the policy is asked, and the responses

**Files:**
- Create: `Sources/IrisKit/NotificationSink.swift`
- Modify: `Sources/IrisKit/AppState.swift:377` (`pendingApprovals` gains a `didSet`; `notificationSink` and `notificationContext` are added beside it)
- Modify: `Sources/IrisKit/EventDelivery.swift` (`notifyForCard` after the `.event` append)
- Test: `Tests/irisTests/NotificationWiringTests.swift` (new)

**Interfaces:**
- Consumes:
  - `NotificationPolicy`, `PlannedNotification`, `NotificationContext` and `NotificationEvent` (Task 12).
  - `AppState.showMainWindow(selecting:)` and `revealCard(runId:jobId:)` (Task 4). `AppState.acknowledgeRun(_:)` (Task 2).
- Produces:
  - `@MainActor protocol NotificationSink: AnyObject` with `post(_:)` and `withdraw(identifiers:)`.
  - `struct NotificationResponse: Equatable, Sendable` with `actionId` and `userInfo`.
  - `AppState.notificationSink: (any NotificationSink)?` and `AppState.notificationContext: @MainActor () -> NotificationContext`.
  - `AppState.notifyForCard(_:destination:)` and `AppState.approvalsChanged(from:)`.
  - `AppState.handleNotificationResponse(_:) -> Task<Void, Never>?` (`@discardableResult`).

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/NotificationWiringTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 7 and 8: the policy is asked in exactly two places, every way an ask can leave
/// the queue withdraws its banner, and a response can open, deny or dismiss, never approve.
@MainActor
@Suite("Notification wiring (D6)", .timeLimit(.minutes(1)))
struct NotificationWiringTests {
    @MainActor
    final class FakeSink: NotificationSink {
        var posted: [PlannedNotification] = []
        var withdrawn: [String] = []
        func post(_ notification: PlannedNotification) { posted.append(notification) }
        func withdraw(identifiers: [String]) { withdrawn += identifiers }
    }

    private final class Raises { var count = 0 }

    private static let away = NotificationContext(enabled: true, appActive: false, mainWindowVisible: false,
                                                  selectedConversationId: nil)

    private func makeApp() throws -> (ConversationStore, AppState, FakeSink, Raises) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let sink = FakeSink(), raises = Raises()
        app.notificationSink = sink
        app.notificationContext = { Self.away }
        app.raiseMainWindow = { raises.count += 1 }
        return (store, app, sink, raises)
    }

    private func raise(_ app: AppState, in conversation: UUID, details: String = "make test") async -> Task<Bool, Never> {
        let before = app.pendingApprovals.count
        let task = Task { @MainActor in
            await app.enqueueUserApproval(toolName: "run_command", details: details, workspace: nil,
                                          conversationId: conversation, origin: "test")
        }
        var spins = 0
        while app.pendingApprovals.count == before, spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(app.pendingApprovals.count == before + 1, "the ask must be queued before the test goes on")
        return task
    }

    private func respond(_ app: AppState, _ action: String, _ info: [String: String]) -> Task<Void, Never>? {
        app.handleNotificationResponse(NotificationResponse(actionId: action, userInfo: info))
    }

    @Test("an AppState, and the --run-job state, have no sink")
    func noSinkByDefault() throws {
        let store = try ConversationStore.inMemory()
        #expect(AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
            .notificationSink == nil)
        #expect(RunJobCLI.makeState(store: try ConversationStore.inMemory()).notificationSink == nil)
    }

    @Test("one post per notifying card, none for a quiet one")
    func onePostPerNotifyingCard() async throws {
        let (store, app, sink, _) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let iris = app.activityConversationId()
        await app.deliverEvent(EventCard(runId: UUID(), jobId: job.id, jobName: job.name, status: .blockedOnApproval,
                                         blockedTool: "run_command", startedAt: Date(), finishedAt: Date()), to: iris)
        await app.deliverEvent(EventCard(runId: UUID(), jobId: job.id, jobName: job.name, status: .completed,
                                         startedAt: Date(), finishedAt: Date()), to: iris)
        #expect(sink.posted.map(\.kind) == [.jobNeedsYou])
    }

    @Test("a card's job is read when the card is delivered, to see that a limit paused it")
    func pausedCardReadsTheJob() async throws {
        let (store, app, sink, _) = try makeApp()
        let job = Job(name: "thrasher", prompt: "do it", trigger: .schedule(.interval(seconds: 60)),
                      pausedReason: JobRunner.breakerReason(count: 6))
        try store.ledger.upsert(job)
        await app.deliverEvent(EventCard(runId: UUID(), jobId: job.id, jobName: job.name, status: .interrupted,
                                         outcome: JobRunner.breakerReason(count: 6), startedAt: Date(),
                                         finishedAt: Date()), to: app.activityConversationId())
        #expect(sink.posted.map(\.categoryId) == [NotificationPolicy.Category.pausedCard])
    }

    @Test("an ask posts once, and each of the four ways out withdraws it")
    func eachRemovalWithdraws() async throws {
        let (_, app, sink, _) = try makeApp()
        let conversation = app.createNewConversation()

        let approved = await raise(app, in: conversation)
        let first = app.pendingApprovals[0].id
        #expect(sink.posted.map(\.identifier) == [first.uuidString])
        app.resolveApproval(id: first, .approve)
        #expect(try await value(of: approved) == true)

        let denied = await raise(app, in: conversation)
        let second = app.pendingApprovals[0].id
        app.resolveApproval(id: second, .deny)
        _ = try await value(of: denied)

        let stopped = await raise(app, in: conversation)
        let third = app.pendingApprovals[0].id
        app.denyPendingApprovals(for: conversation)
        _ = try await value(of: stopped)

        let cancelled = await raise(app, in: conversation)
        let fourth = app.pendingApprovals[0].id
        cancelled.cancel()
        #expect(try await value(of: cancelled) == false)

        #expect(sink.withdrawn == [first, second, third, fourth].map(\.uuidString))
        #expect(sink.posted.count == 4)
    }

    @Test("Deny from a banner denies the ask")
    func denyResponseDenies() async throws {
        let (_, app, _, _) = try makeApp()
        let ask = await raise(app, in: app.createNewConversation())
        _ = respond(app, NotificationPolicy.Action.deny, [NotificationPolicy.Key.askId: app.pendingApprovals[0].id.uuidString])
        #expect(try await value(of: ask) == false)
        #expect(app.pendingApprovals.isEmpty)
    }

    @Test("a response for an ask or run that has gone is a no-op")
    func staleResponsesAreNoOps() async throws {
        let (_, app, _, _) = try makeApp()
        let ask = await raise(app, in: app.createNewConversation())
        _ = respond(app, NotificationPolicy.Action.deny, [NotificationPolicy.Key.askId: UUID().uuidString])
        if let dismissed = respond(app, NotificationPolicy.Action.dismiss, [NotificationPolicy.Key.runId: UUID().uuidString]) {
            try await value(of: dismissed)
        }
        #expect(app.pendingApprovals.count == 1, "someone else's ask is untouched")
        app.resolveApproval(id: app.pendingApprovals[0].id, .deny)
        _ = try await value(of: ask)
    }

    @Test("no response, of any name, approves")
    func unknownActionNeverApproves() async throws {
        let (_, app, _, _) = try makeApp()
        let ask = await raise(app, in: app.createNewConversation())
        let id = app.pendingApprovals[0].id.uuidString
        for action in ["approve", "iris.approve", "com.apple.UNNotificationDismissActionIdentifier", ""] {
            _ = respond(app, action, [NotificationPolicy.Key.askId: id])
        }
        #expect(app.pendingApprovals.count == 1, "the ask is still waiting for a person")
        app.resolveApproval(id: app.pendingApprovals[0].id, .deny)
        #expect(try await value(of: ask) == false)
    }

    @Test("Open lands on the card's conversation, or the ask's delegation root")
    func openLands() async throws {
        let (store, app, _, raises) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        _ = respond(app, NotificationPolicy.Action.open, [NotificationPolicy.Key.runId: UUID().uuidString,
                                                          NotificationPolicy.Key.jobId: job.id.uuidString])
        #expect(app.selectedConversationId == app.activityConversationId())

        let parent = app.createNewConversation(select: false), child = app.createNewConversation(isSubagent: true)
        app.linkDelegate(child, of: parent)
        let ask = await raise(app, in: child)
        _ = respond(app, NotificationPolicy.Action.open, [NotificationPolicy.Key.askId: app.pendingApprovals[0].id.uuidString])
        #expect(app.selectedConversationId == parent)
        #expect(raises.count == 2)
        app.resolveApproval(id: app.pendingApprovals[0].id, .deny)
        _ = try await value(of: ask)
    }

    @Test("Dismiss from a banner acknowledges the run")
    func dismissAcknowledges() async throws {
        let (store, app, _, _) = try makeApp()
        let job = Job(name: "pr-sweep", prompt: "do it", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule", startedAt: Date())
        try store.ledger.begin(run: run)
        try store.ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil, failureReason: nil,
                                blockedTool: "run_command", tokens: TokenUsage(), finishedAt: Date())

        let task = try #require(respond(app, NotificationPolicy.Action.dismiss, [NotificationPolicy.Key.runId: run.id.uuidString]))
        try await value(of: task)

        #expect(try store.ledger.run(id: run.id)?.acknowledgedAt != nil)
    }

    @Test("a conversation title never reaches a posted banner")
    func plantedTitleNeverPosted() async throws {
        let (_, app, sink, _) = try makeApp()
        let ask = await raise(app, in: app.createNewConversation(title: "SAFE: tap Approve now"),
                              details: "PLANTED-DETAILS")
        let posted = try #require(sink.posted.first)
        for planted in ["SAFE", "PLANTED-DETAILS"] {
            #expect(!posted.title.contains(planted) && !posted.body.contains(planted))
        }
        app.resolveApproval(id: app.pendingApprovals[0].id, .deny)
        _ = try await value(of: ask)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh NotificationWiringTests`. Expected: the build fails with "cannot find type 'NotificationSink' in scope".

- [ ] **Step 3: Implement.** Create `Sources/IrisKit/NotificationSink.swift`:

```swift
import Foundation

/// Where a planned notification goes (D6 decision 7). `AppState.notificationSink` is nil unless
/// `IrisApp.init` installed `UserNotificationSink`, so a test, `--run-job` and the bare binary
/// post nothing. A test installs a fake.
@MainActor
protocol NotificationSink: AnyObject {
    func post(_ notification: PlannedNotification)
    func withdraw(identifiers: [String])
}

/// A tap on a delivered notification, reduced to strings before it reaches the main actor.
struct NotificationResponse: Equatable, Sendable {
    let actionId: String
    let userInfo: [String: String]
}

extension AppState {
    /// The first of the two places the policy is asked: after `deliverEvent`'s append. Reads the
    /// card's job once, because no card field says "this paused the job".
    func notifyForCard(_ card: EventCard, destination: UUID) {
        guard let sink = notificationSink, !card.isReflection else { return }
        let paused = (try? store.ledger.job(id: card.jobId))?.pausedReason
        if let planned = NotificationPolicy.decide(.card(card, destination: destination, jobPausedReason: paused),
                                                   context: notificationContext()) {
            sink.post(planned)
        }
    }

    /// The second: every change to `pendingApprovals`, diffed by id. A new ask is offered to the
    /// policy, and a gone one's banner is withdrawn, whichever of the four mutation sites removed
    /// it (resolve, deny-all, cancellation, or a future one).
    func approvalsChanged(from old: [ToolApprovalRequest]) {
        guard let sink = notificationSink else { return }
        let now = Set(pendingApprovals.map(\.id)), before = Set(old.map(\.id))
        let removed = old.filter { !now.contains($0.id) }.map(\.id.uuidString)
        if !removed.isEmpty { sink.withdraw(identifiers: removed) }
        let added = pendingApprovals.filter { !before.contains($0.id) }
        guard !added.isEmpty else { return }
        let context = notificationContext()
        for request in added {
            let event = NotificationEvent.ask(id: request.id, toolName: request.toolName, details: request.details,
                                              root: request.conversationId.map(delegationRoot(of:)))
            if let planned = NotificationPolicy.decide(event, context: context) { sink.post(planned) }
        }
    }

    /// Open, Deny and Dismiss (decision 7), and nothing else. An id that is gone is a no-op, and
    /// acknowledging a run twice is harmless. Returns the acknowledgement for a Dismiss, so a
    /// test can await it.
    @discardableResult
    func handleNotificationResponse(_ response: NotificationResponse) -> Task<Void, Never>? {
        let info = response.userInfo
        let runId = info[NotificationPolicy.Key.runId].flatMap(UUID.init(uuidString:))
        let jobId = info[NotificationPolicy.Key.jobId].flatMap(UUID.init(uuidString:))
        let askId = info[NotificationPolicy.Key.askId].flatMap(UUID.init(uuidString:))
        switch response.actionId {
        case NotificationPolicy.Action.open:
            if let runId, let jobId {
                revealCard(runId: runId, jobId: jobId)
            } else if let askId {
                let owner = pendingApprovals.first { $0.id == askId }?.conversationId
                    ?? info[NotificationPolicy.Key.conversationId].flatMap(UUID.init(uuidString:))
                showMainWindow(selecting: owner.map(delegationRoot(of:)))
            } else {
                showMainWindow(selecting: nil)
            }
            return nil
        case NotificationPolicy.Action.deny:
            if let askId { resolveApproval(id: askId, .deny) }
            return nil
        case NotificationPolicy.Action.dismiss:
            guard let runId else { return nil }
            return acknowledgeRun(runId)
        default:
            // Decision 1: there is no approve action, and no name, however spelled, becomes one.
            return nil
        }
    }
}
```

In `AppState.swift`, replace `var pendingApprovals: [ToolApprovalRequest] = []` (`:377`) with:

```swift
    var pendingApprovals: [ToolApprovalRequest] = [] {
        // D6 decision 7: every mutation passes through here, so a new ask meets the notification
        // policy and a gone one's banner is withdrawn without any site having to remember to.
        didSet { approvalsChanged(from: oldValue) }
    }
    /// Where notifications go: nil unless `IrisApp.init` installed one in a real `.app` bundle
    /// (D6 decision 8). Never set by `init`, which every test runs.
    @ObservationIgnored var notificationSink: (any NotificationSink)?
    /// The app's state when the policy decides. `.off` until `SurfaceInstall` replaces it, so a
    /// sink installed with no context still posts nothing.
    @ObservationIgnored var notificationContext: @MainActor () -> NotificationContext = { .off }
```

In `EventDelivery.swift`, directly after `appendMessage(role: .event, content: card.encodedContent(), to: destinationId)`:

```swift
        notifyForCard(card, destination: destinationId)
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 10 tests passed. Quote the count.

- [ ] **Step 5: Mutation checks (the security rules).** Make each change, run the filter, see the named test fail, then restore.
  - In `handleNotificationResponse`'s `default:`, add `if let askId { resolveApproval(id: askId, .approve) }`: `unknownActionNeverApproves` fails.
  - Delete the `didSet`: `eachRemovalWithdraws` fails.
  - Delete `notifyForCard` from `deliverEvent`: `onePostPerNotifyingCard` fails.

- [ ] **Step 6: Run the neighbours and the warnings check.**
  - Run `timeout 300 scripts/test-filter.sh 'SessionStatusTests|ApprovalQueueTests|EventDeliveryTests|RunJobCLITests'`. If `ApprovalQueueTests` matches no type, drop it from the filter. The script fails on a filter that matches nothing, so check its count. Expected: every test passes. Quote the count.
  - Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/NotificationSink.swift Sources/IrisKit/AppState.swift Sources/IrisKit/EventDelivery.swift Tests/irisTests/NotificationWiringTests.swift`, then `git commit -m "feat(notify): the sink seam, the two policy call sites, and Open/Deny/Dismiss (D6 decision 7)"`.

### Task 14: Permission, `UserNotificationSink`, the bundle guard and the Settings row

**Files:**
- Create: `Sources/IrisKit/NotificationPermission.swift`
- Create: `Sources/IrisKit/UserNotificationSink.swift`, the only file that imports `UserNotifications`
- Create: `Sources/IrisKit/SurfaceInstall.swift`
- Modify: `Sources/IrisKit/ConfigManager.swift` (`NotificationMode` and `notificationMode`, beside `checkpointAutoAdvance`: the property at `:72`, its load at `:399-403`)
- Modify: `Sources/IrisKit/SettingsView.swift:198-212` (the Preferences section)
- Modify: `Sources/IrisKit/iris.swift`, the `MainActor.assumeIsolated` block in `IrisApp.init` (install, after the guard sink)
- Test: `Tests/irisTests/NotificationInstallTests.swift` (new)

**Interfaces:**
- Consumes: `NotificationSink`, `NotificationResponse` and `AppState.handleNotificationResponse` (Task 13). `NotificationPolicy.categories` (Task 12). `MainWindow.isVisible` (Task 4).
- Produces:
  - `@MainActor final class NotificationPermission` with `Status` (`.notDetermined`, `.authorized` or `.denied`), `init(current:request:deliver:)`, `submit(_:) async` and `withdraw(identifiers:)`.
  - `UserNotificationSink(state:)`.
  - `SurfaceInstall.isAppBundle(_:)` and `SurfaceInstall.installNotifications(on:bundleURL:config:)`.
  - `enum NotificationMode: String, CaseIterable, Sendable { case off, needsAttention }` and `ConfigManager.notificationMode`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/NotificationInstallTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 7 and 8: permission is asked once, at the first post, and "denied" is a normal
/// answer; only a real `.app` bundle installs a sink; one file touches `UserNotifications`.
@MainActor
@Suite("Notification install (D6)", .timeLimit(.minutes(1)))
struct NotificationInstallTests {
    private final class Calls {
        var status: NotificationPermission.Status = .notDetermined
        var requests = 0
        var grant = true
        var delivered: [String] = []
        var held: CheckedContinuation<Void, Never>?
        var holdRequest = false
    }

    private func gate(_ calls: Calls) -> NotificationPermission {
        NotificationPermission(
            current: { calls.status },
            request: {
                calls.requests += 1
                if calls.holdRequest { await withCheckedContinuation { calls.held = $0 } }
                calls.status = calls.grant ? .authorized : .denied
                return calls.grant
            },
            deliver: { calls.delivered.append($0.identifier) })
    }

    private func note(_ id: String) -> PlannedNotification {
        PlannedNotification(identifier: id, kind: .jobNeedsYou, title: NotificationPolicy.jobTitle,
                            body: "Job “x” is blocked on “y”.", categoryId: NotificationPolicy.Category.blockedCard,
                            userInfo: [:])
    }

    @Test("the first post asks, once; later posts are delivered without asking")
    func asksOnce() async {
        let calls = Calls(), permission = gate(calls)
        await permission.submit(note("a"))
        await permission.submit(note("b"))
        #expect(calls.requests == 1)
        #expect(calls.delivered == ["a", "b"])
    }

    @Test("denied, by the user or by MDM, posts nothing and never asks again")
    func deniedNeverAsksAgain() async {
        let calls = Calls(), permission = gate(calls)
        calls.grant = false
        for id in ["a", "b", "c"] { await permission.submit(note(id)) }
        #expect(calls.requests == 1)
        #expect(calls.delivered.isEmpty)

        calls.status = .authorized   // the owner turned it on in System Settings
        await permission.submit(note("d"))
        #expect(calls.delivered == ["d"])
        #expect(calls.requests == 1)
    }

    @Test("a post that arrives while the prompt is up is held, and withdrawn if its ask goes")
    func heldWhileAsking() async throws {
        let calls = Calls(), permission = gate(calls)
        calls.holdRequest = true
        let first = Task { @MainActor in await permission.submit(note("a")) }
        var spins = 0
        while calls.held == nil, spins < 10_000 { await Task.yield(); spins += 1 }
        await permission.submit(note("b"))
        await permission.submit(note("c"))
        permission.withdraw(identifiers: ["c"])
        calls.held?.resume()
        try await value(of: first)
        #expect(calls.requests == 1)
        #expect(calls.delivered == ["a", "b"])
    }

    @Test("only a real .app bundle gets a sink")
    func bundleGuard() {
        #expect(SurfaceInstall.isAppBundle(URL(fileURLWithPath: "/Applications/Iris Dev.app")))
        #expect(!SurfaceInstall.isAppBundle(URL(fileURLWithPath: "/Users/me/src/iris/.build/debug")))
        #expect(!SurfaceInstall.isAppBundle(URL(fileURLWithPath: "/usr/bin")))
        #expect(!SurfaceInstall.isAppBundle(Bundle.main.bundleURL), "a test runner is not an app")
    }

    @Test("installing outside a bundle leaves no sink and touches no notification API")
    func installOutsideABundle() throws {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        SurfaceInstall.installNotifications(on: app, bundleURL: URL(fileURLWithPath: "/usr/bin"))
        #expect(app.notificationSink == nil)
    }

    @Test("UserNotificationSink.swift is the only file that imports UserNotifications")
    func oneImporter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        let importers = try files.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("import UserNotifications")
        }.map(\.lastPathComponent)
        #expect(importers == ["UserNotificationSink.swift"])
    }

    @Test("the setting defaults to Needs attention and persists")
    func setting() {
        let name = "iris-notify-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)
        #expect(config.notificationMode == .needsAttention)
        config.notificationMode = .off
        #expect(ConfigManager(store: store).notificationMode == .off)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh NotificationInstallTests`. Expected: the build fails with "cannot find 'NotificationPermission' in scope".

- [ ] **Step 3: Implement.** Create `Sources/IrisKit/NotificationPermission.swift`:

```swift
import Foundation

/// When Iris may post (D6 decision 7). Permission is asked the first time a notification would be
/// posted, never at launch, and at most once per process. "Denied", by the user or by MDM, is a
/// normal answer: nothing is posted, nothing is retried, and nobody is asked again. A later
/// "authorized" (the owner changed System Settings) is honoured at the next post. Pure apart from
/// its three closures, so the whole ladder is testable without `UNUserNotificationCenter`.
@MainActor
final class NotificationPermission {
    enum Status: Sendable { case notDetermined, authorized, denied }

    private let current: @MainActor () async -> Status
    private let request: @MainActor () async -> Bool
    private let deliver: @MainActor (PlannedNotification) -> Void
    private var asked = false
    private var asking = false
    private var held: [PlannedNotification] = []

    init(current: @escaping @MainActor () async -> Status,
         request: @escaping @MainActor () async -> Bool,
         deliver: @escaping @MainActor (PlannedNotification) -> Void) {
        self.current = current
        self.request = request
        self.deliver = deliver
    }

    func submit(_ notification: PlannedNotification) async {
        if asking { held.append(notification); return }
        let status = await current()
        // Re-checked after the await: another post may have started the prompt meanwhile.
        if asking { held.append(notification); return }
        switch status {
        case .authorized:
            deliver(notification)
        case .denied:
            return
        case .notDetermined:
            guard !asked else { return }
            asked = true
            asking = true
            held.append(notification)
            let granted = await request()
            asking = false
            let waiting = held
            held = []
            if granted { waiting.forEach(deliver) }
        }
    }

    /// An ask that went while the prompt was up must not be posted afterwards.
    func withdraw(identifiers: [String]) {
        held.removeAll { identifiers.contains($0.identifier) }
    }
}
```

Create `Sources/IrisKit/UserNotificationSink.swift`:

```swift
import Foundation
import UserNotifications

/// The one file that touches `UserNotifications` (D6 decisions 7 and 8). Built only by
/// `SurfaceInstall.installNotifications`, after the `.app` bundle check:
/// `UNUserNotificationCenter.current()` raises in a process without one. It sets itself as the
/// center's delegate in `init`, which runs in `IrisApp.init`, before `NSApplication` finishes
/// launching, so a click that cold-launches the app is still delivered.
@MainActor
final class UserNotificationSink: NSObject, NotificationSink, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private weak var state: AppState?
    private var permission: NotificationPermission?

    init(state: AppState) {
        self.center = UNUserNotificationCenter.current()
        self.state = state
        super.init()
        let center = self.center
        permission = NotificationPermission(
            current: { await Self.status(of: center) },
            request: { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false },
            deliver: { [weak self] in self?.deliver($0) })
        center.setNotificationCategories(Self.categories())
        center.delegate = self
    }

    func post(_ notification: PlannedNotification) {
        guard let permission else { return }
        Task { await permission.submit(notification) }
    }

    func withdraw(identifiers: [String]) {
        permission?.withdraw(identifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func deliver(_ planned: PlannedNotification) {
        let request = UNNotificationRequest(identifier: planned.identifier,
                                            content: Self.content(for: planned), trigger: nil)
        center.add(request) { error in
            if let error { print("[Notifications] could not post \(planned.identifier): \(error)") }
        }
    }

    static func content(for planned: PlannedNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = planned.title
        content.body = planned.body
        content.categoryIdentifier = planned.categoryId
        content.userInfo = planned.userInfo
        // `.timeSensitive` needs an entitlement this app does not have (decision 7).
        content.interruptionLevel = .active
        return content
    }

    /// `NotificationPolicy.categories`, with no custom dismiss action: swiping a banner away
    /// acknowledges nothing.
    static func categories() -> Set<UNNotificationCategory> {
        Set(NotificationPolicy.categories.map { spec in
            UNNotificationCategory(identifier: spec.id, actions: spec.actions.map { action in
                var options: UNNotificationActionOptions = []
                if action.destructive { options.insert(.destructive) }
                if action.foreground { options.insert(.foreground) }
                return UNNotificationAction(identifier: action.id, title: action.title, options: options)
            }, intentIdentifiers: [], options: [])
        })
    }

    private nonisolated static func status(of center: UNUserNotificationCenter) async -> NotificationPermission.Status {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        // Reduced to strings here, off the main actor, so nothing non-Sendable crosses the hop.
        let raw = response.actionIdentifier
        let actionId = raw == UNNotificationDefaultActionIdentifier ? NotificationPolicy.Action.open : raw
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let reply = NotificationResponse(actionId: actionId, userInfo: info)
        await MainActor.run { _ = self.state?.handleNotificationResponse(reply) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The policy already decided whether a banner is worth showing; show what it posted.
        [.banner, .list]
    }
}
```

If `check-warnings.sh` reports a Sendable diagnostic on `center` crossing into the closures, it is reporting a real isolation question. Answer it at the source by reading through a `nonisolated` helper that takes the center, as `status(of:)` does. Never use `@preconcurrency` to silence it.

Create `Sources/IrisKit/SurfaceInstall.swift`:

```swift
import AppKit

/// Which native surfaces this process gets (D6 decision 8, owner ruling 5). Called by
/// `IrisApp.init` and nothing else: `--run-job` never reaches it, and a test's `AppState()` never
/// has a sink. The status item needs no install; it is plain SwiftUI, so the bare binary has it.
@MainActor
enum SurfaceInstall {
    /// A real `.app` bundle, not just a bundle id: `UNUserNotificationCenter.current()` raises in
    /// an unbundled process, so this is asked before any call into the API.
    nonisolated static func isAppBundle(_ bundleURL: URL) -> Bool { bundleURL.pathExtension == "app" }

    static func installNotifications(on state: AppState, bundleURL: URL = Bundle.main.bundleURL,
                                     config: ConfigManager = .shared) {
        guard isAppBundle(bundleURL) else { return }
        state.notificationSink = UserNotificationSink(state: state)
        state.notificationContext = { [weak state] in
            NotificationContext(enabled: config.notificationMode == .needsAttention,
                                appActive: NSApp.isActive, mainWindowVisible: MainWindow.isVisible,
                                selectedConversationId: state?.selectedConversationId)
        }
    }
}
```

In `ConfigManager.swift`, at file scope above the class:

```swift
/// Settings' "Notifications" row (D6 decision 7).
enum NotificationMode: String, CaseIterable, Sendable {
    case off, needsAttention
}
```

After `checkpointAutoAdvance`:

```swift
    /// D6 decision 7: "Notifications: Off / Needs attention". Needs attention by default.
    var notificationMode: NotificationMode {
        didSet { store.set(notificationMode.rawValue, forKey: "NOTIFICATION_MODE") }
    }
```

After the `CHECKPOINT_AUTO_ADVANCE` load:

```swift
        self.notificationMode = NotificationMode(rawValue: saved.string(forKey: "NOTIFICATION_MODE") ?? "")
            ?? .needsAttention
```

In `SettingsView.swift`'s Preferences section, after the "Stream responses" toggle:

```swift
                    Picker("Notifications", selection: $config.notificationMode) {
                        Text("Off").tag(NotificationMode.off)
                        Text("Needs attention").tag(NotificationMode.needsAttention)
                    }
                    .help("Needs attention: a banner when a job is blocked or stopped by a limit, or an approval is waiting while the window is hidden. A banner never approves anything; Open shows the details. Only the app bundle posts them, not `swift run`.")
```

In `IrisApp.init`'s `MainActor.assumeIsolated` block, after `installGuardHealthSink()`:

```swift
            // D6 decision 8: only here, and only in a real `.app` bundle.
            SurfaceInstall.installNotifications(on: AppState.shared)
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 7 tests passed. Quote the count.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, then restore.
  - Delete `guard !asked else { return }`: `deniedNeverAsksAgain` fails, because a second request is made.
  - Add `import UserNotifications` to `SurfaceInstall.swift`: `oneImporter` fails.
  - Delete `guard isAppBundle(bundleURL) else { return }`: `installOutsideABundle` crashes the suite (the API raises outside a bundle). Kill the run, restore the guard, and record the crash as the expected failure.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/NotificationPermission.swift Sources/IrisKit/UserNotificationSink.swift Sources/IrisKit/SurfaceInstall.swift Sources/IrisKit/ConfigManager.swift Sources/IrisKit/SettingsView.swift Sources/IrisKit/iris.swift Tests/irisTests/NotificationInstallTests.swift`, then `git commit -m "feat(notify): UserNotificationSink, first-post permission, the bundle guard and the setting (D6 decisions 7, 8)"`.

### Task 15: Invariant 9 sweep, and open PR C

**Files:**
- Modify: `README.md` (the feature list)
- Modify: `docs/jobs.md` ("Event cards and the Iris conversation", "Approvals fail closed" at `:803`)

- [ ] **Step 1: Search, do not compose.** Run `grep -n -i "notif\|banner\|only inside\|overlay\|nothing tells\|window is hidden" README.md docs/*.md Sources/IrisKit/ChatView.swift Sources/IrisKit/AppState.swift Sources/IrisKit/EventDelivery.swift`, and read every hit. A sentence saying an ask is shown only in the window, or that a card is the only thing that reaches the owner, is now false. Fix it, and record the findings in the commit body. `EventDelivery.swift`'s "delivery never wakes a turn" stays true: a banner is not a turn.

- [ ] **Step 2: Add what is new.** In the README feature list: `- **Notifications**: a banner when a job is blocked on a call or stopped by a limit, and when an approval is waiting while the window is hidden. Open, Deny and Dismiss only: a banner never approves anything. Settings › General › Notifications turns them off. Only the app bundle posts them.` In `docs/jobs.md`, at the end of "Event cards and the Iris conversation":

```markdown
**Notifications.** A blocked card, and a failed or interrupted card whose job a limit has paused,
also post a banner, unless the app is in front with that conversation selected. An approval that
is waiting posts one too, unless the app is in front with its window showing. The title is always
`Iris: a job needs you` or `Iris: approval waiting`, because macOS shows titles on the lock screen.
The body names only the job and the tool, never what a run said. The actions are Open; Deny, for an
approval; and Dismiss, for a blocked card, which acknowledges it. Nothing on a banner approves:
Open shows the call in full, and approving stays a click in the app. Permission is asked the first
time a banner would be posted. Turn banners off with Settings › General › Notifications. `swift run`
and `scripts/run-dev.sh` never post; dev testing uses Iris Dev.app.
```

- [ ] **Step 3: Full suite.** Run `timeout 900 swift test` (all three markers), then `scripts/check-warnings.sh`.

- [ ] **Step 4: Commit, push and open PR C.** Run `git commit -am "docs: notifications (D6)"` and `git push -u origin feat/agency6-notifications`. Then run `gh api repos/sackheads/iris/pulls -f base=main -f head=feat/agency6-notifications -f title="feat: agency D6 PR C, notifications" -F body=@<file>`. The body lists Tasks 12-15, says Task 16 is pending, and ends with the PR attribution lines.

### Task 16: GUI pass for PR C (`work`, under the lease)

1. Run `pgrep -fl "Iris Dev|\.build/debug/iris"`. Expected: no output.
2. Run `python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: D6 PR C notifications" --minutes 60 --on-behalf-of <requesting peer>`. Expected: exit 0.
3. Build, sign and open Iris Dev.app as in Task 6 step 3. In Settings › General, confirm "Notifications" reads "Needs attention".
4. Create `d6-blocked` as in Task 6 step 8 if it does not exist. In Iris, type `/jobs run d6-blocked`, press Return, then click the Finder in the Dock within a second so that Iris Dev is inactive when the card arrives. Expected: the system prompt "“Iris Dev” Would Like to Send You Notifications" appears. Click "Don't Allow". Expected: no banner, and Iris Dev keeps running.
5. Repeat step 4. Expected: no prompt and no banner (the denied path, with no re-prompt).
6. In System Settings › Notifications › Iris Dev, turn "Allow notifications" on and set the style to "Alerts", so the actions stay visible.
7. Repeat step 4. Expected: an alert titled exactly `Iris: a job needs you`, with the body `Job “d6-blocked” is blocked on “write_file”.`. Its actions are Open and Dismiss. There is no Approve.
8. Click Open. Expected: Iris Dev comes forward on Iris, scrolled to d6-blocked's card.
9. Repeat step 4 and click Dismiss. Expected: the card's run is acknowledged, so `/jobs` no longer lists it under unacknowledged failures, and the menu bar label goes back to the hammer alone.
10. In a conversation other than Iris, type "Run the shell command `date` with run_command." and press Return, then press Cmd-H at once. Expected: an alert titled `Iris: approval waiting`, with the body `“run_command” is waiting for your approval.` and the actions Open and Deny.
11. Click Deny. Then bring Iris Dev forward. Expected: no approval overlay is left, and the turn continued with the call denied.
12. Repeat step 10, then bring Iris Dev forward from the Dock and approve in the overlay. Expected: the alert disappears from Notification Center.
13. Bring Iris Dev forward with Iris selected, and type `/jobs run d6-blocked`. Expected: no banner. Select another conversation, keep the app in front, and run it again from the Iris conversation's composer before switching away. Expected: a banner.
14. In Settings › General › Notifications, choose Off, then repeat step 4. Expected: no banner. Set it back to "Needs attention".
15. Lock screen (optional; skip it if locking would end the remote session). In System Settings › Notifications, set "Show previews" to "When Unlocked". Lock with Ctrl-Cmd-Q and trigger step 4 from a pre-scheduled one-minute job. Expected: the lock screen shows only `Iris: a job needs you`.
16. Quit Iris Dev and run `scripts/run-dev.sh`. Expected: it launches with no crash and no notification prompt, and the menu bar item works. Quit it.
17. Type `/jobs delete d6-blocked`, quit, and release the lease.

---

## PR D1: the URL trigger, without a scheme

Branch: `feat/agency6-url-trigger`, based on `main`. It is independent of A, B and C. Spec decisions 9-11 and 13, and decision 12's non-GUI half. Unit tests only.

### Task 17: Migration v19, `Job.urlTrigger`, `setURLTrigger`, the clear in `upsert`, `urlFires`

**Files:**
- Modify: `Sources/IrisKit/ConversationStore.swift:581-586` (add `v19_job_url_trigger` after `v18`)
- Modify: `Sources/IrisKit/Job.swift:420-528` (`urlTrigger` property, init parameter, `CodingKeys` and `init(from:)`)
- Modify: `Sources/IrisKit/JobLedger.swift`:
  - `:67-113` (`upsert` reads the stored row, clears, and returns `UpsertOutcome`)
  - `:180-189` (add `setURLTrigger` after `setQueuedFire`)
  - `:207-211` (add `job(urlTokenHash:)` after `job(id:)`)
  - `:236-267` (`job(from:)` reads `urlTrigger`)
  - the runs extension, after `runsStarted` (`:616-628`): `urlFires`
- Modify: `Tests/irisTests/JobsCommandTests.swift:663` and `Tests/irisTests/JobRetryTests.swift`'s `try? … upsert(…)`, only if the build warns on them
- Test: `Tests/irisTests/URLTriggerLedgerTests.swift` (new)

**Interfaces:**
- Produces:
  - `Job.urlTrigger: Bool`. It is read from the store and never written by `upsert`. It is an init parameter (`urlTrigger: Bool = false`, last).
  - `JobLedger.UpsertOutcome: Equatable, Sendable { let urlTriggerCleared: Bool }`. `JobLedger.upsert(_:)` now returns it, `@discardableResult`.
  - `JobLedger.setURLTrigger(jobId: UUID, tokenHash: String?) throws` and `JobLedger.job(urlTokenHash: String) throws -> Job?`.
  - `JobLedger.urlFires(jobId: UUID, since: Date) throws -> Int` and `JobLedger.urlTriggerKind = "url"`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/URLTriggerLedgerTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 9-11: the URL opt-in and its token digest have one writer, `setURLTrigger`.
/// `upsert` never writes them, and clears both when a job's prompt, profile or policy changes,
/// which covers both model rewrite paths at once.
@Suite("URL trigger in the ledger (D6)")
struct URLTriggerLedgerTests {
    private func makeLedger() throws -> JobLedger { try ConversationStore.inMemory().ledger }

    private func job(_ name: String = "pr-sweep") -> Job {
        Job(name: name, prompt: "sweep the PRs", trigger: .schedule(.interval(seconds: 60)))
    }

    @Test("a row and a JSON value written before D6 read back off, with no digest")
    func preD6ReadsOff() throws {
        let l = try makeLedger()
        let j = job()
        try l.upsert(j)   // upsert never writes the column, so it is NULL, as on every older row
        #expect(try l.job(id: j.id)?.urlTrigger == false)

        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as? [String: Any])
        object.removeValue(forKey: "urlTrigger")
        let old = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.urlTrigger == false, "invariant 1: a missing key decodes, it does not throw")
    }

    @Test("setURLTrigger writes the flag with the digest, rotates it, and turns both off")
    func setRotateOff() throws {
        let l = try makeLedger()
        let j = job()
        try l.upsert(j)
        try l.setURLTrigger(jobId: j.id, tokenHash: "digest-1")
        #expect(try l.job(id: j.id)?.urlTrigger == true)
        #expect(try l.job(urlTokenHash: "digest-1")?.id == j.id)

        try l.setURLTrigger(jobId: j.id, tokenHash: "digest-2")
        #expect(try l.job(urlTokenHash: "digest-1") == nil, "a rotated-out digest finds nothing")

        try l.setURLTrigger(jobId: j.id, tokenHash: nil)
        #expect(try l.job(id: j.id)?.urlTrigger == false)
        #expect(try l.job(urlTokenHash: "digest-2") == nil)
        let nobody = UUID()
        #expect(throws: JobLedgerError.unknownJob(nobody)) { try l.setURLTrigger(jobId: nobody, tokenHash: "x") }
    }

    @Test("two jobs can never share a digest")
    func digestIsUnique() throws {
        let l = try makeLedger()
        let a = job("a"), b = job("b")
        try l.upsert(a)
        try l.upsert(b)
        try l.setURLTrigger(jobId: a.id, tokenHash: "same")
        #expect(throws: (any Error).self) { try l.setURLTrigger(jobId: b.id, tokenHash: "same") }
    }

    @Test("a stale copy written back, and a new trigger alone, keep the flag")
    func staleCopyAndRescheduleKeep() throws {
        let l = try makeLedger()
        let j = job()
        try l.upsert(j)
        try l.setURLTrigger(jobId: j.id, tokenHash: "d")

        var stale = j   // its urlTrigger is false: the copy predates the opt-in
        stale.nextFireAt = Date()
        #expect(try l.upsert(stale).urlTriggerCleared == false)

        var moved = try #require(try l.job(id: j.id))
        moved.trigger = .schedule(.cron(CronSchedule(expression: "0 9 * * *", timeZone: "UTC")))
        #expect(try l.upsert(moved).urlTriggerCleared == false, "/jobs reschedule changes only the trigger")
        #expect(try l.job(urlTokenHash: "d")?.id == j.id)
    }

    @Test("a changed prompt, profile, grant or budget clears the flag and the digest, and says so")
    func anyChangeClears() throws {
        let edits: [(String, (inout Job) -> Void)] = [
            ("prompt", { $0.prompt = "sweep the PRs and merge them" }),
            ("profile", { $0.profile = .mutating }),
            ("grant", { $0.policy.grants = JobGrant(mounts: [], network: true) }),
            ("daily budget", { $0.policy.dailyTokenBudget = 9_000_000 }),
            ("per-run budget", { $0.policy.perRunTokenBudget = 900_000 }),
            ("breaker", { $0.policy.maxRunsPerHour = 60 }),
        ]
        for (label, edit) in edits {
            let l = try makeLedger()
            let j = job()
            try l.upsert(j)
            try l.setURLTrigger(jobId: j.id, tokenHash: "d")
            var changed = try #require(try l.job(id: j.id))
            edit(&changed)

            #expect(try l.upsert(changed).urlTriggerCleared, Comment(rawValue: label))
            #expect(try l.job(id: j.id)?.urlTrigger == false, Comment(rawValue: label))
            #expect(try l.job(urlTokenHash: "d") == nil, Comment(rawValue: label))
        }
    }

    @Test("a change to a job that never had the trigger clears nothing")
    func changeWithoutTrigger() throws {
        let l = try makeLedger()
        var j = job()
        try l.upsert(j)
        j.prompt = "something else"
        #expect(try l.upsert(j).urlTriggerCleared == false)
    }

    @Test("urlFires counts only this job's url rows since the given time")
    func urlFiresCounts() throws {
        let l = try makeLedger()
        let j = job(), other = job("other")
        try l.upsert(j)
        try l.upsert(other)
        let now = Date()
        for (owner, kind, ago) in [(j, "url", 60.0), (j, "url", 120), (j, "manual", 60), (other, "url", 60), (j, "url", 7_200)] {
            try l.begin(run: JobRun(jobId: owner.id, jobName: owner.name, triggerKind: kind,
                                    startedAt: now.addingTimeInterval(-ago)))
        }
        #expect(try l.urlFires(jobId: j.id, since: now.addingTimeInterval(-3_600)) == 2)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh URLTriggerLedgerTests`. Expected: the build fails with "value of type 'Job' has no member 'urlTrigger'".

- [ ] **Step 3: Implement the migration.** In `ConversationStore.swift`, after `v18_prefix_mismatch_behavior`:

```swift
        // D6 decisions 10-11: a per-job owner opt-in to URL fires, and the SHA-256 digest of its
        // token. NULL (every earlier row) is off with no token. Unique through an index, because
        // SQLite cannot add a UNIQUE column with ALTER TABLE; a unique index still allows any
        // number of NULLs.
        m.registerMigration("v19_job_url_trigger") { db in
            try db.alter(table: "jobs") { t in
                t.add(column: "urlTrigger", .boolean)
                t.add(column: "urlTokenHash", .text)
            }
            try db.execute(sql: "CREATE UNIQUE INDEX jobs_urlTokenHash ON jobs(urlTokenHash)")
        }
```

- [ ] **Step 4: Implement `Job.urlTrigger`.** In `Job.swift`, after `var action: JobAction`:

```swift
    /// D6 decision 9: whether the owner has let a link fire this job. Read from the store; set
    /// only by `/jobs url` through `JobLedger.setURLTrigger`. `upsert` never writes it, so a stale
    /// copy written back cannot turn it on, and setting it on a value does nothing.
    var urlTrigger: Bool
```

Add `urlTrigger: Bool = false` as the init's last parameter, after `action: JobAction = .prompt`, with `self.urlTrigger = urlTrigger` in the body. Add `urlTrigger` to `CodingKeys` (`case policy, retryAttempt, queuedFire, action, urlTrigger`). At the end of `init(from:)`:

```swift
        // Invariant 1: every job written before D6 lacks it.
        urlTrigger = try container.decodeIfPresent(Bool.self, forKey: .urlTrigger) ?? false
```

In `JobLedger.job(from:)`, add the argument after `action: action`:

```swift
            action: action,
            // NULL on every row written before D6 (invariant 1): off.
            urlTrigger: try r.read("urlTrigger", Bool.self) ?? false)
```

- [ ] **Step 5: Implement the ledger writes.** Replace `upsert(_:)` (`:67-113`, doc comment included):

```swift
    /// What an `upsert` changed beyond the row itself.
    struct UpsertOutcome: Equatable, Sendable {
        /// The job was URL-enabled and its prompt, profile or policy changed, so the opt-in and
        /// its token were dropped (D6 decision 11). The caller says so.
        let urlTriggerCleared: Bool
    }

    /// Inserts `job`, or replaces the row with the same id. A rename onto another job's name
    /// surfaces as the UNIQUE violation on `name` rather than silently clobbering that job, which
    /// is why this is an `ON CONFLICT(id)` upsert and not `INSERT OR REPLACE`.
    ///
    /// Editing a job's **gate** also drops every signal its runs recorded, in the same write (#187
    /// §7). A signal is a reading taken by one gate: an ETag cannot answer for an mtime, and
    /// leaving the old one behind would have the new gate compare against something it never saw.
    ///
    /// The URL trigger and its token digest are never written here (D6 decision 11): only
    /// `setURLTrigger` writes them, so a stale `Job` copy written back by the scheduler or a tool
    /// cannot set them. And when a URL-enabled job's prompt, profile or policy (grant and budgets
    /// included) changes, both are cleared in this same write. That one rule covers both model
    /// rewrite paths, `schedule_job`'s re-schedule and `register_directory_watcher`'s update, and
    /// any later `/jobs` verb. Every path that changes a job comes through here, so this is the
    /// one place it has to be done.
    @discardableResult
    func upsert(_ job: Job) throws -> UpsertOutcome {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let triggerJSON = String(decoding: try encoder.encode(job.trigger), as: UTF8.self)
        let policyJSON = String(decoding: try encoder.encode(job.policy), as: UTF8.self)
        let cleared: Bool = try writer.write { db in
            let stored = try Row.fetchOne(db, sql: """
                SELECT trigger, prompt, profile, policy, urlTrigger FROM jobs WHERE id = ?
                """, arguments: [job.id.uuidString])
            try db.execute(sql: """
                INSERT INTO jobs (
                    id, name, prompt, triggerKind, trigger, profile, destinationConversationId,
                    createdInConversationId, createdAt, enabled, nextFireAt, lastRunAt, pausedReason,
                    policy, retryAttempt, queuedFire, action)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    prompt = excluded.prompt,
                    triggerKind = excluded.triggerKind,
                    trigger = excluded.trigger,
                    profile = excluded.profile,
                    destinationConversationId = excluded.destinationConversationId,
                    createdInConversationId = excluded.createdInConversationId,
                    createdAt = excluded.createdAt,
                    enabled = excluded.enabled,
                    nextFireAt = excluded.nextFireAt,
                    lastRunAt = excluded.lastRunAt,
                    pausedReason = excluded.pausedReason,
                    policy = excluded.policy,
                    retryAttempt = excluded.retryAttempt,
                    queuedFire = excluded.queuedFire,
                    action = excluded.action
                """, arguments: [
                    job.id.uuidString, job.name, job.prompt, job.trigger.kind, triggerJSON,
                    job.profile.rawValue, job.destinationConversationId?.uuidString,
                    job.createdInConversationId?.uuidString, job.createdAt, job.enabled,
                    job.nextFireAt, job.lastRunAt, job.pausedReason,
                    policyJSON, job.retryAttempt, job.queuedFire, job.action.stored,
                ])
            guard let stored else { return false }
            if let storedTrigger = String.fromDatabaseValue(stored["trigger"] as DatabaseValue),
               Self.storedGate(storedTrigger) != job.trigger.gate {
                // A stored trigger this build cannot read decodes as "no gate", so a job that
                // *gains* one clears, the safe direction.
                try db.execute(sql: "UPDATE job_runs SET gateSignal = NULL WHERE jobId = ?",
                               arguments: [job.id.uuidString])
            }
            guard Bool.fromDatabaseValue(stored["urlTrigger"] as DatabaseValue) == true else { return false }
            // Read leniently: a stored value this build cannot read counts as changed, which
            // clears the opt-in, the safe direction.
            let storedPrompt = String.fromDatabaseValue(stored["prompt"] as DatabaseValue)
            let storedProfile = String.fromDatabaseValue(stored["profile"] as DatabaseValue)
                .flatMap(JobProfile.init(rawValue:))
            let changed = storedPrompt != job.prompt || storedProfile != job.profile
                || Self.policy(from: stored["policy"] as DatabaseValue?) != job.policy
            guard changed else { return false }
            try db.execute(sql: "UPDATE jobs SET urlTrigger = NULL, urlTokenHash = NULL WHERE id = ?",
                           arguments: [job.id.uuidString])
            return true
        }
        notifyJobsChanged()
        return UpsertOutcome(urlTriggerCleared: cleared)
    }
```

After `setQueuedFire`:

```swift
    /// D6 decisions 10-11: the only writer of the URL trigger and its token digest. A digest
    /// turns it on, replacing any earlier one; nil turns it off and deletes the digest. Throws
    /// `JobLedgerError.unknownJob` for an id that is not in the table, and a constraint error for
    /// a digest another job already holds.
    func setURLTrigger(jobId: UUID, tokenHash: String?) throws {
        let flag: Bool? = tokenHash == nil ? nil : true
        try writer.write { db in
            try db.execute(sql: "UPDATE jobs SET urlTrigger = ?, urlTokenHash = ? WHERE id = ?",
                           arguments: [flag, tokenHash, jobId.uuidString])
            guard db.changesCount > 0 else { throw JobLedgerError.unknownJob(jobId) }
        }
    }
```

After `job(id:)`:

```swift
    /// The job a URL's token digest names, if its trigger is still on (D6 decision 10).
    func job(urlTokenHash: String) throws -> Job? {
        try decodeAll(sql: "SELECT * FROM jobs WHERE urlTokenHash = ? AND urlTrigger",
                      arguments: [urlTokenHash]).jobs.first
    }
```

In the runs extension, after `runsStarted`:

```swift
    /// The `triggerKind` a URL fire's row records. Spelled once: `urlFires` counts it, and
    /// `FireOrigin.url` writes it.
    static let urlTriggerKind = "url"

    /// How many of this job's rows a URL fire wrote at or after `since`: decision 13's limit,
    /// asked with `since = now - 1h`. Every such row counts, a skip row included. The limit is
    /// on links that got as far as admission, and an over-limit link writes no row at all.
    func urlFires(jobId: UUID, since: Date) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM job_runs WHERE jobId = ? AND triggerKind = ? AND startedAt >= ?
                """, arguments: [jobId.uuidString, Self.urlTriggerKind, since]) ?? 0
        }
    }
```

- [ ] **Step 6: Run them and watch them pass.** Run the same filter. Expected: 7 tests passed. Quote the count.

- [ ] **Step 7: Mutation checks (the opt-in rules).** Make each change, run the filter, see the named test fail, then restore.
  - Delete `|| Self.policy(from: stored["policy"] as DatabaseValue?) != job.policy`: `anyChangeClears` fails on "grant", "daily budget", "per-run budget" and "breaker".
  - Add `urlTrigger` to `upsert`'s column list, its `VALUES` and its `ON CONFLICT` set, written from `job.urlTrigger`: `staleCopyAndRescheduleKeep` fails.
  - Change `decodeIfPresent` for `.urlTrigger` to `decode`: `preD6ReadsOff` fails.

- [ ] **Step 8: Run the neighbours and the warnings check.**
  - Run `timeout 300 scripts/test-filter.sh 'JobLedgerTests|JobLedgerPolicyTests|JobModelTests|WatchMigrationTests|JobRunCostMigrationTests|GateEvaluatorTests'`. Expected: every test passes. Quote the count.
  - Run `scripts/check-warnings.sh`. Expected: no warnings. If it warns `result of 'try?' is unused` at `JobsCommandTests.swift:663` or in `JobRetryTests.swift`, write `_ = try? …` there.

- [ ] **Step 9: Commit.** `git add Sources/IrisKit/ConversationStore.swift Sources/IrisKit/Job.swift Sources/IrisKit/JobLedger.swift Tests/irisTests/URLTriggerLedgerTests.swift` (plus either test file Step 8 touched), then `git commit -m "feat(jobs): the URL trigger column, its one writer, and the clear on change (D6 decisions 9-11)"`.

### Task 18: The token, `/jobs url`, and `list_jobs`' flag

**Files:**
- Create: `Sources/IrisKit/URLTriggerToken.swift`
- Create: `Sources/IrisKit/RunJobURL.swift` (the URL builder and the scheme; Tasks 20 and 21 extend it)
- Modify: `Sources/IrisKit/BuildIdentity.swift` (`urlScheme`)
- Modify: `Sources/IrisKit/JobsCommand.swift:12-29` (the `url` case and `usageText`), `:44-66` (`parse`), plus new texts
- Modify: `Sources/IrisKit/AppState.swift:3779` (`handleJobsCommand`'s `.url` branch)
- Modify: `Sources/IrisKit/iris.swift:4944-4946` (`list_jobs` description) and `:5029-5059` (`jobsListJSON`'s row)
- Modify: `Tests/irisTests/JobsCommandTests.swift:650` (the usage-forms list gains `/jobs url`)
- Test: `Tests/irisTests/URLTriggerCommandTests.swift` (new)

**Interfaces:**
- Consumes: `JobLedger.setURLTrigger` and `job(urlTokenHash:)`, `Job.urlTrigger` (Task 17).
- Produces:
  - `enum URLTriggerToken` with `byteCount = 16`, `encodedLength = 22`, `generate(fill:) -> String?`, `secureFill(_:) -> Bool`, `base64url(_:) -> String`, `digest(_:) -> String` (lowercase hex) and `isWellFormed(_:) -> Bool`.
  - `BuildIdentity.urlScheme` (`"iris"` or `"iris-dev"`).
  - `enum RunJobURL` with `host = "run-job"` and `url(token:identity:) -> String`.
  - `JobsCommand.url(name: String, setting: Bool?)`, `JobsCommand.parseURL(_:)`, `JobsCommand.urlStatusText(_:)`, `JobsCommand.urlOnText(_:url:)`, `JobsCommand.urlOffText(_:)` and `JobsCommand.urlSchemePendingNote`.
  - `list_jobs` rows gain `"urlTrigger": Bool`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/URLTriggerCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decisions 9 and 10: `/jobs url <job> on` mints a 128-bit token, prints its link once and
/// keeps only the digest. The token never reaches a model: not through a tool, a card, a system
/// line, the model's history, search, `read_conversation` or the rotation summary.
@MainActor
@Suite("/jobs url (D6)", .timeLimit(.minutes(1)))
struct URLTriggerCommandTests {
    // MARK: The token

    @Test("a token is 22 base64url characters from 16 random bytes")
    func tokenShape() throws {
        let token = try #require(URLTriggerToken.generate())
        #expect(token.count == 22)
        #expect(URLTriggerToken.isWellFormed(token))
        #expect(URLTriggerToken.generate() != token)
        #expect(URLTriggerToken.base64url([0xfb, 0xff]) == "-_8", "no +, / or = padding")
        #expect(URLTriggerToken.generate(fill: { _ in false }) == nil, "a random source that fails mints nothing")
    }

    @Test("the digest is SHA-256, in lowercase hex")
    func digestVector() {
        #expect(URLTriggerToken.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("only a 22-character base64url string is well formed")
    func wellFormed() {
        #expect(!URLTriggerToken.isWellFormed(UUID().uuidString))
        #expect(!URLTriggerToken.isWellFormed("pr-sweep"))
        #expect(!URLTriggerToken.isWellFormed(String(repeating: "a", count: 21)))
        #expect(!URLTriggerToken.isWellFormed(String(repeating: "a", count: 23)))
        #expect(!URLTriggerToken.isWellFormed(String(repeating: "a", count: 20) + "%4"))
        #expect(URLTriggerToken.isWellFormed(String(repeating: "a", count: 20) + "-_"))
    }

    // MARK: Parsing

    @Test("/jobs url reads from the right: the last word is on or off, the rest is the name")
    func parse() {
        #expect(JobsCommand.parse("/jobs url pr-sweep") == .url(name: "pr-sweep", setting: nil))
        #expect(JobsCommand.parse("/jobs url pr-sweep on") == .url(name: "pr-sweep", setting: true))
        #expect(JobsCommand.parse("/jobs url pr-sweep OFF") == .url(name: "pr-sweep", setting: false))
        #expect(JobsCommand.parse("/jobs url Daily digest on") == .url(name: "Daily digest", setting: true))
        #expect(JobsCommand.parse("/jobs url lights-on") == .url(name: "lights-on", setting: nil),
                "a name that ends in 'on' is a name")
        #expect(JobsCommand.parse("/jobs url turn on") == .url(name: "turn", setting: true))
        #expect(JobsCommand.parse(#"/jobs url "turn on""#) == .url(name: "turn on", setting: nil))
        #expect(JobsCommand.parse(#"/jobs url "turn on" off"#) == .url(name: "turn on", setting: false))
        #expect(JobsCommand.parse("/jobs url on") == .url(name: "on", setting: nil))
        #expect(JobsCommand.parse("/jobs url") == .usage)
        #expect(JobsCommand.usageText.contains("/jobs url <name> [on|off]"))
    }

    // MARK: The handler

    private func makeApp(with jobs: [Job]) throws -> (ConversationStore, AppState, UUID) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation()
        app.selectedConversationId = id
        for job in jobs { try store.ledger.upsert(job) }
        return (store, app, id)
    }

    private func output(_ app: AppState, _ id: UUID) -> String {
        (app.conversations.first { $0.id == id }?.messages ?? [])
            .filter { $0.role == .command }.map(\.content).joined(separator: "\n")
    }

    /// The token in the most recent `on` reply.
    private func token(in text: String) throws -> String {
        let marker = "\(BuildIdentity.current.urlScheme)://\(RunJobURL.host)/"
        let range = try #require(text.range(of: marker, options: .backwards))
        return String(text[range.upperBound...].prefix(URLTriggerToken.encodedLength))
    }

    private func sweep() -> Job { Job(name: "pr-sweep", prompt: "sweep", trigger: .schedule(.interval(seconds: 60))) }

    @Test("on prints a link whose token hashes to the stored digest; on again rotates; off clears")
    func onRotateOff() throws {
        let job = sweep()
        let (store, app, id) = try makeApp(with: [job])

        app.sendMessage("/jobs url pr-sweep on")
        let first = try token(in: output(app, id))
        #expect(URLTriggerToken.isWellFormed(first))
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(first))?.id == job.id)

        app.sendMessage("/jobs url pr-sweep on")
        let second = try token(in: output(app, id))
        #expect(second != first)
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(first)) == nil, "the old link is dead")
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(second))?.id == job.id)

        app.sendMessage("/jobs url pr-sweep off")
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)
        #expect(try store.ledger.job(urlTokenHash: URLTriggerToken.digest(second)) == nil)
    }

    @Test("asking shows on or off and never a token, and an unknown name is refused")
    func status() throws {
        let (_, app, id) = try makeApp(with: [sweep()])
        app.sendMessage("/jobs url pr-sweep")
        #expect(output(app, id).contains("is off"))
        app.sendMessage("/jobs url pr-sweep on")
        let minted = try token(in: output(app, id))
        app.sendMessage("/jobs url pr-sweep")
        let lines = output(app, id).components(separatedBy: "\n")
        #expect(lines.last?.contains("is on") == true)
        #expect(lines.last?.contains(minted) == false)
        app.sendMessage("/jobs url nope on")
        #expect(output(app, id).hasSuffix("No job named 'nope'."))
    }

    @Test("the token never reaches the model, by any surface")
    func tokenNeverReachesTheModel() async throws {
        let job = sweep()
        let (store, app, id) = try makeApp(with: [job])
        app.sendMessage("/jobs url pr-sweep on")
        let minted = try token(in: output(app, id))

        // list_jobs and get_job_run: the flag, never the token.
        let jobs = try store.ledger.jobs()
        let listing = IrisEngine.jobsListJSON(jobs, lastStatuses: [:], usage: .empty, unreadableJobs: 0)
        #expect(!listing.contains(minted))
        #expect(listing.contains(#""urlTrigger":true"#))
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "url", startedAt: Date())
        #expect(!IrisEngine.jobRunJSON(run, outcome: nil, failureReason: nil, gateSignal: nil,
                                       lastAgentMessage: nil).contains(minted))

        // /jobs, cards and system lines.
        app.sendMessage("/jobs")
        if let listingTask = app.jobsListingTask { try await value(of: listingTask) }
        let commands = app.conversations.first { $0.id == id }?.messages.filter { $0.role == .command } ?? []
        #expect(commands.last?.content.contains("pr-sweep") == true, "the last command output is the listing")
        #expect(commands.last?.content.contains(minted) == false, "the listing never repeats the token")
        for conversation in app.conversations {
            for message in conversation.messages where message.role != .command {
                #expect(!message.content.contains(minted), "a \(message.role) message carried the token")
            }
        }

        // The model's history, search, read_conversation: holds today by construction (a
        // .command message is outside all three), pinned so a refactor cannot move it.
        let conversation = try #require(app.conversations.first { $0.id == id })
        let history = conversation.history.flatMap(\.parts).compactMap(\.text).joined()
        #expect(!history.contains(minted))
        app.flushSave()
        #expect(try store.searchConversations(query: minted).isEmpty)
        #expect(try store.searchConversations(query: "run-job").isEmpty)
        #expect(!ConversationReader.page(conversation.messages, from: 0, count: 50).text.contains(minted))

        // The rotation summary: the one path that sends UI messages to a model (plan note 12).
        // An owner and an agent line make sure the call is actually made.
        app.appendMessage(role: .user, content: "what is scheduled?", to: id)
        app.appendMessage(role: .agent, content: "pr-sweep, every minute", to: id)
        let messages = try #require(app.conversations.first { $0.id == id }).messages
        let client = CapturingLLMClient(reply: "summary")
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        _ = await engine.summarizeForRotation(messages: messages)
        #expect(!client.requests.isEmpty, "the summary call was made")
        for request in client.requests {
            #expect(!String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains(minted))
        }
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh URLTriggerCommandTests`. Expected: the build fails with "cannot find 'URLTriggerToken' in scope".

- [ ] **Step 3: Implement the token and the URL builder.** Create `Sources/IrisKit/URLTriggerToken.swift`:

```swift
import CryptoKit
import Foundation
import Security

/// The capability a URL trigger carries (D6 decision 10): 128 random bits, base64url-encoded.
/// Not the job id, which sits in the ledger and in transcripts, where an approved host
/// `run_command` could `open` it. Only the SHA-256 digest is stored: the token cannot be printed
/// twice, and a leaked database holds no live URL.
enum URLTriggerToken {
    static let byteCount = 16
    static let encodedLength = 22

    /// A fresh token, or nil when the system's random source failed. Then nothing is stored and
    /// the owner is told.
    static func generate(fill: (inout [UInt8]) -> Bool = URLTriggerToken.secureFill) -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard fill(&bytes) else { return nil }
        return base64url(bytes)
    }

    static func secureFill(_ bytes: inout [UInt8]) -> Bool {
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    }

    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Exactly what `generate` makes. A job id, a name, or anything percent-encoded is not.
    static func isWellFormed(_ token: String) -> Bool {
        token.count == encodedLength && token.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_"
        }
    }
}
```

Create `Sources/IrisKit/RunJobURL.swift`:

```swift
import Foundation

/// `iris://run-job/<token>` (D6 decisions 10 and 12): the link that fires one opted-in job. It
/// carries no input, so no URL content reaches a model and the taint is untouched. Adding any
/// parameter reopens decision 12.
enum RunJobURL {
    static let host = "run-job"

    static func url(token: String, identity: BuildIdentity) -> String {
        "\(identity.urlScheme)://\(host)/\(token)"
    }
}
```

In `BuildIdentity.swift`, after `statusSymbol`, or after `hotkeyName` if PR A has not merged:

```swift
    /// The URL scheme this build answers (D6 decision 12): a separate one per build, so a link
    /// made for the dev build can never fire the release app's job, or the other way round.
    var urlScheme: String { self == .release ? "iris" : "iris-dev" }
```

- [ ] **Step 4: Implement the command.** In `JobsCommand.swift`, add `case url(name: String, setting: Bool?)` after `reschedule`. Replace `usageText` with:

```swift
    static let usageText = "Usage: /jobs · /jobs ack <run id> · /jobs pause <name> · "
        + "/jobs resume <name> · /jobs run <name> · /jobs delete <name> · "
        + "/jobs reschedule <name> <cron> [timezone] · /jobs url <name> [on|off]"
```

In `parse`, after the `reschedule` branch:

```swift
        if args == "url" || args.hasPrefix("url ") {
            return parseURL(String(args.dropFirst("url".count)))
        }
```

Then add the parser and the texts:

```swift
    /// `<name> [on|off]`, read from the right (D6 decision 9): the last word is `on` or `off`, and
    /// the rest of the line is the name, quoted or not. A name of one word that is itself `on` or
    /// `off` is a name, since there is nothing left of the line to be one. So `/jobs url "turn on"`
    /// asks about a job called "turn on".
    static func parseURL(_ rest: String) -> JobsCommand {
        var tokens = quotedTokens(rest)
        var setting: Bool?
        if tokens.count >= 2, let last = tokens.last?.lowercased(), last == "on" || last == "off" {
            setting = last == "on"
            tokens.removeLast()
        }
        let name = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .usage }
        return .url(name: name, setting: setting)
    }

    /// Plan note 13: said until the scheme is registered, and deleted by the PR that registers it.
    static let urlSchemePendingNote = "Nothing opens the link yet: the app registers the scheme in a later update."

    static func urlStatusText(_ job: Job) -> String {
        job.urlTrigger
            ? "The URL trigger for **\(job.name)** is on. Its link was shown once, when it was turned on; `/jobs url \(job.name) on` makes a new one and retires the old."
            : "The URL trigger for **\(job.name)** is off. `/jobs url \(job.name) on` turns it on and shows its link."
    }

    static func urlOnText(_ job: Job, url: String) -> String {
        """
        The URL trigger for **\(job.name)** is on. Its link, shown only this once:

        `\(url)`

        Opening it fires \(job.name) now, as `/jobs run` would, at most \(RunJobURL.maxFiresPerHour) times an hour. \
        Turning it on again replaces the link; `/jobs url \(job.name) off` retires it. Changing the job's prompt, \
        profile or policy turns it off. \(urlSchemePendingNote)
        """
    }

    static func urlOffText(_ job: Job) -> String {
        "The URL trigger for **\(job.name)** is off. Any link made for it no longer works."
    }
```

The reply quotes the limit, so `RunJobURL` gains it now. Add it to `RunJobURL.swift`:

```swift
    /// D6 decision 13: URL fires per job per rolling hour, below the breaker's 6.
    static let maxFiresPerHour = 3
```

In `AppState.handleJobsCommand`, add a branch after `.reschedule`:

```swift
        case .url(let name, let setting):
            do {
                guard let job = try ledger.job(named: name) else {
                    emitCommandOutput("No job named '\(name)'.", format: .markdown, to: convId)
                    return
                }
                switch setting {
                case nil:
                    emitCommandOutput(JobsCommand.urlStatusText(job), format: .markdown, to: convId)
                case false?:
                    try ledger.setURLTrigger(jobId: job.id, tokenHash: nil)
                    emitCommandOutput(JobsCommand.urlOffText(job), format: .markdown, to: convId)
                case true?:
                    guard let token = URLTriggerToken.generate() else {
                        emitCommandOutput("Could not make a link for **\(job.name)**: the system's random source failed. Nothing changed.",
                                          format: .markdown, to: convId)
                        return
                    }
                    // Only the digest is stored. The token exists in this reply and nowhere else:
                    // a `.command` message, outside the model's history, search and
                    // `read_conversation` (URLTriggerCommandTests pins all three).
                    try ledger.setURLTrigger(jobId: job.id, tokenHash: URLTriggerToken.digest(token))
                    emitCommandOutput(JobsCommand.urlOnText(job, url: RunJobURL.url(token: token, identity: .current)),
                                      format: .markdown, to: convId)
                }
            } catch {
                emitCommandOutput("Could not change the URL trigger: \(error).", format: .markdown, to: convId)
            }
```

In `iris.swift`'s `jobsListJSON` row, after `"action": job.action.stored,`:

```swift
                // D6 decision 9: whether the owner has let a link fire this job. Read-only here;
                // the token itself is never in any tool result (decision 10).
                "urlTrigger": job.urlTrigger,
```

In the `list_jobs` description, after "`action` — … the daily digest — ", insert: "`urlTrigger` — whether the owner has let a link fire the job (only the owner can turn it on, and changing the job's prompt, profile or policy turns it off) — ".

In `JobsCommandTests.swift:650`, add `"/jobs url"` to the list of forms.

- [ ] **Step 5: Run them and watch them pass.** Run the same filter. Expected: 8 tests passed. Then run `timeout 300 scripts/test-filter.sh 'JobsCommandTests|JobToolsTests'`. Expected: every test passes. Quote both counts.

- [ ] **Step 6: Mutation checks (the token never reaches the model).** Make each change, run the filter, see the named test fail, then restore.
  - Change the `on` reply's `format: .markdown` to `.system`: `tokenNeverReachesTheModel` fails on the system-line check.
  - In `handleJobsCommand`'s `true?` branch, add `appendContentToHistory(for: convId, content: AppState.eventLineContent(token))`: `tokenNeverReachesTheModel` fails on the history check.
  - Add `.command` to `ConversationStore.indexedRoles` (`ConversationStore.swift:594`): the FTS assertion in `tokenNeverReachesTheModel` fails.

- [ ] **Step 7: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 8: Commit.** `git add Sources/IrisKit/URLTriggerToken.swift Sources/IrisKit/RunJobURL.swift Sources/IrisKit/BuildIdentity.swift Sources/IrisKit/JobsCommand.swift Sources/IrisKit/AppState.swift Sources/IrisKit/iris.swift Tests/irisTests/URLTriggerCommandTests.swift Tests/irisTests/JobsCommandTests.swift`, then `git commit -m "feat(jobs): /jobs url mints a hashed per-job token; list_jobs shows the flag (D6 decisions 9, 10)"`.

### Task 19: Say so when a change turns the trigger off

**Files:**
- Modify: `Sources/IrisKit/JobScheduler.swift:509-519` (`scheduleReporting`, with `schedule` delegating to it)
- Modify: `Sources/IrisKit/iris.swift:2894-2902` (`scheduleJob`'s store) and `:152-160` (`jobToolsProvider` passes the announcer)
- Modify: `Sources/IrisKit/ToolExecutor.swift:7-9` (`JobTools.announceURLTriggerCleared`), `:423` (`registerWatcher`'s upsert) and `:446` (its result)
- Modify: `Sources/IrisKit/ScheduleJobArguments.swift:385` (`urlTriggerClearedNote` beside `replacedNote`)
- Modify: `Sources/IrisKit/AppState.swift` (`announceURLTriggerCleared(jobName:)` and `urlTriggerClearedLine`)
- Test: `Tests/irisTests/URLTriggerClearTests.swift` (new)

**Interfaces:**
- Consumes: `JobLedger.UpsertOutcome` (Task 17).
- Produces:
  - `JobScheduler.scheduleReporting(_:) async throws -> (job: Job, urlTriggerCleared: Bool)`.
  - `JobTools.announceURLTriggerCleared: (@Sendable (String) async -> Void)?`, defaulting to nil, so every existing `JobTools(ledger:)` still compiles.
  - `ScheduleJobArguments.urlTriggerClearedNote(_ name: String) -> String`.
  - `AppState.announceURLTriggerCleared(jobName:)` and `AppState.urlTriggerClearedLine(_:)`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/URLTriggerClearTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 11: both model rewrite paths turn the URL trigger off when they change what the
/// job does, and say so to the model and to the owner. `/jobs reschedule` keeps it.
@MainActor
@Suite("URL trigger cleared on change (D6)", .timeLimit(.minutes(1)))
struct URLTriggerClearTests {
    private func makeEngine() throws -> (ConversationStore, AppState, IrisEngine, UUID) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let conversation = state.createNewConversation()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, conversation)
    }

    private func schedule(_ prompt: String, interval: Int = 600) -> Result<ScheduleJobArguments, ToolMessage> {
        ScheduleJobArguments.parse(["prompt": .string(prompt), "intervalSeconds": .int(interval),
                                    "name": .string("pr-sweep")])
    }

    private func irisLines(_ state: AppState) -> [String] {
        state.conversations.first { $0.id == state.activityConversationId() }?
            .messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    @Test("schedule_job's re-schedule with a new prompt turns it off, and says so twice")
    func rescheduleClears() async throws {
        let (store, state, engine, conversation) = try makeEngine()
        _ = await engine.scheduleJob(schedule("sweep the PRs"), conversationId: conversation, sandboxAvailable: false)
        let job = try #require(try store.ledger.job(named: "pr-sweep"))
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: "d")

        let answer = await engine.scheduleJob(schedule("sweep the PRs and merge them"),
                                              conversationId: conversation, sandboxAvailable: false)

        #expect(answer.contains(ScheduleJobArguments.urlTriggerClearedNote("pr-sweep")))
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)
        #expect(irisLines(state).contains(AppState.urlTriggerClearedLine("pr-sweep")))
    }

    @Test("a re-schedule that changes only the cadence keeps it, and says nothing")
    func cadenceOnlyKeeps() async throws {
        let (store, state, engine, conversation) = try makeEngine()
        _ = await engine.scheduleJob(schedule("sweep the PRs"), conversationId: conversation, sandboxAvailable: false)
        let job = try #require(try store.ledger.job(named: "pr-sweep"))
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: "d")

        let answer = await engine.scheduleJob(schedule("sweep the PRs", interval: 1_200),
                                              conversationId: conversation, sandboxAvailable: false)

        #expect(!answer.contains("URL trigger"))
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == true)
        #expect(!irisLines(state).contains(AppState.urlTriggerClearedLine("pr-sweep")))
    }

    private actor Announced {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    @Test("register_directory_watcher's update with new instructions turns it off, and says so")
    func watcherUpdateClears() async throws {
        let base = try tempDirectory(prefix: "iris-urlclear")
        defer { try? FileManager.default.removeItem(at: base) }
        let notes = base.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let irisRoot = base.appendingPathComponent("dot-iris")
        try FileManager.default.createDirectory(at: irisRoot.appendingPathComponent("config"),
                                                withIntermediateDirectories: true)
        let store = try ConversationStore.inMemory()
        let announced = Announced()
        var configured = ToolExecutor()
        configured.jobToolsProvider = {
            JobTools(ledger: store.ledger, announceURLTriggerCleared: { await announced.add($0) })
        }
        configured.irisPaths = IrisPaths(root: irisRoot)
        configured.homeDirectory = base.appendingPathComponent("home").path
        configured.watchBreakerProvider = { 30 }
        let executor = configured
        let conversation = UUID()
        func register(_ instructions: String) async -> String {
            await executor.execute(name: "register_directory_watcher",
                                   args: ["path": .string(notes.path), "instructions": .string(instructions)],
                                   conversationId: conversation)
        }

        _ = await register("summarise")
        let job = try #require(try store.ledger.jobs().first)
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: "d")

        let same = await register("summarise")
        #expect(!same.contains("URL trigger"), "re-stating the same watch changes nothing")
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == true)

        let changed = await register("summarise and file")
        #expect(changed.contains(ScheduleJobArguments.urlTriggerClearedNote(job.name)))
        #expect(try store.ledger.job(id: job.id)?.urlTrigger == false)
        #expect(await announced.names == [job.name])
    }

    @Test("/jobs reschedule keeps it")
    func jobsRescheduleKeeps() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        let job = Job(name: "pr-sweep", prompt: "sweep", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: "d")

        app.sendMessage("/jobs reschedule pr-sweep 0 9 * * *")

        #expect(try store.ledger.job(id: job.id)?.urlTrigger == true)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh URLTriggerClearTests`. Expected: the build fails with "type 'ScheduleJobArguments' has no member 'urlTriggerClearedNote'".

- [ ] **Step 3: Implement.** In `ScheduleJobArguments.swift`, after `replacedNote`:

```swift
    /// D6 decision 11: what the model is told when its change turned a job's URL trigger off.
    static func urlTriggerClearedNote(_ name: String) -> String {
        "The URL trigger for '\(name)' was turned off, because what the job does changed; only the owner can turn it back on."
    }
```

In `AppState.swift`, beside the `/jobs` handler:

```swift
    /// D6 decision 11's line in Iris, when a change turned a job's URL trigger off.
    nonisolated static func urlTriggerClearedLine(_ name: String) -> String {
        "URL trigger for \(name) turned off: the job was changed. `/jobs url \(name) on` makes a new link."
    }

    func announceURLTriggerCleared(jobName: String) {
        appendMessage(role: .system, content: Self.urlTriggerClearedLine(jobName), to: activityConversationId())
    }
```

In `JobScheduler.swift`, replace `schedule(_:)` with:

```swift
    /// Stores `job` with its first fire computed, and returns what was stored. A cadence that
    /// matches nothing is stored paused rather than silently never running.
    @discardableResult
    func schedule(_ job: Job) async throws -> Job {
        try await scheduleReporting(job).job
    }

    /// `schedule`, plus whether the write turned the job's URL trigger off (D6 decision 11).
    func scheduleReporting(_ job: Job) async throws -> (job: Job, urlTriggerCleared: Bool) {
        var stored = job
        if let cadence = Self.cadence(of: job.trigger) {
            stored.nextFireAt = cadence.next(after: now())
            if stored.nextFireAt == nil { stored.pausedReason = Self.unmatchableReason }
        }
        let outcome = try ledger.upsert(stored)
        return (stored, outcome.urlTriggerCleared)
    }
```

In `iris.swift`'s `scheduleJob`, replace the `do` block's store (`:2894-2898`) with:

```swift
                do {
                    // Stored through the scheduler, not the ledger, so the first fire is computed
                    // by the code the polling loop uses — and a cadence that matches nothing comes
                    // back paused rather than looking scheduled.
                    let scheduled = try await scheduler.scheduleReporting(job)
                    var said = notes
                    if scheduled.urlTriggerCleared {
                        said.append(ScheduleJobArguments.urlTriggerClearedNote(scheduled.job.name))
                        let name = scheduled.job.name
                        await MainActor.run { localState?.announceURLTriggerCleared(jobName: name) }
                    }
                    return ScheduleJobArguments.resultSentence(for: scheduled.job, notes: said)
                } catch {
```

In `ToolExecutor.swift`, give `JobTools` the announcer:

```swift
struct JobTools: Sendable {
    let ledger: JobLedger
    /// D6 decision 11: tells the owner, in Iris, that a watch update turned a job's URL trigger
    /// off. nil where there is no app to tell (a test, a throwaway executor).
    var announceURLTriggerCleared: (@Sendable (String) async -> Void)? = nil
}
```

In `registerWatcher`, replace `try tools.ledger.upsert(job)` with `let outcome = try tools.ledger.upsert(job)`, and directly before `return sentences.joined(separator: " ")` add:

```swift
            if outcome.urlTriggerCleared {
                sentences.append(ScheduleJobArguments.urlTriggerClearedNote(job.name))
                await tools.announceURLTriggerCleared?(job.name)
            }
```

In `iris.swift`'s `jobToolsProvider()`:

```swift
    private func jobToolsProvider() -> @Sendable () async -> JobTools? {
        { [weak state] in
            guard let ledger = await MainActor.run(resultType: JobLedger?.self,
                                                   body: { state?.store.ledger })
            else { return nil }
            return JobTools(ledger: ledger, announceURLTriggerCleared: { [weak state] name in
                await MainActor.run { state?.announceURLTriggerCleared(jobName: name) }
            })
        }
    }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 4 tests passed. Then run `timeout 300 scripts/test-filter.sh 'RegisterWatcherTests|GateCreationTests|ScheduleJobArgumentsTests|JobSchedulerTests|JobFireIntegrationTests|DailyDigestTests'`. If `DailyDigestTests` matches no type, drop it. Expected: every test passes. Quote both counts.

- [ ] **Step 5: Mutation check.** Delete the `if scheduled.urlTriggerCleared` block: `rescheduleClears` fails on the note and on the Iris line. Restore it.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/JobScheduler.swift Sources/IrisKit/iris.swift Sources/IrisKit/ToolExecutor.swift Sources/IrisKit/ScheduleJobArguments.swift Sources/IrisKit/AppState.swift Tests/irisTests/URLTriggerClearTests.swift`, then `git commit -m "feat(jobs): say so when a change turns a job's URL trigger off (D6 decision 11)"`.

### Task 20: `FireOrigin.url` and `runJobByHand`

**Files:**
- Modify: `Sources/IrisKit/JobRunner.swift:1964-1987` (`FireOrigin.url` and its `triggerKind`)
- Create: `Sources/IrisKit/RunJobByHand.swift`
- Modify: `Sources/IrisKit/AppState.swift:3845-3897` (`/jobs run` calls `runJobByHand`)
- Modify: `Sources/IrisKit/RunJobURL.swift` (the fire lines)
- Test: `Tests/irisTests/RunJobByHandTests.swift` (new)

**Interfaces:**
- Consumes: `JobLedger.urlTriggerKind` (Task 17) and `RunJobURL` (Task 18).
- Produces:
  - `FireOrigin.url`, whose `triggerKind` is `"url"`.
  - `AppState.runJobByHand(job: Job, origin: FireOrigin, announceTo: UUID) -> Task<JobRunner.Admission?, Never>?` (`@discardableResult`; nil when refused before firing).
  - `RunJobURL.firingLine(_:)`, `RunJobURL.firedLine(_:)` and `RunJobURL.notStartedLine(_:_:)`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/RunJobByHandTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 12: `/jobs run` and a URL fire share one body. A URL fire records `url`, skips
/// the gate like any hand-started fire, meets overlap and the budgets, and costs Iris one line.
@MainActor
@Suite("Run job by hand (D6)", .timeLimit(.minutes(1)))
struct RunJobByHandTests {
    private func polled() -> Job {
        Job(name: "poller", prompt: "Reply with just the word tick.",
            trigger: .poll(PollSpec(schedule: .interval(seconds: 60), gate: .urlChanged(url: "https://example.invalid/f"))))
    }

    @Test("a URL fire records url, and the gate never decides it")
    func originTable() {
        #expect(FireOrigin.url.triggerKind == "url")
        #expect(!JobRunner.gateApplies(origin: .url, job: polled()))
        #expect(!JobRunner.gateApplies(origin: .queued(from: .url), job: polled()))
    }

    private final class GateCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func bump() { lock.withLock { n += 1 } }
    }

    @Test("a URL fire of a gated job runs without asking the gate")
    func urlFireSkipsTheGate() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let client = FakeLLMClient(responses: [GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(text: "tick")]))], usageMetadata: nil)])
        let engine = IrisEngine(state: state, tier: .medium, client: client, retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0)
        let job = polled()
        try store.ledger.upsert(job)
        let name = "iris-byhand-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let calls = GateCalls()
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in },
                               config: ConfigManager(store: defaults), protectionEnabled: false,
                               gateEvaluator: { _, _ in calls.bump(); return .unchanged(signal: "etag=aaa") })

        #expect(await runner.fire(job: job, origin: .url) == .run)

        #expect(calls.count == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    private func makeApp() throws -> (ConversationStore, AppState, UUID) {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        return (store, app, app.activityConversationId())
    }

    private func systemLines(_ app: AppState, _ id: UUID) -> [String] {
        app.conversations.first { $0.id == id }?.messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    @Test("a URL fire posts one line, updated in place with what admission decided")
    func urlVoiceIsOneLine() async throws {
        let (store, app, iris) = try makeApp()
        // A built-in runs no model turn, so the fire is admitted without a paid call.
        let job = Job(name: "url-digest", prompt: "", trigger: .schedule(.interval(seconds: 86_400)),
                      action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)

        let task = try #require(app.runJobByHand(job: job, origin: .url, announceTo: iris))
        #expect(systemLines(app, iris) == [RunJobURL.firingLine("url-digest")])
        #expect(try await value(of: task) == .run)

        #expect(systemLines(app, iris) == [RunJobURL.firedLine("url-digest")])
        #expect(app.conversations.first { $0.id == iris }?.messages.contains { $0.role == .command } == false)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.triggerKind == "url")
    }

    @Test("a paused job is refused before anything fires, in one line")
    func pausedURLVoice() throws {
        let (store, app, iris) = try makeApp()
        let job = Job(name: "stopped", prompt: "", trigger: .schedule(.interval(seconds: 60)),
                      pausedReason: JobRunner.breakerReason(count: 6), action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)

        #expect(app.runJobByHand(job: job, origin: .url, announceTo: iris) == nil)
        #expect(systemLines(app, iris) == [RunJobURL.notStartedLine("stopped", "it is paused")])
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh RunJobByHandTests`. Expected: the build fails with "type 'FireOrigin' has no member 'url'".

- [ ] **Step 3: Implement.** In `JobRunner.swift`'s `FireOrigin`, after `case manual`:

```swift
    /// An `iris://run-job/<token>` link (D6 decision 12). Admitted like `.manual`: it skips the
    /// gate, which only `.cadence` meets, and meets overlap and the budgets.
    case url
```

Then in `triggerKind`, add `case .url: return JobLedger.urlTriggerKind`.

In `RunJobURL.swift`, add:

```swift
    /// Plan note 9: a URL fire costs Iris one line, posted now and updated when admission answers.
    static func firingLine(_ name: String) -> String { "Firing \(name) from a URL …" }
    static func firedLine(_ name: String) -> String { "Fired \(name) from a URL; the result arrives as a card." }
    static func notStartedLine(_ name: String, _ why: String) -> String {
        "Refused a URL fire of \(name): it was not started, because \(why)."
    }
```

Create `Sources/IrisKit/RunJobByHand.swift`:

```swift
import Foundation

extension AppState {
    /// A fire a person, or a link they made, asked for (D6 decision 12): the body `/jobs run`
    /// used to own, so both callers meet the same checks. Through `fire`, not `run`, so it meets
    /// the overlap, breaker and budget checks a scheduled fire does. It skips the gate, which only
    /// a cadence meets. Returns nil when it refused before firing.
    ///
    /// `/jobs run` speaks in command output, as before. A URL fire speaks in one system line in
    /// `conversationId` (Iris), updated in place once admission answers.
    @discardableResult
    func runJobByHand(job: Job, origin: FireOrigin, announceTo conversationId: UUID) -> Task<JobRunner.Admission?, Never>? {
        let byURL = origin == .url
        // Admission drops a paused or disabled job without a word, and both are states the user
        // has to undo before a hand-started fire can do anything. Saying so before anything is
        // started is the difference between a command that did nothing and one that looks like
        // it worked.
        if job.pausedReason != nil || !job.enabled {
            let refusal = JobRunner.refusalText(job.pausedReason != nil ? .dropPaused : .dropDisabled) ?? ""
            if byURL {
                appendMessage(role: .system, content: RunJobURL.notStartedLine(job.name, refusal), to: conversationId)
            } else if job.pausedReason != nil {
                emitCommandOutput("'\(job.name)' is paused (\(job.pausedReason ?? "")); `/jobs resume \(job.name)` first.",
                                  format: .markdown, to: conversationId)
            } else {
                emitCommandOutput("'\(job.name)' is disabled.", format: .markdown, to: conversationId)
            }
            return nil
        }
        // Said before anything is attempted, because admission only answers when the fire is
        // over, and a run can take minutes.
        let lineId = UUID()
        if byURL {
            appendMessage(role: .system, content: RunJobURL.firingLine(job.name), id: lineId, to: conversationId)
        } else {
            emitCommandOutput("Starting **\(job.name)** …", format: .markdown, to: conversationId)
        }
        let engine = self.engine
        return Task { [weak self] in
            guard let runner = await engine?.jobRunner() else {
                // No engine means no runner and no turn: the app has not finished wiring itself
                // up, or is shutting down.
                self?.finishHandFire(byURL ? RunJobURL.notStartedLine(job.name, JobRunner.runnerUnavailableRefusal)
                                           : "Jobs are not available yet.",
                                     byURL: byURL, lineId: lineId, to: conversationId)
                return nil
            }
            let admission = await runner.fire(job: job, origin: origin)
            guard let self else { return admission }
            let text: String
            if admission == nil {
                text = byURL ? RunJobURL.notStartedLine(job.name, "it is no longer in the jobs table")
                             : "'\(job.name)' is no longer in the jobs table."
            } else if let refusal = admission.flatMap(JobRunner.refusalText) {
                text = byURL ? RunJobURL.notStartedLine(job.name, refusal)
                             : "**\(job.name)** was not started: \(refusal)."
            } else {
                text = byURL ? RunJobURL.firedLine(job.name) : "Fired **\(job.name)**; the result arrives as a card."
            }
            self.finishHandFire(text, byURL: byURL, lineId: lineId, to: conversationId)
            return admission
        }
    }

    private func finishHandFire(_ text: String, byURL: Bool, lineId: UUID, to conversationId: UUID) {
        if byURL {
            updateMessageContent(id: lineId, content: text, in: conversationId, persist: true)
        } else {
            emitCommandOutput(text, format: .markdown, to: conversationId)
        }
    }
}
```

In `AppState.handleJobsCommand`, replace the `.run` branch's body after `guard let job = …` (`:3851-3892`) with one call:

```swift
                runJobByHand(job: job, origin: .manual, announceTo: convId)
```

`private var engine` is visible to `RunJobByHand.swift` only if it is not `private`. Change `private var engine: IrisEngine!` (`AppState.swift:908`) to `private(set) var engine: IrisEngine!`.

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 5 tests passed. Then run `timeout 300 scripts/test-filter.sh 'JobRetryTests|JobsCommandTests|RunJobCLITests'`. Expected: every test passes, `/jobs run`'s existing wording tests (`JobRetryTests:267-309`) included. Quote both counts.

- [ ] **Step 5: Mutation check.** Change `FireOrigin.url`'s `triggerKind` to `"manual"`: `originTable` and `urlVoiceIsOneLine` fail. Restore it.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/JobRunner.swift Sources/IrisKit/RunJobByHand.swift Sources/IrisKit/RunJobURL.swift Sources/IrisKit/AppState.swift Tests/irisTests/RunJobByHandTests.swift`, then `git commit -m "feat(jobs): FireOrigin.url and runJobByHand, shared with /jobs run (D6 decision 12)"`.

### Task 21: `RunJobURL.parse` and `handleRunJobURL`, with the limit and the coalesced refusals

**Files:**
- Modify: `Sources/IrisKit/RunJobURL.swift` (parse, refusals, reasons, the refusal line, `URLRefusalLine`)
- Create: `Sources/IrisKit/RunJobURLHandling.swift` (the `AppState` extension)
- Modify: `Sources/IrisKit/AppState.swift` (stored properties after `pendingApprovals`: `urlRefusalLines`, `urlClock`, `urlFireTask`)
- Test: `Tests/irisTests/RunJobURLTests.swift` (new)

**Interfaces:**
- Consumes:
  - `URLTriggerToken` and `BuildIdentity.urlScheme` (Task 18).
  - `JobLedger.job(urlTokenHash:)` and `urlFires` (Task 17).
  - `runJobByHand` and the fire lines (Task 20).
- Produces:
  - `RunJobURL.Refusal: Error, Equatable, Sendable` with the cases `otherScheme`, `wrongHost`, `hasQuery`, `hasFragment`, `wrongPath` and `malformedToken`, each with a `sentence`.
  - `RunJobURL.parse(_ url: URL, identity: BuildIdentity) -> Result<String, Refusal>`.
  - `RunJobURL.window = 3600`, the reason constants, and `refusalLine(subject:reason:count:)`.
  - `struct URLRefusalLine: Sendable`.
  - `AppState.RunJobURLOutcome: Equatable, Sendable` with `.fired(UUID)`, `.refused` and `.deferred(UUID)`.
  - `AppState.handleRunJobURL(_:identity:) -> RunJobURLOutcome` (`@discardableResult`).
  - `AppState.urlClock`, `AppState.urlFireTask` and `AppState.urlRefusalLines`.
  - `AppState.urlFireRefusal(for:) -> String?`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/RunJobURLTests.swift`:

```swift
import Testing
import Foundation
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
        for line in lines { for t in [minted, current, pausedToken, disabledToken] { #expect(!line.contains(t)) } }
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
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh RunJobURLTests`. Expected: the build fails with "type 'RunJobURL' has no member 'parse'".

- [ ] **Step 3: Implement the parser.** In `RunJobURL.swift`, add these members inside `enum RunJobURL`, beside the ones Tasks 18 and 20 put there:

```swift
    static let window: TimeInterval = 3_600

    /// Why a link was refused before any job was looked up. A fixed sentence each: the link is
    /// unauthenticated input, so no part of it is echoed into Iris.
    enum Refusal: Error, Equatable, Sendable {
        case otherScheme, wrongHost, hasQuery, hasFragment, wrongPath, malformedToken

        var sentence: String {
            switch self {
            case .otherScheme: return "the link is for the other Iris build"
            case .wrongHost: return "the link is not a run-job link"
            case .hasQuery, .hasFragment: return "run-job links take no input, and this one carried some"
            case .wrongPath: return "the link has something other than one token after run-job/"
            case .malformedToken: return "the link's token is not one Iris made; a job's id or name does not work, and `/jobs url <name> on` makes a link"
            }
        }
    }

    /// The token, or why the link is refused (decision 12): this build's scheme, the `run-job`
    /// host (in any case, as hosts are), no user, password, port, query or fragment, and exactly
    /// one path component that is a well-formed token.
    static func parse(_ url: URL, identity: BuildIdentity) -> Result<String, Refusal> {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == identity.urlScheme else { return .failure(.otherScheme) }
        guard parts.user == nil, parts.password == nil, parts.port == nil,
              parts.host?.lowercased() == host else { return .failure(.wrongHost) }
        guard parts.percentEncodedQuery == nil else { return .failure(.hasQuery) }
        guard parts.percentEncodedFragment == nil else { return .failure(.hasFragment) }
        let path = parts.percentEncodedPath
        guard path.hasPrefix("/") else { return .failure(.wrongPath) }
        let token = String(path.dropFirst())
        guard !token.isEmpty, !token.contains("/") else { return .failure(.wrongPath) }
        guard URLTriggerToken.isWellFormed(token) else { return .failure(.malformedToken) }
        return .success(token)
    }

    static let unknownTokenReason = "the link matches no job's URL trigger; it may have been turned off or replaced"
    static let ledgerUnreadableReason = "the jobs table could not be read"
    static let overLimitReason = "URL fires are limited to \(maxFiresPerHour) an hour per job"
    static let disabledReason = "it is disabled"
    static func triggerOffReason(_ name: String) -> String { "\(name) has URL triggers off" }
    static func pausedReason(_ job: Job) -> String {
        "it is paused (\(job.pausedReason ?? "")); `/jobs resume \(job.name)` first"
    }

    /// One refusal line, or the running count of a coalesced one (decision 13, plan note 8).
    static func refusalLine(subject: String?, reason: String, count: Int) -> String {
        let of = subject.map { " of \($0)" } ?? ""
        if count <= 1 { return "Refused a URL fire\(of): \(reason)." }
        return "Refused \(count) URL fires\(of) in the last hour. The latest: \(reason)."
    }
```

Then, at file scope after the enum:

```swift
/// The line a coalesced URL refusal keeps updating, by job id or `unmatched`.
struct URLRefusalLine: Sendable {
    let messageId: UUID
    let since: Date
    var count: Int
    let conversationId: UUID
}
```

- [ ] **Step 4: Implement the handler.** In `AppState.swift`, after `pendingApprovals` and its notification properties, or after `pendingApprovals` alone if PR C has not merged:

```swift
    /// D6 decisions 12-13: one refusal line per job (or per `unmatched`) per hour, updated with a
    /// running count. Written only by `refuseURLFire`.
    @ObservationIgnored var urlRefusalLines: [String: URLRefusalLine] = [:]
    /// The clock the URL limit, the coalescing window and the deferral read. A seam for tests.
    @ObservationIgnored var urlClock: @Sendable () -> Date = { Date() }
    /// Test seam: the most recent URL fire, so a test can await it.
    @ObservationIgnored var urlFireTask: Task<JobRunner.Admission?, Never>?
```

Create `Sources/IrisKit/RunJobURLHandling.swift`:

```swift
import Foundation

extension AppState {
    enum RunJobURLOutcome: Equatable, Sendable {
        case fired(UUID)
        case refused
        case deferred(UUID)
    }

    /// An `iris://run-job/<token>` link (D6 decision 12): parse, hash, look up, apply the URL
    /// limit, defer behind a foreign store holder or fire, and say which in Iris. It never
    /// creates, edits, resumes or unpauses a job; no route for those exists. No part of the link
    /// reaches a model. Callable from a test, with no GUI.
    @discardableResult
    func handleRunJobURL(_ url: URL, identity: BuildIdentity = .current) -> RunJobURLOutcome {
        let iris = activityConversationId()
        let token: String
        switch RunJobURL.parse(url, identity: identity) {
        case .failure(let refusal):
            refuseURLFire(job: nil, reason: refusal.sentence, to: iris)
            return .refused
        case .success(let parsed):
            token = parsed
        }
        let job: Job?
        do {
            job = try store.ledger.job(urlTokenHash: URLTriggerToken.digest(token))
        } catch {
            refuseURLFire(job: nil, reason: RunJobURL.ledgerUnreadableReason, to: iris)
            return .refused
        }
        guard let job else {
            refuseURLFire(job: nil, reason: RunJobURL.unknownTokenReason, to: iris)
            return .refused
        }
        if let reason = urlFireRefusal(for: job) {
            refuseURLFire(job: job, reason: reason, to: iris)
            return .refused
        }
        guard let task = runJobByHand(job: job, origin: .url, announceTo: iris) else { return .refused }
        urlFireTask = task
        return .fired(job.id)
    }

    /// Why `job` may not be fired by a link right now, or nil. Asked when the link arrives and
    /// again when a deferred fire comes due. Decision 13: the limit is checked before admission,
    /// so a refused link writes no row, never counts toward the breaker and never pauses the job.
    func urlFireRefusal(for job: Job) -> String? {
        guard job.urlTrigger else { return RunJobURL.triggerOffReason(job.name) }
        if job.pausedReason != nil { return RunJobURL.pausedReason(job) }
        if !job.enabled { return RunJobURL.disabledReason }
        let since = urlClock().addingTimeInterval(-RunJobURL.window)
        guard let fires = try? store.ledger.urlFires(jobId: job.id, since: since) else {
            return RunJobURL.ledgerUnreadableReason
        }
        return fires >= RunJobURL.maxFiresPerHour ? RunJobURL.overLimitReason : nil
    }

    /// Says a refusal in Iris, coalesced (plan note 8): the first in an hour is a line, and each
    /// later one updates that line's count, so a flood cannot fill the conversation.
    func refuseURLFire(job: Job?, reason: String, to iris: UUID) {
        let key = job?.id.uuidString ?? "unmatched"
        let now = urlClock()
        if var entry = urlRefusalLines[key], entry.conversationId == iris,
           now.timeIntervalSince(entry.since) < RunJobURL.window,
           conversations.first(where: { $0.id == iris })?.messages.contains(where: { $0.id == entry.messageId }) == true {
            entry.count += 1
            urlRefusalLines[key] = entry
            updateMessageContent(id: entry.messageId,
                                 content: RunJobURL.refusalLine(subject: job?.name, reason: reason, count: entry.count),
                                 in: iris, persist: true)
            return
        }
        let id = UUID()
        appendMessage(role: .system, content: RunJobURL.refusalLine(subject: job?.name, reason: reason, count: 1),
                      id: id, to: iris)
        urlRefusalLines[key] = URLRefusalLine(messageId: id, since: now, count: 1, conversationId: iris)
    }
}
```

Task 22 inserts the foreign-holder wait between the refusal check and the fire.

- [ ] **Step 5: Run them and watch them pass.** Run the same filter. Expected: 9 tests passed. Quote the count.

- [ ] **Step 6: Mutation checks (the URL limit never counts toward the breaker).** Make each change, run the filter, see the named test fail, then restore.
  - Delete the limit line in `urlFireRefusal`: `fourthIsRefused` fails, because a fourth row is written.
  - Make the over-limit branch also call `try? store.ledger.setPaused(jobId: job.id, reason: "url limit")`: `fourthIsRefused` fails on `pausedReason`.
  - Make `refuseURLFire` always append: `garbageFloodIsOneLine` and `overLimitFloodIsOneLine` fail.
  - Make `unknownTokenReason` interpolate the token (pass it through): `refusalsWriteNoRow` fails on the echo check.

- [ ] **Step 7: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 8: Commit.** `git add Sources/IrisKit/RunJobURL.swift Sources/IrisKit/RunJobURLHandling.swift Sources/IrisKit/AppState.swift Tests/irisTests/RunJobURLTests.swift`, then `git commit -m "feat(jobs): parse and fire run-job links, limited to 3 an hour, refusals coalesced (D6 decisions 12, 13)"`.

### Task 22: Defer a URL fire while a foreign process holds the store

**Files:**
- Modify: `Sources/IrisKit/RunJobCLI.swift:45-70` (`GUILock.isAlive`, which `read` uses)
- Modify: `Sources/IrisKit/RunJobURL.swift` (`URLDeferral`, `URLDeferralTimer`, `PendingURLFire` and the wait lines)
- Modify: `Sources/IrisKit/RunJobURLHandling.swift` (the holder check in `handleRunJobURL`; add `deferURLFire` and `recheckDeferredURLFire`)
- Modify: `Sources/IrisKit/AppState.swift` (`foreignStoreHolder`, `isProcessAlive`, `urlDeferralTimer` and `pendingURLFires`, after Task 21's URL properties)
- Test: `Tests/irisTests/RunJobURLDeferralTests.swift` (new)

**Interfaces:**
- Consumes: `handleRunJobURL`, `urlFireRefusal(for:)`, `urlFireTask` and `urlClock` (Task 21). `runJobByHand` (Task 20).
- Produces:
  - `GUILock.isAlive(_ pid: Int32) -> Bool`.
  - `enum URLDeferral` with `Step` (`.wait`, `.fire` or `.giveUp`), `interval = 5`, `deadline = 600` and `decide(holderAlive:waited:) -> Step`.
  - `struct URLDeferralTimer: Sendable` with `schedule` and `static let dispatch`.
  - `struct PendingURLFire: Sendable`.
  - `AppState.foreignStoreHolder: Int32?` and `AppState.isProcessAlive: @Sendable (Int32) -> Bool`, which D2's Task 26 sets at launch.
  - `AppState.urlDeferralTimer`, `AppState.pendingURLFires`, `AppState.deferURLFire(_:holder:to:)` and `AppState.recheckDeferredURLFire(_ jobId: UUID)`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/RunJobURLDeferralTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 14: while another Iris process holds the store, a URL fire waits, visibly,
/// re-checking every 5 s, fires once the holder is gone, and gives up after 10 minutes with "try
/// again". It is never refused silently.
@MainActor
@Suite("Run-job URL deferral (D6)", .timeLimit(.minutes(1)))
struct RunJobURLDeferralTests {
    @MainActor
    private final class ManualTimer {
        var pending: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        func fireNext() {
            let (_, body) = pending.removeFirst()
            body()
        }
    }

    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var on = true
        var value: Bool { lock.withLock { on } }
        func set(_ v: Bool) { lock.withLock { on = v } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    private struct Fixture {
        let store: ConversationStore
        let app: AppState
        let iris: UUID
        let job: Job
        let link: URL
        let timer: ManualTimer
        let alive: Switch
        let clock: Clock
    }

    private func fixture() throws -> Fixture {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.selectedConversationId = app.createNewConversation()
        let job = Job(name: "url-digest", prompt: "", trigger: .schedule(.interval(seconds: 86_400)),
                      action: .builtin(DailyDigest.name))
        try store.ledger.upsert(job)
        let minted = try #require(URLTriggerToken.generate())
        try store.ledger.setURLTrigger(jobId: job.id, tokenHash: URLTriggerToken.digest(minted))
        let timer = ManualTimer(), alive = Switch(), clock = Clock()
        app.foreignStoreHolder = 4242
        app.isProcessAlive = { _ in alive.value }
        app.urlDeferralTimer = URLDeferralTimer { delay, body in timer.pending.append((delay, body)) }
        app.urlClock = { clock.now }
        return Fixture(store: store, app: app, iris: app.activityConversationId(), job: job,
                       link: URL(string: RunJobURL.url(token: minted, identity: .dev))!,
                       timer: timer, alive: alive, clock: clock)
    }

    private func lines(_ f: Fixture) -> [String] {
        f.app.conversations.first { $0.id == f.iris }?.messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    @Test("the decision is pure: a dead holder fires, a live one waits until the deadline")
    func decide() {
        #expect(URLDeferral.decide(holderAlive: false, waited: 0) == .fire)
        #expect(URLDeferral.decide(holderAlive: true, waited: 595) == .wait)
        #expect(URLDeferral.decide(holderAlive: true, waited: 600) == .giveUp)
        #expect(URLDeferral.decide(holderAlive: false, waited: 600) == .fire, "gone at the deadline still fires")
    }

    @Test("with a live holder the fire waits with a line, and fires once the holder is gone")
    func waitsThenFires() async throws {
        let f = try fixture()

        #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .deferred(f.job.id))
        #expect(lines(f) == [RunJobURL.waitingLine("url-digest", pid: 4242)])
        #expect(f.timer.pending.map(\.0) == [URLDeferral.interval])
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)

        f.clock.advance(5)
        f.timer.fireNext()                  // still alive: wait again
        #expect(f.timer.pending.count == 1)

        f.alive.set(false)
        f.clock.advance(5)
        f.timer.fireNext()
        _ = try await value(of: try #require(f.app.urlFireTask))

        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).map(\.triggerKind) == ["url"])
        #expect(lines(f).first == RunJobURL.waitEndedLine("url-digest", pid: 4242))
        #expect(f.app.foreignStoreHolder == nil)
    }

    @Test("a second link while one waits joins the wait")
    func secondLinkJoins() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        #expect(f.app.handleRunJobURL(f.link, identity: .dev) == .deferred(f.job.id))
        #expect(lines(f).count == 1)
        #expect(f.timer.pending.count == 1)
    }

    @Test("after 10 minutes it gives up and says try again")
    func givesUp() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        for _ in 0..<119 {
            f.clock.advance(5)
            f.timer.fireNext()
        }
        #expect(f.timer.pending.count == 1)
        f.clock.advance(5)
        f.timer.fireNext()

        #expect(f.timer.pending.isEmpty)
        #expect(lines(f) == [RunJobURL.gaveUpLine("url-digest", pid: 4242)])
        #expect(lines(f).first?.contains("try again after the other Iris process finishes") == true)
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)
        #expect(f.app.pendingURLFires.isEmpty)
    }

    @Test("a job deleted or turned off while it waited is not fired")
    func changedWhileWaiting() throws {
        let f = try fixture()
        f.app.handleRunJobURL(f.link, identity: .dev)
        try f.store.ledger.setURLTrigger(jobId: f.job.id, tokenHash: nil)
        f.alive.set(false)
        f.timer.fireNext()
        #expect(lines(f).first?.contains("has URL triggers off") == true)
        #expect(try f.store.ledger.runs(jobId: f.job.id, limit: 5).isEmpty)

        let g = try fixture()
        g.app.handleRunJobURL(g.link, identity: .dev)
        try g.store.ledger.delete(jobId: g.job.id)
        g.alive.set(false)
        g.timer.fireNext()
        #expect(lines(g).first?.contains("deleted") == true)
    }

    @Test("GUILock.isAlive knows this process, and a reaped child is gone")
    func liveness() throws {
        #expect(GUILock.isAlive(ProcessInfo.processInfo.processIdentifier))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!GUILock.isAlive(child.processIdentifier))
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh RunJobURLDeferralTests`. Expected: the build fails with "cannot find 'URLDeferral' in scope".

- [ ] **Step 3: Implement.** In `RunJobCLI.swift`'s `GUILock`, add the helper and make the end of `read(_:)` use it:

```swift
    /// Whether `pid` names a live process. Signal 0 asks the kernel without sending anything;
    /// `EPERM` means it exists and belongs to somebody else, which is still alive.
    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
```

```swift
        return isAlive(pid) ? .live(pid) : .dead
```

In `RunJobURL.swift`, at file scope:

```swift
/// D6 decision 14's wait for a foreign store holder. Pure.
enum URLDeferral {
    enum Step: Equatable, Sendable { case wait, fire, giveUp }

    static let interval: TimeInterval = 5
    static let deadline: TimeInterval = 600

    static func decide(holderAlive: Bool, waited: TimeInterval) -> Step {
        if !holderAlive { return .fire }
        return waited >= deadline ? .giveUp : .wait
    }
}

/// How the re-check is scheduled: on a dispatch queue, never `Task.sleep` on the cooperative pool
/// (the invariant 4 rule). A seam so a test can fire it by hand.
struct URLDeferralTimer: Sendable {
    let schedule: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    static let dispatch = URLDeferralTimer { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
    }
}

/// A URL fire waiting for a foreign store holder to finish. One per job.
struct PendingURLFire: Sendable {
    let jobId: UUID
    let jobName: String
    let holder: Int32
    let since: Date
    let lineId: UUID
    let conversationId: UUID
}
```

In `enum RunJobURL`:

```swift
    static func waitingLine(_ name: String, pid: Int32) -> String {
        "Waiting for the other Iris process (pid \(pid)) to finish before firing \(name)."
    }
    static func waitEndedLine(_ name: String, pid: Int32) -> String {
        "The other Iris process (pid \(pid)) finished; firing \(name) from the link that was waiting."
    }
    static func gaveUpLine(_ name: String, pid: Int32) -> String {
        "Did not fire \(name) from a link: the other Iris process (pid \(pid)) was still running after 10 minutes. Open the link again; try again after the other Iris process finishes."
    }
    static func waitAbandonedLine(_ name: String, reason: String) -> String {
        "Did not fire \(name) from the link that was waiting: \(reason)."
    }
```

In `AppState.swift`, after Task 21's URL properties:

```swift
    /// D6 decision 14: a live Iris process that held the store at launch (a `--run-job`), read
    /// before this app took the lock. A URL fire waits while it lives. nil once it has gone.
    @ObservationIgnored var foreignStoreHolder: Int32?
    @ObservationIgnored var isProcessAlive: @Sendable (Int32) -> Bool = { GUILock.isAlive($0) }
    @ObservationIgnored var urlDeferralTimer = URLDeferralTimer.dispatch
    @ObservationIgnored var pendingURLFires: [UUID: PendingURLFire] = [:]
```

In `RunJobURLHandling.swift`'s `handleRunJobURL`, insert this between the `urlFireRefusal` check and `guard let task = runJobByHand(…)`:

```swift
        if let holder = foreignStoreHolder {
            if isProcessAlive(holder) {
                deferURLFire(job, holder: holder, to: iris)
                return .deferred(job.id)
            }
            // Gone since launch: never asked about again, so a reused pid cannot hold fires back.
            foreignStoreHolder = nil
        }
```

Then add to the extension:

```swift
    /// Waits, visibly, for the foreign holder to finish (decision 14). One wait per job: a
    /// second link joins it (plan note 10).
    func deferURLFire(_ job: Job, holder: Int32, to iris: UUID) {
        guard pendingURLFires[job.id] == nil else { return }
        let lineId = UUID()
        appendMessage(role: .system, content: RunJobURL.waitingLine(job.name, pid: holder), id: lineId, to: iris)
        pendingURLFires[job.id] = PendingURLFire(jobId: job.id, jobName: job.name, holder: holder,
                                                 since: urlClock(), lineId: lineId, conversationId: iris)
        scheduleURLRecheck(job.id)
    }

    private func scheduleURLRecheck(_ jobId: UUID) {
        urlDeferralTimer.schedule(URLDeferral.interval) { [weak self] in self?.recheckDeferredURLFire(jobId) }
    }

    /// One re-check of a waiting fire. When it fires, the job is read again and asked every
    /// question a fresh link would be: it may have been deleted, paused or turned off, or have
    /// reached its limit, while it waited.
    func recheckDeferredURLFire(_ jobId: UUID) {
        guard let pending = pendingURLFires[jobId] else { return }
        switch URLDeferral.decide(holderAlive: isProcessAlive(pending.holder),
                                  waited: urlClock().timeIntervalSince(pending.since)) {
        case .wait:
            scheduleURLRecheck(jobId)
        case .giveUp:
            pendingURLFires[jobId] = nil
            updateMessageContent(id: pending.lineId, content: RunJobURL.gaveUpLine(pending.jobName, pid: pending.holder),
                                 in: pending.conversationId, persist: true)
        case .fire:
            pendingURLFires[jobId] = nil
            foreignStoreHolder = nil
            guard let job = try? store.ledger.job(id: jobId) else {
                updateMessageContent(id: pending.lineId,
                                     content: RunJobURL.waitAbandonedLine(pending.jobName, reason: "it was deleted while it waited"),
                                     in: pending.conversationId, persist: true)
                return
            }
            if let reason = urlFireRefusal(for: job) {
                updateMessageContent(id: pending.lineId, content: RunJobURL.waitAbandonedLine(job.name, reason: reason),
                                     in: pending.conversationId, persist: true)
                return
            }
            updateMessageContent(id: pending.lineId, content: RunJobURL.waitEndedLine(job.name, pid: pending.holder),
                                 in: pending.conversationId, persist: true)
            urlFireTask = runJobByHand(job: job, origin: .url, announceTo: pending.conversationId)
        }
    }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 6 tests passed. Then run `timeout 300 scripts/test-filter.sh 'RunJobURLTests|RunJobCLITests'`. Expected: every test passes, so `GUILock`'s refactor kept the lock's behaviour. Quote both counts.

- [ ] **Step 5: Mutation check.** In `handleRunJobURL`, replace `if isProcessAlive(holder) {` with `if false {`: `waitsThenFires` fails, because the fire runs at once behind a live holder. Restore it.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/RunJobCLI.swift Sources/IrisKit/RunJobURL.swift Sources/IrisKit/RunJobURLHandling.swift Sources/IrisKit/AppState.swift Tests/irisTests/RunJobURLDeferralTests.swift`, then `git commit -m "feat(jobs): defer a URL fire while another Iris process holds the store (D6 decision 14)"`.

### Task 23: Invariant 9 sweep, and open PR D1

**Files:**
- Modify: `docs/jobs.md` (`/jobs` table at `:1061`, "The job tools" at `:1148`, a new section "Firing a job from a link")
- Modify: `Sources/IrisKit/iris.swift` (agent-facing strings, if the search finds any falsified)

- [ ] **Step 1: Search, do not compose.**
  - Run `grep -rn -i "trigger kind\|triggerKind\|\"manual\"\|/jobs run\|re-schedul\|replaces\|list_jobs" docs/jobs.md README.md Sources/IrisKit/iris.swift Sources/IrisKit/ToolExecutor.swift Sources/IrisKit/ScheduleJobArguments.swift Sources/IrisKit/JobsCommand.swift`, and read every hit.
  - Any sentence that lists the trigger kinds a row can record now misses `url`, and any sentence that says `/jobs run` is the only hand-started fire is false. Fix each one.
  - `list_jobs`' description already gained `urlTrigger` in Task 18.
  - Per plan note 7, the `schedule_job` and `register_directory_watcher` declarations do not change, unless the search finds a sentence there that the clear makes false.
  - Record the findings in the commit body.

- [ ] **Step 2: Add what is new.**
  - Add a `/jobs` table row: ``| `/jobs url <name> [on\|off]` | `on` makes a link that fires the job, `iris://run-job/<token>` (`iris-dev://` for a dev build), shown once; `on` again replaces it; `off` retires it; the bare form says whether it is on. Changing the job's prompt, profile or policy turns it off. Until the app registers the scheme (D6 PR D2), nothing opens the link |``.
  - In "The job tools", add `urlTrigger` to `list_jobs`' field list: "(whether a link may fire it; the token itself is never shown)".
  - Add a section before "## Retention":

```markdown
## Firing a job from a link (`/jobs url`)

A job can be fired from Shortcuts, Raycast or anything else that opens a URL, once you have turned
its link on with `/jobs url <name> on`. Only you can do that: no tool sets it, and `/jobs` is typed
in the composer. The reply shows the link once. Iris keeps only a hash of it, so it cannot show it
again; `on` again makes a new one and kills the old.

Opening the link fires the job exactly as `/jobs run` would: the gate is skipped, and overlap, the
breaker and the budgets apply. The run's row says `url`. Every fire and every refusal says so in
Iris. Repeated refusals of one job, or of links that match no job, update one line with a count
rather than adding a line each. A link carries no input, so nothing in it reaches a model.

At most three links fire a job in any hour. A fourth is refused before admission: it writes no
row, never counts toward the breaker and never pauses the job, so a page that keeps opening the
link cannot stop your job. If `schedule_job` or `register_directory_watcher` changes what the job
does (its prompt, profile, grant or budgets), the link is turned off, and Iris says so.

If the app is launched by a link while `iris --run-job` holds the store, the fire waits, and says
it is waiting, until that process finishes. It re-checks every five seconds and gives up after ten
minutes. Until the app registers the scheme (D6 PR D2), nothing opens the link.
```

- [ ] **Step 3: Full suite.** Run `timeout 900 swift test` (all three markers), then `scripts/check-warnings.sh`.

- [ ] **Step 4: Commit, push and open PR D1.** Run `git commit -am "docs: /jobs url and run-job links (D6)"` and `git push -u origin feat/agency6-url-trigger`. Then run `gh api repos/sackheads/iris/pulls -f base=main -f head=feat/agency6-url-trigger -f title="feat: agency D6 PR D1, the URL trigger without a scheme" -F body=@<file>`. The body lists Tasks 17-23, says that D1 has no GUI pass and that D2 registers the scheme, and ends with the PR attribution lines.

---

## PR D2: the scheme, the launch path, and the window spike

Branch: `feat/agency6-url-scheme`, cut from `main` after PR D1 merges. Spec decision 12's scheme and decision 14's launch path. **Task 24 comes first and gates the rest.** Its answer picks between Task 26's two variants, or stops D2.

### Task 24: The window spike (`work`, under the lease; gates D2)

The question, from spec §3: does SwiftUI's `WindowGroup` open a second window on an external URL, and does `.handlesExternalEvents(matching: [])` or `application(_:open:)` alone prevent it?

This runs on a scratch branch that is never pushed.

1. Run `git worktree add .worktrees/agency6-spike -b spike/agency6-url-window origin/main`, then run the `.sourcekit-lsp` step from AGENTS.md "Worktrees".
2. Apply the throwaway patch. Tasks 25 and 26 add the same lines for real.
   - In `project.yml`, under `configs: Debug:`, add `IRIS_URL_SCHEME: iris-dev`, and under `Release:`, add `IRIS_URL_SCHEME: iris`.
   - In `App/Info.plist`, add the `CFBundleURLTypes` block from Task 25 Step 3.
   - In `AppDelegate` (`Sources/IrisKit/iris.swift:5157`), add:

```swift
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("D6 spike open: %@", urls.map(\.absoluteString).joined(separator: " "))
    }
```

3. Run `pgrep -fl "Iris Dev|\.build/debug/iris"`. Expected: no output. Then run `python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: D6 window spike" --minutes 40 --on-behalf-of <requesting peer>`. Expected: exit 0.
4. Variant A (delegate only). Run `scripts/build-app.sh Debug "$TMPDIR/iris-spike"`, then `scripts/sign.sh "<path>"`, then `open "<path>"`. In a second terminal, run `log stream --style compact --predicate 'process == "Iris Dev"' | grep "D6 spike"`.
5. With the chat window open, run `osascript -e 'tell application "System Events" to count windows of process "Iris Dev"'` and note N. Then run `open 'iris-dev://run-job/AAAAAAAAAAAAAAAAAAAAAA'`, and count the windows again. Record: did the log line appear, and is the count still N?
6. Close the chat window with Cmd-W, keeping the app running, and repeat step 5. Record the same two answers.
7. Quit the app. Run `open 'iris-dev://run-job/AAAAAAAAAAAAAAAAAAAAAA'` to cold-launch it. Record: the log line, and how many chat windows appeared.
8. Variant B. Add `.handlesExternalEvents(matching: [])` after `.commands { … }` on the `WindowGroup("Iris", id: MainWindow.sceneId)` scene, rebuild, re-sign, and repeat steps 5-7.
9. Release the lease, remove the worktree (`git worktree remove --force .worktrees/agency6-spike` is allowed here, because the tree is scratch by design), and run `git branch -D spike/agency6-url-window`.
10. Post the six answers on the D2 PR as a table, or on #187 if the PR is not open yet. Decide:
    - **Variant A** gives no extra window at steps 5 and 6, exactly one window at step 7, and the log line every time: Task 26 uses the delegate only.
    - **Variant A** opens a second window anywhere, and **Variant B** does not, with the log line still printing: Task 26 adds `.handlesExternalEvents(matching: [])`.
    - **Neither** stops a second window, or Variant B stops the log line: stop D2. Report to the owner with the table, because the design must change (for example, an `NSAppleEventManager` `kAEGetURL` handler installed in `applicationWillFinishLaunching`). No later D2 task runs until the owner rules.

### Task 25: The per-build scheme in `project.yml` and `Info.plist`

**Files:**
- Modify: `project.yml:35-39` (`IRIS_URL_SCHEME` per configuration)
- Modify: `App/Info.plist` (`CFBundleURLTypes`)
- Test: `Tests/irisTests/URLSchemeConfigTests.swift` (new)

**Interfaces:**
- Consumes: `BuildIdentity.urlScheme` (Task 18).
- Produces: the build setting `IRIS_URL_SCHEME`, which is `iris-dev` for Debug and `iris` for Release.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/URLSchemeConfigTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 12: each build registers its own scheme, the same one `BuildIdentity.urlScheme`
/// says the handler answers. Read from the repo, located from `#filePath` and never the cwd.
@Suite("URL scheme configuration (D6)")
struct URLSchemeConfigTests {
    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Debug sets iris-dev and Release sets iris, matching BuildIdentity")
    func projectSetsBothSchemes() throws {
        let yml = try repoFile("project.yml")
        let debug = try #require(yml.range(of: "Debug:"))
        let release = try #require(yml.range(of: "Release:"))
        let debugBlock = yml[debug.upperBound..<release.lowerBound]
        let releaseBlock = yml[release.upperBound...].prefix(400)
        #expect(debugBlock.contains("IRIS_URL_SCHEME: \(BuildIdentity.dev.urlScheme)"))
        #expect(releaseBlock.contains("IRIS_URL_SCHEME: \(BuildIdentity.release.urlScheme)"))
    }

    @Test("Info.plist registers the scheme from the build setting")
    func plistRegistersTheScheme() throws {
        let plist = try repoFile("App/Info.plist")
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        let types = try #require(parsed?["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types.first?["CFBundleURLSchemes"] as? [String] == ["$(IRIS_URL_SCHEME)"])
        #expect(types.first?["CFBundleURLName"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh URLSchemeConfigTests`. Expected: both tests fail. `projectSetsBothSchemes` fails on the missing setting, and `plistRegistersTheScheme` fails at the `#require`.

- [ ] **Step 3: Implement.** In `project.yml`, change the configurations to:

```yaml
      configs:
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: com.bnaylor.iris.dev
          PRODUCT_NAME: "Iris Dev"
          IRIS_URL_SCHEME: iris-dev
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: com.bnaylor.iris
          IRIS_URL_SCHEME: iris
```

In `App/Info.plist`, after the `CFBundleVersion` line:

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleURLSchemes</key><array><string>$(IRIS_URL_SCHEME)</string></array>
        </dict>
    </array>
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 2 tests passed. Quote the count.

- [ ] **Step 5: Mutation check.** Set Debug's `IRIS_URL_SCHEME` to `iris`: `projectSetsBothSchemes` fails. Restore it.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings. If `work` has the Metal Toolchain, also have it run `scripts/build-app.sh Debug` and `plutil -p "<app>/Contents/Info.plist" | grep -A3 CFBundleURLSchemes`. Expected: `"iris-dev"`.

- [ ] **Step 7: Commit.** `git add project.yml App/Info.plist Tests/irisTests/URLSchemeConfigTests.swift`, then `git commit -m "feat(app): register iris:// for release and iris-dev:// for dev (D6 decision 12)"`.

### Task 26: `application(_:open:)` and the pre-acquire lock read

**Files:**
- Modify: `Sources/IrisKit/iris.swift:5157-5178` (`AppDelegate.application(_:open:)`), `:5193` (the lock read before `GUILock.acquire()`), `:5203` (the note after `AppState.shared` exists), and `:5239` (`.handlesExternalEvents(matching: [])`, Variant B only)
- Create: `Sources/IrisKit/LaunchLock.swift`
- Modify: `Sources/IrisKit/JobsCommand.swift` (delete `urlSchemePendingNote` and its use in `urlOnText`)
- Test: `Tests/irisTests/LaunchLockTests.swift` (new)

**Interfaces:**
- Consumes: `AppState.handleRunJobURL(_:identity:)`, `foreignStoreHolder` (Tasks 21 and 22) and `GUILock.state(at:)`.
- Produces: `LaunchLock.foreignHolder(_ state: GUILock.State, ownPid: Int32) -> Int32?` and `AppState.noteForeignStoreHolder(_ pid: Int32?)`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/LaunchLockTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// D6 decision 14: the app reads the store lock before it overwrites it, remembers a live
/// foreign holder so that a URL fire waits for it, and says so in Iris. Launch is never blocked.
@MainActor
@Suite("Launch lock (D6)", .timeLimit(.minutes(1)))
struct LaunchLockTests {
    @Test("only a live pid that is not this process is a foreign holder")
    func foreignHolder() {
        let me: Int32 = 100
        #expect(LaunchLock.foreignHolder(.free, ownPid: me) == nil)
        #expect(LaunchLock.foreignHolder(.held(pid: me), ownPid: me) == nil)
        #expect(LaunchLock.foreignHolder(.held(pid: 4242), ownPid: me) == 4242)
        #expect(LaunchLock.foreignHolder(.unreadable(path: "/x"), ownPid: me) == nil)
    }

    @Test("a lock file a live other process wrote reads as that process")
    func readsARealLock() throws {
        try withTempDirectorySync { dir in
            let lock = dir.appendingPathComponent("gui.lock")
            let parent = getppid()
            GUILock.acquire(at: lock, pid: parent)
            #expect(LaunchLock.foreignHolder(GUILock.state(at: lock),
                                             ownPid: ProcessInfo.processInfo.processIdentifier) == parent)
        }
    }

    private func withTempDirectorySync(_ body: (URL) throws -> Void) throws {
        let dir = try tempDirectory(prefix: "iris-launchlock")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test("a foreign holder is remembered and announced in Iris; none is silent")
    func noted() throws {
        let app = AppState(store: try ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        app.noteForeignStoreHolder(nil)
        #expect(app.foreignStoreHolder == nil)
        #expect(app.conversations.flatMap(\.messages).isEmpty)

        app.noteForeignStoreHolder(4242)
        #expect(app.foreignStoreHolder == 4242)
        let iris = app.conversations.first { $0.id == app.activityConversationId() }
        #expect(iris?.messages.last?.content == RunJobURL.foreignHolderNotice(pid: 4242))
    }

    @Test("the on reply no longer says the link cannot be opened")
    func pendingNoteIsGone() {
        let job = Job(name: "pr-sweep", prompt: "sweep", trigger: .schedule(.interval(seconds: 60)))
        #expect(!JobsCommand.urlOnText(job, url: "iris-dev://run-job/x").contains("registers the scheme"))
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh LaunchLockTests`. Expected: the build fails with "cannot find 'LaunchLock' in scope".

- [ ] **Step 3: Implement.** Create `Sources/IrisKit/LaunchLock.swift`:

```swift
import Foundation

/// D6 decision 14: who held the store when this app launched. The app still overwrites the lock,
/// because it owns the store and a lock left by a crashed build must never stop it launching. A
/// live other holder (a `--run-job`) is remembered, so a URL fire waits for it, and the owner is
/// told. The fix, making the app or the CLI yield, is #463.
enum LaunchLock {
    static func foreignHolder(_ state: GUILock.State, ownPid: Int32) -> Int32? {
        if case .held(let pid) = state, pid != ownPid { return pid }
        return nil
    }
}

extension AppState {
    func noteForeignStoreHolder(_ pid: Int32?) {
        foreignStoreHolder = pid
        guard let pid else { return }
        appendLaunchNotice(RunJobURL.foreignHolderNotice(pid: pid), to: activityConversationId())
    }
}
```

In `RunJobURL.swift`'s enum:

```swift
    static func foreignHolderNotice(pid: Int32) -> String {
        "Another Iris process (pid \(pid)) held the store at launch. A link opened before it finishes waits for it."
    }
```

In `IrisApp.init`, replace `GUILock.acquire()` (`:5193`) with:

```swift
        // D6 decision 14: who held the store before this app takes it. Read only the lock file,
        // never the store, so the rule above (nothing touches the store before the acquire) holds.
        let priorLock = GUILock.state(at: IrisPaths.default.guiLockFile)
        GUILock.acquire()
```

In the `MainActor.assumeIsolated` block, after `installGuardHealthSink()`, add:

```swift
            AppState.shared.noteForeignStoreHolder(
                LaunchLock.foreignHolder(priorLock, ownPid: ProcessInfo.processInfo.processIdentifier))
```

In `AppDelegate`, add:

```swift
    /// D6 decision 12: a run-job link, from a browser, Shortcuts, Raycast or `open`. Task 24's
    /// spike showed that this receives it with no second chat window opening (see the D2 PR).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppState.shared.handleRunJobURL(url) }
        }
    }
```

**Variant B only** (Task 24's decision): on the `WindowGroup("Iris", id: MainWindow.sceneId)` scene, after `.commands { … }`, add:

```swift
        // Task 24: without this the scene, not the delegate, took the link and opened a window.
        .handlesExternalEvents(matching: [])
```

In `JobsCommand.swift`, delete `urlSchemePendingNote` and the ` \(urlSchemePendingNote)` at the end of `urlOnText`. Plan note 13: the scheme is registered now, so the note is false.

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 4 tests passed. Then run `timeout 300 scripts/test-filter.sh 'URLTriggerCommandTests|RunJobURLTests|RunJobURLDeferralTests|RunJobCLITests'`. Expected: every test passes. Quote both counts.

- [ ] **Step 5: Mutation check.** Make `foreignHolder` return the pid even when it equals `ownPid`: `foreignHolder` fails. Restore it.

- [ ] **Step 6: Run the warnings check.** Run `scripts/check-warnings.sh`. Expected: no warnings.

- [ ] **Step 7: Commit.** `git add Sources/IrisKit/iris.swift Sources/IrisKit/LaunchLock.swift Sources/IrisKit/RunJobURL.swift Sources/IrisKit/JobsCommand.swift Tests/irisTests/LaunchLockTests.swift`, then `git commit -m "feat(app): receive run-job links, and wait behind a CLI that held the store (D6 decisions 12, 14)"`.

### Task 27: Invariant 9 sweep, and open PR D2

**Files:**
- Modify: `docs/jobs.md` (the `/jobs url` row and "Firing a job from a link", which Task 23 added)
- Modify: `README.md` (the feature list)
- Modify: `Sources/IrisKit/RunJobCLI.swift:355-358`, only if the search finds the comment falsified

- [ ] **Step 1: Search, do not compose.** Run `grep -rn -i "registers the scheme\|nothing opens the link\|D6 PR D2\|CFBundleURLTypes\|races it\|overwrites" docs README.md Sources/IrisKit App`, and read every hit.
  - Task 23's two sentences, "Until the app registers the scheme (D6 PR D2), nothing opens the link", are now false. Delete both.
  - `RunJobCLI.swift:355-358` says an app launched during a run "still races". That stays true, because the app still overwrites the lock. Decision 14 only adds a warning and the deferral. Leave it, and record that in the commit body.

- [ ] **Step 2: Add what is new.** In the README feature list: `- **Run a job from a link**: \`/jobs url <name> on\` makes an \`iris://run-job/…\` link (\`iris-dev://\` for a dev build) for Shortcuts, Raycast or a browser bookmark. It fires that one job, at most three times an hour, and carries no input. See [docs/jobs.md](docs/jobs.md).`

- [ ] **Step 3: Full suite.** Run `timeout 900 swift test` (all three markers), then `scripts/check-warnings.sh`.

- [ ] **Step 4: Commit, push and open PR D2.** Run `git commit -am "docs: run-job links open the app (D6)"` and `git push -u origin feat/agency6-url-scheme`. Then run `gh api repos/sackheads/iris/pulls -f base=main -f head=feat/agency6-url-scheme -f title="feat: agency D6 PR D2, the run-job scheme" -F body=@<file>`. The body has Task 24's spike table and the variant it chose, lists Tasks 25-27, says Task 28 is pending, and ends with the PR attribution lines.

### Task 28: GUI pass for PR D2 (`work`, under the lease)

1. Run `pgrep -fl "Iris Dev|\.build/debug/iris"`. Expected: no output.
2. Run `python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: D6 PR D2 run-job links" --minutes 60 --on-behalf-of <requesting peer>`. Expected: exit 0.
3. Build, sign and open Iris Dev.app as in Task 6 step 3.
4. Ask: "Schedule a job named d6-url every 10 minutes that replies pong." Also schedule `d6-url2` (the same, for steps 11-12) and `d6-slow` (as in Task 6 step 7). Type `/jobs url d6-url on`. Expected: the reply shows `iris-dev://run-job/<22 characters>` once, and says nothing about the link not opening yet. Copy the link.
5. App running: note the window count (`osascript -e 'tell application "System Events" to count windows of process "Iris Dev"'`), then run `open '<link>'`. Expected: Iris shows `Firing d6-url from a URL …`, which turns into `Fired d6-url from a URL; the result arrives as a card.`, and the card arrives. The window count is unchanged.
6. Quit the app (Cmd-Q), then run `open '<link>'`. Expected: the app launches with one chat window, and the same line and card appear.
7. The deferral. Quit the app. In a terminal at the repo, run `swift build && scripts/sign.sh .build/debug/iris && .build/debug/iris --run-job d6-slow &`. Within 5 s, run `open '<link>'`. Expected: Iris shows `Another Iris process (pid N) held the store at launch. …` and `Waiting for the other Iris process (pid N) to finish before firing d6-url.`. Within 5 s of the CLI printing its row, that line turns into `The other Iris process (pid N) finished; firing d6-url …`, and a fire line follows.
8. The limit. Run `open '<link>'` until four have been opened since step 5. Count steps 5-7 as three. Expected: the fourth shows `Refused a URL fire of d6-url: URL fires are limited to 3 an hour per job.`. Open it twice more. Expected: that same line now reads `Refused 3 URL fires of d6-url in the last hour. …`, and `/jobs` shows d6-url is not paused.
9. Type `/jobs url d6-url on` again, then open the old link. Expected: `Refused a URL fire: the link matches no job's URL trigger; …`. The new token appears nowhere in that line.
10. Run `open 'iris-dev://run-job/<new token>?prompt=hi'` and `open 'iris-dev://run-job/<d6-url's job id from /jobs>'`. Expected: both are refused, and the unmatched line's count goes up rather than adding lines.
11. Shortcuts. Type `/jobs url d6-url2 on` and copy its link. Create a shortcut with one "Open URLs" action holding that link, and run it. Expected: d6-url2 fires, as in step 5.
12. Raycast, if installed: create a Quicklink with d6-url2's link and open it. Expected: d6-url2 fires. Otherwise record "Raycast not installed".
13. With the release Iris.app running (if it is already installed and running; do not launch it for this), run `open 'iris://run-job/<d6-url2 token>'`. Expected: the release app refuses it as matching no job, because its store has no such job, and Iris Dev is untouched. If the release app is not running, record "skipped".
14. Quit Iris Dev, then run `scripts/run-dev.sh`. Expected: it launches with no crash, and the status item works. Do not open a link while it runs, because LaunchServices would launch Iris Dev.app beside it on one store. Quit it.
15. Type `/jobs delete d6-url`, `/jobs delete d6-url2` and `/jobs delete d6-slow`, quit, and release the lease.

---

## Self-review against the spec

**1. Spec coverage.** Each spec requirement and the task that implements it:

| Spec | Task |
|---|---|
| §0.1 no approve action; Open, Deny and Dismiss | 12 (`categories`, `noApproveAction`), 13 (`handleNotificationResponse`, `unknownActionNeverApproves`) |
| §0.2 `SurfaceAttention`, pure, never stored | 3 |
| §0.3 what action required means; drafts scoped; failures and owner pauses are menu-only | 3 (`draftScope`, `failuresAndOwnerPausesStayQuiet`), 2 (`ownerPauseReasons`) |
| §0.4 the `MenuBarExtra` label and menu, `sparkles`/`hammer`, `showMainWindow`, hotkey reuse | 3 (glyph, rows), 4 |
| §0.5 `runningJobs` keyed by job id, gate counted, `runApproved` bracketed | 1 |
| §0.6 the policy, both suppressions, fixed titles, body fields | 12 |
| §0.7 the sink, the two call sites, the `didSet` diff, permission on first post, `.active`, responses, the setting | 13, 14 |
| §0.8 bundle-only install, never `--run-job` or tests, delegate in `IrisApp.init` | 13 (`noSinkByDefault`), 14 (`SurfaceInstall`) |
| §0.9 `Job.urlTrigger`, `/jobs url` read from the right, the status form, `list_jobs` read-only | 17, 18 |
| §0.10 the 128-bit token, digest only, rotate on `on`, delete on `off`, never shown again | 17, 18 |
| §0.11 one writer, the clear in `upsert` on prompt, profile or policy, saying so, `/jobs reschedule` keeps | 17, 19 |
| §0.12 the URL form, the per-build scheme, `runJobByHand`, `FireOrigin.url`, a line per fire and refusal | 18, 20, 21, 25, 26 |
| §0.13 3 per hour, refuse-only, no row, no breaker, coalesced | 21 |
| §0.14 the pre-acquire read, the launch notice, the 5 s / 10 min deferral | 22, 26 |
| §0.15 the Run Log window, paging, inclusions, Acknowledge, no Approve, transcript or pruned | 7, 8, 9 |
| §0.16 the cached snapshot and its refresh points, the one hook | 2 |
| §1 components and the v19 migration | 17 (migration), every task's Files |
| §2 agent-facing text and docs | 5, 10, 15, 23, 27; `list_jobs` in 18; plan note 7 for the two declarations |
| §3 unit tests | each task's Step 1; the token exclusions in 18 |
| §3 GUI checks | 6, 11, 16, 24, 28 |
| §4 PR split, D1/D2, the spike gating D2 | the PR headings; Task 24 |

No requirement is left without a task. Two spec items are implemented differently from how the spec words them, and each is a plan note: the unique column (note 1), and the declarations in §2 (note 7).

**2. Placeholder scan.** The plan was searched for "TBD", "TODO", "implement later", "fill in", "appropriate", "handle edge cases", "similar to Task" and "…". None of the first seven occur. Every "…" left is one of three things:
- part of a user-visible string (`Firing d6-url from a URL …`, `Starting **x** …`);
- a quotation of existing text that is cited by line (README:266, the `list_jobs` description, `try? … upsert(…)`);
- an elision of a body that moves unchanged (`runApproved`'s tail in Task 1, the `.commands { … }` block).

**3. Type consistency.**
- `LedgerAttention.Blocked` and `Paused` are produced in Task 2 and consumed in Tasks 3, 12 and 13.
- `StatusMenuRow.Target` is defined in Task 3 with `.nowhere` (not `.none`, to stay clear of `Optional.none`), and `.runLog` is added in Task 9.
- `AppState.acknowledgeRun(_:)` is produced in Task 2 and used in Tasks 8, 9 and 13. `dismissEventCard(runId:)` returns its task.
- `JobLedger.UpsertOutcome` is produced in Task 17 and consumed in Task 19.
- `RunJobURL` gains members in Tasks 18 (`host`, `url`, `maxFiresPerHour`), 20 (fire lines), 21 (parse, refusals, reasons), 22 (wait lines) and 26 (`foreignHolderNotice`). `URLDeferral`, `URLDeferralTimer`, `PendingURLFire` and `URLRefusalLine` live at file scope beside it.
- `foreignStoreHolder` and `isProcessAlive` are produced in Task 22 and set at launch in Task 26.

**4. Review Focus.** Each of the five has its test in the owning task:
- 1 is in Task 21 (`garbageFloodIsOneLine`, `overLimitFloodIsOneLine`).
- 2 is in Task 12 (`hostileNamesStayInsideTheirQuotes`).
- 3 is in Task 2 (`makeSortsTheRows`) and Task 12 (`ownerAndSeederPausesNeverNotify`).
- 4 is in Task 12 (`completedCardOnAPausedJobIsQuiet`).
- 5 is in Task 7 (`pagingNeverDropsOrRepeatsTiedRows`).

The security rules the coordinator named each have a mutation check:
- The token never reaching the model: Task 18, Step 6.
- The opt-in clearing on a prompt, profile, policy or grant change: Task 17, Step 7.
- The URL limit not counting toward the breaker: Task 21, Step 6.
- Fixed notification titles, and notifications never approving: Task 12, Step 5, and Task 13, Step 5.
