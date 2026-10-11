# A single writer per store (#463)

Status: **proposed** (2026-10-11). The design brief is `.superpowers/sdd/463-design-brief.md`. The owner ruled on its questions on 2026-10-11, and those rulings are binding here: the CLI keeps refusing while the app holds the store, with no IPC hand-off (ruling 1); an app launched during a CLI run waits behind a screen that never touches the store, offers "Stop the run", and never times out into opening it (ruling 2); a second GUI on one home refuses and quits (ruling 3); the lock is a lifetime `flock` opened `O_CLOEXEC` (ruling 4). This replaces #390/#391's `GUILock` and D6 decision 14's `LaunchLock` mitigation outright; nothing of the pid-file protocol survives except the file's path.

## Facts this rests on

Checked against `main` at `e418b29`, 2026-10-11. Paths are under `Sources/IrisKit/`.

- **Writes overwrite from a snapshot.** `markChanged` debounces 0.5 s with a 2 s max wait (`AppState.swift:3833`, `:3840`), so a CLI writes throughout a run, then flushes (`RunJobCLI.swift:491`). A message append does `INSERT OR REPLACE` from `from` to the end of the writer's array, then `DELETE … ordinal >= count` (`ConversationStore.swift:844-877`); history is the same (`:879-887`). A `.metadata` write rewrites every column of the row (`:812-822`). Nothing re-reads before writing.
- **What a CLI run writes.** Its hidden transcript (`JobRunner.swift:1682-1704`); the card, as a message append plus a history append (`EventDelivery.swift:49-54`); ledger rows directly. Its `AppState.init` runs the launch repairs (`AppState.swift:1195-1196`) and persists role normalization (`:4047`), and `activityConversationId` can create a pinned Iris and unpin the others (`:1554-1572`). Facts go to `fact_store.sqlite` (`FactStoreManager.swift:160-171`).
- **Locks today.** The CLI claims `conversations.sqlite.lock` (`IrisPaths.swift:148`) by `link(2)`, takes over a dead pid under a directory `flock`, and refuses a live one (`RunJobCLI.swift:126-166`, `:366-384`). The app never checks: `GUILock.acquire` is an `.atomic` write, a rename over the path (`RunJobCLI.swift:234-240`, called at `iris.swift:5500`). `GUILock.release` deletes the file whenever it names this pid (`RunJobCLI.swift:244-248`, `iris.swift:5474`). `PerfCLI` reuses the protocol for its scratch workspace (`PerfCLI.swift:117`), and the seeder reads it on the release home (`DevHomeSeeder.swift:50`).
- **D2's mitigation.** `LaunchLock.read` reads the earlier holder and its start time (`LaunchLock.swift:53-82`); `noteForeignStoreHolder` posts a notice into Iris (`:87-92`); a URL fire is deferred, re-checked every 5 s, and given up after 600 s (`RunJobURLHandling.swift:60-71`, `RunJobURL.swift:166-177`). Its per-job wait counts toward the URL limit (`RunJobURLHandling.swift:92`).
- **Launch.** `AppState.shared` is a lazy `static let` (`AppState.swift:375`) whose init opens and migrates the store (`ConversationStore.swift:200`). `IrisApp.init` migrates the home, seeds skills, touches `.shared`, and starts `reapOrphans` (`iris.swift:5499-5522`). The scenes (`:5544-5578`), `ChatView`'s `@State` (`ChatView.swift:6`), `SettingsView` (`SettingsView.swift:148`), the hotkey (`iris.swift:5539`), `applicationDidFinishLaunching` (`:5455-5460`), `applicationWillTerminate` (`:5468-5469`) and the URL handler (`RunJobURLEvents.swift:24`) all reach it. The link handler is installed in `applicationWillFinishLaunching` (`iris.swift:5442-5447`), and a cold link opens no window. `RunJobURLIntake` holds links until job bookkeeping is done (`RunJobURLIntake.swift:7-17`, `:44-49`).
- **Launch-time sweeps.** `closeRunningRuns` marks every `running` row `interrupted`, "app was not running" (`JobLedger.swift:586-596`, `iris.swift:3439-3456`), and `finish` has no status guard (`JobLedger.swift:446-465`). `reapOrphans` deletes every `iris-` container outside this process's registries (`SandboxSessionManager.swift:8`, `:251-270`); its comment "before anything else can have started one" (`:244-245`) is false while a CLI runs.
- **Overlap is per process**: `JobRunner.inFlight` (`JobRunner.swift:103-105`, `:259`).
- **The CLI's hold is bounded but uncapped.** `runTimeoutSeconds` defaults to 600 (`JobPolicy.swift:36`) and has no ceiling (`JobRunner.swift:2227-2231`); the watchdog ends a hung turn by claiming `ending` and cancelling it (`:1199-1212`). Approvals fail closed. No SIGTERM handler exists anywhere in `Sources/`.
- **Homes.** The lock is per home; `swift run`/`run-dev.sh` and `Iris Dev.app` share `~/.iris-dev`, the release app has `~/.iris`. The container prefix is not per home (`SandboxSessionManager.swift:8`).

