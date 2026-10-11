# A single writer per store (#463)

Status: **proposed** (2026-10-11). This is the lean version, revised after `work`'s review of #487. The design brief is `.superpowers/sdd/463-design-brief.md`.

**Owner rulings (2026-10-11), binding**
1. The CLI keeps refusing while the app holds the store. There is no IPC hand-off.
2. An app launched during a CLI run waits behind a window that never touches the store. It never times out into opening the store.
3. A second GUI on one home refuses and quits.
4. The lock is a lifetime `flock`, opened `O_CLOEXEC`.
5. (The lean ruling.) `--run-job` is a developer measurement and debugging tool (runtime spec §8), so the app launching during a CLI run gets the minimum machinery.
   - Dropped: the Stop and Force stop buttons, the second `app.lock`, and the start-time check for signalling.
   - Kept: #489, folded into PR 1, and the CLI's clean stop on SIGINT, SIGTERM and SIGHUP, which is worth having on its own.

This spec replaces #390/#391's `GUILock` and D6 decision 14's `LaunchLock` mitigation outright.

## Facts this rests on

Checked against `main` at `e418b29`. Paths are under `Sources/IrisKit/`.

- **Writes overwrite from a snapshot.**
  - `markChanged` debounces 0.5 s with a 2 s max wait (`AppState.swift:3833`, `:3840`), so a CLI writes throughout a run (`RunJobCLI.swift:491`).
  - A message append does `INSERT OR REPLACE` from `from` to the end of the writer's array, then `DELETE … ordinal >= count` (`ConversationStore.swift:844-877`). History works the same way (`:879-887`).
  - A `.metadata` write rewrites the whole row (`:812-822`).
  - Nothing re-reads before it writes.
- **What a CLI run writes.**
  - Its hidden transcript (`JobRunner.swift:1682-1704`), its card (`EventDelivery.swift:49-54`), and ledger rows.
  - Its `AppState.init` runs the launch repairs (`AppState.swift:1195-1196`, `:4047`).
  - `activityConversationId` can create or re-pin Iris (`:1554-1572`).
- **The CLI already opens the store after its claim.**
  - `RunJobCLI.run` takes the store as an `@autoclosure` (`RunJobCLI.swift:338`). It is first evaluated at `:389`, after the claim at `:366`.
  - So `IrisMain.swift:31`'s `try ConversationStore.onDisk(…)` doesn't migrate (`ConversationStore.swift:200`) or repair (`:247-256`) a store the CLI refuses. No test pins this.
- **#489.** `ToolExecutor.afterSkillFileWrite` (`ToolExecutor.swift:690`), `createSkill`/`updateSkill`/`deleteSkill` (`:1145`, `:1202`, `:1219`) and `SkillCurator` (`SkillCurator.swift:73`) call `AppState.shared.invalidateEnginePrompt()`.
  - Inside `--run-job` that builds a second `AppState` over the store.
  - It also invalidates an engine that isn't the run's (`AppState.swift:1311-1315`).
- **Who reaches `AppState.shared` today.**
  - The GUI shell: `IrisApp.init`, inside `MainActor.assumeIsolated` (`iris.swift:5510-5519`); the scenes (`:5544-5578`); the hotkey closure (`:5538-5540`); did-finish (`:5455-5460`); terminate (`:5468-5469`); the URL handler (`RunJobURLEvents.swift:24`).
  - Views: `ChatView.swift:6`, `SettingsView.swift:148`, `PluginsSettingsView.swift:412`, `:446`.
  - #489's five skill paths.
  - In tests, only `AttachmentIntegrationTests.swift:46`, `:83`.
  - `PerfCLI`, `BenchCLI` and `DevHomeSeeder` never name `AppState`.
