# A Single Writer per Store (#463): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only one process at a time may open a home's `conversations.sqlite`. A `--run-job` refuses while the app has the store. An app launched during a `--run-job` waits behind a window that never touches the store. A second GUI on one home refuses and quits. A `--run-job` stops cleanly on SIGINT, SIGTERM and SIGHUP.

**Architecture:**
- One new primitive, `StoreLock`, replaces `GUILock`. It holds a lifetime `flock(2)` on `conversations.sqlite.lock`, opened `O_CLOEXEC`. The descriptor lives in a process-lifetime table and is never closed. The claim checks the inode, then writes a one-line JSON payload (`pid`, `kind`, `job`) before it returns.
- The CLI, the seeder and `PerfCLI` claim through `StoreLock`.
- The app asks a pure `LaunchDecision`. A main-actor `LaunchGate` then opens the store, waits (a 1 s main-queue poll), or refuses with an alert. Every scene renders `WaitingView` until the gate is open. `openStore()` and `finishLaunch()` split today's launch into two idempotent halves.
- `AppState.shared` traps unless `ProcessRole` is `.app` and this process holds its home's lock. #489 lands with the trap: skill writes invalidate the engine that made them, through an injected `onSkillsChanged`, never `AppState.shared`.
- PR 2 adds `LiveProcessGroups` (every live `ProcessGroupRunner` group), a `RunStop` that claims a run's ending as a third claimant beside the turn and the watchdog, and `CLISignals`/`CLIStop` for the CLI's signals.

**Tech Stack:** Swift 6.3, SwiftUI (`WindowGroup`, `Window`, `Settings`, `MenuBarExtra`), AppKit (`NSAlert`, `NSRunningApplication`), Darwin (`flock`, `pwrite`, `ftruncate`, `fstat`, `sigaction`), Dispatch (`DispatchSourceTimer`, `DispatchSourceSignal`), GRDB, Swift Testing (exit tests included). No new dependencies.

