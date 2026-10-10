# Agency deliverable 6: Native surfaces

Status: **proposed** (2026-10-09). Deliverable 6 of #187, the last one. It adds four surfaces over state the harness already owns: a status item, notifications, an `iris://run-job/<uuid>` URL, and a run log window. The design brief is `.superpowers/sdd/agency-6-design-brief.md`. The owner ruled on its five questions on 2026-10-09, and those rulings are binding here (decisions 1, 6, 8, 9 and 12). Every surface is additive. Nothing here changes how a job is admitted, gated, run or recorded, beyond one new trigger kind.

The epic names an `NSStatusItem`. This spec uses SwiftUI's `MenuBarExtra` instead (decision 4), which draws the same item.

## Facts this rests on

Checked against `main` at `cec9947`, 2026-10-09. The code is in `Sources/IrisKit/`, not `Sources/iris/` as AGENTS.md's layout says. Paths below are relative to it.

- **No notification or URL code exists.** Nothing in the tree uses `UserNotifications`. `App/Info.plist` declares no `CFBundleURLTypes`, and nothing implements `onOpenURL` or `application(_:open:)`. `App/Iris.entitlements` is an empty dict. Local notifications need no entitlement.
- **One choke point for cards.** Every card, job or reflection, goes through `AppState.deliverEvent(_:to:)` (`EventDelivery.swift:38`).
- **Cards have no priority.** `EventCard` (`EventCard.swift:17-78`) has `status`, `blockedCall`, the Vibecop verdict and `offersApproval` (`:310`), but no priority or severity field. A pause card is `.interrupted`, with the pause reason as its `outcome` (`JobRunner.swift:879-897`). A retry ladder that runs out pauses the job in `apply` (`JobRunner.swift:1514`), and its card is a plain `.failed` card. No card field says "this paused the job".
- **Live asks exist only inside the main window.** `pendingApprovals` (`AppState.swift:377`) holds `ToolApprovalRequest`s (`:281-305`, with `humanOnly` and `requestedAt`). They are drawn only by the overlay on `ChatView` (`ChatView.swift:466`). The array is changed in exactly four places: append (`AppState.swift:3072`), the cancellation removal (`:3084`), `denyPendingApprovals` (`:3091`) and `resolveApproval` (`:3278`).
- **Running is not observable.**
  - `JobRunner.inFlight` is a private `Set<UUID>` of **job** ids (`JobRunner.swift:102`). It is inserted before the gate is asked (`:434`) and removed on a gate refusal (`:444`) and after the run (`:468`). During the gate phase there is no run id yet.
  - `runApproved` (`:1280`) runs an approved call outside `fire`, and so outside `inFlight`.
  - `AppState.activeRuns` is `@ObservationIgnored` (`AppState.swift:402`).
  - `engineTurnCounts` (`:528`) is observed, but a built-in job and a gate run no engine turn.
- **Derived waits exist.** `sessionStatus(for:)` (`AppState.swift:708-737`) ranks a live ask (charged to its delegation root) above a running turn, and a running turn above the three goal waits.
- **Ledger attention.**
  - `unacknowledgedFailures()` (`JobLedger.swift:537`) returns failed and blocked rows that have no `acknowledgedAt`.
  - Approving a blocked call acknowledges its row (`:417-430`).
  - `recentRuns(limit:)` (`:560`) excludes running rows, gate-unchanged completions, stillborn rows and built-ins, so it is not a run log.
  - **`onJobsChanged` holds one hook, and a second call replaces the first** (`:36-40`). The watch resync installs it (`iris.swift:3326`), so no other feature may call it.
