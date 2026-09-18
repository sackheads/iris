# perf/ — the tracked performance database

Iris runs a headless suite of scenarios and records where each turn's time goes. Records are
compared over time against a promoted baseline. The design is in
`docs/specs/2026-09-17-performance-evaluation-suite.md`.

## Run it

    perf/run.sh                 # release build; smoke + ladder + tool-eagerness; compare to baselines
    perf/run.sh --fake-only     # smoke only, no credentials or network
    perf/run.sh --promote       # also copy this run's records into perf/baselines/

Real-lane suites need a configured provider (the ladder was first run with Gemini via ADC).
Run on a quiet machine; timings from a debug build or a dirty tree are flagged in the report.

## Layout

    suites/      what to run: scenarios, lane (fake/real), repetitions, pause, ladder rungs
    prompts/     scenario files grouped by category (model-only, model-only-2, tool-use, fake)
    runs/        one JSON record per suite run (gitignored)
    baselines/   promoted records that later runs compare against (committed)

## The ladder

Each real-lane prompt is timed at up to five rungs; each delta isolates one layer:

| rung | what runs | delta isolates |
|---|---|---|
| 1 | bare provider call, prompt only | the model (the denominator) |
| 2 | + Iris's assembled system prompt | prompt size |
| 3 | + the tool declarations | tool schema |
| 4 | full Iris turn, guards off | harness overhead |
| 5 | full Iris turn, guards as configured | the security layers |

**Overhead ratio** = median rung 5 / median rung 1. **Harness ratio** = rung 4 / rung 1.

Rung 5 includes Vibecop: headless runs auto-approve every tool, but they first run the Vibecop
evaluation a real `run_command` would run and record its `vibecop` span (the verdict is not acted
on). Rung 4 and the fake lane skip it along with the other guards.

There is no unit-test seam to assert guards are switched off under a volatile copy; the evidence
is in every ladder record, where rung 4 turns carry zero `guard.*` and `assembly.userProfile`
spans while rung 5 turns do not.

## Keychain and unattended runs

Every rebuild changes the binary's ad-hoc signature, and the Keychain re-prompts each new binary
on its first secret read, which silently blocks an unattended run. Real-lane runs on Gemini over
ADC never touch the Keychain (the token comes from gcloud), so they run unattended after a
rebuild. Any API-key configuration prompts once per rebuild; run one quick command with the new
binary and click "Always Allow" before starting a long suite.

## Real-lane tool execution

Real-lane suites force `run_command` through the sandbox (the main-agent sandbox default is set
to sandboxed inside the run's volatile settings copy, never in your preferences), because tool
prompts run unattended with auto-approve. The record's `toolSandbox` field says which mode ran,
and `compare` refuses to compare records whose modes differ. Records also keep each tool call's
arguments (capped at 500 characters; values under credential-looking keys and token-shaped
substrings are replaced with `[redacted]`), promoted baselines included, so a tool storm can be
read afterwards without committing a secret.

## Reading a record

`iris --perf report <run.json>` renders the Markdown summary. Per scenario: a row per rung with
median and p90 wall-clock and median prompt tokens, the two ratios, the top five named spans
(`guard.tier3`, `vibecop`, `assembly.userProfile`, ...), and the tool-call rate with a histogram, and, for prompts that declare `expectedTools`, the
**unexpected tool-call rate**: turns that called any tool outside that list (bait prompts declare
`[]`, controls declare their one tool, so an extra `read_file` next to a `set_workspace` counts).

`iris --perf compare <baseline.json> <run.json>` prints percent change per metric and flags any
increase past 20% (`--threshold` to change) that is also at least 50 ms in absolute terms, so
fake-lane turns of a few milliseconds cannot trip the gate on scheduler noise. Exit 1 means a regression was flagged; exit 2 means
the records are not comparable (different provider or model names).

## Promoting a baseline

A baseline is a record you trust as the reference. `perf/run.sh --promote` copies the run's
records into `perf/baselines/`; commit them. Later runs compare against the newest baseline for
the same suite.

**v0 baselines.** The first ladder and eagerness baselines (2026-09-17) are flagged dirty only
because `--promote` wrote the smoke baseline mid-run, and the ladder's rung 2 tool-use rows have
no successful repetitions (a Gemini candidate without `parts` fails to decode; tracked as a
follow-up); compare skips those rungs.