**Spec:** `docs/specs/2026-10-11-single-writer-store.md` (owner-approved in #487, binding; #487 merges before this plan's first PR). Read it in full before any task. "Decision N" below means spec §0.N. The ledger is `.superpowers/sdd/463/progress.md`, and the review rounds are on #487. Where this plan departs from the spec, see **Plan notes**. Each departure is a proposed ruling for the owner.

**Scope:** spec §4, both PRs.
- PR 1 (Tasks 1-10): decisions 1-15 and 18. Branch `feat/463-single-writer`, based on `main`.
- PR 2 (Tasks 11-16): decisions 16-17, plus the coordinator's ruling on #490 that a second Ctrl-C deletes the run's containers (plan note 15). Branch `feat/463-cli-clean-stop`. **Cut from `main` after PR 1 merges.** It uses PR 1's `StoreLock.vacate(at:)` and `ProcessRole`. Never stack it on PR 1's branch.

Every line number below was read on `main` at `e418b29`. Re-read the cited lines before editing, because earlier tasks in a PR move them.

## Global Constraints

- **Code lives in `Sources/IrisKit/`.** Tests live in `Tests/irisTests/` and use `@testable import IrisKit`. Swift Testing only (`@Suite`, `@Test`, `#expect`). The one XCTest file this plan touches (`AttachmentIntegrationTests`) stays XCTest.
- **The lock, verbatim from decisions 1-5:**
  - The path is `conversations.sqlite.lock` beside the store (`IrisPaths.storeLockFile`, renamed from `guiLockFile` in Task 1).
  - `open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)`, then `flock(fd, LOCK_EX | LOCK_NB)`. Use `flock(2)`, never `fcntl`/`lockf`.
  - Never unlink or rename the file. Never close, `dup` or wrap a held descriptor.
  - After every successful `flock`, compare `fstat(fd)` with `stat(path)` (device and inode). If they differ, close, reopen and retry. After 3 tries the claim is `.failed`.
  - Inside `claim()`, in this order: `flock`, the inode check, `pwrite` at offset 0, then `ftruncate` to the payload's length. If the write fails, `claim()` closes the fd and returns `.failed`. Only the inode check (and, for a bare-pid prior payload, one `kill(pid, 0)`) runs between the `flock` and the `pwrite` (plan note 1). No path resolution, directory creation or `FileManager` call may sit there.
  - The payload is one JSON line, keys sorted: `{"job":"<as typed>","kind":"app"|"run-job"|"seed-dev-home"|"perf","pid":N}` followed by `\n`. `job` is optional. A reader parses only up to the first newline.
  - A clean exit vacates the payload (truncates it to empty), in the CLI, the seeder and the app.
- **`.failed` refuses everywhere** (decision 4). The CLI and the seeder exit 1, naming the path and the errno. The app shows an alert and quits. Nothing opens the store unlocked.
- **The 1 s rule** (decisions 5, 6): an empty, unparsable or dead-pid payload under a held lock is re-read for up to 1 s. If it is still unknown after that, the app treats the holder as a GUI and refuses.
- **The sentences, verbatim:**
  - Waiting: `An iris --run-job is using this home (pid N, job X). Iris will open when it finishes.` (Plan note 11 drops the spec's backticks.)
  - Second GUI: title `Iris is already running on this home`. When the launch carried a link: `The link you opened was not run.`
  - CLI refusal names the holder: `the Iris app (pid N)` or `another --run-job (pid N, job X)`.
  - Overflow: `N links that arrived while Iris waited were dropped unread.`
  - `interruptedByQuitReason`: `the Iris process running it ended`.
  - PR 2 row reason: `stopped by a signal (SIGINT)` (or `SIGTERM`, `SIGHUP`).
- **Exit codes** (`docs/jobs.md`'s table): CLI refusal 1. A clean stop 2, and 2 before admission or in a dry run. A second signal `_exit(128 + signal)`, so 130 for SIGINT.
- **Invariants:**
  - 1: no persisted field is added. In particular no owner pid on `job_runs` (decision 11).
  - 2: `LaunchGate` is `@Observable`, never `ObservableObject` or `@Published`.
  - 4: every new deadline or poll runs on a dispatch queue, never `Task.sleep` on the cooperative pool. That covers the 1 s poll, the 15 s stop grace and the kill ladders. `LiveProcessGroups` never signals a reaped group.
  - 7: tests never touch `~/.iris` or `~/.iris-dev`, never mutate `ConfigManager.shared`, never set `ProcessRole` in the shared test process (only inside an exit test's child), and never call `LiveProcessGroups.shared.terminateAll()`/`killAll()` (each test builds its own registry). Lock files live under `FileManager.default.temporaryDirectory`.
  - 9: each PR ends with a task that greps for what it made untrue (Tasks 9 and 14).
- **Bounded tests.**
  - Await every unstructured task through `value(of:within:)` (`Tests/irisTests/BoundedWait.swift`), never bare.
  - Every suite that starts a task, a process or a timer carries `.timeLimit(.minutes(1))`.
  - Stub processes (`LockStub`, Task 1) wait for readiness with a semaphore timeout, never unbounded.
  - CI runs `swift test --no-parallel` on a 3-core runner, so timing margins are generous. A grace a test shortens is never under 0.3 s, and nothing asserts an upper bound under 5 s. Exit tests re-launch the test binary, so this plan keeps them to the nine that need a process of their own (five in Task 8, four in Task 14).
  - Run focused tests as `timeout 300 scripts/test-filter.sh <TypeName>` and quote the count it ran (`--filter` takes the type name, AGENTS.md).
  - The full suite is `timeout 900 swift test`. It is green only with exit 0, the Swift Testing line `Test run with N tests … passed`, and XCTest's `Executed N tests, with 0 failures`. If a `timeout` fires, sweep `pkill -f swiftpm-testing-helper`.
- **Every task ends with `scripts/check-warnings.sh` exiting 0** (#286). Fix a warning at its source and never suppress it.
- **No paid calls in tests.** Model turns run on `FakeLLMClient` or a stub client.
- **GUI work** (Tasks 10 and 16) is done by `work` on its laptop, under the host-wide lease (`python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: …" --minutes N --on-behalf-of <peer>`, and `release` as soon as the pass ends, pass or fail). It runs Iris Dev.app built by `scripts/build-app.sh Debug` into a non-temp directory inside the worktree, signed with `scripts/sign.sh`, with stale LaunchServices registrations removed first. Evidence is command output (`osascript` UI queries, `sqlite3`, `stat`, `pgrep`, `container list`, exit codes), not screenshots. Never launch a Release configuration.
- **Commits:** conventional (`feat:`, `fix:`, `docs:`, `test:`), no emoji, ending with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx
  ```

## Review Focus

1. **A first launch on a machine with no home yet.** On a fresh install `~/.iris` (or `~/.iris-dev`) does not exist, so the lock's directory does not either. A person expects Iris to open. `claim()` creates the directory before it opens the file, and outside the flock-to-pwrite window.
   - Test: Task 1, `claimCreatesTheMissingHome`.
2. **Quitting while Iris waits.** Cmd-Q, or Quit from the hourglass menu or the waiting window, while a `--run-job` holds the store. A person expects Iris to quit quietly. `applicationWillTerminate` today calls `AppState.shared.flushSave()`, which would trap (decision 14) or open the store. The waiting app must also not vacate the CLI's payload, since it holds no lock.
   - Tests: Task 5, `quitWhileWaitingFlushesNothing`. Task 1, `vacateIsANoOpForANonHolder`.
3. **A harness batch while the app waits** (decision 6's accepted cost). Each new `--run-job` may claim the store between polls. A person expects the waiting window to name the run that is actually going, not the first one. And if a GUI wins in between, this waiter quits (decision 8's last bullet).
   - Test: Task 5, `waitingTracksTheCurrentHolder`.
4. **Ctrl-C during `--dry-run` while its gate is running.** A person expects exit 2 at once, no row, and nothing the gate spawned left running. A dry run never arms a run, so the stop takes the before-admission path. That path has to kill the host groups and delete the gate's `iris-gate-*` container as well.
   - Tests: Task 14, `signalDuringDryRun` (the exit path runs the kill and the delete, in order). Task 12, `registriesRecord` (a gate's container is in the box the delete reads) and `deletesInParallelInTheirOwnGroups` (the delete itself).
5. **A new `AppState.shared` reference outside the GUI shell.** A helper, a default argument or a view added later, reached from a headless path or a test. Decision 14's trap turns that into a crash only when a test happens to reach it. A source scan catches it at test time whether or not anything reaches it.
   - Test: Task 8, `sharedAppearsOnlyInTheGUIShell`.

## Plan notes: where the spec and the code disagree (proposed rulings)

1. **`.legacy` needs the prior payload, and decision 5 forbids reading between `flock` and `pwrite`.** The claim reads the file through the same descriptor *before* `flock`. A pre-#463 process only ever replaces or removes the file by path, and the inode check after `flock` catches both, so the early read is sound. After `flock`, the only extra work is one `kill(pid, 0)` when that prior content is a bare pid.
2. **Where the 1 s re-read lives.** `claim()` itself never sleeps.
   - The CLI and the seeder call `StoreLock.claimSettling(…)`, which retries `.held(nil)` every 100 ms for up to 1 s. Blocking is fine there.
   - The app never blocks its main thread. `LaunchGate` counts how long the holder has been unknown across its 1 s polls, and `LaunchDecision.decide(_:unknownFor:)` refuses at 1 s. So the spec's `decide(_ claim:)` gains one argument.
3. **`PerfCLI`'s scratch lock needs a kind.** Decision 5's kinds are `app`, `run-job` and `seed-dev-home`, and decision 18 puts `PerfCLI` on the same primitive. The payload gains `perf`. No GUI reads that lock, and `LaunchDecision` treats `perf` like `app`.
4. **`PerfCLI` re-claims inside one process.** A held lock is never released (decision 2), and a second claim in one process conflicts with the first (spec §3). But `PerfCLITests.skillsListStableAcrossRunsAtFixedLocation` claims twice. `claimScratchWorkspace` therefore reuses this process's own hold (`StoreLock.holds`) rather than claiming again. `releaseScratchWorkspace` becomes a vacate.
5. **`URLDeferralTimer` is also the refusal-flush timer** (`AppState.swift:4231`, `RunJobURLHandling.swift:278`). Decision 12 deletes D2's deferral, but this type outlives it. It is renamed `URLTimer`, not deleted (Task 6).
6. **#489's test cannot go through a CLI turn.** Spec §3 asks for "a `--run-job` (fake client) whose turn calls `write_file` into a skill folder, then `create_skill`".
    - Both tools need an approval, and the CLI fails closed: `makeState` leaves `autoApproveTools` off (`RunJobCLI.swift:437-440`). So a CLI turn's call is blocked before it reaches the executor.
    - Task 8's exit test therefore sets `ProcessRole.runJob` and builds its engine exactly as `fire` does: `IrisEngine(state: makeState(store:), client:, protectionEnabled:)` (`RunJobCLI.swift:463`). That is a second engine over the state, not `state.engine`. It then drives that engine's own executor, the object a CLI turn dispatches through after an approval.
7. **The spec's perl stub needs `$|=1`.** Otherwise its `ok` sits in perl's buffer behind a pipe and the readiness wait times out (Task 1's `LockStub`).
8. **A job's `run_command` never runs on the host, so decision 17's registry does not reach it.** A read-only run's `run_command` is refused unless sandboxed (`Job.readOnlyDenies`, `Job.swift:63-68`). A mutating job's commands always run in the VM (`docs/jobs.md`, "A mutating job…"). In the VM they run through `CLIContainerRuntime.exec` and `CLIProcessRunner`, not `ProcessGroupRunner`. So in a `--run-job`, `LiveProcessGroups` holds hooks, `search_web` and plugin checks, and never a job's `sleep`.
   - The clean stop still ends a VM command: the cancelled turn fires `CLIProcessRunner`'s in-VM kill, and `closeSession` deletes the run's container.
   - The exit-now path deletes the container too, by name (plan note 15, the coordinator's ruling on #490).
   - GUI check 6 (Task 16) therefore asserts the container state, not `pgrep sleep`.
9. **`DeadlineFlag` goes from `Bool` to a three-way `Ending`** (`.turn`, `.deadline`, `.signal(String)`), since decision 16 adds a third claimant (Task 13).
10. **A stop during a built-in job does nothing until the second signal.** A built-in has no turn to cancel and runs in milliseconds. `RunStop` is armed, so the first signal answers `.runWillStop` and the built-in finishes normally.
11. **The waiting sentence drops the spec's backticks.** SwiftUI `Text` renders a `String` verbatim, so the backticks would show literally, and rendering it as Markdown would let a job name inject markup. The job is flattened to one line and capped at 80 characters.
12. **One GUI task per PR.** Spec §3's GUI checks 1-5 and 7 are one `work` pass for PR 1 (Task 10), and check 6 is PR 2's (Task 16). Each numbered check is a numbered step with its own expected output.


13. **The waiting notice does not activate Iris, and launch activation moves into the gate.** Decision 13 opens the notice "without activating the app". But SwiftUI's `OpenWindowAction` has no non-activating form, and `IrisApp.init` and `applicationDidFinishLaunching` both call `NSApp.activate` unconditionally (`iris.swift:5450`, `:5528`).
    - The notice is an AppKit `NSPanel` with `.nonactivatingPanel`, ordered front with `orderFrontRegardless()` (Task 7, `WaitingNoticePanel`).
    - `init` no longer activates. Did-finish activates through `Seams.activate` in every case but one: a link that launched Iris while it waits.
    - A Dock launch, a free-lock link launch (D2's) and the hotkey still activate, as before.
14. **A delegate's skill write must still reach the main chat (coordinator re-ruling on #490).**
    - Today a subagent's or evaluator's `create_skill` reaches the main engine through `.shared` (`SubagentManager.swift:152`, `GoalEvaluator.swift:77`), and the skill appears on the main chat's next turn.
    - The main engine caches its prompt (`ensureSystemPrompt` returns the cache, `iris.swift:533-535`), and the app has one main engine for its whole life (`AppState.swift:1192`). A new conversation, a switch and `/new` never rebuild that cache. So a hook that refreshed only the writing engine would keep a delegate's skill out of the main chat until a restart.
    - So the injected `onSkillsChanged` invalidates the writing engine **and** its owner's main engine (`state?.engine`, which is `AppState.engine`, never `.shared`). In the CLI that owner is the run's own `AppState`, so #489's fix still holds.
    - Task 2's `delegateWriteInvalidatesTheOwner` pins it, with a mutation check.
15. **A second Ctrl-C deletes the run's containers (coordinator ruling on #490).** This extends decision 16's exit-now, and plan note 8's gap closes with it.
    - The names come from a lock-protected `LiveContainerNames` box, not the registry actors, so the signal path reads them synchronously with no pool hop (#372). Each container is recorded where it is created: the session in `SandboxSessionManager.create`, gate containers in `GateContainerRegistry.register`, and the hook and `run_command` one-offs in `EphemeralContainerRegistry.register`.
    - It never sweeps by the `iris-` prefix, which `~/.iris` and `~/.iris-dev` share.
    - The deletes run in parallel through `BlockingSpawn` with `POSIX_SPAWN_SETPGROUP` (so the terminal's Ctrl-C does not hit them), bounded at 5 s in all.
    - SIGINT is reset to `SIG_DFL` first, so a third Ctrl-C kills the CLI at once.
    - The clean stop uses the same box. After its turn and its bounded teardown, it waits up to 3 s for the host groups to drain, SIGKILLs what is left, and deletes any container still recorded, before `_exit` (Tasks 12-14).
16. **An inherited ignore is kept** (`nohup`). If SIGHUP or SIGINT is already `SIG_IGN` when the CLI starts, it stays ignored, and no source is installed for it. SIGTERM is always caught.
---

## PR 1: the lock, the waiting launch, and #489

Branch: `git switch -c feat/463-single-writer origin/main` in a fresh worktree (AGENTS.md "Worktrees": switch off `index-build` with `.sourcekit-lsp/config.json`).

### Task 1: `StoreLock`, the lifetime `flock` and its payload

**Files:**
- Create: `Sources/IrisKit/StoreLock.swift`
- Modify: `Sources/IrisKit/IrisPaths.swift:144-148` (rename `guiLockFile` to `storeLockFile`, rewrite its comment)
- Modify: every `guiLockFile` reference: `RunJobCLI.swift:234`, `:244`, `:341`, `iris.swift:5499`, `DevHomeSeeder.swift:50`, `:101`, `Tests/irisTests/DevHomeSeederTests.swift:63`, `:74-75`, `:86`, `:89`
- Create: `Tests/irisTests/LockStub.swift`
- Create: `Tests/irisTests/StoreLockTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum StoreLock`
  - `StoreLock.Kind: String` with cases `app`, `runJob = "run-job"`, `seedDevHome = "seed-dev-home"`, `perf`
  - `struct StoreLock.Holder: Equatable, Sendable { let pid: Int32; let kind: Kind; let job: String? }`
  - `enum StoreLock.Claim: Equatable, Sendable { case acquired, held(Holder?), legacy(pid: Int32), failed(detail: String) }`
  - `struct StoreLock.Syscalls` (`flock`, `pwrite`, `afterOpen` seams) and `static let live`
  - `static func claim(at: URL, kind: Kind, job: String? = nil, syscalls: Syscalls = .live) -> Claim`
  - `static func claimSettling(at: URL, kind: Kind, job: String? = nil, settle: TimeInterval = 1, syscalls: Syscalls = .live) -> Claim`
  - `static func holds(_ url: URL) -> Bool`
  - `static func vacate(at url: URL)`
  - `static func readHolder(at url: URL) -> Holder?`
  - `static func isAlive(_ pid: Int32) -> Bool`
  - `static func descriptor(for url: URL) -> Int32?` (tests)
  - `enum StoreLock.Payload { static func encode(_:) -> Data; static func decode(_:) -> Holder?; static func legacyPid(_:) -> Int32? }`
  - `IrisPaths.storeLockFile: URL`
  - Test helpers in `LockStub.swift`: `LockStub` (`start(holding:payload:within:)`, `pid`, `kill()`, `static func tryLock(_:) -> Int32`) and `LockedCell<T>` (a locked cell, used by later tasks' tests)

- [ ] **Step 1: Rename the path.** In `IrisPaths.swift` replace lines 144-148 with:

```swift
    /// The lock that makes one process at a time the store's only writer (#463). Whoever holds
    /// its `flock` may open `conversations.sqlite`; nobody else may. Held for the holder's whole
    /// life and never unlinked, so the kernel releases it on any exit, SIGKILL included. Beside
    /// the database on purpose: it guards *that file*, and a volatile copy gets its own lock.
    var storeLockFile: URL { conversationsDB.appendingPathExtension("lock") }
```

Then `grep -rn guiLockFile Sources Tests` and rename every hit to `storeLockFile`. Expected afterwards: no output.

- [ ] **Step 2: Write the stub helper.** Create `Tests/irisTests/LockStub.swift`:

```swift
import Foundation
import Darwin

/// Another process holding `flock(LOCK_EX)` on a file: the stand-in for another Iris (spec §3).
/// perl because it is on every Mac and its `flock` is flock(2). `$|=1`, or "ok" waits in perl's
/// buffer behind the pipe and `start` times out (plan note 7).
final class LockStub {
    enum StubError: Error { case perlMissing, notReady }

    let process: Process
    var pid: Int32 { process.processIdentifier }

    private init(process: Process) { self.process = process }

    /// Returns once the stub holds the lock. `payload`, when given, is written into the locked
    /// file first, with every `%PID%` replaced by the stub's own pid; nil leaves the file empty.
    static func start(holding url: URL, payload: String? = nil, within seconds: Double = 10) throws -> LockStub {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { throw StubError.perlMissing }
        let script = #"""
        use Fcntl qw(:flock); use IO::Handle; $|=1;
        open(F, ">>", $ARGV[0]) or die "open: $!";
        flock(F, LOCK_EX) or die "flock: $!";
        if (defined $ARGV[1]) { my $p = $ARGV[1]; $p =~ s/%PID%/$$/g; truncate(F, 0); print F $p; F->flush(); }
        print "ok\n";
        sleep 60;
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, url.path] + (payload.map { [$0] } ?? [])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let ready = DispatchSemaphore(value: 0)
        let seen = LockedCell(Data())
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            seen.value.append(chunk)   // one handler call at a time
            if seen.value.range(of: Data("ok\n".utf8)) != nil { ready.signal() }
        }
        try process.run()
        guard ready.wait(timeout: .now() + seconds) == .success else {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw StubError.notReady
        }
        out.fileHandleForReading.readabilityHandler = nil
        return LockStub(process: process)
    }

    /// SIGKILL, the death no handler sees, and wait for it: the kernel has dropped the lock on return.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(pid, SIGKILL)
        process.waitUntilExit()
    }

    deinit { kill() }

    /// Asks a fresh process for `LOCK_EX | LOCK_NB` on `url`: 0 when it got the lock, 3 when the
    /// lock is held elsewhere, 2 when the file would not open. Never blocks.
    static func tryLock(_ url: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", #"use Fcntl qw(:flock); open(F, ">>", $ARGV[0]) or exit 2; flock(F, LOCK_EX | LOCK_NB) ? exit 0 : exit 3"#, url.path]
        do { try process.run() } catch { return 2 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// A mutable cell a `@Sendable` seam or handler can write and the test can read.
final class LockedCell<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
```

- [ ] **Step 3: Write the failing tests.** Create `Tests/irisTests/StoreLockTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decisions 1-5: one lifetime `flock` per home, the inode check, the payload written
/// inside the claim, and `.failed`/`.legacy`. Real `flock` on temp files; never a real home.
/// Every claim here is held for the rest of the test process (decision 2), so every test uses a
/// path of its own.
@Suite("StoreLock (#463)", .timeLimit(.minutes(1)))
final class StoreLockTests {
    /// Swift Testing makes one instance per test, so `deinit` removes that test's files (a
    /// crowded `TMPDIR` slows Foundation's listings to seconds, #309).
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-storelock-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    private func path(_ name: String = "store") -> URL {
        base.appendingPathComponent(UUID().uuidString).appendingPathComponent("\(name).sqlite.lock")
    }

    private var me: Int32 { ProcessInfo.processInfo.processIdentifier }

    @Test("a claim acquires, and writes its own payload before it returns")
    func payloadIsThereWhenClaimReturns() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .runJob, job: "pr sweep") == .acquired)
        let line = try Data(contentsOf: url)
        #expect(StoreLock.Payload.decode(line) == .init(pid: me, kind: .runJob, job: "pr sweep"))
        #expect(String(decoding: line, as: UTF8.self) == #"{"job":"pr sweep","kind":"run-job","pid":\#(me)}"# + "\n")
        #expect(StoreLock.holds(url))
    }

    @Test("Review Focus 1: a claim creates a home that does not exist yet")
    func claimCreatesTheMissingHome() throws {
        let url = path()
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
    }

    @Test("two claims in one process conflict, and the second names the first")
    func twoClaimsConflict() {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        #expect(StoreLock.claim(at: url, kind: .runJob) == .held(.init(pid: me, kind: .app, job: nil)))
    }

    @Test("a dropped claim still excludes, in this process and in another")
    func droppedClaimStillExcludes() {
        let url = path()
        _ = StoreLock.claim(at: url, kind: .runJob)
        #expect(StoreLock.claim(at: url, kind: .app) != .acquired)
        #expect(LockStub.tryLock(url) == 3, "another process cannot take it either")
    }

    @Test("the descriptor is close-on-exec from the open")
    func descriptorIsCloexec() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        let fd = try #require(StoreLock.descriptor(for: url))
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test("a stub holding the lock blocks a claim, and SIGKILLing it frees the lock")
    func stubBlocksThenFrees() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url, payload: #"{"job":"nap","kind":"run-job","pid":%PID%}"# + "\n")
        #expect(StoreLock.claim(at: url, kind: .app) == .held(.init(pid: stub.pid, kind: .runJob, job: "nap")))
        stub.kill()
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
        #expect(StoreLock.readHolder(at: url) == .init(pid: me, kind: .app, job: nil), "the stale payload was overwritten")
    }

    @Test("a holder with no payload yet is held by nobody named")
    func emptyPayloadIsUnknown() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url)
        defer { stub.kill() }
        #expect(StoreLock.claim(at: url, kind: .app) == .held(nil))
    }

    @Test("claimSettling waits up to its bound for a holder to say what it is")
    func settlingGivesUpAtTheBound() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url)
        defer { stub.kill() }
        let started = Date()
        #expect(StoreLock.claimSettling(at: url, kind: .runJob, settle: 0.3) == .held(nil))
        #expect(Date().timeIntervalSince(started) >= 0.3)
    }

    @Test("a path replaced between the open and the flock is detected, and the claim reopens")
    func replacedPathIsDetected() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let holder = LockedCell<LockStub?>(nil)
        var calls = StoreLock.Syscalls.live
        calls.afterOpen = { attempt in
            guard attempt == 0 else { return }
            // A pre-#463 app's atomic write: a new file renamed over the path, which a live
            // holder then locks. The claim's descriptor is on the old, unlinked inode.
            let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh")
            FileManager.default.createFile(atPath: fresh.path, contents: nil)
            _ = rename(fresh.path, url.path)
            holder.value = try? LockStub.start(holding: url, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        }
        let claim = StoreLock.claim(at: url, kind: .runJob, syscalls: calls)
        let stub = try #require(holder.value)
        defer { stub.kill() }
        #expect(claim == .held(.init(pid: stub.pid, kind: .app, job: nil)),
                "locking the unlinked inode is not holding the store")
    }

    @Test("a path that keeps being replaced fails after 3 tries")
    func endlessReplacementFails() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tries = LockedCell(0)
        var calls = StoreLock.Syscalls.live
        calls.afterOpen = { _ in
            tries.value += 1
            let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh-\(tries.value)")
            FileManager.default.createFile(atPath: fresh.path, contents: nil)
            _ = rename(fresh.path, url.path)
        }
        guard case .failed(let detail) = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(detail.contains(StoreLock.replacedDetail))
        #expect(tries.value == StoreLock.maxAttempts)
    }

    @Test("a flock that fails with anything but EWOULDBLOCK is .failed, naming the path and the errno")
    func flockErrorIsFailed() {
        let url = path()
        var calls = StoreLock.Syscalls.live
        calls.flock = { _, _ in errno = ENOTSUP; return -1 }
        guard case .failed(let detail) = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(detail.contains(url.lastPathComponent))
        #expect(detail.contains("errno \(ENOTSUP)"))
        #expect(!StoreLock.holds(url))
    }

    @Test("a failed payload write is .failed and closes the descriptor, so the lock is free again")
    func failedWriteReleases() {
        let url = path()
        var calls = StoreLock.Syscalls.live
        calls.pwrite = { _, _, _, _ in errno = ENOSPC; return -1 }
        guard case .failed = StoreLock.claim(at: url, kind: .app, syscalls: calls) else {
            Issue.record("expected .failed"); return
        }
        #expect(!StoreLock.holds(url))
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired, "a lock it never advertised was released")
    }

    @Test("a bare pid naming a live process is a pre-#463 holder, .legacy")
    func bareLivePidIsLegacy() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: url)   // launchd: alive, and not us
        #expect(StoreLock.claim(at: url, kind: .app) == .legacy(pid: 1))
        #expect(!StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 0, "the refused claim let go of the lock")
    }

    @Test("a bare pid naming nobody is stale, and the claim takes it")
    func bareDeadPidIsStale() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("999999\n".utf8).write(to: url)
        #expect(StoreLock.claim(at: url, kind: .app) == .acquired)
    }

    @Test("the payload round-trips, and anything partial or foreign reads as nil")
    func payloadCodec() {
        let holder = StoreLock.Holder(pid: 42, kind: .seedDevHome, job: nil)
        #expect(StoreLock.Payload.decode(StoreLock.Payload.encode(holder)) == holder)
        let withJob = StoreLock.Holder(pid: 7, kind: .runJob, job: "line\nbreak \"quoted\"")
        #expect(StoreLock.Payload.decode(StoreLock.Payload.encode(withJob)) == withJob)
        #expect(StoreLock.Payload.decode(Data(#"{"kind":"app","pid":42}"#.utf8)) == nil, "no newline: half-written")
        #expect(StoreLock.Payload.decode(Data()) == nil)
        #expect(StoreLock.Payload.decode(Data((#"{"kind":"toaster","pid":42}"# + "\n").utf8)) == nil)
        #expect(StoreLock.Payload.decode(Data("42\n".utf8)) == nil)
        #expect(StoreLock.Payload.legacyPid(Data("42\n".utf8)) == 42)
        #expect(StoreLock.Payload.legacyPid(StoreLock.Payload.encode(holder)) == nil)
    }

    @Test("vacate empties this process's payload and keeps the lock")
    func vacateEmptiesAndKeeps() throws {
        let url = path()
        #expect(StoreLock.claim(at: url, kind: .runJob) == .acquired)
        StoreLock.vacate(at: url)
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(StoreLock.holds(url))
        #expect(LockStub.tryLock(url) == 3)
    }

    @Test("Review Focus 2: vacate is a no-op for a path this process does not hold")
    func vacateIsANoOpForANonHolder() throws {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: url, payload: #"{"kind":"run-job","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        StoreLock.vacate(at: url)
        #expect(StoreLock.readHolder(at: url) == .init(pid: stub.pid, kind: .runJob, job: nil))
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh StoreLockTests`
Expected: the build fails with `cannot find 'StoreLock' in scope`.

- [ ] **Step 5: Write `StoreLock`.** Create `Sources/IrisKit/StoreLock.swift`:

```swift
import Darwin
import Foundation
import os

/// #463: one writer per home. Whoever holds this `flock` is the only process that may open the
/// home's `conversations.sqlite`: the app, one `--run-job`, the seeder, or (on its own scratch
/// path) `--perf`.
///
/// - `flock(2)`, never `fcntl`/`lockf`: a POSIX lock drops when *any* descriptor for the file
///   closes, including a read of the payload.
/// - The descriptor is opened `O_CLOEXEC`, so no child keeps the lock alive, and kept in a
///   process-lifetime table: never closed, never `dup`ed (a `dup` loses `FD_CLOEXEC`), never
///   wrapped in anything that closes on `deinit`. `claim` returns a value with no ownership, so a
///   dropped result releases nothing. The kernel releases it when the process dies, however.
/// - The file is never unlinked or renamed. Others may replace it (a pre-#463 app's atomic write,
///   an editor, the old docs' "delete the file"), so every successful `flock` checks it locked the
///   file that is at the path now.
/// - The payload only describes the holder. The lock decides who holds it.
enum StoreLock {
    enum Kind: String, Sendable {
        case app
        case runJob = "run-job"
        case seedDevHome = "seed-dev-home"
        /// `--perf`'s scratch workspace lock (plan note 3). No GUI ever reads it.
        case perf
    }

    struct Holder: Equatable, Sendable {
        let pid: Int32
        let kind: Kind
        /// The CLI argument as typed. Resolving a name needs the store, which needs the lock.
        let job: String?
    }

    enum Claim: Equatable, Sendable {
        case acquired
        /// Someone else holds it. nil while their payload is empty, unparsable or names a dead pid
        /// (a new holder between its `flock` and its `pwrite`): re-read, don't guess.
        case held(Holder?)
        /// A pre-#463 process: a bare pid naming a live process, in a file it never flocks.
        case legacy(pid: Int32)
        /// The lock could not be taken or advertised: refuse, never open unlocked (decision 4).
        case failed(detail: String)
    }

    /// The syscalls a test needs to fail, plus a hook between the open and the `flock`.
    struct Syscalls: Sendable {
        var flock: @Sendable (Int32, Int32) -> Int32 = { Darwin.flock($0, $1) }
        var pwrite: @Sendable (Int32, UnsafeRawPointer, Int, off_t) -> Int = { Darwin.pwrite($0, $1, $2, $3) }
        var afterOpen: @Sendable (_ attempt: Int) -> Void = { _ in }
        static let live = Syscalls()
    }

    static let maxAttempts = 3
    static let replacedDetail = "the lock file kept being replaced while it was claimed"

    /// Path to descriptor, for every lock this process holds. Written once per path, never removed.
    private static let descriptors = OSAllocatedUnfairLock<[String: Int32]>(initialState: [:])

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    static func claim(at url: URL, kind: Kind, job: String? = nil, syscalls: Syscalls = .live) -> Claim {
        let path = key(url)
        // Everything that can take time happens here, before the first `flock`: from the `flock`
        // to the `pwrite` only the inode check runs, so a holder is never unnamed for longer than
        // a few syscalls (decision 5).
        let line = Payload.encode(Holder(pid: getpid(), kind: kind, job: job))
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(detail: "could not create \(directory.path): \(error.localizedDescription)")
        }
        for attempt in 0..<maxAttempts {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return .failed(detail: errnoDetail("open", path, errno)) }
            syscalls.afterOpen(attempt)
            // Read before the `flock` (plan note 1): only a bare pid matters here, and a pre-#463
            // writer replaces the file by path, which the inode check below catches.
            let prior = readAll(fd)
            guard syscalls.flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(fd)
                if code == EWOULDBLOCK { return .held(readHolder(at: url)) }
                return .failed(detail: errnoDetail("flock", path, code))
            }
            guard isStillAtPath(fd, path) else {
                close(fd)
                continue
            }
            if let pid = Payload.legacyPid(prior), pid != getpid(), isAlive(pid) {
                close(fd)   // releases a lock this process never advertised
                return .legacy(pid: pid)
            }
            let written = line.withUnsafeBytes { syscalls.pwrite(fd, $0.baseAddress!, $0.count, 0) }
            guard written == line.count else {
                let code = errno
                close(fd)
                return .failed(detail: errnoDetail("write", path, code))
            }
            guard ftruncate(fd, off_t(line.count)) == 0 else {
                let code = errno
                close(fd)
                return .failed(detail: errnoDetail("truncate", path, code))
            }
            descriptors.withLock { $0[path] = fd }
            return .acquired
        }
        return .failed(detail: "\(replacedDetail): \(path)")
    }

    /// `claim`, retrying a held lock whose holder has not said what it is, for up to `settle`
    /// seconds (decision 5's re-read). For the CLI and the seeder, which may block; the app counts
    /// the same second across its polls instead (plan note 2).
    static func claimSettling(at url: URL, kind: Kind, job: String? = nil, settle: TimeInterval = 1,
                              syscalls: Syscalls = .live) -> Claim {
        let deadline = Date().addingTimeInterval(settle)
        while true {
            let result = claim(at: url, kind: kind, job: job, syscalls: syscalls)
            guard case .held(nil) = result, Date() < deadline else { return result }
            usleep(100_000)
        }
    }

    static func holds(_ url: URL) -> Bool {
        let path = key(url)
        return descriptors.withLock { $0[path] != nil }
    }

    /// Empties this process's payload on a clean exit. The lock stays held until the process
    /// ends. A no-op for a path this process does not hold: a refused or waiting process must
    /// never erase the holder's payload.
    static func vacate(at url: URL) {
        let path = key(url)
        guard let fd = descriptors.withLock({ $0[path] }) else { return }
        _ = ftruncate(fd, 0)
    }

    static func descriptor(for url: URL) -> Int32? {
        let path = key(url)
        return descriptors.withLock { $0[path] }
    }

    /// Who the payload names, if it names a live process. Its own descriptor, opened and closed
    /// here: harmless with `flock`, which no other descriptor's close can release.
    static func readHolder(at url: URL) -> Holder? {
        let fd = open(key(url), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let holder = Payload.decode(readAll(fd)), isAlive(holder.pid) else { return nil }
        return holder
    }

    /// Signal 0 asks the kernel without sending anything. `EPERM` is alive and somebody else's.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    enum Payload {
        static func encode(_ holder: Holder) -> Data {
            var object: [String: Any] = ["pid": Int(holder.pid), "kind": holder.kind.rawValue]
            if let job = holder.job { object["job"] = job }
            let json = (try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return json + Data("\n".utf8)
        }

        /// Up to the first newline only. A line with none was never finished.
        static func decode(_ data: Data) -> Holder? {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
                  let object = try? JSONSerialization.jsonObject(with: Data(data[data.startIndex..<newline])) as? [String: Any],
                  let pid = object["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
                  let raw = object["kind"] as? String, let kind = Kind(rawValue: raw) else { return nil }
            return Holder(pid: Int32(pid), kind: kind, job: object["job"] as? String)
        }

        /// The whole file as a bare positive pid: what pre-#463 binaries wrote.
        static func legacyPid(_ data: Data) -> Int32? {
            guard let text = String(data: data, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
            return pid
        }
    }

    private static func readAll(_ fd: Int32) -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, 0) }
        return count > 0 ? Data(buffer[..<count]) : Data()
    }

    private static func isStillAtPath(_ fd: Int32, _ path: String) -> Bool {
        var mine = stat()
        var there = stat()
        guard fstat(fd, &mine) == 0, Darwin.stat(path, &there) == 0 else { return false }
        return mine.st_dev == there.st_dev && mine.st_ino == there.st_ino
    }

    private static func errnoDetail(_ call: String, _ path: String, _ code: Int32) -> String {
        "\(call) \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh StoreLockTests`
Expected: PASS, `Test run with 17 tests in 1 suite passed`.

- [ ] **Step 7: Mutation-check each correctness rule.** Make each change alone, run the same filter, confirm the named test fails, then revert it.
  - Delete the `guard isStillAtPath(fd, path) else { … }` block. Expected: `replacedPathIsDetected` and `endlessReplacementFails` fail (the inode re-check).
  - Move the `pwrite`/`ftruncate` block below `return .acquired` (unreachable), so the claim no longer writes. Expected: `payloadIsThereWhenClaimReturns` and `stubBlocksThenFrees` fail (the payload is written inside `claim()`).
  - Change `guard written == line.count` to `guard true`. Expected: `failedWriteReleases` fails.
  - Change `if code == EWOULDBLOCK` to `if true`. Expected: `flockErrorIsFailed` fails (`.failed` refuses).
  - Delete the `.legacy` block. Expected: `bareLivePidIsLegacy` fails (`.legacy` refuses).
  - Replace the table insert with `let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); _ = handle`. Expected: `droppedClaimStillExcludes` fails.
  - Drop `O_CLOEXEC` from the `open`. Expected: `descriptorIsCloexec` fails.

- [ ] **Step 8: Build and check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0. (`GUILock` still exists and is still used. It is deleted in Task 7.)

- [ ] **Step 9: Commit.**

```bash
git add Sources/IrisKit/StoreLock.swift Sources/IrisKit/IrisPaths.swift Sources/IrisKit/RunJobCLI.swift \
  Sources/IrisKit/iris.swift Sources/IrisKit/DevHomeSeeder.swift Tests/irisTests/LockStub.swift Tests/irisTests/StoreLockTests.swift \
  Tests/irisTests/DevHomeSeederTests.swift
git commit -m "feat: StoreLock, a lifetime flock with its payload written inside the claim (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 2: #489, skill writes invalidate the engine that made them

**Files:**
- Modify: `Sources/IrisKit/ToolExecutor.swift:15-24` (add `onSkillsChanged`), `:690`, `:1145`, `:1202`, `:1219`
- Modify: `Sources/IrisKit/SkillCurator.swift:17-21`, `:72-74`
- Modify: `Sources/IrisKit/iris.swift:136-145` (`IrisEngine.executor`)
- Modify: `Sources/IrisKit/AppState.swift:1311-1315` (delete `invalidateEnginePrompt`), `:4070`, `:4086`
- Create: `Tests/irisTests/SkillInvalidationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ToolExecutor.onSkillsChanged: (@Sendable () async -> Void)?`
  - `SkillCurator.curateSkills(paths: IrisPaths = .default, onSkillsChanged: (@Sendable () async -> Void)? = nil) async -> CurationReport` (the public no-argument overload is removed: it would be ambiguous)
  - `IrisEngine.executor` sets `onSkillsChanged` to its own `invalidateSystemPrompt()`
  - `AppState.invalidateEnginePrompt()` no longer exists

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/SkillInvalidationTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// #489: a skill write tells the engine that made it, through `onSkillsChanged`, and never
/// `AppState.shared`. Inside `--run-job`, `.shared` built a second `AppState` over the store.
/// The no-`.shared` half is pinned in a process of its own by Task 8's exit test, where the trap
/// is armed.
@Suite("Skill writes invalidate their own engine (#489)", .timeLimit(.minutes(1)))
struct SkillInvalidationTests {
    private func tempHome() throws -> (IrisPaths, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-489-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return (paths, { try? FileManager.default.removeItem(at: root) })
    }

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test("create, update and delete each call onSkillsChanged once")
    func crudCallsTheHook() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let count = Count()
        var executor = ToolExecutor()
        executor.onSkillsChanged = { count.bump() }
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await executor.createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
        #expect(await executor.updateSkill(name: "probe", description: "e", body: nil, paths: paths).hasPrefix("Successfully"))
        #expect(await executor.deleteSkill(name: "probe", paths: paths).hasPrefix("Successfully"))
        #expect(count.value == 3)
    }

    @Test("write_file onto a skill's SKILL.md calls onSkillsChanged once, through execute")
    func writeFileOntoASkillCallsTheHook() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let count = Count()
        var executor = ToolExecutor()
        executor.irisPaths = paths   // the temp home, never the process's test home
        executor.onSkillsChanged = { count.bump() }
        let file = paths.skillsDir.appendingPathComponent("probe/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = String(repeating: "A procedure step. ", count: 4)
        let result = await executor.execute(name: "write_file", args: [
            "path": .string(file.path), "content": .string("---\nname: probe\ndescription: d\n---\n\(body)"),
        ])
        #expect(result.hasPrefix("Successfully wrote to"))
        #expect(count.value == 1)
        let elsewhere = paths.root.appendingPathComponent("notes.txt")
        _ = await executor.execute(name: "write_file", args: ["path": .string(elsewhere.path), "content": .string("x")])
        #expect(count.value == 1, "a file outside the skills tree is not a skill write")
    }

    @Test("an executor with no hook writes skills and invalidates nothing")
    func noHookIsANoOp() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await ToolExecutor().createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
    }

    @Test("the curator calls onSkillsChanged when it prunes, and not otherwise")
    func curatorCallsTheHookOnPrune() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let count = Count()
        _ = await SkillCurator.shared.curateSkills(paths: paths, onSkillsChanged: { count.bump() })
        #expect(count.value == 0, "nothing to prune")
        try FileManager.default.createDirectory(at: paths.skillsDir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        _ = await SkillCurator.shared.curateSkills(paths: paths, onSkillsChanged: { count.bump() })
        #expect(count.value == 1)
    }

    @MainActor
    @Test("plan note 14: a delegate engine's skill write invalidates the owner's main engine too")
    func delegateWriteInvalidatesTheOwner() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let main: IrisEngine = state.engine
        // A delegate over the same state, built the way `SubagentManager` builds one.
        let delegate = IrisEngine(state: state, client: FakeLLMClient(responses: []), protectionEnabled: false)
        await main.setSystemPrompt(text: "main, primed")
        await delegate.setSystemPrompt(text: "delegate, primed")
        let executor = await delegate.executor
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await executor.createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
        #expect(await delegate.systemPrompt == nil)
        #expect(await main.systemPrompt == nil, "the main chat sees the delegate's skill on its next turn, not after a restart")
    }

    @MainActor
    @Test("an engine's executor invalidates that engine's prompt")
    func engineExecutorInvalidatesItsOwnEngine() async throws {
        let (paths, cleanup) = try tempHome(); defer { cleanup() }
        let state = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let engine: IrisEngine = state.engine
        await engine.setSystemPrompt(text: "primed")
        let executor = await engine.executor
        let body = String(repeating: "A procedure step. ", count: 4)
        #expect(await executor.createSkill(name: "probe", description: "d", body: body, paths: paths).hasPrefix("Successfully"))
        #expect(await engine.systemPrompt == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh SkillInvalidationTests`
Expected: the build fails with `value of type 'ToolExecutor' has no member 'onSkillsChanged'`.

- [ ] **Step 3: Add the hook to `ToolExecutor`.** After `var jobToolsProvider` (`ToolExecutor.swift:24`), add:

```swift
    /// #489: how a skill write tells the engine it ran for, so that engine's cached system prompt
    /// (and only that engine's) is rebuilt. nil — `ToolExecutor.shared`, a plugin's throwaway
    /// executor, a test — invalidates nothing: no engine is behind it. Never `AppState.shared`,
    /// which inside `--run-job` built a second `AppState` over the store (#463 decision 15).
    var onSkillsChanged: (@Sendable () async -> Void)?
```

Replace each of the four `await AppState.shared.invalidateEnginePrompt()` lines (`:690`, `:1145`, `:1202`, `:1219`) with:

```swift
        await onSkillsChanged?()
```

- [ ] **Step 4: Route the curator.** In `SkillCurator.swift`, delete the public `curateSkills()` (`:17-19`) and change the internal one's signature (`:21`) and its `:72-74` block to:

```swift
    func curateSkills(paths: IrisPaths = .default,
                      onSkillsChanged: (@Sendable () async -> Void)? = nil) async -> CurationReport {
```

```swift
        if prunedNames.count > 0 {
            await onSkillsChanged?()
        }
```

- [ ] **Step 5: Give the engine's executor its own hook.** In `iris.swift`, replace `var executor` (`:141-145`) with:

```swift
    var executor: ToolExecutor {
        var executor = ToolExecutor.shared
        executor.jobToolsProvider = jobToolsProvider()
        // #489: a skill written through this engine's tools rebuilds this engine's prompt, and
        // the owner's main engine's too (plan note 14): a delegate's skill must reach the main
        // chat, whose engine caches its prompt for the life of the app. Never `AppState.shared`.
        executor.onSkillsChanged = { [weak self, weak state] in
            await self?.invalidateSystemPrompt()
            let owner = await MainActor.run { state?.engine }
            if let owner, owner !== self { await owner.invalidateSystemPrompt() }
        }
        return executor
    }
```

- [ ] **Step 6: Route `/skills`.** In `AppState.swift`, delete `invalidateEnginePrompt()` (`:1311-1315`). At `:4070`, replace the curate call with:

```swift
                let engine = self.engine
                let report = await SkillCurator.shared.curateSkills(onSkillsChanged: { await engine?.invalidateSystemPrompt() })
```

At `:4086`, replace `await ToolExecutor.shared.createSkill(` with `await self.engine.executor.createSkill(` (the arguments are unchanged).

- [ ] **Step 7: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh SkillInvalidationTests` then `timeout 300 scripts/test-filter.sh SkillCurationAdvancementsTests`
Expected: PASS, 6 tests, then the curation suite's count unchanged from `main` (its `curateSkills(paths:)` call compiles as it is, with no hook).

- [ ] **Step 8: Confirm nothing in the module names `invalidateEnginePrompt`.** Run `grep -rn "invalidateEnginePrompt\|AppState.shared.invalidate" Sources Tests`. Expected: no output.

- [ ] **Step 9: Mutation checks.** Put `await AppState.shared.invalidateEnginePrompt()` back in place of `await onSkillsChanged?()` in `createSkill` only, and restore `invalidateEnginePrompt` in `AppState`. Run `SkillInvalidationTests`. Expected: `crudCallsTheHook` fails (count 2). Revert. Do the same in `afterSkillFileWrite`. Expected: `writeFileOntoASkillCallsTheHook` fails. Revert. Then delete the `owner` lines from `IrisEngine.executor`'s hook. Expected: `delegateWriteInvalidatesTheOwner` fails. Revert. The no-`.shared` half is Task 8 Step 8.

- [ ] **Step 10: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 11: Commit.**

```bash
git add Sources/IrisKit/ToolExecutor.swift Sources/IrisKit/SkillCurator.swift Sources/IrisKit/iris.swift \
  Sources/IrisKit/AppState.swift Tests/irisTests/SkillInvalidationTests.swift
git commit -m "fix: skill writes invalidate the engine that made them, never AppState.shared (#489)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 3: the CLI claims through `StoreLock`, and opens the store only after

**Files:**
- Modify: `Sources/IrisKit/RunJobCLI.swift:328-386` (the `run` doc comment, the claim, the refusals, the `defer`)
- Modify: `Sources/IrisKit/IrisMain.swift:24-41` (the comment at `:25-29`, and a vacate just before `_exit` at `:41`)
- Modify: `Tests/irisTests/RunJobCLITests.swift`: delete the 14 `GUILock` cases (`:150-458` and `:491-499`), rewrite `:501-522`, add 5, and make the suite a `final class` that removes its lock files

**Interfaces:**
- Consumes: Task 1's `StoreLock.claimSettling`, `.vacate(at:)`, `.readHolder(at:)`, `.holds`, `Claim`, `Holder`, `Syscalls`, and the test helpers `LockStub` and `LockedCell`.
- Produces:
  - `RunJobCLI.run(_:store:client:runner:lockPath:lockSyscalls:protectionEnabled:gate:out:err:)`, where `lockPath` defaults to `IrisPaths.default.storeLockFile` and `lockSyscalls: StoreLock.Syscalls = .live` is new
  - `RunJobCLI.refusal(for: StoreLock.Claim, path: URL) -> String?` (nil for `.acquired`)

- [ ] **Step 1: Write the failing tests.** In `RunJobCLITests.swift`, delete every test from `// MARK: The GUI lock (ruling R35, spec §8)` through `acquireAndRelease` (`:150-458`, 13 tests), `anUnreadableLockFileIsHeld` (`:491-499`), and the `StartLine`, `Claims`, `race` and `lockPathInOwnDirectory` helpers. Keep `theCLIStateFailsClosedAndLeavesNothingBehind` and the test after it (`:460-489`). Add `import GRDB` at the top, then add:

```swift
    // MARK: The store lock (#463 decision 7)

    @Test("a stub --run-job holding the lock: exit 1 naming it, and the store is never opened")
    func refusedRunNeverOpensTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-runjob-\(UUID().uuidString)")
        let db = dir.appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try ConversationStore.onDisk(at: db)   // a real, migrated store, closed again
        // The count first: closing a reader can checkpoint the WAL into the file, so the mtime is
        // taken after it, and compared before the second read.
        let migrations = try DatabaseQueue(path: db.path).read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") }
        let mtime = try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date
        let lock = db.appendingPathExtension("lock")
        let stub = try LockStub.start(holding: lock, payload: #"{"job":"nightly","kind":"run-job","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        let opened = LockedCell(0)
        func openStore() throws -> ConversationStore {
            opened.value += 1
            return try ConversationStore.onDisk(at: db)
        }

        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try openStore(),
                                       client: FakeLLMClient(responses: []), lockPath: lock,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })

        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("another --run-job (pid \(stub.pid), job nightly)"))
        #expect(opened.value == 0, "the store factory never ran")
        #expect(try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date == mtime)
        #expect(try DatabaseQueue(path: db.path).read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") } == migrations)
    }

    @Test("the app holding the lock is named as the app")
    func appHolderIsNamed() async throws {
        let lock = lockPath()
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: lock, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try ConversationStore.inMemory(),
                                       client: FakeLLMClient(responses: []), lockPath: lock,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("the Iris app (pid \(stub.pid))"))
    }

    @Test("--dry-run claims too")
    func dryRunClaims() async throws {
        let lock = lockPath()
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: lock, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        // A job that exists and has a gate, so the only thing that can refuse is the lock.
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(self.job(name: "polled",
                                         trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                                                 gate: .pathChanged(path: "/tmp/whatever")))))
        let opened = LockedCell(0)
        func openStore() throws -> ConversationStore { opened.value += 1; return store }
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "polled", dryRun: true),
                                       store: try openStore(), client: FakeLLMClient(responses: []),
                                       lockPath: lock, protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("the Iris app (pid \(stub.pid))"))
        #expect(opened.value == 0)
    }

    @Test("a lock that cannot be taken is exit 1 naming the path and errno, and the store is never opened")
    func failedLockRefuses() async throws {
        let lock = lockPath()
        var calls = StoreLock.Syscalls.live
        calls.flock = { _, _ in errno = ENOLCK; return -1 }
        let opened = LockedCell(0)
        func openStore() throws -> ConversationStore { opened.value += 1; return try ConversationStore.inMemory() }
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try openStore(),
                                       client: FakeLLMClient(responses: []), lockPath: lock, lockSyscalls: calls,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains(lock.path))
        #expect(err.text.contains("errno \(ENOLCK)"))
        #expect(opened.value == 0)
    }

    @Test("a pre-#463 holder (a bare live pid) refuses")
    func legacyHolderRefuses() async throws {
        let lock = lockPath()
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: lock)
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try ConversationStore.inMemory(),
                                       client: FakeLLMClient(responses: []), lockPath: lock,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("an older Iris build (pid 1)"))
    }
```

Replace `aRunHoldsTheLockWhileItRuns` (`:501-522`) with:

```swift
    @Test("a run holds the lock while it runs, with its own payload, and keeps both until IrisMain exits")
    func aRunHoldsTheLockWhileItRuns() async throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(self.job(name: "holder"))
        let path = lockPath()
        let seen = LockedCell<StoreLock.Holder?>(nil)
        let client = ProbingLLMClient(reply: "done") { seen.value = StoreLock.readHolder(at: path) }
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "holder"), store: store,
                                       client: client, lockPath: path, protectionEnabled: false,
                                       out: { _ in }, err: { _ in })
        #expect(code == RunJobCLI.Exit.completed)
        #expect(seen.value == .init(pid: ProcessInfo.processInfo.processIdentifier, kind: .runJob, job: "holder"))
        #expect(StoreLock.readHolder(at: path) == seen.value,
                "not vacated in `run`: IrisMain vacates just before `_exit`, so no empty payload sits under a held lock")
        #expect(StoreLock.holds(path), "and still held: the process exits next (decision 2)")
    }
```

Lock files now outlive a run (decision 2), so the suite cleans up after itself: a crowded `TMPDIR` slows Foundation's listings to seconds (#309). Change `struct RunJobCLITests` (`:15`) to `final class RunJobCLITests`, and replace `lockPath()` (`:76-79`) with:

```swift
    /// Every lock path this instance hands out lives under `base`, which `deinit` removes. The
    /// held descriptors stay open on the unlinked files, which is harmless.
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-runjob-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    private func lockPath() -> URL {
        base.appendingPathComponent(UUID().uuidString).appendingPathComponent("conversations.sqlite.lock")
    }
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh RunJobCLITests`
Expected: the build fails with `extra argument 'lockSyscalls' in call`.

- [ ] **Step 3: Claim through `StoreLock`.** In `RunJobCLI.run`, change the signature's `lockPath:` line (`:341`) to:

```swift
                    lockPath: URL = IrisPaths.default.storeLockFile,
                    lockSyscalls: StoreLock.Syscalls = .live,
```

Replace the doc paragraph at `:331-335` with:

```swift
    /// `store` is an autoclosure because the order matters: usage and the lock are decided
    /// *before* anything opens a database file, so a run refused behind a live holder never
    /// migrates, repairs or reads the store (#463 decision 7; pinned by
    /// `refusedRunNeverOpensTheStore`). The lock is held for the rest of the process. `runner` is
    /// nil in production — the CLI builds the same `AppState`, engine and `JobRunner` the app
    /// fires through.
```

Replace `:355-385` (the comment block, the `switch GUILock.acquireExclusively` at `:366`, and `defer { GUILock.release(at: lockPath) }` at `:385`) with:

```swift
        // Taken for a `--dry-run` too, which writes no row: opening the store may migrate it.
        // One `flock`, held until this process exits, so two `--run-job` started together cannot
        // both pass, and an app launched during the run waits behind it (#463).
        let claim = StoreLock.claimSettling(at: lockPath, kind: .runJob, job: target, syscalls: lockSyscalls)
        if let refusal = refusal(for: claim, path: lockPath) { return refuse(refusal) }
        // Not vacated here: `IrisMain` empties the payload just before `_exit`, so an empty
        // payload never sits under the held lock while this process still runs (decision 5).
```

Add below `run`:

```swift
    /// What a claim that did not acquire says, or nil when it did (decision 7).
    static func refusal(for claim: StoreLock.Claim, path: URL) -> String? {
        let wait = "the CLI will not write to the store behind a live one. Try again when it has finished."
        switch claim {
        case .acquired:
            return nil
        case .held(let holder?):
            switch holder.kind {
            case .app:
                return "the Iris app (pid \(holder.pid)) has this home open; quit it and try again — the CLI will not write behind a live app."
            case .runJob:
                let job = holder.job.map { ", job \($0)" } ?? ""
                return "another --run-job (pid \(holder.pid)\(job)) has this home; \(wait)"
            case .seedDevHome:
                return "an iris --seed-dev-home (pid \(holder.pid)) is copying this home; \(wait)"
            case .perf:
                return "an iris --perf (pid \(holder.pid)) holds \(path.path); \(wait)"
            }
        case .held(nil):
            return "another Iris process holds \(path.path) and has not said which; \(wait)"
        case .legacy(let pid):
            return "an older Iris build (pid \(pid)) holds the store; quit it and try again."
        case .failed(let detail):
            return "could not lock the store (\(detail)); the CLI will not open it without the lock."
        }
    }
```

In `IrisMain.swift`, replace the comment at `:25-29` with:

```swift
            // The real store and the real model client (#187 §8): a `--run-job` measurement is only
            // worth anything if it is the run the scheduler would have done. No volatile defaults and
            // no `HeadlessMode`: approvals fail closed exactly as unattended. `store:` is an
            // autoclosure that `run` calls only once it holds the store lock (#463), so a refused
            // run never opens, migrates or repairs it.
```

and the end of the `_exit` comment (`:37-38`) with `// Nothing is lost by skipping the atexit handlers: the run's save was flushed inside \`run\`, and the two streams are flushed here.` Then add `StoreLock.vacate(at: IrisPaths.default.storeLockFile)` between `fflush(stderr)` and `_exit(code)`, with the comment `// Last: an empty payload under a held lock reads as an unnamed holder (decision 5).`

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh RunJobCLITests`
Expected: PASS, `Test run with 27 tests in 1 suite passed` (`main`'s 36, minus the 14 deleted, plus the 5 added).

- [ ] **Step 5: Mutation check (open only after the lock).** Move `let store: ConversationStore; do { store = try openStore() } catch { … }` above the `claimSettling` line. Run `RunJobCLITests`. Expected: `refusedRunNeverOpensTheStore` and `failedLockRefuses` fail on `opened.value == 0`. Revert.

- [ ] **Step 6: Mutation check (`.failed` and `.legacy` refuse in the CLI).** Make `refusal(for:)` return nil for `.failed`. Expected: `failedLockRefuses` fails. Revert. Do the same for `.legacy`. Expected: `legacyHolderRefuses` fails. Revert.

- [ ] **Step 7: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 8: Commit.**

```bash
git add Sources/IrisKit/RunJobCLI.swift Sources/IrisKit/IrisMain.swift Tests/irisTests/RunJobCLITests.swift
git commit -m "feat: --run-job claims the store lock and names its holder (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 4: the seeder and `PerfCLI` claim through `StoreLock`

**Files:**
- Modify: `Sources/IrisKit/DevHomeSeeder.swift:9-31` (`Failure`), `:47-54` (the check), `:139-159` (`runCLI` vacates)
- Modify: `Sources/IrisKit/PerfCLI.swift:94-136`, `:205-209` (a comment)
- Modify: `Tests/irisTests/DevHomeSeederTests.swift:59-81`
- Modify: `Tests/irisTests/PerfCLITests.swift:217-241`

**Interfaces:**
- Consumes: Task 1's `StoreLock` and the test helper `LockStub`.
- Produces:
  - `DevHomeSeeder.seed(from:to:identity:sourceKeychain:destKeychain:whileHeld:)`, where `whileHeld: (() -> Void)? = nil` is a test seam
  - `DevHomeSeeder.Failure.sourceInUse(pid: Int32?)` (an optional pid now) and `.sourceLockFailed(String)`. `.sourceLockUnreadable` is gone.
  - `PerfCLI.claimScratchWorkspace(base:)`, which reuses this process's own hold (plan note 4)
  - `PerfCLI.releaseScratchWorkspace(base:)`, which vacates

- [ ] **Step 1: Write the failing tests.** In `DevHomeSeederTests.swift`, replace `refusesWhileHeld` and `refusesWhenLockUnreadable` (`:59-81`) with:

```swift
    @Test("refuses while another process holds the source store, naming it")
    func refusesWhileHeld() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let stub = try LockStub.start(holding: src.storeLockFile, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        #expect(throws: DevHomeSeeder.Failure.sourceInUse(pid: stub.pid)) {
            try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
        #expect(!FileManager.default.fileExists(atPath: dst.root.path))
    }

    @Test("refuses a pre-#463 holder (a bare live pid)")
    func refusesLegacyHolder() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        try Data("1\n".utf8).write(to: src.storeLockFile)
        #expect(throws: DevHomeSeeder.Failure.sourceInUse(pid: 1)) {
            try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"))
        }
    }

    @Test("holds the source lock as seed-dev-home while it copies, and vacates it after")
    func holdsTheSourceWhileSeeding() throws {
        let (src, dst, cleanup) = try tempHomes(); defer { cleanup() }
        let during = LockedCell<StoreLock.Holder?>(nil)
        _ = try DevHomeSeeder.seed(from: src, to: dst, identity: .dev,
                                   sourceKeychain: .init(serviceSuffix: ""), destKeychain: .init(serviceSuffix: ".dev"),
                                   whileHeld: { during.value = StoreLock.readHolder(at: src.storeLockFile) })
        #expect(during.value == .init(pid: ProcessInfo.processInfo.processIdentifier, kind: .seedDevHome, job: nil),
                "an app launched mid-seed reads seed-dev-home, and waits")
        #expect(StoreLock.holds(src.storeLockFile))
        #expect(try Data(contentsOf: src.storeLockFile).isEmpty)
    }
```

`lockFileNotCopied` stays as it is (`999999` is a dead bare pid, which the claim takes).

In `PerfCLITests.swift`, replace `secondClaimWhileHeldIsRefused` and `releaseAllowsReclaim` (`:217-241`) with:

```swift
    @Test("a claim while another process holds the lock is refused, not raced (#321)")
    func secondClaimWhileHeldIsRefused() throws {
        let base = testBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let lockURL = PerfCLI.scratchLockURL(base: base)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: lockURL, payload: #"{"kind":"perf","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        #expect(throws: PerfCLIError.self) { try PerfCLI.claimScratchWorkspace(base: base) }
    }

    @Test("a second claim in the same process reuses its hold and resets the directory (plan note 4)")
    func sameProcessReclaims() throws {
        let base = testBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try PerfCLI.claimScratchWorkspace(base: base)
        try Data("stale".utf8).write(to: first.appendingPathComponent("stale.txt"))
        PerfCLI.releaseScratchWorkspace(base: base)
        let again = try PerfCLI.claimScratchWorkspace(base: base)
        #expect(again == PerfCLI.scratchWorkspaceURL(base: base))
        #expect(try FileManager.default.contentsOfDirectory(atPath: again.path).isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh DevHomeSeederTests`
Expected: it builds (an `Int32` converts to `Int32?`, and `whileHeld:` is not there yet, so first add the parameter from Step 3 as a no-op to get a build), then fails at runtime:
- `refusesWhileHeld` fails: `GUILock` reads the stub's JSON payload as unreadable and throws `sourceLockUnreadable`.
- `holdsTheSourceWhileSeeding` fails: nothing claims the lock.

`refusesLegacyHolder` already passes on `main`, since a bare live pid is `GUILock`'s `.held`. It is kept as a regression pin.

- [ ] **Step 3: Move the seeder.** In `DevHomeSeeder.swift`:
  - Replace `case sourceInUse(pid: Int32)` and `case sourceLockUnreadable(String)` (`:13-14`) with `case sourceInUse(pid: Int32?)` and `case sourceLockFailed(String)`.
  - Replace the two `description` lines (`:26-27`) with:

```swift
            case .sourceInUse(let pid?): "refusing: Iris (pid \(pid)) has the source store open; quit it and retry"
            case .sourceInUse(nil): "refusing: another Iris process has the source store open; quit it and retry"
            case .sourceLockFailed(let detail): "refusing: could not lock the source store (\(detail))"
```

  - Replace `:47-54` with:

```swift
        // Held as `seed-dev-home` for the rest of this process (#463 decision 18), so an app
        // launched mid-seed waits rather than opening the store under the copy.
        switch StoreLock.claimSettling(at: source.storeLockFile, kind: .seedDevHome) {
        case .acquired: break
        case .held(let holder): throw Failure.sourceInUse(pid: holder?.pid)
        case .legacy(let pid): throw Failure.sourceInUse(pid: pid)
        case .failed(let detail): throw Failure.sourceLockFailed(detail)
        }
        defer { StoreLock.vacate(at: source.storeLockFile) }
        whileHeld?()
```

Add `whileHeld: (() -> Void)? = nil` as `seed`'s last parameter: a test seam, called once the claim is held, so a test can read the payload mid-seed.

- [ ] **Step 4: Move `PerfCLI`.** Replace `claimScratchWorkspace`'s doc paragraph at `:111-113` and its `switch GUILock.acquireExclusively` (`:117-127`) with:

```swift
    /// The lock is `StoreLock`'s, as kind `perf`: a live holder is refused rather than raced, and
    /// a crashed one's lock is gone with it. It is held for this process's life (#463 decision 2),
    /// so a second claim here reuses that hold (plan note 4) instead of conflicting with it.
```

```swift
        if !StoreLock.holds(lockURL) {
            switch StoreLock.claimSettling(at: lockURL, kind: .perf) {
            case .acquired:
                break
            case .held(let holder):
                let who = holder.map { "pid \($0.pid)" } ?? "an unnamed process"
                throw PerfCLIError.usage(
                    "perf: another run (\(who)) already holds the scratch workspace at \(url.path) — wait for it to finish, or stop it")
            case .legacy(let pid):
                throw PerfCLIError.usage("perf: an older Iris build (pid \(pid)) holds \(lockURL.path) — wait for it, or stop it")
            case .failed(let detail):
                throw PerfCLIError.usage("perf: could not claim the scratch workspace lock at \(lockURL.path): \(detail)")
            }
        }
```

Replace `releaseScratchWorkspace` (`:132-136`) with:

```swift
    /// Empties the scratch lock's payload. The lock itself stays held until the process exits.
    static func releaseScratchWorkspace(base: URL = FileManager.default.temporaryDirectory) {
        StoreLock.vacate(at: scratchLockURL(base: base))
    }
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh DevHomeSeederTests` then `timeout 300 scripts/test-filter.sh PerfCLITests`
Expected: PASS. The seeder's count is `main`'s plus 1, and perf's is unchanged.

- [ ] **Step 6: Confirm `GUILock`'s last users are the app's.** Run `grep -rn "GUILock" Sources Tests`. Expected: only these, all deleted by Tasks 6-7:
  - `RunJobCLI.swift` (the enum itself)
  - `iris.swift` (`acquire`, `release`)
  - `LaunchLock.swift`
  - `AppState.swift:4245`
  - `LaunchLockTests.swift:53`, `:58`
  - `RunJobURLDeferralTests.swift:284-292`

  Also `PerfCLITests.swift:223`'s comment, which you now rewrite to `// a stub process holds the lock (LockStub)`.

- [ ] **Step 6b: Fix the comment this falsifies.** `PerfCLI.swift:205-209` says the next claim "reclaims a dead pid's lock". Replace those five lines with:

```swift
                // If anything between this claim and `scratch = dir` throws, the defer below
                // never sees `scratch`: the half-built directory is left for the next run's
                // claim to reset. The lock goes with this process when it exits (main.swift); a
                // long-lived host calling `execute` repeatedly reuses its own hold (plan note 4).
```

- [ ] **Step 7: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 8: Commit.**

```bash
git add Sources/IrisKit/DevHomeSeeder.swift Sources/IrisKit/PerfCLI.swift Tests/irisTests/DevHomeSeederTests.swift Tests/irisTests/PerfCLITests.swift
git commit -m "feat: the seeder and --perf claim through StoreLock (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 5: `LaunchDecision`, `LaunchGate` and `WaitingView`

**Files:**
- Create: `Sources/IrisKit/LaunchGate.swift`
- Create: `Sources/IrisKit/WaitingView.swift`
- Modify: `Tests/irisTests/RunJobURLEventsTests.swift:52-53` (add `LaunchGate.swift` to the no-logging list)
- Create: `Tests/irisTests/LaunchGateTests.swift`

**Interfaces:**
- Consumes: Task 1's `StoreLock.Claim`, `Holder`. `RunJobURLIntake.capacity` (`RunJobURLIntake.swift:17`).
- Produces:
  - `enum LaunchDecision: Equatable { case open, wait(StoreLock.Holder?), refuse(LaunchRefusal) }`, with `static let unknownGrace: TimeInterval = 1` and `static func decide(_ claim: StoreLock.Claim, unknownFor: TimeInterval) -> LaunchDecision`
  - `enum LaunchRefusal: Equatable { case otherApp(pid: Int32?), legacy(pid: Int32), failed(detail: String) }`, with `title`, `message(hadLinks:)`, `holderPid`
  - `@MainActor @Observable final class LaunchGate`, with:
    - `State` (`.waiting(Holder?)`, `.open`, `.refused(LaunchRefusal)`), `state`, `isOpen`, `sentence`, `heldLinkCount`
    - `Seams` (`claim`, `openStore`, `finishLaunch`, `deliver`, `refuse`, `startPolling(interval, tick)`, `stopPolling`, `showWaitingNotice`, `hideWaitingNotice`, `activate`, `now`)
    - `init(seams:)`, `begin()`, `poll()`, `didFinishLaunching()`, `receive(_:)`, `willTerminate(flush:)`, `showNoticeNow()`
    - `static let knownPollInterval: TimeInterval = 1`, `static let unknownPollInterval: TimeInterval = 0.2`, `static func waitingSentence(_:) -> String`
  - Views: `WaitingView(gate:)`, `WaitingMenu(gate:)`, `GatedStatusMenu(gate:)`, `GatedContent(gate:content:)`, `GatedStatusLabel(gate:)`

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/LaunchGateTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// #463 decisions 6-13: the app's launch decision and the gate that waits. Everything the gate
/// does to the world goes through `Seams`, so nothing here opens a store, a window or a timer.
@MainActor
@Suite("LaunchGate (#463)", .timeLimit(.minutes(1)))
struct LaunchGateTests {
    private static let cli = StoreLock.Holder(pid: 4242, kind: .runJob, job: "nightly")
    private static let seeder = StoreLock.Holder(pid: 4343, kind: .seedDevHome, job: nil)
    private static let app = StoreLock.Holder(pid: 4444, kind: .app, job: nil)

    // MARK: The decision

    @Test("the table of holders: a CLI or the seeder waits; an app, a legacy holder or a failure refuses")
    func decisionTable() {
        #expect(LaunchDecision.decide(.acquired, unknownFor: 0) == .open)
        #expect(LaunchDecision.decide(.held(Self.cli), unknownFor: 0) == .wait(Self.cli))
        #expect(LaunchDecision.decide(.held(Self.seeder), unknownFor: 0) == .wait(Self.seeder))
        #expect(LaunchDecision.decide(.held(Self.app), unknownFor: 0) == .refuse(.otherApp(pid: 4444)))
        #expect(LaunchDecision.decide(.held(.init(pid: 9, kind: .perf, job: nil)), unknownFor: 0) == .refuse(.otherApp(pid: 9)))
        #expect(LaunchDecision.decide(.legacy(pid: 77), unknownFor: 0) == .refuse(.legacy(pid: 77)))
        #expect(LaunchDecision.decide(.failed(detail: "flock: ENOTSUP"), unknownFor: 0) == .refuse(.failed(detail: "flock: ENOTSUP")))
    }

    @Test("an unnamed holder is waited on for under a second, then treated as a GUI")
    func unknownHolderBecomesAGUI() {
        #expect(LaunchDecision.decide(.held(nil), unknownFor: 0.99) == .wait(nil))
        #expect(LaunchDecision.decide(.held(nil), unknownFor: 1) == .refuse(.otherApp(pid: nil)))
    }

    @Test("the refusal's words: the title, and the link note only when a link came with the launch")
    func refusalWords() {
        let refusal = LaunchRefusal.otherApp(pid: 12)
        #expect(refusal.title == "Iris is already running on this home")
        #expect(!refusal.message(hadLinks: false).contains(LaunchRefusal.linkNotRun))
        #expect(refusal.message(hadLinks: true).contains("The link you opened was not run."))
        #expect(LaunchRefusal.legacy(pid: 3).title == "Iris is already running on this home")
        #expect(LaunchRefusal.failed(detail: "flock /x: Operation not supported (errno 45)").message(hadLinks: false)
            .contains("errno 45"))
    }

    @Test("the waiting sentence names the run, flattened and capped")
    func waitingSentence() {
        #expect(LaunchGate.waitingSentence(Self.cli)
            == "An iris --run-job is using this home (pid 4242, job nightly). Iris will open when it finishes.")
        let long = StoreLock.Holder(pid: 1, kind: .runJob, job: "a\nb" + String(repeating: "x", count: 200))
        let sentence = LaunchGate.waitingSentence(long)
        #expect(!sentence.contains("\n"))
        #expect(sentence.count < 200)
    }

    // MARK: The gate

    @MainActor
    final class Harness {
        var claims: [StoreLock.Claim]
        var opened = 0
        var finishes: [[URL?]] = []
        var droppedReported: [Int] = []
        var delivered: [URL?] = []
        var refusals: [(LaunchRefusal, Bool)] = []
        var tick: (@MainActor () -> Void)?
        var intervals: [TimeInterval] = []
        var stops = 0
        var notices = 0
        var hides = 0
        var activations = 0
        var clock = Date(timeIntervalSince1970: 1_000)

        init(_ claims: [StoreLock.Claim]) { self.claims = claims }

        lazy var gate = LaunchGate(seams: .init(
            claim: { [unowned self] in self.claims.count > 1 ? self.claims.removeFirst() : self.claims[0] },
            openStore: { [unowned self] in self.opened += 1 },
            finishLaunch: { [unowned self] links, dropped in self.finishes.append(links); self.droppedReported.append(dropped) },
            deliver: { [unowned self] in self.delivered.append($0) },
            refuse: { [unowned self] refusal, hadLinks in self.refusals.append((refusal, hadLinks)) },
            startPolling: { [unowned self] interval, tick in self.intervals.append(interval); self.tick = tick },
            stopPolling: { [unowned self] in self.stops += 1; self.tick = nil },
            showWaitingNotice: { [unowned self] in self.notices += 1 },
            hideWaitingNotice: { [unowned self] in self.hides += 1 },
            activate: { [unowned self] in self.activations += 1 },
            now: { [unowned self] in self.clock }))

        func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds); tick?() }
    }

    @Test("a free lock opens the store at begin and finishes at did-finish, as today")
    func freeLockKeepsTodaysOrder() {
        let h = Harness([.acquired])
        h.gate.begin()
        #expect(h.opened == 1)
        #expect(h.gate.isOpen)
        #expect(h.finishes.isEmpty, "startOnce waits for did-finish")
        #expect(h.tick == nil, "no poll")
        h.gate.didFinishLaunching()
        #expect(h.finishes.count == 1)
        #expect(h.activations == 1, "did-finish activates, as today")
    }

    @Test("while a CLI holds the store, openStore is never called; when it lets go, the launch completes")
    func waitsThenOpens() {
        let h = Harness([.held(Self.cli), .held(Self.cli), .acquired])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.gate.state == .waiting(Self.cli))
        #expect(h.opened == 0)
        h.advance(1)
        #expect(h.opened == 0)
        h.advance(1)
        #expect(h.opened == 1)
        #expect(h.gate.isOpen)
        #expect(h.stops == 1)
        #expect(h.finishes.count == 1)
    }

    @Test("finishLaunch runs exactly once, after both the store and did-finish, in either order")
    func finishOnceEitherOrder() {
        let early = Harness([.held(Self.cli), .acquired])
        early.gate.begin()
        early.gate.didFinishLaunching()
        early.advance(1)
        early.gate.didFinishLaunching()
        #expect(early.finishes.count == 1)

        let late = Harness([.acquired])
        late.gate.begin()
        late.gate.didFinishLaunching()
        late.gate.poll()
        #expect(late.finishes.count == 1)
    }

    @Test("links that arrive while waiting are held in order up to capacity, counted past it, and handed over at finish")
    func linksAreHeldThenDrained() throws {
        let h = Harness([.held(Self.cli), .acquired])
        h.gate.begin()
        let urls = (0..<(RunJobURLIntake.capacity + 3)).map { URL(string: "iris-dev://run-job/t\($0)") }
        for url in urls { h.gate.receive(url) }
        #expect(h.gate.heldLinkCount == RunJobURLIntake.capacity)
        #expect(h.delivered.isEmpty, "nothing reaches AppState while waiting")
        h.gate.didFinishLaunching()
        h.advance(1)
        #expect(h.finishes == [Array(urls.prefix(RunJobURLIntake.capacity))])
        #expect(h.droppedReported == [3])
        h.gate.receive(URL(string: "iris-dev://run-job/after"))
        #expect(h.delivered == [URL(string: "iris-dev://run-job/after")], "after launch a link goes straight through")
    }

    @Test("with the store open before did-finish, links go to AppState's own intake at once")
    func openGateDeliversDirectly() {
        let h = Harness([.acquired])
        h.gate.begin()
        h.gate.receive(URL(string: "iris-dev://run-job/x"))
        #expect(h.delivered.count == 1)
        h.gate.didFinishLaunching()
        #expect(h.finishes == [[]])
    }

    @Test("a cold start from a link shows the notice without activating, and hides it when Iris opens")
    func coldStartShowsTheNotice() {
        let h = Harness([.held(Self.cli), .acquired])
        h.gate.begin()
        h.gate.receive(URL(string: "iris-dev://run-job/x"))
        #expect(h.notices == 0, "not before did-finish")
        h.gate.didFinishLaunching()
        #expect(h.notices == 1)
        #expect(h.activations == 0, "decision 13: the notice is shown without activating Iris")
        h.advance(1)
        #expect(h.gate.isOpen)
        #expect(h.hides == 1)
        #expect(h.activations == 0)
    }

    @Test("a Dock launch while waiting activates as today and shows no extra notice")
    func dockLaunchHasNoNotice() {
        let h = Harness([.held(Self.cli)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.notices == 0)
        #expect(h.activations == 1)
    }

    @Test("a GUI holder at launch is refused at did-finish, and the alert knows about a link")
    func secondGUIRefuses() {
        let h = Harness([.held(Self.app)])
        h.gate.begin()
        #expect(h.refusals.isEmpty, "no alert before the app has finished launching")
        h.gate.receive(URL(string: "iris-dev://run-job/x"))
        h.gate.didFinishLaunching()
        #expect(h.refusals.count == 1)
        #expect(h.refusals.first?.0 == .otherApp(pid: 4444))
        #expect(h.refusals.first?.1 == true)
        #expect(h.opened == 0)
        #expect(h.delivered.isEmpty)
    }

    @Test("a waiting GUI that finds a GUI holder on a poll quits the same way")
    func waiterLosesToAGUI() {
        let h = Harness([.held(Self.cli), .held(Self.app)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        h.advance(1)
        #expect(h.refusals.map(\.0) == [.otherApp(pid: 4444)])
        #expect(h.tick == nil)
        #expect(h.opened == 0)
    }

    @Test(".legacy and .failed refuse, and never open")
    func legacyAndFailedRefuse() {
        for claim in [StoreLock.Claim.legacy(pid: 5), .failed(detail: "flock: ENOLCK")] {
            let h = Harness([claim])
            h.gate.begin()
            h.gate.didFinishLaunching()
            #expect(h.opened == 0)
            #expect(h.refusals.count == 1)
        }
    }

    @Test("an unnamed holder still unnamed after a second refuses as a GUI")
    func unnamedHolderRefusesAfterASecond() {
        let h = Harness([.held(nil)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.intervals == [LaunchGate.unknownPollInterval], "an unnamed holder is re-read fast")
        for _ in 0..<4 { h.advance(0.2) }
        #expect(h.refusals.isEmpty, "four re-reads inside the second, none refused")
        h.advance(0.2)
        #expect(h.refusals.map(\.0) == [.otherApp(pid: nil)])
    }

    @Test("a named holder is polled once a second, and the poll speeds up while the holder is unnamed")
    func pollRateFollowsTheHolder() {
        let h = Harness([.held(Self.cli), .held(nil), .held(Self.cli)])
        h.gate.begin()
        h.advance(1)
        h.advance(0.2)
        #expect(h.intervals == [LaunchGate.knownPollInterval, LaunchGate.unknownPollInterval, LaunchGate.knownPollInterval])
    }

    @Test("Review Focus 3: the waiting state tracks whichever run holds the store now")
    func waitingTracksTheCurrentHolder() {
        let next = StoreLock.Holder(pid: 5151, kind: .runJob, job: "second")
        let h = Harness([.held(Self.cli), .held(nil), .held(next), .held(Self.app)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.gate.state == .waiting(Self.cli))
        h.advance(0.2)   // between runs, before the next has written its payload
        #expect(h.gate.state == .waiting(nil))
        h.advance(0.2)
        #expect(h.gate.state == .waiting(next))
        #expect(h.gate.sentence.contains("pid 5151, job second"))
        h.advance(1)
        #expect(h.refusals.map(\.0) == [.otherApp(pid: 4444)])
    }

    @Test("Review Focus 2: quitting while waiting flushes nothing")
    func quitWhileWaitingFlushesNothing() {
        let h = Harness([.held(Self.cli)])
        h.gate.begin()
        var flushed = 0
        h.gate.willTerminate { flushed += 1 }
        #expect(flushed == 0)
        let open = Harness([.acquired])
        open.gate.begin()
        open.gate.willTerminate { flushed += 1 }
        #expect(flushed == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh LaunchGateTests`
Expected: the build fails with `cannot find 'LaunchDecision' in scope`.

- [ ] **Step 3: Write the decision and the gate.** Create `Sources/IrisKit/LaunchGate.swift`:

```swift
import Foundation
import Observation

/// #463 decisions 6, 8 and 9: what an app launch does with the store lock's answer. Pure.
enum LaunchDecision: Equatable, Sendable {
    case open
    case wait(StoreLock.Holder?)
    case refuse(LaunchRefusal)

    /// How long a holder may go unnamed before the app treats it as a GUI (decision 6). Refusing
    /// a slow CLI costs a relaunch; waiting forever behind a GUI costs the session.
    static let unknownGrace: TimeInterval = 1

    static func decide(_ claim: StoreLock.Claim, unknownFor: TimeInterval) -> LaunchDecision {
        switch claim {
        case .acquired:
            return .open
        case .held(let holder?):
            switch holder.kind {
            case .runJob, .seedDevHome: return .wait(holder)
            case .app, .perf: return .refuse(.otherApp(pid: holder.pid))
            }
        case .held(nil):
            return unknownFor < unknownGrace ? .wait(nil) : .refuse(.otherApp(pid: nil))
        case .legacy(let pid):
            return .refuse(.legacy(pid: pid))
        case .failed(let detail):
            return .refuse(.failed(detail: detail))
        }
    }
}

/// Why this app quits instead of opening (decisions 4 and 8).
enum LaunchRefusal: Equatable, Sendable {
    case otherApp(pid: Int32?)
    case legacy(pid: Int32)
    case failed(detail: String)

    static let alreadyRunningTitle = "Iris is already running on this home"
    static let cannotLockTitle = "Iris could not lock its store"
    static let linkNotRun = "The link you opened was not run."

    var title: String {
        switch self {
        case .otherApp, .legacy: Self.alreadyRunningTitle
        case .failed: Self.cannotLockTitle
        }
    }

    /// The process to bring forward, when there is one to name.
    var holderPid: Int32? {
        switch self {
        case .otherApp(let pid): pid
        case .legacy(let pid): pid
        case .failed: nil
        }
    }

    func message(hadLinks: Bool) -> String {
        let body: String
        switch self {
        case .otherApp(let pid):
            body = "Another Iris\(pid.map { " (pid \($0))" } ?? "") has this home open, so this one is quitting. Use that one."
        case .legacy(let pid):
            body = "An older Iris build (pid \(pid)) has this home open, so this one is quitting. Quit it, then open Iris again."
        case .failed(let detail):
            body = "Iris will not open its conversations without the lock, so it is quitting. \(detail)"
        }
        return hadLinks ? body + " " + Self.linkNotRun : body
    }
}

/// #463 decisions 9-13: the only state an app has while another process holds its store.
/// Nothing here, and nothing a waiting scene renders, touches `AppState`. Every effect goes
/// through `Seams`, so the tests drive it without a store, a window or a timer.
@MainActor
@Observable
final class LaunchGate {
    enum State: Equatable {
        case waiting(StoreLock.Holder?)
        case open
        case refused(LaunchRefusal)
    }

    struct Seams {
        var claim: @MainActor () -> StoreLock.Claim
        /// `IrisApp.openStore()`: migrations, shipped skills, `AppState.shared`, notifications,
        /// `reapOrphans` and the idle loop (decision 11). Runs once, with the lock held.
        var openStore: @MainActor () -> Void
        /// `startOnce` or `refuseRunJobURLsUntilSetUp`, then the held links, oldest first.
        var finishLaunch: @MainActor (_ links: [URL?], _ dropped: Int) -> Void
        /// A link after the store is open: `AppState.shared.receiveRunJobURL`.
        var deliver: @MainActor (URL?) -> Void
        /// The alert, the holder brought forward, and quit.
        var refuse: @MainActor (LaunchRefusal, _ hadLinks: Bool) -> Void
        /// A repeating main-queue `DispatchSourceTimer` at `interval`, never `Task.sleep`
        /// (invariant 4). Called again with a new interval when the poll rate changes.
        var startPolling: @MainActor (_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> Void
        var stopPolling: @MainActor () -> Void
        /// Orders the "Iris is waiting" panel front without activating Iris (decision 13).
        var showWaitingNotice: @MainActor () -> Void
        var hideWaitingNotice: @MainActor () -> Void
        /// `NSApp.activate`, which did-finish did unconditionally before #463. Skipped only for a
        /// link that launched Iris while it waits (plan note 13).
        var activate: @MainActor () -> Void
        var now: @MainActor () -> Date = { Date() }
    }

    /// Decision 9's poll, while the holder is named.
    static let knownPollInterval: TimeInterval = 1
    /// While the holder is unnamed, so decision 5's second of re-reading is several reads, not one.
    static let unknownPollInterval: TimeInterval = 0.2

    private(set) var state: State = .waiting(nil)
    var isOpen: Bool { state == .open }

    private let seams: Seams
    @ObservationIgnored private var links: [URL?] = []
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var didFinish = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var refusalShown = false
    @ObservationIgnored private var noticeShown = false
    @ObservationIgnored private var pollInterval: TimeInterval?
    @ObservationIgnored private var unknownSince: Date?

    init(seams: Seams) { self.seams = seams }

    var heldLinkCount: Int { links.count }

    /// `IrisApp.init`: when the lock is free this opens the store right here, as today's `init` did.
    func begin() { apply(seams.claim()) }

    /// One poll: re-claim, re-read the holder's `kind`, re-run decision 3's inode check.
    func poll() {
        guard case .waiting = state else { return }
        apply(seams.claim())
    }

    func didFinishLaunching() {
        guard !didFinish else { return }
        didFinish = true
        switch state {
        case .refused(let refusal):
            showRefusal(refusal)   // the alert activates Iris itself
        case .waiting where !links.isEmpty:
            showNoticeNow()   // a link launched Iris: no activation (decision 13)
        case .waiting:
            seams.activate()
        case .open:
            seams.activate()
            finishIfReady()
        }
    }

    /// Every link from `RunJobURLEvents`. Never logged: it carries a live token.
    func receive(_ url: URL?) {
        if isOpen { return seams.deliver(url) }
        guard links.count < RunJobURLIntake.capacity else { dropped += 1; return }
        links.append(url)
        if didFinish, case .waiting = state { showNoticeNow() }
    }

    /// `applicationWillTerminate`: only an open app has anything to flush (Review Focus 2).
    func willTerminate(flush: () -> Void) {
        if isOpen { flush() }
    }

    /// A held link after did-finish, and the hotkey (which activates first, on purpose).
    func showNoticeNow() {
        guard case .waiting = state else { return }
        noticeShown = true
        seams.showWaitingNotice()
    }

    var sentence: String {
        switch state {
        case .waiting(let holder): Self.waitingSentence(holder)
        case .open: "Iris is open."
        case .refused(let refusal): refusal.title + "."
        }
    }

    static func waitingSentence(_ holder: StoreLock.Holder?) -> String {
        guard let holder else { return "Another Iris process is using this home. Iris will open when it finishes." }
        switch holder.kind {
        case .seedDevHome:
            return "An iris --seed-dev-home is copying into this home (pid \(holder.pid)). Iris will open when it finishes."
        case .runJob, .app, .perf:
            let job = holder.job.map { ", job \(flattened($0))" } ?? ""
            return "An iris --run-job is using this home (pid \(holder.pid)\(job)). Iris will open when it finishes."
        }
    }

    private static func flattened(_ job: String) -> String {
        let line = job.components(separatedBy: .newlines).joined(separator: " ")
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    private func apply(_ claim: StoreLock.Claim) {
        let now = seams.now()
        if case .held(nil) = claim { unknownSince = unknownSince ?? now } else { unknownSince = nil }
        let unknownFor = unknownSince.map { now.timeIntervalSince($0) } ?? 0
        switch LaunchDecision.decide(claim, unknownFor: unknownFor) {
        case .open:
            stopPolling()
            hideNotice()
            seams.openStore()
            state = .open
            finishIfReady()
        case .wait(let holder):
            if state != .waiting(holder) { state = .waiting(holder) }
            poll(every: holder == nil ? Self.unknownPollInterval : Self.knownPollInterval)
        case .refuse(let refusal):
            stopPolling()
            hideNotice()
            state = .refused(refusal)
            if didFinish { showRefusal(refusal) }
        }
    }

    private func poll(every interval: TimeInterval) {
        guard pollInterval != interval else { return }
        if pollInterval != nil { seams.stopPolling() }
        pollInterval = interval
        seams.startPolling(interval) { [weak self] in self?.poll() }
    }

    private func stopPolling() {
        guard pollInterval != nil else { return }
        pollInterval = nil
        seams.stopPolling()
    }

    private func hideNotice() {
        guard noticeShown else { return }
        noticeShown = false
        seams.hideWaitingNotice()
    }

    private func showRefusal(_ refusal: LaunchRefusal) {
        guard !refusalShown else { return }
        refusalShown = true
        seams.refuse(refusal, !links.isEmpty)
    }

    private func finishIfReady() {
        guard isOpen, didFinish, !finished else { return }
        finished = true
        let held = links
        links = []
        seams.finishLaunch(held, dropped)
    }
}
```

- [ ] **Step 4: Write the views.** Create `Sources/IrisKit/WaitingView.swift`:

```swift
import SwiftUI
import AppKit

/// What every scene shows until the gate is open (#463 decision 10). Reads the gate only.
struct WaitingView: View {
    let gate: LaunchGate

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(verbatim: gate.sentence)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit Iris") { NSApp.terminate(nil) }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 160)
    }
}

/// A scene's content, or the waiting view until the store is open. `content` is built only in
/// the open branch, so `ChatView()`'s `AppState.shared` default is never evaluated while waiting.
struct GatedContent<Content: View>: View {
    let gate: LaunchGate
    @ViewBuilder let content: () -> Content

    var body: some View {
        if gate.isOpen { content() } else { WaitingView(gate: gate) }
    }
}

/// The status item's menu while waiting: the sentence and Quit.
struct WaitingMenu: View {
    let gate: LaunchGate

    var body: some View {
        Text(verbatim: gate.sentence)
        Divider()
        Button("Quit Iris") { NSApp.terminate(nil) }
    }
}

/// The status item's menu: `StatusMenu` once open, `WaitingMenu` until then. A view of its own so
/// the branch is re-evaluated when the gate changes, which a `Scene` body's closure may not be.
struct GatedStatusMenu: View {
    let gate: LaunchGate

    var body: some View {
        if gate.isOpen { StatusMenu(state: AppState.shared) } else { WaitingMenu(gate: gate) }
    }
}

/// The status item's label: the hourglass while waiting, `StatusItemLabel` once open. It adopts
/// the label's `openWindow` in both branches, so the waiting notice can open before any window.
struct GatedStatusLabel: View {
    let gate: LaunchGate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if gate.isOpen {
            StatusItemLabel(state: AppState.shared)
        } else {
            let _ = MainWindow.adoptOpenAction(openWindow, from: .label)
            Image(systemName: "hourglass")
                .accessibilityLabel("Iris is waiting")
        }
    }
}
```

In `RunJobURLEventsTests.swift:52-53`, add `"LaunchGate.swift"` to the file list in `nothingLogs`.

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh LaunchGateTests` then `timeout 300 scripts/test-filter.sh RunJobURLEventsTests`
Expected: PASS, 18 tests, then the events suite's count unchanged from `main`.

- [ ] **Step 6: Mutation checks.** Make each change alone, run `LaunchGateTests`, confirm the named test fails, then revert it.
  - In `decide`, return `.open` for `.failed`. Expected: `decisionTable` and `legacyAndFailedRefuse` fail (`.failed` refuses).
  - Return `.wait(nil)` for `.legacy`. Expected: `decisionTable` and `legacyAndFailedRefuse` fail (`.legacy` refuses).
  - Move `.app` into the `.runJob, .seedDevHome` case. Expected: `secondGUIRefuses`, `waiterLosesToAGUI` and `waitingTracksTheCurrentHolder` fail (a second GUI refuses).
  - Call `seams.openStore()` at the top of the `.wait` branch. Expected: `waitsThenOpens` fails.

- [ ] **Step 7: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0. (Nothing uses the gate yet. Task 7 wires it.)

- [ ] **Step 8: Commit.**

```bash
git add Sources/IrisKit/LaunchGate.swift Sources/IrisKit/WaitingView.swift Tests/irisTests/LaunchGateTests.swift Tests/irisTests/RunJobURLEventsTests.swift
git commit -m "feat: LaunchDecision and LaunchGate, the launch that waits behind a CLI (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 6: delete D2's deferral and `LaunchLock`

**Files:**
- Delete: `Sources/IrisKit/LaunchLock.swift`, `Tests/irisTests/LaunchLockTests.swift`, `Tests/irisTests/RunJobURLDeferralTests.swift`
- Modify: `Sources/IrisKit/RunJobURLHandling.swift:11-15`, `:17-20`, `:60-71`, `:76-78`, `:91-92`, `:152-238`, `:240-249`
- Modify: `Sources/IrisKit/RunJobURL.swift:40-56` (the waiting lines and notice), `:166-203` (`URLDeferral`, `URLDeferralTimer`, `PendingURLFire`)
- Modify: `Sources/IrisKit/AppState.swift:4231`, `:4241-4263`
- Modify: `Sources/IrisKit/iris.swift:5497-5499`, `:5512` (the pre-acquire read and `noteForeignStoreHolder`)
- Modify: `Tests/irisTests/RunJobURLTests.swift:704`, `:726`, `:738`, `:753`, `Tests/irisTests/RunJobURLEventsTests.swift:53`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `struct URLTimer` (renamed from `URLDeferralTimer`, plan note 5), with `static let dispatch` and `schedule`
  - `AppState.RunJobURLOutcome` without `.deferred`
  - These no longer exist: `URLDeferral`, `PendingURLFire`, `deferURLFire`, `recheckDeferredURLFire`, `foreignStoreHolder`, `foreignStoreHolderStart`, `isProcessAlive`, `processStart`, `urlDeferralTimer`, `pendingURLFires`, `noteForeignStoreHolder`, `isForeignHolderAlive`, `isHolderAlive`, `ProcessStart`, `StoreHolder`, `LaunchLock`, `RunJobURL.waitingLine`, `waitEndedLine`, `gaveUpLine`, `waitAbandonedLine`, `foreignHolderNotice`, `deletedWhileWaitingReason`, `replacedWhileWaitingReason`

- [ ] **Step 1: Delete the files and their tests.** Run `git rm Sources/IrisKit/LaunchLock.swift Tests/irisTests/LaunchLockTests.swift Tests/irisTests/RunJobURLDeferralTests.swift`.

- [ ] **Step 2: Cut the deferral out of the handler.** In `RunJobURLHandling.swift`:
  - Delete `case deferred(UUID)` (`:14`).
  - In `handleRunJobURL`'s doc comment (`:17-20`), replace "apply the URL limit, defer behind a foreign store holder or fire" with "apply the URL limit and fire". A store held by another process now holds the whole app at the gate (#463), so nothing here waits.
  - Delete `:60-71` (the `pendingURLFires` join and the `foreignStoreHolder` block).
  - In `urlFireRefusal`, change the doc's "and again when a deferred fire comes due" (`:77`) to nothing. Replace `:91-92` with `let inBatch = batch?.dispatched.count ?? 0`.
  - Delete `deferURLFire`, `scheduleURLRecheck`, `recheckDeferredURLFire`, `DeferredFireRefusal`, `deferredFireCheck` and `abandonDeferredFire` (`:152-238`).
  - In `forgetURLState` (`:240-249`), delete the `if let pending = …` block and the doc's last sentence.

- [ ] **Step 3: Cut the deferral's words and types.** In `RunJobURL.swift`, delete `waitingLine`, `waitEndedLine`, `gaveUpLine`, `waitAbandonedLine`, `foreignHolderNotice`, `deletedWhileWaitingReason` and `replacedWhileWaitingReason` (`:40-56`). Delete `URLDeferral` and `PendingURLFire` (`:166-177`, `:190-203`). Replace `URLDeferralTimer` (`:179-188`) with:

```swift
/// How the URL refusal line's catch-up is scheduled: on a dispatch queue, never `Task.sleep` on
/// the cooperative pool (the invariant 4 rule). A seam so a test can fire it by hand.
struct URLTimer: Sendable {
    let schedule: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    static let dispatch = URLTimer { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
    }
}
```

- [ ] **Step 4: Cut the fields.** In `AppState.swift`, change `:4231` to `@ObservationIgnored var urlRefusalFlushTimer = URLTimer.dispatch`. Delete `foreignStoreHolder`, `isProcessAlive`, `foreignStoreHolderStart`, `processStart`, `urlDeferralTimer` and `pendingURLFires`, with their doc comments (`:4241-4263` except `urlIntake`, `engineStarted` and `launchEngine`, which stay). Update the `urlClock` comment (`:4237`) to "The clock the URL limit and the coalescing window read. A seam for tests."

- [ ] **Step 5: Cut the launch read.** In `iris.swift`'s `IrisApp.init`, delete `:5497-5499` (the D6 decision 14 comment and `let priorHolder = LaunchLock.read(…)`) and `:5512` (`AppState.shared.noteForeignStoreHolder(priorHolder)`). `GUILock.acquire()` stays until Task 7.

- [ ] **Step 6: Fix the tests that name the renamed timer.** In `RunJobURLTests.swift`, replace `URLDeferralTimer` with `URLTimer` at `:704`, `:726`, `:738` and `:753`. In `RunJobURLEventsTests.swift:53`, remove `"LaunchLock.swift"` from the list.

- [ ] **Step 7: Confirm nothing is left.** Run:

```bash
grep -rnE "URLDeferral|PendingURLFire|deferURLFire|\.deferred\b|foreignStoreHolder|noteForeignStoreHolder|foreignHolderNotice|LaunchLock|ProcessStart|StoreHolder|isHolderAlive|isForeignHolderAlive|urlDeferralTimer|pendingURLFires|waitingLine|gaveUpLine|waitEndedLine|waitAbandonedLine|WhileWaitingReason" Sources Tests
```

Expected: no output.

- [ ] **Step 8: Run the URL suites.**

Run: `timeout 300 scripts/test-filter.sh RunJobURLTests`, then `RunJobURLIntakeTests`, then `RunJobURLEventsTests`.
Expected: PASS each, with `main`'s counts.

- [ ] **Step 9: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 10: Commit.**

```bash
git add -A Sources/IrisKit/RunJobURLHandling.swift Sources/IrisKit/RunJobURL.swift Sources/IrisKit/AppState.swift \
  Sources/IrisKit/iris.swift Tests/irisTests/RunJobURLTests.swift Tests/irisTests/RunJobURLEventsTests.swift
git commit -m "refactor: delete D2's foreign-holder deferral and LaunchLock (#463 decision 12)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 7: the app opens through the gate; `GUILock` goes

**Files:**
- Create: `Sources/IrisKit/IrisApp.swift` (`AppDelegate` and `IrisApp`, moved out of `iris.swift:5438-5579` and rewired)
- Create: `Sources/IrisKit/LaunchGate+App.swift` (`Seams.app()`, `GatePollTimer`, `WaitingNoticePanel`)
- Modify: `Sources/IrisKit/iris.swift:5438-5579` (deleted, moved), `:3437-3439` (`interruptedByQuitReason`)
- Modify: `Tests/irisTests/RunJobURLEventsTests.swift:52-53` (scan the two new files)
- Modify: `Sources/IrisKit/RunJobURLEvents.swift:18-27`
- Modify: `Sources/IrisKit/RunJobURLIntake.swift:3-7` (comment), plus `noteLinksDroppedWhileWaiting`
- Modify: `Sources/IrisKit/RunJobURL.swift` (add `droppedWhileWaitingLine`)
- Modify: `Sources/IrisKit/SandboxSessionManager.swift:241-250` (comment)
- Modify: `Sources/IrisKit/RunJobCLI.swift:1-249` (delete `GUILock`)
- Modify: `Tests/irisTests/RunJobURLIntakeTests.swift` (one test)

**Interfaces:**
- Consumes: Task 5's `LaunchGate`, `Seams` and views. Task 1's `StoreLock`. `RunJobURLIntake.capacity`.
- Produces:
  - `extension LaunchGate { static let shared }`, `LaunchGate.Seams.app()`, `GatePollTimer`, `WaitingNoticePanel`
  - `@MainActor static func IrisApp.openStore()`
  - `AppState.noteLinksDroppedWhileWaiting(_ count: Int)`
  - `RunJobURL.droppedWhileWaitingLine(_ count: Int) -> String`
  - `IrisEngine.interruptedByQuitReason == "the Iris process running it ended"`
  - `GUILock` no longer exists

- [ ] **Step 1: Write the failing test.** In `RunJobURLIntakeTests.swift`, add:

```swift
    @Test("#463 decision 12: links dropped while Iris waited are counted in one line in Iris")
    func droppedWhileWaitingIsOneLine() throws {
        let (_, app, _, _) = try makeApp()
        app.noteLinksDroppedWhileWaiting(3)
        #expect(irisLines(app).contains("3 links that arrived while Iris waited were dropped unread."))
        app.noteLinksDroppedWhileWaiting(0)
        #expect(irisLines(app).filter { $0.contains("dropped unread") }.count == 1, "nothing for zero")
    }
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `timeout 300 scripts/test-filter.sh RunJobURLIntakeTests`
Expected: the build fails with `value of type 'AppState' has no member 'noteLinksDroppedWhileWaiting'`.

- [ ] **Step 3: Add the line.** In `RunJobURL.swift`, beside the other refusal sentences:

```swift
    /// #463 decision 12: links past the gate's capacity while Iris waited for the store.
    static func droppedWhileWaitingLine(_ count: Int) -> String {
        "\(count) link\(count == 1 ? "" : "s") that arrived while Iris waited \(count == 1 ? "was" : "were") dropped unread."
    }
```

In `RunJobURLIntake.swift`, add to the `AppState` extension:

```swift
    /// The gate's overflow, said once in Iris after the launch completes. The links were never
    /// read, so nothing can say which jobs they named.
    func noteLinksDroppedWhileWaiting(_ count: Int) {
        guard count > 0 else { return }
        appendMessage(role: .system, content: RunJobURL.droppedWhileWaitingLine(count), to: activityConversationId())
    }
```

Replace the intake's header comment (`RunJobURLIntake.swift:3-7`) with:

```swift
/// Where a run-job link waits while Iris starts (D2, owner ruling C2). A cold launch delivers the
/// link between `applicationWillFinishLaunching` and `applicationDidFinishLaunching`, before the
/// job bookkeeping `IrisEngine.start()` does first, which closes every `running` row as a dead
/// process's. So links wait here until that is done, in order, and are then handled as if they had
/// just arrived. A link that came while another process held the store waited at `LaunchGate`
/// first, and arrives here at `finishLaunch` (#463 decision 12).
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `timeout 300 scripts/test-filter.sh RunJobURLIntakeTests`
Expected: PASS, `main`'s count plus 1.

- [ ] **Step 5: Move the GUI shell into a file of its own, and wire it.** Cut `iris.swift:5438-5579` (`AppDelegate` and `IrisApp`) out of `iris.swift`. Their new home is `Sources/IrisKit/IrisApp.swift`, so the `.shared` scan (Task 8) can exempt the GUI shell without exempting `IrisEngine`. The seams that carry raw links go in `Sources/IrisKit/LaunchGate+App.swift`, which `RunJobURLEventsTests.nothingLogs` reads. That keeps `iris.swift`'s `print` calls out of the link's path. Five changes come with the move:
  - `IrisApp.init` asks the gate.
  - `openStore()` holds today's store half (`:5501-5528`, minus the lock lines).
  - Activation moves from `init` and did-finish into the gate, so a link that launches Iris while it waits does not activate it (plan note 13).
  - terminate flushes only an open app.
  - Every store-backed scene is gated.

Create `Sources/IrisKit/IrisApp.swift`:

```swift
import AppKit
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Kept for the life of the app: `NSAppleEventManager` is not documented to retain a handler.
    private var runJobURLEvents: RunJobURLEvents?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Here, not in did-finish: a link that launches Iris arrives between the two (Task 24).
        // Never `application(_:open:)` or `.handlesExternalEvents`: SwiftUI opened a window per
        // link with either (owner ruling C2).
        runJobURLEvents = RunJobURLEvents.installForApp()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Sparkle wants its scheduled checks started after launch, not at construction.
            UpdaterController.shared?.start()
            // #463 decision 11: `finishLaunch` (startOnce, then the held links) runs once both this
            // and `openStore()` have happened, whichever is later. The gate also activates Iris,
            // except for a link launch while it waits (decision 13), and alerts a refused launch.
            LaunchGate.shared.didFinishLaunching()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush BEFORE _exit: it runs no atexit handlers, so it would kill the pending debounced
        // save and skip the cfprefsd flush, losing every unwritten change (#62). Only an open app
        // has an `AppState` to flush; a waiting or refused one must not build one now (#463).
        MainActor.assumeIsolated {
            LaunchGate.shared.willTerminate {
                AppState.shared.flushURLRefusalLines()
                AppState.shared.flushSave()
            }
        }
        // Conversations live in their own database now (#163), but settings and other state
        // still ride on UserDefaults, and `_exit` skips the cfprefsd flush for those too.
        IrisDefaults.store.synchronize()
        // Last, just before `_exit`: an empty payload under a held lock reads as an unnamed holder
        // (decision 5), so it must not sit there while anything else runs. A no-op in a process
        // that never held the lock, so a refused second GUI leaves the holder's payload alone.
        StoreLock.vacate(at: IrisPaths.default.storeLockFile)
        // Bypass static destructors in llama.cpp ggml-metal to prevent GGML_ASSERT crash on exit
        _exit(0)
    }
}

