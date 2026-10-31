# Building Iris from source

Moved from the README, which now links here.

Iris is managed via Swift Package Manager (SPM).
To build:
```bash
swift build
```

## Running a dev build

```bash
swift run
```

`swift run` re-signs the binary ad-hoc on every rebuild, and macOS keys Keychain access to the
signature, so each rebuild asks for Keychain access again. With a Developer ID Application
certificate in your keychain, `scripts/run-dev.sh` builds, signs with it, and launches, so one
"Always Allow" sticks across rebuilds. `perf/run.sh` signs the same way when the certificate is
present (or `CODESIGN_IDENTITY` is set). The Xcode app build (`scripts/build-app.sh`, below) signs
through Xcode's own manual signing instead, with a fixed Developer ID identity in `project.yml`.

A build from source — `swift run`, `scripts/run-dev.sh`, or the Xcode Debug scheme — is a **dev
build**: it keeps its own conversations and memory under `~/.iris-dev`, not the installed app's
`~/.iris`, uses its own `.dev`-suffixed Keychain services, and answers to
`Cmd + Shift + Option + Space` instead of the installed app's [global hotkey](features.md#global-hotkey). Its settings are not in `~/.iris-dev`:
every dev build (`swift run`, `scripts/run-dev.sh` and the Xcode Debug build) shares the
`com.bnaylor.iris.dev` defaults domain, separate from the installed app's `com.bnaylor.iris`. Its
first launch copies in the settings an older dev build left in the legacy `iris` domain, once.
`scripts/run-dev.sh` seeds
`~/.iris-dev` from `~/.iris` and its Keychain
items when `~/.iris-dev` is missing or empty (`iris --seed-dev-home`), so a local build starts from
your installed app's conversations, memory and keys instead of empty; copied jobs arrive paused, so
they do not fire in both apps. Any dev launch creates `~/.iris-dev`, so a first `swift run` before
`scripts/run-dev.sh` leaves a home that is never seeded (`run-dev.sh` says so when it sees one). To
reseed, quit the dev build and run `rm -rf ~/.iris-dev && scripts/run-dev.sh`.

The seeded Keychain items trust only the binary that made them, the bare `iris` that `run-dev.sh`
runs, so Iris Dev.app asks for your login password once for each of them, the first time it reads
it: `com.iris.secrets.dev` at launch, then `iris.mcp.dev` and each plugin's
`iris.plugin.<id>.dev` when first used. The seeder's success line lists the ones it copied. Keep
the app open and choose **Always Allow** each time: that adds the app to that item's access list
for good, rebuilds included as long as they are signed with the same Developer ID (`build-app.sh`
does). **Deny**, or quitting the app before you answer, means that item asks again at the next
launch (#578).

To build a real `.app` bundle from the command line instead of Xcode, run
`scripts/build-app.sh Debug` (needs `brew install xcodegen` and the Metal Toolchain). Either way,
building the app needs the team's Developer ID Application certificate in your keychain —
`project.yml` signs it manually with that fixed identity, not an Xcode account. See
`AGENTS.md`'s "Build and test" section for the `Release` config and why not to launch it before
your first real install.

## Headless profiling (`--bench`)

The core agent loop runs without the UI, so you can profile end-to-end turn performance
without clicking through the app. Run a benchmark scenario:

```bash
swift run iris --bench                          # built-in default scenario
swift run iris --bench scenarios/echo-latency.json   # a scenario file
swift run iris --bench scenarios/live.json --real    # hit a real provider (needs keys)
```

The binary runs the scenario headlessly and prints a per-category timing breakdown (primary
LLM, tool execution, injection guard, context assembly, …), then exits. Fake scenarios script
the model's responses (with optional simulated latency) and need no network or API keys;
`--real` drives a configured provider for true wall-clock measurement.

Scenario files are JSON. For the full scenario schema, how to read the output, and how to
author new scenarios, see **[docs/headless_profiling.md](headless_profiling.md)**. The
same `ScenarioRunner` powers the profiling tests under
`Tests/irisTests/ProfilingHarnessTests.swift`.

For repeatable performance tracking over time, run `perf/run.sh`: it executes the suites under
`perf/suites/` at a release build, records where each turn's time goes (including a five-rung
comparison against a bare provider call), and compares against promoted baselines. See
[perf/README.md](../perf/README.md).

## Model evals (`--eval`)

```sh
swift run iris --eval run injection.classifier --model onnx:~/.iris/models/<bundle dir>          # a 60-text sample of test
swift run iris --eval run injection.classifier --model onnx:~/.iris/models/<bundle dir> --full   # the whole test split: graded
swift run iris --eval run injection.verdict --model ollama:gemma4:12b --full                      # tier 3's canary, 3 repeats
swift run iris --eval run injection.stack --stack 1+2+3 --tier2 onnx:<bundle dir> --tier3 ollama:gemma4:12b --full
swift run iris --eval compare eval/results/<task>/<a>.json eval/results/<task>/<b>.json --vary model
swift run iris --eval table                                                                       # regenerates docs/evals.md
```

