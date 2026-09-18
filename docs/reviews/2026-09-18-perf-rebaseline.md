# Perf Re-baseline After the First Round of Fixes

* **Records**: `perf/baselines/*-2026-09-18-*` (ladder, tool-eagerness, tool-eagerness-2, smoke)
* **Provider / models**: unchanged from 2026-09-17 (Gemini via ADC, medium `gemini-3.8-flash`; Vibecop `cloud`, prompt guard `cloud`)
* **What changed since the first baseline**: #130 (tier-3 verdict cache), #131 (180 s timeout, transport retry), #132 (`rename_conversation` only on its trigger), #133 slice 1 (12 dead-weight declarations gone), #135 (Vibecop measured under headless auto-approve), #136 (parts-less candidates decode), and this branch: real-lane tool prompts run in the sandbox, tool arguments recorded, unexpected/missed tool scoring, ladder at 5 repetitions
* **Previous analysis**: `docs/reviews/2026-09-17-tool-eagerness-analysis.md`

## Why these baselines replace the 2026-09-17 ones rather than compare to them

Two measurement conditions changed on purpose, and `compare` refuses across both:

- Real-lane tool prompts now execute in the sandbox VM (`toolSandbox: sandboxed`). A VM `run_command` is not like-for-like with a host one, and the earlier records predate the field.
- Vibecop is now inside rung 5 (#135); before, it was bypassed by headless auto-approve.

So the 2026-09-17 records stay as the "before" for the fixes above, and these are the reference for
everything after.

## Ladder

Medians in ms over 5 repetitions; the ladder ran unattended under the sandboxed configuration
(`perf/baselines/20260918T040234Z-ladder-43ed273.json`). Rung 1 is a bare provider call; rung 5 is
a full Iris turn with guards and Vibecop as configured.

| scenario | rung 1 | rung 2 | rung 3 | rung 4 | rung 5 | overhead | harness |
|---|---|---|---|---|---|---|---|
| capital-city (model-only) | 3391 | 2855 | 2741 | 2608 | 2711 | 0.80x | 0.77x |
| explain-concept (model-only) | 5686 | 4537 | 3951 | 4227 | 4792 | 0.84x | 0.74x |
| short-writing (model-only) | 4234 | 3206 | 1898 | 2292 | 2763 | 0.65x | 0.54x |
| run-uname (tool-use, sandboxed) | 3531 | 2902 | 1753 | 4934 | 6166 | 1.75x | 1.40x |
| count-files (tool-use, sandboxed) | 14142 | 3275 | 2566 | 4573 | 5705 | 0.40x | 0.32x |

Against the 2026-09-17 ladder (same prompts, host tools, 3 repetitions):

| what | 2026-09-17 | now |
|---|---|---|
| tool declarations per call | 30 | 17 |
| prompt tokens at rung 3 | about 5,110 | about 3,930 |
| failed repetitions | 9 of 75 | 0 of 125 |
| tool calls per tool turn | 1 (plus the 32-command storm in the eagerness run) | exactly 1, every turn |
| model-only overhead ratio | 0.93x to 2.43x | 0.65x to 0.84x |

Ratios below 1.0 mean the full Iris turn came back faster than the bare call with the same prompt.
That is not Iris being faster than the model; it is the model answering a 4,000-token request with
tools and a system prompt more tersely than a 20-token bare prompt, and it is why the ratio is a
regression yardstick rather than a statement about cost. The numbers that describe cost are the
spans and the token counts.

### Where the time goes now

Per full turn at rung 5, from the recorded spans:

| span | model-only turns | tool turns | note |
|---|---|---|---|
| `assembly.userProfile` + `guard.tier3` | 0.2 ms after the first turn | same | #130: the static context is sanitized once per process; the first `capital-city` repetition still paid 1.6 s (including the 0.6 s CoreML cold load) |
| `vibecop` | not consulted | 670 to 720 ms | #135: now measured; one cloud call per `run_command` |
| `guard.tier3` on tool output | none | about 100 ms | the tool result is fresh content each turn, so it is evaluated, but the 200-byte output is quick |
| `assembly.systemPrompt`, `assembly.factSearch` | 1 to 2 ms | same | |
| sandbox `run_command` (VM) | none | rung 5 minus rung 4 is 1.1 to 1.2 s per tool turn | VM start plus Vibecop; the VM is torn down after each run |

So the deterministic harness cost on a model-only turn is now single-digit milliseconds after the
first turn of a process, and a tool turn costs about 0.7 s of Vibecop plus the sandbox round trip.
Everything else in the wall-clock columns is the provider: same-prompt rounds still range 1.9 s to
5.7 s at the median with p90s of 5 to 8 s, and rung 1 for `count-files` shows a bare call
generating for 14 s.

## Eagerness, first set (the prompts the 2026-09-17 run used)

Rung 5, two repetitions each. Before: 2 unprompted tool calls in 21 model-only turns, both
`rename_conversation` on a first message.

| prompt | unexpected tool calls |
|---|---|
| capital-city, explain-concept, advice, short-writing, conversation-meta, quick-reasoning | none in any turn |
| run-uname (control) | none; `run_command` once per turn |

**Zero unprompted calls in 12 model-only turns.** #132 removed the only one this set could produce.

## Eagerness, second set (`tool-eagerness-2`, first measured in PR #148)

| prompt | before (PR #148 run) | now |
|---|---|---|
| mentions-directory | `set_workspace` 2/2 | `set_workspace` 2/2, plus one `read_file` |
| personal-fact | `save_fact` 1/2 | none |
| remember-instruction | `update_user_profile` 1/2 | none |
| hypothetical-schedule, describe-process, watch-out | none | none |

Bait rate 2 of 12 turns (17 %), down from 4 of 12. Everything left is `set_workspace` on a
directory mention, whose description ("Do this when the user says they are working in a specific
project or directory") is satisfied literally by the bait sentence. That is the target for #133
slice 2.

Controls, with the two new scores:

| control | expected | now |
|---|---|---|
| remember-editor | `update_user_profile` or `save_fact` | **missed 2/2**: no tool at all |
| schedule-reminder | `schedule_job` | **missed 2/2**; instead `run_command` x3 and `search_memory` x2, 32 s median |
| bind-workspace | `set_workspace` | hit 2/2, plus an unrequested `read_file` both times |

The control set exposes the other half of the tool problem: under-calling and detours. Two of
three controls never reached the tool they exist to exercise. This is not something the tool-surface
trim caused (the prompts are new), but it is now measured, and the memory and scheduling tools'
descriptions are the place to look.

## Harness changes verified by this run

- **Sandboxed tool execution is real.** `iris-*` Ubuntu VMs appeared during tool-use scenarios;
  the record says `toolSandbox: sandboxed`. The first pass also showed that every repetition left
  its VM running (18 at one point, 1 GB each) because the CLI process has no idle reaper; the
  runner now ends the conversation's sandbox session after its turns, and the ladder re-run held
  at zero leaked VMs.
- **A sandbox-hostile prompt is a tool storm.** The old `count-files` prompt asked about
  `Sources/iris`, which does not exist in the VM; the model hunted for it with 60 `run_command`
  calls over five turns (50 s median, 143 s p90; 148 s median in the eagerness suite). The prompt
  now counts `/usr/bin`, which exists in both worlds and needs exactly one command. Tool
  arguments are in the record, so the next storm is readable.
- **A rebuilt binary blocks an unattended run on a Keychain dialog.** The first ladder re-run sat
  50 minutes at its first `ConfigManager.shared` touch, in `SecItemCopyMatching`, without making a
  call: the Keychain ACL is per binary identity and every rebuild re-prompts. Real-lane runs on
  Gemini over ADC now skip the Keychain (the token comes from gcloud); the second re-run started
  unattended and finished in 14 minutes. API-key configurations still prompt once per rebuild;
  `perf/README.md` says what to do.
- **The ladder at 5 repetitions** is still noisy in wall-clock terms (see the p90 columns), but
  the span-based numbers are stable, and rung 5 now includes Vibecop.

## Not measured here

- Streaming and time-to-first-token (no client streams yet; the #131 timeout slice landed, the
  streaming half has not).
- The tool-surface after #133 slice 2 (not started).