- **Locks today.**
  - The CLI claims `conversations.sqlite.lock` (`IrisPaths.swift:148`) by `link(2)`, with a dead-pid takeover, and refuses a live holder (`RunJobCLI.swift:126-166`, `:366-384`).
  - The app never checks. `GUILock.acquire` renames over the path (`:234-240`, `iris.swift:5500`), and `release` deletes it on quit (`:244-248`, `iris.swift:5474`).
  - `PerfCLI` (`:117`) and the seeder (`DevHomeSeeder.swift:50`) use the same protocol.
- **D2.**
  - `LaunchLock` remembers a foreign holder and posts a notice (`LaunchLock.swift:53-92`).
  - A URL fire is deferred for up to 600 s (`RunJobURLHandling.swift:60-71`, `RunJobURL.swift:166-177`).
  - A cold start from a link opens no window (`RunJobURLEvents.swift:1-7`).
  - `RunJobURLIntake` holds links until the job bookkeeping is done (`RunJobURLIntake.swift:7-49`).
- **Launch sweeps.**
  - `closeRunningRuns` marks every `running` row `interrupted`, "app was not running" (`JobLedger.swift:586-596`, `iris.swift:3439-3456`).
  - `reapOrphans` deletes every `iris-` container this process doesn't know about (`SandboxSessionManager.swift:8`, `:251-270`).
  - Overlap tracking is per process (`JobRunner.swift:103-105`).
- **Signals.**
  - No signal handler exists in `Sources/`.
  - `ProcessGroupRunner` resets every disposition in the child (`ProcessGroupRunner.swift:190-201`), and gives each `run_command` its own process group. So a terminal's Ctrl-C reaches only the CLI, and those groups outlive it.
  - The watchdog ends a hung turn by claiming `ending` and cancelling the turn (`JobRunner.swift:1199-1212`).
- **Homes.**
  - The lock is per home.
  - `swift run`/`run-dev.sh` and `Iris Dev.app` share `~/.iris-dev`.
  - The bare binary registers no URL scheme, so an `iris-dev://` link opened beside it launches `Iris Dev.app` on the same home (AGENTS.md).

## 0. Decided

1. **One lifetime `flock` per home**, on `conversations.sqlite.lock`, today's path. Whoever holds it is the only process that may open the store.
   - `open(O_RDWR | O_CREAT | O_CLOEXEC, 0600)`, then `flock(LOCK_EX | LOCK_NB)`.
   - Use `flock(2)`, never `fcntl`/`lockf`. A POSIX lock drops when *any* descriptor for the file closes, including a read of the payload.
   - Never unlink or rename the file. The kernel releases the lock on any death, SIGKILL included.
   - *Cost if wrong:* none beyond today's file.
2. **The descriptor can't be dropped.**
   - A held lock is a raw fd in a process-lifetime static, keyed by path. It is never closed, never `dup`ed (a `dup` loses `FD_CLOEXEC`), and never wrapped in anything that closes on `deinit`.
   - `claim` returns a value with no ownership, so `_ = claim(…)` releases nothing.
3. **The locked file must be the one at the path.**
   - After every successful `flock`, including the waiting app's, compare the fd's `fstat` device and inode with a `stat` of the path. If they differ, close the fd, reopen and retry.
   - After 3 tries the claim is `.failed`.
   - This covers a pre-#463 app's rename, the old docs' "delete the file", and an editor.
4. **`.failed` refuses everywhere.** Any error other than `EWOULDBLOCK` (`ENOTSUP`, `ENOLCK`, `EACCES`, a read-only or network mount) refuses, naming the path and the errno.
   - The CLI and the seeder exit 1.
   - The app shows an alert and quits. It never opens the store unlocked.
