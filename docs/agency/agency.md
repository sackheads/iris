# Iris Gains Agency

*Authors: Scromp (draft), Rune (review), Clomp (review), Claude Fable 5.1 (review and synthesis). The individual documents are `01`–`04` in this directory; this one is the proposal.*

## What

Iris has a good harness for a conversation and a long detour into `/goal` land. It does not yet act on its own. This epic gives Iris a background: jobs and watches that run without a conversation open, results that reach me without burying the conversation I use every day, and one pinned "main" conversation that knows what the rest of Iris has been doing.

About a third of this already exists. `schedule_job` persists jobs, catches up after sleep, and fires them as system events. `register_directory_watcher` watches directories with `FSEventStream`. Both fire a full model turn into whichever conversation is selected, which is the behaviour I complain about most. So the first deliverables are changes to running code, not new subsystems.

## Why

- Every job fire today lands in a visible conversation as a system event plus a model turn. That is the "pops into the conversation list" problem, and at fifteen-minute cadences it is also the context trap Clomp describes: the conversation fills with telemetry and the model starts associating my questions with unrelated checks.
- Hermes runs a job, dumps its output in the DM, and has no idea it did so. I want to discuss a result without pasting it back.
- A job that needs approval today would block on a modal nobody is there to answer.
- Nothing records that a job ran, what it cost, or that it has been failing for a week.

## Non-goals

- Iris never performs a mutating action unattended unless the job was created with that permission and the action is inside the job's declared scope. Read-only is the default profile.
- No LaunchAgent, helper daemon, or `BGTaskScheduler` in this epic. Background agency requires the app to be running. This is a stated constraint on a corp-managed laptop, not an oversight; the ledger is designed so a helper can be added later without changing the data model.
- No general cross-conversation memory. The main conversation gets tools and a briefing, not the contents of every other chat in its context.
- No new delivery mechanism. Results ride the plumbing we already have.

## Two decisions before anything else

**1. Substrate: in the app.** Jobs and watches run inside the Iris process. The scheduler already survives sleep via `NSWorkspace.didWakeNotification` and recomputes `nextFireAt` after a fire, so a weekend asleep produces one catch-up run per job, not a stampede. We add a sleep assertion for the duration of a run, capped at the run's timeout, and a per-job `catchUp` policy: `coalesce` (default), `skip`, `replay`. `replay` is the stampede Clomp warned about with a different name; it carries a hard per-job cap on replays per wake and is off unless a job asks for it.

**2. Unattended actions fail closed.** A background run never blocks on an approval. A tool call that would need one fails immediately with a structured status; the run turns that into a proposal card in the destination conversation ("job `pr-sweep` wants to run `git push origin main`; Approve and run / Dismiss"). Approving dispatches the action as a tracked foreground turn. Every job declares a profile: `readOnly` runs autonomously; `mutating` runs in the `apple/container` sandbox unless the job carries an explicit waiver that I granted in the main conversation when the job was created. Deterministic jobs with no model involvement are the encouraged default.

Everything else forks on these two, which is why they come first.

## Architecture

One pipeline, two kinds of trigger:

```
schedule (cron subset, tz-aware) ─┐
fs event (debounced, self-writes filtered) ─┼─► gate (deterministic, no model) ─► run (IrisEngine turn, background profile) ─► deliver + ledger
poll (script at a cadence) ─┘
```

- **Trigger.** `.schedule`, `.fsEvent`, `.poll`. A poll is a schedule whose gate is a script; it exists as a trigger type so the model has a name for it. Existing `ScheduledJob` and `WatcherRule` records import into this model.
- **Gate.** A check that returns a signal and an optional diff. No model tokens are spent unless the gate says something changed. The gate is code the model wrote, and it runs on every tick with nobody watching, so it gets the same treatment as a mutating tool: either one of a fixed set of built-in checks (HEAD of a URL, mtime or hash of a path, exit code of a script) or a script run through the `run_command` sandbox path in the `apple/container` VM with the job's declared mounts. A gate never executes free-form on the host, and creating or editing one is Vibecop-reviewed like any mutating action. Gate output is untrusted input and passes the InjectionGuard tiers before any model sees it, the same path system events use today.
- **Run.** An `IrisEngine` turn in a background conversation: hidden from the sidebar, subject to the job's profile, Vibecop, sandbox preference, and budget. It has the normal tool surface minus anything the profile forbids. Its transcript is stored like any conversation so `#177` search covers it.
- **Deliver.** A compact event card (job, status, one-line outcome, run id) to the job's destination: the main conversation by default, or a designated one. If the destination is mid-turn, the card rides the `#173` steer inbox so the model sees it with its next tool results. Raw output never enters `messages`.
- **Ledger.** A `job_runs` table beside the conversation store: job, trigger, started, finished, status, tokens, cost, gate signal, transcript conversation id, failure reason. The ledger is the answer to "what happened", the source of the briefing, and the thing a future helper process would write to.