- **Dismiss exists only on blocked-call cards** (`ChatView.swift:971-974`). Any other failure is acknowledged only with `/jobs ack` (`AppState.swift:3766`).
- **`/jobs run`** (`AppState.swift:3816-3865`) looks the job up by **name**. It refuses a paused or disabled job with a sentence, then calls `runner.fire(job:origin: .manual)`, which applies overlap, breaker and budget admission. The gate applies only to `.cadence` origins (`JobRunner.swift:553-556`). `FireOrigin` (`:1955-1977`) has `cadence`, `watcher`, `manual` and `queued`. The breaker defaults are 6 runs an hour, and 30 for a watch job (`ConfigManager.swift:292,301`).
- **Job creation asks a human only in Iris or a tainted conversation** (`iris.swift:3532`). Elsewhere the approval set is `run_command` and the file tools (`:4381-4387`). `/jobs` is reached only from the composer (`AppState.swift:1885`).
- **A model can rewrite an existing job.** `register_directory_watcher` on a path that already has a watch updates that job in place: its prompt, profile, grant, `enabled`, and it clears `pausedReason` (`ToolExecutor.swift:380-393`). `JobLedger.upsert` writes every column from the `Job` value (`JobLedger.swift:67-113`).
- **Persistence.** `Job` is stored as SQL columns, read in `job(from:)` (`JobLedger.swift:236`). Its `Codable` decoder uses `decodeIfPresent ?? default` for `action` (`Job.swift:516`). The latest migration is `v18_prefix_mismatch_behavior` (`ConversationStore.swift:581`).
- **App scaffolding.**
  - `IrisApp.init` calls `GUILock.acquire()` first and `installGuardHealthSink()` once (`iris.swift:5180-5204`). That sink is installed there, not in `AppState.init`, so tests never get it (`AppState.swift:2200-2206`).
  - `AppDelegate` implements only `applicationDidFinishLaunching` and `applicationWillTerminate` (`iris.swift:5157-5178`).
  - The scenes are `WindowGroup("Iris")` (`:5239`), `Window("Diagnostics")` (`:5255`) and a static `MenuBarExtra("Iris", systemImage: "sparkles")`, whose "Show Chat" button is an empty placeholder (`:5260-5279`).
  - The hotkey finds the window by title (`:5220`).
  - The deployment target is macOS 14 (`project.yml:4`).
- **The one transcript sheet** hangs off `SessionStripView` in the main window (`SessionStripView.swift:100-105`), and setting `transcriptSheetConversationId` (`AppState.swift:375`) opens it.
- **Identity.**
  - `BuildIdentity` is `.release` only for `com.bnaylor.iris`, and `.dev` for everything else, including the bare binary (`BuildIdentity.swift:15-19`).
  - The hotkey name differs per build (`:28`).
  - Debug is `com.bnaylor.iris.dev` / "Iris Dev" (`project.yml:36-40`).
  - `scripts/run-dev.sh:31` `exec`s the bare `.build/debug/iris`, which has no bundle and no Info.plist.
- **The store lock.** The app *overwrites* the lock (`RunJobCLI.swift:228-235`). The CLI's own comment admits that an app launched during a `--run-job` races it (`:355-358`). `RunJobCLI.makeState` builds a real `AppState` (`:430`).
- **Sparkle** is created with `userDriverDelegate: nil` (`UpdaterController.swift:27`), so it brings no notification delegate to clash with.

## 0. Decided

Each decision gives its default and the reason for it. A reviewer should weigh the cost if wrong.

1. **A notification never approves** (owner ruling 1).
   - The actions are **Open**, **Deny** (live asks) and **Dismiss** (blocked cards). The categories are registered without any approve action, so no code path can add one by accident.
   - *Why:* a banner truncates, a locked screen hides previews, and `humanOnly` exists so nothing but a click with the details in view can authorise. The card rule is the same: "an approval given without sight of the payload is worse than no button" (`EventCard.swift:45-47`).
   - *Cost if wrong:* one extra click to open the app.
2. **One derived attention value.** `SurfaceAttention`, a pure function of `(pendingApprovals, session statuses, runningJobs, LedgerAttention)`. It returns `.actionRequired([Reason])`, `.running(count)` or `.idle`, in that order of precedence. It is computed, never stored. The status item and the run log's header read it. Notifications use the same inputs, through the policy in decision 6.
   - *Why:* four surfaces, one answer, and one producer to move if #331's split ever comes back.
   - *Cost if wrong:* none to speak of; it is a function.
3. **What "action required" means** (owner ruling 3). Something is waiting on the owner and a click resolves it:
   - any live ask;
   - any conversation whose `sessionStatus` is `.waiting` (asks and goal waits);
   - any unacknowledged `blockedOnApproval` run;
   - any paused job whose `pausedReason` is not `JobsCommand.pausedByUserReason`. A breaker, budget, retry-ladder or vanished-folder pause needs `/jobs resume`, and the owner's own pause does not wait on anyone.

   Plain unacknowledged failures, including a job still on its retry ladder, are a count in the menu only. Owner-paused jobs are a count in the menu only. Neither changes the icon.
   - *Why:* an icon that one failed job could leave lit for good stops meaning anything, and a retrying job counts as failed until it succeeds, so the icon would flap.
   - *Cost if wrong:* a failure seen later than it might have been. The menu count and the run log still show it.
