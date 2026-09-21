# Agency: Job Model and Run Ledger (deliverables 1 and 2 of #187) — Design

**Status:** implemented on branches `feat/agency-d1-job-model` (PR #252) and `feat/agency-d2-ledger-runs-cards` (PR pending) (written overnight 2026-09-21 under a pre-agreed decision set; every ruling made without the author of #187 is listed in §14)
**Issue:** #187 (`docs/agency/agency.md` is the epic; this spec is its first two deliverables)
**Builds on:** #163 (conversation store), #182 (archiving), #172/#173 (mid-turn steering), #217 (session strip), #247 (sessions slice 1: migration v8), #156 (weekdays, superseded here)
**Does not touch:** #185 (peer sessions), deliverables 3–6 of the epic

## 1. Overview

Today a scheduled job or a directory watcher fires a full model turn into whichever conversation
is selected. `ScheduleManager` keeps jobs as a JSON blob in `UserDefaults`, `WatcherManager` keeps
rules the same way, nothing records that a run happened or what it cost, and a run that needs an
approval blocks on a dialog nobody is there to answer.

This spec replaces both with one **job** model stored in the conversation database, runs each job
in its own hidden conversation, records every run in a **ledger**, and delivers the outcome as a
compact **event card** into a destination conversation without waking a model turn there.

Two decisions from the epic shape everything below and are not re-opened: jobs run **inside the app
process**, and unattended actions **fail closed**.

## 2. Scope

**Deliverable 1 — policies and model.** The `Job` type, the trigger model with a cron subset and a
per-job time zone, the profile, the `jobs` table, and the `schedule_job` /
`register_directory_watcher` tools rewritten to create jobs. The old `ScheduledJob`, `WatcherRule`,
and their `UserDefaults` keys are removed.

**Deliverable 2 — ledger and delivery.** The `job_runs` table, the background run conversation,
fail-closed approvals, the event card and its delivery, the "Iris Activity" destination, retention,
`get_job_run`, `list_jobs`, and `/jobs`.

**Out of scope (later deliverables, named so nobody looks for them here):** gate execution and the
`.poll` runtime, budgets, breaker, retry and pause, overlap policy beyond `skip`, sleep assertion
and `catchUp` policy, `iris --run-job`, quiet window and self-write filter for watches, the pinned
main conversation's briefing and read tools, notifications, status item, URL scheme, and any
Settings surface for jobs. Cost calculation (§6.3).

**No import.** Nobody has real jobs or watcher rules. The old keys `iris_scheduled_jobs` and
`WATCHER_RULES` are deleted from `UserDefaults` on first launch of a build containing migration v9.

## 3. The job

```swift
struct Job: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String                   // slug, unique, model-chosen or derived from the prompt
    var prompt: String                 // what the run is asked to do
    var trigger: Trigger
    var profile: JobProfile            // .readOnly | .mutating — only .readOnly is creatable in D2
    var destinationConversationId: UUID?   // nil = the Iris Activity conversation (§8)
    var createdInConversationId: UUID?
    var createdAt: Date
    var enabled: Bool
    var nextFireAt: Date?              // schedules only; recomputed after every fire
    var lastRunAt: Date?
    var pausedReason: String?          // nil = not paused; D3 sets it; D2 only reads it
}

enum JobProfile: String, Codable, Sendable { case readOnly, mutating }
```

Every persisted type here has a hand-written `init(from:)` using `decodeIfPresent` with the
defaults above (AGENTS.md invariant 1). `Job` decodes with `profile = .readOnly` and
`enabled = true` when those are absent; a row whose `trigger` payload is unreadable is skipped and
counted (§4), never fatal for the table.

### 3.1 Triggers

```swift
enum Trigger: Codable, Equatable, Sendable {
    case schedule(Schedule)
    case fsEvent(FSWatch)
    case poll(PollSpec)          // defined for the schema; not creatable until gates land (D3)
}

enum Schedule: Codable, Equatable, Sendable {
    case cron(CronSchedule)
    case interval(seconds: Int)  // "every 90 s" is not expressible in cron; kept as its own form
}

struct CronSchedule: Codable, Equatable, Sendable {
    var expression: String       // five fields: minute hour day-of-month month day-of-week
    var timeZone: String         // IANA identifier, e.g. "America/Los_Angeles"
}

struct FSWatch: Codable, Equatable, Sendable {
    var path: String
    var quietWindowSeconds: Int  // stored now (default 3), enforced by D4
}

struct PollSpec: Codable, Equatable, Sendable {
    var schedule: Schedule
    var gate: String             // script; executed by D3
}
```

**Cron subset.** Each field accepts `*`, a number, a list `1,15`, a range `1-5`, and steps `*/15`
or `1-5/2`. Day-of-week is `0-6` with `0` = Sunday and `7` accepted as Sunday, the cron convention.
Month `1-12`, day-of-month `1-31`, hour `0-23`, minute `0-59`. Names (`MON`, `JAN`) are not
accepted. Day-of-month and day-of-week combine with OR when both are restricted, as in Vixie cron.
Anything else is a parse error returned to the model.

`CronSchedule.next(after date: Date, calendar: Calendar) -> Date?` is a pure function. It walks
forward minute by minute from `date + 1 min` in the schedule's time zone, checking fields, and
gives up after four years (1,466 days; returns nil, which disables the job with `pausedReason =
"no matching time in the next four years"`). Four years, not one, so `0 0 29 2 *` is schedulable.
Minute-stepping with day and hour skip-ahead is simple, correct across DST and month boundaries,
and fast: the worst realistic case (`0 0 29 2 *` asked in March) is a few thousand day-steps. The calendar parameter exists for tests; production passes `Calendar(identifier:
.gregorian)` with the job's zone.

**Aliases.** `schedule_job` keeps accepting `minute`, `hour`, `day`, `month`, `weekday` (1 = Sunday
… 7 = Saturday, the Foundation numbering the tool has always used), `weekdays`, and
`intervalSeconds`. They are translated to a cron expression or an interval at creation and the job
stores only the translation. `weekday`/`weekdays` values are converted with `cronDay = weekday - 1`.
A test pins that every alias combination the old `calculateNextFireDate` accepted yields the same
next fire time under the new model.

### 3.2 Profile

`readOnly` is the default and the only profile `schedule_job` accepts in this slice. `mutating`
exists in the model so the ledger and the card can name it; creating one is refused with "mutating
jobs arrive with deliverable 3". When it does arrive, a mutating job always runs sandboxed; the
policy is recorded here so nothing in D1/D2 assumes otherwise.

In a read-only run of this slice the tool surface is the normal one, and §7's fail-closed approvals
are the only enforcement — which is weaker than the name suggests: only `run_command`,
`read_file` and `write_file` reach the approval path today, so `create_skill`, `update_soul`,
`update_memory`, `save_fact`, `set_workspace` and their kin run ungated. The real read-only
profile — tools omitted from the declaration and failed closed at dispatch, per the denylist in
`docs/specs/2026-09-21-agency-runtime.md` §0.2 — is deliverable 3's. Until then "read-only" means
"cannot pass an approval gate unattended", no more.

## 4. Storage: migration `v9_jobs`

Both tables live in the conversation database, registered as one migration after `v8_session_card` (#185 slice 1, #247):

```sql
CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  prompt TEXT NOT NULL,
  triggerKind TEXT NOT NULL,            -- schedule | fsEvent | poll (queryable without JSON)
  trigger TEXT NOT NULL,                -- JSON of Trigger
  profile TEXT NOT NULL DEFAULT 'readOnly',
  destinationConversationId TEXT,
  createdInConversationId TEXT,
  createdAt DATETIME NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT 1,
  nextFireAt DATETIME,
  lastRunAt DATETIME,
  pausedReason TEXT
);
CREATE INDEX jobs_due ON jobs(enabled, nextFireAt);

CREATE TABLE job_runs (
  id TEXT PRIMARY KEY,
  jobId TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  jobName TEXT NOT NULL,                -- denormalized so a card survives a rename
  triggerKind TEXT NOT NULL,
  startedAt DATETIME NOT NULL,
  finishedAt DATETIME,
  status TEXT NOT NULL,                 -- running | completed | failed | blockedOnApproval | interrupted
  outcome TEXT,                         -- one line, <= 200 chars
  failureReason TEXT,
  blockedTool TEXT,                     -- set with blockedOnApproval
  promptTokens INTEGER NOT NULL DEFAULT 0,
  candidateTokens INTEGER NOT NULL DEFAULT 0,
  totalTokens INTEGER NOT NULL DEFAULT 0,
  costMicros INTEGER,                   -- reserved; nothing computes it yet (§6.3)
  gateSignal TEXT,                      -- reserved for D3
  transcriptConversationId TEXT,        -- no FK: the transcript is pruned independently (§10)
  acknowledgedAt DATETIME
);
CREATE INDEX job_runs_by_job ON job_runs(jobId, startedAt);
CREATE INDEX job_runs_open ON job_runs(status, acknowledgedAt);
```

Two columns are added to `conversations`, both nullable so absent reads as false:
`isBackground BOOLEAN` and `isPinned BOOLEAN`.

Access goes through a new `JobLedger` that shares the store's `DatabaseWriter`:

```swift
final class JobLedger: Sendable {
    init(writer: any DatabaseWriter)
    func upsert(_ job: Job) throws
    func delete(jobId: UUID) throws
    func jobs() throws -> [Job]
    func job(named: String) throws -> Job?
    func dueJobs(at: Date) throws -> [Job]
    func begin(run: JobRun) throws
    func finish(runId: UUID, status: JobRun.Status, outcome: String?, failureReason: String?,
                blockedTool: String?, tokens: TokenUsage, finishedAt: Date) throws
    func run(id: UUID) throws -> JobRun?
    func runs(jobId: UUID, limit: Int) throws -> [JobRun]
    func acknowledge(runId: UUID, at: Date) throws
    func prune(now: Date, rowRetention: TimeInterval, transcriptsPerJob: Int) throws -> PruneDecision
}
```

`ConversationStore` exposes it as `let ledger: JobLedger`, built in `init(writer:path:)`, so
`inMemory()` gives tests a ledger for free. Rows decode through the same lenient path as
conversations: a row whose JSON fails to decode is skipped and counted, never fatal. Unlike
conversation payloads, a bad job row is not quarantined; it is reported once in the log and by
`/jobs` as "1 unreadable job".

## 5. Scheduling

`JobScheduler` (an actor owned by `IrisEngine`, replacing `ScheduleManager`) polls
`ledger.dueJobs(at: now)` every 10 s and on `NSWorkspace.didWakeNotification`, exactly the cadence
the old code had. For each due job it recomputes and stores `nextFireAt` first, then asks
`JobRunner` to run it. A job whose next fire cannot be computed is disabled with a
`pausedReason` and a failed ledger row so the failure is visible.

**Catch-up** stays what it is today: a job asleep through several ticks fires once and is
rescheduled from now. The one change is a cap: at most **three** due jobs start per tick; the rest
wait for the next tick. That bounds the wake stampede the epic worries about without designing
the `catchUp` policy, which is D3's.

**Overlap** is `skip`: a trigger for a job whose previous run is still `running` is dropped and the
ledger gets a row with status `interrupted`, outcome "skipped: previous run still in progress",
and no transcript. D3 adds `queue`.

**Watches.** `WatcherManager` stays as the FSEvent runtime but no longer owns rules: it starts a
watcher for every enabled `.fsEvent` job at launch and on job creation, and on a change batch it
asks `JobRunner` to run the job with the changed paths appended to the prompt. The quiet window
and self-write filter remain D4; today's 1 s stream latency is what there is.

## 6. The run

### 6.1 Background conversation

`JobRunner.run(job:, reason:)` creates a conversation with `isBackground = true`, title
`"<job.name> · <ISO timestamp>"`, `mainAgentSandbox` taken from the job's profile (`.mutating` →
`.sandboxed`, `.readOnly` → nil, meaning the global default), and no selection change. It writes
the ledger row with `status = running`, then calls
`processInput(job.prompt, source: "job:<name>", conversationId:)`. `isBackground` is a new,
persisted flag; it is not `isSubagent`, because subagent conversations are deliberately never
written to disk and a run transcript must be (the epic wants #177 search to cover it).

`isBackground` conversations are hidden from both sidebar sections, excluded from the archive
sweep, never auto-titled, and included in FTS. They appear in the session strip like any engine
turn while running, with role `job:<name>`.

### 6.2 Recording the outcome

When the turn ends, `JobRunner` finishes the row: `tokens` = the conversation's `tokenUsage`
delta across the run, `outcome` = the first line of the last agent message truncated to 200
characters (or the failure reason), `status` = `completed`, or `failed` when the turn ended with
an `[LLM_ERROR]`, an uncaught tool failure, or the loop detector's soft stop, or
`blockedOnApproval` (§7), or `interrupted` when the app quit mid-run (detected at next launch:
any `running` row is closed as `interrupted` with reason "app was not running").

### 6.3 Cost

There is no pricing table anywhere in Iris. `costMicros` is created now so the schema does not
change when one exists, and it stays NULL. Cards and `/jobs` show tokens, not money. A follow-up
issue covers pricing.

## 7. Fail-closed approvals

`AppState.requestApproval` gains one branch before the auto-approve check: if the conversation is
`isBackground`, it records `(toolName, details)` in a new transient
`backgroundDenials: [UUID: [BlockedToolCall]]`, appends a `.system` message "Not run: `<tool>`
needs approval, and this is an unattended run" to the run transcript, and returns `false`. Nothing
is enqueued in `pendingApprovals`, so no dialog appears and the run is never blocked. The tool
result the model sees is the existing denied-approval result. At the end of the run, if any denial
was recorded the row's status is `blockedOnApproval` and `blockedTool` names the first one; the
card names it too. D3 turns that card into "Approve and run".

`autoApproveTools` is untouched: it means "always yes" for tests and the scenario runner, which is
the opposite of this.

## 8. Delivery: the event card

### 8.1 Destination

`job.destinationConversationId` if set, otherwise the **Iris Activity** conversation: one ordinary
conversation, created on first delivery with title "Iris Activity", `isPinned = true`, recorded in
`meta` under key `activity_conversation_id`. It is never the selected conversation by rule: if a
job's stored destination *is* the selected conversation at delivery time the card still goes there,
because the user chose it when creating the job; the default never does. An archived destination
receives the card without being un-archived, which is the one way an arrival differs from #182's
rule for user-visible work: a card is a record, not work.

`isPinned` conversations sort first in the sidebar, above the search results and the rest, and
`/clear` refuses them. Only the Activity conversation sets it in this slice; D5 generalizes.

### 8.2 The card

A new `ChatRole.event` case. The message `content` is the JSON of:

```swift
struct EventCard: Codable, Equatable, Sendable {
    let kind: String            // "job_run"
    let runId: UUID
    let jobId: UUID
    let jobName: String
    let status: JobRun.Status
    let outcome: String?        // one line
    let blockedTool: String?
    let startedAt: Date
    let finishedAt: Date
    let totalTokens: Int
    let transcriptConversationId: UUID?
}
```

`MessageView` renders `.event` as a one-line card: status glyph, job name, outcome, elapsed and
tokens, and a "View run" action that opens the transcript in the same read-only sheet #217 uses for
subagents. "Copy Transcript" renders it as `[job pr-sweep · completed · 4.2k tokens] outcome`. An
older build that reads a `.event` message quarantines that row (unknown enum case), which is the
correct failure for a downgrade and the same one every new enum case has had.

FTS is not extended to `.event`; the ledger is the searchable record of runs.

### 8.3 What the model sees

A card never wakes a model turn. The destination's model context still has to know a card arrived
the next time the user talks there, so delivery also appends one `Content` to the destination's
`history`: role `user`, text `[Event] job <name> <status>: <outcome> (run <short id>)`. It is
labelled as an event and passes `InjectionGuard` under tag `event_card`, tier 1 only: every field
in it is harness-written or harness-normalised except `outcome` — `<name>` arrives through
`schedule_job`'s arguments and is model-supplied, but `Job.slug(from:)` reduces it to an
`[a-z0-9-]` allowlist of at most 32 characters, so no delimiter survives — and `outcome` is
model-written by the run, truncated to one line, so it gets the same treatment as the session
strip's activity text.

If the destination has a turn in flight, the history line is **not** appended immediately: a
`user` entry landing between a function call and its response corrupts the request. It goes into a
per-conversation `pendingEventLines` queue that the engine drains at the same point it takes steers
(`takePendingSteers`), which is a safe boundary. Since #247 that queue also carries peer arrivals with an `isPeer` flag; event lines stay a separate queue because they must never start a turn. Leftovers at turn end are appended
directly, without starting a turn; `drainPendingUserMessages` never sees them. The UI message is
appended immediately in both cases.

## 9. Tools and commands

- `schedule_job` (all conversations, as today): `prompt` (required), `name` (optional slug; derived
  from the prompt when absent, made unique with a numeric suffix), `cron` + `timezone` (defaults to
  the system zone) **or** `intervalSeconds` **or** the aliases in §3.1. Returns the job name, the
  resolved cron/interval, and the next fire time in the job's zone. Refuses `profile: mutating`
  and `.poll`. Its description no longer claims wake-specific catch-up machinery.
- `register_directory_watcher` (all conversations, as today): `path`, `instructions`; creates an
  `.fsEvent` job named after the path's last component. Stays in `trustedTools`.
- `list_jobs` and `get_job_run(run_id)`: declared only in `isPinned` conversations (invariant 6).
  `list_jobs` returns name, trigger summary, enabled, next fire, last status. `get_job_run` returns
  the ledger row and the first 2,000 characters of the transcript's last agent message, guarded
  under tag `tool_output_get_job_run`.
- `/jobs` (any conversation, deterministic, no model turn): a table of jobs with last status and
  next fire, plus a line per unacknowledged failure. `/jobs ack <run id>` sets `acknowledgedAt`.
  `/jobs delete <name>` removes a job and cascades its runs; transcripts are left to retention.

## 10. Retention

`ledger.prune(now:rowRetention: 90 days, transcriptsPerJob: 20)` runs at launch and once a day:
ledger rows older than 90 days are deleted unless `status ∈ {failed, blockedOnApproval}` and
`acknowledgedAt` is NULL; for each job, background conversations beyond the 20 most recent by
`startedAt` are deleted unless referenced by such an unacknowledged row. Deleting a transcript
leaves `transcriptConversationId` dangling on purpose; the card's "View run" says "transcript
pruned". The prune is a pure decision over `[JobRun]` + `[UUID: Date]` with the deletions applied
by the caller, so the policy is unit-tested without a clock.

## 11. What is removed

`ScheduledJob`, `ScheduleManager`, `WatcherRule` and the two `UserDefaults` keys;
`handleSystemEvent`'s scheduler and watcher callers (it stays for subagent post-backs). The
`ScheduledJobWeekdaysTests` suite is replaced by the cron and alias tests. README lines that
describe the old behaviour (feature bullets 20 and 25, the un-archive bullet's "scheduled job"
example, the `schedule_job` entry) are rewritten; `docs/prompt_injection_guard_design.md`'s
trusted-tool sentence is checked; `docs/agency/agency.md`'s deliverables 1–2 get a "landed in"
pointer.

## 12. Testing

All Swift Testing, none touching `~/.iris`, `ConfigManager.shared`, or the network.

- **Cron:** parse each field form and each rejection; `next(after:)` for lists, ranges, steps,
  month end, February 29, a DST spring-forward hour in `America/Los_Angeles` and a non-local zone,
  the day-of-month OR day-of-week rule, and the four-year give-up; a fixed `Calendar` and explicit
  dates throughout.
- **Aliases:** every combination the old handler accepted → same next fire as its cron translation,
  including `weekdays: [2,3,4,5,6]` → `MON-FRI` from a Friday and a Saturday.
- **Ledger:** in-memory store: upsert/rename uniqueness, due-job query at a boundary, begin/finish
  round trip with tokens, `runs(limit:)` ordering, `acknowledge`, a v8 fixture migrating to v9 with
  its conversations intact and both new columns reading false, a job row with unreadable JSON
  skipped and counted.
- **Prune:** the pure decision: retention boundary, unacknowledged failure exemption, per-job
  transcript cap, a run whose transcript is already gone.
- **Runner (FakeLLMClient):** a job fires → a hidden conversation exists, the ledger row is
  `completed` with the fake's token counts, the card is in the Activity conversation, the selected
  conversation has no new message, the sidebar filter excludes the run. Overlap `skip` writes an
  `interrupted` row. A scripted tool call that needs approval → `blockedOnApproval`, no entry in
  `pendingApprovals`, card names the tool. A card delivered while the destination is mid-turn:
  the UI message is immediate, the history line lands only after the current round (scripted
  two-round turn), and no new turn starts.
- **Card rendering:** the copy-transcript line format (pure); the `.event` decode path is covered
  by the store tests' lenient-decoder fixture.
- **Slash:** `/jobs` output for zero jobs, one job, one unacknowledged failure.
- **Migration deletes the old keys** from an injected `UserDefaults` suite (never the real one).

## 13. Documentation

README: replace the scheduling and watcher bullets with the job model, the Activity conversation,
and cards; add `/jobs`. New `docs/jobs.md` for the cron subset, aliases, profiles, the ledger, and
retention, linked from README. `docs/agency/agency.md`: mark deliverables 1–2 as landed with the PR
numbers and list what moved to D3/D4 (§2). Tool descriptions rewritten (invariant 9 applies to the
`schedule_job` description's catch-up sentence specifically).

## 14. Rulings made without the epic's author

Each is "what — why — cost if wrong".

1. `interval` kept as a schedule form beside cron — cron cannot express sub-hour arbitrary
   intervals and today's jobs can — a third form to maintain.
2. Cron day-of-week is 0–6, tool aliases stay 1–7 — cron users expect cron numbering; the tool
   has shipped with Foundation numbering — one translation to get right, pinned by tests.
3. Minute-stepping `next(after:)` with a 366-day cap — simple and DST-safe — slow only for
   pathological expressions; a smarter algorithm can replace it behind the same signature.
4. `isBackground` is a new column, not `isSubagent` — subagent conversations are never persisted
   and run transcripts must be — one more boolean on `Conversation`.
5. `isPinned` lands now, used only by the Activity conversation — D5 needs it and adding it later
   is a second migration — a column with one user for a while.
6. `ChatRole.event` rather than overloading `.system` — cards need their own rendering and must
   not read as harness notices — older builds quarantine those rows on downgrade.
7. Card history line rides a `pendingEventLines` queue drained at the steer boundary — appending
   mid-round corrupts call/response pairing — a second queue beside the steer queue.
8. Delivery never un-archives — a card is a record, not work — an archived destination's card is
   only seen when the user opens the archive.
9. `WatcherManager` fires through `JobRunner` now (a D4 pull-forward) — otherwise watches keep
   landing in the selected conversation, the epic's headline complaint — the quiet window and
   self-write filter still wait for D4.
10. Three due jobs per tick — bounds the wake stampede without designing `catchUp` — a long
    backlog drains at 18 jobs a minute.
11. `costMicros` reserved and NULL — no pricing exists — a column nothing writes until it does.
12. `list_jobs`/`get_job_run` only in pinned conversations; `/jobs` everywhere — invariant 6 —
    a user who wants the tools elsewhere pins that conversation, which D5 defines.
13. `mutating` refused at creation in this slice — the sandbox-always rule needs D3's allowlist
    and proposal cards to mean anything — no mutating jobs until D3.

## 15. Relationship to #185

A background run conversation is not a session in #185's sense, in both directions: it never
advertises a card and is excluded from `list_sessions` exactly as subagents are (#185 §3), and it
may not message sessions either — the session tools are not declared for it and `send_to_session`
is refused at dispatch (review finding on #253: a run could otherwise start an attended turn in a
user-facing conversation and launder a gated action through it). A run's only output channel is
its card. The Activity conversation is an ordinary conversation and may be a peer.

Two directories under `~/.iris` are write-protected from the auto-allow for every caller, attended
or not: `config/` (the permissions file, hook settings) and `plugins/` (a plugin can spawn an MCP
command at next launch). A background run additionally gets no write access under `~/.iris` at all
through the auto-allow; only an explicit rule can grant it a write, and no rule may target the
protected directories. `rules/` stays writable: it persists prompt text, not code. #185 slice 1 landed as #247 while this spec was being written. Nothing here touches
`drainPendingUserMessages`, `takePendingSteers`, `deliverPeerMessage`, or the session card; the
`pendingEventLines` drain is a sibling call at the steer boundary, and `JobScheduler`'s wiring in
`IrisEngine.start()` sits beside, not inside, the peer-delivery code.