struct IrisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    init() {
        // AppDefaultsImport.runIfNeeded() already ran in IrisMain.run(), before this initializer —
        // that is the earliest call site (also covers --run-job/--perf/--bench from a bundle
        // executable) and importOnce is idempotent, so it is not repeated here.
        //
        // #463: the store lock decides, before anything touches `conversations.sqlite`. Free, and
        // `openStore()` runs right here, as this initializer always did. Held by a `--run-job` or
        // the seeder, and the app waits behind `WaitingView` until it is free. Held by a GUI, and
        // the app alerts and quits at did-finish.
        //
        // `assumeIsolated` is safe *here* specifically: `App.init` is documented to run on the
        // main thread, and this is a synchronous call in it. It is not a general escape hatch —
        // the same construct trapped in #187's D3 PR B when it was reached from a non-isolated
        // closure. The gate's poll reaches `openStore()` from a main-queue timer, which is the
        // main thread too.
        MainActor.assumeIsolated {
            LaunchGate.shared.begin()
        }
        NSApplication.shared.setActivationPolicy(.regular)
        // No `activate` here any more: did-finish activates through the gate, which knows whether
        // a link launched Iris while it waits (plan note 13).

        if let imagePath = Bundle.module.path(forResource: "iris-icon", ofType: "png"),
           let image = NSImage(contentsOfFile: imagePath) {
            NSApplication.shared.applicationIconImage = image
        }