4. **The status item is the existing `MenuBarExtra`, with a label that changes.**
   - Menu bar images are template-rendered, so the states differ in **shape**, not colour. Idle is the base symbol. Running is the base symbol plus the count as text. Action required is the base symbol plus `!` and the count.
   - The base symbol is `sparkles` for release and `hammer` for dev, so two running builds can be told apart.
   - The menu lists the reasons with counts ("2 approvals waiting", "pr-sweep blocked: run_command", "1 job paused (budget)", "3 failed runs"). Each row opens the main window on the conversation or card concerned. It also has "Open Run Log…" and a working "Show Chat".
   - All window raising goes through one `showMainWindow(selecting:)`, which the hotkey reuses (`iris.swift:5220`).
   - The status item is plain SwiftUI, so it works in the bare binary too.
   - *Cost if wrong:* the glyphs are constants.
5. **Running becomes observable.** Add a transient, observed `AppState.runningJobs: [UUID: String]`, keyed by job id, with the job name as the value.
   - `JobRunner` reports at the three `inFlight` mutation points through one small async helper, the actor-helper rule. A refusal at `:444` reports as well, so a gate counts as running while it is being asked.
   - `runApproved` reports under the approved run's id for the length of the call.
   - The map is never added to a `Codable` type (the invariant 5 pattern).
   - *Cost if wrong:* a stuck entry shows "running" until relaunch. A test pins the clear on every exit path.
6. **The notification policy is pure, and notification text is harness-owned.** `NotificationPolicy.decide(event, context) -> PlannedNotification?`.
   - It notifies on:
     - a card with `status == .blockedOnApproval`;
     - a card whose job is paused when the card is delivered, read once from `job(id:)?.pausedReason`, because no card field says so;
     - a live ask (owner ruling 4).
   - It does not notify on completed or interrupted runs that paused nothing, on a retrying failure, on reflections, or on the digest.
   - It suppresses a notification for a card when the app is active and the card's conversation is selected. It suppresses one for an ask when the app is active and the main window is visible, because the overlay is global.
   - The title and body use only these fields:
     - the job name, flattened and capped as the briefing does (`IrisEngine.flattenCardField`, `cardNameCap`), since the model chose it;
     - the status;
     - the tool name, flattened;
     - fixed reason words.

     They never use a run's `outcome`, an ask's `details`, a conversation title or a Vibecop reason. All of those are model-, script- or page-written, and on a lock screen such text is a phishing surface ("safe, tap Approve").
   - *Cost if wrong:* a less informative banner. Open shows everything.
7. **Notification mechanics.**
   - A `NotificationSink` protocol property on `AppState`, nil by default.
   - The policy is asked in exactly two places: after the append in `deliverEvent`, and in a `didSet` on `pendingApprovals`. The `didSet` diffs ids, so all four mutation sites are covered, and a removed ask's delivered notification is withdrawn.
   - The identifier is the run id or the ask id.
   - Permission is requested the first time a notification would be posted, never at launch. "Denied", including denied by MDM, is a normal state. It never re-prompts and is never retried.
   - Interruption level is `.active`. `.timeSensitive` needs an entitlement.
   - A response hops to the main actor:
     - **Open** calls `showMainWindow(selecting:)` with the card's conversation, or the ask's delegation root;
     - **Deny** calls `resolveApproval(id:, .deny)`;
     - **Dismiss** calls `dismissEventCard(runId:)`;
     - a response for an ask that has already gone is a no-op, and acknowledging a run twice is harmless.
   - A Settings toggle, "Notifications: Off / Needs attention", defaults to Needs attention and is stored through `ConfigManager`.
   - *Cost if wrong:* a click lands on the wrong conversation. The GUI pass checks this.
