# A single writer per store (#463)

Status: **proposed** (2026-10-11), revised after `work`'s review of #487. The design brief is `.superpowers/sdd/463-design-brief.md`. The owner's rulings of 2026-10-11 are binding here:
1. The CLI keeps refusing while the app holds the store, with no IPC hand-off.
2. An app launched during a CLI run waits behind a screen that never touches the store and offers "Stop the run". It never times out into opening the store.
3. A second GUI on one home refuses and quits.
4. The lock is a lifetime `flock` opened `O_CLOEXEC`.

The coordinator's rulings on the review are binding too:
- #489 is fixed in PR 1: the CLI never builds `AppState.shared`.
- "Force stop" (SIGKILL) is offered 30 s after an unanswered Stop.
- SIGINT and SIGHUP take Stop's clean path, and a second Ctrl-C means exit now, after the CLI kills the process groups it started.

This spec replaces #390/#391's `GUILock` and D6 decision 14's `LaunchLock` mitigation. Of the pid-file protocol, only the file's path and `ProcessStart` survive.

## Facts this rests on

Checked against `main` at `e418b29`, 2026-10-11. Paths are under `Sources/IrisKit/`.

- **Writes overwrite from a snapshot.** `markChanged` debounces 0.5 s with a 2 s max wait (`AppState.swift:3833`, `:3840`), so a CLI writes throughout a run and then flushes (`RunJobCLI.swift:491`). A message append does `INSERT OR REPLACE` from `from` to the end of the writer's array, then `DELETE … ordinal >= count` (`ConversationStore.swift:844-877`); history does the same (`:879-887`); a `.metadata` write rewrites every column (`:812-822`). Nothing re-reads before it writes.
- **What a CLI run writes:** its hidden transcript (`JobRunner.swift:1682-1704`), its card as a message plus a history append (`EventDelivery.swift:49-54`), and ledger rows. Its `AppState.init` runs the launch repairs (`AppState.swift:1195-1196`) and persists role normalization (`:4047`), and `activityConversationId` can create a pinned Iris and unpin the others (`:1554-1572`).
- **The CLI already opens the store late.** `RunJobCLI.run` takes the store as an `@autoclosure` (`RunJobCLI.swift:338`), first evaluated at `:389`, after the claim (`:366`). So `IrisMain.swift:31`'s `try ConversationStore.onDisk(…)` runs after the claim, not before. The review's must-fix 1 misread this. A refused run never opens, migrates or repairs (`ConversationStore.swift:247-256`) the store. No test pins this yet.
- **The other headless modes don't open the real store.** `--perf` runs against a volatile copy of the home (`PerfCLI.swift:180`, `:215`); `--bench` opens no store; `--seed-dev-home` opens only its staging copy (`DevHomeSeeder.swift:164-165`), after its lock check (`:50`).
- **#489 is live on main.** `ToolExecutor.afterSkillFileWrite` (`ToolExecutor.swift:690`), `createSkill`/`updateSkill`/`deleteSkill` (`:1145`, `:1202`, `:1219`) and `SkillCurator` (`SkillCurator.swift:73`) call `AppState.shared.invalidateEnginePrompt()`. Inside `--run-job` that lazily builds a second `AppState` over the store, launch repairs included, and invalidates the wrong engine (`AppState.swift:1311-1315`), not the run's.
- **Locks today.** The CLI claims `conversations.sqlite.lock` (`IrisPaths.swift:148`) by `link(2)`, takes over a dead pid under a directory `flock`, and refuses a live one (`RunJobCLI.swift:126-166`, `:366-384`). The app never checks: `GUILock.acquire` is an `.atomic` write, a rename over the path (`RunJobCLI.swift:234-240`, `iris.swift:5500`), and `release` deletes the file whenever it names this pid (`RunJobCLI.swift:244-248`, `iris.swift:5474`). `PerfCLI` (`:117`) and the seeder (`DevHomeSeeder.swift:50`) use the same protocol.
- **D2's mitigation.** `LaunchLock.read` reads the earlier holder and its start time (`LaunchLock.swift:53-82`); `noteForeignStoreHolder` posts a notice (`:87-92`); a URL fire is deferred, re-checked every 5 s, and given up at 600 s (`RunJobURLHandling.swift:60-71`, `RunJobURL.swift:166-177`), and the wait counts toward the URL limit (`:92`).
- **Launch.**
  - `AppState.shared` is a lazy `static let` (`AppState.swift:375`). Its init opens and migrates the store (`ConversationStore.swift:200`).
  - `IrisApp.init` migrates the home, seeds skills, touches `.shared` inside `MainActor.assumeIsolated` (safe only because `App.init` runs on the main thread), and starts `reapOrphans` (`iris.swift:5499-5522`).
  - These reach `.shared` too: the scenes (`:5544-5578`), `ChatView` (`ChatView.swift:6`), `SettingsView` (`:148`) and `PluginsSettingsView` (`:412`, `:446`), the hotkey closure (`iris.swift:5538-5540`, evaluated on key press), did-finish's `startOnce` (`:5455-5460`, D2 put it there), terminate (`:5468-5469`), and the URL handler (`RunJobURLEvents.swift:24`).
  - `Window("Diagnostics")` (`:5560`) reads only metrics and the profiler.
  - A cold start from a link opens no window. `RunJobURLIntake` holds links until bookkeeping is done (`RunJobURLIntake.swift:7-17`).
