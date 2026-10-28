# Model evaluation framework (spec)

Status: **decisions answered by Brian on 2026-10-28 (§10). Waiting on spec review, then Brian's approval to build.**
Planner: iris-planner, 2026-10-28.

## What and why

Brian, 2026-10-28: "let's plan for a consistent eval framework that can assess models at different tiers to compare 1. efficacy/accuracy, 2. cost/latency, 3. size, 4. .... Such that it's repeatable over time and we can re-evaluate new models with an apples/apples comparison".

Why now:
- The July tier-2 survey ranked DeBERTa v3 best on 19 hand-picked samples. #770 re-tested it on 276, through the product's path, and found about 31% benign false positives and 67% recall. That went unnoticed for three months because nothing re-ran the survey, and its method lived only in a doc's prose.
- Three harnesses are about to be built separately:
  - #770's fixtures and opt-in test;
  - #780's search for a better tier 2;
  - #783's tier-3 verdict baseline.

  This spec makes them one harness, so a number from October and a number from March mean the same thing.

## 1. Principles

- **One harness, many tasks.** A *task* is one job a model does in Iris, with its own labelled dataset and its own accuracy metrics. Models compete only within a task.
- **Score the product, not just the model.** Every accuracy number is taken through the code path Iris runs (windows, thresholds, narrowing, prompts, parsing), as #770 did. A raw model score is reported beside it, never instead of it.
- **Nothing is compared unless it's pinned.** That covers the dataset version, model identity, runtime, hardware, OS, Iris commit and settings. A result missing any of them can't be compared.
- **Headless and free by default.** Local runs need no paid calls and no GUI. Paid cloud runs are opt-in and need explicit configuration.
- **Results are files in the repo.** They're machine-readable, diffable and regenerable, and the docs table is generated from them, never hand-edited.

## 2. Tasks