8. **Only a real `.app` bundle gets these surfaces** (owner ruling 5).
   - `IrisApp.init`, and nothing else, installs the notifier and sets the `UNUserNotificationCenter` delegate. It does so only when `Bundle.main.bundleURL.pathExtension == "app"`. `UNUserNotificationCenter.current()` raises in an unbundled process, so the check comes before any call into the API.
   - `--run-job` never installs it, even from inside a bundle. `AppState()` in tests has none (invariant 7).
   - The delegate is set in `IrisApp.init`, before `NSApplication` finishes launching, so a click that cold-launches the app is still delivered.
   - Dev testing uses Iris Dev.app (`scripts/build-app.sh Debug`). `run-dev.sh` stays as it is.
   - *Cost if wrong:* the daily dev loop never exercises the notifier. The policy is pure and unit-tested, which is why.
9. **URL triggers are a per-job opt-in that only the owner can set** (owner ruling 2).
   - It is a persisted `Job.urlTrigger: Bool`, default false. The only writer is `/jobs url <job> on|off`.
   - `/jobs url <job>` with no argument prints the state, and the URL when it is on.
   - The job is read from the right: the last token is `on` or `off`, and the rest of the line is the name.
   - `schedule_job` and `register_directory_watcher` have no such argument. `list_jobs` reports the flag read-only.
   - *Cost if wrong:* the owner types one command per job.
10. **Nothing but `/jobs url` writes the flag, and a model rewrite turns it off.**
   - The column is **not** in `upsert`'s insert or `ON CONFLICT` list. A dedicated `setURLTrigger(jobId:on:)` `UPDATE` writes it, so a stale `Job` copy written back by the scheduler, `/jobs reschedule` or a tool cannot set or clear it.
   - `register_directory_watcher`'s update path (`ToolExecutor.swift:380-393`) can change a job's prompt and profile with no click outside Iris. When it updates a job whose flag is on, it clears the flag in the same transaction. Its result says so, and a system line in Iris says so: "URL trigger turned off: the watch was changed".
   - The URL fires only what the owner opted in on.
   - *Cost if wrong:* the owner re-enables the flag after editing a watch by chat.
11. **The URL carries no input, and it fires through `/jobs run`.**
   - The URL is `iris://run-job/<uuid>`, or `iris-dev://run-job/<uuid>` for the dev build. It accepts no query, no fragment, no other host or path, and no slug. A UUID is not guessable, so the URL works as a weak capability.
   - The scheme is per configuration: an `IRIS_URL_SCHEME` build setting in `project.yml`, substituted into `CFBundleURLTypes`, and `BuildIdentity.urlScheme`. The handler refuses the other build's scheme, because two apps claiming one scheme is undefined LaunchServices behaviour.
   - The `/jobs run` body is extracted into `runJobByHand(job:origin:announceTo:)`, which both callers use.
   - A new `FireOrigin.url` records `triggerKind "url"`. It is admitted like `.manual`, skips the gate (only `.cadence` is gated), and meets overlap, the breaker and the budgets. A flood of URL fires pauses the job at the breaker: 6 an hour, or 30 for a watch job.
   - Every fire and every refusal posts one line to Iris naming the source, for example "Fired pr-sweep from a URL" or "Refused a URL fire: pr-sweep has URL triggers off".
   - A URL never creates, edits, resumes or unpauses a job, and no route for those exists.
   - Because no URL content reaches a model, the taint (`hasUnattendedInput`) is untouched. Adding any parameter later, such as #330 script arguments or a `?prompt=`, reopens this decision, because the URL would then be unattended input.
   - *Cost if wrong:* budget burn up to the breaker, and a mutating job acting at a time the owner did not choose. Both are bounded, and both are visible in Iris.
12. **The store-lock hazard: a mitigation in D6, the fix later.**
   - A URL can launch a closed app while `iris --run-job` holds the store, and the app's overwrite then makes two writers.
   - D6 does three things:
     - (a) `IrisApp.init` reads `GUILock.state` before `acquire`, and keeps the foreign pid if one is live;
     - (b) it posts a launch notice to Iris: "Another Iris process (pid N) held the store at launch";
     - (c) URL fires are refused while that pid is still alive, with a line saying why.
   - Launch is never blocked.
   - **Fix direction, not in D6** (a new issue): the app waits, with a bound and visibly, for a live CLI holder before opening the store. Or the CLI watches the lock file and ends its run as `interrupted` when the app takes over.
   - *Cost if wrong:* the race stays as it is today, with a warning added.