## 0. Decided

1. **Two lifetime flocks per home.** `conversations.sqlite.lock` (the *store lease*, same path as today) is held by whichever process may open the store. `app.lock` (the *app lease*) is held by a GUI for its whole life, waiting or open. Both are `open(O_RDWR | O_CREAT | O_CLOEXEC, 0600)` plus `flock(LOCK_EX | LOCK_NB)`, held until exit, never unlinked, never renamed; the kernel drops them on any death, SIGKILL included.
   - *Why:* ruling 4. The app lease is what tells a waiting GUI from a CLI and gives the app priority (decision 5) without reading anything racy.
   - *Cost if wrong:* a second file in the home.
2. **The store lease carries a payload, written on the held descriptor.** One JSON line, `{"pid", "kind": "app"|"run-job"|"seed-dev-home", "job"?, "started", "deadline"?}`, written with `ftruncate` + `pwrite` after the lock is taken; the CLI rewrites it with `deadline` once it knows the job's timeout. It is display only: the lock decides, the payload explains.
   - A reader that finds it empty or unparsable (a holder between `flock` and `pwrite`) re-reads for up to 1 s, then shows "another Iris process".
   - *Why:* the waiting screen names what it waits for, and Stop needs a pid. Pre-#463 binaries parse the whole file as a pid, so they read it as unreadable and refuse, which is safe.
   - *Cost if wrong:* an old CLI tells the user to delete the file; doing so while a new holder lives makes the next claimant open a fresh inode. Decision 11 bounds this to the transition.
3. **The CLI refuses while the app holds either lease** (ruling 1). It probes the app lease first, then claims the store lease; either held is exit 1, naming the holder from the payload ("the app" or "--run-job <job> (pid N)"). `--dry-run` takes the lease too, as today. No socket, no forwarding.
4. **A GUI that finds the app lease held refuses and quits** (ruling 3): an `NSAlert`, "Iris is already running on this home", raised before any scene; the holder is activated (`NSRunningApplication(processIdentifier:)`) when it is an app; then `exit(0)`. This covers `swift run`/`run-dev.sh` beside `Iris Dev.app`, and a second GUI launched while the first one waits. A probe (decision 3's, or the seeder's) holds the app lease for microseconds, so a GUI retries for 1 s before it concludes another GUI has it.
   - *Cost if wrong:* the owner who wanted two dev windows on one home cannot have them; they never safely could.
5. **A GUI that holds the app lease but not the store lease waits** (ruling 2). It shows the waiting surface (decision 6) and polls `LOCK_NB` every second on a dispatch timer, never `Task.sleep` on the pool. Because the app lease is held, every new `--run-job` refuses (decision 3), so a harness running a batch cannot starve the app: it waits for the run in flight and no more. No timeout opens the store.
   - *Cost if wrong:* the owner waits out a run up to its `deadline`; the screen says until when, and offers Stop.
6. **The waiting surface touches nothing of `AppState`.** A new `@Observable LaunchGate` (phase `.waiting(Holder)` / `.open`) is the only state. The `WindowGroup`, `Settings` and `Run Log` scenes render a `WaitingView` until `.open`; the `MenuBarExtra` label shows an hourglass and its menu "Waiting for --run-job <job> (pid N, until T)", "Stop the run" and "Quit". The window shows the same text and buttons, and a count of links held.
   - A cold start by a link stays windowless (D2): the status item carries the wait, a Dock click opens the waiting window.
   - The hotkey raises the waiting window.
