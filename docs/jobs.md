# Jobs

A job is a stored instruction that runs without a conversation open: a recurring prompt
(`schedule_job`) or a directory watch (`register_directory_watcher`). Both tools create a `Job` row
in the `jobs` table of `~/.iris/conversations.sqlite` — the same database every conversation lives
in, not `UserDefaults`. Jobs survive an app restart.

The two pre-ledger `UserDefaults` keys (`iris_scheduled_jobs` and `WATCHER_RULES`) are deleted on
first launch of a build with migration v9, and whatever they held is dropped rather than imported:
no install outside development ever had a real job in them. How many records went is logged once,
and if there were any the app posts a one-time notice into the open conversation saying what was
dropped and to recreate it with `schedule_job` or `register_directory_watcher` — a console line is
not something anyone running a Mac app reads.

This document covers deliverables 1 and 2 of `#187` (see `docs/agency/agency.md` and
`docs/specs/2026-09-21-agency-model-and-ledger.md`): the job model, the cron subset, the schedule
aliases, what happens on sleep, and what a fire actually does — a run in a hidden conversation of
its own, a row in the run ledger, and one event card. Gates, budgets, retries and `iris --run-job`
are deliverable 3.

## Creating a job

- `schedule_job` creates a job that fires on a schedule: a cron expression, a plain interval, or
  the older `minute`/`hour`/`day`/`month`/`weekday`/`weekdays` fields (below).
- `register_directory_watcher` creates a job that fires when files under a directory change. Watch
  jobs are named after the directory's last path component. Watching a path that is already
  watched rewrites that job's instructions in place instead of adding a second one.

Every job needs a unique name. If the requested name (or a slug of the prompt) is already taken,
`-2`, `-3`, … is appended until it isn't.

## The cron subset

Five space-separated fields, in order: `minute hour day-of-month month day-of-week`. Each field
accepts:

| Form | Example | Meaning |
| --- | --- | --- |
| `*` | `*` | every value |
| a number | `9` | that value only |
| a list | `1,15,30` | any of these values |
| a range | `9-17` | inclusive range |
| a step | `*/15` | every 15th value starting at the field's minimum |
| a stepped range | `9-17/2` | every 2nd value in the range |

Ranges: minute `0-59`, hour `0-23`, day-of-month `1-31`, month `1-12`, day-of-week `0-6` (`0` =
Sunday; `7` is also accepted and also means Sunday, the standard cron convention). Names like
`MON` or `JAN` are not accepted. Anything else is a parse error, returned to the model as a
sentence naming the field and the bad token.

Two forms are refused rather than guessed at: an empty list element (`1,,2`, or a trailing comma
in `1-5,`), and a range that wraps past the end of the field (`22-2` — write `22-23,0-2` if the
intent was "10 PM through 2 AM"). Both are typos far more often than intentions, and either
reading of them silently schedules something other than what was asked for.

If both day-of-month and day-of-week are restricted (neither is a bare `*`), a day matches when
*either* condition is true — standard (Vixie) cron behavior, not AND.

Every job carries an IANA time zone (e.g. `America/Los_Angeles`), defaulting to the zone Iris is
running in when the job is created. The cron fields are evaluated in that zone.

Examples:

| Cron | Meaning |
| --- | --- |
| `0 9 * * 1-5` | 9:00 AM every weekday |
| `*/15 9-17 * * *` | every 15 minutes, 9 AM–5 PM, every day |
| `0 0 1 * *` | midnight on the 1st of every month |
| `30 8 * * 0,6` | 8:30 AM on Saturday and Sunday |

The next fire is computed by walking forward minute by minute from the schedule's time zone,
which is what makes it correct across a DST transition (a wall-clock time that never occurs, like
02:30 on a spring-forward day, is simply never reached) without a special case for it. A schedule
that has no next occurrence within roughly four years (a `29 February`-only cron between leap
years, for example) disables the job with `pausedReason` set to a message naming the reason.

`intervalSeconds` is kept as a separate schedule form alongside cron, for cadences cron cannot
express (sub-hour, non-clock-aligned intervals like "every 90 seconds").

## Aliases (the old `schedule_job` parameters)

`schedule_job` still accepts the looser parameters it always has. They are translated to a cron
expression once, at creation time, and only the translation is stored:

