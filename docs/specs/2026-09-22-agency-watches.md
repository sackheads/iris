# Agency deliverable 4: Watches

Status: **proposed** (2026-09-22). Deliverable 4 of #187, after deliverables 1–3 (`2026-09-21-agency-model-and-ledger.md`, `2026-09-21-agency-runtime.md`). Argued from `docs/agency/agency.md` ("Watches. Fold `WatcherManager` onto the trigger model; quiet window; self-write filter; poll trigger" — the poll trigger landed in deliverable 3).

## 0. Decided

Each decision names its default and why; the cost of being wrong is what a reviewer should weigh.

1. **Quiet window = debounce with a ceiling.** A watch fires when its directory has been quiet for `quietWindowSeconds` (default 3), coalescing every path seen since the burst began; if changes never stop, it fires anyway once the burst has lasted `quietWindowSeconds × 10` (30 s at the default), then starts a new burst. The ceiling is a fixed multiple, not a second knob. *Why:* one run per save-burst, and a directory under continuous change still gets a run rather than starving. *Cost if wrong:* a burst that straddles the ceiling becomes two runs.
2. **Changes during a run accumulate and re-fire once.** Watches default to overlap `queue`. Events that arrive while the watch's run is in flight are collected; when the run ends the runner's held re-fire asks the coordinator for the merged paths and fires once after the quiet window. Under `skip` the coordinator still accumulates and the next window fires with everything. *Why:* a change made during a run must not be silently lost, which is what happens today; and the job must never run concurrently with itself. *Cost if wrong:* a watch under `queue` runs twice for one edit session — bounded, and the second run carries only what the first did not see.
3. **Self-writes are any Iris conversation's file-tool writes.** Every `write_file`, `edit_file` and `create_skill` from any conversation — foreground, job run, subagent, evaluator, `--run-job` — records its canonical path and instant in a process-wide registry; an event on such a path within the expiry is dropped and counted. Commands (`run_command`, host or container) are not seen and the docs say so; the breaker stays the backstop. *Why:* the loop the design doc names (a watch summarising a folder into a file in that folder) is Iris reacting to itself regardless of which conversation wrote; the hook that knows a write's resolved path already exists. *Cost if wrong:* a user who wanted a watch to react to a foreground turn's write into the watched folder does not get a run — they get a count.
4. **Noise = a built-in ignore set plus per-watch globs.** Always ignored: `.git/`, `.DS_Store`, `node_modules/`, `*~`, `*.swp`, `*.swx`, `.#*`, `4913` (Vim's directory-write probe), `*.tmp`. `register_directory_watcher` gains optional `ignore` globs. *Cost if wrong:* a watch that wanted `.git` activity needs a change to the built-in set.
5. **One stream per distinct path, fan-out to subscribers; watches keyed by name.** Several jobs may watch one path, each with its own window, globs, prompt and destination; they share one FSEvents stream. Re-registering the same path from the same conversation updates that conversation's watch; from another conversation it creates a second watch. *Why:* today a second registration on a path silently rewrites the first conversation's watch. *Cost if wrong:* two watches on one busy path cost two runs per burst, which is what two watches means.
6. **The coordinator owns time; the manager owns streams.** Debounce timers, accumulation and counts live in a new `WatchCoordinator`; `WatcherManager` becomes a diff-based stream owner (`sync(with:)`) so no stream restarts for an unrelated change and no timer dies on reload. *Why:* today's stop-all/restart-all reload would destroy any timer held in the manager.
7. **A fire that is entirely absorbed leaves no row and no card.** Nothing happened. Absorbed counts accumulate on the subscriber and appear in `/jobs`. *Cost if wrong:* a user debugging a watch that "never fires" has to open `/jobs` to see it was all noise — which is where the numbers are.

Not in this deliverable: watches over individual files (a watch is a directory, as today), content-based filtering, a gate on a watch (the quiet window and globs cover the cases the pipeline diagram meant), cross-watch event publishing, per-watch retention caps, and `run_command`-write detection.

## 1. Model

`FSWatch` (`Sources/iris/Job.swift`) gains two fields, both `decodeIfPresent` (invariant 1):

```swift
struct FSWatch: Codable, Equatable, Sendable {
    var path: String                 // canonical, absolute
    var quietWindowSeconds: Int      // 1…300, default 3; stored today, enforced by this deliverable
    var ignore: [String]             // per-watch globs relative to `path`; default []
}
```

`quietWindowSeconds` outside 1…300 clamps on decode and on the tool. The ceiling is `quietWindowSeconds * 10`, derived, never stored. `Job.policy.overlap` for a watch defaults to `.queue` at creation (existing rows keep whatever they have; a row created before this deliverable has `.skip`, which is honoured — see §3).

`Trigger.summary` for a watch stays `watch <path>`; the policy column (§6) carries the window and globs when not default.

## 2. The watch coordinator

`actor WatchCoordinator` (new file `Sources/iris/WatchCoordinator.swift`), constructed with a ledger, a clock (`now: @Sendable () -> Date`), a recent-writes registry, and a fire handler `(Job, [String]) async -> Void` that in production is `JobRunner.fire(job:origin: .watcher(paths:))`. Injectable throughout; `IrisEngine` owns the production instance the way it owns the runner.

Per subscriber (`jobId`) it keeps:

| field | meaning |
|---|---|
| `pending: Set<String>` | canonical paths seen this burst, after filters |
| `burstBegan: Date?` | when the first accepted event of this burst arrived |
| `lastAccepted: Date?` | when the last accepted event arrived |
| `coalesced: Int` | events that landed in this burst (all batches' accepted paths, counted per event) |
| `noise: Int`, `ownWrites: Int` | absorbed this burst |
| `absorbedSinceLaunch: (noise: Int, ownWrites: Int)` | shown in `/jobs` |

**On a batch** `(path, events)` from the manager: for each subscriber whose watch path covers the event path (exact or ancestor, after canonicalisation), for each event path: if it matches the built-in set or the subscriber's globs → `noise += 1`; else if the registry says Iris wrote it within the expiry (§4) → `ownWrites += 1`; else insert into `pending`, set `burstBegan` if nil, set `lastAccepted = now`, `coalesced += 1`. A batch that accepted nothing changes no timer.

**Firing.** A single scheduling loop (one `Task` per coordinator, woken on every accepted event) computes, per subscriber with a non-empty `pending`, the earlier of `lastAccepted + quietWindow` and `burstBegan + quietWindow × 10`; when the clock passes it, the subscriber fires:

1. Read the job row fresh from the ledger. Missing, `enabled == false`, or `pausedReason != nil` → drop `pending`, reset the burst, count nothing (the job is not running by the user's choice).
2. Take `pending` as an ordered list (sorted), reset the burst, and call the fire handler with the job and the paths. The prompt receives at most 100 paths plus a line `and N more changed paths`; the run row receives the full count (§6).
3. The runner's admission answers. `.run` — the run starts with these paths. `.queued` (job in flight, overlap `queue`) — the coordinator keeps a `heldPaths` list for the job; further events accumulate into it; when the runner performs the held re-fire it calls `coordinator.takeHeldPaths(jobId)` and fires with the merged list (the original paths plus everything since), then the quiet window applies again from that fire. `.skipInFlight` (overlap `skip`) — the paths return to `pending` and the burst restarts, so the next window carries them; the runner writes no row for a watch skip, as today. Any other refusal (paused, breaker, budget) — the runner's normal row and card; `pending` is dropped, because a job admission refused is not going to be admitted a moment later and re-firing would write a row per burst.

**Watch fires never retry** (deliverable 3's rule stands): a failed watch run is reported and the next burst runs it again with real paths.

Timers are wall-clock through the injected clock; a suspended Mac that wakes mid-window fires once on wake with everything pending (FSEvents delivers the backlog as a batch on resume).

## 3. Overlap for watches

`register_directory_watcher` creates the job with `policy.overlap = .queue`. `JobRunner`'s held re-fire (deliverable 3) is extended with one seam: before re-firing an origin of kind `.watcher`, it asks the coordinator for the merged paths (`takeHeldPaths`), and fires `.watcher(paths: merged)` instead of the original origin. A job created before this deliverable, or one whose user chose `skip`, behaves as §2's `.skipInFlight` branch: nothing lost, re-fire not immediate.

## 4. The recent-writes registry

`actor RecentWrites` (new, `Sources/iris/RecentWrites.swift`), injectable; the production instance is owned by `IrisEngine` alongside the coordinator. Entries: `(canonicalPath: String, at: Date)`, bounded to the most recent 1,000 (oldest evicted).

**Fed** from the existing post-tool hook that resolves a written path (`iris.swift`, the `recordSubagentWrite` site), widened from `write_file` to `write_file`, `edit_file`, `create_skill`, and from subagent conversations to every conversation. The headless `--run-job` process shares the hook. Not fed: `run_command` (host or container), MCP tools, plugin hooks — documented in `docs/jobs.md`.

**Consulted** by the coordinator per event path: `wroteRecently(path, within: quietWindow + 2 s)` — exact canonical match, plus one prefix case: an event on a directory that is the parent of a recently written path, within the same expiry, is treated as own (the directory-modified event a file write produces). Entries are not consumed on match (one write produces several events: create, modify, rename); expiry is what ends their effect. The 2 s margin is FSEvents' stream latency (1 s) with headroom, and the whole expiry is short on purpose: a stale entry must never swallow a genuine hand edit minutes later (the plugins panel's `LegacyFileWatchSuppressor` records the same reasoning with its 3 s expiry).

The registry is not a tool and nothing model-facing reads it.

## 5. Tool surface and registration

`register_directory_watcher` (all conversations; still undeclared and refused in unattended runs, deliverable 2's rule):

| argument | type | rule |
|---|---|---|
| `path` | string | as today; canonicalised (symlinks, `..`); must be an existing directory; `~/.iris/config` and `~/.iris/plugins` refused as watch roots (a watch there reacts to its own configuration) |
| `instructions` | string | as today |
| `quiet_window_seconds` | int, optional | 1…300; outside clamps and the result sentence names the value used |
| `ignore` | [string], optional | globs relative to the watch path; a pattern set that would ignore `*`/`**` is refused: "that ignore list would ignore every change; drop the pattern or watch a narrower path" |
| `overlap` | `queue`\|`skip`, optional | default `queue` for watches |

**Registration rule.** Watches are keyed by name (the path's last component, suffixed on collision, as today). Same `createdInConversationId` and same canonical path → update that job in place (prompt, window, globs, overlap; `enabled = true`; `pausedReason = nil`). Different conversation, same path → a new job with a suffixed name. The result sentence says which happened ("updated your watch `notes`" / "created `notes-2`; `notes` belongs to another conversation").

The tool description states: the quiet window and ceiling, the built-in ignore set by name, that self-writes through Iris's file tools are ignored, and that a watch never runs concurrently with itself.

## 6. Observability

**Run row.** `job_runs` gains one nullable JSON column `watchSummary` (migration v11) decoded leniently into:

```swift
struct WatchSummary: Codable, Sendable, Equatable {
    var delivered: Int      // paths handed to the run (≤ full count)
    var changed: Int        // distinct paths in the burst
    var coalesced: Int      // events that landed in the burst
    var noise: Int          // absorbed this burst
    var ownWrites: Int      // absorbed this burst
    var ceilingFired: Bool  // the burst was cut at the ceiling
}
```

Null for non-watch rows. `get_job_run` returns it as stored.

**Card.** The outcome line is the run's output as today. The metadata line (tokens, duration) gains, only when non-zero: `12 changes · 3 noise · 2 own writes`, and `(cut at 30 s)` when the ceiling fired. A fully absorbed burst writes no row and no card (§0.7).

**`/jobs`.** The policy column adds `quiet 10 s` when not default and `2 ignore` when globs are set. A watch row adds a second line: `last burst: 12 changes · 3 noise · 2 own writes — absorbed since launch: 41 noise · 7 own writes`. `list_jobs` carries `quietWindowSeconds`, `ignore`, `lastBurst` (the `WatchSummary`), and `absorbedSinceLaunch` as fields, null for non-watches.

## 7. Stream lifecycle and errors

`WatcherManager` keeps one FSEvents stream per distinct canonical watch path and exposes `sync(with jobs: [Job])`: compute the set of paths across enabled, unpaused `.fsEvent` jobs; start a stream for each new path; stop the stream for each path with no remaining subscriber; touch nothing else. Every stream's batches go to the coordinator with the stream's path; the coordinator fans out to subscribers by path coverage.

`sync` is called at launch and from one hook, `JobLedger.onJobsChanged`, fired after any job insert, update or delete (the ledger already funnels these through `upsert`/`delete`/`setPaused`/`setEnabled`). Pause, resume, disable, delete and re-registration therefore take effect within the same second, with no restart of unrelated streams and no lost timer.

Errors:
- A watch whose path does not exist at launch, or whose stream FSEvents refuses to create, pauses itself with `pausedReason = "watch path unavailable: <path>"` and a card, rather than starting nothing silently. `/jobs resume` retries the stream.
- A stream that stops mid-life (directory deleted, volume unmounted) is detected on the next `sync` or on the coordinator's next fire attempt (the path no longer exists): the fire is recorded as a failed run row with `watch path unavailable`, and three consecutive such failures pause the watch with that reason — the gate-failing shape from deliverable 3.
- A ledger or registry read failure during a fire drops the burst and writes a failed run row naming the failure — never a silent drop, and never a fire with the self-write filter bypassed. Firing without the filter is the one direction that can loop (every event would read as someone else's), so the safe failure is not to fire and to say so.

## 8. Tests

All headless: injected clock, a fake event source the test feeds batches into, an injected fire handler, an in-memory ledger, a per-test registry; no test touches `~/.iris`, real FSEvents, `ConfigManager.shared`, or `WatcherManager.shared` (invariant 7 — the singleton is reached only through injection, as the runner's seams are).

Coordinator: eight batches in 2 s → one fire, eight paths, after 3 s of quiet; a batch every second for 45 s → fires at 30 s with everything so far, then again at the next quiet; noise-only and own-write-only batches never start or extend a burst and never fire; a batch mixing both accepts only the rest; two subscribers on one path get independent windows and counts; a child-path subscriber receives a parent stream's event under the child and nothing outside it; pause, disable and delete between event and fire suppress the fire; `.queued` accumulates and the held re-fire gets the merged list; `.skipInFlight` returns paths to pending and the next window carries them; other refusals drop pending; the 100-path cap and the count on the row; wall-clock fire after a simulated sleep.

Registry: expiry at exactly window + 2 s; exact-path match; parent-directory case; no consumption on match; the 1,000 bound.

Manager: `sync` starts one stream for two jobs on one path, stops it when the last leaves, does not restart an unchanged stream, starts a second for a second path; `onJobsChanged` reaches `sync`.

Tool and rule: argument decoding, clamps, the ignore-everything refusal, protected roots refused; same conversation updates, other conversation creates a suffixed watch; `overlap` default `queue`.

Row, card, `/jobs`, `list_jobs`: lenient decode of `watchSummary`; rendering with fixed figures; absorbed burst leaves no row.

Regression: the existing `watcherFireWhileRunningIsDropped` becomes "a burst during a run is held and re-fires once with the merged paths".

## 9. Delivery

Spec PR (this document), then two execution PRs:

- **A — behaviour:** `FSWatch` fields and migration, `WatchCoordinator`, `RecentWrites` and the widened hook, `WatcherManager.sync` and `onJobsChanged`, the runner's held-re-fire seam, watch default `queue`. On-screen check: a watch over a folder, a save burst from an editor yields one run after the window; an Iris `write_file` into the folder yields no run; a save during a run yields one held re-fire.
- **B — visibility:** tool arguments and the registration rule, `watchSummary`, card suffix, `/jobs` and `list_jobs`, docs. On-screen check: the `/jobs` watch line and a card with counts.

Docs falsified by this deliverable (invariant 9): `docs/agency/agency.md` deliverables list (4 landed); `docs/specs/2026-09-21-agency-model-and-ledger.md` handover paragraph and ruling D2-R9; the comments in `JobRunner`, `WatcherManager`, `iris.swift`'s watcher callback and `FSWatch` that say deliverable 4 will do this; README's jobs bullet; `docs/jobs.md` (new Watches section).

## 10. Decided in review

(Filled during the spec review and execution, as the earlier deliverables did.)
