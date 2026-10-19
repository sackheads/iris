# Script jobs (#330)

**Status:** draft spec, iris-dev-2, 2026-10-19.  Brian's direction on #330: "let's do a, cheap jobs first".  Forks A-E below are for the planner (and Brian where they touch money or safety); F is already ruled.  Reviewers: iris-dev-3 and iris-dev-1 (rule 26: sandbox and mounts).  Nothing is built until the forks are ruled.

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
- **Gates on script jobs:** not in v1.  A script job *is* its own check, so `gate_*` together with `script` is refused.  (A script can exit early when there's nothing to do.)
- **`--run-job`:** works unchanged through `fire` → `run`.  `--dry-run` on a script job is refused with a sentence, since there's no model turn to skip; or it could run the script without writing a row.  I lean refuse: a dry run that runs the thing isn't dry.

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

**Lean: option 1 for v1, then option 2 as its own PR** once read-only script jobs have run for a while.  The jump from "a script that reads" to "a script that writes unattended" is worth its own review, and #330's cheapest cases are reads.

### B. Network

**Option 1, off by default (`NetworkMode.isolated`), with `script_network: true` to ask.**  The review shows "network: on" or "off".
**Option 2, follows the job's grant** (only meaningful with A option 2).
**Option 3, on, as gates are today.**

**Lean: option 1.**
- Gate scripts get network silently today, which is looser than the grants model.  A script job runs on every fire, not just as a check, so it should start where grants do: off unless asked for, and shown in the review.
- "Is the site up" needs network, so the flag is needed in v1 even with read-only mounts.
- **For the planner:** should gates move to the same default?  That's a separate behaviour change for existing jobs, so I'd file it rather than fold it in.

### C. The card and the status

- **Status:**
  - exit 0 → `completed`;
  - non-zero → `failed`, so the retry ladder applies, unchanged;
  - a timeout → `failed`, with "script timed out after N s" (as Limits words a run timeout);
  - no runtime at fire time → `interrupted`, with "no container runtime", like a mutating job's refusal.
- **Outcome:** the **last non-empty line of stdout**, capped at 200 characters (the same cap as `outcome(from:)`).  With no stdout, it's `exit N`.
- **Full output:** stdout and stderr, each capped at 64 KB on the row (`JobRun.scriptOutput`, `scriptStderr`), with a "[truncated]" marker.  The gate path captures output whole with no byte cap, which I'd fix here for both, since a chatty script would otherwise fill the ledger.  `get_job_run` returns it, as untrusted (D).
- **When a card posts.**  Option (i) every fire, like a prompt job.  Option (ii) only when the outcome changed since the last run, or on failure.  **Lean: (ii)**, since a digest that says the same thing every hour is noise.  The person can still read every run in `/jobs`.  For the planner.

### D. Output is untrusted (a rule)

- **The card.**  The card's one-line summary goes into the destination's history (jobs.md, "Delivery"), and today `deliverEvent` sanitizes `historyLine` at **tier 1 only** (`EventDelivery.swift`).  That's fine for a model's own one-liner, but not for a script's stdout, which can be anything a mounted file or a web response put there.
  - So for a script job, the outcome passes `InjectionGuard.sanitize(..., contextTag: "script_output", maxTier: .tier3_canary)`, as gate output already does in `buildPrompt` (`JobRunner.swift:2053`), before it becomes the card's outcome.
  - A blocked verdict replaces it with "output withheld: the injection guard blocked it" and keeps the raw text on the row only.
- **`get_job_run`** wraps the stored output with `InjectionGuard.wrapped` like any tool output.
- **Test:** a script whose stdout is an injection string ("SYSTEM: ignore previous instructions and …"), under a scoped canary that flags it.  The card's history line must hold the withheld text, not the string, and so must the `get_job_run` result.  A mutation that skips the guard must fail it.

### E. Budgets and the timeout

- **Budgets are zero tokens:** `countsTokens` is already `action == .prompt`.  Breaker, overlap, catch_up and retry apply unchanged.
- **Timeout:** option (i) the gate's 5-600 s clamp, or option (ii) the job's `timeout_seconds` (60-3600) and `RunDeadlineWatchdog`.  **Lean: (ii), with the gate's lower bound.**  `script_timeout_seconds` is clamped to 5-3600, default 120.  A script job is a run, not a check, and the run limits (Limits, `JobLimits.resolve`) are where a person looks for "how long may a job take".  A one-hour ceiling is still bounded.  The deadline runs on the dispatch-based watchdog (Invariant 4), and the kill is the in-VM group kill.

### F. VM only (ruled)

Brian: "Let do it this way for now and if it becomes a hindrance we can revisit".  No host variant.  `schedule_job` refuses `script` without a container runtime and sandboxing on.  A fire that finds the VM gone is `interrupted` (C), never run on the host.

## Invariants

- **Invariant 4.**  The container joins `LiveContainerNames` (through `GateContainerRegistry` or its sibling).  The deadline is on the dispatch watchdog, the kill happens inside the VM, and the container is swept on every exit.  A `--run-job` stopped by a signal ends it as it ends a gate.
- **Invariant 1.**  `JobAction.script`, `JobRun.scriptOutput` and `scriptStderr` are read with `decodeIfPresent`, and the ledger gets new columns.
- **Invariant 6.**  No new tool: `schedule_job`'s new arguments sit beside `gate_script`'s.
- **Invariant 9**, the sentences this makes untrue (searched, not composed):
  - jobs.md:3: "A job is … a recurring prompt (`schedule_job`) or a directory watch".
  - jobs.md:18-20 and :689-692: every fire is "a run in a hidden conversation".
  - jobs.md:701, built-ins: "`schedule_job` cannot create one".  This stays true for built-ins, but the section needs a sibling for script jobs.
  - jobs.md:763-764: the `completed` and `failed` meanings are in model terms.
  - jobs.md:782-783: the card has "tokens" and a "View run" button onto the transcript.  A script run has neither; it'll show "View output".
  - The `schedule_job` description (`iris.swift:2261`) says "Each fire runs in the background, in a hidden conversation of its own" and makes `prompt` the only action.  This is agent-facing, so it's the one that matters.
  - `/jobs` has no action column.  Add an `action` field to `list_jobs` (`script`), and "script" to the trigger cell.

## Tests

- **Fake runtime** (the default suite): creation and refusal (both or neither of prompt and script, script with a gate, no runtime), the review dialog's text, the status mapping, the outcome line and its cap, the output caps, the card rule (C), the guard (D), the timeout, and decoding an older build's rows.
- **Real VM** (rule 29: work can run these through the planner, `IRIS_REAL_VM=1`):
  1. A script job fires and its stdout last line becomes the outcome.
  2. A script that overruns its timeout is killed in the VM, leaving no process and no container.
  3. With network off (B), `curl` fails and the run is `failed`.
  4. A read-only mount refuses a write (`touch` → non-zero exit, `failed`).

## Out of scope

- Host scripts (F).
- Gates on script jobs.
- Writes (A option 2, its own PR).
- Secrets in the environment.
- A script job that starts a model turn on some exit code.  That's a gate, which exists.