| Old parameter | Cron field | Notes |
| --- | --- | --- |
| `minute` | minute | defaults to `0` if a schedule is otherwise specified without it |
| `hour` | hour | omitted with `day`, `month`, `weekday` or `weekdays` set → `0` (midnight on those days); omitted with only `minute` given → `*` (every hour) |
| `day` | day-of-month | defaults to `*` |
| `month` | month | defaults to `*` |
| `weekday` | day-of-week | `1`–`7`, `1` = Sunday (Foundation's numbering) → cron `0`–`6` by subtracting 1 |
| `weekdays` | day-of-week (list) | same 1=Sunday numbering; e.g. `[2,3,4,5,6]` → weekdays |
| `intervalSeconds` | (interval, not cron) | mutually exclusive with the fields above and with `cron` |
| `cron` | the expression directly | mutually exclusive with the fields above and with `intervalSeconds` |
| `timezone` | the job's IANA zone | defaults to the system's current zone |

Note the day-of-week numbering switch: the tool's `weekday`/`weekdays` use 1 = Sunday, matching
what the tool has always accepted; cron's own day-of-week field uses 0 = Sunday. The alias layer
does this translation so callers of the tool never see cron's numbering.

`weekday: 2` on its own therefore means "midnight on Mondays", not "every hour on Mondays"; ask
for an hour if you want one.

Giving no schedule at all, giving conflicting forms (e.g. both `cron` and `hour`), or giving values
out of range each return a specific refusal sentence rather than silently guessing. A weekday
outside `1-7`, or a `weekdays` element that is not a number, refuses the whole job: the older
behaviour dropped the bad value and scheduled what was left, which turns `[2, "wednesday"]` into a
Monday-only job nobody asked for.

## Profiles

Every job has a profile, `readOnly` or `mutating`, and `readOnly` is the default.

**A read-only run's tool surface is an allowlist, not a denylist.** `JobProfile.readOnlyAllowed`
names every tool such a run may call — today `read_file`, `search_web`, `search_memory`, `reflect`,
the two job-reading tools, and the Google read tools (list, get, search) — and everything else is
refused, including every tool added to Iris after this was written. That direction is deliberate: a
denylist's default answer is "allowed", and the first draft of this gate was a denylist that let a
read-only run rewrite `SOUL.md`, `USER.md`, `memory.md` and the fact store because nobody had
thought to name those four tools. Widening the surface is now a one-line decision with a test to
change, rather than something that happens by omission.

Two tools are judged per run rather than listed. `run_command` is available only when it resolves
to the container; on the host it is refused. An MCP tool is available only when its server
annotated it `readOnlyHint` — that is the server's own claim, not something Iris verifies, but it
is the only signal the protocol offers, and a tool that says nothing about itself is denied rather
than assumed harmless. `set_workspace` is deliberately *not* on the list: a workspace is what gives
a sandboxed `run_command` a read-write bind mount of that directory, so a read-only run that could
set one could write to the host through the very sandbox that is meant to contain it. Which is also
the honest statement of the `run_command` guarantee — a sandboxed command cannot write to the host
*because a job run's conversation has no workspace and therefore no mount*, not because the mount
is read-only. Anyone who gives job runs a workspace has to come back to this paragraph.

Declaration is only the cheap half. A call that reaches the dispatcher anyway — a stale
declaration, a forged name — is refused there too, recorded as the whole call (name, arguments,
working directory) on the run's ledger row, and the run finishes `blocked on approval` with a card
naming the tool. The tool result the refusal writes into the transcript says the job is
read-only and that no other tool will do it either — but the turn ends on the first such refusal
before another model round can read it, which is the order that matters: no approval is coming and
nothing else would do the same thing, so a further round could only spend the run's budget
arriving at the same answer. The sentence is the record; the ending is the enforcement.

A `mutating` job keeps the whole tool surface and always runs in the `apple/container` VM — that is
what pays for the wider surface. "Always" is enforced twice: `schedule_job` refuses to create one
unless the VM is available (the runtime installed *and* sandboxing switched on — with the master
switch off, the sandbox resolution returns the host however the conversation is pinned), and the
runner asks the same question again at every fire. A fire with no VM to run in is refused before
the turn starts: a `failed` run with the reason `sandbox unavailable`, a card, and the usual retry
ladder. It is never run on the host instead. Everything outside the user's allowlist still fails
closed inside the VM: unattended means unattended whatever the profile. A `readOnly` run leaves the
sandbox choice alone, so it follows the per-workspace default rather than being pinned to the
host.

## What happens on sleep

A background scheduler polls the jobs table for due jobs every 10 seconds, and once more right
after the Mac wakes from sleep (`NSWorkspace.didWakeNotification`) so a job doesn't wait out the
rest of the poll interval. A job that came due while the Mac was asleep — or otherwise missed one
or more ticks — fires once when the scheduler next looks, and its next fire is computed fresh from
that moment. It does not replay every tick it missed. At most three jobs start firing per tick;
any others due in the same tick wait for the next one.

A cadence that overlaps its own still-running fire is skipped rather than started a second time,
and the skip is recorded as an `interrupted` run so `/jobs` can show it — unless the job's overlap
policy is `queue`, which holds exactly one fire and takes it when the run ends (see Limits).
A watch fire for a job that is already running is dropped instead, with no row at all: a single
save can deliver a dozen filesystem events, and a row apiece would bury the ledger. Coalescing
them into one run after a quiet window is deliverable 4's job.

## Job creation is never unattended

Only a conversation with a person in it can create a job. `schedule_job` and
`register_directory_watcher` are not offered to a background run at all, and are refused if one
calls them anyway: a run that could schedule another run would be growing its own footprint with
nobody having asked. A run that thinks a job is warranted says so, and you create it.

## Where a fire goes

A fire does not touch the conversation you are in. Each run gets a **background conversation** of
its own — a real conversation, so its transcript can be read back afterwards, but flagged
`isBackground`, so it is out of the sidebar and can never be selected. The model turn happens
there. A run in flight shows up in the session strip under the composer as `job:<name>`; that is
the only place a running job is visible while it runs.

Before deliverable 2, a fire posted a system event into the conversation the job was created in
and started a turn there. That is gone: a five-minute cadence no longer writes into the chat you
are reading.

## The run ledger

Every fire writes a row to `job_runs`, in the same database as the jobs and the conversations: job,
trigger kind, start and finish, status, outcome (the first line of the last thing the run said,
capped at 200 characters), token counts, the background conversation it ran in, and — for a
failure — the reason and the tool it wanted. The row is written *before* the turn, so a run the app
died inside leaves evidence behind.

A run ends in one of five statuses:

| Status | Meaning |
| --- | --- |
| `running` | in flight right now |
| `completed` | the turn finished and said something |
| `failed` | the model call errored, the loop was cut short, or the turn ended having said nothing at all |
| `blocked on approval` | the run wanted a tool it is not allowed to use unattended, and stopped (see below) |
| `interrupted` | nothing finished it: the app quit mid-run and the next launch closed the row out, a cadence came round while the previous run of the same job was still going so this trigger was dropped rather than started twice, or a limit refused the fire before it started (the breaker, a budget, or a ledger that could not say what the job has spent) |

A run that says nothing is a failure, not a success: "it worked and had nothing to report" and "it
never got as far as a reply" must not look the same on a card.

## Event cards and the Iris Activity conversation

When a run ends, one **event card** is delivered: job name, status, the one-line outcome, tokens,
and a "View run" button onto the transcript. It goes to the job's destination conversation if it
has one, and otherwise to **Iris Activity** — a pinned conversation Iris creates on first use and
keeps at the top of the sidebar. (Pinned conversations refuse `/clear`.)

Delivery never wakes a model turn. The card is a `ChatRole.event` message, drawn as a card and
never indexed for search; alongside it the card's one-line summary is appended to the destination's
history, so the next turn *you* start reads it as context. If the destination is mid-turn, the line
rides the steer inbox and the model sees it with its next tool results instead. A job finishing is
news, not a request — waking the model on every run would turn a five-minute schedule into a
five-minute agent loop. Raw run output never enters the destination's messages.

## Approvals fail closed

Nobody is watching a background run, so it never blocks on an approval dialog. A tool call from a
background conversation is checked against the deterministic allowlist — a call that is already
permitted needs no human, so it runs — and anything else is denied on the spot, without consulting
Vibecop and without a dialog. The denial is recorded, the run ends `blocked on approval`, and the
card names the tool that was refused so you can decide in the morning.

This outranks everything, including the headless auto-approve used by scenario runs, and it is
inherited: a subagent or an evaluator a run spawns is a background conversation too, so delegating
is not a way around the gate. What a descendant was refused is recorded against the run itself, so
it is the run that ends `blocked on approval` and the run's card that names the tool.

The allowlist has one carve-out — the agent's own `~/.iris` directory — and it stops short of two
things. Nothing auto-allows a *write* into a protected directory: `config/`, which holds the file
that grants permissions along with the hook and plugin settings, and `plugins/`, where a plugin
with an `mcp` component becomes a command spawned at the next launch. That check is canonical —
case-insensitive, with symlinks resolved — so `~/.iris/CONFIG/permissions.json` or a link planted
under `memory/` is the same refusal. (`rules/` is not protected: it is prompt text, which the guard
already treats as untrusted, not a way to make something run.) And a background run gets no write
carve-out at all: it reads its own memory freely, but anything it writes needs a rule you approved,
and no rule can hand it a protected directory.

A background run cannot message other sessions either. `list_sessions`, `send_to_session` and
`set_session_card` are not offered to it, and all three are refused if called anyway: delivering a
message starts a real turn in an attended conversation — which would run the work under *that*
conversation's approval path — and the roster is how a sender picks its target. A run reports
through its card; it does not ask a peer to act for it, and it does not advertise itself to peers
that cannot reach it.

## Limits

A job is bounded before, during and after a run. Every number below is a global default a job's own
`JobPolicy` may override, except the global daily budget — a job that could raise the ceiling on the
whole unattended system is not a ceiling.

**Before a run**, admission decides in a fixed order: a paused job is dropped, then a disabled one,
then an overlap (skipped or queued by `policy.overlap`), then the breaker, then the budgets.

- **Breaker** — **6 runs per job per hour** by default. The run that would be the seventh does not
  happen; the job is paused instead, with the count in the reason. Refusals do not count as runs, so
  a job cannot trip its own breaker by being skipped.
- **Daily token budget** — **1,000,000 tokens per job** per local calendar day, and **3,000,000
  across every background run together**. The fire that finds the day's spend at or over the figure
  pauses the job rather than starting.
- A refused fire writes a zero-length `interrupted` row and one card naming the figure that tripped
  it, so a pause is never silent.

**During a run**, the turn itself is bounded: **200,000 tokens** and **10 minutes**. The token
budget is checked between model rounds; the deadline can also end a turn parked inside a model call
that never returns. Either one ends the run `failed` with `budget: tokens exceeded` or
`budget: time exceeded` on the row and on the card. The budget stop does not summarize — there is
nothing left to spend on a summary — and any message you steered in mid-run is written to the
transcript before the turn ends, without starting another turn.

**After a run**, a failure climbs the retry ladder: **1 minute, 5 minutes, 25 minutes**, and the
fourth consecutive failure pauses the job ("failed 3 times; paused"). A run that finally works
clears the ladder. A watch-driven fire never retries — its input was the paths the filesystem handed
it, and a retry minutes later would re-run the prompt without them; the next save is its retry.
A hand-started fire of a watch job does not retry either, for the same reason.

**A pause is permanent until you lift it.** Nothing un-pauses a job on its own — not the next hour,
not the next day, not a restart. `/jobs resume <name>` clears the pause *and* the retry ladder and
recomputes the next fire from the job's own schedule.

The five global numbers are `ConfigManager` keys — `JOB_MAX_RUNS_PER_HOUR`,
`JOB_DAILY_TOKEN_BUDGET`, `JOB_GLOBAL_DAILY_TOKEN_BUDGET`, `JOB_PER_RUN_TOKEN_BUDGET` and
`JOB_RUN_TIMEOUT_SECONDS` — and Settings → Advanced grows a stepper for each of them later in this
deliverable; today they are defaults with per-job overrides.

## `/jobs`

`/jobs` works in every conversation and never spends a model turn.

| Form | What it does |
| --- | --- |
| `/jobs` | A table of every job — name, trigger, when it next fires (or why it is paused), how its last run ended — then one line per unacknowledged failure, with the first eight characters of the run's id |
| `/jobs ack <run id>` | Marks a failed or blocked run as seen: it leaves the failure list, and it stops being exempt from retention. Takes a full id or the first eight or more characters of one, as a card prints it; an ambiguous prefix is refused rather than guessed |
| `/jobs pause <name>` | Stops a job firing, with "paused by user" as the reason the table shows |
| `/jobs resume <name>` | Clears the pause *and* the retry ladder, and recomputes the next fire from the job's own schedule |
| `/jobs run <name>` | Fires the job now, through the same admission a scheduled fire meets. Says it is starting straight away, then reports what admission decided once the fire is over — an overlap, the breaker or an exhausted budget is named rather than reported as a run. The result itself arrives as a card. A paused or disabled job is refused up front |
| `/jobs delete <name>` | Deletes a job and its ledger rows. Refused while a run is in flight. The transcripts are left for retention to clear, so a card you are still reading keeps working |

## The job tools

Two read-only tools let the model answer questions about jobs: `list_jobs` (every job, its trigger,
its next fire, how its last run ended) and `get_job_run` (one run, by id or by the eight characters
a card shows, including the last thing the run itself said).

Both are declared **only in a pinned conversation**, and refused at dispatch anywhere else even if
a call arrives regardless. The reason is cost, not secrecy: two extra tool declarations are a tax on
every turn of every conversation, and the conversation where you ask about your jobs is the pinned
one.

## Retention

Run history is pruned at launch and once a day after that:

- ledger rows older than **90 days** are deleted;
- for each job, background transcripts beyond its **20 most recent runs** are deleted;
- both are overridden by the same exemption: a `failed` or `blocked on approval` run that nobody
  has acknowledged keeps its row *and* its transcript, however old. `/jobs ack` is what gives it
  up.

A pruned transcript leaves the ledger's `transcriptConversationId` dangling on purpose — the card
then says "transcript pruned" rather than offering a dead button. Only a background conversation is
ever deleted this way; if a row somehow names a conversation you can see, retention leaves it
alone.