7. **`AppState.shared` traps without the store lease.** Its accessor checks `StoreLease.heldByThisProcess` and calls `preconditionFailure` otherwise, in every build. Under test the check is disarmed (the per-process test home, as `IrisPaths.default` already detects), so `AttachmentIntegrationTests`' use is unaffected.
   - *Why:* a missed path must fail as a crash, which loses nothing, not as a second writer, which loses rows. The GUI checks drive every scene while waiting.
   - *Cost if wrong:* a path nobody exercised crashes the app during a CLI run.
8. **Everything that writes the home runs after the store lease, in `completeLaunch()`.** What `IrisApp.init` does after `GUILock.acquire()` today (`IrisMigrator`, `ShippedSkills`, the `AppState.shared` setup, notifications, `reapOrphans` and the idle loop) and what `applicationDidFinishLaunching` does with `AppState` (`startOnce` / `refuseRunJobURLsUntilSetUp`) move into one function, run synchronously when the lease is free at launch, else when the poll wins it. Then `closeRunningRuns` closes only rows whose process is dead, `reapOrphans` only reaps a dead process's containers, and every migration runs with no other opener.
   - `interruptedByQuitReason` becomes "the Iris process running it ended": a dead CLI's row is closed by it too, and "app was not running" would be false.
9. **Links that arrive while waiting are held by `LaunchGate`, not dropped and not timed out.** Raw URLs, in memory, never logged, up to `RunJobURLIntake.capacity`; beyond it a count. At `completeLaunch` they go to `receiveRunJobURL` in order, which is `.starting` then, so `RunJobURLIntake` holds them until bookkeeping as today, and the overflow posts D2's flood refusal line. D2's deferral goes: `URLDeferral`, `URLDeferralTimer`, `PendingURLFire`, `deferURLFire`, the `.deferred` outcome, `foreignStoreHolder*`, `processStart`, `noteForeignStoreHolder`, `foreignHolderNotice`, the waiting and give-up lines, and `LaunchLock.swift` entire. The launch notice goes with no replacement: nothing raced, and the waiting screen already said why.
   - *Cost if wrong:* a link opened an hour into a long wait fires an hour late. The URL limit still applies.
10. **Stop sends SIGTERM, and the CLI yields at its next safe point.** The app re-checks that the store lease is still held immediately before `kill(pid, SIGTERM)`, so a holder that has exited (and freed the lease) is never signalled. The CLI installs a `DispatchSource` for SIGTERM (with `SIG_IGN` set first). On it, the run's `ending` gets a third claimant beside the turn and the watchdog: the stop claims it, cancels the turn, waits up to 15 s for the cancelled turn to come back (so `ProcessGroupRunner` and the in-VM killer finish their ladders, invariant 4), closes the row `interrupted` with reason "stopped: the app needed the store", delivers its card, `flushSave`s, and exits 2. A stop that loses the claim (the run already ended) just lets the CLI finish. A dry run exits 2 with nothing written. Stop is not offered for a `seed-dev-home` holder, which takes seconds.
    - If the CLI has not exited 30 s after Stop, the screen says so and keeps waiting; there is no force-kill button (open question 1).
    - *Cost if wrong:* the run's tokens are spent and its measurement lost, by the owner's own click.
11. **Pre-#463 binaries.** A new claimant that wins the store lease but finds a bare-pid payload naming a live pid other than itself refuses: only a pre-#463 app, or a pre-#463 CLI in its takeover window, writes that format. Nothing else is done for mixed versions; the window closes when every build on the machine is rebuilt.
12. **The seeder claims the release home's leases** with `LOCK_NB` (app lease probed, store lease held) for the length of the copy, kind `seed-dev-home`. A release app launched mid-seed waits seconds. The "lock file names no readable pid" refusal (`DevHomeSeeder.swift:47-54`) goes. `PerfCLI`'s scratch lock moves to the same `StoreLease` primitive; its semantics (refuse a live holder) are unchanged.
13. **Quit while waiting** releases nothing by hand and flushes nothing: `applicationWillTerminate` asks `LaunchGate` first and skips the `AppState.shared` flush. Held links are dropped; the waiting window counted them.

## 1. Failure modes, closed