        // D6 decision 4: the raise goes through `showMainWindow`, like every other surface's.
        // The gate is asked when the key is pressed, not here (#463 decision 10). A hotkey is the
        // owner asking for Iris, so it activates even while waiting.
        KeyboardShortcuts.onKeyUp(for: .toggleIris) {
            if LaunchGate.shared.isOpen {
                MainWindow.tracking.toggleFromHotkey(state: AppState.shared)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                LaunchGate.shared.showNoticeNow()
            }
        }
    }

    /// #463 decision 11's first half: everything that needs the store, once, with the lock held.
    @MainActor
    static func openStore() {
        IrisMigrator.migrate(.default)
        ShippedSkills.seedIfNeeded(.default)
        // Once, in the app, on the one `AppState` that exists here — never from `AppState.init`,
        // which a test suite runs hundreds of times (#218).
        AppState.shared.installGuardHealthSink()
        // D6 decision 16: the snapshot at launch. Here and not in `AppState.init`, which a test
        // suite runs hundreds of times.
        AppState.shared.refreshLedgerAttention()
        AppState.shared.raiseMainWindow = { MainWindow.raise() }
        AppState.shared.openRunLogWindow = { RunLogWindow.open() }
        // D6 decision 8: only here, and only in a real `.app` bundle.
        SurfaceInstall.installNotifications(on: AppState.shared)
        Task {
            // Only the lock's holder runs this, so every `iris-` container on this home it does
            // not know about belongs to a process that has ended (#463 decision 11).
            await SandboxSessionManager.shared.reapOrphans()
            while true {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // every 5 min
                let minutes = await MainActor.run { ConfigManager.shared.sandboxIdleTimeoutMinutes }
                await SandboxSessionManager.shared.reapIdle(olderThan: TimeInterval(minutes * 60))
            }
        }
    }

    var body: some Scene {
        WindowGroup("Iris", id: MainWindow.sceneId) {
            GatedContent(gate: LaunchGate.shared) {
                ChatView()
                    .tint(.irisIndigo)
            }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                if let updater = UpdaterController.shared {
                    CheckForUpdatesButton(updater: updater)
                }
                Divider()
                Button("Rerun Setup Wizard...") {
                    NotificationCenter.default.post(name: NSNotification.Name("RerunSetupWizard"), object: nil)
                }
            }
        }

        // Touches no store (MetricsManager and PerformanceProfiler only), so it is not gated.
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
        }

        Window("Run Log", id: RunLogWindow.sceneId) {
            GatedContent(gate: LaunchGate.shared) {
                RunLogView(state: AppState.shared)
            }
        }
        .defaultSize(width: RunLogView.defaultWidth, height: RunLogView.defaultHeight)

        MenuBarExtra {
            GatedStatusMenu(gate: LaunchGate.shared)
        } label: {
            GatedStatusLabel(gate: LaunchGate.shared)
        }

        Settings {
            GatedContent(gate: LaunchGate.shared) {
                SettingsView()
            }
        }
    }
}
```

Create `Sources/IrisKit/LaunchGate+App.swift`. It holds the production seams, the poll's timer and the waiting notice. The notice is an AppKit panel rather than a SwiftUI `Window` scene: `OpenWindowAction` has no non-activating form, and decision 13 opens the notice without activating Iris.

```swift
import AppKit
import SwiftUI

