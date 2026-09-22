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

This document covers deliverables 1 to 4 of `#187` (see `docs/agency/agency.md`,
`docs/specs/2026-09-21-agency-model-and-ledger.md`, `docs/specs/2026-09-21-agency-runtime.md` and
`docs/specs/2026-09-22-agency-watches.md`): the job model, the cron subset, the schedule aliases,
what happens on sleep, what a fire actually does — a run in a hidden conversation of its own, a row
in the run ledger, and one event card — the gates, limits and retries around it, what a directory
watch does with a burst of saves, and `iris --run-job`, which fires one job from a terminal and
prints the row it wrote.

## Creating a job

- `schedule_job` creates a job that fires on a schedule: a cron expression, a plain interval, or
  the older `minute`/`hour`/`day`/`month`/`weekday`/`weekdays` fields (below).
- `register_directory_watcher` creates a job that fires once files under a directory have changed
  and then gone quiet for a few seconds (see "Watches"). Watch jobs are named after the directory's
  last path component. A watch belongs to the conversation that registered it: watching the same
  directory again *from that conversation* updates its watch in place — only the arguments you
  give are changed, and the watch is switched back on if it was paused — while watching it from
  another conversation creates a second watch with a suffixed name, and the tool says how many
  watches the folder now has. Two standing orders on one folder are two orders; each runs on every
  change.
- A `schedule_job` that also carries a gate (`gate_url`, `gate_path` or `gate_script`) is a
  **polled** job: the cadence decides how often the gate is checked, and the gate decides whether
  the job actually runs. See "Gates" below.

Every job needs a unique name. If the requested name (or a slug of the prompt) is already taken,
`-2`, `-3`, … is appended until it isn't.

Two of the job's policies can be set at creation, and both default to the quieter answer:

| `schedule_job` argument | Values | What it decides |
| --- | --- | --- |
| `overlap` | `skip` (default), `queue` | What a fire does when the previous run is still going: drop it and record the drop, or hold exactly one and take it when that run ends |
| `catch_up` | `coalesce` (default), `skip`, `replay`, `replay:N` | What a wake does with occurrences missed while the Mac slept (see "What happens on sleep"). A bare `replay` uses the cap of 5; a negative cap is read as the typo it is and takes that default. The object form the policy itself stores, `{"kind": "replay", "cap": N}`, is also accepted, but the argument is declared a string, so prefer `replay:N` |

A value neither field recognizes is refused with a sentence naming the ones that work, rather than
quietly creating a job that behaves differently from the one that was asked for. The rest of a job's
policy is not settable from the tool: the budgets, the breaker and the run timeout are global
settings with a per-job override in the stored `policy` column, and `retry` is per job and on (see
"Limits").

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
refused, including every tool added to Iris after this was written. The allowlist is a ceiling, not
a promise: what a run is actually *offered* is the intersection of it with the declarations that
conversation builds, and the two job-reading tools are declared only in a pinned conversation (see
"The job tools" below) while a run's hidden conversation never is. So a read-only fire's surface
today is `read_file`, `search_web`, `search_memory` and `reflect`, plus a sandboxed `run_command`
and whatever read-only MCP tools are connected — it cannot read its own job records, and nothing
here offers to widen that. That direction is deliberate: a
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
the honest statement of the `run_command` guarantee *for this profile*: a read-only run's sandboxed
command cannot write to the host *because its conversation has no workspace and therefore no
mount*, not because the mount is read-only. Anyone who gives read-only runs a workspace has to come
back to this paragraph. It does not carry over to `mutating`, which has `set_workspace` and can
therefore give itself a workspace mid-turn, after which a command gets that directory bind-mounted
read-write — no wider than the allowlist or the approval that let the command run at all (in an
attended chat that same command runs on the host), and the card's `in <cwd>` line says where.

Declaration is only the cheap half. A call that reaches the dispatcher anyway — a stale
declaration, a forged name — is refused there too, recorded as the whole call (name, arguments,
working directory) on the run's ledger row, and the run finishes `blocked on approval` with a card
naming the tool. The tool result the refusal writes into the transcript says the job is
read-only and that no other tool will do it either — but the turn ends on the first such refusal
before another model round can read it, which is the order that matters: no approval is coming and
nothing else would do the same thing, so a further round could only spend the run's budget
arriving at the same answer. The sentence is the record; the ending is the enforcement.