- **Launch-time sweeps.** `closeRunningRuns` marks every `running` row `interrupted`, "app was not running" (`JobLedger.swift:586-596`, `iris.swift:3439-3456`), and `finish` has no status guard (`JobLedger.swift:446-465`). `reapOrphans` deletes every `iris-` container outside this process's registries (`SandboxSessionManager.swift:8`, `:251-270`); its "before anything else can have started one" (`:244-245`) is false while a CLI runs. Overlap is per process (`JobRunner.swift:103-105`).
- **Signals and children.** No signal handler exists in `Sources/`. `ProcessGroupRunner` resets every disposition and mask in the child (`ProcessGroupRunner.swift:190-201`), as does `BlockingSpawn` (`:35`). Foundation `Process` (in `ContainerRuntime`, `MCPManager`, `ToolExecutor`, `GCloudHelper`, `ADCCredentialManager`, `BinaryResolver`, `ModelDownloader`, `PerfEnvironment+Capture`) is not documented to reset an inherited `SIG_IGN`. Each `run_command` is its own process group, so a terminal's Ctrl-C reaches only the CLI, and its groups outlive it.
- **The CLI's hold is bounded but uncapped.** `runTimeoutSeconds` defaults to 600 (`JobPolicy.swift:36`) with no ceiling (`JobRunner.swift:2227-2231`). The watchdog ends a hung turn by claiming `ending` and cancelling the turn (`:1199-1212`).
- **Homes.** The lock is per home. `swift run`/`run-dev.sh` and `Iris Dev.app` share `~/.iris-dev`. The bare binary registers no URL scheme, so an `iris-dev://` link opened beside it launches `Iris Dev.app` on the same home (AGENTS.md). The container prefix is not per home.

## 0. Decided