13. **The run log is a window that reads the ledger.**
   - It is `Window("Run Log", id: "run-log")`, backed by a new `JobLedger.runLog(limit:before:jobId:status:)` that pages by `(startedAt, rowid)`. It includes running rows, built-ins and stillborn rows. Gate-unchanged rows are hidden by a toggle that is off by default.
   - The columns are started, duration, job, trigger kind (`url` included), status, weighted tokens and outcome. The outcome is shown in the window as plain text, and it is never sent to a model or a notification.
   - **Acknowledge** appears on any unacknowledged failed or blocked row. This is the one-click way to clear a plain failure that ruling 3 needs.
   - **No Approve** in the log. The blocked call and its verdict live on the card, so the row links to the card instead.
   - A row with a live transcript raises the main window and sets `transcriptSheetConversationId`, which keeps one sheet in the app. A pruned one reads "transcript pruned".
   - The log refreshes on appear, and when `LedgerAttention` changes.
   - *Cost if wrong:* the transcript opens in the other window. A sheet owned by the log can come later.
14. **The ledger attention snapshot is cached, and is never polled.**
   - `AppState.ledgerAttention`: blocked-unacknowledged, failed-unacknowledged, attention-paused and owner-paused, each with names for the menu.
   - It is read off the main actor and assigned on it, in these places:
     - at launch;
     - after `deliverEvent`, which every pause, block and failure reaches;
     - after each acknowledge path (`dismissEventCard`, `/jobs ack`, the log's Acknowledge);
     - after `/jobs pause|resume|delete`;
     - from the existing `onJobsChanged` closure (`iris.swift:3326`), by adding one call to it, **never** by installing a second hook, which would silently replace the watch resync.
   - *Cost if wrong:* a menu count that lags by one event.

## 1. Components

- **`SurfaceAttention`** (new, pure): decision 2's value and its `Reason`s, with the menu's sentences.
- **`AppState`**:
  - `runningJobs` and the `JobRunner` helper;
  - `ledgerAttention` and its refresh;
  - the `notificationSink` property and the `pendingApprovals` `didSet`;
  - `showMainWindow(selecting:)`;
  - `runJobByHand(job:origin:announceTo:)`;
  - `handleRunJobURL(_:)`, which parses, refuses, fires and announces.
- **`NotificationPolicy`** (new, pure) and **`UserNotificationSink`** (new, the only file that imports `UserNotifications`): categories, the permission state, posting, withdrawal and responses.
- **`RunJobURL`** (new, pure): `parse(URL, identity:) -> Result<UUID, Refusal>`.
- **`IrisApp` / `AppDelegate`**:
  - the dynamic `MenuBarExtra` label and menu;
  - the `Run Log` scene;
  - the bundle-guarded notifier install;
  - `application(_:open:)`;
  - the pre-acquire `GUILock.state` read.
- **`RunLogView`** (new) over `runLog(...)`.
- **Ledger:**
  - migration `v19_job_url_trigger` (a nullable `urlTrigger INTEGER`, where NULL means false);
  - `setURLTrigger`;
  - the read in `job(from:)`;
  - `decodeIfPresent(...) ?? false` in `Job.init(from:)` (invariant 1);
  - `runLog(...)`.
- **`JobsCommand`:** the `url` verb, and its entry in `usageText`.
- **`FireOrigin.url`.**
- **`project.yml` / `App/Info.plist`:** `IRIS_URL_SCHEME` and `CFBundleURLTypes`.

## 2. Agent-facing text and docs (invariant 9)

Search, then fix:
- `list_jobs`' description and fields (the new flag);
- `register_directory_watcher`'s description (an update turns the URL trigger off);
- `JobsCommand.usageText`;
- `docs/jobs.md`: `/jobs`, the trigger kinds (add `url`), acknowledging a failure (the log now does it), and where news appears (notifications, the menu bar);
- the README's mentions of "the menu bar item" (README:266) and of features, which gain notifications, the URL and the run log.

Dated specs are history and are not edited.

## 3. Verification

**Unit tests** (Swift Testing, with injected stores, `ConfigManager(store:)` and `IrisPaths(root:)`, never `.shared`; invariant 7):
- `SurfaceAttention`:
  - a table covering asks, a delegate's ask charged to its root, goal waits, running jobs, and each ledger count;
  - the precedence;
  - plain failures and owner pauses never produce `.actionRequired`.
- `runningJobs`:
  - set and cleared on a completed, failed, blocked and interrupted run;
  - set and cleared on a gate refusal and on a built-in;
  - set and cleared during `runApproved`, using `JobRunnerTests`' harness.
- `NotificationPolicy`:
  - which events notify;
  - both suppressions;
  - a planted string in `outcome`, the ask's `details` and the conversation title never appears in the title or body;
  - no category contains an approve action.
- Sink wiring:
  - `AppState()` and `RunJobCLI.makeState` have no sink;
  - a fake sink sees exactly one post per notifying card;
  - the `didSet` posts on append and withdraws on each of the four removal paths;
  - Deny resumes the continuation with `false`;
  - a stale id is a no-op;
  - the bundle guard is false for a non-`.app` URL.
- `RunJobURL` and `handleRunJobURL`:
  - a valid URL is accepted;
  - each of these is refused with a line in Iris: a slug, a query, a fragment, extra path parts, the other build's scheme, an unknown job, a disabled job, a paused job, a job that has not opted in, and a foreign live lock holder;
  - an accepted fire writes `triggerKind == "url"`, skips the gate, and is still refused at the breaker.
- Opt-in:
  - a pre-D6 job row loads `urlTrigger == false`;
  - `upsert` of a stale copy does not change the flag;
  - a `register_directory_watcher` update clears it and says so;
  - `/jobs url` parsing, including a name ending in "on".
- `runLog`: paging and filters, the inclusions, Acknowledge stamps `acknowledgedAt`, and the pruned-transcript state.
- `ledgerAttention`:
  - it refreshes after deliver, acknowledge and the `/jobs` verbs;
  - the `onJobsChanged` closure still resyncs watches (the existing watch tests stay green).
- **Full suite:** exit 0, the Swift Testing line, and XCTest's "Executed N tests, with 0 failures". A filtered run is cited through `scripts/test-filter.sh` with its test count.

**GUI checks, under the `gui-test-lease`** (acquire before launching, release as soon as the pass ends). Run on Iris Dev.app from `scripts/build-app.sh Debug`, signed with `scripts/sign.sh`:
- the permission prompt on the first notification, then the denied path: no re-prompt and no crash;
- a blocked card's banner with the app inactive: Open lands on the card, and Dismiss acknowledges it;
- a live ask with the window hidden: the banner appears, Deny unparks the turn with a denial, and resolving the ask in the app withdraws the banner;
- the icon through idle → running (a one-minute job) → action required (a blocked job) → idle after Dismiss. A failed job leaves the icon alone and raises the menu count. With both builds running, the release and dev icons can be told apart;
- `open 'iris-dev://run-job/<uuid>'` with the app running and with it quit, then the same from Shortcuts' "Open URL" and from Raycast. **Spike first:** whether SwiftUI's `WindowGroup` opens a second window on an external URL, and whether `.handlesExternalEvents(matching: [])` or `application(_:open:)` alone prevents it;
- the Run Log: a row opens the transcript sheet, and Acknowledge clears the menu's count;
- the bare `scripts/run-dev.sh`: it launches with no crash and the status item works.

## 4. PR split

Every PR is based on `main` and none is stacked. A later PR rebases on `main` after an earlier one merges.

| PR | Contents | Depends on |
|---|---|---|
| A | Decisions 2–5 and 14: `SurfaceAttention`, `runningJobs`, `ledgerAttention`, the dynamic `MenuBarExtra`, `showMainWindow` (the hotkey reuses it) | — |
| B | Decision 13: `runLog(...)`, the Run Log window, Acknowledge | none (reads the ledger directly; once A has merged, it refreshes on A's snapshot) |
| C | Decisions 1, 6–8: the policy, the sink, categories, Settings, the bundle guard, responses | A merged |
| D | Decisions 9–12: migration v19, `setURLTrigger`, `/jobs url`, the watcher-update clear, `FireOrigin.url`, `runJobByHand`, `RunJobURL`, the scheme in `project.yml`/Info.plist, the lock mitigation, the window spike | none |

Each PR carries its own slice of §2's docs sweep.

## 5. Not in this deliverable

- Any approve action on a notification (ruling 1).
- URL parameters of any kind, and URL fires for #330's script actions with arguments (decision 11).
- The store-lock fix: the app waiting for a CLI holder, or the CLI yielding (decision 12; new issue).
- A Dismiss on failed cards, as distinct from Acknowledge in the log.
- Notifications for completed runs, reflections or the digest. A finer per-kind setting.
- Making `run-dev.sh` build the `.app`.
- Push notifications, and `.timeSensitive` interruption.