A `mutating` job keeps the whole tool surface, and its *commands* always run in the
`apple/container` VM — that is what pays for the wider surface. Commands, precisely: `run_command`
is what the VM routes, and `write_file`, `read_file` and the rest of the native tools execute on
the host as they do in any run, behind the user's allowlist and the same fail-closed approval.
"Always" is enforced twice: `schedule_job` refuses to create one
unless the VM is available (the runtime installed *and* sandboxing switched on — with the master
switch off, the sandbox resolution returns the host however the conversation is pinned), and the
runner asks the same question again at every fire. A fire with no VM to run in is refused before
the turn starts: a `failed` run with the reason `sandbox unavailable`, a card, and the usual retry
ladder. It is never run on the host instead. Nor is it run on the host when the VM goes away
*during* a turn — turn sandboxing off or uninstall the runtime while a run is in flight and the
next `run_command` is refused where it stands, with the command recorded on the run's card, so the
"Always allow" rule you once clicked on that command in an ordinary chat cannot quietly stand in
for the container. That rule holds for any unattended run, not just a job's own: a subagent the run
delegates into is unattended too. Everything outside the user's allowlist still fails
closed inside the VM: unattended means unattended whatever the profile. A `readOnly` run leaves the
sandbox choice alone, so it follows the per-workspace default rather than being pinned to the
host.

## Gates

A gate is a check, run on the job's cadence, that answers one question: has anything changed since
the last time we looked? A job with a gate only spends a model turn when the answer is yes. There
are three kinds.

| Argument | What it checks | Needs the VM |
| --- | --- | --- |
| `gate_url` | A HEAD request to an `http(s)` URL: its `ETag`, `Last-Modified` and `Content-Length` | no |
| `gate_path` | An absolute path: a file's mtime, size and content hash, or a directory's own mtime, the newest modification under it, and how many entries it holds — up to 20,000 of them, past which the path is refused when the job is created and reads as a gate failure if it grows into one | no |
| `gate_script` | A shell script, run inside the sandbox VM with `gate_mounts` attached read-only, under `gate_timeout_seconds` (default 60, clamped to 5–600) | yes |

What the gate saw is stored on the run's ledger row as its **signal** and compared with the
previous one. The first look has nothing to compare against, so it counts as a change: a new job
runs once and records its baseline.

**A script gate's verdict is the last line of its standard output — exactly `CHANGED` or
`UNCHANGED` — and never its exit code.** Exit codes are ambiguous here: `diff -q` returns 0 for
"identical" and `grep -q` returns 0 for "found", so any exit-code convention makes a plausible gate
fire every tick or never. Everything the script printed before that line is the gate's payload: the
first 4,000 characters of it go into the run's prompt as untrusted context, wrapped and tagged
`gate_output` like any other text Iris did not write.

A script gate is the only model-written code in Iris that runs repeatedly with nobody watching, so
it is fenced in:

- it runs **only** inside the `apple/container` VM, in a container created and removed around that
  one command, never on the host — with the runtime uninstalled or sandboxing switched off, the
  evaluation is a gate failure rather than a command on your Mac;
- *starting* that container is bounded as well as running the script in it, so a daemon that never
  answers shows up as a gate failure — and, after three, a paused job that says so — rather than a
  job that goes quiet with nobody to notice;
- its mounts are **always read-only**, whatever was written, and each one is checked when the job is
  created: an absolute path, no commas, and an existing directory (a single file cannot be mounted
  — give its directory). Neither `/` nor Iris's own `config/` and `plugins/` can be one, however
  they are spelled;
- a mount is recorded as the directory it **resolves to**, not the name it was given: `..` is
  removed and symlinks are followed, so what you are shown at creation is what will actually be
  read. The same check runs on every tick — a source that has since been pointed somewhere else,
  or is no longer a directory, is a gate failure and nothing is started;
- it is reviewed once, at creation, by Vibecop, with the ordinary approval dialog for anything
  Vibecop escalates or cannot answer. Both are shown the same thing: the script, every mount as
  `source → target, read-only`, and the timeout — the mounts are the standing permission being
  granted, and the script is only what is done with them. That review is the last time a human sees
  it, which is why the sandbox, the read-only mounts and the timeout are not negotiable.

What each answer costs:

| The gate says | What happens |
| --- | --- |
| changed | The job runs, and the signal is recorded on that run's row |
| nothing changed | A `completed` row with the outcome `gate: no change`, and **no card** — cards are for things that happened, and a five-minute poll would otherwise bury the Activity conversation. It costs no model turn and does not count towards the breaker |
| it could not tell (a 404 or 5xx, a response with none of the three headers, a missing path, a mount that has moved, a non-zero exit, a timeout, or any other last line — and a ledger Iris could not read the last signal out of) | An `interrupted` row whose reason starts `gate error`. Three of those **in a row** pause the job with the reason `gate failing`, and that pause gets a card |