| Brief (A) | Closed by |
|---|---|
| 1, 2. Iris rows and history erased or holed | Decisions 3, 5, 7: one process has the store at a time, so every snapshot is the only one. |
| 3. Whole-row metadata clobber, launch repairs from a stale snapshot | Same; the repairs run in `AppState.init`, behind the lease. |
| 4. `closeRunningRuns` marks the CLI's live run interrupted | Decision 8: it runs only after the CLI is gone, when the row is truly orphaned. `finish` keeps no status guard; no live writer can be raced. |
| 5. Double runs from per-process overlap | `inFlight` is again the whole story: one process runs jobs per home. |
| 6. `reapOrphans` kills the CLI's containers | Decision 8, for one home. The release/dev cross-home reap is out of scope (§5). |
| 7. App deletes the lock on quit | Decision 1: nothing unlinks a lease; the kernel releases it. |
| 8. Two GUIs on one home | Decision 4. |
| 9. Migrations against an open store | Decision 8 (store and `IrisMigrator`), decision 11 for old binaries. |

**A holder that crashes**, CLI or app or seeder: the kernel frees both leases, a waiting app's next poll wins, and `closeRunningRuns` closes the dead run with decision 8's reason. No stale-lock takeover, no pid-reuse check. `O_CLOEXEC` means a `run_command` background child left running (invariant 4) never inherits a lease and keeps a dead holder's store held.

**Dev and release homes** never contend: each has its own two leases. `swift run` beside `Iris Dev.app` (or two `run-dev.sh`) is decision 4.

## 2. Components

- **`StoreLease`** (new, replaces `GUILock`): `claim(at:kind:job:) -> Claim` (`.acquired(Lease)`, `.held(Holder?)`, `.legacy(pid)`, `.failed(detail)`), `Lease.update(deadline:)`, `probe(at:) -> Holder?`, `heldByThisProcess`. The payload codec, pure. The same type serves the app lease (`IrisPaths.appLockFile`).
- **`LaunchGate`** (new, `@MainActor @Observable`): the phase, held URLs and overflow count, the poll timer seam, `stop()`, and `LaunchDecision.decide(appLease:storeLease:) -> .open | .wait(Holder) | .refuse(Holder?)`, pure.
- **`WaitingView`** (new) for the window, Settings and Run Log scenes, and the status item's waiting label and menu.
- **`IrisApp` / `AppDelegate`:** `completeLaunch()`; the gated scenes; the gated hotkey and terminate; `RunJobURLEvents` delivering to the gate.
- **`AppState.shared`:** the decision 7 accessor.
- **`RunJobCLI`:** the lease claim, the payload deadline, the SIGTERM source, the refusal sentences. **`JobRunner`:** the stop claimant on `ending`, and the stop reason.
- **Deleted:** `LaunchLock.swift`, `GUILock`'s link/takeover/directory-lock code, D2's deferral (decision 9), and their tests (`LaunchLockTests`, `RunJobURLDeferralTests`, the `GUILock` cases of `RunJobCLITests`).

## 3. Agent-facing text and docs (invariant 9)

Searched; each of these is made untrue:
- `README.md:250-258`: the pid lock file, "created, not checked and then written", the refusal list. It becomes: the CLI refuses while the app runs on that home; an app opened during a run waits for it, and can stop it.
- `docs/jobs.md:1146-1167`: the pid file, crash takeover, "delete the file", "do not start Iris while a `--run-job` is in flight", the app keeping the lock. `:1173`'s exit-1 row. `:1234-1237`: the 5 s / 10 min URL wait.
- `AGENTS.md`, dev builds: "do not run both at once … both would open the store's GUI lock" (now the second refuses and quits), and the seeder's "holds the release store's GUI lock … doesn't hold a readable pid (delete it and retry)".
- `docs/specs/2026-10-09-agency-native-surfaces.md` decision 14 (and `:194`, `:255`, `:298`): dated specs stay as written; decision 14 gets one line, "Superseded by 2026-10-11-single-writer-store.md; no bound, no deferral."
- Agent-visible: `interruptedByQuitReason` (`iris.swift:3439`), which `get_job_run` returns to a model; the new stop reason; D2's notice and waiting lines (`RunJobURL.swift:52` and the deferral lines), which sat in Iris's history.
- Comments: `GUILock`'s header (`RunJobCLI.swift:2-17`), its `run` comment (`:355-364`), `IrisApp.init`'s (`iris.swift:5487-5498`), terminate's (`:5471-5473`), `SandboxSessionManager.swift:244-249`, `RunJobURLIntake.swift:3-6`.