| Task | What is judged | Who competes | Label | Accuracy metrics |
|---|---|---|---|---|
| `injection.classifier` | one text → injection probability | tier-2 classifiers (ONNX, CoreML) | benign / attack, plus the attack's payload | **at the product threshold:** benign false-positive rate (anything withheld) and attack recall (payload withheld or text blocked), each per category. **Threshold-free:** ROC-AUC on one raw score per text, the **maximum over its windows**, which is the score that first flags a text in the product. |
| `injection.verdict` | one text → SAFE / MALICIOUS | tier-3 canaries (llama.cpp, MLX, Ollama, cloud) | the same dataset | the same, plus **parse failures**: no verdict means fail-closed, counted apart. **Agreement** across N repeats. |
| `injection.stack` | one text → what reaches the main model | the guard stack as configured: tier 1 + 2 + 3 | the same dataset | the same, end to end: what Iris as a whole catches and wrongly withholds |
| `approval.vibecop` (later, §10 Q1) | one command plus its context → approve / ask | Vibecop engines and models | safe-to-run-silently / must-ask | **wrong-approve rate** on must-ask, which must be ~0 (it's the security number), and **approve rate** on safe, which is the prompts-saved number Brian cares about |

The three `injection.*` tasks share one dataset, so the classifier, the canary and the whole stack are scored on identical texts. Tier 1 isn't a task of its own: it's deterministic code with unit tests, and its contribution shows up as `injection.stack` minus the tiers above it. Main-agent models (task success at coding or research) are out of scope.

**What's comparable across tasks:** cost, latency, size, memory, licence and runtime. Accuracy isn't, because a 2% false-positive rate means different things for a classifier and an approval engine. The one honest cross-tier accuracy view is `injection.stack`, comparing configurations: "tier 1 + tier 3 alone" against "tier 1 + 2 + 3". That's #780's retire-tier-2 question.

## 3. Datasets

```
eval/datasets/<task-family>/v<N>/
  manifest.json         # version, created, sha256 of each file, counts per split and category, generator commit
  benign.jsonl          # {id, category, source, split, text}
  attacks.jsonl         # {id, category, source, split, text, payload}
  README.md             # sources, licences, scrubbing, what changed from v<N-1>
```

- **v1 for `injection` is #770's fixtures as they are:** 201 benign and 75 attacks, the same ids, with a `split` field added.
- **Versioned and immutable.** A change makes `v<N+1>`, and a result names the version and its sha256. Old versions stay, so an old result can be reproduced.
- **Splits.**
  - `test` (about 70%) is frozen and never used to choose a threshold, prompt or fine-tune.
  - `dev` (about 30%) is for tuning.
  - The split is **stratified by category**, and the manifest states each category's count in each split. At v1's size, some attack categories have only a handful of `test` texts, so **bars apply to the aggregate over `test`**. Per-category numbers are reported and marked "small n" below 10, but they aren't barred.
  - #780's fine-tune option may train only on `dev` and on data outside the dataset. A model or setting tuned on `test` is marked `contaminated` and can't be compared.
  - **Choices made before the split are contaminated too.** #770 measured DeBERTa on all 276 texts. So tier 2's current threshold and narrowing settings, and anything #780 shortlists with #770's full-set numbers in view, have seen v1's `test`. Results that depend on them carry `contaminated: pre-split`. Before #780 decides anything, v2 adds a fresh set of `test` attacks, never scored during tuning: 24 from InjecAgent, with each text marked `exposure: pre-split` or `clean`, so a result says how many of its texts were exposed (`eval/datasets/injection/v2/`).
- **Adversarial variants** (`attacks.adversarial`): deterministic transforms of the attack set, using a fixed seed in the generator:
  - case and whitespace changes;
  - Unicode look-alikes;
  - splitting the instruction across lines;
  - paraphrase without trigger words;
  - burying it deeper in benign text.

  They're reported as their own category, so robustness is visible rather than averaged away.
- **A known weakness, stated:** every v1 attack was written by this project, so a model tuned to our authors' phrasing would look better than it is. v2 adds 24 attacks from InjecAgent (MIT) as their own category, `subtle_plain`, plus 10 benign look-alikes built on its templates; they are plain requests planted in tool output, not disguised ones, and harder cases are #802.
- **Real traffic:** none for now (§10 Q2). The datasets hold synthetic and repository content only, apart from v2's InjecAgent rows (Brian, 2026-10-28, for that slice only). This can be revisited once Iris is used for work; a private local split would be the shape then.
- **`approval.vibecop`** needs its own dataset: commands with cwd, the workspace shape and the conversation's recent denials, labelled safe-to-run-silently or must-ask. Seed it from the refusal tables of `ReadOnlyCommand` and the #600 cases. Deferred (§10 Q1).

## 4. Model identity and environment (recorded with every result)

- **Model:**
  - name and source URL or repo;
  - the **fingerprint**: sha256 of the local model file(s), or the Ollama manifest digest from `/api/tags`, or the cloud provider's model id plus the run date;
  - quantisation;
  - parameter count, if known;
  - licence and gating (open, gated, commercial).
- **Runtime:** ONNX Runtime, CoreML, llama.cpp, MLX, Ollama, or cloud provider plus model id. Record its version: the ORT version, `ollama --version`, or the cloud model id with the run date (cloud models change under one name).
- **Settings:** the **temperature and sampling the product actually uses**, recorded rather than overridden; the eval runs the canary as Iris runs it. Today:
  - Ollama and MLX use the model's defaults, since no engine sets a temperature;
  - llama.cpp uses argmax.

  A temperature of 0 would be a product change, measured with `compare` like any other lever, not an eval setting. Also recorded: the prompt template's sha256 for LLM tasks, hashed with the per-call random tag (`executeTier3Canary`'s UUID prefix) as a placeholder; the threshold and window settings for classifiers; and max tokens. The per-call tag means no two rendered prompts are identical, which is part of the run-to-run variance §5 measures.
- **Environment:**
  - chip and RAM (`sysctl hw.model`, `hw.memsize`);
  - macOS version;
  - power state (`pmset -g batt`; a run on battery is flagged);
  - the Iris commit and its dirty flag.
- **Dataset:** task family, version, sha256, split and sample mode.

## 5. Metrics beyond accuracy (Brian's "2. cost/latency, 3. size, 4. …")