If a job's gate is ever changed — no tool does this today — the signals its runs recorded are
dropped: a signal is a reading taken by one particular gate, and an ETag cannot answer for an
mtime. The new gate would take its own baseline on the next tick.

**A cadence tick asks the gate; a retry and a hand-started fire do not.** A retry after a failed
run is re-running work the gate already authorised, and asking again would get "nothing has changed
since the run that failed" and quietly drop it. `/jobs run <name>` runs the job whatever the gate
would have said, because you asked for it. A fire the `queue` policy held while the previous run
finished *is* asked: it is an ordinary tick whose gate never got a chance to answer, and running it
unasked would spend the very turn the gate exists to save. `/jobs` shows a gated job's trigger as, for example, `poll every
900 s (url gate)`, so a job that has been quiet for a week says why it might be.

## Watches

A watch is a job whose trigger is a directory. It does not fire on every filesystem event: it
waits for the folder to go **quiet**, runs once with every path that changed in the burst, never
runs alongside itself, and ignores both editor noise and the writes its own unattended runs make.
What it saw and what it absorbed are printed on the card and in `/jobs`.

**The quiet window and the ceiling.** A watch fires once its directory has been quiet for
`quiet_window_seconds` (1 to 300; default 3; a value outside the range is clamped and the tool
says which value it used), coalescing every path seen since the burst began into one run. If the
changes never stop — a build writing output, a sync tool catching up — it fires anyway once the
burst has lasted **ten times the window** (30 s at the default), and the next change starts a new
burst with a new ceiling. The ceiling is derived from the window, not a second setting. A watch
created before the window was enforced keeps the window it stored.

**Noise.** Every watch ignores `.git/`, `.DS_Store`, `node_modules/`, `*~`, `*.swp`, `*.swx`,
`.#*`, `4913` (Vim's directory probe), `*.tmp`, and the temporary files a macOS atomic save
creates beside the real one (`.<name>.sb-*`, `(A Document Being Saved By …`). A watch can add its
own patterns with `ignore` — globs relative to the watched folder, where `**` spans directories and
a pattern with no `/` matches a name at any depth, so `*.log` catches `build/out.log`. Matching is
case-insensitive, like the rest of the file system. An ignore list that would absorb everything —
it is tried against a fixed handful of sample names before the job exists — is refused
("that ignore list would ignore every change; drop the pattern or watch a narrower path") rather
than creating a watch that never fires.

