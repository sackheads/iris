# Model evaluation framework (spec)

Status: **draft, waiting on Brian's decisions (§9).** Nothing is built until he approves.
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
- **Headless and free by default.** Local runs need no paid calls and no GUI. Paid cloud runs are opt-in and go to the work laptop.
- **Results are files in the repo.** They're machine-readable, diffable and regenerable, and the docs table is generated from them, never hand-edited.

## 2. Tasks

| Task | What is judged | Who competes | Label | Accuracy metrics |
|---|---|---|---|---|
| `injection.classifier` | one text → injection probability | tier-2 classifiers (ONNX, CoreML) | benign / attack, plus the attack's payload | **at the product threshold:** benign false-positive rate (anything withheld) and attack recall (payload withheld or text blocked), each per category. **Threshold-free:** ROC-AUC on the raw score. |
| `injection.verdict` | one text → SAFE / MALICIOUS | tier-3 canaries (llama.cpp, MLX, Ollama, cloud) | the same dataset | the same, plus **parse failures**: no verdict means fail-closed, counted apart. **Agreement** across N repeats. |
| `injection.stack` | one text → what reaches the main model | the guard stack as configured: tier 1 + 2 + 3 | the same dataset | the same, end to end: what Iris as a whole catches and wrongly withholds |
| `approval.vibecop` (§9 Q1) | one command plus its context → approve / ask | Vibecop engines and models | safe-to-run-silently / must-ask | **wrong-approve rate** on must-ask, which must be ~0 (it's the security number), and **approve rate** on safe, which is the prompts-saved number Brian cares about |

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
  - #780's fine-tune option may train only on `dev` and on data outside the dataset. A model or setting tuned on `test` is marked `contaminated` and can't be compared.
- **Adversarial variants** (`attacks.adversarial`): deterministic transforms of the attack set, using a fixed seed in the generator:
  - case and whitespace changes;
  - Unicode look-alikes;
  - splitting the instruction across lines;
  - paraphrase without trigger words;
  - burying it deeper in benign text.

  They're reported as their own category, so robustness is visible rather than averaged away.
- **A known weakness, stated:** every v1 attack was written by this project, so a model tuned to our authors' phrasing would look better than it is. A public labelled injection set may be added as a separate category if its licence allows. That is a slice-2 call, not a question for Brian.
- **Real traffic:** §9 Q2.
- **`approval.vibecop`** needs its own dataset: commands with cwd, the workspace shape and the conversation's recent denials, labelled safe-to-run-silently or must-ask. Seed it from the refusal tables of `ReadOnlyCommand` and the #600 cases. Built only if Q1 says so.

## 4. Model identity and environment (recorded with every result)

- **Model:**
  - name and source URL or repo;
  - sha256 of the local file, or the Ollama digest from `/api/tags`;
  - quantisation;
  - parameter count, if known;
  - licence and gating (open, gated, commercial).
- **Runtime:** ONNX Runtime, CoreML, llama.cpp, MLX, Ollama, or cloud provider plus model id. Record its version: the ORT version, `ollama --version`, or the cloud model id with the run date (cloud models change under one name).
- **Settings:** temperature (0 wherever the runtime allows), the prompt template's sha256 for LLM tasks, the threshold and window settings for classifiers, max tokens.
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
| **Variance** | LLM tasks: N repeats (default 3), with the verdict agreement rate and the latency spread. Classifiers are deterministic, so their run-to-run check is a hash of all scores. |
| **Fail-closed rate** | errors, timeouts and parse failures that make the product block, counted apart from real verdicts |
| **Licence / gating / platforms** | recorded fields, so "it passed but we can't ship it" is visible in the table |
| **Pass / fail** | against a per-task bar (§9 Q3), shown as a column. The verdict is the bar's, not the reader's. |

## 6. Running it

- **`iris --eval run <task> --model <spec> [--sample N | --full] [--split test|dev] [--repeats N] [--out DIR]`**
  - It's dev builds only, read-only, with no store, conversation or home lock, which is #782's `--guard-probe` pattern.
  - `--model` takes the runtime and model as config (`ollama:gemma4:12b`, `onnx:<path>`, `cloud:<provider>/<model>`), so the same command runs on the work laptop with a cloud model.
- **`iris --eval compare <a.json> <b.json>`** prints the per-metric and per-category differences, and flags any attack that flipped from caught to missed. This is modelled on `iris --perf compare`.
- **`iris --eval table`** regenerates `docs/evals.md` from every result file.
- **Sample vs full:**
  - `--sample N` takes a fixed, seeded, stratified sample: the same N texts every time, so two sampled runs compare. The default N is 60.
  - `--full` takes the whole split.
  - A local 12B canary takes about 5 s per text (#778), so the full `injection` set is about 25 min per repeat. Sample by default for LLMs, and go full before a decision.
- **Results:** `eval/results/<task>/<YYYY-MM-DD>-<model-slug>-<dataset-version>.json`, committed, with schema-versioned JSON. The per-text verdicts are included, so a later run can diff text by text.
- **Paid runs:** cloud-model runs go to the work laptop through the planner, as the house rule says. The results file records it as `paid: true`.
- **Opt-in tests:** #770's `IRIS_ONNX_TEST_BUNDLE` tests become thin wrappers that call the runner on the sampled set. CI still skips them.

## 7. Where existing work goes

- **#770 lands as it is.** Don't stall it. Slice 1 then moves its fixtures to `eval/datasets/injection/v1/` unchanged, with the same ids, plus the `split` field. Its test becomes a wrapper, and its docs table becomes the first generated row.
- **#783 phase 1 runs now**, measuring tokens, calls per turn and latency with `--guard-probe`. Its **tier-3 verdict baseline waits for slice 1**: it would otherwise be a second, throwaway accuracy harness. Phase 2's levers are then each an `iris --eval compare` against that baseline.
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
3. **Cloud models and cost.** The `cloud:` model spec and cost from #239's price list. First paid run on work.
4. **`approval.vibecop`**, if Q1 includes it: its dataset and task.

## 9. Decisions for Brian (rule 11, via the Overseer)

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
