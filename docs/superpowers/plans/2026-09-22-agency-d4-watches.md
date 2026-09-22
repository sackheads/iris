# Agency Deliverable 4: Watches — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Status:** READY — spec proposed 2026-09-22 and revised the same day after an adversarial pre-review; ruling R-D4-1 (self-writes are the writes of unattended runs) is folded in. Written 2026-09-22.

**Goal:** A directory watch runs once per save-burst after a quiet window, never concurrently with itself, never on Iris's own unattended writes or on editor noise, and says in `/jobs` and on the card what it saw and what it absorbed.

**Architecture:** One additive migration (`v11_watches`: `job_runs.watchSummary` plus a canonical-root rewrite of every `.fsEvent` row); `FSWatch.ignore`; a new `actor WatchCoordinator` that owns time (debounce with a ×10 ceiling, held paths, counts, `tick(now:)`), fires through a `WatchFireHandler` that returns the runner's admission; a process-wide `actor RecentWrites` fed from the tool dispatcher's unattended branch; `WatcherManager` re-keyed by canonical root with a diff-based `sync(with:)`; one `JobLedger.onJobsChanged` hook that syncs both; `JobRunner.fire(... watch:)` stamps the summary on the row and the held re-fire unions watch paths; tool arguments, refusals and the per-conversation registration rule; the figures on the card, `/jobs`, `list_jobs`, `get_job_run`.

**Tech Stack:** Swift 6 strict concurrency, GRDB, FSEvents (`FileWatcher`, unchanged), `OSAllocatedUnfairLock`, Swift Testing.

**Spec:** `docs/specs/2026-09-22-agency-watches.md` (binding). Every `file:line` below is from `main` @ `2015c84`. Prior slices: #252 (D1), #253 (D2), #257 / #260 / #262 / #264 (D3).

## Global Constraints