**Iris's own writes.** A watch's point is usually to react to *your* changes, and the loop it must
never fall into is reacting to its own: a run that summarises a folder into a file in that folder.
So the writes made by an **unattended** conversation — a job run, or a subagent or evaluator
descended from one — through the file tools (`write_file`, `create_skill`, `update_skill`,
`delete_skill`) are remembered for a few seconds, and an event on such a path, or on the
temporary file its atomic save produced, is absorbed and counted as an own write rather than
delivered. A write you asked for in an ordinary conversation, or one you approved from a card, is
not filtered: it is a change a person made, and a watch is expected to notice it ("index the note
Iris just wrote"). The filter sees only the file tools, and you should know exactly what it
**cannot** see: files written by `run_command`, on the host or in the container; anything an MCP
tool writes; anything a plugin hook writes; the memory tools (`update_memory`, `save_fact`,
`update_soul`), which write under `~/.iris` through their own managers — which is why `~/.iris`,
and anything containing it, is refused as a watch root; and the writes of an `iris --run-job`
process, which is another process altogether (no watch is live while it holds the store). A loop
built from any of those is not silent and not unbounded: it ends in the job's **breaker** pause
(six runs an hour by default) with a card naming the figure, the same backstop every job has.

**Roots.** The path must be an existing directory; it is stored in its resolved spelling
(`/tmp/notes` becomes `/private/tmp/notes`), which is what the file system reports events under.
Some roots are refused: `/`, your home folder itself, `/System`, `/Library`, `/usr`, `/private`,
`/var`, `/etc`, `/bin`, `/sbin`, `/Volumes` and any volume or mount point are "too broad to watch;
name a specific folder", and `~/.iris` — or any folder above or below it — "is or contains Iris's
own directory; a watch there would react to itself". A folder *inside* any of those is fine.

**Overlap.** A watch never runs concurrently with itself. Its `overlap` defaults to `queue`: saves
that land while a run is going are held — including a file the run itself was given, saved again —
and when the run ends they are re-fired once, as a single run carrying the union of everything held.
A watch created with `overlap: skip` holds the same way but is only offered again once per ceiling
until a run lets it through. Neither writes a skip row.

**One stream per folder.** However many watches cover a directory — two conversations watching
`~/notes`, or one watching `~/notes` and another `~/notes/drafts` — the process opens one
filesystem stream for it and hands each event to every watch it belongs to, once. A watch registered
on a folder that is nested inside another watched folder is served by the outer stream. Registering,
pausing, resuming or deleting a watch takes effect within the second; nothing else's stream is
restarted for it.

**A folder that disappears.** The file system does not stop a stream whose root is deleted,
renamed or unmounted; it goes silent. Iris checks every watched root on every job change and once a
minute besides, and a watch whose folder is gone is paused with the reason
`watch path unavailable: <path>` and one card — the same answer a watch gets at launch when its
folder is already missing, or when the stream cannot be created. `/jobs resume <name>` retries it.

**What you can see.** A watch run's card carries, beside the tokens and the duration, `12 changes ·
3 noise · 1 own writes`, each figure only when it is not zero, then `(cut at the ceiling)` when the
burst never went quiet, `(N not kept)` when a burst exceeded the 1,000 distinct paths a watch keeps
(the run still hears the true count), and `(paths withheld by the guard)` when the injection guard
blocked the block of paths and the run got none of them. `/jobs` prints one line per watch beneath
the table: `` `notes` — last burst: 12 changes · 3 noise · 1 own writes (cut at 30 s) · absorbed
since launch: 41 noise · 7 own writes · 3 while paused `` — the first half from the newest run row,
so it survives a relaunch ("nothing fired yet" when there is none), the second from memory, so it
starts again at zero, and a dash from an `iris --run-job` process, which has no watch layer. The
policy column shows `quiet 10 s` and `2 ignore` when a watch departs from the defaults. A burst in
which *every* event was noise or an own write writes no row and no card: nothing happened, and the
count is in the `absorbed since launch` figure. The run itself receives at most 100 paths, sorted,
plus one line saying how many more changed.

**Limits worth knowing.** A run started by a watch is not retried after a failure (see "Limits").
After the Mac sleeps, the file system delivers what it can on wake and may fold a long gap into a
"scan this directory" flag that Iris does not act on, so the detail of a backlog can be lost; the
watch fires on the next real change. A watch whose creating conversation has been deleted keeps
running — jobs outlive their conversations — but no conversation can update it any more, so
re-registering the folder creates a second watch beside it; `/jobs delete <name>` is how the
orphan goes.

## What happens on sleep

A background scheduler polls the jobs table for due jobs every 10 seconds, and once more right
after the Mac wakes from sleep (`NSWorkspace.didWakeNotification`) so a job doesn't wait out the
rest of the poll interval.

A job that came due while the Mac was asleep — or otherwise missed more than one cadence — is
handled by its **catch-up policy**. The default is `coalesce`: it fires once when the scheduler
next looks, its next fire is computed fresh from that moment, and it does not replay every tick
it missed. A job that missed exactly one occurrence is an ordinary fire whatever its policy says;
there is nothing to coalesce, skip or replay.

| catch-up | what a job that fell behind does |
| -------- | -------------------------------- |
| `coalesce` (default) | one fire now, against the world as it is, rescheduled from now |
| `skip` | no fire at all; the cadence jumps to the first occurrence still in the future |
| `replay(cap)` | one fire per missed occurrence, up to `cap` (5 unless the job says otherwise; 100 at most) |

A cap above **100** is lowered to 100, and `schedule_job` says so in its answer rather than
refusing the job: a hundred is far past any cadence worth replaying — a quarter-hourly job asleep
for a whole day is 96 occurrences — and an uncapped figure only buys a job that walks its breaker
open, pauses, is resumed and does it again.

`replay` runs the **most recent** `N` missed occurrences, oldest of those first — a job that slept
through eight hours of quarter-hours wants the last five states of the world, not five from this
morning. The older ones are dropped, and the first run of the burst says how many on its card:
"27 earlier occurrences skipped". The fires are sequential, never side by side, and each one goes
through the same admission an ordinary fire meets — so it asks the gate, and it counts against the
breaker and the daily budgets. The burst therefore ends at the first refusal: if the breaker opens
or a budget runs out on the second of five, the other three are abandoned and the job goes back on
its ordinary cadence rather than spending the next tick being refused four more times.

A replayed run that **fails** ends the burst too. The failure puts the job on the retry ladder — a
minute, then five, then twenty-five, then a pause — and that is now the schedule; the occurrences
the burst still owed are dropped rather than fired over the top of it. Without that, a provider
outage during a catch-up would spend the whole ladder in the time it takes to make four failing
runs and leave the job paused, where an ordinary failed fire costs one run now and one a minute
later. For the same reason a job that was asleep *mid-retry* is an ordinary single fire whatever
its catch-up policy says: the time it was waiting for was a retry, not a missed occurrence.

On a **gated** job, `replay` will usually produce a single run whatever the cap says, and that is
the right answer: the first replayed fire stamps the fresh gate signal, so the second asks the gate
and is told nothing has changed since a moment ago, which ends the burst. There was one change to
react to, not five.

A job so far behind that catching up would mean stepping through more than 10,000 occurrences — a
per-minute cadence and a fortnight with the app closed — coalesces instead. That is a restart, not
a catch-up, and one fire against the present is what a restart wants; the card for that fire says
"too far behind to replay; ran once instead", and the job's policy is untouched for the next time.

When the first replayed fire is refused before it can run — a gate that found nothing, an open
breaker, an exhausted budget — the count still gets recorded: on the gate's ledger row, or on the
pause card. The same is true of the two answers a wake gives most often. If the job is **still
running** the turn it started before the sleep, the count goes on the overlap skip row
("skipped: previous run still in progress (27 earlier occurrences skipped)"); if the job's
`overlap` is `queue`, the fire is held and the count is held with it, so it arrives on the card of
the run that fire becomes when the previous one ends. The count is only dropped where the job
itself has stopped — paused or disabled — and there the pause reason is what a person needs, and
the scheduler would not have planned the burst in the first place.

At most three fires start per tick, counting every job's rather than counting jobs — so one job's
replay cannot start more work in a tick than any three ordinary fires would. It does take the whole
tick while it lasts: due jobs are served furthest-behind first, so a job catching up goes first and
anything that does not fit waits. Nothing is lost by waiting — what did not fit is still due and
the next tick takes it, including the rest of the replay burst — and the wait is bounded by how
many ticks the burst needs, two at the default cap of five.

A job whose burst is still running is not planned again while it runs, even though its next fire
is deliberately left in the past: that is what brings a later tick back to finish the burst, not an
invitation to start a second one alongside it.

A cadence that overlaps its own still-running fire is skipped rather than started a second time,
and the skip is recorded as an `interrupted` run so `/jobs` can show it — unless the job's overlap
policy is `queue`, which holds exactly one fire and takes it when the run ends (see Limits).
A watch never overlaps itself either, but it is not dropped: saves that land while a watch's run
is going are held, and when the run ends they are re-fired once, as one run carrying everything
that arrived — a watch's `overlap` defaults to `queue`. A watch created with `overlap: skip`
holds the same way and is offered again once per ceiling until a run lets it through. Neither
writes a skip row: a single save can deliver a dozen filesystem events, and a row apiece would
bury the ledger. See "Watches".

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
failure — the reason and the tool it wanted. A run that stopped on a call it was not allowed to
make also stores the whole call (name, every argument, working directory, and why it was refused),
which is what "Approve and run" re-dispatches. The row is written *before* the turn, so a run the
app died inside leaves evidence behind.

A run ends in one of five statuses:

| Status | Meaning |
| --- | --- |
| `running` | in flight right now |
| `completed` | the turn finished and said something — or the job's gate found nothing to do, in which case the outcome says `gate: no change` and there was no turn |
| `failed` | the model call errored, the loop was cut short, or the turn ended having said nothing at all |
| `blocked on approval` | the run wanted a tool it is not allowed to use unattended, and stopped (see below) |
| `interrupted` | nothing finished it: the app quit mid-run and the next launch closed the row out, a cadence came round while the previous run of the same job was still going so this trigger was dropped rather than started twice, a gate could not answer, or a limit refused the fire before it started (the breaker, a budget, or a ledger that could not say what the job has spent) |

A run that says nothing is a failure, not a success: "it worked and had nothing to report" and "it
never got as far as a reply" must not look the same on a card.

## Event cards and the Iris Activity conversation

When a run ends, one **event card** is delivered: job name, status, the one-line outcome, tokens,
and a "View run" button onto the transcript. It goes to the job's destination conversation if it
has one, and otherwise to **Iris Activity** — a pinned conversation Iris creates on first use and
keeps at the top of the sidebar. (Pinned conversations refuse `/clear`.) A run that stopped on a
refused call gets a second half as well — the call in full, and what you can do about it; see
"Approve and run" below.

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
Vibecop and without a dialog. The whole call is recorded, the run ends `blocked on approval`, and
the card shows what was refused — with an "Approve and run" button, below — so you can decide in
the morning.

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

## Approve and run

The card for a run that stopped on an approval shows the **whole call** — the tool, every argument,
and a long body cut to the first 500 characters — because an approval given without sight of the
payload is worse than no button. Vibecop is asked about that same persisted call when the card is
written, and its verdict and reason sit beside the button. A verdict is information, not a veto: a
`DENY` still leaves the button there, and clicking it is you overruling Vibecop, not skipping it.

**Approve and run** dispatches exactly that one call, once, as a tracked run of its own: a fresh
hidden conversation titled `<job> · approved <tool>`, a `job_runs` row with the trigger kind
`approval` and a pointer back to the run that asked, and a follow-up card with what the call
returned. It is not "resume the job": the original turn is over, and what the model would have done
next with the result is unknowable. If the job needs to go further, its next fire takes it there.

Approving is one-shot, and the claim is stamped in the database *before* the call runs — so a
second click, a second window, or the app dying between the click and the execution all get the
same refusal rather than running the call twice. The approved run is an ordinary row, so it counts
towards the breaker and the daily budgets the next fire is judged against; admission is not re-run
over it, because a person clicking a button is not an unattended fire.

The job's **profile is re-asked at the moment you click**, not inherited from the run that was
blocked. Between the two you can have uninstalled the container runtime or turned sandboxing off,
and the answer to "may this job do this?" changes with that. In particular, a `run_command` that
came out of a background run — read-only or mutating — runs in the container or not at all: with no
VM to run it in the click is refused with `sandbox unavailable`, the claim is left unspent, and it
is never run on the host instead. A click authorises the command; it does not authorise dropping
the isolation.

Precisely: *model-issued* commands. A hook is the other way a command leaves an unattended run, and
it does not follow this rule — a `BeforeTool` or command hook runs under the hooks sandbox setting
and executes on the host when no container resolves. That is deliberate rather than a gap: a hook is
configuration the user wrote, in a file only the user edits, so it is not something an unattended
model can reach for. The rule above is about what the model can issue.

A refusal is said in the conversation the card is in — the job's destination, or Iris Activity —
because a sentence in a conversation you do not have open is the same as silence.

Two calls are never offered the button at all, and are refused again by the runner and by the
ledger if one is reached another way:

- a call a **read-only** job's profile refused. It was not stopped for want of a human, so no human
  can grant it; the job would have to be created `mutating`.
- a **write into a protected directory** (`~/.iris/config`, `~/.iris/plugins`). A write there grants
  further permission rather than editing a file, and a click says a person vouches for the call —
  it does not change what may be written. Make that change yourself if you want it.

**Dismiss** acknowledges the run: it leaves `/jobs`'s failure list and stops being exempt from
retention. The card stays in the transcript, because it is a record of what happened. Approving
acknowledges it too, in the same write that claims the call — clicking **Approve and run** is a
stronger "I have seen this" than Dismiss is, so an approved run does not sit in the failure list
waiting for a second click on a button that would now only answer "it has already been approved
once".

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
  pauses the job rather than starting. A run still in flight counts too: its spend is written to its
  row after every model round, so a run the app quit in the middle of still costs the day what it
  spent.
- A refused fire writes a zero-length `interrupted` row and one card naming the figure that tripped
  it, so a pause is never silent.

**During a run**, the turn itself is bounded: **200,000 tokens** and **10 minutes**. The token
budget is checked between model rounds; the deadline does not wait for a round, and does not wait
for the turn either. At the deadline the run is closed `failed`, the Mac is let go back to sleep and
the job is free to fire again; the turn is asked to stop, and if it is parked somewhere that never
checks — a blocking subprocess, a stream with no timeout — it is abandoned rather than waited on.
Whichever bound bit, the row and the card say `budget: tokens exceeded` or `budget: time exceeded`.
The budget stop does not summarize — there is nothing left to spend on a summary — and any message
you steered in mid-run is written to the transcript before the turn ends, without starting another
turn.

**One command inside the VM is bounded on its own**, by the number `run_command` was given —
`timeout_seconds`, clamped to between 10 seconds and an hour, 10 minutes if it says nothing. That
number used to be dropped the moment a command was routed to the container, so a sandboxed command
had no bound at all while the model believed it had set one; it is honoured now. At the deadline
the command is killed — politely first, then not — and the result reads exactly as it does on the
host: `Error: command timed out after N seconds`. The container itself is left alone, because a
deadline is the command's answer and not a sign of a dead container: the session, its installed
packages and its files are all still there for the next command. Stopping a run mid-command reads
differently — `Error: the command was cancelled.` — and leaves the session alone for the same
reason. This is a bound on a command, not on the run: a turn that spends its ten
minutes on six timed-out commands still ends on the run's own deadline, above.

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
`JOB_RUN_TIMEOUT_SECONDS` — and **Settings → Advanced → Job Limits** has a stepper for each. A
stepper wound down to zero reads as "default": the figure above is what the runner then uses, and
the row says so rather than claiming a budget of nothing. Each stepper moves from the figure its
row is showing, so one click up from "default (6)" is 7 and one click down is 5 — and winding one
back down to zero is how you give that number to the default again. A job's own `policy` column
overrides any of them except the global daily budget.

**What zero means depends on which number it is.** An unset settings key — which is how a `0` reads
— is simply the default above. In a job's own `JobPolicy`, `0` is an answer rather than a gap, and
it means two different things: for the token budgets and the breaker it means **unlimited**, and for
`runTimeoutSeconds` it means **take the global default**. The reason for the split is what each
number bounds: a budget bounds spend, which a person may reasonably want unbounded, while the
timeout bounds a turn that has stopped responding, and a run nothing can end is the failure this
whole section exists to prevent. A **negative** figure is not a third answer — nobody writes `-1` to
mean unlimited — so it is read as the typo it is and takes the default, wherever it was written: a
settings key, or a hand-edited `policy` column.

**What you can see of all this.** Every one of these numbers is readable before it bites, not only
in the pause that names it. `/jobs` prints, per job, what it has spent today against its own daily
budget (`620k / 1M (62%)`), how many runs it has started in the last hour against the breaker
(`2 / 6`), its place on the retry ladder (`retry 1/3`) beside its next fire, and a policy column
naming whatever it does differently from the defaults; under the table is the whole unattended
system's spend for the day against the global ceiling. `list_jobs` carries the same figures as
fields — `tokensToday`, `dailyBudget`, `runsLastHour`, `maxRunsPerHour`, `retryAttempt`, `policy`,
`gateKind`, `profile`, and `tokensTodayAllJobs` against `globalDailyBudget` — so the model answers
"what is this job costing?" from the same arithmetic admission decides on. A figure that could not
be read is a dash in the table and a `null` in the tool, never a zero: "nothing spent today" is a
claim, and an unreadable ledger is not one. A pause still names the figure that caused it, in the
pause reason the table prints, on the `interrupted` row and on the card.

## `/jobs`

`/jobs` works in every conversation and never spends a model turn.

| Form | What it does |
| --- | --- |
| `/jobs` | A table of every job — name, trigger (with its gate, if it has one), its policy where it departs from the defaults, when it next fires (or why it is paused), how its last run ended, its tokens today against its daily budget and its runs in the last hour against the breaker — then one line per watch with what its last burst saw and what it has absorbed since launch (see "Watches"), then the day's spend across every job, then one line per unacknowledged failure with the first eight characters of the run's id |
| `/jobs ack <run id>` | Marks a failed or blocked run as seen: it leaves the failure list, and it stops being exempt from retention. Takes a full id or the first eight or more characters of one, as a card prints it; an ambiguous prefix is refused rather than guessed |
| `/jobs pause <name>` | Stops a job firing, with "paused by user" as the reason the table shows |
| `/jobs resume <name>` | Clears the pause *and* the retry ladder, and recomputes the next fire from the job's own schedule |
| `/jobs run <name>` | Fires the job now, through the same admission a scheduled fire meets. Says it is starting straight away, then reports what admission decided once the fire is over — an overlap, the breaker or an exhausted budget is named rather than reported as a run. The result itself arrives as a card. A paused or disabled job is refused up front |
| `/jobs delete <name>` | Deletes a job and its ledger rows. Refused while a run is in flight. The transcripts are left for retention to clear, so a card you are still reading keeps working |

## Running one job from a terminal (`iris --run-job`)

```
iris --run-job <id-or-name> [--dry-run] [--json]
```

One job, fired once, against your real store (`~/.iris/conversations.sqlite`) with the real model
client — then the process exits. No scheduler starts, no watchers, no window. What it is for is
**measuring a job before you trust it**: run a new job or a new gate on demand and read its row —
status, tokens, duration, gate signal — instead of waiting for its cadence, feed a gate's verdicts
to an eval harness, or debug a misbehaving job under exactly the rules it has unattended. It is a
measurement and debugging tool, not a way to run jobs in production.

It behaves like `/jobs run`, not like a scheduled tick: the fire's origin is `manual`, so it meets
the same admission checks (paused, disabled, overlap, breaker, budgets) and **skips the gate** — a
person asking for a run does not get outvoted by one. `--dry-run` is where the gate is the
question: it evaluates the gate and nothing else, prints the verdict and the signal, and writes no
run row, no card and no stored signal.

Approvals fail closed exactly as they do at 3 a.m.: no auto-approve, no headless mode, no volatile
settings copy. A tool call a read-only profile denies, or one that would need a human, is recorded
as a `blocked on approval` run with the call on it — the same row and the same card a scheduled
fire would leave, so the card is in the Activity conversation the next time you open the app.

Apart from the run's own two conversations — its hidden transcript and the Activity conversation
the card lands in — the command leaves nothing behind. The things a *launch* does and a
measurement must not (creating an empty conversation in a store with nothing selected, appending
the guard-provisioning and unreadable-row notices) are suppressed for a CLI run; the fire, its
row, its card and its approvals are untouched by that.

**It refuses while another Iris process holds the store**, `--dry-run` included — a dry run
writes nothing, but opening the store may *migrate* it, and a schema migration under a live app is
a worse failure than being told to try again. The app writes a lock file holding its
pid beside the store (`conversations.sqlite.lock`) at launch and removes it at exit; `--run-job`
takes the same lock for the length of its run and gives it back. The file holds a pid and nothing
else, so the refusal names both possibilities — "another Iris process holds the store (pid N) —
the app, or another `--run-job`" — rather than sending you off to quit an app that may not be
running. GRDB's WAL would survive two writers, but
`AppState` keeps conversation state in memory, so a CLI write behind a live app desyncs the UI and
the app then saves its stale copy over the top. A lock left behind by a crash names a process that
no longer exists and is taken over; one that cannot be read or parsed is treated as held, and the
message names the file to delete. Very occasionally a crashed holder's pid has since been handed
to some unrelated process, and then there is nothing to wait for and no app to quit: the refusal
names the lock file for that case too, and deleting it is the fix.

What that covers, exactly: a CLI run started while the app is up, a second CLI run started while
the first one is going, and — because the CLI *creates* the lock file rather than checking and
then writing it — several `--run-job` launched at the same instant, of which exactly one proceeds
and the rest refuse. A harness may therefore run them in parallel and read the refusals. What it
does **not** cover is the app being launched *during* a CLI run — the app never checks the lock,
it simply takes it — so do not start Iris while a `--run-job` is in flight. (An app that starts
mid-run also keeps the lock afterwards: the CLI's release is pid-guarded and will not delete
somebody else's.)

| Exit | Meaning |
| --- | --- |
| `0` | The run `completed` — or, with `--dry-run`, the gate says something changed |
| `1` | Usage; no job with that id or name; `--dry-run` on a job that has no gate; a store that would not open; the app (or another `--run-job`) holding the lock; or the job being deleted out from under the fire |
| `2` | The run did not complete: `failed`, `blocked on approval`, `interrupted`, an admission refusal (paused, disabled, overlap, breaker, budget), or a gate that could not answer |
| `3` | The gate looked and nothing had changed (`--dry-run`) |

Without `--json` the row prints one field per line (`job`, `run`, `status`, `trigger`, `started`,
`duration`, `tokens`, `gate`, then `outcome` / `reason` / `blocked tool` when there is one). With
`--json` it is a single object with sorted keys, which is what a script or `jq` should read; a
refusal or an error prints its sentence to stderr and, under `--json`, a `{"error": …,
"exitCode": …}` object on stdout too, so a pipeline is never handed an empty stdout.

One known gap, and it is pre-existing rather than new: a few tool implementations reach
`AppState.shared` directly (skill curation, plugin auth). In the app that is the app's own state;
in a `--run-job` process it would open a *second* `AppState` over the same store. A read-only job
cannot reach any of those tools, so this is only in play for a `mutating` job, and the durable fix
is threading the run's own state to those call sites.

## The job tools

Two read-only tools let the model answer questions about jobs: `list_jobs` (every job, its trigger,
its next fire, why it is paused, how its last run ended, its policy, profile and gate kind, what
it has spent today against its budgets and the breaker, and — for a watch — its quiet window, its
ignore globs, its last burst's figures and what it has absorbed since launch, `null` for anything
else) and `get_job_run` (one run, by id or by the eight characters a card shows, including the
last thing the run itself said and, for a watch run, the burst's `watchSummary` as the row stores
it). Neither can change
anything: creating, pausing and deleting a job are `schedule_job` and `/jobs`, and nothing a
background run can reach.

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