1. **Two lifetime flocks per home.**
   - The *store lease*, `conversations.sqlite.lock` (today's path), is held by whichever process may open the store.
   - The *app lease*, `app.lock`, is held by a GUI for its whole life, waiting or open.
   - Each is `open(O_RDWR | O_CREAT | O_CLOEXEC, 0600)` plus `flock(LOCK_EX | LOCK_NB)`. It is never unlinked or renamed, and the kernel drops it on any death, SIGKILL included.
   - It must be `flock(2)`, never `fcntl`/`lockf`: a POSIX lock drops when the process closes *any* descriptor for the file, including a read of its own payload. On Darwin a `flock` belongs to the open file description, so two `open`s in one process conflict.
   - Every contender is a process on this Mac, so local lock semantics are enough even on a network home.
   - *Cost if wrong:* one more file in the home.
2. **The descriptor can't be dropped.**
   - A held lease is a raw fd in a process-lifetime static table keyed by path. It is never closed, never `dup`ed (a `dup` loses `FD_CLOEXEC`), and never wrapped in a `FileHandle` or anything that closes on `deinit`.
   - `claim` returns a value type with no ownership, so `_ = claim(…)` releases nothing.
   - Release is process exit. Tests release only through stub child processes.
3. **The locked file must be the one at the path.**
   - After every successful `flock`, including each poll of the waiting app, compare `fstat(fd)`'s `st_dev`/`st_ino` with `stat(path)`'s.
   - If they differ, close that fd (it locks a replaced inode and excludes nobody), reopen, and retry, up to 3 times. After that the claim is `.failed("the lock file keeps being replaced")`.
   - This covers a pre-#463 app's rename, a user following the old "delete the file" advice, and an editor.
4. **`.failed` refuses everywhere.** Any `open`/`flock`/`stat` error other than `EWOULDBLOCK` is a refusal that names the path and the errno: `ENOTSUP`, `ENOLCK`, `EACCES`, a read-only home, an iCloud or network mount that doesn't support it.
   - The CLI and the seeder exit 1. The app shows an alert and quits; it never opens the store unlocked.
   - *Cost if wrong:* a home on an exotic volume can't run Iris until it moves.
5. **The store lease carries a payload, written on the held fd.**
   - One JSON line, `{"pid", "kind": "app"|"run-job"|"seed-dev-home", "job"?, "started", "deadline"?, "groups"?}`, written with `ftruncate` + `pwrite`.
   - `started` is the holder's own kernel start time (`ProcessStart.of(getpid())`).
   - The CLI rewrites the payload with `deadline` once it knows the job, and with `groups` whenever a `ProcessGroupRunner` group starts or ends (decision 14).
   - A clean exit truncates it to empty.
   - The payload only describes the holder; the lock decides who holds it. An empty or unparsable payload is re-read for up to 1 s, then shown as "another Iris process".
   - Pre-#463 binaries can't parse it as a pid, so they refuse, which is safe.
6. **The CLI refuses while the app holds either lease** (ruling 1).
   - It probes the app lease first, then claims the store lease. Either one held means exit 1, naming the holder ("the app", or "--run-job <job> (pid N)").
   - `--dry-run` claims too.
   - The store autoclosure stays as it is and is pinned by a test (§4).
7. **A GUI that finds the app lease held refuses and quits** (ruling 3).
   - It retries for 1 s first, because a probe holds the app lease for microseconds.
   - Then it shows an alert, "Iris is already running on this home", before any scene. It activates the holder when that is an app, and calls `exit(0)`.
   - When the launch carried a link (the bare-binary case in the facts), the alert says the link was not run and that it should be opened from the running Iris's home build.
   - This also covers a second GUI launched while the first one waits.
8. **A GUI that holds the app lease but not the store lease waits** (ruling 2).
   - It polls the store lease once a second on a **main-queue** `DispatchSourceTimer`, never `Task.sleep`, re-checking the inode each time (decision 3).
   - While the app lease is held every new `--run-job` refuses, so a batch can't starve the app: it waits out only the run in flight.
   - No timeout opens the store.
9. **The waiting surface touches nothing of `AppState`.**
   - A new `@MainActor @Observable LaunchGate` (`.waiting(Holder)` / `.open`) is its only state.
   - `WindowGroup`, `Settings` and `Run Log` render `WaitingView` until `.open`.
   - The `MenuBarExtra` label and content take the gate's branch, and the other branch never evaluates `.shared`. They show an hourglass, then "Waiting for --run-job <job> (pid N, until T)", Stop, and Quit.
   - The hotkey closure checks the gate **when pressed** and raises the waiting window.
   - Diagnostics needs no gate; it touches no store.
   - A cold start from a link stays windowless: the status item shows the wait, and a Dock click opens the waiting window.
10. **`AppState.shared` is legal only in the GUI process that holds the store lease for `IrisPaths.default.conversationsDB`.**
    - `IrisMain` sets the process role (`.app`, `.runJob`, `.seed`, `.perf`, `.bench`) before anything else runs.
    - The accessor calls `preconditionFailure` unless the role is `.app` and `StoreLease.holds(IrisPaths.default.conversationsDB)`. That holds in every build, so `--run-job` traps too.
    - Under test the accessor records the access to a task-local `SharedStateWitness` when one is scoped, and is otherwise disarmed, so `AttachmentIntegrationTests` is unaffected.
    - *Why:* while the app waits, a missed path then fails as a crash, which loses nothing. Once the app is open a crash can still lose the 2 s debounce, as it can today.
11. **#489: the skill paths take their state by injection** (coordinator ruling, PR 1).
    - `ToolExecutor.execute` and the skill CRUD take an `onSkillsChanged: @Sendable () async -> Void`, which `IrisEngine` supplies as its own `invalidateSystemPrompt()`.
    - `SkillCurator.curateSkills` takes the same closure from its caller (`AppState.swift:4070`).
    - No code under `Sources/` reaches `AppState.shared` except the GUI shell (`IrisApp`, `AppDelegate`, the views' defaults).
    - This also fixes the CLI's own engine never hearing about the change.
12. **Launch completes in two idempotent halves, both on the main actor.**
    - `openStore()` runs once the store lease is held: `IrisMigrator`, `ShippedSkills`, the `AppState.shared` setup, notifications, `reapOrphans` and the idle loop.
    - `finishLaunch()` runs once both `openStore()` and `applicationDidFinishLaunching` have happened, whichever is later: `startOnce` or `refuseRunJobURLsUntilSetUp`, then handing the gate's held links over.
    - When the lease is free at launch, `openStore()` runs in `App.init` exactly as today, and `finishLaunch()` in did-finish. The order doesn't change.
    - *Why the sweeps need no owner data:* only the lease holder runs them, so every `running` row and unregistered `iris-` container on this home belongs to a dead process. No `job_runs` column is added.
    - `interruptedByQuitReason` becomes "the Iris process running it ended".
13. **Links that arrive while waiting are held by `LaunchGate`, with no timeout.**
    - It keeps raw URLs in memory, never logs them, and holds up to `RunJobURLIntake.capacity`; past that it counts.
    - `finishLaunch` passes them to `receiveRunJobURL` in order. The overflow posts one line: "N links that arrived while Iris waited were dropped unread". Nothing can be checked without the store, so junk links can crowd out a real one, which is accepted.
    - D2's deferral is deleted: `URLDeferral`, its timer, `PendingURLFire`, `deferURLFire`, `.deferred`, `foreignStoreHolder*`, `noteForeignStoreHolder`, `foreignHolderNotice`, the waiting and give-up lines, and `LaunchLock`, apart from `ProcessStart`.
    - The launch notice isn't replaced. Nothing races any more, and the waiting screen says why.
14. **`ProcessGroupRunner` keeps a registry of live groups.**
    - A process-wide `LiveProcessGroups` records `(pgid, leader start)` at spawn and drops it at reap.
    - `terminateAll(grace:)` sends SIGTERM to each group, then SIGKILL after the grace, on a dispatch queue (invariant 4). `killAll()` sends SIGKILL at once.
    - In the CLI it mirrors the set into the payload's `groups`.
15. **The CLI's stop path.**
    - The CLI installs a **no-op `sigaction` handler** for SIGTERM, SIGINT and SIGHUP, plus a `DispatchSource` per signal on its own serial queue (not `.main`, which a ggml load can hold).
    - A caught signal, unlike `SIG_IGN`, resets to default across `exec`, so no child inherits an ignore, whether it is spawned through `Process` or `posix_spawn`.
    - The first signal claims the run's `ending` as a third claimant beside the turn and the watchdog. It cancels the turn, calls `LiveProcessGroups.terminateAll`, and waits up to 15 s for the turn to come back.
    - When the turn is back, or the 15 s are up (the turn is then abandoned, like the watchdog's, so a cancel that a bare continuation ignores can't turn Stop into a hang), the CLI closes the row `interrupted` with "stopped by a signal (SIGTERM)", naming the signal, delivers the card, runs `flushSave`, truncates the payload, and exits 2.
    - A signal before admission (opening, bookkeeping) exits 2 with no row. A dry run exits 2 with nothing written. A signal after the run ended changes nothing.
    - A second SIGINT means exit now: `killAll()`, then `_exit(130)`. The row is left for decision 12's sweep.
    - Exit 2 already means "interrupted" in the documented table, so scripts need no change.
16. **Stop and Force stop, from the waiting app.**
    - Stop is offered only when the payload parses, `kind` is `run-job`, the pid is alive, and `ProcessStart.of(pid) == started`. That check is repeated immediately before `kill(pid, SIGTERM)`.
    - A new holder whose payload isn't written yet still exposes the old holder's payload. That pid is dead or reused, so the start check refuses to signal it.
    - There is no Stop for an unreadable, legacy or `seed-dev-home` payload.
    - 30 s after Stop, if the lease is still held, "Force stop" appears (coordinator ruling). Its confirmation says it ends the run with no card, the row is closed at open with "the Iris process running it ended", and up to 2 s of transcript can be lost. It then SIGKILLs the CLI, after the same start check.
    - Next it SIGKILLs each payload group whose leader start still matches, so nothing it started outlives it. Containers are reaped at `openStore()`.
17. **Pre-#463 binaries.**
    - A claimant that wins the store lease but finds a bare-pid payload treats it as live only if that pid is alive *and* started before the file's mtime (`LaunchLock.read`'s rule, kept). Then it refuses ("a pre-#463 Iris, pid N, holds this home").
    - Nothing else is done for mixed versions. Decision 3 already handles a replaced inode.
18. **The seeder claims the release home's leases** with `LOCK_NB` for the length of the copy, kind `seed-dev-home`.
    - A release app launched mid-seed waits a few seconds.
    - The seeder's "no readable pid" refusal goes.
    - `PerfCLI`'s scratch lock moves onto `StoreLease`, unchanged in meaning.
19. **Quit while waiting** flushes nothing: `applicationWillTerminate` asks the gate before it touches `.shared`. Held links are dropped; the waiting window counted them.

## 1. Failure modes, closed

| Brief (A) | Closed by |
|---|---|
| 1, 2. Iris rows and history erased or holed | One process holds the store at a time (decisions 6, 8, 10), and since #489 one `AppState` per process (11). |
| 3. Whole-row metadata clobber, launch repairs from a stale snapshot | Same. The repairs run behind the lease, in the only `AppState`. |
| 4. `closeRunningRuns` marks the CLI's live run interrupted | Decision 12: it runs only once the CLI is dead. |
| 5. Double runs from per-process overlap | One process runs jobs per home, so `inFlight` covers every run. |
| 6. `reapOrphans` kills the CLI's containers | Decision 12, for one home. Reaping across homes is out of scope (§6). |
| 7. App deletes the lock on quit | Decisions 1-2: nothing unlinks a lease or drops its fd. Decision 3 survives anyone else unlinking it. |
| 8. Two GUIs on one home | Decision 7. |
| 9. Migrations against an open store | The CLI opens only after its claim (facts, pinned by §4); the app migrates in `openStore()`; decision 17 covers old binaries. |

**A holder that crashes**, whether CLI, app or seeder: the kernel frees its leases, and a waiting app's next poll wins. Decision 12's sweep closes the row. No stale-lock takeover or pid check is involved. `O_CLOEXEC` at `open`, plus `POSIX_SPAWN_CLOEXEC_DEFAULT`, keeps a surviving `run_command` child from holding the lease. Nothing in Iris forks without exec, and container VMs belong to the container daemons, not to us.

**Dev and release homes** never contend, because each has its own leases. `swift run` beside `Iris Dev.app` is decision 7.

## 2. Components

- **`StoreLease`** (new, replaces `GUILock`):
  - `claim(at:kind:) -> Claim` (`.acquired`, `.held(Holder?)`, `.legacy(pid)`, `.failed(detail)`);
  - `updatePayload`, `vacate()` (truncate), `probe(at:)`, `holds(_ store: URL)`;
  - the fd table, the inode check, and a pure payload codec.
  - It serves the app lease too (`IrisPaths.appLockFile`). `ProcessStart` moves here.
- **`ProcessRole`** (new), set in `IrisMain`.
- **`LiveProcessGroups`** (new), fed by `ProcessGroupRunner`.
- **`LaunchGate`** (new):
  - the phase, held links and their count, the timer seam, `stop()` and `forceStop()` with an injected `kill`;
  - `LaunchDecision.decide(appLease:storeLease:) -> .open | .wait(Holder) | .refuse(Reason)`, which is pure.
- **`WaitingView`** (new): the window, Settings and Run Log content, and the status item's label and menu.
- **`IrisApp` / `AppDelegate`:** `openStore()`, `finishLaunch()`, the gated scenes, hotkey and terminate, and `RunJobURLEvents` delivering to the gate.
- **`ToolExecutor`, `SkillCurator`, `IrisEngine`:** decision 11's injection.
- **`RunJobCLI` / `JobRunner`:** the lease claim, the payload, the signal sources, and the stop claimant.
- **Deleted:** `GUILock`'s link, takeover and directory-lock code; `LaunchLock.swift` apart from `ProcessStart`; D2's deferral. Their tests are deleted or replaced (`LaunchLockTests`, `RunJobURLDeferralTests`, the `GUILock` cases in `RunJobCLITests`).

## 3. Agent-facing text and docs (invariant 9)

I searched for each of these. Each becomes untrue:
- `README.md:250-258`: the pid lock file, "created, not checked and then written", and the refusal list.
- `docs/jobs.md`:
  - `:1146-1167`: the pid file, takeover, "delete the file", "do not start Iris while a `--run-job` is in flight", and the app keeping the lock;
  - `:1173`: the exit-1 row (add `.failed`);
  - `:1234-1237`: the 5 s / 10 min URL wait;
  - the exit-2 row: add "stopped by a signal".
- `AGENTS.md`, dev builds:
  - "do not run both at once … both would open the store's GUI lock";
  - "an `iris-dev://` link opened while `swift run` … launches Iris Dev.app beside it", which now refuses with decision 7's line;
  - the seeder's "GUI lock … doesn't hold a readable pid (delete it and retry)".
- `docs/specs/2026-10-09-agency-native-surfaces.md`, decision 14 (and `:194`, `:255`, `:298`): dated specs stay as they are. Decision 14 gets one line: "Superseded by 2026-10-11-single-writer-store.md: no bound, no deferral."
- Agent-visible strings:
  - `interruptedByQuitReason` (`iris.swift:3439`), which `get_job_run` returns to a model;
  - the new stop reasons;
  - D2's notice and waiting lines (`RunJobURL.swift:52`), which went into Iris's history.
- Comments:
  - `GUILock`'s header (`RunJobCLI.swift:2-17`) and `run`'s (`:355-364`);
  - `IrisMain.swift:27-28`, which is true but should name the autoclosure;
  - `IrisApp.init`'s (`iris.swift:5487-5498`) and terminate's (`:5471-5473`);
  - `SandboxSessionManager.swift:244-249`;
  - `RunJobURLIntake.swift:3-6`.

## 4. Verification

**Unit tests.** All in Swift Testing, using real `flock` on files under a temp directory, never `~/.iris` or `~/.iris-dev`. Suites that spawn get `.timeLimit(.minutes(1))` and await through `value(of:within:)`.
- **`StoreLease`:**
  - two claims in one process conflict;
  - a claim whose result is dropped still excludes a second `open`;
  - a stub holder (`perl -MFcntl=:flock -e 'open F,">>",shift; flock F,LOCK_EX; print "ok\n"; sleep 60'`) blocks a claim, and SIGKILLing it frees the lease;
  - the lease fd carries `FD_CLOEXEC` from the `open` itself (`fcntl(F_GETFD)`), never set afterwards;
  - the path is replaced under a held lease: the next claimant sees the new inode, and the old holder's poll reopens;
  - an unsupported-lock fixture (a directory opened `O_RDWR`, or an injected `flock` seam returning `ENOTSUP`) gives `.failed`;
  - the payload round-trips, a truncated one reads as nil, and `vacate()` leaves it empty;
  - a bare-pid file naming a live stub that started before the file's mtime is `.legacy`; one naming a stub that started after it isn't.
- **`LaunchDecision`:** the table of app lease × store lease × payload.
- **`LaunchGate`:**
  - links are held in order up to capacity, with the overflow count and its line;
  - an injected `openStore` is never called while waiting;
  - with an injected `kill`, Stop is not offered or sent on a stale payload (dead pid, mismatched start, legacy, unreadable);
  - Force stop appears at 30 s on an injected clock, and kills the groups whose start matches.
- **`AppState.shared`:** under a `SharedStateWitness` scope, a `--run-job` (fake client) whose turn calls `write_file` into a skill folder, then `create_skill`, records no `.shared` access, and the run's own engine is invalidated (#489).
- **`RunJobCLI`:**
  - a refusal with the app lease held by a stub, and with the store lease held, both exit 1 with the holder named. The db file's mtime and `grdb_migrations` don't change, and the injected store factory is never called;
  - with an injected signal, before admission: exit 2, no row;
  - mid-run: the row is `interrupted` with the stop reason, the card is in Iris, the save is flushed, the payload is empty, and the registered stub groups are gone; exit 2;
  - with a turn that ignores cancellation: the same result after the 15 s grace (injected short);
  - a second SIGINT: `killAll`, then exit 130.
- **Signal inheritance:** with the CLI's handlers installed, `Process` running `/bin/sh -c 'kill -TERM $$; sleep 5'` dies by SIGTERM, and so does the same command through `ProcessGroupRunner`.
- **#463's repro:** with a stub holding a temp store lease, `LaunchDecision` says wait and nothing opens the store. Once the stub dies the store opens, and the CLI's card is at its ordinal.
- **Launch order, through seams:** nothing in `openStore()` runs before the lease is held; `finishLaunch()` runs after both of its triggers, in either order, exactly once.

**GUI checks on `work`.** Run them under the `gui-test-lease`, with a dev build and a `--run-job` against `~/.iris-dev` (a test job whose turn sleeps, plus a `run_command` that sleeps):
1. Dock launch during a run: the waiting window and hourglass appear, naming the job and deadline. The store's mtime doesn't move.
2. Cold `iris-dev://run-job/<token>` launch during a run: no window, and the status item waits. After the run the fire happens, and both cards are in Iris.
3. Stop: the CLI exits 2 with the stop reason, its `sleep` is gone (`pgrep`), and the app opens.
4. A CLI made to ignore the stop (a test hook): Force stop appears at 30 s, the CLI and its `sleep` are gone, and the row is closed at open.
5. Quit while waiting. Then, while waiting: the hotkey, Cmd-, and the Run Log menu item. No crash, and the store doesn't open.
6. `run-dev.sh` beside `Iris Dev.app`, in both orders, plus an `iris-dev://` link with `swift run` up: the second GUI shows the alert and quits.
7. `--run-job` with the app open, and again while the app waits: exit 1.
8. Ctrl-C a terminal `--run-job` mid-`run_command`: exit 2, the row is stopped, no `sleep` is left. A second Ctrl-C exits at once.
9. SIGKILL the CLI mid-run: the app opens within a second, and the row is closed at open.

## 5. PR split

Each PR is based on `main`, never stacked, and carries its own §3 doc fixes.
1. **The leases, and #489.** It contains:
   - `StoreLease` with decisions 1-5 and 17;
   - the app lease and the CLI's probe of it (decision 6), which is what keeps CLIs out of an open app's home until PR 3;
   - the CLI, `PerfCLI` and the seeder moved onto the leases;
   - `ProcessRole`, decision 11, and the `.shared` rule for non-app roles;
   - the autoclosure test.

   The app takes both leases at launch. If the store lease is held, it still continues through D2's path, reading the pid from the payload, so the behaviour is today's minus failures 7 and #489.
2. **The CLI stops cleanly** (decisions 14 and 15). It lands before PR 3, so Stop has a clean path to call.
3. **The app waits.** Decisions 7-10, 12, 13, 16 and 19, and D2's deferral deleted. GUI checks 1-9 run on `work`.

## 6. Not in this deliverable

- `--run-job` while the app is open, over a socket: not wanted now (ruling 1).
- Reaping containers across homes. The `iris-` prefix is shared, so a dev launch can still reap the release app's live containers. That needs a per-home prefix and its own issue.
- A notification response that launches the app while it waits. The delegate is installed in `openStore()`, so the response is lost. The card is still in Iris.
- Mixed pre-#463 binaries, beyond decisions 3 and 17.
- `AppDefaultsImport`, which runs before any lease. It writes a defaults domain once, under its own marker, and never touches the store.