/// The poll's timer, held between `startPolling` and `stopPolling`. A main-queue dispatch timer,
/// never `Task.sleep` (invariant 4).
@MainActor
final class GatePollTimer {
    private var timer: DispatchSourceTimer?

    func start(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { MainActor.assumeIsolated { tick() } }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Decision 13's "Iris is waiting" notice for a link's windowless cold start: a non-activating
/// panel, ordered front without taking focus from whatever the owner is doing.
@MainActor
final class WaitingNoticePanel {
    private var panel: NSPanel?

    func show(gate: LaunchGate) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Iris is waiting"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: WaitingView(gate: gate))
            panel.center()
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

extension LaunchGate {
    /// The app's one gate. Built on first use, from `IrisApp.init`. Tests build their own.
    static let shared = LaunchGate(seams: .app())
}

extension LaunchGate.Seams {
    @MainActor
    static func app() -> LaunchGate.Seams {
        let poll = GatePollTimer()
        let notice = WaitingNoticePanel()
        let lock = IrisPaths.default.storeLockFile
        return LaunchGate.Seams(
            claim: { StoreLock.claim(at: lock, kind: .app) },
            openStore: { IrisApp.openStore() },
            finishLaunch: { links, dropped in
                // D2: a link's cold start opens no window, so `ChatView.onAppear` may never start
                // the engine; start it here. The window's own call is then a no-op.
                if AppState.isSetUp() {
                    AppState.shared.startOnce()
                } else {
                    AppState.shared.refuseRunJobURLsUntilSetUp()
                }
                for link in links { AppState.shared.receiveRunJobURL(link) }
                AppState.shared.noteLinksDroppedWhileWaiting(dropped)
            },
            deliver: { AppState.shared.receiveRunJobURL($0) },
            refuse: { refusal, hadLinks in
                let alert = NSAlert()
                alert.messageText = refusal.title
                alert.informativeText = refusal.message(hadLinks: hadLinks)
                alert.addButton(withTitle: "Quit")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                if let pid = refusal.holderPid {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                NSApp.terminate(nil)
            },
            startPolling: { interval, tick in poll.start(every: interval, tick) },
            stopPolling: { poll.stop() },
            showWaitingNotice: { notice.show(gate: LaunchGate.shared) },
            hideWaitingNotice: { notice.hide() },
            activate: { NSApp.activate(ignoringOtherApps: true) })
    }
}
```

In `RunJobURLEventsTests.swift`'s `nothingLogs` list, add `"LaunchGate+App.swift"` and `"IrisApp.swift"` beside `"LaunchGate.swift"`.

In `RunJobURLEvents.swift`, replace `:18-27` with:

```swift
    /// The app's handler, delivering to `LaunchGate`, which holds a link while another process has
    /// the store and passes it to `AppState.shared` once Iris is open (#463 decision 12). Here
    /// rather than in `AppDelegate` so the closure that carries the raw link sits in a file the
    /// no-logging test reads. A real `.app` only (decision 8), by the predicate notifications use:
    /// the bare binary registers no scheme, so nothing routes a link to it.
    static func installForApp(bundleURL: URL = Bundle.main.bundleURL) -> RunJobURLEvents? {
        guard SurfaceInstall.isAppBundle(bundleURL) else { return nil }
        let events = RunJobURLEvents { url in LaunchGate.shared.receive(url) }
        events.install()
        return events
    }
```

- [ ] **Step 6: The quit reason and the sweep's comment.** In `iris.swift:3437-3439`:

```swift
    /// The failure reason written onto runs that were still `running` when this process opened the
    /// store: only the lock's holder runs this sweep, so whatever process was running them has
    /// ended, and nothing will ever finish them (#463 decision 11).
    static let interruptedByQuitReason = "the Iris process running it ended"
```

In `SandboxSessionManager.swift`, replace the doc's first sentence (`:241-242`) with `/// Deletes the containers a previous process left behind. Launch only, and only in the process holding the home's store lock (#463), before anything else can have started one.` Then replace the last sentence ("Nothing schedules this today; …") with `/// The one caller is \`IrisApp.openStore()\`; the exclusions keep it from killing live work if anything else ever calls it.`

- [ ] **Step 7: Delete `GUILock`.** Delete `RunJobCLI.swift:1-249` (the `GUILock` doc and enum), leaving `import Foundation` at the top. Then run `grep -rn "GUILock" Sources Tests`. Expected: no output.

- [ ] **Step 8: Build and run the touched suites.**

Run: `scripts/check-warnings.sh` (expected: exit 0). Then `timeout 300 scripts/test-filter.sh RunJobURLIntakeTests`, `LaunchGateTests` and `JobRunnerTests` (`JobRunnerTests.swift:724` reads the constant). Expected: PASS each.

- [ ] **Step 9: Commit.**

```bash
git add Sources/IrisKit/iris.swift Sources/IrisKit/IrisApp.swift Sources/IrisKit/LaunchGate+App.swift \
  Sources/IrisKit/RunJobURLEvents.swift Sources/IrisKit/RunJobURLIntake.swift \
  Sources/IrisKit/RunJobURL.swift Sources/IrisKit/SandboxSessionManager.swift Sources/IrisKit/RunJobCLI.swift \
  Tests/irisTests/RunJobURLIntakeTests.swift Tests/irisTests/RunJobURLEventsTests.swift
git commit -m "feat: the app opens its store through the gate, waits behind a CLI, refuses a second GUI (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 8: `ProcessRole` and the `AppState.shared` trap

**Files:**
- Create: `Sources/IrisKit/ProcessRole.swift`
- Modify: `Sources/IrisKit/AppState.swift:370-375`
- Modify: `Sources/IrisKit/IrisMain.swift:13-46`
- Modify: `Tests/irisTests/AttachmentIntegrationTests.swift:45-46`, `:82-83`
- Create: `Tests/irisTests/SharedAppStateTrapTests.swift`

**Interfaces:**
- Consumes: Task 1's `StoreLock.holds`, `.claim`. Task 2's `onSkillsChanged` (the exit test proves no `.shared` is reached). Task 7's `IrisApp.openStore()`, which reaches `.shared` only after the gate's claim.
- Produces:
  - `enum ProcessRole: Sendable, Equatable { case app, runJob, perf, bench, seed }`
  - `static var current: ProcessRole?`, `static func set(_:)`, `static func mayUseSharedAppState(role:holdsStore:) -> Bool`
  - `AppState.shared`, which now traps outside the app's own holder

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/SharedAppStateTrapTests.swift`:

```swift
import Testing
import Foundation
@testable import IrisKit

/// #463 decision 14: `AppState.shared` traps unless this process is the app and holds its home's
/// store lock. Every build and every test traps, with no disarm, so the trapping cases run in exit
/// tests: each is a child process of its own, where setting `ProcessRole` and claiming the
/// (per-process, temporary) test home's lock touch nothing the shared test process can see.
@Suite("AppState.shared trap (#463)", .timeLimit(.minutes(1)))
struct SharedAppStateTrapTests {
    @Test("the rule: only the app, and only while it holds the store")
    func rule() {
        #expect(ProcessRole.mayUseSharedAppState(role: .app, holdsStore: true))
        #expect(!ProcessRole.mayUseSharedAppState(role: .app, holdsStore: false))
        for role in [ProcessRole.runJob, .perf, .bench, .seed] {
            #expect(!ProcessRole.mayUseSharedAppState(role: role, holdsStore: true))
        }
        #expect(!ProcessRole.mayUseSharedAppState(role: nil, holdsStore: true))
    }

    @Test("a process that never set a role traps")
    func trapsWithNoRole() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("the app traps before it holds the store")
    func appWithoutTheLockTraps() async {
        await #expect(processExitsWith: .failure) {
            ProcessRole.set(.app)
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("the app holding its store gets .shared")
    func appWithTheLockGetsShared() async {
        await #expect(processExitsWith: .success) {
            ProcessRole.set(.app)
            guard StoreLock.claim(at: IrisPaths.default.storeLockFile, kind: .app) == .acquired else { exit(3) }
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("--run-job traps even while it holds the store")
    func runJobTraps() async {
        await #expect(processExitsWith: .failure) {
            ProcessRole.set(.runJob)
            _ = StoreLock.claim(at: IrisPaths.default.storeLockFile, kind: .runJob)
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("#489: in a --run-job process, skill writes invalidate the run's own engine and reach nothing shared")
    func runJobSkillWritesStayOnTheRunsEngine() async {
        await #expect(processExitsWith: .success) {
            guard await RunJobSkillScenario.run() else { exit(2) }
        }
    }

    @Test("Review Focus 5: AppState.shared appears only in the GUI shell")
    func sharedAppearsOnlyInTheGUIShell() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // The GUI shell only: `IrisApp.swift` (Task 7 moved `IrisApp` and `AppDelegate` out of
        // `iris.swift`, which is mostly `IrisEngine`, the headless path), the gate's app seams,
        // and the views. `AppState.swift` is scanned too: its declaration is `static var shared`,
        // which neither pattern matches.
        let allowed: Set<String> = ["IrisApp.swift", "LaunchGate+App.swift", "WaitingView.swift", "ChatView.swift",
                                    "SettingsView.swift", "PluginsSettingsView.swift"]
        // `AppState.shared`, and the implicit-member spellings `: AppState = .shared` and
        // `AppState? = .shared`, which a literal-text match would miss.
        let use = try Regex(#"\bAppState\.shared\b|:\s*AppState[?!]?\s*=\s*\.shared\b"#)
        var offenders: [String] = []
        for dir in ["Sources/IrisKit", "Tests/irisTests"] {
            let base = root.appendingPathComponent(dir)
            for name in try FileManager.default.contentsOfDirectory(atPath: base.path) where name.hasSuffix(".swift") {
                guard !allowed.contains(name), name != "SharedAppStateTrapTests.swift" else { continue }
                let text = try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), code.firstMatch(of: use) != nil else { continue }
                    offenders.append("\(dir)/\(name):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "AppState.shared outside the GUI shell: \(offenders)")
    }
}

/// #489, in a child process with `ProcessRole.runJob` set, so any path that reached the shared
/// `AppState` would trap and fail the exit test. Drives an engine built as `fire` builds one,
/// through its own executor: what a CLI turn dispatches through after an approval (plan note 6).
@MainActor
enum RunJobSkillScenario {
    static func run() async -> Bool {
        ProcessRole.set(.runJob)
        guard let store = try? ConversationStore.inMemory() else { return false }
        let state = RunJobCLI.makeState(store: store)
        // Built the way `RunJobCLI.fire` builds its engine (`RunJobCLI.swift:463`): a second engine
        // over the state, not `state.engine`.
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []), protectionEnabled: false)
        let body = String(repeating: "A procedure step. ", count: 4)
        let skillFile = IrisPaths.default.skillsDir.appendingPathComponent("probe/SKILL.md")
        try? FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let calls: [(String, [String: JSONValue])] = [
            ("write_file", ["path": .string(skillFile.path),
                            "content": .string("---\nname: probe\ndescription: probe\n---\n\(body)")]),
            ("create_skill", ["name": .string("probe-two"), "description": .string("probe"), "body": .string(body)]),
        ]
        for (name, args) in calls {
            await engine.setSystemPrompt(text: "primed")
            let executor = await engine.executor
            let result = await executor.execute(name: name, args: args)
            guard result.hasPrefix("Successfully") else { return false }
            guard await engine.systemPrompt == nil else { return false }
        }
        withExtendedLifetime(state) {}
        return true
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh SharedAppStateTrapTests`
Expected: the build fails with `cannot find 'ProcessRole' in scope`.

- [ ] **Step 3: Write `ProcessRole`.** Create `Sources/IrisKit/ProcessRole.swift`:

```swift
import os

/// #463 decision 14: what this process is, set once by `IrisMain` before anything else in its
/// branch runs. `AppState.shared` is legal only in `.app`, and only while this process holds its
/// home's store lock. Never set in the shared test process (only in an exit test's child), so a
/// test that reaches `.shared` crashes the suite: that is the alarm, and it has no disarm.
enum ProcessRole: Sendable, Equatable {
    case app, runJob, perf, bench, seed

    private static let storage = OSAllocatedUnfairLock<ProcessRole?>(initialState: nil)

    static var current: ProcessRole? { storage.withLock { $0 } }

    /// Once per process. Setting a different role later is a programming error.
    static func set(_ role: ProcessRole) {
        storage.withLock { current in
            precondition(current == nil || current == role,
                         "ProcessRole set twice: \(String(describing: current)), then \(role)")
            current = role
        }
    }

    static func mayUseSharedAppState(role: ProcessRole?, holdsStore: Bool) -> Bool {
        role == .app && holdsStore
    }
}
```

- [ ] **Step 4: Arm the trap.** In `AppState.swift`, replace `static let shared = AppState()` (`:375`) and its comment (`:370-374`) with:

```swift
    /// The app's one `AppState`. `ChatView` and `SubagentManager` MUST share one instance —
    /// SwiftUI evaluates a `@State`'s default expression on every view re-init, so
    /// `@State var state = AppState()` was constructing several AppStates. Referencing the
    /// singleton means the expression returns the same object every time.
    ///
    /// #463 decision 14: it traps unless this process is the app and holds its home's store lock.
    /// Everything else — `--run-job`, `--perf`, `--bench`, the seeder, every test — builds an
    /// `AppState(store:)` of its own. A second `AppState` over one store is the #463 bug.
    static var shared: AppState {
        guard ProcessRole.mayUseSharedAppState(role: ProcessRole.current,
                                               holdsStore: StoreLock.holds(IrisPaths.default.storeLockFile)) else {
            // Worded so the source scan (Review Focus 5) does not read it as a use.
            fatalError("the shared AppState was reached outside the app's own store holder (role: "
                       + "\(String(describing: ProcessRole.current))). Build an AppState(store:) instead (#463).")
        }
        return sharedInstance
    }
    private static let sharedInstance = AppState()
```

- [ ] **Step 5: Set the role in `IrisMain`.** In `IrisMain.run`, make `ProcessRole.set(…)` the first statement of each branch:
  - `ProcessRole.set(.perf)` before `switch perf` (`:14`)
  - `ProcessRole.set(.bench)` before `await BenchCLI.run` (`:22`)
  - `ProcessRole.set(.runJob)` before the `--run-job` comment (`:25`)
  - `ProcessRole.set(.seed)` before `exit(DevHomeSeeder.runCLI())` (`:43`)
  - `ProcessRole.set(.app)` before `IrisApp.main()` (`:45`)

- [ ] **Step 6: Move the two attachment tests off `.shared`.** In `AttachmentIntegrationTests.swift`, change both `func testAppStateSendMessageWithAttachments()` and `func testAutoTitleWithEmptyTextAndAttachment()` to `throws`, and replace `let appState = AppState.shared` (`:46`, `:83`) with:

```swift
        let appState = AppState(store: try ConversationStore.inMemory())
```

- [ ] **Step 7: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh SharedAppStateTrapTests` then `timeout 300 scripts/test-filter.sh AttachmentIntegrationTests`
Expected: PASS, 7 tests; then XCTest's `Executed N tests, with 0 failures` for the attachment class (Swift Testing legitimately prints 0 for an XCTest-only filter, and the script passes that run).

- [ ] **Step 8: Mutation checks.** Make each change alone, run `SharedAppStateTrapTests`, confirm the named test fails, then revert it.
  - Replace the `guard` in `shared` with `return sharedInstance`. Expected: `trapsWithNoRole`, `appWithoutTheLockTraps` and `runJobTraps` fail (the `AppState.shared` trap).
  - In `ToolExecutor.createSkill`, add `_ = await MainActor.run { AppState.shared }` before `await onSkillsChanged?()`. Expected: `runJobSkillWritesStayOnTheRunsEngine` fails (#489: no shared `AppState` in the CLI).
  - In `IrisEngine.executor`, delete the `onSkillsChanged` line. Expected: `runJobSkillWritesStayOnTheRunsEngine` fails.
  - Add `let _ = AppState.shared` to the body of any function in `RunJobURLHandling.swift`. Expected: `sharedAppearsOnlyInTheGUIShell` fails. Then try `let s: AppState = .shared` in `iris.swift`. Expected: it fails again.

- [ ] **Step 9: Run the full suite.** Any test that reaches `.shared` by another path now crashes the run (decision 14's alarm).

Run: `timeout 900 swift test 2>&1 | tee /tmp/463-pr1-full.log; echo "exit=$?"`
Expected: `exit=0`, `Test run with N tests … passed`, and `Executed N tests, with 0 failures`. If it crashes with `the shared AppState was reached outside the app's own store holder`, the stack trace names the path. Route that path to an injected `AppState`, as #489 did. Never add a disarm.

- [ ] **Step 10: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 11: Commit.**

```bash
git add Sources/IrisKit/ProcessRole.swift Sources/IrisKit/AppState.swift Sources/IrisKit/IrisMain.swift \
  Tests/irisTests/SharedAppStateTrapTests.swift Tests/irisTests/AttachmentIntegrationTests.swift
git commit -m "feat: AppState.shared traps outside the app's own store holder (#463 decision 14)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 9: invariant 9 sweep for PR 1, and open it

**Files:**
- Modify: `README.md:250-258`
- Modify: `docs/jobs.md:1146-1167`, `:1173`, `:1234-1237`
- Modify: `AGENTS.md:68-72`, `:89-90`
- Modify: `docs/specs/2026-10-09-agency-native-surfaces.md:157`, `:194`, `:255`, `:298`

**Interfaces:**
- Consumes: Tasks 1-8.
- Produces: docs that no longer contradict PR 1.

- [ ] **Step 1: Search, do not compose.** Run:

```bash
grep -rnE "GUILock|LaunchLock|guiLockFile|pid lock|lock file|delete (the|that) file|readable pid|do not start Iris while|takes it|five seconds|ten minutes|foreign (lock|store)|held the store at launch|Waiting for the other Iris|app was not running|GUI lock|keeps the lock|both would open|beside it on the same" \
  README.md AGENTS.md docs/jobs.md docs/specs/2026-10-09-agency-native-surfaces.md Sources/IrisKit
```

Read every hit. Steps 2-6 fix the ones `main` has today. Fix any other hit the same way. A hit in `docs/specs/2026-09-21-*` or `docs/superpowers/plans/*` is history and stays.

- [ ] **Step 2: `README.md:254-258`.** Replace from "It **refuses while another Iris process holds the store**" through "naming the pid that has it." with:

```markdown
It **refuses while another Iris process has this home** — the app, or another `--run-job` —
rather than writing behind a live `AppState`. The lock is a `flock(2)` on
`conversations.sqlite.lock` beside the store, held for the process's whole life and released by
the kernel however it exits, so a crash leaves nothing to clean up. Several `--run-job` started at
the same instant are told apart: one runs and the rest refuse, naming the pid (and job) that has
it. An app opened during a `--run-job` waits, in a window that names the run, and opens when the
run ends; a second app on the same home says "Iris is already running on this home" and quits.
```

- [ ] **Step 3: `docs/jobs.md:1146-1167`.** Replace the two paragraphs from "**It refuses while another Iris process holds the store**" through "will not delete somebody else's.)" with:

```markdown
**It refuses while another Iris process has this home**, `--dry-run` included — a dry run
writes nothing, but opening the store may *migrate* it, and a schema migration under a live app is
a worse failure than being told to try again. Whoever holds a `flock(2)` on
`conversations.sqlite.lock`, beside the store, is the only process that may open it: the app for
its whole session, a `--run-job` for its whole run, `--seed-dev-home` while it copies. The kernel
releases the lock however the holder exits, a crash or `kill -9` included, so nothing is ever left
behind to delete. The file also holds one line saying who has it, so the refusal names them: "the
Iris app (pid N) has this home open", or "another --run-job (pid N, job X) has this home". GRDB's
WAL would survive two writers, but `AppState` keeps conversation state in memory, so a CLI write
behind a live app desyncs the UI and the app then saves its stale copy over the top.

What that covers: a CLI run started while the app is up, a second CLI run started while the first
is going, and several `--run-job` launched at the same instant, of which exactly one proceeds and
the rest refuse. A harness may run them in parallel and read the refusals. **The app launched
during a CLI run waits**: every window shows "An iris --run-job is using this home (pid N, job X).
Iris will open when it finishes.", the menu bar shows an hourglass, and nothing opens the store
until the run ends. It never times out into opening the store. A harness batch keeps it waiting
until the batch ends, since each new run may claim the store before the app looks again. A second
app (or `swift run`) on the same home says "Iris is already running on this home" and quits. A
home whose filesystem cannot lock (some network or read-only mounts) is refused by everything,
naming the path and the error, rather than opened unlocked.
```

Change the exit-1 row (`:1173`) to:

```markdown
| `1` | Usage; no job with that id or name; `--dry-run` on a job that has no gate; a store that would not open; the app (or another `--run-job`, or the seeder) holding the store; a store lock that could not be taken (the path and error are named); or the job being deleted out from under the fire |
```

- [ ] **Step 4: `docs/jobs.md:1234-1237`.** Replace the paragraph "If the app is launched by a link while `iris --run-job` holds the store, … gives up after ten minutes." with:

```markdown
If a link launches Iris while `iris --run-job` holds the store, Iris does not open until that run
has finished: the menu bar shows an hourglass, and a small "Iris is waiting" window names the run.
The link is held, with up to 16 others, and fired once Iris has opened. Any beyond 16 are dropped
unread, and Iris says how many. If the store is held by another Iris *app* instead (for example
`swift run` beside `Iris Dev.app`), the app the link launched says "Iris is already running on
this home", says the link was not run, and quits.
```

- [ ] **Step 5: `AGENTS.md`.** Replace `:68-72` ("`Iris Dev.app` and `scripts/run-dev.sh` are still separate processes — … beside it on the same `~/.iris-dev`.") with:

```markdown
`Iris Dev.app` and `scripts/run-dev.sh` are still separate processes on one `~/.iris-dev`, and only
one of them can have it (#463): the second to launch says "Iris is already running on this home"
and quits. An `iris-dev://` link opened while `swift run` or `run-dev.sh` is running launches Iris
Dev.app (the bare binary registers no scheme), which refuses the same way and says the link was not
run.
```

Replace `:89-90` ("refuses outright if the installed app currently holds the release store's GUI lock (quit it and retry), if that lock file exists but doesn't hold a readable pid (delete it and retry), or if the") with:

```markdown
refuses outright if another Iris process holds the release store's lock (the installed app or a
`--run-job`: quit it and retry), or if the
```

- [ ] **Step 6: The D6 spec.** Append ` Superseded by \`docs/specs/2026-10-11-single-writer-store.md\`.` to the end of `docs/specs/2026-10-09-agency-native-surfaces.md:157` (decision 14's heading line), `:194`, `:255` and `:298`.

- [ ] **Step 7: Agent-visible strings.**
  - `interruptedByQuitReason`, which `get_job_run` returns, was changed in Task 7.
  - D2's notice and waiting lines were deleted in Task 6.
  - Run `grep -rn "held the store\|waits for it\|Waiting for the other" Sources/IrisKit`. Expected: no output.
  - Run `grep -n "interrupted" Sources/IrisKit/ToolExecutor.swift Sources/IrisKit/iris.swift | grep -i "description"`. Read each hit: a tool description that explains `interrupted` as "the app was not running" must now say "the Iris process running it ended". Finding none is fine.

- [ ] **Step 8: Full suite, warnings.** Run `timeout 900 swift test 2>&1 | tee /tmp/463-pr1-full.log` and `scripts/check-warnings.sh`. Expected: green on all three counts, and exit 0.

- [ ] **Step 9: Commit and open the PR.**

```bash
git add README.md AGENTS.md docs/jobs.md docs/specs/2026-10-09-agency-native-surfaces.md
git commit -m "docs: a single writer per store, in README, jobs.md and AGENTS.md (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
git push -u origin feat/463-single-writer
```

Open the PR against `main` (`gh api repos/sackheads/iris/pulls -f base=main -f head=feat/463-single-writer -f title="feat: a single writer per store (#463 PR 1)" -F body=@<file>`). The body lists decisions 1-15 and 18, the plan notes it relies on (1-7, 11), the test counts from Steps 8 and Task 3-8's filtered runs, and "GUI pass: Task 10, pending". It ends with the session's PR attribution lines.

### Task 10: GUI pass for PR 1 (`work`, under the lease)

Run on `work`'s laptop, on PR 1's branch, before the PR merges. Post each numbered result on the PR as the command and its output. Steps marked **(spend)** run a real model turn on the owner's account, which is expected on `work`. Only Iris Dev.app and the dev binary are launched, against `~/.iris-dev`.

**Before you start.**
- `export DD="$PWD/.dd-463"` (inside the worktree: LaunchServices refuses to route a scheme to an app under a temp directory, `-10814`, D6 Task 24). Step 12 deletes it.
- `LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`
- `HOLDER='cat ~/.iris-dev/conversations.sqlite.lock; echo'`
- `MT='stat -f "%m %z" ~/.iris-dev/conversations.sqlite'`. `-wal` is not included: an open GRDB store can touch it without writing rows.
- `TEXTS='osascript -e "tell application \"System Events\" to get value of every static text of every window of process \"Iris Dev\""'`
- `WINDOWS='osascript -e "tell application \"System Events\" to get name of every window of process \"Iris Dev\""'`
- `ITEM='osascript -e "tell application \"System Events\" to get description of every menu bar item of menu bar 2 of process \"Iris Dev\""'`
- `HOTKEY='osascript -e "tell application \"System Events\" to key code 49 using {command down, shift down, option down}"'`
- `ROW='sqlite3 ~/.iris-dev/conversations.sqlite "SELECT triggerKind, status, failureReason FROM job_runs WHERE jobName = '"'"'463-nap'"'"' ORDER BY startedAt DESC LIMIT 1"'`
- `DENY='sleep 1; pgrep -x SecurityAgent >/dev/null && /tmp/irisgui/ui click 930 413; sleep 1; pgrep -x SecurityAgent >/dev/null && echo prompt-still-up || echo no-prompt'`. A freshly signed Iris Dev raises a Keychain prompt, and the prompt blocks until it is answered. ≈930,413 pt is its Deny button on `work`'s display. The command clicks only when SecurityAgent is up, so it never lands on the waiting panel or the refusal alert.
  - Under the gate, the Keychain read probably moves from launch to `openStore()` (`ConfigManager.swift:422` is first touched there; unverified).
  - So run `eval $DENY` after every launch (`open "$APP"`, `open "$LINK"`, the bare `$CLI &` GUI), **and again right after each gate opens** (each `cli-exit=`, `exit=` or `kill -9` below, before the "within N s" checks), and after any `$CLI --run-job` start.
  - Expected output: `no-prompt`.
- `SETTINGS='/tmp/irisgui/ui cmdkey 43'`: Cmd-, through `work`'s CGEvent helper (key code 43 is the comma). System Events keystrokes do not reliably reach SwiftUI there.
- `PD=com.bnaylor.iris.dev` and `PKEYS="PRIMARY_PROVIDER ANTHROPIC_AUTH_MODE ANTHROPIC_VERTEX_PROJECT ANTHROPIC_VERTEX_LOCATION"`.

1. `pgrep -fl "Iris Dev|\.build/debug/iris"`. Expected: no output. Quit anything listed.
2. `python3 ~/.claude/skills/gui-test-lease/lease.py acquire --purpose "iris: #463 PR 1 single writer" --minutes 90 --on-behalf-of <requesting peer>`. Expected: exit 0.
3. **Build into a non-temp dir and clear stale registrations.**
   - `scripts/build-app.sh Debug "$DD"`. Note the printed `.app` path as `APP`. Then `scripts/sign.sh "$APP"`.
   - `swift build && scripts/sign.sh .build/debug/iris`, and `export CLI="$PWD/.build/debug/iris"`.
   - `$LSR -dump | awk '/^path:/ && /Iris Dev\.app/ {sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); print}' | sort -u > "$DD/registered.txt"; cat "$DD/registered.txt"`.
   - Then `while read -r p; do [[ "$p" == "$APP" ]] || $LSR -u "$p"; done < "$DD/registered.txt"; $LSR -f "$APP"`.
   - Re-run the dump line. Expected: exactly one line, `$APP`.
3b. **Provider: Claude on Vertex in the dev domain.** Job runs need it, because Gemini refuses job prompts (#475). With nothing running:

   ```sh
   VPROJ=gke-claude-dev; VLOC=global
   for k in $=PKEYS; do defaults read $PD $k > "$DD/prev-$k" 2>/dev/null || rm -f "$DD/prev-$k"; done
   defaults write $PD PRIMARY_PROVIDER Anthropic
   defaults write $PD ANTHROPIC_AUTH_MODE "Vertex AI (ADC)"
   defaults write $PD ANTHROPIC_VERTEX_PROJECT "$VPROJ"
   defaults write $PD ANTHROPIC_VERTEX_LOCATION "$VLOC"
   for k in $=PKEYS; do echo "$k=$(defaults read $PD $k)"; done
   ```

   Expected: the four values just written. `gcloud auth application-default print-access-token >/dev/null && echo adc-ok` prints `adc-ok`.
4. **(spend) Setup.**
   - `open "$APP"`, then `eval $DENY`. Ask: "Schedule a mutating job named 463-nap every 12 hours with a grant on `$DD/nap` (read-write, no network): run the shell command `sleep 90` with run_command, then reply done." Approve the grant. Then `mkdir -p "$DD/nap"`.
   - Type `/jobs url 463-nap on`, Copy the link, Done, and `export LINK='<the link>'`.
   - Quit Iris Dev (Cmd-Q).
   - Run `container system status`. Expected: running. If not, record "no VM: 463-nap cannot run" and stop the pass at step 12.
5. **Spec check 1: a Dock launch during a run.**
   - `( $CLI --run-job 463-nap; echo "cli-exit=$?" ) &`, then wait until `eval $HOLDER` prints `{"job":"463-nap","kind":"run-job","pid":N}`.
   - `BEFORE=$(eval $MT)`, then `open "$APP"`, `eval $DENY`, and wait 5 s.
   - `eval $TEXTS`. Expected: contains `An iris --run-job is using this home (pid N, job 463-nap). Iris will open when it finishes.`
   - `eval $ITEM`. Expected: contains `Iris is waiting`.
   - Every 10 s until the CLI exits: `[ "$(eval $MT)" = "$BEFORE" ] && echo same`. Expected: `same` each time.
   - After `cli-exit=0`, within 3 s: `eval $TEXTS` no longer contains `is using this home`, `eval $ROW` is `manual|completed|`, and `sqlite3 ~/.iris-dev/conversations.sqlite "SELECT count(*) FROM messages WHERE payload LIKE '%jobName%463-nap%'"` is at least 1 (the card).
6. **Spec check 3: the hotkey, Settings, the Run Log and Quit, while waiting.**
   - Quit Iris Dev. Start the CLI as in step 5. Once it holds, `open "$APP"`, `eval $DENY`, and take `BEFORE=$(eval $MT)`.
   - `eval $HOTKEY`, then `eval $WINDOWS`. Expected: no crash (`pgrep -fl "Iris Dev"` still lists it), and the windows listed.
   - `eval $SETTINGS`, then `eval $WINDOWS` and `eval $TEXTS`. Expected: a settings window, showing the waiting sentence.
   - `osascript -e 'tell application "System Events" to click menu item "Run Log" of menu "Window" of menu bar 1 of process "Iris Dev"'`, then `eval $WINDOWS` and `eval $TEXTS`. Expected: "Run Log" is listed, showing the waiting sentence.
   - `[ "$(eval $MT)" = "$BEFORE" ] && echo same`. Expected: `same`.
   - **Review Focus 2:** take `REPORTS=$(ls ~/Library/Logs/DiagnosticReports | grep -c "Iris Dev")`. Then `osascript -e 'tell application "System Events" to click menu bar item 1 of menu bar 2 of process "Iris Dev"'` and choose Quit Iris from that menu. Within 3 s:
     - `pgrep -fl "Iris Dev"` is empty.
     - `eval $HOLDER` still shows the CLI's payload (the quitting app did not vacate it).
     - The `ls … | grep -c` count equals `$REPORTS`: no crash report.
     - The CLI is still running.
   - Wait for `cli-exit=0`.
7. **Spec check 2: a cold start from a link during a run.**
   - `( $CLI --run-job 463-nap; echo "cli-exit=$?" ) &`. Once it holds, `open "$LINK"`, `eval $DENY`, and wait 5 s.
   - `pgrep -fl "Iris Dev"`. Expected: running.
   - `eval $WINDOWS`. Expected: exactly `Iris is waiting`.
   - `eval $ITEM`. Expected: contains `Iris is waiting`.
   - After `cli-exit=0`, within 3 s: `eval $WINDOWS` no longer lists `Iris is waiting`.
   - Within 120 s more: `sqlite3 ~/.iris-dev/conversations.sqlite "SELECT triggerKind, status FROM job_runs WHERE jobName = '463-nap' ORDER BY startedAt DESC LIMIT 2"` is `url|completed` then `manual|completed`, and the step-5 card count has grown by 2.
8. **Spec check 5: `--run-job` with the app open.** With Iris Dev open (from step 7), run `$CLI --run-job 463-nap; echo "exit=$?"`. Expected: stderr contains `the Iris app (pid N) has this home open`, and `exit=1`.
9. **Spec check 4: two GUIs on one home, both orders, and a link.**
   - (a) With Iris Dev open, `$CLI &` (the bare binary's GUI) and wait 5 s. `osascript -e 'tell application "System Events" to get value of every static text of every window of process "iris"'`. Expected: contains `Iris is already running on this home`. Click Quit (`osascript -e 'tell application "System Events" to click button "Quit" of window 1 of process "iris"'`). Expected: `pgrep -fl "\.build/debug/iris"` is empty, and Iris Dev is frontmost or was offered activation (macOS 14's cooperative activation may refuse `NSRunningApplication.activate()`; record which).
   - (b) Quit Iris Dev. `$CLI &`, wait until its window opens, then `open "$APP"`. Expected: Iris Dev shows the same alert; after Quit, `pgrep -fl "Iris Dev"` is empty and `$CLI`'s GUI is still running.
   - (c) With the bare binary still up, note `N=$(sqlite3 ~/.iris-dev/conversations.sqlite "SELECT count(*) FROM job_runs WHERE jobName = '463-nap'")`. Run `open "$LINK"`. Expected: Iris Dev's alert text also contains `The link you opened was not run.`, and after Quit the count is still `N` 10 s later. Quit the bare binary.
10. **Spec check 7: SIGKILL the CLI while the app waits.**
    - `$CLI --run-job 463-nap & CLIPID=$!`. Once it holds, `open "$APP"`, `eval $DENY`, and wait 15 s (the turn is inside `sleep 90`).
    - `kill -9 $CLIPID`.
    - Within 2 s: `eval $TEXTS` no longer contains `is using this home`.
    - `eval $ROW`. Expected: `manual|interrupted|the Iris process running it ended`.
    - `eval $DENY` (the gate just opened). Then `container list --all | grep -c "$SESSION"`, where `SESSION` is the session name `container list --all | grep iris-` showed before the `kill -9`. Expected: `0` (`reapOrphans` in `openStore()` took the dead CLI's container).
11. **The lock file is never replaced.** `stat -f %i ~/.iris-dev/conversations.sqlite.lock` printed at step 4 and now. Expected: the same inode.
12. **Teardown.** In Iris Dev: `/jobs delete 463-nap`. Quit. Restore the provider settings, before `$DD` goes: `for k in $=PKEYS; do if [ -f "$DD/prev-$k" ]; then defaults write $PD $k "$(cat "$DD/prev-$k")"; else defaults delete $PD $k 2>/dev/null; fi; done`. Then `$LSR -u "$APP"`, `rm -rf "$DD"`, and `python3 ~/.claude/skills/gui-test-lease/lease.py release`. Expected: exit 0.

---

## PR 2: the CLI's clean stop

Cut after PR 1 merges: `git fetch origin && git switch -c feat/463-cli-clean-stop origin/main`, in a fresh worktree. Never base it on PR 1's branch.

### Task 11: `LiveProcessGroups`, the registry of live groups

**Files:**
- Create: `Sources/IrisKit/LiveProcessGroups.swift`
- Modify: `Sources/IrisKit/ProcessGroupRunner.swift:21` (init), `:103-114` (`capture`), `:116-124` (`killNow` beside `terminate`), `:218` (register), `:320-334` (unregister)
- Create: `Tests/irisTests/LiveProcessGroupsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `final class LiveProcessGroups: @unchecked Sendable`, with `static let shared`, `add(_:)`, `remove(_:)`, `count`, `terminateAll()`, `killAll()`, `waitUntilEmpty(within:) -> Bool`
  - `ProcessGroupRunner.init(registry: LiveProcessGroups = .shared)` and `func killNow()`
  - `ProcessGroupRunner.capture(…, registry: LiveProcessGroups = .shared)`

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/LiveProcessGroupsTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decision 17: every `ProcessGroupRunner` group is recorded at spawn and dropped once its
/// leader is reaped, so a stopping CLI can end them. Each test has a registry of its own: the
/// shared one belongs to whatever else is running in this process (invariant 7).
@Suite("LiveProcessGroups (#463)", .timeLimit(.minutes(1)))
struct LiveProcessGroupsTests {
    private func spawn(_ registry: LiveProcessGroups, _ script: String)
        async throws -> (ProcessGroupRunner, Task<Result<ProcessGroupRunner.Output, Error>, Never>) {
        let runner = ProcessGroupRunner(registry: registry)
        let task = Task { await runner.run(executable: "/bin/sh", arguments: ["-c", script], environment: nil, currentDirectory: nil) }
        var waited = 0
        while runner.processIdentifier == 0, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        try #require(runner.processIdentifier > 0, "spawned")
        return (runner, task)
    }

    @Test("a running group is registered, and leaves the registry when it finishes")
    func registeredWhileRunning() async throws {
        let registry = LiveProcessGroups()
        // Long enough that no load can reap it before the count is read; ended by the test.
        let (runner, task) = try await spawn(registry, "sleep 30")
        #expect(registry.count == 1)
        runner.terminate()
        _ = try await value(of: task, within: 10)
        #expect(registry.count == 0)
    }

    @Test("waitUntilEmpty returns true once the groups drain, and false at its bound while one lives")
    func waitUntilEmptyIsBounded() async throws {
        let registry = LiveProcessGroups()
        #expect(registry.waitUntilEmpty(within: 0.1), "an empty registry is already drained")
        let (runner, task) = try await spawn(registry, "trap '' TERM; sleep 30")
        let started = Date()
        #expect(!registry.waitUntilEmpty(within: 0.3))
        #expect(Date().timeIntervalSince(started) >= 0.3)
        runner.terminate()   // SIGTERM is ignored, so this drains at the SIGKILL rung, 2 s on
        #expect(registry.waitUntilEmpty(within: 5))
        _ = try await value(of: task, within: 10)
    }

    @Test("terminateAll ends every group with SIGTERM, through each runner's own ladder")
    func terminateAllEndsThemAll() async throws {
        let registry = LiveProcessGroups()
        let (_, a) = try await spawn(registry, "sleep 30")
        let (_, b) = try await spawn(registry, "sleep 30")
        registry.terminateAll()
        for task in [a, b] {
            guard case .success(let out) = try await value(of: task, within: 10) else { Issue.record("spawn failed"); continue }
            #expect(out.status == 128 + SIGTERM)
            #expect(out.killed)
        }
        #expect(registry.count == 0)
    }

    @Test("terminateAll reaches a group that ignores SIGTERM with the SIGKILL rung")
    func terminateAllEscalates() async throws {
        let registry = LiveProcessGroups()
        let (_, task) = try await spawn(registry, "trap '' TERM; sleep 30")
        registry.terminateAll()
        guard case .success(let out) = try await value(of: task, within: 10) else { Issue.record("spawn failed"); return }
        #expect(out.status == 128 + SIGKILL)
    }

    @Test("killAll SIGKILLs every group before it returns")
    func killAllIsImmediate() async throws {
        let registry = LiveProcessGroups()
        let (runner, task) = try await spawn(registry, "trap '' TERM; sleep 30")
        let pid = runner.processIdentifier
        registry.killAll()
        guard case .success(let out) = try await value(of: task, within: 5) else { Issue.record("spawn failed"); return }
        #expect(out.status == 128 + SIGKILL)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh LiveProcessGroupsTests`
Expected: the build fails with `cannot find 'LiveProcessGroups' in scope`.

- [ ] **Step 3: Write the registry.** Create `Sources/IrisKit/LiveProcessGroups.swift`:

```swift
import Foundation

/// #463 decision 17: every `ProcessGroupRunner` group this process has spawned and not yet
/// reaped, so a CLI that is stopping can end them rather than leave them running after it.
///
/// It holds runners, not group ids: a signal always goes through the runner's own queue, which
/// never signals once it has reaped its leader, so nothing here can reach a reused group id.
/// Known gap: a background job that redirected its output, which invariant 4 deliberately leaves
/// running, leaves this registry when its leader is reaped. Nothing ends it on exit.
final class LiveProcessGroups: @unchecked Sendable {
    static let shared = LiveProcessGroups()

    private let lock = NSLock()
    private var runners: [ObjectIdentifier: ProcessGroupRunner] = [:]

    func add(_ runner: ProcessGroupRunner) { lock.withLock { runners[ObjectIdentifier(runner)] = runner } }
    func remove(_ runner: ProcessGroupRunner) { lock.withLock { _ = runners.removeValue(forKey: ObjectIdentifier(runner)) } }
    var count: Int { lock.withLock { runners.count } }

    /// SIGTERM to every group, then SIGKILL after `ProcessGroupRunner.terminateGraceSeconds`:
    /// each runner's ladder, on its own dispatch queue (invariant 4). Returns at once.
    func terminateAll() { snapshot().forEach { $0.terminate() } }

    /// SIGKILL to every group, now, for an exit that will not wait. Returns once each is sent.
    func killAll() { snapshot().forEach { $0.killNow() } }

    /// Blocks until every group has been reaped, or `seconds` pass: what a stopping CLI waits on
    /// before `_exit`, so a group the SIGTERM did not end gets its SIGKILL rung first. Polls with
    /// `usleep` on the caller's thread, never the cooperative pool (invariant 4). True when drained.
    func waitUntilEmpty(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while count > 0 {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }

    /// Copied out first: a runner finishing calls `remove` from its queue, and `killNow` waits on
    /// that queue, so holding this lock across either would deadlock.
    private func snapshot() -> [ProcessGroupRunner] { lock.withLock { Array(runners.values) } }
}
```

- [ ] **Step 4: Register in the runner.** In `ProcessGroupRunner.swift`:
  - After `private let queue = …` (`:43`), add:

```swift
    private let registry: LiveProcessGroups

    init(registry: LiveProcessGroups = .shared) { self.registry = registry }
```

  - In `launch`, after `pid = child` (`:218`), add `registry.add(self)`.
  - In `finishIfDone`, after the `waitpid` loop (`:328`), add `registry.remove(self)   // reaped, and the ladder is over`.
  - Below `terminate()` (`:124`), add:

```swift
    /// SIGKILL to the whole group now, synchronously, for a process about to `_exit` (#463).
    /// Through the queue, so it never signals a group whose leader was reaped. Never call it
    /// from this runner's own queue.
    func killNow() {
        queue.sync { signalGroup(SIGKILL) }
    }
```

  - Give `capture` a `registry: LiveProcessGroups = .shared` parameter after `onKilled`, and build its runner with `ProcessGroupRunner(registry: registry)`.

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh LiveProcessGroupsTests`, then `RunCommandProcessGroupTests`, then `SpawnerProcessGroupTests`
Expected: PASS, 5 tests, then both existing suites at `main`'s counts.

- [ ] **Step 6: Mutation check.** Delete `registry.add(self)`. Expected: `registeredWhileRunning`, `terminateAllEndsThemAll` and `killAllIsImmediate` fail. Revert. Then delete `registry.remove(self)`. Expected: `registeredWhileRunning` fails. Revert.

- [ ] **Step 7: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 8: Commit.**

```bash
git add Sources/IrisKit/LiveProcessGroups.swift Sources/IrisKit/ProcessGroupRunner.swift Tests/irisTests/LiveProcessGroupsTests.swift
git commit -m "feat: LiveProcessGroups, every ProcessGroupRunner group until it is reaped (#463 decision 17)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 12: `LiveContainerNames`, so an exiting CLI can delete its containers

The coordinator ruled on #490 that a second Ctrl-C also deletes the run's containers (plan note 15). This task builds the names box and the parallel, bounded delete. Task 14 calls it.

**Files:**
- Create: `Sources/IrisKit/LiveContainerNames.swift`
- Modify: `Sources/IrisKit/BlockingSpawn.swift:21-72` (`newGroup:` on `run` and `detached`)
- Modify: `Sources/IrisKit/SandboxSessionManager.swift:50-60` (init), `:325-345` (`attemptCreate` records the name), and every `runtime.remove(name:)` / `removeIgnoringCancellation(name:)` in the file (`:157`, `:216`, `:323`, and the close path): they go through a new `removeContainer(_:)` that also drops the name
- Modify: `Sources/IrisKit/GateEvaluator.swift:530-543` (`GateContainerRegistry` records and drops)
- Modify: `Sources/IrisKit/HookManager.swift:268-275` (`EphemeralContainerRegistry` records and drops)
- Create: `Tests/irisTests/LiveContainerNamesTests.swift`
- Modify: `Tests/irisTests/SandboxClosedSessionTests.swift` (one test)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `final class LiveContainerNames: @unchecked Sendable`, with `static let shared`, `add(_:)`, `remove(_:)`, `names: Set<String>`, and `deleteAll(within:command:) -> Int`
  - `BlockingSpawn.run(_:_:timeoutSeconds:newGroup:)` and `BlockingSpawn.detached(_:_:timeoutSeconds:newGroup:then:)`, with `newGroup: Bool = false`
  - `SandboxSessionManager.init(…, live: LiveContainerNames = .shared)`
  - `GateContainerRegistry.init(live: LiveContainerNames = .shared)` and `EphemeralContainerRegistry.init(live: LiveContainerNames = .shared)`

- [ ] **Step 1: Write the failing tests.** Create `Tests/irisTests/LiveContainerNamesTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463, the coordinator's ruling on #490: an exiting CLI deletes the containers it created, from
/// a lock-protected box (no actor hop), in parallel, each in a process group of its own, bounded
/// in all. A stub stands in for the `container` binary, run through `/bin/sh` so no freshly
/// written executable meets the first-exec check. Every test has its own box (invariant 7).
@Suite("LiveContainerNames (#463)", .timeLimit(.minutes(1)))
final class LiveContainerNamesTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-463-names-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    /// A `container` stand-in: logs `delete --force <name>`, its own pid and its process group,
    /// then `exec`s `sleep`, so the logged pid *is* the sleep and a kill at the bound leaves no orphan.
    private func stub(sleeping seconds: Double) throws -> (script: URL, log: URL) {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let log = base.appendingPathComponent("log-\(UUID().uuidString)")
        let script = base.appendingPathComponent("container-\(UUID().uuidString).sh")
        try """
        echo "$* pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d ' ')" >> '\(log.path)'
        exec sleep \(seconds)
        """.write(to: script, atomically: true, encoding: .utf8)
        return (script, log)
    }

    private func lines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test("names are recorded and dropped")
    func recordsAndDrops() {
        let live = LiveContainerNames()
        live.add("iris-a")
        live.add("iris-b")
        live.remove("iris-a")
        #expect(live.names == ["iris-b"])
    }

    @Test("every recorded container is deleted, in parallel, each in a process group of its own")
    func deletesInParallelInTheirOwnGroups() async throws {
        let live = LiveContainerNames()
        for name in ["iris-a", "iris-b", "iris-c"] { live.add(name) }
        let (script, log) = try stub(sleeping: 1)
        let started = Date()
        let task = Task.detached {
            live.deleteAll(within: 5) { name in ("/bin/sh", [script.path, "delete", "--force", name]) }
        }
        let finished = try await value(of: task, within: 15)
        #expect(finished == 3)
        #expect(Date().timeIntervalSince(started) < 2.5, "three 1 s deletes in parallel, not 3 s in series")
        let logged = lines(log)
        #expect(Set(logged.compactMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) })
            == ["iris-a", "iris-b", "iris-c"])
        for line in logged {
            let fields = Dictionary(uniqueKeysWithValues: line.split(separator: " ").compactMap { part -> (String, String)? in
                let kv = part.split(separator: "=")
                return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            })
            #expect(fields["pid"] == fields["pgid"], "SETPGROUP: a terminal's Ctrl-C cannot reach the delete: \(line)")
        }
        #expect(live.names.isEmpty, "a delete that succeeded drops its name")
    }

    @Test("a delete that hangs is cut off at the bound")
    func hungDeleteIsBounded() async throws {
        let live = LiveContainerNames()
        live.add("iris-stuck")
        let (script, log) = try stub(sleeping: 30)
        let started = Date()
        let task = Task.detached {
            live.deleteAll(within: 0.5) { name in ("/bin/sh", [script.path, "delete", "--force", name]) }
        }
        _ = try await value(of: task, within: 10)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(live.names == ["iris-stuck"], "not deleted, so still recorded")
        // The helper itself was SIGKILLed at the bound, not merely stopped being waited for.
        let pid = try #require(lines(log).first?.split(separator: " ").first { $0.hasPrefix("pid=") }
            .flatMap { Int32($0.dropFirst(4)) })
        var gone = false
        for _ in 0..<200 {
            if kill(pid, 0) == -1 && errno == ESRCH { gone = true; break }
            usleep(10_000)
        }
        #expect(gone, "BlockingSpawn's timeout killed and reaped the hung delete")
    }

    @Test("with no container binary, or nothing recorded, nothing is spawned")
    func nothingToDelete() {
        #expect(LiveContainerNames().deleteAll(within: 1) { _ in ("/usr/bin/false", []) } == 0)
    }

    @Test("the gate and one-off registries record their names in the box")
    func registriesRecord() async {
        let live = LiveContainerNames()
        let gates = GateContainerRegistry(live: live)
        let ephemeral = EphemeralContainerRegistry(live: live)
        await gates.register("iris-gate-x")
        await ephemeral.register("iris-hook-y")
        #expect(live.names == ["iris-gate-x", "iris-hook-y"])
        await gates.unregister("iris-gate-x")
        await ephemeral.unregister("iris-hook-y")
        #expect(live.names.isEmpty)
    }
}
```

In `SandboxClosedSessionTests.swift`, add:

```swift
    @Test("#463: a session's container name is recorded at create and dropped at close")
    func sessionNameIsRecorded() async {
        let live = LiveContainerNames()
        let m = SandboxSessionManager(runtime: MockRuntime(), image: { "ubuntu:latest" }, live: live)
        let id = UUID()
        _ = await m.run(command: "a", conversationId: id, workspace: "/ws")
        #expect(live.names == ["iris-\(id.uuidString.lowercased())"])
        await m.closeSession(id)
        #expect(live.names.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh LiveContainerNamesTests`
Expected: the build fails with `cannot find 'LiveContainerNames' in scope`.

- [ ] **Step 3: A process group of its own for `BlockingSpawn`.** In `BlockingSpawn.run`, add `newGroup: Bool = false` after `timeoutSeconds`, and replace the `setflags` line with:

```swift
        var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        // A group of its own, so a terminal's Ctrl-C (sent to the CLI's foreground group) does
        // not end the helper the CLI is waiting on (#463).
        if newGroup { flags |= POSIX_SPAWN_SETPGROUP }
        posix_spawnattr_setflags(&attr, Int16(flags))
        if newGroup { posix_spawnattr_setpgroup(&attr, 0) }
```

Give `detached` the same parameter and pass it through.

- [ ] **Step 4: Write the box.** Create `Sources/IrisKit/LiveContainerNames.swift`:

```swift
import Foundation

/// #463, the coordinator's ruling on #490: the containers this process created and has not
/// removed — its sessions, gate containers and one-offs — for a CLI that is exiting at once.
///
/// A lock-protected set, not an actor: the signal path reads it synchronously, with no hop onto a
/// cooperative pool that may be starved (#372). It names only what this process made, never a
/// sweep by `SandboxSessionManager.namePrefix`, which `~/.iris` and `~/.iris-dev` share.
final class LiveContainerNames: @unchecked Sendable {
    static let shared = LiveContainerNames()

    private let lock = NSLock()
    private var set: Set<String> = []

    func add(_ name: String) { lock.withLock { _ = set.insert(name) } }
    func remove(_ name: String) { lock.withLock { _ = set.remove(name) } }
    var names: Set<String> { lock.withLock { set } }

    /// Deletes every recorded container in parallel, each through `BlockingSpawn` in a process
    /// group of its own, and returns within `seconds` (plus a moment) whatever they are doing: a
    /// helper still running at the bound is SIGKILLed by `BlockingSpawn`. A delete that exits 0
    /// drops its name. Returns how many exited 0. `command` is a seam for the `container` binary;
    /// nil means the installed one, and none installed means nothing to do.
    @discardableResult
    func deleteAll(within seconds: TimeInterval,
                   command: ((String) -> (path: String, arguments: [String]))? = nil) -> Int {
        let targets = names
        guard !targets.isEmpty else { return 0 }
        let build: (String) -> (path: String, arguments: [String])
        if let command {
            build = command
        } else if let binary = SandboxingManager.resolveBinaryPath() {
            build = { (binary, ["delete", "--force", $0]) }
        } else {
            return 0
        }
        let group = DispatchGroup()
        let deleted = OSAllocatedUnfairLock(initialState: 0)
        for name in targets {
            let (path, arguments) = build(name)
            group.enter()
            BlockingSpawn.detached(path, arguments, timeoutSeconds: seconds, newGroup: true) { status in
                if status == 0 {
                    self.remove(name)
                    deleted.withLock { $0 += 1 }
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + seconds + 0.5)
        return deleted.withLock { $0 }
    }
}
```

(`import os` for `OSAllocatedUnfairLock`.)

- [ ] **Step 5: Record where containers are made.**
  - `SandboxSessionManager`: add a stored property and init parameter `live: LiveContainerNames = .shared` (last). In `attemptCreate`, before the first `createDetached`, add `live.add(name(for: id))`. Add the helper below, and route every `runtime.remove(name:)` and `runtime.removeIgnoringCancellation(name:)` in this file through it (`reapOrphans` included: removing a name that is not recorded is a no-op):

```swift
    /// Removes a container and drops its name from the exit-now box (#463).
    private func removeContainer(_ name: String, ignoringCancellation: Bool = false) async {
        if ignoringCancellation { await runtime.removeIgnoringCancellation(name: name) }
        else { await runtime.remove(name: name) }
        live.remove(name)
    }
```

  - `GateContainerRegistry` (`GateEvaluator.swift:530`) and `EphemeralContainerRegistry` (`HookManager.swift:268`): each gets `private let live: LiveContainerNames` and `init(live: LiveContainerNames = .shared) { self.live = live }`. `register` also calls `live.add(name)`, and `unregister` calls `live.remove(name)`. Their `static let shared` keep the default.

- [ ] **Step 6: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh LiveContainerNamesTests`, then `SandboxClosedSessionTests`, then `BlockingSpawnTests`
Expected: PASS, 5 tests; then `main`'s closed-session count plus 1; then `main`'s `BlockingSpawnTests` count.

- [ ] **Step 7: Mutation checks.** Make each change alone, run `LiveContainerNamesTests`, confirm the named test fails, then revert it.
  - Pass `newGroup: false` in `deleteAll`. Expected: `deletesInParallelInTheirOwnGroups` fails on `pid == pgid`.
  - Replace `BlockingSpawn.detached(…)` with a synchronous `BlockingSpawn.run(…)` in the loop (serial deletes). Expected: `deletesInParallelInTheirOwnGroups` fails on the 2.5 s bound.
  - Drop `timeoutSeconds: seconds`. Expected: `hungDeleteIsBounded` fails on `gone` (the 0.5 s wait still returns, so it is the stub's pid that tells: it is still alive).
  - Delete `live.add(name(for: id))` in `attemptCreate`. Expected: `SandboxClosedSessionTests/sessionNameIsRecorded` fails.

- [ ] **Step 8: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 9: Commit.**

```bash
git add Sources/IrisKit/LiveContainerNames.swift Sources/IrisKit/BlockingSpawn.swift Sources/IrisKit/SandboxSessionManager.swift \
  Sources/IrisKit/GateEvaluator.swift Sources/IrisKit/HookManager.swift \
  Tests/irisTests/LiveContainerNamesTests.swift Tests/irisTests/SandboxClosedSessionTests.swift
git commit -m "feat: LiveContainerNames, so an exiting CLI deletes the containers it made (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 13: `RunStop`, a third claimant on a run's ending

**Files:**
- Create: `Sources/IrisKit/RunStop.swift`
- Modify: `Sources/IrisKit/JobRunner.swift:140-183` (init), `:1026-1033` (arm at the top of `run`), `:1147-1232` (the ending, the grace, the status), `:2036-2077` (`DeadlineFlag`)
- Modify: `Sources/IrisKit/iris.swift:3234-3242` (`jobRunner(stop:)`)
- Modify: `Tests/irisTests/JobRetryTests.swift:701-717` (`DeadlineFlag` tests), plus the new tests

**Interfaces:**
- Consumes: Task 11's `LiveProcessGroups.shared.terminateAll()` (default).
- Produces:
  - `final class RunStop: @unchecked Sendable`, with:
    - `enum Answer { case exitNow, runWillStop, ignored }`
    - `grace: TimeInterval`, `teardown: TimeInterval`, `terminateGroups: @Sendable () -> Void`, `wasRequested: Bool`
    - `init(grace: TimeInterval = 15, teardown: TimeInterval = 5, terminateGroups: … = { LiveProcessGroups.shared.terminateAll() })`
    - `request(reason:) -> Answer`, `arm() -> String?`, `disarm()`, `wait() async -> String?`
    - `static func reason(for signal: Int32) -> String`, `static func signalName(_:) -> String`
  - `DeadlineFlag.Ending` (`.turn`, `.deadline`, `.signal(String)`), `claim(_ how: Ending) -> Bool`, `wait() async -> Ending`
  - `JobRunner.init(…, stop: RunStop? = nil)`
  - `IrisEngine.jobRunner(stop: RunStop? = nil) async -> JobRunner?`
  - `static func JobRunner.returnsWithin(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async -> Bool`

- [ ] **Step 1: Write the failing tests.** In `JobRetryTests.swift`, rewrite the two `DeadlineFlag` tests (`:701-717`) to:

```swift
    @Test("the turn, the deadline and a stop race for one claim, and exactly one of them wins it")
    func theEndingIsClaimedOnce() async {
        let ending = DeadlineFlag()
        #expect(await ending.claim(.turn) == true)
        #expect(await ending.claim(.deadline) == false, "the loser gets no say in how the run ended")
        #expect(await ending.claim(.signal("stopped by a signal (SIGINT)")) == false)
        #expect(await ending.wait() == .turn, "and the run hears the winner's answer, not the loser's")
    }

    @Test("the run waits for the claim, and whichever claims it is what releases the wait")
    func theRunWaitsForWhicheverClaimsTheEnding() async throws {
        let ending = DeadlineFlag()
        let waiting = Task { await ending.wait() }
        #expect(await ending.claim(.signal("stopped by a signal (SIGTERM)")) == true)
        #expect(try await value(of: waiting) == .signal("stopped by a signal (SIGTERM)"))
    }
```

Then add, in a new `// MARK: The CLI's stop (#463 decision 16)` section of `JobRetryTests`:

```swift
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test("a stop mid-turn cancels it, ends the groups, and closes the row stopped, with a card")
    func stopMidTurn() async throws {
        let client = GatedClient(response: textResponse("tick"))
        let (store, state, engine) = try harness([], client: client)
        let j = job(timeoutSeconds: Self.heldTimeout)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let terminated = Count()
        let stop = RunStop(grace: 5, terminateGroups: { terminated.bump() })
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               activity: RecordingActivity(), stop: stop)
        let fire = Task { await runner.fire(job: j, origin: .manual) }
        defer { client.release() }
        try #require(await client.calls.reach(1), "the turn reached the model")
        #expect(stop.request(reason: RunStop.reason(for: SIGINT)) == .runWillStop)
        try #require(await finished(fire) != nil, "the stop ended the run")

        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .interrupted)
        #expect(run.failureReason == "stopped by a signal (SIGINT)")
        #expect(terminated.value == 1)
        #expect(card(state)?.runId == run.id, "the card was delivered")
    }

    /// The turn parks in `WedgedClient`'s stream (this file, `:459-524`), where cancellation cannot
    /// reach it. A client parked in `generateContent` would not do: the engine reads it through
    /// `LLMStreamEvent.replay`, whose `next()` is cancellable, so the turn would come straight back
    /// and the grace would never be exercised (the trap `WedgedClient`'s own comment records).
    @Test("a turn that ignores cancellation is abandoned after the grace, and the row still closes")
    func stopAbandonsAStubbornTurn() async throws {
        let client = WedgedClient(response: textResponse("late"))
        let (store, state, engine) = try harness([], client: client, streamResponses: true)
        let j = job(timeoutSeconds: Self.heldTimeout)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let stop = RunStop(grace: 0.3, terminateGroups: {})
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               activity: RecordingActivity(), stop: stop)
        let fire = Task { await runner.fire(job: j, origin: .manual) }
        defer { client.releaseAll() }
        try #require(await client.parks.reach(1), "the turn is parked in the stream")
        let asked = Date()
        _ = stop.request(reason: RunStop.reason(for: SIGTERM))
        try #require(await finished(fire, within: 10) != nil, "the grace bounded the wait")
        #expect(Date().timeIntervalSince(asked) >= 0.3)
        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .interrupted)
        #expect(run.failureReason == "stopped by a signal (SIGTERM)")
        #expect(client.replayCount == 0, "the park was the stream's, not the cancellable replay's")
    }

    @Test("the stop's teardown is bounded: a container delete that hangs does not hold the run")
    func stopBoundsTheTeardown() async throws {
        let client = GatedClient(response: textResponse("tick"))
        let (store, state, engine) = try harness([], client: client)
        let j = job(timeoutSeconds: Self.heldTimeout)
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let stop = RunStop(grace: 5, teardown: 0.3, terminateGroups: {})
        // `container stop` and `delete` can each take 60 s (`ContainerRuntime.swift:601`, `:726-729`).
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger,
                               endSandboxSession: { _ in try? await Task.sleep(nanoseconds: 30_000_000_000) },
                               config: config, activity: RecordingActivity(), stop: stop)
        let fire = Task { await runner.fire(job: j, origin: .manual) }
        defer { client.release() }
        try #require(await client.calls.reach(1))
        _ = stop.request(reason: RunStop.reason(for: SIGINT))
        try #require(await finished(fire, within: 10) != nil, "the teardown was abandoned at its bound")
        let run = try #require(try store.ledger.runs(jobId: j.id, limit: 1).first)
        #expect(run.status == .interrupted)
        #expect(card(state)?.runId == run.id, "the card is still delivered")
    }

    @Test("a stop before the run starts means no run: no row, no conversation")
    func stopBeforeTheRun() async throws {
        let (store, state, engine) = try harness([textResponse("tick")])
        let j = job()
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let stop = RunStop(grace: 5, terminateGroups: {})
        #expect(stop.request(reason: RunStop.reason(for: SIGINT)) == .exitNow)
        let conversations = state.conversations.count
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               activity: RecordingActivity(), stop: stop)
        await runner.fire(job: j, origin: .manual)
        #expect(try store.ledger.runs(jobId: j.id, limit: 5).isEmpty)
        #expect(state.conversations.count == conversations)
    }

    @Test("a stop after the turn came back changes nothing")
    func stopAfterTheTurn() async throws {
        let (store, state, engine) = try harness([textResponse("tick")])
        let j = job()
        try store.ledger.upsert(j)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let stop = RunStop(grace: 5, terminateGroups: {})
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               activity: RecordingActivity(), stop: stop)
        await runner.fire(job: j, origin: .manual)
        #expect(stop.request(reason: RunStop.reason(for: SIGINT)) == .ignored)
        #expect(try store.ledger.runs(jobId: j.id, limit: 1).first?.status == .completed)
    }
```

(`harness`, `job(timeoutSeconds:)`, `GatedClient`, `isolatedConfig`, `card`, `finished`, `Signal`, `RecordingActivity` and `textResponse` already exist in this file.)

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh JobRetryTests`
Expected: the build fails with `cannot find 'RunStop' in scope`.

- [ ] **Step 3: Write `RunStop`.** Create `Sources/IrisKit/RunStop.swift`:

```swift
import Foundation

/// #463 decision 16: a CLI stop, as the run sees it. A third claimant on the run's ending, beside
/// the turn and the watchdog. Lock-based, so a signal source on its own queue can ask without
/// waiting for the main actor or the runner's actor.
final class RunStop: @unchecked Sendable {
    enum Answer: Equatable, Sendable {
        /// No run is armed: before admission, or a dry run. The CLI exits 2 now, with no row.
        case exitNow
        /// An armed run will close itself as stopped; the CLI exits when it returns.
        case runWillStop
        /// Already asked, or the run is over: the CLI finishes on its own.
        case ignored
    }

    private enum Phase { case idle, armed, requested(String), done }

    /// How long the run waits for a cancelled turn before abandoning it, so an uncancellable
    /// await cannot hang the stop.
    let grace: TimeInterval
    /// How long the run's teardown (`closeSession`: the container's stop and delete, each up to
    /// 60 s) may take on the stop path before the run goes on without it. A container it leaves is
    /// deleted by the CLI's settle (Task 14).
    let teardown: TimeInterval
    /// SIGTERM to the run's host process groups, then SIGKILL after the runner's grace.
    let terminateGroups: @Sendable () -> Void

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var waiter: CheckedContinuation<String?, Never>?

    init(grace: TimeInterval = 15, teardown: TimeInterval = 5,
         terminateGroups: @escaping @Sendable () -> Void = { LiveProcessGroups.shared.terminateAll() }) {
        self.grace = grace
        self.teardown = teardown
        self.terminateGroups = terminateGroups
    }

    /// Whether a stop was ever asked for, armed or not. The CLI settles its groups and containers
    /// before `_exit` when it was.
    var wasRequested: Bool {
        lock.withLock {
            if case .requested = phase { return true }
            return false
        }
    }

    static func reason(for signal: Int32) -> String { "stopped by a signal (\(signalName(signal)))" }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        default: "signal \(signal)"
        }
    }

    func request(reason: String) -> Answer {
        let (answer, waiting): (Answer, CheckedContinuation<String?, Never>?) = lock.withLock {
            switch phase {
            case .idle:
                phase = .requested(reason)
                return (.exitNow, nil)
            case .armed:
                phase = .requested(reason)
                let w = waiter
                waiter = nil
                return (.runWillStop, w)
            case .requested, .done:
                return (.ignored, nil)
            }
        }
        waiting?.resume(returning: reason)
        return answer
    }

    /// At the top of a run. nil: armed. A reason: a stop came first, so the run must not start.
    func arm() -> String? {
        lock.withLock {
            switch phase {
            case .idle, .done, .armed:
                phase = .armed
                return nil
            case .requested(let reason):
                return reason
            }
        }
    }

    /// At the end of a run: a later signal is `.ignored`, so the CLI's flush and print are kept.
    func disarm() {
        let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
            if case .armed = phase { phase = .done }
            let w = waiter
            waiter = nil
            return w
        }
        waiting?.resume(returning: nil)
    }

    /// The reason once a stop is requested, or nil when the run ends or the waiting task is cancelled.
    func wait() async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                lock.withLock {
                    if case .requested(let reason) = phase { return continuation.resume(returning: reason) }
                    if case .done = phase { return continuation.resume(returning: nil) }
                    if Task.isCancelled { return continuation.resume(returning: nil) }
                    precondition(waiter == nil, "RunStop has one waiter: the armed run")
                    waiter = continuation
                }
            }
        } onCancel: {
            let waiting: CheckedContinuation<String?, Never>? = lock.withLock {
                let w = waiter
                waiter = nil
                return w
            }
            waiting?.resume(returning: nil)
        }
    }
}
```

- [ ] **Step 4: Make `DeadlineFlag` three-way.** Replace `DeadlineFlag`'s body (`JobRunner.swift:2041-2077`) with:

```swift
actor DeadlineFlag {
    /// How a run ended: its turn came back, its deadline arrived, or a CLI stop took it (#463).
    enum Ending: Equatable, Sendable {
        case turn
        case deadline
        case signal(String)
    }

    private var ending: Ending?
    /// `run()`, parked in `wait()`. One at a time, by construction: a run has one waiter.
    private var waiter: CheckedContinuation<Ending, Never>?

    /// `true` for exactly one caller, ever.
    @discardableResult
    func claim(_ how: Ending) -> Bool {
        guard ending == nil else { return false }
        ending = how
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: how)
        }
        return true
    }

    /// Returns as soon as any racer has claimed the ending. This is what lets the deadline or a
    /// stop win the *wait* and not only the claim: a turn parked somewhere that never checks
    /// cancellation is left behind rather than kept waited on.
    func wait() async -> Ending {
        if let ending { return ending }
        // One waiter, and enforced where it is relied on: a second would overwrite the first
        // continuation, which is never resumed again — a silent permanent hang.
        precondition(waiter == nil, "DeadlineFlag has one waiter: the run that owns the ending")
        return await withCheckedContinuation { self.waiter = $0 }
    }
}
```

Keep its doc comment (`:2036-2040`), with "Which of the two racers" changed to "Which of the racers (the turn, the deadline, a CLI stop)".

- [ ] **Step 5: Thread the stop through `JobRunner`.**
  - Add the stored property next to `watchdogSlice`: `/// #463 decision 16: a CLI's stop. nil everywhere but \`--run-job\`.` and `private let stop: RunStop?`.
  - Add `stop: RunStop? = nil` as `init`'s last parameter (after `deadlineClock`), and `self.stop = stop` at the end of the body.
  - At the top of `run(job:origin:limits:gate:note:watch:afterBegin:)` (`:1028`, before the built-in check), add:

```swift
        // #463: a stop that arrived before this run means it never starts: no row, no
        // conversation (decision 16, "before admission").
        if let stop, let reason = stop.arm() {
            print("[JobRunner] not running \(job.name): \(reason)")
            return
        }
        defer { stop?.disarm() }
```

  - Change the turn's claim (`:1172`) to `if await ending.claim(.turn) { return true }`, and the watchdog's (`:1201`) to `guard await ending.claim(.deadline) else { return }`.
  - After the watchdog task (`:1208`), add the stop's watcher:

```swift
        // The third claimant (#463 decision 16): a CLI signal. It cancels the turn and ends the
        // run's host process groups; the run then waits up to `stop.grace` for the turn.
        let stopWatch = Task { [stop] in
            guard let stop, let reason = await stop.wait() else { return }
            guard await ending.claim(.signal(reason)) else { return }
            await holder.end()
            turnTask.cancel()
            stop.terminateGroups()
        }
```

  - Replace `:1212-1218` (`let overran = await ending.wait()` through `if overran { await lifetime.release() }`) with:

```swift
        let how = await ending.wait()
        watchdog.cancel()
        stopWatch.cancel()
        await holder.end()
        let overran = how == .deadline
        var stoppedBy: String?
        if case .signal(let reason) = how { stoppedBy = reason }
        // The indicator is the run's while the run is running, and this run is over. A turn that
        // came back released it on its own way out, so this is a no-op then; a turn the deadline
        // or the stop's grace abandoned never will, so this is the only release it gets.
        var abandoned = overran
        if stoppedBy != nil, let stop {
            abandoned = !(await Self.returnsWithin(stop.grace) { _ = await turnTask.value })
        }
        if abandoned { await lifetime.release() }
```

  - In the status block (`:1224-1232`), annotate `let status: JobRun.Status` and replace `overran ? .failed : Self.status(…)` with `overran ? .failed : stoppedBy != nil ? .interrupted : Self.status(…)`, `let blockedCall = overran ? nil : turn.denials.first` with `let blockedCall = (overran || stoppedBy != nil) ? nil : turn.denials.first`, and `let failureReason = overran ? TurnBudget.timeExceeded : Self.failureReason(…)` with `let failureReason = overran ? TurnBudget.timeExceeded : stoppedBy ?? Self.failureReason(…)`.
  - Bound the teardown on the stop path. Replace the `await closeSession(conversationId, status: card.statusText)` before `deliver` (`:1300`) with:

```swift
        if stoppedBy != nil, let stop {
            // A container stop and delete can each take 60 s; a stopping CLI does not wait that
            // long. What this leaves, the CLI's settle deletes by name (Task 14).
            let status = card.statusText
            _ = await Self.returnsWithin(stop.teardown) { await self.closeSession(conversationId, status: status) }
        } else {
            await closeSession(conversationId, status: card.statusText)
        }
```

  - Add beside `DeadlineFlag`:

```swift
extension JobRunner {
    /// Whether `operation` came back within `seconds`. Timed on a dispatch queue (invariant 4);
    /// the operation is never awaited past the bound, since it may never come back.
    static func returnsWithin(_ seconds: TimeInterval,
                              _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        let first = FirstBool()
        return await withCheckedContinuation { continuation in
            first.install(continuation)
            Task { await operation(); first.resolve(true) }
            // A queue of its own, as `BlockingSpawn.detached` uses: `.global()` does not overcommit.
            DispatchQueue(label: "iris.jobrunner.bound").asyncAfter(deadline: .now() + seconds) { first.resolve(false) }
        }
    }
}

/// One answer, from whichever side gets there first.
private final class FirstBool: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var answered = false

    func install(_ continuation: CheckedContinuation<Bool, Never>) { lock.withLock { self.continuation = continuation } }

    func resolve(_ value: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !answered else { return nil }
            answered = true
            let c = continuation
            continuation = nil
            return c
        }
        waiting?.resume(returning: value)
    }
}
```

  - In `iris.swift`, change `func jobRunner()` (`:3234`) to `func jobRunner(stop: RunStop? = nil) async -> JobRunner?`, and pass `stop: stop` into `JobRunner(…)`. The first call builds the runner, so the stop it was given is the one it keeps.

- [ ] **Step 6: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh JobRetryTests`
Expected: PASS, `main`'s count plus 5.

- [ ] **Step 7: Mutation checks (a clean stop).** Make each change alone, run `JobRetryTests`, confirm the named test fails, then revert it.
  - Delete the `stopWatch` task. Expected: `stopMidTurn` and `stopAbandonsAStubbornTurn` fail. The second runs until `finished` gives up.
  - Replace `abandoned = !(await Self.returnsWithin(…))` with `_ = await turnTask.value`. Expected: `stopAbandonsAStubbornTurn` fails (the wedged turn never comes back, so `finished` gives up).
  - Replace the bounded teardown with the plain `await closeSession(…)`. Expected: `stopBoundsTheTeardown` fails.
  - Delete `stop.terminateGroups()`. Expected: `stopMidTurn` fails on `terminated.value == 1`.
  - Delete the `arm()` block. Expected: `stopBeforeTheRun` fails.

- [ ] **Step 8: Check warnings.** Run `scripts/check-warnings.sh`. Expected: exit 0.

- [ ] **Step 9: Commit.**

```bash
git add Sources/IrisKit/RunStop.swift Sources/IrisKit/JobRunner.swift Sources/IrisKit/iris.swift Tests/irisTests/JobRetryTests.swift
git commit -m "feat: RunStop, a CLI stop as the run's third claimant (#463 decision 16)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 14: `CLISignals` and `CLIStop`, wired into `--run-job`

**Files:**
- Create: `Sources/IrisKit/CLISignals.swift`
- Modify: `Sources/IrisKit/RunJobCLI.swift` (`run` gains `stop:` and settles a stopped run; `fire` passes the stop to `jobRunner(stop:)`)
- Modify: `Sources/IrisKit/IrisMain.swift` (the `--run-job` branch)
- Create: `Tests/irisTests/RunJobCLIStopTests.swift`
- Create: `Tests/irisTests/CLISignalTests.swift`

**Interfaces:**
- Consumes:
  - Task 11's `LiveProcessGroups` (`terminateAll`, `killAll`, `waitUntilEmpty(within:)`) and `ProcessGroupRunner(registry:)`.
  - Task 12's `LiveContainerNames.deleteAll(within:command:)`.
  - Task 13's `RunStop` (`wasRequested`, `teardown`) and `IrisEngine.jobRunner(stop:)`.
  - PR 1's `StoreLock.vacate(at:)` and `ProcessRole`, and IrisMain's vacate just before `_exit`.
- Produces:
  - `enum CLISignals`, with:
    - `static let stopping: [Int32] = [SIGINT, SIGTERM, SIGHUP]`
    - `static let keepsInheritedIgnore: Set<Int32> = [SIGINT, SIGHUP]`
    - `final class Installation` (`installed: [Int32]`, `uninstall()`), and `static func install(_:queue:onSignal:) -> Installation`
  - `final class CLIStop: @unchecked Sendable`, with:
    - `run: RunStop`
    - `init(grace:teardown:terminateGroups:drainGroups:killGroups:deleteContainers:resetInterrupt:vacate:exitNow:)`
    - `receive(_ signal: Int32)`, `settle()`
  - `RunJobCLI.run(…, stop: CLIStop? = nil, …)`

- [ ] **Step 1: Write the failing in-process tests.** Create `Tests/irisTests/RunJobCLIStopTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decision 16, in this process: signals are *delivered by hand* to `CLIStop.receive`, so
/// nothing installs a handler here and Ctrl-C still stops `swift test`. Each test has its own
/// registry and box, and records exits, deletes and the SIGINT reset rather than doing them.
/// Real signals run in `CLISignalTests`.
@MainActor
@Suite("--run-job's clean stop (#463)", .timeLimit(.minutes(1)))
final class RunJobCLIStopTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-463-stop-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    /// What the stop did, in order.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ event: String) { lock.withLock { list.append(event) } }
        var values: [String] { lock.withLock { list } }
        var exits: [Int32] { values.compactMap { $0.hasPrefix("exit ") ? Int32($0.dropFirst(5)) : nil } }
    }

    /// Spawns `/bin/sleep 30` in a group of the test's registry, says so, then waits on it,
    /// terminating it when the turn is cancelled: a turn that is "mid-run" by construction.
    final class SleepingClient: LLMClientProtocol, @unchecked Sendable {
        private let registry: LiveProcessGroups
        private let onRunning: @Sendable () -> Void
        private let lock = NSLock()
        private var pid: pid_t = 0
        var sleepPid: pid_t { lock.withLock { pid } }

        init(registry: LiveProcessGroups, onRunning: @escaping @Sendable () -> Void) {
            self.registry = registry
            self.onRunning = onRunning
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let runner = ProcessGroupRunner(registry: registry)
            let running = Task { await runner.run(executable: "/bin/sleep", arguments: ["30"], environment: nil, currentDirectory: nil) }
            var waited = 0
            while runner.processIdentifier == 0, waited < 500 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
            }
            lock.withLock { pid = runner.processIdentifier }
            onRunning()
            _ = await withTaskCancellationHandler { await running.value } onCancel: { runner.terminate() }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "woke")]))],
                                  usageMetadata: nil)
        }
    }

    private func lockPath() -> URL {
        base.appendingPathComponent(UUID().uuidString).appendingPathComponent("conversations.sqlite.lock")
    }

    private func stop(_ registry: LiveProcessGroups, _ events: Events, grace: TimeInterval = 5) -> CLIStop {
        CLIStop(grace: grace, teardown: 2,
                terminateGroups: { registry.terminateAll() },
                drainGroups: { registry.waitUntilEmpty(within: 3) },
                killGroups: { events.add("kill"); registry.killAll() },
                deleteContainers: { events.add("delete") },
                resetInterrupt: { events.add("reset") },
                vacate: { events.add("vacate") },
                exitNow: { events.add("exit \($0)") })
    }

    @Test("SIGINT, SIGTERM and SIGHUP mid-run: interrupted with the reason, the card, the groups drained, exit 2",
          arguments: [SIGINT, SIGTERM, SIGHUP])
    func signalMidRun(_ signal: Int32) async throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "napper", prompt: "Nap.", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let registry = LiveProcessGroups()
        let events = Events()
        let cliStop = stop(registry, events)
        let client = SleepingClient(registry: registry, onRunning: { cliStop.receive(signal) })

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "napper"), store: store, client: client,
                                       lockPath: lockPath(), protectionEnabled: false, stop: cliStop,
                                       out: { _ in }, err: { _ in })

        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(events.exits.isEmpty, "the first signal stops the run; it does not exit the process")
        let row = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(row.status == .interrupted)
        #expect(row.failureReason == "stopped by a signal (\(RunStop.signalName(signal)))")
        let cards = try store.loadAll().conversations.flatMap(\.messages).compactMap { EventCard.decode($0.content) }
        #expect(cards.contains { $0.runId == row.id }, "the card was delivered and the save flushed")
        // `settle` waited for the SIGTERM'd group's ladder (its SIGKILL rung is 2 s on) before
        // `run` returned, so a group that ignored SIGTERM could not outlive the `_exit`.
        #expect(registry.count == 0)
        #expect(kill(client.sleepPid, 0) == -1 && errno == ESRCH, "the sleep's group is gone")
        #expect(events.values == ["delete"], "settle deletes what containers are left; nothing was killed early")
    }

    @Test("a signal before admission: groups killed, containers deleted, the payload emptied, exit 2, no row")
    func signalBeforeAdmission() async throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "napper", prompt: "Nap.", trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        cliStop.receive(SIGINT)
        #expect(events.values == ["reset", "kill", "delete", "vacate", "exit 2"])
        // In production that exit is `_exit`. Here the run goes on, and the run armed too late
        // writes nothing.
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "napper"), store: store,
                                       client: FakeLLMClient(responses: []), lockPath: lockPath(),
                                       protectionEnabled: false, stop: cliStop, out: { _ in }, err: { _ in })
        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("Review Focus 4: a signal during --dry-run while its gate runs: exit 2 at once, host groups killed, containers deleted, nothing written")
    func signalDuringDryRun() async throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "gated", prompt: "p",
                      trigger: .poll(PollSpec(schedule: .interval(seconds: 60), gate: .pathChanged(path: "/tmp/whatever"))))
        try store.ledger.upsert(job)
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        _ = await RunJobCLI.run(RunJobCLI.Invocation(target: "gated", dryRun: true), store: store,
                                client: FakeLLMClient(responses: []), lockPath: lockPath(), protectionEnabled: false,
                                gate: { _, _ in cliStop.receive(SIGINT); return .unchanged(signal: "same") },
                                stop: cliStop, out: { _ in }, err: { _ in })
        #expect(events.values == ["reset", "kill", "delete", "vacate", "exit 2"],
                "the exit path runs the kill and the delete, in that order; Task 12 shows a gate's container is in the box")
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("a second signal resets SIGINT, kills the groups, deletes the containers, and exits 128 + signal")
    func secondSignalExitsNow() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        #expect(cliStop.run.arm() == nil)
        cliStop.receive(SIGINT)
        #expect(events.values.isEmpty)
        cliStop.receive(SIGINT)
        #expect(events.values == ["reset", "kill", "delete", "vacate", "exit 130"],
                "SIGINT back to its default first, so a third Ctrl-C ends the CLI while the deletes run")
    }

    @Test("a signal after the run is over is left to the CLI's own exit")
    func signalAfterTheRun() {
        let events = Events()
        let cliStop = stop(LiveProcessGroups(), events)
        _ = cliStop.run.arm()
        cliStop.run.disarm()
        cliStop.receive(SIGTERM)
        #expect(events.values.isEmpty)
    }

    @Test("settle kills what has not drained by its bound")
    func settleKillsTheStragglers() async throws {
        let events = Events()
        let cliStop = CLIStop(drainGroups: { false }, killGroups: { events.add("kill") },
                              deleteContainers: { events.add("delete") }, resetInterrupt: {},
                              vacate: {}, exitNow: { _ in })
        cliStop.settle()
        #expect(events.values == ["kill", "delete"])
    }

    @Test("the stopping signals are SIGINT, SIGTERM and SIGHUP")
    func stoppingSignals() {
        #expect(CLISignals.stopping == [SIGINT, SIGTERM, SIGHUP])
        #expect(CLISignals.keepsInheritedIgnore == [SIGINT, SIGHUP], "SIGTERM is always caught")
    }
}
```

The gated job is built the way `RunJobCLITests.dryRunUnchangedExitsThree` (`RunJobCLITests.swift:714-720`) builds one: `.poll(PollSpec(schedule:gate:))` with a host gate, `.pathChanged(path:)`.

- [ ] **Step 2: Write the failing exit tests.** Create `Tests/irisTests/CLISignalTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463 decision 16 with real signals. Each case is an exit test, a child process of its own,
/// because installing handlers in the shared test process would stop Ctrl-C from ending the run.
@Suite("CLI signals (#463)", .timeLimit(.minutes(1)))
struct CLISignalTests {
    /// SIG_DFL is 0 and SIG_IGN is 1; anything else is a handler.
    static func raw(_ signal: Int32) -> UInt {
        var now = sigaction()
        sigaction(signal, nil, &now)
        return unsafeBitCast(now.__sigaction_u, to: UInt.self)
    }

    @Test("the handler is a do-nothing catch with SA_RESTART, and the signal reaches its source")
    func installCatchesAndRestarts() async {
        await #expect(processExitsWith: .success) {
            let fired = DispatchSemaphore(value: 0)
            let installation = CLISignals.install(onSignal: { if $0 == SIGHUP { fired.signal() } })
            // Exit 5 also means this `swift test` itself started with SIGINT or SIGHUP ignored
            // (`nohup`, a non-interactive `&`): run it in the foreground.
            guard installation.installed == CLISignals.stopping else { exit(5) }
            for signal in CLISignals.stopping {
                guard CLISignalTests.raw(signal) > 1 else { exit(2) }
                var now = sigaction()
                sigaction(signal, nil, &now)
                guard now.sa_flags & SA_RESTART != 0 else { exit(3) }
            }
            kill(getpid(), SIGHUP)   // its default would end this process
            guard fired.wait(timeout: .now() + 5) == .success else { exit(4) }
            withExtendedLifetime(installation) {}
        }
    }

    @Test("nohup: an inherited ignore on SIGHUP or SIGINT is kept, and SIGTERM is caught anyway")
    func inheritedIgnoreIsKept() async {
        await #expect(processExitsWith: .success) {
            _ = signal(SIGHUP, SIG_IGN)
            _ = signal(SIGINT, SIG_IGN)
            _ = signal(SIGTERM, SIG_IGN)
            let installation = CLISignals.install(onSignal: { _ in })
            guard CLISignalTests.raw(SIGHUP) == 1, CLISignalTests.raw(SIGINT) == 1 else { exit(2) }
            guard CLISignalTests.raw(SIGTERM) > 1 else { exit(3) }
            guard installation.installed == [SIGTERM] else { exit(4) }
            kill(getpid(), SIGHUP)   // ignored: this process carries on
            withExtendedLifetime(installation) {}
        }
    }

    @Test("with the handlers installed, a child that signals itself still dies of it, through Process and ProcessGroupRunner")
    func childrenKeepTheDefaultDisposition() async {
        await #expect(processExitsWith: .success) {
            let installation = CLISignals.install(onSignal: { _ in })
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "kill -TERM $$; sleep 5"]
            guard (try? process.run()) != nil else { exit(2) }
            process.waitUntilExit()
            guard process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM else { exit(3) }
            // ProcessGroupRunner resets every disposition in the child (POSIX_SPAWN_SETSIGDEF), so it
            // is checked against a real inherited ignore: only that reset can make this child die.
            _ = signal(SIGTERM, SIG_IGN)
            let result = await ProcessGroupRunner(registry: LiveProcessGroups())
                .run(executable: "/bin/sh", arguments: ["-c", "kill -TERM $$; sleep 5"], environment: nil, currentDirectory: nil)
            guard case .success(let out) = result, out.status == 128 + SIGTERM else { exit(4) }
            withExtendedLifetime(installation) {}
        }
    }

    @Test("without handlers, the same child dies of SIGTERM too: the check above can tell")
    func baselineWithoutHandlers() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "kill -TERM $$; sleep 5"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    @Test("a second SIGINT resets SIGINT, SIGKILLs the registered groups and _exits 130")
    func secondSignalKillsAndExits() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("iris-463-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        await #expect(processExitsWith: .exitCode(130)) { [path = pidFile.path] in
            let registry = LiveProcessGroups()
            let runner = ProcessGroupRunner(registry: registry)
            let running = Task { await runner.run(executable: "/bin/sleep", arguments: ["30"], environment: nil, currentDirectory: nil) }
            var waited = 0
            while runner.processIdentifier == 0, waited < 500 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 1
            }
            try? Data("\(runner.processIdentifier)".utf8).write(to: URL(fileURLWithPath: path))
            let installation = CLISignals.install(onSignal: { _ in })
            let stop = CLIStop(terminateGroups: { registry.terminateAll() }, killGroups: { registry.killAll() },
                               deleteContainers: {}, vacate: {},
                               exitNow: { code in _exit(CLISignalTests.raw(SIGINT) == 0 ? code : 7) })   // the real reset ran
            _ = stop.run.arm()
            stop.receive(SIGINT)
            stop.receive(SIGINT)   // exits here
            withExtendedLifetime((running, installation)) {}
            exit(1)
        }
        let pid = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)))
        var gone = false
        for _ in 0..<200 {   // a zombie until launchd reaps it, at most a moment
            if kill(pid, 0) == -1 && errno == ESRCH { gone = true; break }
            usleep(10_000)
        }
        #expect(gone, "the sleep's group was SIGKILLed before the exit")
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail.**

Run: `timeout 300 scripts/test-filter.sh RunJobCLIStopTests`
Expected: the build fails with `cannot find 'CLIStop' in scope`.

- [ ] **Step 4: Write `CLISignals` and `CLIStop`.** Create `Sources/IrisKit/CLISignals.swift`:

```swift
import Darwin
import Foundation

/// #463 decision 16: the CLI's own SIGINT, SIGTERM and SIGHUP.
///
/// - A do-nothing `sigaction` handler, not `SIG_IGN`: a caught disposition resets to the default
///   across `exec`, so no child — `Process` or `posix_spawn` — inherits an ignore.
/// - `SA_RESTART`, so blocking calls on whichever thread takes the signal do not fail with `EINTR`
///   mid-stop.
/// - A `DispatchSource` per signal, on the CLI's own serial queue rather than `.main`: a long
///   main-actor stretch (Vibecop loading ggml) must not delay the stop.
/// - An inherited ignore on SIGHUP or SIGINT is kept (plan note 16). `nohup iris --run-job x &`
///   sets SIGHUP ignored so a closed terminal does not end the run, and a non-interactive shell
///   starts `&` jobs with SIGINT ignored. SIGTERM is always caught.
enum CLISignals {
    static let stopping: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    static let keepsInheritedIgnore: Set<Int32> = [SIGINT, SIGHUP]

    final class Installation: @unchecked Sendable {
        /// The signals this installation caught: `stopping` minus any inherited ignore it kept.
        let installed: [Int32]
        fileprivate let sources: [DispatchSourceSignal]
        fileprivate let previous: [(Int32, sigaction)]

        fileprivate init(installed: [Int32], sources: [DispatchSourceSignal], previous: [(Int32, sigaction)]) {
            self.installed = installed
            self.sources = sources
            self.previous = previous
        }

        /// Puts the old dispositions back. For tests; the CLI keeps its handlers until it exits.
        func uninstall() {
            sources.forEach { $0.cancel() }
            for (signal, old) in previous {
                var action = old
                sigaction(signal, &action, nil)
            }
        }
    }

    static func install(_ signals: [Int32] = stopping,
                        queue: DispatchQueue = DispatchQueue(label: "iris.cli.signals"),
                        onSignal: @escaping @Sendable (Int32) -> Void) -> Installation {
        var installed: [Int32] = []
        var sources: [DispatchSourceSignal] = []
        var previous: [(Int32, sigaction)] = []
        for signal in signals {
            var old = sigaction()
            sigaction(signal, nil, &old)
            let ignored = unsafeBitCast(old.__sigaction_u, to: UInt.self) == 1   // SIG_IGN
            if ignored, keepsInheritedIgnore.contains(signal) { continue }
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { _ in }
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
            previous.append((signal, old))
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { onSignal(signal) }
            source.resume()
            sources.append(source)
            installed.append(signal)
        }
        return Installation(installed: installed, sources: sources, previous: previous)
    }
}

/// What the CLI does with a stopping signal.
/// - The first stops the run cleanly (`RunStop`). With no run armed yet (before admission, or a
///   dry run), it exits now instead, with 2.
/// - A second means exit now, with `128 + signal`.
/// - Exiting now resets SIGINT to its default first, so a third Ctrl-C ends the CLI at once while
///   the deletes run. It then SIGKILLs every registered host group, deletes every container this
///   process made (bounded at 5 s, in parallel, plan note 15), empties the lock's payload and
///   `_exit`s.
/// - After a clean stop, `settle()` runs before `_exit`: up to 3 s for the host groups to drain
///   (their SIGKILL rung is 2 s after the SIGTERM), a SIGKILL for any that did not, and a delete
///   for any container the bounded teardown left behind.
final class CLIStop: @unchecked Sendable {
    let run: RunStop

    private let drainGroups: @Sendable () -> Bool
    private let killGroups: @Sendable () -> Void
    private let deleteContainers: @Sendable () -> Void
    private let resetInterrupt: @Sendable () -> Void
    private let vacate: @Sendable () -> Void
    private let exitNow: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var received = 0

    init(grace: TimeInterval = 15, teardown: TimeInterval = 5,
         terminateGroups: @escaping @Sendable () -> Void = { LiveProcessGroups.shared.terminateAll() },
         drainGroups: @escaping @Sendable () -> Bool = { LiveProcessGroups.shared.waitUntilEmpty(within: 3) },
         killGroups: @escaping @Sendable () -> Void = { LiveProcessGroups.shared.killAll() },
         deleteContainers: @escaping @Sendable () -> Void = { _ = LiveContainerNames.shared.deleteAll(within: 5) },
         resetInterrupt: @escaping @Sendable () -> Void = {
             // Only our own catch is reset: an inherited ignore (plan note 16) stays ignored.
             var now = sigaction()
             sigaction(SIGINT, nil, &now)
             if unsafeBitCast(now.__sigaction_u, to: UInt.self) > 1 { _ = signal(SIGINT, SIG_DFL) }
         },
         vacate: @escaping @Sendable () -> Void,
         exitNow: @escaping @Sendable (Int32) -> Void = { code in
             fflush(stdout)
             fflush(stderr)
             _exit(code)
         }) {
        self.run = RunStop(grace: grace, teardown: teardown, terminateGroups: terminateGroups)
        self.drainGroups = drainGroups
        self.killGroups = killGroups
        self.deleteContainers = deleteContainers
        self.resetInterrupt = resetInterrupt
        self.vacate = vacate
        self.exitNow = exitNow
    }

    func receive(_ signal: Int32) {
        let count = lock.withLock { () -> Int in
            received += 1
            return received
        }
        guard count == 1 else {
            // Exit now. A row this leaves `running` is closed by the next app launch's sweep
            // (decision 11), with "the Iris process running it ended".
            return exitAtOnce(128 + signal)
        }
        if run.request(reason: RunStop.reason(for: signal)) == .exitNow {
            exitAtOnce(RunJobCLI.Exit.notCompleted)
        }
    }

    /// After a stopped run has returned, before `_exit`.
    func settle() {
        if !drainGroups() { killGroups() }
        deleteContainers()
    }

    private func exitAtOnce(_ code: Int32) {
        resetInterrupt()
        killGroups()
        deleteContainers()
        vacate()
        exitNow(code)
    }
}
```

- [ ] **Step 5: Wire it into the CLI.**
  - In `RunJobCLI.run`, add `stop: CLIStop? = nil,` after `gate:`.
  - Replace the final `return await fire(…)` with:

```swift
        let code = await fire(job: job, store: store, client: client, runner: injectedRunner,
                              protectionEnabled: protectionEnabled, json: invocation.json, stop: stop,
                              out: out, err: err)
        // A stopped run's host groups get their SIGKILL rung, and its leftover containers a
        // delete, before the process exits (#463).
        if let stop, stop.run.wasRequested { stop.settle() }
        return code
```

  - In `fire`, add the parameter `stop: CLIStop?` and replace `irisEngine.jobRunner()` with `irisEngine.jobRunner(stop: stop?.run)`. An injected runner was built by its test with its own `RunStop`.
  - In `IrisMain.swift`'s `--run-job` branch, after `ProcessRole.set(.runJob)`, replace the `let code = await RunJobCLI.run(…)` call with the block below. PR 1's `StoreLock.vacate` just before `_exit` stays where it is.

```swift
            // #463 decision 16: SIGINT, SIGTERM and SIGHUP stop the run cleanly; a second one exits
            // at once. Installed before the claim, so a signal there still exits 2 with no row.
            let lockPath = IrisPaths.default.storeLockFile
            let stop = CLIStop(vacate: { StoreLock.vacate(at: lockPath) })
            let signals = CLISignals.install { stop.receive($0) }
            let code = await RunJobCLI.run(invocation,
                                           store: try ConversationStore.onDisk(at: IrisPaths.default.conversationsDB),
                                           client: LLMClient(), lockPath: lockPath, stop: stop)
            withExtendedLifetime(signals) {}
```

- [ ] **Step 6: Run the tests to verify they pass.**

Run: `timeout 300 scripts/test-filter.sh RunJobCLIStopTests`, then `CLISignalTests`, then `RunJobCLITests`
Expected: PASS: 7 tests (9 cases: `signalMidRun` runs once per signal), then 5, then PR 1's 27.

- [ ] **Step 7: Mutation checks.** Make each change alone, run the named suite, confirm the named test fails, then revert it.
  - In `exitAtOnce`, delete `killGroups()`. Expected: `CLISignalTests/secondSignalKillsAndExits` fails (the sleep outlives the exit), and `RunJobCLIStopTests/secondSignalExitsNow` fails on its event list (a second Ctrl-C kills the registered groups).
  - In `exitAtOnce`, delete `deleteContainers()`. Expected: `secondSignalExitsNow`, `signalBeforeAdmission` and `signalDuringDryRun` fail (the coordinator's ruling: exit-now deletes the containers).
  - Move `resetInterrupt()` after `deleteContainers()`. Expected: `secondSignalExitsNow` fails on the order.
  - In `RunJobCLI.run`, delete the `settle()` line. Expected: `signalMidRun` fails on `registry.count == 0` for all three signals.
  - Replace the handler with `action.__sigaction_u.__sa_handler = SIG_IGN`. Expected: `installCatchesAndRestarts` fails, and so does the `Process` half of `childrenKeepTheDefaultDisposition` (exit 3).
  - In `ProcessGroupRunner.launch`, drop `POSIX_SPAWN_SETSIGDEF` from the flags. Expected: the `ProcessGroupRunner` half of `childrenKeepTheDefaultDisposition` fails (exit 4): the child inherits the ignore and sleeps out its 5 s.
  - Drop `SA_RESTART`. Expected: `installCatchesAndRestarts` fails.
  - Delete the `if ignored, keepsInheritedIgnore.contains(signal) { continue }` line. Expected: `inheritedIgnoreIsKept` fails.
  - Remove `SIGHUP` from `stopping`. Expected: `stoppingSignals` and `installCatchesAndRestarts` fail (a clean stop on SIGINT/TERM/HUP).
  - In `fire`, call `irisEngine.jobRunner()` without the stop. Expected: `signalMidRun` fails for all three signals.

- [ ] **Step 8: Full suite and warnings.** Run `timeout 900 swift test 2>&1 | tee /tmp/463-pr2-full.log` and `scripts/check-warnings.sh`. Expected: green on all three counts, and exit 0. The three trapping exit tests (Task 8) leave a crash report each in `~/Library/Logs/DiagnosticReports`. That is expected and harmless.

- [ ] **Step 9: Commit.**

```bash
git add Sources/IrisKit/CLISignals.swift Sources/IrisKit/RunJobCLI.swift Sources/IrisKit/IrisMain.swift \
  Tests/irisTests/RunJobCLIStopTests.swift Tests/irisTests/CLISignalTests.swift
git commit -m "feat: --run-job stops cleanly on SIGINT, SIGTERM and SIGHUP (#463 decision 16)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
```

### Task 15: invariant 9 sweep for PR 2, and open it

**Files:**
- Modify: `docs/jobs.md` (after the exit-code table at `:1170-1175`)
- Modify: `README.md` (after the `--run-job` exit-code line, `:260`)

**Interfaces:**
- Consumes: Tasks 11-14.
- Produces: docs for the clean stop, the exit-now, and their gap.

- [ ] **Step 1: Search, do not compose.** Run `grep -rnE "Ctrl-C|SIGINT|SIGTERM|interrupt|kills? the CLI|orphan" README.md docs/jobs.md AGENTS.md`. Read every hit. Any sentence that says Ctrl-C kills a `--run-job` outright, or that its `run_command` groups survive it, is now untrue. Fix it to match Step 2.

- [ ] **Step 2: Add the behaviour.** After `docs/jobs.md`'s exit-code table, add:

```markdown
**Stopping a run.** Ctrl-C, `kill` (SIGTERM) or closing the terminal (SIGHUP) stops a `--run-job`
cleanly: the turn is cancelled, its host process groups get SIGTERM and then SIGKILL, and the CLI
waits up to 15 seconds for the turn to come back (a turn that never does is abandoned). The row is
then closed `interrupted` with "stopped by a signal (SIGINT)" (or `SIGTERM`, `SIGHUP`), the card is
delivered, the store is flushed, and it exits `2`. The run's container is given 5 seconds to stop
and be deleted, and is then deleted by name before the CLI exits. A signal before the run starts,
or during a `--dry-run`, exits `2` at once with nothing written. A **second** Ctrl-C exits at once
with `130`. It SIGKILLs the host process groups, then deletes the containers this run made (its
session, any gate or one-off container), in parallel, for at most 5 seconds. A third Ctrl-C during
those 5 seconds ends the CLI outright. The row is closed the next time Iris opens, as "the Iris
process running it ended". Under `nohup` (or any shell that starts the CLI with SIGHUP or SIGINT
ignored), that signal stays ignored, so closing the terminal does not stop the run. `kill` still
does.

One thing a stop does not reach: a background process a command started with its output
redirected (`nohup x >/dev/null 2>&1 &`) is left running, as it is when any command finishes.
```

In `README.md`, after the exit-code line, add one sentence: `Ctrl-C (or SIGTERM, SIGHUP) stops a run cleanly — its row reads "stopped by a signal", and it exits 2 — and a second Ctrl-C exits at once; see docs/jobs.md, "Stopping a run".`

- [ ] **Step 3: Agent-visible strings.** Run `grep -rn "stopped by a signal\|interruptedByQuitReason" Sources/IrisKit`. Expected: only `RunStop.swift` and the two `iris.swift` sites. `get_job_run` returns `failureReason` as stored, so the new reason needs no description change. Read `get_job_run`'s `description` in `ToolExecutor.swift`. If it enumerates the reasons an `interrupted` row can carry, add this one.

- [ ] **Step 4: Commit and open the PR.**

```bash
git add README.md docs/jobs.md
git commit -m "docs: --run-job's clean stop and its known gaps (#463)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017NLGyK8ozWezeZeijjgGJx"
git push -u origin feat/463-cli-clean-stop
```

Open the PR against `main` (`gh api repos/sackheads/iris/pulls -f base=main -f head=feat/463-cli-clean-stop -f title="feat: --run-job stops cleanly on SIGINT, SIGTERM and SIGHUP (#463 PR 2)" -F body=@<file>`). The body lists decisions 16-17, plan notes 8-10 and 15-16, the full-suite counts, and "GUI pass: Task 16, pending". It ends with the session's PR attribution lines.

### Task 16: GUI pass for PR 2 (`work`, under the lease)

Spec check 6, adjusted by plan note 8. Run on `work`, on PR 2's branch, before it merges. Post each result as the command and its output. The setup variables are Task 10's; repeat its "Before you start" block and steps 1-4 (build, registrations, the `463-nap` job), with `--purpose "iris: #463 PR 2 clean stop"`. The CLI is signalled the way a terminal's Ctrl-C reaches it: to its process group. That reaches the CLI, but not its `Process` children: those lead groups of their own (`ProcessGroupRunner.swift:15-16`), so it is the CLI's stop that ends them.
- `set -m` cannot do this from an agent's shell. A non-interactive zsh refuses it (`can't change option: -m`).
- A non-interactive shell also starts `&` jobs with SIGINT ignored (POSIX).
- So every start below goes through this wrapper, tested on `work`. It restores SIGINT and SIGHUP to their defaults and makes the CLI the leader of a group of its own, so `$PG` is both its pid and its group id:

```sh
GROUP() { perl -e '$SIG{INT}=$SIG{HUP}="DEFAULT"; setpgrp(0,0); exec @ARGV' "$@"; }
```

1. **A clean stop, SIGINT.**
   - Take the card baseline for step 3. Then run, in one shell session for the whole task:

     ```sh
     GROUP "$CLI" --run-job 463-nap & PG=$!
     ```

   - Wait until `eval $HOLDER` shows the run-job payload, then 15 s more (the turn is inside `sleep 90`). Run `container list --all | grep iris-` and note the session container's name as `SESSION`. Grep for that name below, never the bare `iris-` prefix: the installed `~/.iris` app's containers share it.
   - `kill -INT -$PG; wait $PG; echo "exit=$?"`. Expected: `exit=2`, within the worst case of 15 s (grace) + 5 s (teardown) + 3 s (drain) + 5 s (deletes) = 28 s, and normally a few seconds.
   - `eval $ROW`. Expected: `manual|interrupted|stopped by a signal (SIGINT)`.
   - `wc -c < ~/.iris-dev/conversations.sqlite.lock`. Expected: `0`.
   - `container list --all | grep -c "$SESSION"`. Expected: `0`.
   - `pgrep -fl "container exec|sleep 90"`. Expected: no output.
   - Record the time from the `kill` to `exit=`.
2. **SIGTERM, then SIGHUP.** Repeat step 1 with `kill -TERM -$PG`, then with `kill -HUP -$PG`. Expected: the same, with `SIGTERM` and `SIGHUP` in the reason.
3. **The cards.** `sqlite3 ~/.iris-dev/conversations.sqlite "SELECT count(*) FROM messages WHERE payload LIKE '%jobName%463-nap%' AND payload LIKE '%interrupted%'"`. Expected: 3 more than the same query printed before step 1 (run it once there, as the baseline).
4. **A second Ctrl-C.**
   - Start as in step 1 and wait the same way.
   - Run `kill -INT -$PG; sleep 0.2; kill -INT -$PG; wait $PG; echo "exit=$?"`. Expected: within 7 s (the deletes are bounded at 5), `exit=130`.
   - `eval $ROW`. Expected: `manual|running|` (closed later).
   - `container list --all | grep -c "$SESSION"` (this step's own session name). Expected: `0`: the exit-now deleted it (plan note 15).
   - `open "$APP"`, `eval $DENY`, and wait 5 s. `eval $ROW` is then `manual|interrupted|the Iris process running it ended`.
   - **Quit Iris Dev** (Cmd-Q, then `pgrep -fl "Iris Dev"` is empty). Steps 4b-5 start `--run-job`, which PR 1 refuses while the app holds the home.
4b. **A third Ctrl-C during the deletes.** Start and wait as in step 1. Then run `kill -INT -$PG; sleep 0.2; kill -INT -$PG; sleep 0.2; kill -INT -$PG; wait $PG; echo "exit=$?"`. Expected: within 1 s, `exit=130` (SIGINT was reset to its default before the deletes, so the third one ended the CLI). Then `container list --all | grep "$SESSION"` may list this step's session container: record it, and delete it with `container delete --force "$SESSION"`.
4c. **`nohup` keeps SIGHUP ignored.**
   - `nohup "$CLI" --run-job 463-nap >"$DD/nohup.out" 2>&1 & P=$!`. Wait until `eval $HOLDER` shows it.
   - `kill -HUP $P; sleep 3; kill -0 $P && echo alive`. Expected: `alive`.
   - Then `kill -TERM $P; wait $P; echo "exit=$?"`. Expected: `exit=2`, and `eval $ROW` reads `manual|interrupted|stopped by a signal (SIGTERM)`.
5. **Before admission.** Run `GROUP "$CLI" --run-job 463-nap & P=$!; sleep 0.5; kill -INT -$P; wait $P; echo "exit=$?"` (the pause lets `IrisMain` install its handlers; through the wrapper, a signal before that is SIGINT's default, 130). Expected: `exit=2`, and `sqlite3 ~/.iris-dev/conversations.sqlite "SELECT count(*) FROM job_runs WHERE jobName = '463-nap'"` is unchanged. (If the signal lands after admission on this machine, the row reads stopped and exits 2. Record which.)
6. **Teardown.** `open "$APP"` and `eval $DENY`, then as in Task 10 step 12.

---

## Self-review against the spec

**Decision coverage.**
- 1: Task 1 (`open` flags, `flock`, never unlink).
- 2: Task 1 (the table, `droppedClaimStillExcludes`, `descriptorIsCloexec`).
- 3: Task 1 (`replacedPathIsDetected`, `endlessReplacementFails`). The waiting app's poll re-claims through the same `claim`, so it runs the check every time (Task 7's `claim` seam).
- 4: `.failed` refuses in Task 1 (`flockErrorIsFailed`), Task 3 (`failedLockRefuses`), Task 4 (`sourceLockFailed`) and Task 5 (`legacyAndFailedRefuse`).
- 5: Task 1 (`payloadIsThereWhenClaimReturns`, `failedWriteReleases`, `payloadCodec`, `vacateEmptiesAndKeeps`), plus plan notes 1-2.
- 6: Task 5 (`unknownHolderBecomesAGUI`, `unnamedHolderRefusesAfterASecond`). The harness-batch cost is Review Focus 3.
- 7: Task 3, plus Task 8's `IrisMain` role.
- 8: Task 5 (`secondGUIRefuses`, `waiterLosesToAGUI`, `legacyAndFailedRefuse`), Task 7's alert, and Task 10 step 9.
- 9: Task 5 (`waitsThenOpens`) and Task 7 (`GatePollTimer`).
- 10: Tasks 5 and 7 (gated scenes, `GatedStatusLabel`, the hotkey checked when pressed, Diagnostics left alone).
- 11: Task 5 (`freeLockKeepsTodaysOrder`, `finishOnceEitherOrder`) and Task 7 (`openStore`, `interruptedByQuitReason`).
- 12: Task 5 (`linksAreHeldThenDrained`), Task 6 (the deletion) and Task 7 (`noteLinksDroppedWhileWaiting`).
- 13: Task 5 (`coldStartShowsTheNotice`, `dockLaunchHasNoNotice`) and Task 7's non-activating `WaitingNoticePanel` (plan note 13).
- 14: Task 8.
- 15: Task 2, with Task 8's exit test.
- 16: Tasks 13-14, with the exit-now container delete in Task 12.
- 17: Task 11, with plan note 8.
- 18: Task 4.
- §3's unit tests each map to a test named above. §3's GUI checks: 1-5 and 7 are Task 10, and 6 is Task 16. §4's doc fixes are Tasks 9 and 15.

**Mutation checks.**
- Open only after the lock: Task 3 Step 5.
- The payload is written inside `claim()`: Task 1 Step 7.
- The inode re-check: Task 1 Step 7.
- `.failed` refuses: Task 1 Step 7, Task 3 Step 6, Task 5 Step 6.
- `.legacy` refuses: Task 1 Step 7, Task 3 Step 6, Task 5 Step 6.
- A second GUI refuses: Task 5 Step 6.
- The `AppState.shared` trap: Task 8 Step 8.
- #489, no shared `AppState` in the CLI: Task 2 Step 9 and Task 8 Step 8.
- A clean stop on SIGINT/TERM/HUP: Task 13 Step 7 (including the wedged turn and the teardown bound) and Task 14 Step 7.
- A second Ctrl-C kills the registered groups, resets SIGINT and deletes the containers: Task 14 Step 7, and Task 12 Step 7 for the delete's group, parallelism and bound.
- An inherited ignore is kept: Task 14 Step 7.
- The `write_file` skill path: Task 2 Step 9.

**Type consistency.** Names are used as Task 1 and Task 5 define them, in every later task:
- `StoreLock.claim`, `claimSettling`, `holds`, `vacate(at:)`, `readHolder(at:)`, `Claim`, `Holder`, `Kind` (`.runJob`, `.seedDevHome`, `.perf`, `.app`), `Syscalls`
- `LaunchDecision.decide(_:unknownFor:)`, `LaunchRefusal`, `LaunchGate.Seams`
- `RunStop.request(reason:)`, `arm()`, `disarm()`, `wait()`, `wasRequested`, `teardown`, `reason(for:)`, `signalName(_:)`, `JobRunner.returnsWithin(_:_:)`
- `CLIStop(grace:teardown:terminateGroups:drainGroups:killGroups:deleteContainers:resetInterrupt:vacate:exitNow:)`, `settle()`, `LiveProcessGroups` (`terminateAll`, `killAll`, `waitUntilEmpty(within:)`), `ProcessGroupRunner(registry:)`, `LiveContainerNames.deleteAll(within:command:)`
- `LaunchGate.Seams` (`startPolling(interval, tick)`, `showWaitingNotice`, `hideWaitingNotice`, `activate`)
- `IrisEngine.jobRunner(stop:)`, `DeadlineFlag.Ending`

**Checked and left alone.**
- `IrisMain`'s `try ConversationStore.onDisk` stays inside the autoclosure. Only Task 3's test pins it.
- `PluginAuthRunner`'s throwaway `ToolExecutor()` gets no `onSkillsChanged`. It runs no skill writes, and nil invalidates nothing. Subagents and evaluators are `IrisEngine`s, so they get their own hook (plan note 14).
