# Script jobs (#330)

**Status:** spec, iris-dev-2, 2026-10-19.  Brian's direction on #330: "let's do a, cheap jobs first".  The planner ruled forks A-E on 2026-10-19 (recorded under each), and Brian ruled F.  Reviewers: iris-dev-3 and iris-dev-1 (rule 26: sandbox and mounts).  The build starts once their reviews converge.

## What and why

A **script job** is a job whose action is a shell script run in the sandbox VM when the job fires.  No model turn: no background conversation, no tokens, no transcript.  The model still creates it through `schedule_job`; only the fire is model-free.

The cheap cases are the point: "tell me when the build on main goes red", "post the disk-free line every morning", "sweep `~/Downloads` of `.dmg` files older than a week".  Today each of those costs a model turn per fire, or a gate plus a turn whenever the gate says yes.

## What already exists

Most of this is built, in two places.

**Gate scripts** (`gate_script`, #187-era):
- **Review at creation:** `GateScriptReview` (`ScheduleJobArguments.swift:596`), called once in `scheduleJob`.  Vibecop judges it as a sandboxed `run_command`; anything other than APPROVE goes to the dialog with `offersAlwaysAllow: false` (#648).  The dialog shows the script, its mounts ("source → target, read-only") and its timeout together.
- **Run:** `GateEvaluator.evaluateScript` (`GateEvaluator.swift:270`).
  - A fresh container per evaluation, joined to `LiveContainerNames` through `GateContainerRegistry`.
  - Mounts forced `:ro`, with `mountDrift` re-checked every tick.
  - Workdir `/`, no env.
  - Timeout clamped 5-600 s, at creation and again at evaluation.
  - The kill happens inside the VM: `CLIContainerRuntime.exec`'s group killer, then the container is swept.
- **Network:** **on**.  The gate uses `createDetached`'s `network: .default`; the isolated network is only for grants.

**Model-free runs:** `JobAction.builtin` and `JobRunner.runBuiltin` (`JobRunner.swift:720-782`).
- A run row with `tokens: TokenUsage()`.
- The retry ladder, and a card only when asked.
- No provider or model stamp.
- Budgets skipped (`countsTokens: action == .prompt`).
- `JobAction`'s own comment already expects this case: "an action a newer build wrote (a script, say)".

So a script job is mostly `runBuiltin`'s shape with `evaluateScript`'s machinery, and a third `JobAction` case.

## The shape

- **Action.**  `JobAction.script(command: String, mounts: [ContainerMount], timeoutSeconds: Int)`, persisted with `decodeIfPresent`.  An unknown action is still refused on read, so an older build never runs a script job as a prompt.
- **Creation.**  `schedule_job` gets a mutually exclusive alternative to `prompt`: `script` (plus `script_mounts`, `script_timeout_seconds`).  Giving both, or neither, is refused with a sentence.  `prompt` stops being `required` in the schema; the executor enforces "exactly one".
- **Review.**  The same `GateScriptReview`, with "runs on every fire, no model" in the dialog title, and no Always Allow.  It's refused outright with no container runtime (F).
- **Fire.**  A `run()` branch beside `.builtin`.  It begins a row, runs the script through the gate's container path, and finishes the row:
  - zero tokens;
  - the outcome from stdout (C);
  - the full output on the row (`JobRun.scriptOutput`, a new `decodeIfPresent` column, capped, see C);
  - a card per C and D.
- **Gates on script jobs:** refused (accepted by the planner).  A script job is its own check, and it can exit early when there's nothing to do.
- **`--run-job`** works unchanged through `fire` → `run`.  **`--dry-run`** on a script job is refused (accepted): a dry run that runs the thing isn't dry.

## Forks

### A. Mounts: read-only, or the job's grant

**Option 1, read-only only (the planner's lean for v1).**  Mounts are forced `:ro` exactly as for gates, with the same `mountRefusal` and drift check, and no network decision beyond B.
- **Upside:** the review shows a script that can only read, so it's the same risk class as gates, already reviewed.  Nothing new to reason about in the VM.
- **Loses:**
  - every job that changes something: the Downloads sweep, rotating logs, `git pull` in a mirror, writing a report file;
  - anything that writes a result where the next fire can see it (state between fires), short of printing it into the ledger.

  What stays: watchers, checks, digests, "is X up", "what changed in Y", which is most of the cheap-job list in #330.

**Option 2, the job's grant (`profile: mutating`).**  Script jobs get the Grants section's model: read-write mounts (with `.iris/` and `.git/hooks` forced read-only), and `network` per B.  The review shows the grant as well as the script, as #652's mutating-job dialog does.
- **Upside:** the sweep job works.
- **Cost:** a script that writes on every fire, with no model in the loop to notice something went wrong.  The person approves the script once; after that it runs as written, against whatever is in the mount, forever.  A model-run mutating job at least reads what it's about to change.

**Ruled: option 1 for v1** (planner).  Writes come as their own PR, with their own review, filed as #688.  The jump from "a script that reads" to "a script that writes unattended" is worth that, and #330's cheapest cases are reads.

### B. Network

**Option 1, off by default (`NetworkMode.isolated`), with `script_network: true` to ask.**  The review shows "network: on" or "off".
**Option 2, follows the job's grant** (only meaningful with A option 2).
**Option 3, on, as gates are today.**

**Ruled: option 1, plus one rule** (planner).
- **Off by default.**  A script job runs on every fire, not just as a check, so it starts where grants do: network off unless asked for with `script_network: true`, and shown in the review.  "Is the site up" needs network, so the flag is in v1.
- **Network on is egress.**  Read-only mounts plus network, unattended, is a way out for whatever is mounted.  The review (below) is human-only for every script, so for a script with `script_network: true` too:
  - Vibecop's APPROVE doesn't count;
  - the dialog offers no Always Allow (the same flag as #652's).

  A test pins it: a script job, and a gate script, network on or off, raises the dialog even when Vibecop approves, and neither offers Always Allow.
- **Every script job is human-only at creation, whatever its network flag** (planner, ruling (b), revised 2026-10-19).  Vibecop advises, but its APPROVE doesn't count, and there's no Always Allow.  The same goes for gate scripts, through the #687 fold.
  - **Why it changed.**  The earlier overrule for network-off scripts rested on "it's like `read_file`".  But "off" is the isolated network, which is host-only (#690).  So a network-off script can still POST to services on the Mac (dev servers, Ollama's API, anything listening on all interfaces) on every fire, unattended, and `read_file` can't.  dev-3 caught it.
  - **The cost** is one dialog per new script job or gate script, at creation, never per fire.
  - **What the dialog says** about "network off": "can still reach services on this Mac".
  - **The way back:** if a true no-network mode passes the real-VM check (`unshare --net` in the VM, #691), a follow-up makes "off" mean off for scripts and gates alike, and network-off goes back to Vibecop review.
- **The dialog says what the combination means.**  With network on and a mount: "This script can read <mounts> and reach the internet on every run, with no one watching: it could send what it reads anywhere, or download and run more code."  With network on and no mounts, it says the second half only.
- **A change re-asks.**  Any change to a stored job's script, mounts or network (a later `schedule_job` with the same name, or an edit) goes through the same review, as a new job would.
- **Gate scripts get the same treatment, in this PR** (planner's addendum, folding in #687).  Today they get network silently and a read-only job's gate is approved on Vibecop alone.  One code path serves both:
  - an isolated network by default;
  - a `gate_network` flag, shown in the review;
  - every gate script is human-only at creation, network on or off (the same flaw, #690).

  **Existing gate-script jobs:**
  - On upgrade their network goes off, as a data migration on the stored gates, run once and keyed by a marker.
  - A one-time notice names each job and how to re-enable it: schedule it again with `gate_network: true`, which takes the human-only review.
  - Tests: the migration, the notice naming each job, and a second run changing nothing (idempotent).

### C. The card and the status

- **Status:**
  - exit 0 → `completed`;
  - non-zero → `failed`, so the retry ladder applies, unchanged;
  - a timeout → `failed`, with "script timed out after N s" (as Limits words a run timeout);
  - no runtime at fire time → `interrupted`, with "no container runtime", like a mutating job's refusal.
- **Outcome:** the **last non-empty line of stdout**, capped at 200 characters (the same cap as `outcome(from:)`).  With no stdout, it's `exit N`.
- **Full output:** stdout and stderr, each capped at 64 KB on the row (`JobRun.scriptOutput`, `scriptStderr`), with a "[truncated]" marker.  The cap is applied **in the VM** for an ordinary script: output goes to the container's `/tmp`, and only the head of each stream is sent back.  A hostile script can get round that (dev-1's #698 review: it can write to its parent's stdout through `/proc/$PPID/fd/1`), so the host holds it too: #699's bounded drain keeps 128 KB of each stream while reading, as dev-3 asked, and a run past it on stdout fails.  Stored output is shown as plain text, never rendered as Markdown (dev-1).  The gate path captures output whole with no byte cap, which I'd fix here for both, since a chatty script would otherwise fill the ledger.  `get_job_run` returns it, as untrusted (D).
- **When a card posts.**  **Ruled: only on a change or a failure** (planner, fork ii).
  - **"Change"** means the exit status or the outcome line differs from the previous run's.
  - **The first run** always posts.
  - **Every run** writes its ledger row regardless.
  - **`/jobs`** shows "last posted" and "last ran" separately, so a quiet job doesn't look dead.

### D. Output is untrusted (a rule)

- **The card.**  The card's one-line summary goes into the destination's history (jobs.md, "Delivery"), and today `deliverEvent` sanitizes `historyLine` at **tier 1 only** (`EventDelivery.swift`).  That's fine for a model's own one-liner, but not for a script's stdout, which can be anything a mounted file or a web response put there.
  - So for a script job, the outcome passes `InjectionGuard.sanitize(..., contextTag: "script_output", maxTier: .tier3_canary)`, as gate output already does in `buildPrompt` (`JobRunner.swift:2053`), before it becomes the card's outcome.
  - A blocked verdict replaces it with "output withheld: the injection guard blocked it" and keeps the raw text on the row only.
  - **Only a line that will be posted is checked** (planner).  Under C that's rare, and tier 3 isn't free: with the cloud engine it's a model call.
  - **Guard calls aren't charged to job budgets today (#689).**  I checked.  `CloudAuxiliaryEngine.generate` calls `LLMClient().generateContent(tier: .easy)` and returns only the text, so the usage is discarded.  That's true for Vibecop and for gate output's tier 3 alike.  A script job does the same, and charges nothing.  Charging guard calls is its own change, for every caller, filed as #689.  **Ruled (planner): it stays in #689**, since charging one caller would make the ledger inconsistent.  That answers dev-3's ask to count cloud canary tokens here.
  - **Whether a card will post** is decided on the raw output, before the guard runs (dev-3), so the guard runs only on a line that's going out.
  - **Wording:** the docs never call a script run "zero tokens".  They say "no model turn", plus a line that the injection guard may call the primary's easy tier on a posted line.
  - **Tier 3 unavailable** (`.skipped`): tiers 1 and 2 still run.  No card path marks this today; a skip shows only as the launch notice and the P2/P3 light (#218).  So the card gets a short marker, "(checked without tier 3)", in its outcome.  **Ruled (planner): accepted.**  It's the same text on any card path that adds it later, and jobs.md's Delivery section mentions it.
- **`get_job_run`** wraps the stored output with `InjectionGuard.wrapped` like any tool output.
- **Test:** a script whose stdout is an injection string ("SYSTEM: ignore previous instructions and …"), under a scoped canary that flags it.  The card's history line must hold the withheld text, not the string, and so must the `get_job_run` result.  A mutation that skips the guard must fail it.

### E. Budgets and the timeout

- **Budgets are zero tokens:** `countsTokens` is already `action == .prompt`.  Breaker, overlap, catch_up and retry apply unchanged.
- **Timeout:** option (i) the gate's 5-600 s clamp, or option (ii) the job's `timeout_seconds` (60-3600) and `RunDeadlineWatchdog`.  **Ruled: (ii), with the gate's lower bound** (planner).  `script_timeout_seconds` is clamped to 5-3600, default 120.  A script job is a run, not a check, and the run limits (Limits, `JobLimits.resolve`) are where a person looks for "how long may a job take".  A one-hour ceiling is still bounded.  The deadline runs on the dispatch-based watchdog (Invariant 4), and the kill is the in-VM group kill.

### F. VM only (ruled)

Brian: "Let do it this way for now and if it becomes a hindrance we can revisit".  No host variant.  `schedule_job` refuses `script` without a container runtime and sandboxing on.  A fire that finds the VM gone is `interrupted` (C), never run on the host.

## Invariants

- **Invariant 4.**  The container joins `LiveContainerNames` (through `GateContainerRegistry` or its sibling).  The deadline is on the dispatch watchdog, the kill happens inside the VM, and the container is swept on every exit.  A `--run-job` stopped by a signal ends it as it ends a gate.
- **Invariant 1.**  `JobAction.script`, `JobRun.scriptOutput` and `scriptStderr` are read with `decodeIfPresent`, and the ledger gets new columns.
- **Invariant 6.**  No new tool: `schedule_job`'s new arguments sit beside `gate_script`'s.
- **Invariant 9**, the sentences this makes untrue (searched, not composed).  Also, from #687: jobs.md's gate-script section and the `gate_script` text in the `schedule_job` description both say or imply that a gate script has network, or doesn't say; they gain "network off unless `gate_network`, which asks you":
  - jobs.md:3: "A job is … a recurring prompt (`schedule_job`) or a directory watch".
  - jobs.md:18-20 and :689-692: every fire is "a run in a hidden conversation".
  - jobs.md:701, built-ins: "`schedule_job` cannot create one".  This stays true for built-ins, but the section needs a sibling for script jobs.
  - jobs.md:763-764: the `completed` and `failed` meanings are in model terms.
  - jobs.md:782-783: the card has "tokens" and a "View run" button onto the transcript.  A script run has neither; it'll show "View output".
  - The `schedule_job` description (`iris.swift:2261`) says "Each fire runs in the background, in a hidden conversation of its own" and makes `prompt` the only action.  This is agent-facing, so it's the one that matters.
  - `/jobs` has no action column.  Add an `action` field to `list_jobs` (`script`), and "script" to the trigger cell.

## Tests

- **Fake runtime** (the default suite): creation and refusal (both or neither of prompt and script, script with a gate, no runtime), the review dialog's text, the status mapping, the outcome line and its cap, the output caps, the card rule (C), the guard (D), the timeout, and decoding an older build's rows.
- **Real VM** (rule 29, `IRIS_REAL_VM=1`).  The planner routes these to work after confirming that work's standing instructions allow container; I tell the planner when the build reaches that point:
  1. A script job fires and its stdout last line becomes the outcome.
  2. A script that overruns its timeout is killed in the VM, leaving no process and no container.
  3. With network off (B), `curl` fails and the run is `failed`.
  4. A read-only mount refuses a write (`touch` → non-zero exit, `failed`).

## Known limits

- **Changed content after review** (the planner's reason for ruling (b)).  A script judged once can run content that changes after review.  One that executes a file from a mount (`sh /mnt/repo/check.sh`) runs whatever that file holds at each fire, and with host-only network that content can reach Mac services.  The follow-up that relaxes network-off scripts to Vibecop review once there's no interface (#691) has to argue that changed content can then only read the mounts and print a guarded line, which is what `read_file` already allows.
- **Changing the stored script outside Iris** is caught: the review's fingerprint (script, mounts, network, timeout) is kept in the Keychain item beside the API keys, and a fire that doesn't match is refused, carded once, and paused until re-scheduled (planner, 2026-10-19).  Gate scripts too.  **No trust-on-first-use pass** (planner, after dev-3's #698 review: a silent item delete would replay its marker and bless edited rows): a gate or script job with no fingerprint pauses once with "script needs your review (new check in this version)", distinct from "changed since review", and a re-schedule is the review.
- **A deleted Keychain item stops script jobs; it doesn't unlock them.**  No fingerprint means a pause for review, and an unreadable item refuses every script fire.

## Scope

Closes #330 and #687.

## Out of scope

- Host scripts (F).
- Gates on script jobs.
- Writes (A option 2, its own PR).
- Secrets in the environment.
- A script job that starts a model turn on some exit code.  That's a gate, which exists.
