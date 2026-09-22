# Agency deliverable 4: Watches

Status: **proposed** (2026-09-22; revised the same day after an adversarial pre-review — see §10). Deliverable 4 of #187, after deliverables 1–3 (`2026-09-21-agency-model-and-ledger.md`, `2026-09-21-agency-runtime.md`). Argued from `docs/agency/agency.md` ("Watches. Fold `WatcherManager` onto the trigger model; quiet window; self-write filter; poll trigger" — the poll trigger landed in deliverable 3).

## 0. Decided

Each decision names its default and why; the cost of being wrong is what a reviewer should weigh.

1. **Quiet window = debounce with a ceiling.** A watch fires when its directory has been quiet for `quietWindowSeconds` (default 3), coalescing every path seen since the burst began; if changes never stop, it fires anyway once the burst has lasted `quietWindowSeconds × 10` (30 s at the default), and the next accepted event begins a new burst, ceiling included. The ceiling is a fixed multiple, not a second knob. *Why:* one run per save-burst, and a directory under continuous change still gets a run rather than starving. *Cost if wrong:* a burst that straddles the ceiling becomes two runs.
2. **Changes during a run accumulate and re-fire once.** Watches default to overlap `queue`. Events that arrive while the watch has a fire outstanding are held; when the run ends, the runner's held re-fire carries the union of the paths it held and everything the coordinator gathered since, and fires once. Under `skip` the coordinator holds the same way and offers the held set again once per ceiling until the run lets it through (R-D4-2). *Why:* a change made during a run must not be silently lost, which is what happens today; and the job must never run concurrently with itself. *Cost if wrong:* a watch under `queue` runs twice for one edit session — bounded, and the second run carries only what the first did not see.
3. **Self-writes are the file-tool writes of unattended runs.** Every tool that writes a filesystem path through `ToolExecutor` — today `write_file`, `create_skill`, `update_skill`, `delete_skill` — records the symlink-resolved path and the instant in one process-wide registry **when the writing conversation is unattended** (a job run, or a subagent or evaluator descended from one — `isUnattendedRun`). An event on such a path within the expiry is dropped and counted, and so is the sibling temp file an atomic write creates. A write made in an attended turn — the user asking Iris to write a note into the watched folder — is not recorded, so the watch reacts to it like any other change. Commands (`run_command`, host or container) and MCP tools are not seen; the docs say so, and the breaker is the backstop: a loop the filter cannot see ends in the job's breaker pause (default 6 runs an hour) with a card naming the figure, never in unbounded spend. `--run-job` is another process holding the store lock, so no watch is live to filter for; its writes are not recorded and need not be. *Why:* the loop the design doc names (a watch summarising a folder into a file in that folder) is an unattended run reacting to its own output; a foreground write is a human-driven action a watch is expected to notice ("index the note Iris just wrote for me"). Cross-watch loops (A writes where B watches, B writes where A watches) are two unattended runs and are filtered on both sides. *Cost if wrong:* an attended write that starts a chain is filtered from the second link on and bounded by the breaker before that; a user who wanted the watch to ignore Iris's foreground writes has no knob for it. Recorded as ruling R-D4-1 (§10).
4. **Noise = a built-in ignore set plus per-watch globs.** Always ignored: `.git/`, `.DS_Store`, `node_modules/`, `*~`, `*.swp`, `*.swx`, `.#*`, `4913` (Vim's directory-write probe), `*.tmp`, and Foundation's atomic-write temp forms (`.*.sb-*`, `(A Document Being Saved By *`). `register_directory_watcher` gains optional `ignore` globs. *Cost if wrong:* a watch that wanted `.git` activity needs a change to the built-in set.
5. **One stream per distinct root, fan-out to subscribers; watches keyed by name.** Several jobs may watch one path, each with its own window, globs, prompt and destination; they share one FSEvents stream, and a path nested under another watched path gets no stream of its own — its subscriber is served by the ancestor's stream, once. Re-registering the same path from the same conversation updates that conversation's watch; from another conversation it creates a second watch. *Why:* today a second registration on a path silently rewrites the first conversation's watch. *Cost if wrong:* two watches on one busy path cost two runs per burst, which is what two watches means.
6. **The coordinator owns time; the manager owns streams.** Debounce timers, held paths, accumulation and counts live in a new `WatchCoordinator`; `WatcherManager` becomes a diff-based stream owner (`sync(with:)`) so no stream restarts for an unrelated change and no timer dies on reload. Both are synced from one ledger hook. *Why:* today's stop-all/restart-all reload would destroy any timer held in the manager.
7. **A burst in which every event was absorbed never fires: no row, no card.** Nothing happened. Absorbed counts accumulate in memory per watch and appear in `/jobs`. *Cost if wrong:* a user debugging a watch that "never fires" has to open `/jobs` to see it was all noise — which is where the numbers are.

Not in this deliverable: watches over individual files (a watch is a directory, as today), content-based filtering, a gate on a watch (the quiet window and globs cover the cases the pipeline diagram meant), cross-watch event publishing, per-watch retention caps, `run_command`-write detection, and FSEvents flag handling (`FileWatcher` yields paths only; widening it is a follow-up if the must-scan case in §7 bites).

## 1. Model

`FSWatch` (`Sources/iris/Job.swift`) gains one field, `decodeIfPresent` (invariant 1):

```swift
struct FSWatch: Codable, Equatable, Sendable {
    var path: String                 // canonical (symlink-resolved, standardised), absolute
    var quietWindowSeconds: Int      // 1…300, default 3; stored today, enforced by this deliverable
    var ignore: [String]             // per-watch globs relative to `path`; default []
}
```

`quietWindowSeconds` outside 1…300 clamps on decode and on the tool. The ceiling is `quietWindowSeconds * 10`, derived, never stored.

**Migration v11** is additive: `ALTER TABLE job_runs ADD COLUMN watchSummary TEXT` (§6), and a data step that rewrites `FSWatch.path` in every `.fsEvent` row to its canonical form; a row whose path no longer exists is left as stored and pauses at launch per §7. Without the rewrite, every existing watch whose path passes through a symlink (`/tmp`, `/var`, a symlinked workspace) would stop matching silently. An older build reading the new column ignores it.

`Job.policy.overlap` for a watch defaults to `.queue` at creation; existing rows keep what they have and a pre-existing `.skip` is honoured (§3).

`Trigger.summary` for a watch stays `watch <path>`; the policy column (§6) carries the window and globs when not default.

## 2. The watch coordinator

`actor WatchCoordinator` (new file `Sources/iris/WatchCoordinator.swift`). Constructed with: a ledger; `now: @Sendable () -> Date`; a `RecentWrites` registry; and a fire handler. Injectable throughout; `IrisEngine` owns the production instance the way it owns the runner, and tests build their own.

**The seam**, defined once:

```swift
struct WatchFire: Sendable, Equatable { let paths: [String]; let summary: WatchSummary }
typealias WatchFireHandler = @Sendable (Job, WatchFire) async -> JobRunner.Admission?
```

Production: `{ job, fire in await runner.fire(job: job, origin: .watcher(paths: fire.paths), watch: fire.summary) }`. `JobRunner.fire` gains `watch: WatchSummary? = nil` and stamps it on the row it begins (§6). The handler's return is the admission the coordinator branches on; `nil` means the job is gone or unreadable.

**Subscribers.** `WatchCoordinator.sync(with jobs: [Job])` is called from the ledger hook (§7) immediately before `WatcherManager.sync`. Rules: a new or re-registered subscriber starts with an empty burst and **keeps** its `absorbedSinceLaunch`; a subscriber whose job is gone, disabled or paused is removed with its `pending`, `heldPaths` and `absorbedSinceLaunch` (`/jobs` has nothing to show them against); a window or glob edit takes effect from the next accepted event and does not re-filter `pending`. Nothing is keyed by a job that no longer exists, so nothing leaks across a long session.

Per subscriber (`jobId`) it keeps:

| field | meaning |
|---|---|
| `watch: FSWatch` | as of the last `sync` |
| `pending: Set<String>` | paths accepted this burst — at most `maxTrackedPaths` (1,000) distinct; beyond that a new path is counted in `changed` and `overflow` but not kept |
| `heldPaths: Set<String>` | paths handed to a fire whose handler has not returned, plus anything accepted meanwhile — same bound, same overflow rule |
| `fireOutstanding: Bool` | a handler call is in flight for this subscriber |
| `burstBegan: Date?`, `lastAccepted: Date?` | timers |
| `coalesced: Int`, `changed: Int`, `overflow: Int`, `noise: Int`, `ownWrites: Int` | this burst (zero between bursts); `changed` counts every distinct accepted path, kept or not |
| `absorbedSinceLaunch: AbsorbedCounts` | `{ noise: Int, ownWrites: Int, whilePaused: Int }`, all bursts and between bursts, memory only |

**A burst** begins with the first accepted event and ends when it fires or is dropped; a ceiling fire ends it and the next accepted event begins a new one, ceiling included; absorbed events between bursts add to `absorbedSinceLaunch` only.

**On a batch** (a stream root and the `[String]` its FSEvents callback delivered; one callback may deliver a path once with several flags OR'd, which counts once): the batch is fanned out once, to every subscriber whose watch root covers each path by lexical, case-insensitive prefix after `IrisPaths.canonicalPath` (R-D4-5, R-D4-7) — the coverage test itself is lexical, never a `stat` of the event path, because the root is canonical and FSEvents reports paths under it, and a delete event names a path that no longer exists. For each subscriber and path: matches the built-in set or the subscriber's globs → `noise += 1`; else the registry says it is Iris's own (§4) → `ownWrites += 1`; else if `fireOutstanding` → insert into `heldPaths`; else insert into `pending`, set `burstBegan` if nil, `lastAccepted = now`, `coalesced += 1`. A batch that accepted nothing changes no timer. Which counter an absorbed event lands in is decided **per batch, not per position within it** (R-D4-6): a batch that accepts at least one path, or that arrives while a burst is already open, counts its absorbed events in the burst as well as since launch; a batch that accepts nothing counts them since launch only.

**Evaluation** is `func tick(now: Date) async`, the injectable heart: for each subscriber with `pending` non-empty and no fire outstanding, the deadline is the earlier of `lastAccepted + quietWindow` and `burstBegan + quietWindow × 10`; when `now` has passed it, the subscriber fires. The production loop is a thin wrapper: sleep until the earliest deadline (or until woken by an accepted event), then `tick(now: now())`. Tests call `tick` directly with a chosen instant; nothing in the coordinator sleeps on its own clock.

**Firing** a subscriber:

1. Read the job row fresh from the ledger. Missing → drop `pending`, end the burst, count nothing. `enabled == false` or `pausedReason != nil` → drop `pending`, end the burst, and add its `changed` to `absorbedSinceLaunch.whilePaused`, so a user who pauses a watch, works for an hour and resumes can see in `/jobs` that changes happened meanwhile (`sync` removes the subscriber and its counts when the pause is a ledger change, so this covers the window between the change and the sync).
2. Move `pending` into `heldPaths`, set `fireOutstanding`, end the burst, and build `WatchFire(paths: sorted(heldPaths), summary:)` with the burst's counts. **The fire is dispatched in a `Task` of its own; the loop never awaits a run** — at most one fire per subscriber is outstanding, and other subscribers keep their windows.
3. The handler returns the admission:
   - `.run` — the run started with these paths. Remove them from `heldPaths`; anything accepted meanwhile stays held. When the handler returns (the run is over), clear `fireOutstanding`; held paths, if any, begin a new burst with `burstBegan = lastAccepted = now`, so the quiet window applies from the end of the run.
   - `.queued` (overlap `queue`, job in flight) — the paths stay in `heldPaths`. The runner's held re-fire will take them (§3). Clear `fireOutstanding` when that re-fire's handler returns.
   - `.skipInFlight` (overlap `skip`) — the paths stay in `heldPaths`; the runner writes no row for a watch skip, as today. The subscriber offers the held set again once per **ceiling**, not once per window (R-D4-2): the run in flight is never one of the coordinator's own handlers, so there is nothing to wait on, and the ceiling is what stops a busy directory calling admission every window for the length of a run.
   - any other refusal (paused, breaker, budget, unavailable) — the runner's normal row and card; `heldPaths` are dropped, because a refused job will not be admitted a moment later and re-firing would write a row per burst.
   - `nil` — the job is gone or unreadable; drop everything for the subscriber and count nothing.

At every instant a path is in exactly one of `pending`, `heldPaths`, or a started run. Both sets are bounded at `maxTrackedPaths = 1,000` distinct paths: a burst or a hold that exceeds it keeps the first thousand, counts every further distinct path in `changed` and `overflow`, and the row and card report the true `changed` — the same shape as the registry's bound, and for the same reason: a build writing thousands of files into a watched directory during a long `queue`d run must cost a number, not memory.

**Prompt.** The paths go into the run through `JobRunner.prompt`'s existing `fs_event_paths` block, each path through the tier-1 normaliser and the block through the injection guard at tier 3 — a filename is chosen by whoever can write into the watched directory (`~/Downloads` is the review docs' example). The cap is applied before the guard: at most 100 paths plus one line `and N more changed paths`, so the guard never sees an unbounded block. If the guard blocks the block, the run gets the prompt with the blocked marker and no paths, the row's `watchSummary.delivered` is 0 with `pathsWithheld = true`, and the card says so; today that case is silent.

**Watch fires never retry** (deliverable 3's rule stands): a failed watch run is reported and the next burst runs it again with real paths.

Timers are wall-clock through the injected `now`. After the Mac sleeps, FSEvents delivers what it can on wake; it may coalesce a long gap into a must-scan flag that `FileWatcher` discards today, so a backlog's detail can be lost and the watch fires on the next real change. Documented as a limit; carrying flags through `FileWatcher` is the follow-up if it bites.

## 3. Overlap for watches

`register_directory_watcher` creates the job with `policy.overlap = .queue`. The runner's held re-fire (deliverable 3) gains one seam: before re-firing an origin whose root is `.watcher`, it asks `coordinator.takeHeldPaths(jobId)` and fires `.queued(from: .watcher(paths: held.paths ∪ taken))`, sorted and deduplicated — **a union, never a replacement**, and the `.queued` wrapper is kept so the row still records `queued` and `gateApplies` still reads the root. Because the coordinator moves paths into `heldPaths` before calling the handler (§2 step 2), the re-fire always finds what was fired plus what arrived since; the race in which a run ends before the coordinator has stashed its paths cannot occur.

A job created before this deliverable, or one whose user chose `skip`, follows §2's `.skipInFlight` branch: nothing lost, re-fire not immediate.

## 4. The recent-writes registry

`actor RecentWrites` (new, `Sources/iris/RecentWrites.swift`). **One instance per process:** `RecentWrites.shared`, injected into the coordinator and into every engine (`IrisEngine(recentWrites:)`, defaulted to `.shared`), and threaded by `SubagentManager` and `GoalEvaluator` to the engines they build, so a subagent's or evaluator's write reaches the same registry as the foreground's. Tests construct their own and inject it; the singleton is never mutated from a test (invariant 7).

Entries: `(path: String, at: Date)`, where `path` is `URL(fileURLWithPath: resolved).resolvingSymlinksInPath().standardizedFileURL.path`, computed **at the hook site**, not merely `ToolExecutor.resolvePath`'s output (which expands `~` and joins the workspace but does not resolve symlinks, so it would never match a root FSEvents reports through a symlink).

**Fed** from one choke point: `ToolExecutor` records every path it writes or unlinks on success — `write_file`, `create_skill`, `update_skill`, `delete_skill` today — through `recentWrites.record(path)`, **only when the calling conversation is unattended** (`isUnattendedRun`; R-D4-1). Attended writes are not recorded. A tool added later that writes a path records it there; §8's test pins the list against `getTools()`. Not fed: `run_command` (host or container), MCP tools, plugin hooks — documented in `docs/jobs.md`. The existing `recordSubagentWrite` call stays for its own purpose.

**Consulted** by the coordinator per event path with `isOwn(path, within: expiry)`, where `expiry = min(quietWindow, 30) + 2 s`: past 30 s a write and an edit are no longer plausibly the same event, and the 2 s is FSEvents' stream latency (1 s) with headroom. A match is any of: the exact path; the parent directory of a recorded path (the directory-modified event a file write produces); or a **sibling** of a recorded path whose basename has one of Foundation's atomic-write temp forms (`.<name>.sb-*`, `<name>.tmp`, `(A Document Being Saved By *`) — `ToolExecutor.writeFile` writes atomically, so every Iris write produces a temp file's create, rename and remove beside the final path. Entries are not consumed on match (one write produces several events); expiry ends their effect. A stale entry must never swallow a genuine hand edit minutes later — the plugins panel's `LegacyFileWatchSuppressor` records the same reasoning with its 3 s expiry.

**Bounds.** Swept by time first: entries older than the longest live expiry (32 s) are removed on every `record`. A count bound of 10,000 is a safety valve only; eviction by count is a filter *bypass* — a run that writes more files than the bound would see its earliest files' events as someone else's — so the number is set where no burst reaches it, and anyone lowering it should know which way it fails.

The registry is not a tool and nothing model-facing reads it.

## 5. Tool surface and registration

`register_directory_watcher` (all attended conversations; still undeclared and refused in unattended runs, deliverable 2's rule). Its declaration stays unconditional, so its description is kept to two sentences: the quiet-window default and that Iris's own file-tool writes are ignored. The built-in ignore set, the ceiling and the never-concurrent rule are stated in `docs/jobs.md` and in the tool's *result* sentence, not in the declaration (invariant 6: this is a per-turn prompt cost; `ToolSurfaceTrimTests` pins the declaration's size).

| argument | type | rule |
|---|---|---|
| `path` | string | canonicalised (symlinks, `..`); must be an existing directory. Refused if it **is or contains** `~/.iris/config` or `~/.iris/plugins` (D2 §15 write-protects both for every caller because a plugin can spawn an MCP command at next launch; a watch there reacts to its own configuration). Refused as too broad: `/`, the home directory itself, any volume root, `/System`, `/Library`, `/usr`, `/private`, `/var`, `/etc`, `/bin`, `/sbin` — "that is too broad to watch; name a specific folder". |
| `instructions` | string | as today |
| `quiet_window_seconds` | int, optional | 1…300; outside clamps and the result sentence names the value used |
| `ignore` | [string], optional | globs relative to the watch path. Refusal is decided by the compiled matcher, not the pattern text: the set is run against a fixed probe list (`a.txt`, `dir/b.md`, `.hidden`, `x.swift`, `sub/dir/c`); if it matches every probe it is refused: "that ignore list would ignore every change; drop the pattern or watch a narrower path". |
| `overlap` | `queue`\|`skip`, optional | default `queue` for watches |

**Registration rule.** Watches are keyed by name (the path's last component, suffixed on collision, as today). Same `createdInConversationId` and same canonical path → update that job in place: **omitted optional arguments leave the stored value untouched; only what is supplied is updated**; `enabled = true` and `pausedReason = nil` are unconditional, because re-registering is a request for the watch to be on. Different conversation, same path → a new job with a suffixed name. The result sentence says which happened ("updated your watch `notes`" / "created `notes-2`; `notes` belongs to another conversation — this folder now has 2 watches, each of which runs on every change") and names the built-in ignore set once. There is no hard cap on watches per path: they are created only from attended conversations, so the count is a human's choice; naming it at the moment it grows is what makes the cost visible.

`schedule_job` is untouched. The read-only allowlist is untouched: a read-only watch cannot write, so the filter earns its keep on `mutating` watches and on other conversations' writes into the watched folder; the sandbox rule from deliverable 3 is unchanged. Background runs still cannot register a watch.

## 6. Observability

**Run row.** `job_runs.watchSummary` (nullable TEXT, JSON, migration v11) decoded leniently into:

```swift
struct WatchSummary: Codable, Sendable, Equatable {
    var delivered: Int       // paths handed to the run (≤ changed; 0 when withheld)
    var changed: Int         // distinct paths in the burst, kept or not
    var overflow: Int        // distinct paths beyond maxTrackedPaths, counted but not kept
    var coalesced: Int       // accepted path entries as the manager delivered them
    var noise: Int           // absorbed this burst
    var ownWrites: Int       // absorbed this burst
    var ceilingFired: Bool   // the burst was cut at the ceiling
    var pathsWithheld: Bool  // the injection guard blocked the path block
}
```

`JobRun.watchSummary: WatchSummary?` and `EventCard.watchSummary: WatchSummary?` are both `decodeIfPresent`, default `nil` (invariant 1); older rows and cards render as today. The card carries its own copy because a card is persisted verbatim and never reads the row later. `get_job_run` returns it as stored. Null for non-watch rows.

**Card.** The outcome line is the run's output as today. The metadata line (tokens, duration) gains, only when non-zero: `<changed> changes · <noise> noise · <ownWrites> own writes`, then `(cut at 30 s)` when the ceiling fired, `(N not kept)` when the bound was hit, and `(paths withheld by the guard)` when they were. `coalesced` appears only on the row and in `get_job_run`. A fully absorbed burst writes no row and no card (§0.7).

**`/jobs`.** The policy column adds `quiet 10 s` when not default and `2 ignore` when globs are set. A watch row adds a second line with two halves from two sources: `last burst:` from the ledger's newest `watchSummary` for the job (survives relaunch; "nothing fired yet" when there is none), and `absorbed since launch: 41 noise · 7 own writes · 3 while paused` from the coordinator's memory (0 after a relaunch). `/jobs` awaits the coordinator for the second half and prints `absorbed since launch: —` when there is no live coordinator (the `--run-job` process). `list_jobs` carries `quietWindowSeconds`, `ignore`, `lastBurst` (the `WatchSummary`) and `absorbedSinceLaunch` (`AbsorbedCounts`) as fields, null for non-watches.

## 7. Stream lifecycle and errors

`WatcherManager` keeps one FSEvents stream per distinct canonical watch root and exposes `sync(with jobs: [Job])`: compute the set of roots across enabled, unpaused `.fsEvent` jobs, **collapse nested roots** (a root with an ancestor in the set gets no stream of its own — the ancestor's stream, which is recursive and already carries per-file events, serves it), start a stream for each new root, stop the stream for each root with no remaining subscriber, and touch nothing else. Every stream's batches go to the coordinator tagged with the stream's root; the coordinator fans out once (§2).

**The hook.** `JobLedger` is a `Sendable` final class of `let`s and a lock, so the hook is `private let jobsChanged = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)` with `func onJobsChanged(_ hook: @escaping @Sendable () -> Void)`, set once by `IrisEngine.start()`. It is invoked **after** the `writer.write` block returns — never inside it, or the hook's own `jobs()` read would re-enter the writer — and only from `upsert`, `delete` and `setPaused`; the cadence writers (`setNextFire`, `setLastRun`, `setRetry`, `setQueuedFire`) never change the watch set and never fire it. The hook body is `Task { let jobs = try ledger.jobs(); await coordinator.sync(with: jobs); await manager.sync(with: jobs) }`, so no writer thread waits on an actor. Pause, resume, disable, delete and re-registration therefore take effect within the same second, with no restart of unrelated streams and no lost timer.

**Errors.**
- A watch whose path does not exist at launch, or whose stream FSEvents refuses to create, pauses itself with `pausedReason = "watch path unavailable: <path>"` and a card, rather than starting nothing silently. `/jobs resume` retries.
- FSEvents does **not** stop a stream when its root is deleted or renamed; it keeps running and delivers nothing further (a root-changed flag `FileWatcher` discards). So a vanished root is detected by `sync`, which stats every watch root: it runs on every job change and, additionally, once a minute from the coordinator's loop. A root that is gone pauses the watch with `watch path unavailable: <path>` and a card. The three-consecutive-failures ladder (a failed run row each time, then the pause) covers only a root that disappears between a fire and its run.
- A ledger or registry read failure during a fire drops the burst and writes a failed run row naming the failure — never a silent drop, and never a fire with the self-write filter bypassed. Firing without the filter is the one direction that can loop (every event would read as someone else's), so the safe failure is not to fire and to say so.

## 8. Tests

All headless: `tick(now:)` driven with chosen instants, a fake event source the test feeds batches into, an injected fire handler returning chosen admissions, an in-memory ledger, a per-test `RecentWrites`; no test touches `~/.iris`, real FSEvents, a real directory to provoke an event, `ConfigManager.shared`, `WatcherManager.shared`, `RecentWrites.shared`, or a shared ledger's `onJobsChanged` (invariant 7 — the singletons are reached only through injection, as the runner's seams are).

Coordinator: eight batches within 2 s → one fire, eight paths, when `tick` passes 3 s of quiet; a batch every second → fires at the 30 s ceiling with everything so far, and the next accepted event starts a new burst with a new ceiling; noise-only and own-write-only batches never start or extend a burst and never fire, and their counts land in `absorbedSinceLaunch` only; a mixed batch accepts only the rest and per-burst counts start at zero with the burst; two subscribers on one root get independent windows and counts; a child-root subscriber is served once by the ancestor's stream and never twice; a fire is dispatched without blocking — a second subscriber still fires while the first's handler never returns; `.run` removes only the fired paths from `heldPaths` and later arrivals begin a new burst at run end; `.queued` keeps the paths held and `takeHeldPaths` returns fired plus later; `.skipInFlight` holds and does not call the handler again until it returns; other refusals drop held paths; `nil` drops the subscriber's state; `sync` keeps `absorbedSinceLaunch` across a re-registration and removes a paused job's state; the 100-path cap is applied before the guard and `delivered`/`pathsWithheld` reflect a blocked block; a burst of 1,500 distinct paths keeps 1,000, reports `changed = 1500`, `overflow = 500`; a paused job's dropped burst lands in `whilePaused`; a simulated long gap fires once on the first `tick` after it.

Runner seam: the held re-fire is a union that keeps the `.queued` wrapper; `triggerKind` stays `queued`; `watch:` lands on the row.

Registry: an attended write is not recorded and an unattended one is (R-D4-1); expiry at exactly `min(window, 30) + 2 s`; exact, parent and sibling-temp matches; no consumption on match; the time sweep and the 10,000 valve; the hook actually feeds it — a scripted run calls `write_file` into the watched root and the coordinator absorbs the final path and its atomic temp sibling; the recorded path is symlink-resolved; the tool list pinned against `getTools()`.

Manager: `sync` starts one stream for two jobs on one root, none for a nested root, stops the stream when the last subscriber leaves, does not restart an unchanged stream; a vanished root pauses the watch with the reason; `onJobsChanged` fires after the write returns and not from the cadence writers.

Tool and rule: argument decoding, clamps, the probe-list refusal (`*`, `**/*`, `*.*`, `?*`), protected and too-broad roots refused; same conversation updates with omitted arguments preserved; another conversation gets a suffixed watch; `overlap` default `queue`; the declaration's size in `ToolSurfaceTrimTests`.

Row, card, `/jobs`, `list_jobs`: lenient decode of `watchSummary` on `JobRun` and `EventCard` (an older card decodes with `nil`); rendering with fixed figures, both halves of the `/jobs` line and the no-coordinator dash; an absorbed burst leaves no row.

Regressions restated: `watcherOverlapWritesNoRow` and the queued-watch case in `JobAdmissionTests` — an unconfigured watch now takes the `queue` branch; the held re-fire carries merged paths.

## 9. Delivery

Spec PR (this document), then two execution PRs:

- **A — behaviour:** `FSWatch.ignore` and migration v11 (column + canonical rewrite), `WatchCoordinator` with `tick`, `RecentWrites` and the `ToolExecutor` choke point, `WatcherManager.sync` and the ledger hook, the runner's `watch:` parameter and union re-fire, watch default `queue`, the vanished-root pause. On-screen check: a watch over a folder; a save burst from an editor yields one run after the window; an Iris `write_file` into the folder yields no run and the count moves; a save during a run yields one held re-fire; deleting the folder pauses the watch with the reason.
- **B — visibility:** tool arguments and the registration rule, `watchSummary` on card and `list_jobs`, the `/jobs` watch line, the withheld-paths case, docs. On-screen check: the `/jobs` watch line and a card with counts.

Docs falsified by this deliverable (invariant 9): `docs/agency/agency.md` deliverables list (4 landed); `docs/specs/2026-09-21-agency-model-and-ledger.md` handover paragraph and ruling D2-R9; the comments in `JobRunner`, `WatcherManager.reload` ("FSEvents streams are cheap to recreate"), `ToolExecutor.registerWatcher` ("re-registering a path already watched rewrites that job … in place"), `iris.swift`'s watcher callback and `FSWatch` that say deliverable 4 will do this; README's jobs bullet; `docs/jobs.md` (new Watches section, incl. what the self-write filter cannot see).

## 10. Decided in review

- **R-D4-1 (home review, 2026-09-22): self-writes are the writes of unattended runs, not of every conversation.** The named loop is an unattended run reacting to its own output; a foreground write into a watched folder is a human-driven change the watch should notice ("index the note Iris just wrote for me"), and filtering it would be the decision most likely to surprise someone. Cross-watch loops are unattended on both sides and remain filtered; a chain started by an attended write is filtered from its second link and bounded by the breaker before that. Cost if wrong: no knob to make a watch ignore Iris's foreground writes.
- **R-D4-2 (2026-09-22): a `skip` subscriber re-asks once per ceiling, not once per window.** §2's letter had the subscriber wait for "the handler that started the run" to return, but that handler is never one of the coordinator's — at most one fire is outstanding per subscriber, so the run in flight is a `/jobs run` or an approved call, and there is nothing to wait on. Re-asking writes no row for a watcher origin (`JobRunner.fire` returns before `recordSkip`) but costs two ledger sums per ask, so the interval is the ceiling: at the default, one ask per 30 s for the length of a human-started run rather than one per 3 s. The grid is the burst's own ceiling, so a watch that fired on its window still waits the full ceiling from the burst.
- **R-D4-5 (2026-09-22, amended): event paths are normalised with `IrisPaths.canonicalPath`, not `standardizingPath`.** The `/private` strip in `standardizingPath` is conditional on the leaf existing, so a delete event — a path that by definition no longer exists — under `/var`, `/tmp` or `/etc` arrives spelled `/private/…` and matches neither the canonical root nor the registry entry the write recorded. `canonicalPath` resolves the deepest existing ancestor and re-appends what is missing, which is the same helper the roots and `RecentWrites` already use, so all three agree on one spelling. Coverage is then a lexical prefix test on canonical forms, as §2 always said.
- **R-D4-6 (2026-09-22): an absorbed event's attribution is decided per batch, not per position within it.** Consulting "is a burst open" per event, in the order one FSEvents callback happened to coalesce its paths, makes `deliver([".DS_Store", "a.swift"])` and `deliver(["a.swift", ".DS_Store"])` report different figures for the same batch. §6's card ("40 changed, 12 noise absorbed") must not depend on an ordering no user can see, reproduce or reason about. So the decision is taken once for the whole batch, in the gather pass: accepted anything, or arrived during an open burst or a hold → the burst counts it too; otherwise since-launch only. Cost if wrong: an absorbed event that arrives in the same callback as the first accepted path is attributed to the burst that callback began, which is the reading a person would give it anyway.
- **R-D4-7 (2026-09-22): root coverage and ignore-glob matching are case-insensitive; the stored root keeps its spelling.** `realpath` does not case-normalise — measured on APFS, `/tmp/CaseProbe` resolves to `/private/tmp/CaseProbe` and keeps the caller's casing — so a root registered as `~/Documents/NOTES` against a directory spelled `Notes` is stored with the user's casing while FSEvents reports the disk's, and a case-sensitive prefix test would have every event miss: a watch that silently never fires, with `/jobs` showing zero absorbed as well as zero fired, so even §0.7's diagnostic says nothing. The canonical root keeps its own spelling (it is what the migration wrote and what `WatcherManager` keys streams by) and the event keeps its own in the set and the prompt. Cost if wrong: on a case-sensitive volume, two sibling directories differing only by case are one watch, so a watch on `src/` also absorbs events under `SRC/` — the rarer configuration, and it over-delivers where the alternative under-delivers to nothing.
- **Home review, same day:** the registry expiry is bounded independently of the window (already `min(window, 30) + 2 s` in the pre-review revision); `pending`/`heldPaths` are bounded at 1,000 distinct paths with the overflow counted in `changed`/`overflow`; a burst dropped because the job was paused or disabled is counted in `absorbedSinceLaunch.whilePaused`; the registration result names how many watches now cover the path; the breaker's terminal behaviour is stated in §0.3.

- **Pre-review (2026-09-22, adversarial, before the human read it):** eight blocking findings and seventeen should-fixes folded into this revision. The ones that changed the design: the fire seam returns the admission and carries the summary (§2); a fire never blocks the coordinator's loop and at most one is outstanding per watch (§2); the held re-fire is a union that keeps its `.queued` wrapper, and paths are held before the handler is called (§3); the self-write filter matches the atomic-write temp sibling and records symlink-resolved paths (§4); one registry per process, threaded to subagent and evaluator engines (§4); existing watch roots are canonicalised by the migration and event paths are matched lexically, never stat'ed (§1, §2); the coordinator has an explicit `sync` and a `tick(now:)` seam (§2); nested roots share one stream (§7); a vanished root is found by a periodic stat, because FSEvents never stops the stream (§7); the registry expiry is capped at 32 s and swept by time (§4); the ignore refusal is decided by a probe list (§5); the tool's declaration stays two sentences (§5).