### The main conversation

A conversation with `isPinned`, kept at the top of the list, never auto-renamed, never deleted by `/clear`. It is not a different engine. It differs from other conversations in three ways:

- **Briefing.** Its system prompt gets a `<recent_activity>` block: the last five notable ledger events (failures first), one line each. Capped, so it cannot grow.
- **Tools.** `list_jobs`, `get_job_run(id)`, `search_conversations(query)`, `read_conversation(id, range)`, declared only in the pinned conversation (invariant 6: no dead-weight declarations on other turns). Subagent and evaluator scratch conversations are excluded from search and read. Text read this way passes the InjectionGuard tiers under the tool-output tag with tool-call markers stripped, exactly as a `run_command` result does.
- **Anchoring.** Memory reflection and the daily digest job report here.

Lands after `#163` and `#177`.

### Failure and concurrency

- Overlap: a trigger that fires while the same job is running is dropped and counted (`skip`), or queued once (`queue`), per job. Never concurrent with itself.
- Retry: failed runs back off exponentially up to three attempts, then the job pauses and the main conversation gets a card. A paused job stays paused until I say otherwise.
- Budget: tokens per run and per day, per job, plus a global daily background budget. Exceeding any of them pauses the job with a card. The ledger's token column is how we know.
- Breaker: more than N runs per hour pauses the job. N defaults low.
- Loop guard: a watch ignores events on paths Iris itself wrote in the last quiet window, and every fs watch has a quiet window (default 3 s) on top of the stream latency.
- Digest: a deterministic daily job summarizes the ledger into one card. "Failing silently for a week" cannot happen without someone deleting that job.

### Observability

`/jobs` in any conversation lists jobs with last status and next fire. A run log view shows the ledger with the transcript one click away. `iris --run-job <id>` runs a job headlessly so the eval harness can measure a gate's false-positive rate and a job's cost before the job is trusted; nothing lands unmeasured, same as every other Iris feature.

### Native surfaces (later)

`UNUserNotificationCenter` banners with actions for high-priority cards, an `NSStatusItem` showing idle / running / action required, and an `iris://run-job/<id>` URL scheme for Shortcuts and Raycast. Useful, additive, last.

## Deliverables, in order

1. **Policies and model.** Write the two decisions above into the spec; define the unified trigger, profile, and ledger schema; import existing jobs and watcher rules. Adopt a cron subset with lists, ranges, steps, and a timezone per job (closes `#156` properly). — landed: see `docs/specs/2026-09-21-agency-model-and-ledger.md`; PR pending
2. **Ledger and delivery.** `job_runs` beside the conversation store; background conversations hidden from the sidebar; event cards; steer-inbox delivery; `get_job_run`; stop writing job output into `messages`.
3. **Runtime.** Gate execution, background profile, fail-closed approvals with proposal cards, budgets, breaker, overlap policy, retry and pause, sleep assertion and `catchUp`, `iris --run-job`.
4. **Watches.** Fold `WatcherManager` onto the trigger model; quiet window; self-write filter; poll trigger.
5. **Main conversation.** Pin, briefing, tools, anchoring. After `#163` and `#177`.
6. **Native surfaces.** Notifications, status item, URL scheme, run log view.

Each is an issue with its own spec and measured verification; this document is the epic they hang from.

## Decided in review

- **Sandbox always.** A `mutating` job runs in the `apple/container` VM, full stop. A waiver widens the tool allowlist inside the container; it never drops isolation. Unattended mutation on the bare host of a corp-managed Mac is a risk with no upside.
- **Briefing cap: five recent events, plus every unacknowledged failure and paused job pinned until dismissed or resolved.** A strict five-slot window would let five trivial successes roll a failure out of sight, which is "failing silently" coming back through the side door.
- **No unattended job creation.** A run may propose a job with a card in the main conversation; committing it to the schedule takes a human click. Otherwise triggers create triggers.