5. **The payload.**
   - It is one JSON line, `{"pid", "kind": "app"|"run-job"|"seed-dev-home", "job"?}`.
   - The holder writes it first, with `pwrite` at offset 0, and then `ftruncate`s to its length.
   - It is vacated (truncated to empty) on a clean exit, by the CLI and the app.
   - The payload only describes the holder; the lock decides who holds it.
   - A reader that finds it empty, unparsable or naming a dead pid (a new holder that hasn't written yet) re-reads for up to 1 s.
   - Pre-#463 binaries can't parse it as a pid, so they refuse, which is safe.
6. **No second lock file.** The waiting app tells a GUI holder from a CLI by `kind`.
   - If `kind` is still unknown after 1 s, the waiting app treats the holder as a GUI (decision 8). Refusing is harmless; waiting forever behind a GUI is not.
   - Without an app lock, a new `--run-job` can still claim the store between runs while the app waits, so a harness batch keeps the app waiting until the batch ends. That's accepted for a dev tool.
7. **The CLI refuses while the store is held** (ruling 1). Exit 1 names the holder: "the Iris app (pid N)", or "another --run-job (pid N, job X)".
   - `--dry-run` claims too.
   - The store `@autoclosure` stays as it is, and a test now pins it (§3).
8. **A GUI that finds a GUI holder refuses and quits** (ruling 3).
   - It shows an alert, "Iris is already running on this home", activates the holder (`NSRunningApplication`), and exits 0.
   - When the launch carried a link (the bare-binary case), the alert says the link was not run.
   - A GUI that is itself waiting re-reads `kind` on every poll. If a second waiting GUI won the race, the loser quits the same way.
9. **A GUI that finds a CLI holder waits** (ruling 2).
   - It polls `LOCK_NB` once a second on a main-queue `DispatchSourceTimer`, never `Task.sleep`, running decision 3's check each time.
   - There is no timeout and no Stop. When it wins the lock it completes the launch (decision 11).
10. **The waiting window touches nothing of `AppState`.**
    - A `@MainActor @Observable LaunchGate` (`.waiting(Holder)` / `.open`) is the only state.
    - `WindowGroup`, `Settings` and `Run Log` render `WaitingView` until `.open`. It says: "An `iris --run-job` is using this home (pid N, job X). Iris will open when it finishes."
    - The `MenuBarExtra` label and content take the gate's branch: an hourglass, the same sentence, and Quit.
    - The hotkey closure checks the gate *when pressed*.
    - Diagnostics touches no store and needs no gate.
11. **Launch completes in two idempotent halves, both on the main actor.**
    - `openStore()` runs once the lock is held: `IrisMigrator`, `ShippedSkills`, the `AppState.shared` setup, notifications, `reapOrphans` and the idle loop.
    - `finishLaunch()` runs once both `openStore()` and `applicationDidFinishLaunching` have happened, whichever is later. It does `startOnce` or `refuseRunJobURLsUntilSetUp`, then hands over the gate's links.
    - When the lock is free at launch, `openStore()` runs in `App.init` as today and `finishLaunch()` in did-finish, so nothing about today's order changes.
    - The sweeps need no owner data: only the holder runs them, so every leftover `running` row and every unregistered `iris-` container on this home belongs to a dead process.
    - `interruptedByQuitReason` becomes "the Iris process running it ended".
12. **A link that arrives while waiting is queued as in D2, then drained after launch.**
    - `LaunchGate` holds raw URLs in memory, never logs them, and keeps up to `RunJobURLIntake.capacity`.
    - At `finishLaunch` they go to `receiveRunJobURL`, oldest first. `RunJobURLIntake` holds them until the bookkeeping is done, then fires them.
    - Overflow posts one line, "N links that arrived while Iris waited were dropped unread".
    - D2's deferral is deleted: `URLDeferral`, `PendingURLFire`, `deferURLFire`, `.deferred`, `foreignStoreHolder*`, `noteForeignStoreHolder`, the notice, the waiting lines, and all of `LaunchLock.swift`, `ProcessStart` included. Nothing signals a holder any more, and the refusal message needs only the pid.
13. **A windowless cold start (D2) still shows the waiting notice**, as the status item's hourglass plus a small `Window("Iris is waiting")` scene, opened without activating the app.
    - *Why both:* the status item alone is easy to miss, and nothing else would explain a link that seems to do nothing for up to the run's timeout.
    - D2 kept link launches windowless so that a chat window wouldn't open per link. One small notice, shown only in this rare case and closed when the launch completes, doesn't break that.
    - *Cost if wrong:* a Shortcut user sees a small window they didn't ask for.
14. **`AppState.shared` traps unless this process is the app and holds the lock** for `IrisPaths.default.conversationsDB`.
    - `IrisMain` sets `ProcessRole` (`.app`, `.runJob`, `.perf`, `.bench`, `.seed`) first.
    - Every build traps, and so does every test: there is no test disarm. How each is safe:
      - **`--run-job`:** builds its own `AppState(store:)` (`RunJobCLI.swift:437`). After #489, nothing it reaches names `.shared`.
      - **`--perf`, `--bench`, `--seed-dev-home`:** none names `AppState`. The tools they run reach `.shared` only through #489's paths, now gone.
      - **Tests:** `AttachmentIntegrationTests` moves to `AppState(store: .inMemory())`. A test that reaches `.shared` by any other path now crashes the suite. That is the alarm.
    - *Cost if wrong:* a path nobody exercised crashes. That loses nothing while the app waits; once it's open, a crash loses up to the 2 s debounce, as today.
15. **#489, in PR 1.**
    - `ToolExecutor.execute`, the skill CRUD and `SkillCurator.curateSkills` take an `onSkillsChanged: @Sendable () async -> Void`. `IrisEngine` supplies its own `invalidateSystemPrompt()`, and `AppState.swift:4070` supplies its engine's.
    - The CLI never builds `AppState.shared`.
16. **The CLI stops cleanly on SIGINT, SIGTERM and SIGHUP.**
    - It installs a do-nothing `sigaction` handler with `SA_RESTART`, not `SIG_IGN`. A caught disposition resets to the default across `exec`, so no child inherits an ignore.
    - Each signal gets a `DispatchSource` on the CLI's own serial queue, not `.main`.
    - The first signal claims the run's `ending` as a third claimant, beside the turn and the watchdog. It cancels the turn, calls `LiveProcessGroups.terminateAll`, and waits up to 15 s for the turn to come back.
    - When the turn is back, or the 15 s are up (the turn is then abandoned, so an uncancellable await can't hang the stop), the CLI:
      - closes the row `interrupted`, "stopped by a signal (SIGINT)";
      - delivers the card;
      - flushes;
      - vacates the payload;
      - exits 2.
    - Before admission it exits 2 with no row, and a dry run exits 2 with nothing written.
    - A second SIGINT means exit now: `LiveProcessGroups.killAll()`, then `_exit(130)`. Decision 11's sweep closes the row later.
17. **`LiveProcessGroups`.** `ProcessGroupRunner` records each group at spawn and drops it once the leader is reaped and the kill sequence is over. `terminateAll` sends SIGTERM, then SIGKILL after the runner's grace, on a dispatch queue (invariant 4).
    - *Known gap:* a background job that redirected its output, so invariant 4 deliberately leaves it running, has left the registry once its leader is reaped. A CLI exit doesn't end it. The same is true today, and of the app.
18. **The seeder and `PerfCLI`** claim through the same primitive (`kind` `seed-dev-home`; `PerfCLI` on its scratch path). The seeder's "no readable pid" refusal goes.

## 1. Failure modes, re-checked under the lean design

| Brief (A) | Closed by |
|---|---|
| 1, 2. Iris rows and history erased or holed | The app opens the store only once the CLI is gone (9, 11), and each process has one `AppState` (14, 15). |
| 3. Metadata clobber, launch repairs from a stale snapshot | The same: the repairs run in the only `AppState`, behind the lock. |
| 4. `closeRunningRuns` marks the CLI's live run interrupted | 11: it runs after the CLI is dead. |
| 5. Double runs | One process runs jobs per home. |
| 6. `reapOrphans` kills the CLI's containers | 11, for one home (§5). |
| 7. App deletes the lock on quit | 1, 2: nothing unlinks or closes it. 3 survives anyone who does. |
| 8. Two GUIs on one home | 8. |
| 9. Migrations against an open store | The CLI opens only after its claim (pinned in §3). The app migrates in `openStore()`. |

**A holder that crashes**, CLI, app or seeder: the kernel frees the lock, the waiting app's next poll wins, and decision 11's sweep closes the dead run. `O_CLOEXEC` plus `POSIX_SPAWN_CLOEXEC_DEFAULT` mean no surviving child keeps it held. **Dev and release homes** have separate locks and never contend.

## 2. Components

- **`StoreLock`** (new, replaces `GUILock`):
  - `claim(at:kind:job:) -> Claim` (`.acquired`, `.held(Holder?)`, `.legacy(pid)`, `.failed(detail)`), plus `vacate()` and `holds(_:)`;
  - the fd static, the inode check, and the pure payload codec.
  - `.legacy` is a bare-pid file naming a live pid: a pre-#463 holder, refused.
- **`ProcessRole`**, **`LiveProcessGroups`**.
- **`LaunchGate`**, with `LaunchDecision.decide(_ claim:) -> .open | .wait | .refuse`, pure; **`WaitingView`**; the waiting `Window` scene.
- **`IrisApp` / `AppDelegate`:** `openStore()`, `finishLaunch()`, the gated scenes, hotkey and terminate, and `RunJobURLEvents` delivering to the gate.
- **`ToolExecutor`, `SkillCurator`, `IrisEngine`:** decision 15.
- **`RunJobCLI` / `JobRunner`:** the claim, the signal sources, and the stop claimant.
- **Deleted:** `GUILock`, `LaunchLock.swift`, D2's deferral, and their tests (`LaunchLockTests`, `RunJobURLDeferralTests`, the `GUILock` cases of `RunJobCLITests`).

## 3. Verification

**Unit tests.** They use Swift Testing and real `flock` on temp files, never `~/.iris` or `~/.iris-dev`. Suites that spawn get `.timeLimit(.minutes(1))` and `value(of:within:)`.
- **`StoreLock`:**
  - two claims in one process conflict;
  - a dropped claim still excludes;
  - a stub holder (`perl -MFcntl=:flock -e 'open F,">>",shift; flock F,LOCK_EX; print "ok\n"; sleep 60'`) blocks a claim, and SIGKILLing it frees the lock;
  - the fd has `FD_CLOEXEC` from the `open` (`fcntl(F_GETFD)`);
  - a path replaced under a holder is detected, and the claim reopens;
  - an injected `flock` returning `ENOTSUP` gives `.failed`;
  - the payload round-trips, a half-written one reads as nil, and `vacate()` leaves the file empty;
  - a bare pid naming a live stub is `.legacy`.
- **`LaunchDecision`:** the table of holder kinds, including an unknown kind after 1 s, which refuses.
- **`LaunchGate`:**
  - an injected `openStore` is never called while waiting;
  - links are held in order up to capacity, then counted, and delivered after launch;
  - a poll that finds a GUI holder quits.
- **`finishLaunch`:** it runs exactly once, after both triggers, in either order.
- **#489:** a `--run-job` (fake client) whose turn calls `write_file` into a skill folder, then `create_skill`, invalidates the run's own engine. A run with `ProcessRole.runJob` set doesn't trap, which proves nothing reached `.shared`.
- **`RunJobCLI`:**
  - with the lock held by a stub, the CLI exits 1, names the holder, never calls the store factory, and leaves the db's mtime and `grdb_migrations` unchanged;
  - an injected signal before admission: exit 2, no row;
  - an injected signal mid-run: `interrupted` with the stop reason, the card delivered, the save flushed, the payload empty, the stub's `ProcessGroupRunner` groups gone, exit 2;
  - a turn that ignores cancellation: the same, after the (shortened) grace;
  - a second SIGINT: `killAll`, exit 130.
- **Signal inheritance:** with the handlers installed, `/bin/sh -c 'kill -TERM $$; sleep 5'` dies by SIGTERM, both through `Process` and through `ProcessGroupRunner`.
- **#463's repro:** while a stub holds a temp lock, nothing opens the store. After it dies, the store opens and the CLI's card is at its ordinal.

**GUI checks on `work`**, under the `gui-test-lease`, with a dev build, `~/.iris-dev`, and a test job whose turn runs `sleep` through `run_command`:
1. Dock launch during a run: the waiting window and the hourglass name the pid and job, and the store's mtime doesn't move. After the run, Iris opens with the card in place.
2. Cold `iris-dev://run-job/<token>` launch during a run: the small waiting window and the hourglass appear, with no chat window. After the run, the link fires, and both cards are in Iris.
3. While waiting: the hotkey, Cmd-, the Run Log menu item, and Quit. No crash, and the store doesn't open.
4. `run-dev.sh` beside `Iris Dev.app` in both orders, and an `iris-dev://` link with `swift run` up: the second GUI shows the alert and quits.
5. `--run-job` with the app open: exit 1, naming the app.
6. Ctrl-C a terminal `--run-job` mid-`sleep`: exit 2, the row says stopped, and `pgrep sleep` finds nothing. Repeat with a second Ctrl-C: it exits at once, and the `sleep` is gone.
7. SIGKILL the CLI mid-run while the app waits: the app opens within a second, and the row is closed at open.

## 4. PR split and docs (invariant 9)

Each PR is based on `main`, never stacked, and carries the doc fixes its change makes necessary. I searched for the sentences each one makes untrue.
1. **The lock, the waiting launch, and #489:** decisions 1-15 and 18.
   - Fix `README.md:250-258`: the pid file, "created, not checked and then written".
   - Fix `docs/jobs.md:1146-1167`: the pid file, the takeover, "delete the file", "do not start Iris while a `--run-job` is in flight", the app keeping the lock.
   - Fix `docs/jobs.md:1173`'s exit-1 row (add `.failed`) and `:1234-1237`'s 5 s / 10 min URL wait.
   - Fix `AGENTS.md`'s dev-builds paragraph: "both would open the store's GUI lock"; the `iris-dev://` link that "launches Iris Dev.app beside it", which now refuses; the seeder's "doesn't hold a readable pid (delete it and retry)".
   - D6 spec decision 14 (and `:194`, `:255`, `:298`) gets one line: "Superseded by 2026-10-11-single-writer-store.md."
   - Agent-visible: `interruptedByQuitReason` (`iris.swift:3439`), which `get_job_run` returns, and D2's notice and waiting lines (`RunJobURL.swift:52`).
   - Comments: `GUILock`'s header (`RunJobCLI.swift:2-17`), `:355-364`, `IrisMain.swift:27-28`, `iris.swift:5471-5473`, `:5487-5498`, `SandboxSessionManager.swift:244-249`, `RunJobURLIntake.swift:3-6`.
   - GUI checks 1-5 and 7.
2. **The CLI's clean stop:** decisions 16-17.
   - Add to `docs/jobs.md` and the README: Ctrl-C and SIGTERM stop a run cleanly, its row reads "stopped by a signal", it exits 2, and a second Ctrl-C exits at once. Also document decision 17's known gap.
   - GUI check 6.

## 5. Not in this deliverable

- A Stop or Force stop for a CLI run from the app (dropped by the lean ruling).
- `--run-job` while the app is open, over a socket (ruling 1).
- Reaping containers across homes. The `iris-` prefix is shared, so a dev launch can still reap the release app's live containers; that needs its own issue.
- A notification response that launches the app while it waits. The delegate is installed in `openStore()`, so the response is lost. The card is still in Iris.
- Mixed pre-#463 binaries, beyond decision 3 and `.legacy`.
