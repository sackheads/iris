# Jobs

A job is a stored instruction that runs without a conversation open: a recurring prompt
(`schedule_job`) or a directory watch (`register_directory_watcher`). Both tools create a `Job` row
in the `jobs` table of `~/.iris/conversations.sqlite` — the same database every conversation lives
in, not `UserDefaults`. Jobs survive an app restart.

The two pre-ledger `UserDefaults` keys (`iris_scheduled_jobs` and `WATCHER_RULES`) are deleted on
first launch of a build with migration v9, and whatever they held is dropped rather than imported:
no install outside development ever had a real job in them. How many records went is logged once,
so a machine that turns out to have had some is not silent about it.

This document covers deliverable 1 of `#187` (see `docs/agency/agency.md` and
`docs/specs/2026-09-21-agency-model-and-ledger.md`): the job model, the cron subset, the schedule
aliases, and what happens on sleep. Run history, background run conversations, event cards, and
`/jobs` are deliverable 2 and are not built yet.

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

Every job has a profile, `readOnly` or `mutating`. `readOnly` is the default and, right now, the
only one `schedule_job` will create — asking for `profile: mutating` is refused with a message
saying it arrives with deliverable 3. There is no sandboxing or approval-bypass model for mutating
jobs yet; until there is, a job that might write is a job nobody is watching.

## What happens on sleep

A background scheduler polls the jobs table for due jobs every 10 seconds, and once more right
after the Mac wakes from sleep (`NSWorkspace.didWakeNotification`) so a job doesn't wait out the
rest of the poll interval. A job that came due while the Mac was asleep — or otherwise missed one
or more ticks — fires once when the scheduler next looks, and its next fire is computed fresh from
that moment. It does not replay every tick it missed. At most three jobs start firing per tick;
any others due in the same tick wait for the next one.

A cadence that overlaps its own still-running fire is skipped rather than started a second time.

## Where a fire goes, today

A job firing posts a system event into the conversation it was created in (or the currently
selected conversation, if it wasn't created in one) and starts a model turn there — the same
behavior `schedule_job` and `register_directory_watcher` have always had. It is an ordinary turn in
an ordinary conversation, with nothing special about its permissions: a fire whose work needs
approval raises the approval dialog and waits for you, exactly as if you had typed the prompt
yourself. Deliverable 2 (`#253`, which ships alongside the model and scheduler in `#252`) moves the
fire into a hidden background conversation with a run ledger (`job_runs`) and delivers a compact
event card to a destination conversation instead of interrupting whatever's open; the background
profile, the fail-closed gate and the proposal card that replace the approval dialog are
deliverable 3. Until then, a job posting into a conversation you're using will show up as a message
there, and can stop on a dialog nobody is sitting in front of.

## Not built yet (deliverable 2)

- The `job_runs` ledger: what ran, when, tokens, cost, pass/fail.
- Background run conversations, hidden from the sidebar.
- Event cards and the "Iris Activity" destination conversation.
- `list_jobs`, `get_job_run`, and the `/jobs` command.