- Quiet window `quietWindowSeconds`: 1…300, default 3, clamped on decode and on the tool. Ceiling = `quietWindowSeconds × 10` (30 s at the default), derived, never stored. Registry expiry = `min(quietWindow, 30) + 2 s`; the registry sweeps entries older than 32 s on every `record` and has a 10,000-entry safety valve. `maxTrackedPaths = 1,000` distinct paths for `pending` and for `heldPaths`; at most 100 paths reach the prompt plus one line `and N more changed paths`, applied **before** the injection guard.
- Built-in ignore set, spelled once as `WatchCoordinator.builtInIgnore`: `.git/`, `.DS_Store`, `node_modules/`, `*~`, `*.swp`, `*.swx`, `.#*`, `4913`, `*.tmp`, `.*.sb-*`, `(A Document Being Saved By *`. Probe list for the ignore refusal: `a.txt`, `dir/b.md`, `.hidden`, `x.swift`, `sub/dir/c`. Too-broad roots: `/`, the home directory, any volume root (`/Volumes/<name>`), `/System`, `/Library`, `/usr`, `/private`, `/var`, `/etc`, `/bin`, `/sbin`; protected: a root that is or contains `~/.iris/config` or `~/.iris/plugins`.
- Every new persisted field decodes leniently (invariant 1): `FSWatch.ignore` → `[]`, `JobRun.watchSummary`/`EventCard.watchSummary` → `nil` (a malformed JSON blob also → `nil`, the `blockedCall` idiom).
- A burst in which every event was absorbed writes no row and no card. A watch skip writes no row (as today). Watch fires never retry. Self-writes are recorded **only** for unattended conversations (`conversation.isBackground == true` — R-D4-1); the singleton `RecentWrites.shared` is reached only through injection.
- The names below are the only names: `WatchFire`, `WatchFireHandler`, `WatchSummary` (eight fields: `delivered`, `changed`, `overflow`, `coalesced`, `noise`, `ownWrites`, `ceilingFired`, `pathsWithheld`), `AbsorbedCounts { noise, ownWrites, whilePaused }`, `WatchCoordinator.maxTrackedPaths`, `WatchCoordinator.takeHeldPaths(_:)`, `WatchCoordinator.sync(with:)`, `WatcherManager.sync(with:)`, `JobLedger.onJobsChanged(_:)`.
- Tests (invariant 7): Swift Testing; in-memory store per test; injected clock through `tick(now:)` and `now:` closures; a fake event source (the test calls `coordinator.deliver(root:paths:)` or holds a fake stream's continuation); an injected `WatchFireHandler` returning chosen admissions; a per-test `RecentWrites`; no real FSEvents, no directory written to provoke an event, no `ConfigManager.shared`, `WatcherManager.shared`, `RecentWrites.shared`, or a shared ledger's `onJobsChanged`.
- `swift test; echo exit=$?` = 0 and zero `with [1-9][0-9]* failures` before each commit; conventional commits with the `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` trailer; never `git add` `.superpowers/` or `.claude/`.

---

## PR A — behaviour (Tasks 1–5)

### Task 1: `FSWatch.ignore`, the clamp, `WatchSummary`, migration `v11_watches` **[§1, §6 row]**

**Files:** Create `Sources/iris/WatchSummary.swift` (`WatchSummary`, `AbsorbedCounts`), `Sources/iris/WatchRoot.swift` (`WatchRoot.canonical`); Modify `Sources/iris/Job.swift` (`FSWatch` :70-89 — `ignore`, `CodingKeys` case, clamp; doc comment :70-72 rewritten), `Sources/iris/ConversationStore.swift` (register `v11_watches` after `v10_job_policy` :412-427), `Sources/iris/JobRun.swift` (`var watchSummary: WatchSummary?` after `parentRunId` :51), `Sources/iris/JobLedger.swift` (`begin(run:)` :263-282 → 21 columns; `run(from:)` :594-630 decodes the column with `try?`), `Sources/iris/ToolExecutor.swift` (`registerWatcher` :222-262: stores `WatchRoot.canonical(path)` and creates with `policy: JobPolicy(overlap: .queue)`); Tests `Tests/irisTests/JobModelTests.swift` (extend `fsWatchDefault` :38-42), `Tests/irisTests/JobRunLedgerTests.swift`, new `Tests/irisTests/WatchMigrationTests.swift`.

Why the row field is here and not in Task 7: Task 4's runner test asserts `watch:` lands on the row, so `JobRun.watchSummary`, the column and its decode must exist in PR A; only `EventCard.watchSummary` waits for PR B.

**Interfaces (produces):**
```swift
struct FSWatch: Codable, Equatable, Sendable {
    var path: String                       // canonical, absolute
    var quietWindowSeconds: Int            // clamped 1…300
    var ignore: [String]                   // default []
    init(path: String, quietWindowSeconds: Int = 3, ignore: [String] = [])   // clamps too
    static func clampQuietWindow(_ seconds: Int) -> Int                        // min(max(seconds, 1), 300)
    var ceilingSeconds: Int { quietWindowSeconds * 10 }
}
struct WatchSummary: Codable, Sendable, Equatable {
    var delivered: Int; var changed: Int; var overflow: Int; var coalesced: Int
    var noise: Int; var ownWrites: Int; var ceilingFired: Bool; var pathsWithheld: Bool
    // all decodeIfPresent: Ints ?? 0, Bools ?? false
}
struct AbsorbedCounts: Codable, Sendable, Equatable { var noise = 0; var ownWrites = 0; var whilePaused = 0 }
enum WatchRoot {
    /// `~` expanded, `..` and symlinks resolved, standardised. nil when `fileExists` is false for the path.
    static func canonical(_ raw: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String?
}
// JobRun: var watchSummary: WatchSummary?      (nil default; hand-decoded with try? like blockedCall)
```
Migration `v11_watches`: `ALTER TABLE job_runs ADD COLUMN watchSummary TEXT`; then for every `jobs` row with `triggerKind = 'fsEvent'`, decode `trigger`, replace `FSWatch.path` with `WatchRoot.canonical(path)` when it returns non-nil, re-encode with the encoder `JobLedger.upsert` uses for the `trigger` column, and `UPDATE jobs SET trigger = ? WHERE id = ?` only when the string changed. A path that no longer exists is left as stored (§7 pauses it at launch).

In `registerWatcher` (Task 1's minimal touch; the arguments and refusals are Task 6): the stored path is `WatchRoot.canonical(resolved) ?? IrisPaths.canonicalPath(resolved)` (so a not-yet-existing path still round-trips until Task 6 refuses it), and a new job is created with `policy: JobPolicy(overlap: .queue)`; an existing job's policy is untouched.

- [ ] Tests first — `JobModelTests`: `fsWatchDefault` also asserts `ignore == []`; `fsWatchClampsOnDecode` (`{"path":"/tmp","quietWindowSeconds":0}` → 1, `999` → 300); `fsWatchIgnoreRoundTrips`. `WatchMigrationTests`: `v11AddsTheColumnAndKeepsRows` (migrate an in-memory store `upTo: "v10_job_policy"`, insert a schedule job and a run, migrate to v11, both read back); `v11CanonicalisesAnExistingWatchRoot` (a temp directory `d` and a symlink `l → d`, a v10 `.fsEvent` row with `l`'s path, after v11 the row's path is `d`'s canonical path); `v11LeavesAMissingRootAsStored`; `olderBuildIgnoresTheColumn` (a `JobRun` row with `watchSummary = NULL` decodes with `nil`, a malformed blob decodes with `nil`). `JobRunLedgerTests`: `beginPersistsWatchSummary` (`begin(run:)` with a summary, `run(id:)` returns it equal). `ToolExecutorWorkspaceTests`: a new `watcherStoresCanonicalPathAndQueueOverlap` (a temp dir through a symlink → stored path is canonical; `policy.overlap == .queue`); `relativeWatcherResolvesToWorkspace` :46-65 still passes (`/ws` does not exist, so `/ws/src` is left as is; `FSWatch(path: "/ws/src", quietWindowSeconds: 3)` equals with `ignore: []`).
- [ ] Watch them fail; implement; `swift test --filter "JobModelTests|WatchMigrationTests|JobRunLedgerTests|JobLedgerTests|ConversationStore|ToolExecutorWorkspaceTests"`; full suite; commit `feat(jobs): FSWatch.ignore, the 1…300 clamp, WatchSummary on the run row, and migration v11 with canonical watch roots (#187)`.

### Task 2: `RecentWrites` and the dispatcher choke point **[§4, R-D4-1]**

**Files:** Create `Sources/iris/RecentWrites.swift`; Modify `Sources/iris/iris.swift` (`init` :187 gains `recentWrites: RecentWrites = .shared` stored as `let recentWrites`; the hook beside `recordSubagentWrite` :2948-2954; `static let pathWritingTools`), `Sources/iris/ToolExecutor.swift` (factor `static func skillFolder(named:paths:) -> URL` out of the duplicated `cleanName`/`skillFolder` lines :514-520 and :548-553 and use it in `createSkill`, `updateSkill`, `deleteSkill`), `Sources/iris/SubagentManager.swift` (`runSubagent(role:task:effort:parentConversationId:…)` :33 gains `recentWrites: RecentWrites = .shared`, passed to the `IrisEngine(...)` at :70-71), `Sources/iris/GoalEvaluator.swift` (`evaluate(contract:workspace:originatingConversationId:…)` :28 gains the same, passed at :51); the `IrisEngine` call sites of both pass `self.recentWrites` (grep `runSubagent(` and `.evaluate(contract:`); Tests new `Tests/irisTests/RecentWritesTests.swift`, `Tests/irisTests/SelfWriteHookTests.swift`.

The spec's "`ToolExecutor` records" is implemented one frame up, in `IrisEngine`'s dispatcher: `isUnattendedRun` does not exist — the gate is the local `isUnattended` (`conversation?.isBackground == true`, iris.swift:2227) — and the three skill tools (:513/:547/:613) take no `conversationId`, so the dispatcher at :2948 is the only frame with both the unattendedness and the tool result in scope. `recordSubagentWrite` stays beside it, untouched.

**Interfaces (produces):**
```swift
actor RecentWrites {
    static let shared = RecentWrites()
    static let maxEntries = 10_000                 // safety valve; eviction by count is a filter bypass
    static let sweepAfter: TimeInterval = 32       // the longest live expiry: min(300, 30) + 2
    init(now: @escaping @Sendable () -> Date = Date.init)
    func record(_ path: String)                    // stores URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path; sweeps; valve
    func isOwn(_ eventPath: String, within expiry: TimeInterval) -> Bool   // exact | parent of a recorded path | atomic-temp sibling; lexical, never stats
    var count: Int
    static func expiry(quietWindowSeconds: Int) -> TimeInterval           // min(Double(w), 30) + 2
    static func isAtomicTempSibling(_ basename: String, of recorded: String) -> Bool  // ".\(recorded).sb-*", "\(recorded).tmp", "(A Document Being Saved By *"
}
// IrisEngine
static let pathWritingTools: Set<String> = ["write_file", "create_skill", "update_skill", "delete_skill"]
static let toolsThatWriteNoPath: Set<String>   // every other declared tool, by name; the pin below keeps the two exhaustive
static func writtenPaths(tool: String, args: [String: JSONValue], cwd: String?, result: String, paths: IrisPaths = .default) -> [String]
// write_file + "Successfully wrote to " → [resolvePath(path, cwd)]; create_skill/update_skill + "Successfully saved skill '" or "Successfully updated skill '" → [folder.path, folder/SKILL.md]; delete_skill + "Successfully deleted skill '" → [folder.path]; anything else → []
```
Hook at :2948, after `execute` returns and before `fireAfterTool`: `if isUnattended { for p in Self.writtenPaths(...) { await recentWrites.record(p) } }`.

- [ ] Tests first — `RecentWritesTests` (per-test `RecentWrites(now:)` over a mutable fake clock): `exactParentAndSiblingMatch` (`record("/w/notes.md")`; `isOwn("/w/notes.md")`, `isOwn("/w")`, `isOwn("/w/.notes.md.sb-1a2b")`, `isOwn("/w/notes.md.tmp")`, `isOwn("/w/(A Document Being Saved By Iris)")` true; `isOwn("/w/other.md")` false); `noConsumptionOnMatch` (three `isOwn` calls all true); `expiryIsExactlyWindowPlusTwo` (`expiry(quietWindowSeconds: 3) == 5`, `expiry(300) == 32`; at `record + 4.999` own, at `+ 5` not); `recordedPathIsSymlinkResolved` (temp dir + symlink; record through the link, `isOwn` on the resolved path); `timeSweepRemovesOldEntries` (record, advance 33 s, record another, `count == 1`); `theValveHoldsTenThousand` (10,001 records within 1 s → `count == 10_000` and the earliest is gone — the documented failure direction). `SelfWriteHookTests` (harness as `JobAdmissionTests.harness(client:)` with an injected `RecentWrites`): `anUnattendedWriteIsRecorded` (a background conversation's scripted `write_file` into a temp dir → `count == 1`, the recorded path is canonical); `anAttendedWriteIsNotRecorded` (the same script from the user conversation → `count == 0`; R-D4-1); `skillWritesRecordFolderAndFile` (`create_skill` under a volatile `IrisPaths` → two entries); `everyDeclaredToolIsClassified` (names from `ToolExecutor.getTools(workspaceToolsEnabled: true)` ∪ `IrisEngine.jobToolDeclarations(isPinned: true)` are each in exactly one of `pathWritingTools`, `toolsThatWriteNoPath` — the pin against `getTools()`); `subagentEngineSharesTheRegistry` (`runSubagent(..., recentWrites: r)` builds an engine whose `recentWrites === r`).
- [ ] Implement; `swift test --filter "RecentWritesTests|SelfWriteHookTests|SubagentManagerTests|GoalEvaluatorTriggerTests"`; full suite; commit `feat(jobs): RecentWrites — unattended file-tool writes are remembered per process for the self-write filter (#187)`.

### Task 3: `WatchCoordinator` core **[§2, §0.1, §0.2, §0.4, §0.7]**

**Files:** Create `Sources/iris/WatchCoordinator.swift` (`WatchFire`, `WatchFireHandler`, `WatchCoordinator`), `Sources/iris/WatchGlob.swift`; Modify `Sources/iris/JobRunner.swift` (`prompt` :1369-1392 → `PromptBuild` with the 100-path cap and the withheld signal; `recordStillborn` :1494 stays the failed-row writer); Tests new `Tests/irisTests/WatchCoordinatorTests.swift`, `Tests/irisTests/WatchGlobTests.swift`, `Tests/irisTests/JobRunnerTests.swift` (prompt cap cases).

**Interfaces (produces):**
```swift
struct WatchFire: Sendable, Equatable { let paths: [String]; let summary: WatchSummary }
typealias WatchFireHandler = @Sendable (Job, WatchFire) async -> JobRunner.Admission?

struct WatchGlob: Sendable {
    /// Relative to the watch root. `**` spans components; `*` and `?` never cross `/`; a pattern without `/`
    /// matches any single component; a trailing `/` matches a component and everything under it.
    init(_ pattern: String)
    func matches(relativePath: String) -> Bool
    static func matcher(_ patterns: [String]) -> @Sendable (String) -> Bool      // compiled once
    static let probes = ["a.txt", "dir/b.md", ".hidden", "x.swift", "sub/dir/c"]
    static func ignoresEveryProbe(_ patterns: [String]) -> Bool                  // Task 6's refusal, decided by the compiled matcher
}

actor WatchCoordinator {
    static let maxTrackedPaths = 1_000
    static let maxDeliveredPaths = 100
    static let ceilingMultiplier = 10
    static let builtInIgnore: [String]            // the eleven patterns from Global Constraints
    init(ledger: JobLedger, now: @escaping @Sendable () -> Date, recentWrites: RecentWrites, fire: @escaping WatchFireHandler)
    func sync(with jobs: [Job])
    func deliver(root: String, paths: [String]) async     // one FSEvents batch, tagged with the stream root
    func tick(now: Date) async
    func takeHeldPaths(_ jobId: UUID) -> [String]         // heldPaths ∪ pending, sorted, both emptied; clears fireOutstanding
    func absorbedSinceLaunch() -> [UUID: AbsorbedCounts]
    func nextDeadline() -> Date?
    struct Snapshot: Equatable { let pending: Int; let held: Int; let fireOutstanding: Bool; let burstBegan: Date? }
    func snapshot(_ jobId: UUID) -> Snapshot?             // test-facing read
    func startLoop(everyMinute: @escaping @Sendable () async -> Void) / func stopLoop()   // production only (Task 5)
}
// JobRunner
struct PromptBuild: Sendable, Equatable { let text: String; let delivered: Int; let pathsWithheld: Bool }
static func buildPrompt(job: Job, changedPaths: [String], gateOutput: String? = nil, protectionEnabled: Bool? = nil) async -> PromptBuild
static func prompt(job:changedPaths:gateOutput:protectionEnabled:) async -> String   // kept: buildPrompt(...).text
```

Per-subscriber state is the spec's table verbatim (`job: Job` as of the last `sync`, `pending`, `heldPaths`, `fireOutstanding`, `burstBegan`, `lastAccepted`, the five per-burst counters, `absorbedSinceLaunch`), plus `lastAdmission: JobRunner.Admission?` and a compiled `ignore` matcher (built-in set + the watch's globs, rebuilt on `sync`).

`sync(with:)`: a subscriber for every enabled, unpaused `.fsEvent` job; new or re-registered (same id, changed `watch`) → empty burst, `absorbedSinceLaunch` kept; gone, disabled or paused → removed with everything; a window or glob edit rebuilds the matcher and does not re-filter `pending`; an overlap edit from `.queue` to `.skip` while a `.queued` fire is outstanding releases `heldPaths` into a fresh burst at `now()` (the runner will `discardQueuedFire`, so nobody else would take them).

`deliver(root:paths:)`: fan out once to every subscriber whose `watch.path` is a lexical prefix (`==` or `hasPrefix(path + "/")`) of the path after `standardizingPath`; per subscriber and path: matcher hit → `noise += 1`; `recentWrites.isOwn(path, within: RecentWrites.expiry(quietWindowSeconds:))` → `ownWrites += 1`; `fireOutstanding` → insert into `heldPaths` (bounded: a new distinct path beyond `maxTrackedPaths` adds to `changed` and `overflow`, not to the set); else insert into `pending` with the same bound, `changed += 1` on a new distinct path, `coalesced += 1` on every accepted entry, `burstBegan = burstBegan ?? now`, `lastAccepted = now`. Absorbed events outside a burst go to `absorbedSinceLaunch` only; a batch that accepted nothing changes no timer.

`tick(now:)`: for each subscriber with `pending` non-empty and no fire outstanding, `deadline = min(lastAccepted + quiet, burstBegan + quiet × 10)`; `now >= deadline` → fire (`ceilingFired = now >= burstBegan + quiet × 10`). A subscriber whose outstanding admission is `.skipInFlight` is re-offered its held set when `now >= lastAttempt + quiet × 10` — the ceiling, not the window (see below).

Firing: (1) `try ledger.job(id:)` — throws → drop the burst and write `JobRunner.recordStillborn(job: subscriber.job, ledger:, reason: "watch fire dropped: \(error)", triggerKind: Trigger.fsEventKind, now:, note: nil)` (never silent, never a fire without the filter); `nil` → drop `pending`, end the burst; `!enabled || pausedReason != nil` → drop `pending`, `absorbedSinceLaunch.whilePaused += changed`. (2) `heldPaths ∪= pending`, `pending = []`, `fireOutstanding = true`, build `WatchFire(paths: heldPaths.sorted(), summary: WatchSummary(delivered: min(count, 100), changed:, overflow:, coalesced:, noise:, ownWrites:, ceilingFired:, pathsWithheld: false))`, zero the burst counters, dispatch `Task { await fire(job, fire) }` — the loop never awaits a run. (3) On return: `.run` → remove the fired paths from `heldPaths`, clear `fireOutstanding`; remaining held paths start a new burst with `burstBegan = lastAccepted = now()`. `.queued` → paths stay held, `fireOutstanding` stays; `takeHeldPaths` is what clears it (the runner's re-fire is the continuation of this fire). `.skipInFlight` → paths stay held, `fireOutstanding` stays, `lastAttempt = now()`; the next `tick` at or after `lastAttempt + quiet × 10` (the ceiling) re-offers the held set with the same summary. Departure from §2's letter, stated here: the run in flight when the coordinator fires is never one of the coordinator's own handlers (at most one is outstanding), so "until the handler that started the run returns" has nothing to wait on — it is a `/jobs run` or an approved call. Re-asking writes no rows (`fire` returns before `recordSkip` for a watcher origin, JobRunner.swift:305-313) but costs two ledger sums per ask, so the interval is the ceiling: at the default that is one ask per 30 s for the length of a human-started run, not one per 3 s (ruling, recorded in the ledger as R-D4-2). Any other refusal → drop `heldPaths`, clear `fireOutstanding`. `nil` → remove the subscriber's state entirely.

`buildPrompt`: sort, take the first `maxDeliveredPaths`, append `and N more changed paths` when more; each path through `PromptInjectionGuard.sanitizeUntrustedInput`; the block through the `GuardOutcome`-returning function beneath `sanitize` (InjectionGuard.swift:221-230) with `contextTag: "fs_event_paths"`, `maxTier: .tier3_canary`, then `wrap`/`wrapBlocked` as `sanitize` does; `.blocked` → `delivered = 0`, `pathsWithheld = true`, the text carries the blocked marker and no paths.

- [ ] Tests first — `WatchGlobTests`: `builtInSetMatchesTheExpectedNames` (`.git/HEAD`, `a/.DS_Store`, `node_modules/x/y.js`, `f~`, `.f.swp`, `.#f`, `4913`, `x.tmp`, `.notes.md.sb-9f`, `(A Document Being Saved By TextEdit)` hit; `notes.md`, `src/main.swift` miss); `starDoesNotCrossSlash`, `doubleStarDoes`, `trailingSlashIsASubtree`; `probeRefusal` (`["*"]`, `["**/*"]`, `["?*"]` ignore every probe; `["*.*"]` does **not** — `sub/dir/c` has no dot — nor does `["*.md"]`). `WatchCoordinatorTests` (per test: in-memory ledger with the jobs upserted, `RecentWrites(now:)`, a recording handler returning a scripted admission, a fixed base instant `t0`): `eightBatchesWithinTwoSecondsFireOnce` (deliver 8 batches at `t0…t0+2`, `tick(t0+4)` no fire, `tick(t0+5)` one fire with eight sorted paths, `summary.coalesced == 8`, `changed == 8`); `aBatchEverySecondFiresAtTheCeiling` (batches at `t0, +1, …`; the fire happens at the first `tick ≥ t0+30` with everything so far, `ceilingFired == true`; the next batch starts a new burst whose ceiling is its own `+30`); `noiseAndOwnWritesNeverStartABurst` (a `.DS_Store` batch and a batch on a recorded path; `snapshot.burstBegan == nil`, `absorbedSinceLaunch == [noise: 1, ownWrites: 1]`, no fire); `aMixedBatchAcceptsOnlyTheRest` (per-burst counts start at zero with the burst); `twoSubscribersOnOneRootAreIndependent` (windows 3 and 10; the first fires at `+3`, the second at `+10`; separate counts); `aChildRootIsServedOnceByTheAncestorStream` (subscribers on `/r` and `/r/sub`; one `deliver(root: "/r", paths: ["/r/sub/a"])` → both fire exactly once, `/r/sub/a` once each; a path `/r/other` reaches only `/r`); `aFireNeverBlocksTheLoop` (handler for job A parks on a continuation; job B still fires on the next tick); `runRemovesOnlyTheFiredPaths` (fire `a`; deliver `b` while outstanding; handler returns `.run`; `snapshot.held == 0`, `pending == 1`, `burstBegan == now`); `queuedKeepsThePathsAndTakeHeldPathsReturnsTheUnion` (fire `a` → `.queued`; deliver `b`; `takeHeldPaths == ["a","b"]`; `fireOutstanding == false`); `skipInFlightReAsksOncePerCeiling` (`.skipInFlight` scripted twice then `.run`; `tick` at `+3` and `+6` → no further call; `+30` and `+60` → the second and third calls, no `pending` growth, the third carries the whole held set); `otherRefusalsDropHeldPaths` (`.pauseBreaker(count: 6)` → `held == 0`); `nilDropsTheSubscriber` (`snapshot == nil`); `syncKeepsAbsorbedAcrossReRegistrationAndRemovesAPausedJob`; `aPausedRowDropsTheBurstIntoWhilePaused` (`setPaused` on the ledger between the burst and the tick → no handler call, `whilePaused == changed`); `aLedgerReadFailureWritesAFailedRow` (a ledger over a closed/poisoned writer → one row with the reason, no handler call); `fifteenHundredPathsKeepAThousand` (`changed == 1500`, `overflow == 500`, `paths.count == 1000`); `aSimulatedLongGapFiresOnce` (batch at `t0`, `tick(t0 + 3600)` → one fire). `JobRunnerTests`: `promptCapsAtAHundredPaths` (150 paths → 100 listed, `and 50 more changed paths`, `delivered == 100`); `aBlockedPathBlockIsWithheld` (`protectionEnabled: true` with `CoreMLEvaluator.$scopedModel.withValue(.init(blockingModel))` → `delivered == 0`, `pathsWithheld == true`, no path in `text`); `changedPathsArriveSanitized` :248 and `noChangedPathsIsTheJobPromptAlone` :264 unchanged.
- [ ] Implement; `swift test --filter "WatchCoordinatorTests|WatchGlobTests|JobRunnerTests|WatcherJobsTests"`; full suite; commit `feat(jobs): WatchCoordinator — quiet window with a ceiling, noise and self-write absorption, bounded holds, non-blocking fires (#187)`.

### Task 4: The runner seam — `watch:` on the row, the union re-fire **[§3, §6 row]**

**Files:** Modify `Sources/iris/JobRunner.swift` (`fire(job:origin:note:)` :240-242 gains `watch: WatchSummary? = nil`; `run(job:origin:limits:gate:note:)` :686-687 gains `watch:`; the prompt build :735-737 moves above the row at :696-707 and the row is begun with the final summary; re-fire points :347-351 and :356-362; `setHeldPathsSource`; `pauseUnavailable`); Tests `Tests/irisTests/JobAdmissionTests.swift` (restate :319-344 and :385-424; add the union and row cases), `Tests/irisTests/JobRunnerTests.swift`.

**Interfaces (produces):**
```swift
// JobRunner
@discardableResult
func fire(job: Job, origin: FireOrigin, note: String? = nil, watch: WatchSummary? = nil) async -> Admission?
func setHeldPathsSource(_ source: @escaping @Sendable (UUID) async -> [String])   // production: coordinator.takeHeldPaths
func pauseUnavailable(job: Job, reason: String) async                              // wraps the private pause(job:origin:reason:at:note:) with origin .watcher(paths: []); Task 5's vanished-root pause
static func mergedWatcherOrigin(_ held: FireOrigin, taking extra: [String]) -> FireOrigin
// .watcher-rooted → .watcher(paths: Set(held.paths ∪ extra).sorted()); any other root → held unchanged
```
At both re-fire points: `let taken = held.origin.isWatcher ? await heldPathsSource?(current.id) ?? [] : []; origin = .queued(from: Self.mergedWatcherOrigin(held.origin, taking: taken))` — the `.queued` wrapper stays, so `triggerKind == "queued"` and `gateApplies` still reads the root. In `run`: `var summary = watch; if let built = promptBuild, summary != nil { summary?.delivered = built.delivered; summary?.pathsWithheld = built.pathsWithheld }`; `run.watchSummary = summary` before `ledger.begin(run:)`. `isPathDriven` :207-209 and its three call sites are untouched: a `.queued(from: .watcher)` re-fire is still path-driven and still never retries.

- [ ] Tests first — `JobAdmissionTests`: **restate** `watcherOverlapWritesNoRow` :319-344 as `aSkipWatchOverlapWritesNoRow` (the job pins `overlap: .skip` explicitly; same assertions — the default is now `.queue` and would take the other branch); **restate** `queuedFireRunsOnceAfterTheRun` :385-424 so the runner has `setHeldPathsSource { _ in ["/tmp/fromCoordinator"] }` and the queued run's prompt contains `/tmp/second`, `/tmp/third` and `/tmp/fromCoordinator` — a union, not the latest burst — with `triggerKind == "queued"`; new `heldPathsSourceIsAskedOnlyForWatcherRoots` (a `.manual` held fire never calls the source); `watchSummaryLandsOnTheRow` (`fire(..., watch: summary)` → `runs(...).first?.watchSummary == summary` with `delivered` equal to the path count); `aWithheldBlockIsRecorded` (blocking guard scope → `delivered == 0`, `pathsWithheld == true` on the row). `JobRunnerTests`: `pauseUnavailableWritesTheReasonAndACard` (`pausedReason == "watch path unavailable: /gone"`, one stillborn row, one card).
- [ ] Implement; `swift test --filter "JobAdmissionTests|JobRunnerTests|JobSchedulerTests"`; full suite; commit `feat(jobs): the runner stamps a watch summary on the row and the held re-fire is a union of watch paths (#187)`.

### Task 5: `WatcherManager.sync(with:)`, the ledger hook, launch wiring **[§7, §0.5, §0.6]**

**Files:** Modify `Sources/iris/WatcherManager.swift` (re-keyed by root; `reload()` :58-72, `reload(adoptingIfUnconfigured:callback:)` :48-53, `setCallback` :37-39, `deliver(job:paths:)` :99-101, `startWatcher(for:path:)` :83-95 and `activeJobIds` :32 removed; the "cheap to recreate" comment :55-57 goes with them), `Sources/iris/JobLedger.swift` (the hook; `upsert` :47, `delete` :101, `setPaused` :122), `Sources/iris/iris.swift` (`start()` :501-506 replaced; `watcherCallback()` :2098-2114 deleted; `jobToolsProvider()` :110-122 builds `JobTools(ledger:)`; `func watchCoordinator() -> WatchCoordinator?`; `private func syncWatches(ledger:)`), `Sources/iris/ToolExecutor.swift` (`JobTools` :6-21 loses `watchers` and `watcherCallback`; the `reload` at :257 removed — the hook covers it), `Sources/iris/AppState.swift` (the `reload()` at :2971 removed; `forget(jobId:)` stays); Tests `Tests/irisTests/WatcherJobsTests.swift` (restated), new `Tests/irisTests/WatcherManagerSyncTests.swift`, `Tests/irisTests/JobLedgerTests.swift` (hook cases), `Tests/irisTests/ToolExecutorWorkspaceTests.swift` and any other `JobTools(ledger:watchers:watcherCallback:)` caller updated to `JobTools(ledger:)`.

The facts make this a re-keying, not a diff: `activeWatchers`/`watchTasks` are `[UUID: …]` keyed by job with the `Job` value captured in the task closure; `FileWatcher` holds one stream per instance, so the manager keeps one `FileWatcher` per root and the coordinator, not the manager, knows which jobs a root serves.

**Interfaces (produces):**
```swift
actor WatcherManager {
    struct WatchStream: Sendable { let events: AsyncStream<[String]>; let stop: @Sendable () -> Void }
    typealias StreamFactory = @Sendable (_ root: String) -> WatchStream
    static let shared = WatcherManager(ledger: nil)
    init(ledger: JobLedger?, streams: @escaping StreamFactory = WatcherManager.fsEventsStream,
         fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    static let fsEventsStream: StreamFactory     // { root in let w = FileWatcher(); return WatchStream(events: w.watch(paths: [root]), stop: { w.stop() }) } — the closure retains w
    func configure(ledger: JobLedger)                                                        // kept
    func setBatchHandler(_ handler: @escaping @Sendable (_ root: String, _ paths: [String]) async -> Void)
    func setUnavailableHandler(_ handler: @escaping @Sendable (Job, String) async -> Void)  // production: runner.pauseUnavailable
    var activeRoots: [String]
    func sync(with jobs: [Job]) async
    static func roots(for jobs: [Job]) -> Set<String>                    // enabled, unpaused .fsEvent roots with nested roots collapsed — pure
    static func vanished(in jobs: [Job], fileExists: (String) -> Bool) -> [Job]   // enabled, unpaused .fsEvent jobs whose root is gone — pure
    func stopAll()
}
// JobLedger
private let jobsChanged = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
func onJobsChanged(_ hook: @escaping @Sendable () -> Void)
private func notifyJobsChanged()     // called after `try writer.write` returns in upsert, delete, setPaused — never inside the block, never from setNextFire/setLastRun/setRetry/setQueuedFire
// IrisEngine
func watchCoordinator() -> WatchCoordinator?
```
`sync(with:)`: for each job in `vanished(in:fileExists:)`, call the unavailable handler with `"watch path unavailable: \(watch.path)"` (the pause is a `setPaused`, which re-enters the hook; the second `sync` finds the job paused and converges); compute `roots(for:)` over the remaining jobs; start a stream for each new root — its task forwards every batch to the batch handler tagged with the root, and a stream that ends without the task being cancelled reports the root through the unavailable handler for every job on it (that is how `FileWatcher` signals a stream FSEvents refused to create); stop and drop each root with no remaining subscriber; touch nothing else.

`IrisEngine.start()` replaces :501-506 with: build `WatchCoordinator(ledger:, now: Date.init, recentWrites:, fire: { job, fire in await runner.fire(job: job, origin: .watcher(paths: fire.paths), watch: fire.summary) })`; `runner.setHeldPathsSource { await coordinator.takeHeldPaths($0) }`; `WatcherManager.shared.configure(ledger:)`, `setBatchHandler { await coordinator.deliver(root: $0, paths: $1) }`, `setUnavailableHandler { await runner.pauseUnavailable(job: $0, reason: $1) }`; `ledger.onJobsChanged { [weak self] in Task { await self?.syncWatches(ledger: ledger) } }` (set once); `await syncWatches(ledger: ledger)`; `coordinator.startLoop(everyMinute: { [weak self] in await self?.syncWatches(ledger: ledger) })`. `syncWatches` is `let jobs = try ledger.jobs(); await coordinator.sync(with: jobs); await manager.sync(with: jobs)` — coordinator first, so a fire cannot arrive for a subscriber that does not exist. The loop sleeps until `min(nextDeadline(), now + 60 s)`, is woken by an accepted event that moves the earliest deadline, then `tick(now: Date())`; the minute closure runs the periodic root stat.

- [ ] Tests first — `WatcherManagerSyncTests` (fake `StreamFactory` that records roots and hands the test each continuation; `fileExists` a closure over a set): `syncStartsOneStreamForTwoJobsOnOneRoot`; `aNestedRootGetsNoStream` (`/r` and `/r/sub` → `activeRoots == ["/r"]`); `theStreamStopsWhenTheLastSubscriberLeaves` (the fake's `stop` recorded once); `anUnchangedStreamIsNotRestarted` (a second `sync` with an unrelated schedule job added → no new factory call); `batchesReachTheHandlerTaggedWithTheRoot`; `aVanishedRootPausesTheWatch` (`fileExists` false → unavailable handler called with `"watch path unavailable: /gone"`; no stream); `aStreamThatEndsUnpromptedReportsUnavailable` (finish the continuation → handler called). `JobLedgerTests`: `onJobsChangedFiresAfterUpsertDeleteAndSetPaused` (a counter; three calls; inside the hook `ledger.jobs()` succeeds — proving it runs after the write returns); `cadenceWritersDoNotFireTheHook` (`setNextFire`, `setLastRun`, `setRetry`, `setQueuedFire` → counter unchanged); `aFailedWriteDoesNotFireTheHook`. `WatcherJobsTests`: drop `reload()` :14-28 and `reloadAdoptsLedgerWhenUnconfigured` :30-64 (both drove the removed API); restate `firePath` :66-91 to call `JobRunner.prompt` directly with the two paths (same three assertions). `ToolExecutorWorkspaceTests`: `watcherWithoutLedger` :103-110 unchanged; the `JobTools(ledger:)` callers compile.
- [ ] Implement; `swift test --filter "WatcherManagerSyncTests|WatcherJobsTests|JobLedgerTests|ToolExecutorWorkspaceTests|JobAdmissionTests"`; full suite; on-screen check per spec §9 A with `scripts/run-dev.sh`: a watch over a folder, an editor save-burst → one run after 3 s; an unattended `write_file` into the folder → no run, the count moves in `/jobs` (after Task 7; until then confirm no row); a save during a run → one held re-fire; deleting the folder pauses the watch with the reason; commit `feat(jobs): WatcherManager.sync keeps one stream per root, the ledger's onJobsChanged hook drives it, and a vanished root pauses the watch (#187)`.

---

## PR B — visibility (Tasks 6–8)

### Task 6: Tool arguments, the registration rule, refusals **[§5]**

**Files:** Modify `Sources/iris/ToolExecutor.swift` (declaration :94-106 — two sentences plus three optional parameters; dispatch :187-189 decodes them; `registerWatcher` :222-262 rewritten; the doc comment :222-229 rewritten), `Sources/iris/WatchRoot.swift` (`refusal(for:paths:home:)`), `Sources/iris/JobRunner.swift` nothing; Tests `Tests/irisTests/ToolExecutorWorkspaceTests.swift` (restate :46-65 and :67-101), `Tests/irisTests/ToolSurfaceTrimTests.swift` (the declaration pin), new `Tests/irisTests/WatchRootTests.swift`, `Tests/irisTests/RegisterWatcherTests.swift`.

**Interfaces (produces):**
```swift
struct RegisterWatcherArguments: Equatable, Sendable {
    let path: String; let instructions: String
    let quietWindowSeconds: Int?; let ignore: [String]?; let overlap: JobPolicy.Overlap?
    static func parse(_ args: [String: JSONValue]) -> Result<RegisterWatcherArguments, String>   // "Error: Missing path or instructions"; a non-array ignore or an unknown overlap is an error naming the argument
}
enum WatchRoot {
    static func canonical(_:fileExists:) -> String?                       // Task 1
    static let tooBroad = ["/", "/System", "/Library", "/usr", "/private", "/var", "/etc", "/bin", "/sbin"]
    /// nil = allowed. Both sides through canonical form, so `/var` also refuses `/private/var`; a volume root is any `/Volumes/<name>`.
    static func refusal(for canonical: String, paths: IrisPaths, home: String) -> String?
    // "that is too broad to watch; name a specific folder"
    // "that path is or contains Iris's own configuration; a watch there would react to itself"   (root == or contains or is under paths.configDir / paths.pluginsDir)
}
static let tooBroadRefusal / static let protectedRefusal / static let allIgnoredRefusal = "that ignore list would ignore every change; drop the pattern or watch a narrower path"
static let watchDescription = "Watch a directory for file changes and run your instructions in the background once it has been quiet for a few seconds (default 3). Iris's own file-tool writes into the folder are ignored, so a watch can safely write there."
```
Declaration parameters: `path`, `instructions` (as today), `quiet_window_seconds` (INTEGER, "1 to 300; outside is clamped"), `ignore` (ARRAY of STRING, "glob patterns relative to the path, e.g. `*.log`, `build/`"), `overlap` (STRING, `queue` or `skip`). The built-in ignore set, the ceiling and the never-concurrent rule are stated in the **result** sentence and `docs/jobs.md`, not in the declaration (invariant 6).

`registerWatcher` order: resolve (`resolvePath`) → `WatchRoot.canonical` must return non-nil and the path must be a directory, else `"That path does not exist or is not a directory: <resolved>"` → `refusal(for:paths:home:)` → `ignore` through `WatchGlob.ignoresEveryProbe` → clamp the window and remember whether it changed → find `jobs.first { .fsEvent && watch.path == canonical && createdInConversationId == conversationId }`: found → update `prompt`; `quietWindowSeconds`, `ignore`, `policy.overlap` only when supplied; `enabled = true`, `pausedReason = nil` unconditionally. Not found → `Job(name: uniqueName(slug(lastPathComponent)), prompt:, trigger: .fsEvent(FSWatch(path: canonical, quietWindowSeconds: window ?? 3, ignore: ignore ?? [])), createdInConversationId:, policy: JobPolicy(overlap: overlap ?? .queue))`. Result: `"updated your watch `notes`"` or `"created `notes-2`; `notes` belongs to another conversation — this folder now has 2 watches, each of which runs on every change"` (the second clause only when the count is above one), then `"It runs once the folder has been quiet for N s (M s when changes never stop) and never alongside its own previous run; it ignores .git/, .DS_Store, node_modules/, *~, *.swp, *.swx, .#*, 4913, *.tmp and Foundation's atomic-write temp files, plus your K patterns."`, then `"The window was clamped to N s."` when it was.

- [ ] Tests first — `WatchRootTests` (a volatile `IrisPaths` root and an injected `home`): `tooBroadRootsAreRefused` (each of the list, `home`, `/Volumes/Data`, and `/private/var` → the too-broad text); `protectedRootsInBothDirections` (`paths.configDir`, a child of it, and the `IrisPaths` root itself — which *contains* `config` — all refused; `home/Notes` allowed; the facts note `IrisPaths.isUnderProtectedWriteDir` covers only the "is under" direction). `RegisterWatcherTests` (an in-memory store, a temp directory, a `ToolExecutor` with `jobToolsProvider`): `argumentsDecodeAndClamp` (`quiet_window_seconds: 900` → stored 300 and the result says so); `ignoreProbeRefusal` (`["*"]`, `["**/*"]`, `["?*"]` refused with the text; `["*.*"]` and `["*.log"]` accepted — the probe list, not the pattern text, decides); `aMissingDirectoryIsRefused`; `sameConversationUpdatesAndPreservesOmittedArguments` (register with window 10 and `ignore: ["*.log"]`, register again with only new instructions → window 10 and the glob kept, `pausedReason` cleared, `enabled == true`); `anotherConversationGetsASuffixedWatch` (two jobs, `notes` and `notes-2`, the result names the count 2); `overlapDefaultsToQueueAndSkipIsHonoured`. `ToolExecutorWorkspaceTests`: **restate** `relativeWatcherResolvesToWorkspace` :46-65 with a real temp workspace containing `src` (the stored path is its canonical form) and **restate** `watcherReregistration` :67-101 as `reregistrationFromAnotherConversationForks` (two jobs, distinct ids, the first's prompt still `"first"`) — the old expectation is exactly what §0.5 reverses. `ToolSurfaceTrimTests.descriptionsStateTriggers` :96-127: add `#expect(decls["register_directory_watcher"]!.count <= 230)` and `contains("quiet")`, `contains("own file-tool writes")`, and that it does not contain `.git` (the built-in set stays out of the declaration).
- [ ] Implement; `swift test --filter "WatchRootTests|RegisterWatcherTests|ToolExecutorWorkspaceTests|ToolSurfaceTrimTests"`; full suite; commit `feat(jobs): register_directory_watcher takes quiet_window_seconds, ignore and overlap; refuses protected, too-broad and all-ignoring watches; keys watches by conversation (#187)`.

### Task 7: The card, the `/jobs` watch line, `list_jobs`, `get_job_run` **[§6]**

**Files:** Modify `Sources/iris/WatchSummary.swift` (`figuresText`), `Sources/iris/EventCard.swift` (`let watchSummary: WatchSummary?` — init :57-89 default `nil`; `init(from:)` after :131 with `try?`; `watchMetadataText`; `transcriptLine` :358-366 appends it in parentheses), `Sources/iris/EventCardView.swift` (:69 renders `card.metadataLine`), `Sources/iris/JobRunner.swift` (`EventCard(...)` at :872 and :1305 pass `watchSummary:`), `Sources/iris/JobLedger.swift` (`lastWatchSummary(jobId:)`), `Sources/iris/JobsCommand.swift` (`policySummary` :224-234; `render` :133 gains `lastBursts:`/`absorbed:`; `watchLine`), `Sources/iris/AppState.swift` (`.list` :2821-2839 wrapped in a `Task` that awaits `engine?.watchCoordinator()?.absorbedSinceLaunch()`), `Sources/iris/iris.swift` (`jobsListJSON` :3140-3175 gains the same two parameters; the caller at :2399 awaits the coordinator; `jobRunJSON` :3184-3211 adds `watchSummary`); Tests `Tests/irisTests/EventCardTests.swift`, `Tests/irisTests/JobsCommandTests.swift` (:251-257 extended), `Tests/irisTests/JobRunLedgerTests.swift`, `Tests/irisTests/JobToolsTests.swift` (where `jobsListJSON`/`jobRunJSON` are tested today).

`render` and `jobsListJSON` stay synchronous and pure: the callers read the coordinator and pass the figures in (`absorbed == nil` means no live coordinator — the `--run-job` process — and prints `—`).

**Interfaces (produces):**
```swift
extension WatchSummary {
    /// nil when changed, noise and ownWrites are all zero and no flag is set. Each figure only when non-zero:
    /// "<changed> changes · <noise> noise · <ownWrites> own writes", then " (cut at <ceilingSeconds> s)" when
    /// ceilingFired and the ceiling is known, " (cut at the ceiling)" when it is not, " (<overflow> not kept)", " (paths withheld by the guard)".
    func figuresText(ceilingSeconds: Int? = nil) -> String?
}
// EventCard
let watchSummary: WatchSummary?
var watchMetadataText: String? { watchSummary?.figuresText() }                 // the card has no window, so no figure
var metadataLine: String  // "\(elapsedText) · \(tokens) tokens" + (" · " + watchMetadataText when present)
// JobLedger
func lastWatchSummary(jobId: UUID) throws -> WatchSummary?   // newest row with watchSummary IS NOT NULL
// JobsCommand
static func render(jobs:lastRuns:usage:unacknowledged:unreadableJobs:now:, lastBursts: [UUID: WatchSummary] = [:], absorbed: [UUID: AbsorbedCounts]? = nil) -> String
static func watchLine(job: Job, lastBurst: WatchSummary?, absorbed: AbsorbedCounts?, hasCoordinator: Bool) -> String
// "`notes` — last burst: 12 changes · 3 noise · 1 own writes (cut at 30 s) · absorbed since launch: 41 noise · 7 own writes · 3 while paused"
// "`notes` — last burst: nothing fired yet · absorbed since launch: —"
// IrisEngine
nonisolated static func jobsListJSON(_ jobs:lastStatuses:usage:unreadableJobs:, lastBursts: [UUID: WatchSummary] = [:], absorbed: [UUID: AbsorbedCounts]? = nil) -> String
```
`policySummary` appends `quiet 10 s` when `quietWindowSeconds != 3` and `2 ignore` when `ignore` is non-empty. The watch line is emitted directly beneath the table, one per `.fsEvent` job in table order, before the global daily footer: a markdown table row cannot carry a second line, and this keeps `JobsCommandTests` :257's row string true. On the card, the ceiling is rendered as `(cut at the ceiling)` — the card carries no window and a literal `30 s` would be false for any other window; the `/jobs` line, which has the job, prints `(cut at \(watch.ceilingSeconds) s)`. `list_jobs` per-job fields: `quietWindowSeconds`, `ignore`, `lastBurst`, `absorbedSinceLaunch` — `null` for non-watches, and `absorbedSinceLaunch` `null` when there is no coordinator. `jobRunJSON` adds `watchSummary` as stored (`null` for non-watch rows).

- [ ] Tests first — `EventCardTests`: `anOlderCardDecodesWithNilWatchSummary` (a card JSON without the key; and one with `"watchSummary": "junk"` → `nil`); `watchSummaryRoundTrips`; `metadataLineWithFixedFigures` (`changed 12, noise 3, ownWrites 1, ceilingFired, overflow 500, pathsWithheld` → `"12 changes · 3 noise · 1 own writes (cut at the ceiling) (500 not kept) (paths withheld by the guard)"`; all-zero → `metadataLine` unchanged from today's; `changed 4` alone → `"4 changes"`). `JobsCommandTests`: extend :251-257 — the row string still holds and `out.contains("`inbox` — last burst: nothing fired yet · absorbed since launch: —")`; `watchLineWithBothHalves` (fixed `WatchSummary` and `AbsorbedCounts`, window 3 → `(cut at 30 s)`); `watchLineWithAWiderWindow` (window 10 → `quiet 10 s` in the policy column, `(cut at 100 s)`); `ignoreCountInThePolicyColumn` (`2 ignore`). `JobRunLedgerTests`: `lastWatchSummaryIsTheNewestNonNull`. `list_jobs`/`get_job_run` JSON: `listJobsCarriesWatchFields` (a watch and a schedule; the schedule's four fields are `null`; `absorbed: nil` → `absorbedSinceLaunch: null`); `getJobRunReturnsWatchSummaryAsStored`. `WatchCoordinatorTests.noiseAndOwnWritesNeverStartABurst` already proves an absorbed burst leaves no row — cite it, do not duplicate.
- [ ] Implement; `swift test --filter "EventCardTests|JobsCommandTests|JobRunLedgerTests|WatchCoordinatorTests"`; full suite; on-screen check per spec §9 B: the `/jobs` watch line and a card with counts; commit `feat(jobs): watch figures on the card, the /jobs watch line, list_jobs and get_job_run (#187)`.

### Task 8: Docs falsification and the spec status line **[§9 docs, invariant 9]**

**Files:** Modify `docs/agency/agency.md` (deliverable 4 at :81 → "landed: see `docs/specs/2026-09-22-agency-watches.md` and `docs/jobs.md`"; the loop-guard bullet at :65 now true — reword to "unattended writes"), `docs/specs/2026-09-21-agency-model-and-ledger.md` (the "Watches." handover paragraph :225-226 — the manager no longer starts one watcher per job; ruling 9 in §14 at :430 — annotate "superseded by D4: fires through `WatchCoordinator` → `JobRunner`"), `docs/specs/2026-09-22-agency-watches.md` (status line → **implemented**, PRs named), `Sources/iris/Job.swift` (the `FSWatch` comment :70-72 — already rewritten in Task 1; verify), `Sources/iris/iris.swift` (the deleted `watcherCallback` comment :2098-2109 — gone in Task 5; verify no other "Deliverable 4" remains: `grep -rn "eliverable 4" Sources/`), `Sources/iris/WatcherManager.swift` (:55-57 gone in Task 5; verify), `Sources/iris/ToolExecutor.swift` (:222-229 rewritten in Task 6; verify), `README.md` (:20 — "a watch fire for a job already running is dropped rather than started alongside it" → held and re-fired once with the union; add the quiet window, the ceiling, the self-write filter and what it cannot see), `docs/jobs.md` (:26-28 "Watching a path that is already watched rewrites that job's instructions in place instead of adding a second one" → the per-conversation rule; :329-331 "dropped instead, with no row at all … Coalescing them into one run after a quiet window is deliverable 4's job" → the new behaviour; a new **Watches** section: quiet window and ceiling, the built-in ignore set and `ignore`, `quiet_window_seconds`, `overlap` default `queue`, the self-write filter and what it cannot see — `run_command` host or container, MCP tools, plugin hooks, `--run-job`'s own writes — with the breaker as the backstop, one stream per root, `watch path unavailable`, the `/jobs` line and the card figures, the sleep/must-scan limit).

- [ ] Falsify first: `grep -rn -i "watch\|fsevent\|deliverable 4\|rewrites that job" README.md docs/jobs.md docs/agency/agency.md docs/specs/2026-09-21-agency-model-and-ledger.md Sources/iris/*.swift` and read every hit against the new behaviour; rewrite; `swift build`; full suite; commit `docs(jobs): watches — quiet window, self-write filter, one stream per root; deliverable 4 landed (#187)`.

---

## Self-review

- **Spec coverage:** §0.1 quiet window and ceiling → T3; §0.2 accumulate and re-fire once → T3 (`.queued`, `takeHeldPaths`) + T4 (union); §0.3 self-writes of unattended runs → T2 (registry, choke point) + T3 (`isOwn` per event); §0.4 built-in set and globs → T3 (`WatchGlob`, `builtInIgnore`) + T6 (`ignore` argument); §0.5 one stream per root, keyed by name and conversation → T5 (`roots(for:)`, nested collapse) + T6 (registration rule); §0.6 coordinator owns time, manager owns streams → T3 + T5 (`sync` from one hook); §0.7 absorbed burst writes nothing → T3 (`noiseAndOwnWritesNeverStartABurst`) + T7 (cited); §1 model and migration v11 → T1; §2 coordinator, subscribers, batch, tick, firing branches, bounds, prompt cap, no retry, sleep limit → T3 (prompt cap in `buildPrompt`; the sleep limit is documented in T8); §3 overlap for watches → T1 (default `queue` at creation) + T4 (union re-fire keeping `.queued`); §4 registry → T2; §5 tool surface and registration → T6; §6 row → T1, card and `/jobs` and `list_jobs` and `get_job_run` → T7; §7 stream lifecycle, hook, errors → T5 (vanished root, refused stream, once-a-minute stat) + T3 (ledger read failure → failed row) + T4 (`pauseUnavailable`); §8 tests distributed as named in each task, regressions restated in T4 (`watcherOverlapWritesNoRow`, `queuedFireRunsOnceAfterTheRun`), T5 (`WatcherJobsTests`), T6 (`watcherReregistration`, `relativeWatcherResolvesToWorkspace`), T7 (`JobsCommandTests` :257 extended); §9 delivery → the two-PR split below and the on-screen checks in T5 and T7; docs list → T8; §10 rulings: R-D4-1 in T2, the 32 s cap and the 1,000 bound and `whilePaused` and the watch-count sentence in T2/T3/T6.
- **Departures forced by the code, each stated in its task:** the choke point is `IrisEngine`'s dispatcher at iris.swift:2948 with the local `isUnattended` (no `isUnattendedRun` exists; the skill tools take no conversation id) — T2; `JobRun.watchSummary` and the column land in PR A — T1; `WatcherManager.sync` is a re-keying by root and `reload`/`setCallback`/`deliver`/`activeJobIds`/`JobTools.watchers` go — T5; `render`/`jobsListJSON` stay synchronous and the callers read the coordinator; the `/jobs` "second line" is a line beneath the table — T7; the card prints `(cut at the ceiling)` because it carries no window, `/jobs` prints the figure — T7; `.skipInFlight` re-asks once per ceiling (not per window) with no rows because no coordinator handler is ever the one holding the run — T3; `*.*` is not refused by the spec's own probe list (`sub/dir/c` has no dot) and the test pins that — T3/T6; the prompt is built before `ledger.begin` so the row carries the final `delivered`/`pathsWithheld` in one write — T4; `IrisPaths.isUnderProtectedWriteDir` covers one direction, `WatchRoot.refusal` covers both through canonical forms — T6.
- **Placeholders:** none. Every task names its files with line anchors, its signatures, its test names with what each asserts, and its commit message; every number and string is the spec's (3 s, ×10, 1…300, 100 + `and N more changed paths`, 1,000, `min(window, 30) + 2 s`, 32 s sweep, 10,000 valve, the eleven built-in patterns, the five probes, the refused roots, the refusal and result sentences, the `/jobs` and card strings).
- **Type consistency:** `WatchSummary` and `AbsorbedCounts` (T1) are used by T3 (built at fire), T4 (stamped on the row), T7 (card, `/jobs`, JSON); `WatchFire`/`WatchFireHandler` (T3) by T5 (production closure); `WatchCoordinator.takeHeldPaths(_:)` (T3) by T4 through `setHeldPathsSource` and T5's wiring; `WatchCoordinator.maxTrackedPaths` (T3) by T3's bound tests; `WatchCoordinator.sync(with:)` and `WatcherManager.sync(with:)` (T3, T5) by `IrisEngine.syncWatches` behind `JobLedger.onJobsChanged(_:)` (T5); `WatchRoot.canonical` (T1) by the migration, `registerWatcher` (T1, T6) and `WatchRoot.refusal` (T6); `WatchGlob` (T3) by the coordinator's matcher and T6's probe refusal; `JobRunner.Admission` (existing) is the handler's return everywhere.
- **Slicing note:** T1–T5 are PR A (behaviour): after T5 the suite is green and a watch coalesces, filters, holds, unions and pauses on a vanished root, with the row carrying the summary; T6–T8 are PR B (visibility): arguments and refusals, the figures on every surface, the docs. Each task ends green on its own. Recommend two PRs in that order, as spec §9 asks; do not merge T6 into PR A — the registration rule reverses two existing tests and belongs with the surface it explains.