| Metric | How |
|---|---|
| **Warm latency** | p50 / p95 per judgement, after the model is loaded, by input size band (≤1 KB, ≤8 KB, ≤32 KB) |
| **Cold start** | Process start → first verdict. Load time is separate, from #782's `ModelLoadTracker`. For Ollama, `load_duration`, plus a run after `ollama stop`. |
| **Size** | on-disk bytes, plus resident memory added (`phys_footprint` before and after load, after judging; the #725 probe method) |
| **Cost** | local: $0, with energy not measured. Cloud: tokens × price from #239's price list, reported per 1,000 judgements of the dataset's median text |
| **Variance** | LLM tasks: N repeats (default 3), with the verdict agreement rate and the latency spread. Classifiers are deterministic on ONNX Runtime's CPU path, so their run-to-run check is a hash of all scores **rounded to 4 decimal places**. CoreML on the GPU or Neural Engine can differ in the last bits between runs and machines. |
| **Fail-closed rate** | errors, timeouts and parse failures that make the product block, counted apart from real verdicts |
| **Licence / gating / platforms** | recorded fields, so "it passed but we can't ship it" is visible in the table |
| **Pass / fail** | against a per-task accuracy bar (§10 Q3), shown as a column. The verdict is the bar's, not the reader's. |

## 6. Running it

- **`iris --eval run <task> --model <spec> [--sample N | --full] [--split test|dev] [--repeats N] [--out DIR]`**
  - It's dev builds only, read-only, with no store, conversation or home lock, which is #782's `--guard-probe` pattern.
  - `--model` takes the runtime and model as config (`ollama:gemma4:12b`, `onnx:<path>`, `cloud:<provider>/<model>`), so the same command runs against a cloud model when it's configured that way. The runtime prefix is split on the **first colon only**, because Ollama names contain colons (`gemma4:12b-32k`). The runner never reads the home's settings by default: the model is always explicit config, so a run can't silently score whatever the home happens to be set to.
- **Model-change flag (§10 Q4).** Before scoring, `run` looks up the last committed result for the same task and model name. If the fingerprint differs, it prints `MODEL CHANGED: <old> → <new>` and records `model_changed: true` with both digests. This catches a silent change, such as an Ollama re-pull of `gemma4:12b`. A changed model is a new model for comparison purposes.
- **`iris --eval compare <a.json> <b.json>`** prints the per-metric and per-category differences, and flags any attack that flipped from caught to missed. This is modelled on `iris --perf compare`.
- **`iris --eval table`** regenerates `docs/evals.md` from every result file.
- **Sample vs full:**
  - `--sample N` takes a fixed, seeded, stratified sample: the same N texts every time, so two sampled runs compare. The default N is 60.
  - `--full` takes the whole split.
  - A local 12B canary takes about 5 s per text (#778), so the full `injection` set is about 25 min per repeat. Sample by default for LLMs, and go full before a decision.
- **Results:** `eval/results/<task>/<YYYY-MM-DD>-<model-slug>-<dataset-version>.json`, committed, with schema-versioned JSON. The per-text verdicts are included, so a later run can diff text by text.
- **Paid runs:** a cloud model is never used unless `--model cloud:…` names it and its provider credentials are configured. The run says up front that it will make paid calls, and its results file records `paid: true` along with the token totals.
- **Opt-in tests:** #770's `IRIS_ONNX_TEST_BUNDLE` tests become thin wrappers that call the runner on the sampled set. CI still skips them.

## 7. Where existing work goes

- **#770 lands as it is.** Don't stall it. Slice 1 then moves its fixtures to `eval/datasets/injection/v1/` unchanged, with the same ids, plus the `split` field. Its test becomes a wrapper, and its docs table becomes the first generated row.
- **#783 phase 1 runs now**, measuring tokens, calls per turn and latency with `--guard-probe`. **Phase 2 doesn't wait for slice 1**, because the 5-second floor is what Brian feels. As an interim, #783 may add a tier-3 mode to #770's opt-in fixture test (the same fixtures and the same file, not a new harness) for its baseline and lever verdicts, with `--guard-probe` for latency. Slice 1 then migrates that mode and reruns #783's chosen lever through `compare` as a follow-up.
- **#780 stays parked** until slice 1 lands. Every candidate is then one `run` plus one `compare`.
- **#782's** `ModelLoadTracker` and `--guard-probe` are reused for load time and cold start.

## 8. Slices (each its own PR; a dev builds and a different dev reviews)

1. **Runner, classifier and verdict tasks.**
   - `iris --eval run/compare/table`;
   - the `injection` dataset v1 (migrated from #770), with splits;
   - `injection.classifier` (ONNX, CoreML) and `injection.verdict` (Ollama, llama.cpp, MLX), local only;
   - the results schema, the identity and environment capture, and `docs/evals.md`.

   This is the slice that unblocks #783 phase 2 and #780.
2. **Stack, adversarial variants and the frozen test split.** `injection.stack` (tier 1+2+3 as configured, plus named configurations), the adversarial generator, and contamination marking.
3. **Cloud models and cost.** The `cloud:` model spec and cost from #239's price list. Its first paid run is recorded like any other.
4. **`approval.vibecop`**, later (§10 Q1): its dataset and task.

## 9. Rules for honest comparison

These hold across every task. Most are adapted from the eval design of [kube-agents](https://github.com/gke-labs/kube-agents), an open-source agent project (Apache-2.0) whose benchmark harness has run since mid-2026 (`docs/designs/eval-scorer.md` and `bench/` there, read at `adc39ad4`).

- **A version key on every result.** It joins the dataset version and sha256, the model identity, the runtime and its version, and a hand-bumped `scoring_version` integer. Bump `scoring_version` whenever a metric's meaning changes (a threshold rule, the definition of "caught"), and not for a cosmetic change to the scorer. `compare` refuses to compare results whose keys differ, unless it's told which part is meant to differ (the model, for a model comparison).
- **Append-only results.** A run adds a file and never rewrites or deletes one. A wrong result is superseded by a later file that names it, not edited. `compare` can't see this, since it reads only two files, so slice 1 adds a CI check in the style of `scripts/ci-changes.sh` that fails a PR modifying or deleting any existing file under `eval/results/`.
- **Absent, never zero.** A metric that wasn't measured (memory on a cloud model, cold start in a sampled run) is recorded as missing, and the table shows "n/a". It is never 0.
- **Deterministic labels decide.** Every accuracy number comes from the dataset's labels (payload withheld or not, verdict parsed), never from a model grading another model.
- **Margins sized to noise.** For LLM tasks:
  - **Unstable texts.** A text whose verdict differs across a result's own repeats is `unstable`. `compare` lists unstable texts separately and leaves them out of the caught/missed flips.
  - **When a difference counts.** `compare` reports an aggregate difference as real only if it moves by at least 2 stable texts **and** by more than twice the larger of the two results' repeat spreads. It prints that rule with its verdict.

  The docs say plainly that 3 repeats catch a collapse, not a slow drift.
- **Infra failures are not product failures.** An engine that's down, or a runner error, invalidates that text's result and is counted as `infra`. A timeout or parse failure that the product would treat as a block is counted as `fail-closed`, because that's what a person would see.
- **Watch the margin, not just the bar.** The table keeps each model's separation (ROC-AUC, and the gap between the highest benign and lowest attack score) over time, so a model that still passes while getting worse is visible before it fails.
- **A fix comes with a case.** A guard change that fixes a missed attack or a false positive adds that text to the next dataset version, so the fix stays tested. That can't be checked by machine, so it's a line in the PR template's checklist, held to at review.

### What we take from kube-agents, and what we don't

**Taken as ideas.** These are re-implemented in Swift for Iris's tasks; no code is copied.
- the version key on every result;
- an append-only results store;
- "absent, never zero";
- deterministic checks decide, while their LLM judge stays advisory (Iris needs no judge at all);
- margins sized to measured judge noise, with the plain statement that 3 repeats catch a collapse, not a drift;
- infra repetitions kept out of the rates;
- the "drift under green" view: cases that still pass while their score slides;
- "a behaviour change comes with a red-to-green case".

**Not taken, and why.**
- **Pull-request gating, a nightly CI run and a blocking roster.** Iris's CI has no local models, and a full local run takes about 25 minutes. Runs are by hand (§10 Q4).
- **A cloud evidence store (create-only bucket, BigQuery views, dashboard, digest email).** Committed result files and a generated docs table are enough here.
- **An LLM judge.** Iris's labels are deterministic.
- **Case admission (at least 20 runs at a pass rate of 0.90 or more).** That exists to arm a gate, and Iris has no gate.
- **Planted infrastructure fixtures, owner aliases and rosters.** That's team-scale process.

**Licence.** kube-agents is Apache-2.0 (its `LICENSE`; it has no `NOTICE` file). This spec copies nothing verbatim. If a later slice does copy a file or a substantial passage, for example its scoring ladder or dashboard SQL as a starting point, that file keeps the Apache-2.0 licence header, says what was changed, and names its source. Apache-2.0 allows that inside Iris.

## 10. Decisions (Brian, 2026-10-28, via the Overseer)

- **Q1, scope: (a).** The prompt-injection tasks only: `injection.classifier`, `.verdict` and `.stack`. `approval.vibecop` comes later (slice 4, not scheduled). Main-agent models are out of scope.
- **Q2, real traffic: (c).** Synthetic and repository content only, with no real-traffic split for now. Brian: "I'm going to choose (3) just because I don't actually use iris for work yet." Revisit once he does.
- **Q3, bars: (a).** Accuracy bars only: for the injection tasks, a benign false-positive rate of 2% or less and attack recall of 80% or more on `test`. Vibecop's bars are set when that task is added. Latency, memory and size are reported, not graded.
- **Q4, cadence: (a) plus a model fingerprint.** Runs are by hand, whenever a model, prompt or guard setting changes and before any default changes. Every run records the model's exact fingerprint, and `run` flags any difference from the last committed result for that model (§6).

## Options as put to Brian (kept for the record)


**Q1. Which tasks are in scope?**
- **(a) Prompt-injection tasks only for now** (tier 2, tier 3 and the whole stack); Vibecop later (recommended). This answers #770, #780 and #783 directly.
- **(b) Also Vibecop's approve/ask from the start.** Slice 4 moves up. It needs a new labelled command dataset, and its error is a security error, so it gets a security review.
- **(c) Also the main-agent models** (coding and research task success). That's a different, much larger eval. Not recommended here.

**Q2. Real traffic in datasets?**
- **(a) Never committed** (recommended).
  - Optionally, a local-only private split under `~/.iris-dev/eval/private/`, built from texts you choose to export, scrubbed.
  - Only aggregate numbers from it are committed, marked `private split`.
  - Public results stay reproducible from committed data alone.
- **(b) Committed after scrubbing.** It's more realistic and reproducible by anyone, but your tool output (paths, code, docs) becomes public in the repo.
- **(c) Synthetic and repo content only.** It's the simplest, but #770 already showed synthetic sets miss what real traffic does.

**Q3. Pass bars per task** (proposed; adjust any):
- **(a) Accept these** (recommended):
  - `injection.classifier`, `.verdict` and `.stack`: benign false-positive rate ≤ 2% and attack recall ≥ 80% on `test`, plus adversarial recall reported, with no bar yet.
  - `approval.vibecop`: wrong-approve ≤ 0.5% on must-ask, approve ≥ 50% on safe.
  - Latency and memory are reported, not barred.
- **(b) Set latency or memory bars too**, e.g. a tier-3 p50 ≤ 1.5 s warm and a tier-2 resident memory ≤ 500 MB. A fast-but-wrong model then can't pass on accuracy alone, and a slow-but-right one can't pass either.
- **(c) No bars.** Numbers only, judged case by case.

**Q4. When does it run?**
- **(a) By hand**, whenever a model, prompt or guard setting changes, and before any default changes (recommended).
- **(b) Also on a schedule:** a monthly Iris script job (#330) runs the sampled local set and posts a diff against the last committed result. Cheap, but it's another job to keep alive, and a drift it finds still needs a person.