## 4. Verification

**Unit tests** (Swift Testing, real `flock` on files under a temp directory, never `~/.iris` or `~/.iris-dev`; suites that spawn get `.timeLimit(.minutes(1))` and await through `value(of:within:)`):
- `StoreLease`: two claims in one process conflict (separate `open`s); a stub holder (`perl -MFcntl=:flock -e 'open F,">>",shift; flock F,LOCK_EX; print "ok\n"; sleep 60'`) blocks a claim, and SIGKILLing it frees it; a child spawned through `ProcessGroupRunner` while the lease is held does not keep it held after the lease is closed (`O_CLOEXEC`); the inode is unchanged across claim, payload update and close, and the file still exists after; the payload round-trips, and a truncated one reads as nil; a bare-pid payload naming this test's live stub is `.legacy`.
- `LaunchDecision`: the table of app lease × store lease × payload kind.
- `LaunchGate`: links held in order up to capacity, the overflow count, delivery at open; a store factory injected into the gate's open path is never called while waiting; Stop re-checks the lease (a freed lease sends nothing), using an injected `kill`.
- `RunJobCLI`: refusal with the app lease held by a stub, and with the store lease held by a stub, both exit 1 with the holder named; through `RunJobCLI.run` with an injected stop trigger, the row is `interrupted` with the stop reason, the card is in Iris, the save is flushed, the lease is released, exit 2; a stop after the run ended changes nothing.
- #463's repro as a test: with a stub holding a temp store lease, `LaunchDecision` says wait and nothing opens the store; after the stub dies, it opens and the CLI's card is at its ordinal.
- `completeLaunch` ordering, recorded through seams: nothing in it runs before the lease.

**GUI checks on `work`**, under the `gui-test-lease`, with a dev build and a `--run-job` against `~/.iris-dev` (a test job whose turn sleeps):
1. Dock launch during a run: waiting window, status item hourglass, job and deadline named; the store's mtime does not move.
2. `iris-dev://run-job/<token>` cold launch during a run: no window, the status item waits; after the run, the fire happens and both cards are in Iris, none lost.
3. Stop the run: the CLI exits 2, its row reads the stop reason, the app opens.
4. Quit while waiting; then the hotkey, Cmd-, and the Run Log menu item while waiting (no crash, no store open).
5. `run-dev.sh` beside `Iris Dev.app`, both orders: the second shows the alert and quits.
6. `--run-job` with the app open, and with the app waiting: exit 1.
7. SIGKILL the CLI mid-run: the app opens within a second, and the row is closed with the new reason.

## 5. PR split

Each PR is based on `main`, never stacked, and carries its own §3 doc fixes.
1. **The leases.** `StoreLease`, the app lease, the CLI/`PerfCLI`/seeder moved onto them, decision 11. The app takes both leases at launch; if the store lease is held it still proceeds through D2's path (reading the pid from the payload), so behaviour is today's minus failure 7. `GUILock` goes.
2. **The CLI yields on SIGTERM** (decision 10). Lands before 3 so Stop has something clean to talk to.
3. **The app waits.** `LaunchGate`, `WaitingView`, decisions 4-9 and 13, the `AppState.shared` trap, and D2's deferral deleted. GUI checks 1-7 on `work`.

## 6. Not in this deliverable

- `--run-job` while the app is open, over a socket (brief option iii): not wanted now (ruling 1).
- Containers reaped across homes: the `iris-` prefix is shared, so a dev launch can still reap the release app's live containers. A separate issue; it needs a per-home prefix.
- Notification responses that launch the app while it waits: the delegate is installed at `completeLaunch`, so such a response is lost. Rare (a banner from a run that ended before a relaunch), and the card is still in Iris.
- Mixed pre-#463 binaries beyond decision 11.
- `AppDefaultsImport`, which runs before any lease: it writes a defaults domain once, under its own marker, not the store.

**Open questions**
1. Should the waiting screen offer a force stop (SIGKILL) after Stop has gone unanswered for 30 s? Ruling 2 says a clean stop; this spec offers none.
2. SIGINT (Ctrl-C in the terminal) still kills the CLI outright, leaving the row for decision 8 to close. Should it take decision 10's path too?
