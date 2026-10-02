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
prompts run unattended with auto-approve. Only `run_command` is sandboxed: `read_file`,
`write_file`, and the other file tools act on the host, so a real-lane run also changes its cwd to
a **fixed** scratch directory under the temporary folder (`$TMPDIR/iris-perf`, not a per-run UUID
— a per-run location put a different absolute path in the skills list's `**Path:**` lines on every
run, which cache-busted the system prompt and confounded cross-run comparisons, #321), binds each
throwaway conversation's workspace to it, and routes the whole `~/.iris` home (memory, rules,
config, plugins copied; models symlinked) at a copy inside it, so the memory tools cannot touch
your real USER.md, fact store or skills; the run exits 3 with a warning if the real memory
directory changed anyway; relative and workspace-relative paths land there and the directory is
reset to empty at the start of every run (not just removed at the end, so a crash or `^C` that
skips that cleanup cannot leak a stale copy into the next run) and removed after the run too. The
scratch directory is exclusively locked for the run's length — a second `iris --perf run` started
while one already holds it is refused with a message naming the holder's pid, rather than racing
it for the same directory. An absolute path would still reach the host, which is why prompt files
are reviewed before they are committed. The record's `toolSandbox` field says which mode ran,
and `compare` refuses to compare records whose modes differ. Records also keep each tool call's
arguments (capped at 500 characters; values under credential-looking keys and token-shaped
substrings are replaced with `[redacted]`), promoted baselines included, so a tool storm can be
read afterwards without committing a secret.

## The caching suite

`perf/suites/caching.json` runs three real-lane, rung-4 scenarios from `perf/prompts/caching/`.
Each scenario's `seedFacts` are written, before turn 1, into a fresh
in-memory fact store scoped to that run alone — never the developer's real store and never shared
across repetitions — so the fact-store block a turn's request carries is deterministic, and
`PerfSuiteFilesTests` pins each scenario's match schedule. `six-turns.json` is the best case: its
seeds carry only tokens distinctive enough that no prompt but turn 2's shares one, so the schedule
is exactly `[false, true, false, false, false, false]` and the block appears once, then disappears
for good; turn 3 calls a tool, so it has more than one model round. `every-turn-facts.json` is the
realistic case: each of its six turns matches its own seed, so the block changes on every turn.
`tool-heavy.json` has five turns: turns 1, 2 and 3 each match their own seed, and turn 2 runs a
dozen commands one at a time. Turn 2's entry changes at turn 3 and spans far more than 20 content
blocks, so turn 3 can read past the system prompt only through the explicit end-of-turn-k−2 marker
(spec §1; measured old vs new in §3.1). This is the suite that measures prompt-cache behavior across the 5a request
change (see `docs/specs/2026-09-30-agency-cacheable-prompts.md` §3 for the before/after baselines);
it needs a configured provider and is not part of `perf/run.sh`'s default sweep, so run it manually:
`iris --perf run perf/suites/caching.json`.

Since 5a's request change landed (the fact block and peer count moved out of the system prompt and
into a per-turn `<turn_context>` block on the turn's own user entry), rungs 2 and 3 replay a system
prompt that no longer holds either, so they measure the stable prefix only and are not comparable
with pre-5a baselines. Anthropic's prompt tokens also jump across the 5a boundary, since they now
include cached tokens. `--perf compare` accounts for this itself rather than needing a manual
workaround: "prompt tokens" is the metric the regression gate reads, so on a pair that straddles the
boundary (one side carries cache counts, the other doesn't) that row is marked informational with an
explanatory note instead of being flagged, and the separate "uncached prompt tokens" row — always
informational, since it swings with cache warmth rather than what was sent — is emitted only when
both sides of the comparison carry cache counts, i.e. never on a straddled pair.

`IRIS_PERF_DECLARE_STATE_TOOLS=1 iris --perf run …` is 5a's tool-list experiment (spec §0.6): the
state-gated tools (`manage_fact` and the peer tools) are declared on every turn instead of only when
their state holds. Perf runs pin the peer count to 0, so the peer tools are declared with no
`# Active Sessions` block. The record says so (`stateGatedToolsAlwaysDeclared`), its recorded tool
count is the experiment's list, and `--perf compare` on a pair where only one side ran it prints a
note and marks the prompt-token row informational, since the two sent different tool lists.

`--dump-requests <dir>` on `iris --perf run` writes each round's request body — exactly the body the
client builds, keys sorted (5a) — reusing
`AnthropicClient`/`OpenAIClient`'s own `makeURLRequest` builders with the currently configured
streaming flag (Gemini's body is just the request's own JSON encoding, and streaming or not makes
no difference to it) — to `<dir>/<scenario>/rung-<N>/<rep>/<turn>-<round>.json`, where `<round>` is
the engine's own model round and matches `ModelCallRecord.round` in the same run's record; a retry
after a transient failure is named explicitly, `<turn>-<round>-retry<k>.json`, rather than shifting
into the next round's slot (5a review F4). The rung is part of the path so a suite that dumps more
than one rung (e.g. 4 and 5) never has one rung's files overwrite another's. Nothing is sent over
the network; a placeholder API key is used so the dump works even without configured credentials.
These are what a byte-prefix diff reads to find exactly where two rounds' requests first differ:
every request-path encoder now sorts keys, so a divergence it finds is real content or prefix
drift, never key reordering.

## Reading a record

`iris --perf report <run.json>` renders the Markdown summary. Per scenario: a row per rung with
median and p90 wall-clock, median prompt tokens, median cache read tokens, median cache write
tokens, and median uncached tokens (prompt minus cache read minus cache write; an unknown cache
read counts the whole prompt as uncached), the two ratios, the top five named spans
(`guard.tier3`, `vibecop`, `assembly.userProfile`, ...), and the tool-call rate with a histogram, and, for prompts that declare `expectedTools`, the
**unexpected tool-call rate**: turns that called any tool outside that list (bait prompts declare
`[]`, controls declare their one tool, so an extra `read_file` next to a `set_workspace` counts).

For a multi-turn scenario (only `caching` today), the report also carries a per-round cache table
— turn, round, prompt, cache read, cache write, uncached — built from the top rung's first
repetition only; a table per repetition would be noise; the rung table's medians already cover
that.

`first token ms` is the median time from request start to the first streamed token for rungs that
streamed (4 and 5 when the streaming setting is on); it is `-` for the bare-call rungs and for
fake-lane runs, whose clients replay whole responses. The header line `streaming:` records the
setting; compare does not refuse across it because total wall time is comparable either way.

Two things to keep in mind when reading those numbers with streaming on. `primaryLLM` no longer
spans just a request and a response: it covers the whole consume loop, so it includes the
streamer's MainActor hops for every UI write the answer produced. A long answer therefore books a
little engine time under the model's name, and `primaryLLM` minus provider latency is not idle
time. And `firstTokenMs` and `latencyMs` are measured over different windows: `firstTokenMs` runs
from the start of the *last* attempt (a retried call's first token is timed from the attempt that
succeeded), while `latencyMs` spans every attempt and the backoff waits between them. On a call
that retried, `firstTokenMs` can be a small fraction of `latencyMs` without either being wrong.

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