Scores a guard model on a frozen dataset (`eval/datasets/`, injection v3 unless `--dataset` names another) through the product's own path, and writes one result file under `eval/results/<task>/` to commit ([spec](specs/2026-10-28-model-eval-framework.md), #788).  The model is always named on the command line, never read from the home's settings, and a run reads no Keychain item (#805):
- **`injection.classifier`:** a tier-2 classifier, `onnx:` or `coreml:`.
- **`injection.verdict`:** tier 3's canary, with tier 2 passing everything: `ollama:<name>`, `llamacpp:<path to a .gguf file>` or `mlx:<Hugging Face id>` (#815). The engine is built as the product builds the `canary` role and is the run's own. A GGUF file is fingerprinted by its sha256, an MLX model by the files of its snapshot in the Hugging Face cache (`HF_HUB_CACHE`, else `HF_HOME/hub`, else `~/.cache/huggingface/hub`; the first load downloads it there). The result's runtime version is the engine package this checkout pins (`llama.swift <revision>`, `mlx-swift <version>`), read from `Package.resolved`. `--think` applies to Ollama only: the other two engines have no thinking switch, and `--think on` or `off` is refused.
- **`injection.stack`:** the guard as a whole, with each tier named: `--stack 1+3`, or `1+2+3` with `--tier2`. From scoring version 2 (#830) each row of a stack result says which tier blocked it (`blocked_by`: `tier2`, `tier3`, `tier3_after_partial` or `none`) and what tier 2 said (`tier2_verdict`: `safe`, `partial`, `malicious`, `error`, or `skipped` for `1+3`), taken from the guard's own result for that judgement, so it holds when judgements run side by side. Rows of the earlier stack results (version 1) have neither field, and the three committed ones don't compare with a new one.

The canary sends thinking as the product does (off for a model that thinks, #783), unless `--think on` or `off` says otherwise. The canary tasks judge every text 3 times (`--repeats`). Their rates pool the judgements, and a result lists the texts judged differently across repeats as unstable; `compare` leaves those out of its flips and applies the spec's margin rule to false positives and recall: a difference is real only if it moves by at least 2 stable texts and by more than twice the larger of the two results' repeat spreads (the range of each repeat's own rate, recorded in the result as `false_positives_by_repeat` and `recall_by_repeat`, #816). A result from before they were recorded has no spread, and `compare` says so and gives no verdict, never a zero spread. A text whose canary couldn't be reached counts as `infra`. A timeout, an error or an answer with no clear verdict (read by the product's own parser, #821) counts as `fail-closed`, as the product blocks it.  Dev builds only, and read-only apart from the result file: no store, conversation, job or home lock.  Results are append-only: a second run the same day gets `-2`, and CI fails a pull request that edits or deletes one (`scripts/eval-append-only.sh`).  `compare` refuses two results whose version keys differ, unless `--vary` names what's meant to differ; task, configuration and scoring version never compare across.  A result gives the false positives and recall of texts marked `exposure: clean` apart, and v3's fresh attacks' recall on its own line. A run prints `MODEL CHANGED` when the model's fingerprint differs from its last committed result.  The results table is [docs/evals.md](evals.md).

## Held memory changes (`--context-holds-report`)

```sh
swift run iris --context-holds-report            # the last 7 days
swift run iris --context-holds-report --days 30
```

Prints, per day, how often the hold on standing-context writes asked (#813, [memory](memory.md)): the turns that showed the chip, the items held by tool, how many were approved, declined, went stale, failed to apply or are still pending, and the median time from the hold to the decision, each for the pinned Iris and for other conversations. It reads `conversations.sqlite` read-only (no lock, no migration, so it runs beside the app), and touches no Keychain item and no settings. A store older than the hold reads as zeros. It's local only; nothing is sent anywhere.

## Timing the guard models (`--guard-probe`)

```sh
swift run iris --guard-probe                       # judge one benign text through tiers 2 and 3
swift run iris --guard-probe --reps 3              # three judgements in one process
swift run iris --guard-probe --prebuild 20         # build the canary engine 20 s before judging
```

It reads this dev home's guard settings and prints a timestamped `[perf]` line for each model
load's begin and end, each tier's start and end, and each Ollama request, with Ollama's own
`load_duration` (#778). Dev builds only, and read-only: no conversation store, job or home lock,
and a cloud tier 3 is skipped rather than called. Each rep's text gets a suffix so the verdict
cache never answers for the model. The fake lane of `--perf` runs with the guards off, so it can't
time them. The app writes the same `[perf]` lines to stderr.

`--fixtures` runs a folder of labelled texts (#785's `benign.jsonl` and `attacks.jsonl`) through
the guard with tier 2 passing everything, so each verdict is tier 3's alone, on the one model
`--model` names (#783's bake-off; #788's `iris --eval` replaces it):

```sh
swift run iris --guard-probe --fixtures Tests/irisTests/Fixtures/tier2-eval --model ollama:gemma4:12b \
  --arm g12-today --out ~/bakeoff --joins --latency --repeats 3 --agreement-sample 40
swift run iris --guard-probe --fixtures … --model ollama:gemma4:12b --think off --arm g12-off \
  --out ~/bakeoff --baseline ~/bakeoff/g12-today.jsonl
swift run iris --guard-probe --fixtures … --model cloud:gemini/gemini-3.8-flash --thinking-level low \
  --arm flash-low --out ~/bakeoff --allow-paid --max-dollars 2
swift run iris --guard-probe --compare ~/bakeoff --baseline-arm g12-today   # the table, also table.md
```

Each run writes one row per judgement to `<out>/<arm>.jsonl`, with the model's digest, the machine
and the dataset's sha256 in a header row. `--joins` adds each benign category joined to 8 and
32 KB; `--latency` times a cold call, five warm and three rounds of three at once; `--baseline`
re-judges, `--flip-repeats` times (3), every text whose first verdict differs from that arm's.
`--think off` asks a thinking Ollama model not to think. A cloud arm makes paid calls. It needs
`--allow-paid`, prints its estimate before the first call, and never passes `--max-dollars` (5):
each call first reserves the most it could cost in the spend ledger, and settles what it did cost
after. `--spend-ledger FILE` makes one cap for every arm naming that file, even running at once:
the file is append-only (a line per reserve and per settled call, with its tokens and dollars) and
locked while read and appended, and one that exists but won't read or parse stops the run.
`--estimate-only` makes three real calls (counted in the ledger) and prints an estimate calibrated
on their tokens, thinking included; a full run prints its estimate with the assumption it uses. It
uses gcloud's ADC on Vertex (project from `GOOGLE_CLOUD_QUOTA_PROJECT` or gcloud's config) and
never reads the Keychain; `--gemini-auth key` uses the Keychain's API key instead.
`--thinking-level` is added to the probe's own request body only; the product sends none. The
table also counts each arm's calls slower than the product's 60 s request timeout (#797).

## Running one job headlessly (`--run-job`)

```bash
swift run iris --run-job pr-sweep              # fire one job now, print its ledger row
swift run iris --run-job pr-sweep --dry-run    # ask only its gate; write nothing
swift run iris --run-job <job id> --json       # the same row as one JSON object
```

`--run-job` opens your real conversation store and the real model client, fires one job the way
`/jobs run` does (admission applies, the gate does not), prints the run's ledger row — status,
reason, tokens, duration, gate signal — and exits: no scheduler, no watchers, no window. Approvals
fail closed exactly as they do unattended, and the run's event card is delivered as usual, so the
Iris conversation shows it the next time you open the app. It **refuses while another Iris process
has this home** — the app, another `--run-job`, or `--seed-dev-home` while it copies — rather than
writing behind a live `AppState`. The lock is a `flock(2)` on `conversations.sqlite.lock` beside
the store, held for the process's whole life and released by the kernel however it exits, so a
crash leaves nothing to clean up. Several `--run-job` started at the same instant are told apart:
one runs and the rest refuse, naming the pid (and job) that has it. An app opened during a
`--run-job` waits: its window, and the menu under an hourglass in the menu bar, name the run, and
Iris opens once the run ends. There is no timeout, and nothing in the waiting app stops the run (it
can only quit); end the run from its terminal. A second app on the same home says "Iris is already
running on this home" and quits.

Exit codes: `0` completed (or a `--dry-run` gate that saw a change); `2` failed, blocked on
approval, interrupted, or refused by admission (and a gate that could not answer); `3` a
`--dry-run` gate that saw no change; `1` usage, an unknown job, `--dry-run` on a job with no gate,
a store that would not open, the store's lock held by the app, another `--run-job`, the seeder or
an older Iris build, or a lock that could not be taken at all (the path and error are named);
`130` (or `143`, `129`) a second signal. The first Ctrl-C, SIGTERM or SIGHUP stops a run cleanly:
its turn is cancelled, its row reads "stopped by a signal (SIGINT)", the card is delivered (for a
stop before the turn started too), the containers it made are deleted by name, and it exits `2`:
for a stop mid-turn, within about 28.5 seconds; a stop during the checks before the turn first
waits for the one under way, up to about 2 minutes for a grant's isolated-network check. A second exits at once, and a third Ctrl-C kills it outright. Under
`nohup`, closing the terminal does not stop it. A container whose delete fails, or one a crash leaves,
is deleted by the next launch on that home, of the app or of `--run-job`. Full detail,
including what a dry run does and does not record, what the lock does and does not protect, and
what a stop does not reach, is in **[docs/jobs.md](jobs.md)** ("Stopping a run").
