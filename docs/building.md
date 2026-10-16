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
