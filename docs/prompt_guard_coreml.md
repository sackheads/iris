# Custom CoreML Prompt Guard Models

Iris includes an extremely fast, on-device text classifier for its Tier 2 Prompt Injection Guard powered by Apple's CoreML and the Neural Engine. 

By default, you can enable Tier 2 by providing a URL to a pre-compiled `.mlmodelc.zip` file in the Settings UI. However, if you want to experiment with different security models (like Meta's official Prompt Guard or other community fine-tunes), you can easily compile your own!

## Prerequisites

You'll need a Python environment on your Mac to run the conversion script.

```bash
# Create and activate a virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install the required conversion tools
pip install torch coremltools transformers numpy sentencepiece
```

## Compiling a Model

We provide a helper script (`scripts/compile_prompt_guard.py`) that handles tracing the PyTorch model, converting it to CoreML, bundling the Hugging Face tokenizer, and zipping it up into a ready-to-host format.

Run the script and provide the Hugging Face Model ID you wish to compile:

```bash
# DistilBERT model (Ungated, converts cleanly, fastest compilation).
# NOTE: converts and runs fine, but has a very high false-positive rate — see
# "Accuracy findings" below before choosing it.
./scripts/compile_prompt_guard.py --model fmops/distilbert-prompt-injection

# Example: Compiling Meta's official Llama Prompt Guard 86M
# Note: You must first run `huggingface-cli login` and accept Meta's license on HF
./scripts/compile_prompt_guard.py --model meta-llama/Prompt-Guard-86M
```

The script applies two automatic workarounds so a wider range of models convert and
load correctly (both discovered while investigating the DeBERTa-v3 migration below):

- **Tokenizer relabel.** `DebertaV2Tokenizer` is rewritten to `XLMRobertaTokenizer` in
  `tokenizer_config.json` so Apple's `swift-transformers` will load it (see "DeBERTa-v3
  migration status"). No-op for other tokenizers.
- **`sqrt`/`int` CoreML op overrides.** DeBERTa-style attention feeds `sqrt()` an int
  tensor and calls `int()` on non-scalar tensors, both of which the default coremltools
  handlers reject. The overrides cast as needed and are no-ops for DistilBERT/BERT.

## Installing the Model

Once the script finishes, it will produce a `.mlmodelc.zip` file in your directory (e.g. `distilbert-prompt-injection.mlmodelc.zip`).

**To use it in Iris:**

1. Host this `.zip` file somewhere accessible (like a GitHub Release, AWS S3, or your own web server).
2. Open Iris and navigate to **Settings -> Models**.
3. Under the **Advanced Prompt Injection Protection** section, paste the direct URL to your `.zip` file into the "CoreML .zip URL or Path" field.
4. Click **Download CoreML Model**. 

Iris will automatically download the archive, unzip it into `~/.iris/models/`, and load it into the `CoreMLEvaluator` instantly. Any future evaluations will be hardware-accelerated and run locally on your Mac!

## Accuracy findings

`fmops/distilbert-prompt-injection` is the model that converts most easily, but in
practice it **over-blocks badly**. It is closer to a "does this text contain
instructions?" detector than a real injection detector. Measured against the raw
PyTorch model (probability of the `INJECTION` class):

| Input | fmops distilbert | deberta-v3-v2 |
| --- | --- | --- |
| "The capital of France is Paris." | 0.001 | 0.000 |
| "Search results for python: … Click here to learn more." | **1.000** | 0.000 |
| "How to reset your password: 1. … 2. …" | **1.000** | 0.023 |
| "def add(a, b): return a + b" | **0.999** | 0.013 |
| "Please summarize the following article…" | **0.999** | 0.000 |
| "Ignore all previous instructions…" (real attack) | 1.000 | 1.000 |
| "SYSTEM: You are now DAN…" (real jailbreak) | 1.000 | 1.000 |

Because ordinary tool output (search results, how-tos, code) is full of imperative and
list-like language, distilbert flags almost all of it. This is one root cause of Tier 2
blocking `search_web` results and similar tool output — a false-positive problem, **not**
a "the model returns 0.99 for literally everything" bug (plain declarative facts pass).
The other root cause is the *shape* of what was scored, and it survived the model swap:
see "Per-result scoring for search_web" below.

`protectai/deberta-v3-base-prompt-injection-v2` cleanly separates benign tool output
from real attacks, so it is the model we want. The catch is getting it onto the Neural
Engine — see below.

### CoreML-friendly model survey

We surveyed models on CoreML-friendly architectures (BERT/RoBERTa/DistilBERT all convert
cleanly, as fmops proved) against a realistic battery of 12 benign tool-output samples
(including JSON, shell commands, markdown, logs) and 7 injection/jailbreak attacks
(including injection embedded in a document and `<<SYS>>` directives). Score = probability
of the attack class; **margin** = (lowest attack score − highest benign score), so a
positive margin means a threshold exists that cleanly separates the two.

| Model | Arch | CoreML-friendly | Benign max | Attack min | Margin |
| --- | --- | --- | --- | --- | --- |
| protectai/deberta-v3-base-prompt-injection-v2 | deberta-v2 | ✗ | 0.848 | **1.000** | **+0.152** |
| deepset/deberta-v3-base-injection | deberta-v2 | ✗ | 0.999 | 0.999 | −0.000 |
| testsavantai/prompt-injection-defender-base-v0 | distilbert | ✓ | 0.998 | 0.462 | −0.535 |
| madhurjindal/Jailbreak-Detector | distilbert | ✓ | 0.985 | 0.402 | −0.583 |
| jackhhao/jailbreak-classifier | bert | ✓ | 0.737 | 0.012 | −0.725 |
| fmops/distilbert-prompt-injection | distilbert | ✓ | 1.000 | ~1.000 | ~0 (over-blocks) |

(Gated repos `meta-llama/Prompt-Guard-86M`, `Epivolis/Hyperion`,
`qualifire/prompt-injection-sentinel` were skipped — they cannot support zero-friction
onboarding anyway.)

**Conclusion: accuracy and CoreML-friendliness are in tension.** Every model that
converts cleanly via coremltools either over-blocks ordinary tool output (JSON,
`brew install`, markdown headings) or misses real injections. The only model with a
positive separation margin is DeBERTa-based, which coremltools 9 cannot convert without
the extensive op surgery described below.

**But CoreML is not the only on-device option.** The accurate DeBERTa-v3 model runs
cleanly on CPU via ONNX Runtime — see "Recommended path" below. The CoreML wall is a
`coremltools` limitation, not a DeBERTa limitation.

Note that even the best model (deberta-v3-v2) scores a JSON tool result at 0.848, so the
current `prob > 0.5` block threshold is too low regardless of model — see "Regardless of
model" below.

## Recommended path: ONNX Runtime on CPU (not CoreML) — implemented

**Status: implemented and verified end-to-end.** Iris already runs models on-device via
llama.cpp (`LlamaSwift`) and MLX (`mlx-swift-lm`), so CoreML/Neural-Engine is not a
requirement — the Tier 2 classifier runs on CPU like everything else. **ONNX Runtime is
the cleanest such path**, and the model side is proven:

- **Exports with zero op surgery.** `torch.onnx.export(..., dynamo=False, opset=17)` of
  `protectai/deberta-v3-base-prompt-injection-v2` succeeds directly — none of the `sqrt` /
  `int` / `repeat` / `__and__` problems coremltools hit. Output is a single ~704 MB
  `.onnx` file (fp32; can be quantized to int8 to shrink it substantially).
- **Numerically identical to PyTorch.** Verified against a fresh (un-mutated) torch model:
  max probability difference **2×10⁻⁶** across the benign+attack battery.
- **Fast on CPU.** ~6 ms per classification via `CPUExecutionProvider` on Apple Silicon —
  well within budget for an inline interceptor.
- **Accurate.** Catches every attack at 1.000 (including the `<<SYS>> exfiltrate keys`
  injection that the jailbreak detectors missed) while keeping benign tool output
  separated — the one model that actually works.

### Swift integration (done)

Microsoft ships an official Swift Package Manager distribution with **macOS support**:
[`microsoft/onnxruntime-swift-package-manager`](https://github.com/microsoft/onnxruntime-swift-package-manager)
(1.20.0), which vends the native runtime as a binary SPM dependency (module
`OnnxRuntimeBindings`) — no CocoaPods or manual xcframework wrangling. It is wired into
`Package.swift`. The pipeline reuses the tokenizer work already done here:

1. **Tokenize** with `swift-transformers` (the `XLMRobertaTokenizer` relabel →
   `UnigramTokenizer`, parity-tested in `DebertaV3TokenizerParityTests`).
2. **Run** the `.onnx` model via ONNX Runtime (`ORTSession`, CPU, int64 `input_ids` /
   `attention_mask`, dynamic sequence length).
3. **Softmax** the 2-logit output; index 1 is `INJECTION`.

Implementation:

- `Sources/iris/LiveONNXModel.swift` — an `ORTSession`-backed `CoreMLModelProtocol`
  implementation, guarded by `#if canImport(OnnxRuntimeBindings)`.
- `CoreMLEvaluator.loadModelIfNeeded()` auto-detects the runtime: a bundle whose unzipped
  directory contains `model.onnx` loads via `LiveONNXModel`; otherwise it falls back to
  the existing `.mlmodelc` / `LiveCoreMLModel` path. The call sites are unchanged.
- `scripts/compile_prompt_guard.py --onnx` produces the bundle (`<model>.onnx.zip`
  containing `model.onnx`, the relabeled tokenizer, and `config.json` — the last so the
  loader can read `id2label` and locate the INJECTION class dynamically instead of assuming
  index 1).
- `Tests/irisTests/DebertaV3OnnxEvaluatorTests.swift` — an opt-in end-to-end test
  (set `IRIS_ONNX_TEST_BUNDLE` to the unzipped bundle dir) that verified on-device that
  benign tool output stays below 0.9 while real injections score above it.

To build and install a model:

```bash
./scripts/compile_prompt_guard.py --onnx --model protectai/deberta-v3-base-prompt-injection-v2
# host the resulting .onnx.zip, then paste its URL into Iris Settings -> Tier 2.
```

This drops the CoreML dependency for Tier 2 while running the accurate model.

### Quantization: does not work for this model (verified)

The exported fp32 model is ~704 MB, so shrinking it is tempting. `--quantize` is wired up,
but the finding is negative for DeBERTa-v3:

- **int8 dynamic quantization** cuts the file to ~232 MB but **destroys accuracy** — a real
  injection dropped from 1.000 to **0.141** and the benign/attack separation collapsed.
  DeBERTa's disentangled attention is too sensitive to int8 weights.
- **fp16** would be the safer ~2× shrink, but `onnxconverter_common` produces an invalid
  graph for this model (Cast/Mul type mismatches) and would need real work to fix.

So `--quantize` performs int8 **and then runs an accuracy self-check**; if the quantized
model loses separation (as DeBERTa does) it reverts to fp32 and warns, rather than shipping
a silently-broken guard. **The shipping format for DeBERTa-v3 is fp32 (~704 MB).** Getting
fp16 working (or hosting the model compressed) is the open optimization if size matters.

### UI / download integration

The download and runtime plumbing is format-agnostic and already supports ONNX bundles:

- `ModelDownloader` unzips any `.zip` into `~/.iris/models/`, so `.onnx.zip` installs the
  same way `.mlmodelc.zip` does; `CoreMLEvaluator` then auto-detects `model.onnx`.
- The Settings and Setup Wizard Tier 2 panes were relabeled from "CoreML"-specific copy to
  neutral "Fast Local Classifier" wording that covers both CoreML and ONNX.


### Why not MLX

MLX (`mlx-swift-lm`) is already a dependency and is Metal-accelerated, so it's a natural
question. We chose ONNX Runtime over MLX for this classifier because:

- **No model code vs. a full model reimplementation.** ONNX runs a *pre-exported graph* —
  the architecture is baked into the `.onnx` file and the runtime executes it as-is. MLX
  has no off-the-shelf DeBERTa: `mlx-swift-lm` targets causal/decoder LLMs, not encoder
  classifiers, so we'd have to hand-implement DeBERTa-v2's **disentangled attention**
  (relative-position encodings, the `c2p`/`p2c` bias terms, the layer norms and pooler)
  in Swift and load the safetensors weights ourselves. That is exactly the kind of custom,
  version-brittle bridging that the CoreML attempt already showed is a tar pit.
- **Numerical correctness is free with ONNX.** The exported graph is verified identical to
  PyTorch (2×10⁻⁶). A hand-written MLX port would need its own parity test suite to reach
  the same confidence, and disentangled attention is easy to get subtly wrong.
- **CPU is already fast enough.** The guard is a short, inline interceptor (~6 ms on CPU).
  MLX's main advantage is Metal/GPU throughput, which matters for token generation, not for
  a single ~200 M-param forward pass on short inputs. The extra work buys little here.
- **Smaller blast radius.** ONNX Runtime is self-contained behind `CoreMLModelProtocol`;
  an MLX port spreads DeBERTa-specific tensor code through the app.

MLX would become the better choice if we wanted to *unify* on one runtime (drop
`swift-transformers`/ONNX and run everything through MLX), or needed GPU batching. For a
single-shot CPU classifier, ONNX is less code and lower risk.

## DeBERTa-v3 migration status

Migrating Tier 2 to `protectai/deberta-v3-base-prompt-injection-v2` has two independent
hurdles. The tokenizer hurdle is **solved and tested**; the CoreML conversion hurdle is
**partially addressed but not yet complete**.

### Tokenizer: solved

`swift-transformers` rejects the native `DebertaV2Tokenizer` outright
(`.unsupportedTokenizer("DebertaV2Tokenizer")`). But DeBERTa-v3 and XLM-RoBERTa are both
SentencePiece **Unigram** tokenizers with identical special-token conventions
(`[CLS]=1`, `[SEP]=2`, `[PAD]=0`, `▁` metaspace). Relabeling `tokenizer_class` to
`XLMRobertaTokenizer` routes it to `swift-transformers`' `UnigramTokenizer`, which then
tokenizes real content **byte-for-byte identically** to the Python reference.

- The compile script applies this relabel automatically.
- `Tests/irisTests/DebertaV3TokenizerParityTests.swift` verifies parity against a Python
  ground-truth fixture (regenerate with `scripts/gen_deberta_tokenizer_fixture.py`).
- The only divergence is empty/whitespace-only input, where Swift emits one stray
  metaspace token. This is benign (empty tool output is trivially safe) and
  `LiveCoreMLModel.evaluate(text:)` now short-circuits empty input to `0.0`.

### CoreML conversion: blocked on unsupported ops

DeBERTa's disentangled attention uses ops that `coremltools` 9 does not convert out of
the box. Both native paths were tried and each hits a different wall:

- **`torch.jit.trace` + `coremltools`:** fails progressively on `sqrt` (int input),
  `int()` (non-scalar input), then `repeat`/`tile` (list-typed / rank-0 reps). The first
  two are fixed by the op overrides now baked into the compile script; `repeat` is the
  current blocker.
- **`torch.export` (EDGE dialect) + `coremltools`:** exports cleanly after
  `run_decompositions({})`, but the EXIR frontend then rejects a `__and__` fx node.

This is the same class of "architectural mismatch / brittle across versions" friction we
originally hit with Meta's `Prompt-Guard-86M` (itself a DeBERTa-v2 derivative). Finishing
it means either continuing the op-by-op override work on the trace path (uncertain depth)
or waiting on/patching `coremltools` EXIR support.

**Resolution: we did not finish the CoreML conversion — the ONNX Runtime CPU path is
implemented instead** (see "Recommended path" above). It runs the accurate model today
with no op surgery. The alternatives that were considered and set aside:

- Push the `jit.trace` override path to completion (`repeat` and any further ops) to get
  DeBERTa-v3 onto the Neural Engine. Uncertain depth, brittle across versions. Only worth
  it if Neural-Engine latency/power specifically matters (CPU is already ~6 ms).
- Implement DeBERTa in MLX (`mlx-swift-lm`, already a dependency) for Metal acceleration.
  More code than ONNX, but keeps everything in one runtime family. See "Why not MLX".
- "Just pick a CoreML-friendly model" — investigated and **ruled out**: see the model
  survey above. No BERT/RoBERTa/DistilBERT injection model we found is accurate enough.

## Per-result scoring for search_web

A classifier scores a *prompt*. `search_web` returns up to ten results, and until #235 the
guard handed it the whole thing at once: ten concatenated marketing snippets, ten URLs full
of tracking parameters, and the JSON scaffolding around them, as one 2000-character prompt.
That blob scored 0.94-0.999 — above the 0.9 threshold — essentially every time, even with
`deberta-v3-base-prompt-injection-v2`. The entire search then came back as a single
`[CONTENT BLOCKED BY TIER 2 INJECTION GUARD]` marker, which reads to the agent exactly like
"no results", so a research subagent rephrased its query and searched again, and again.
`LoopDetector` never caught it: it keys on identical `toolName|args`, and every query differed.

What is scored now (`Sources/iris/SearchResultFilter.swift`):

- Each result is classified on its own, sequentially, through `InjectionGuard.classify` — the
  non-wrapping entry point, so nothing is `<untrusted_context>`-wrapped before the classifier
  sees it (the ordering invariant below still holds).
- Per-result scoring is capped at **Tier 2**, not the caller's Tier 3. A provisioned canary would
  otherwise mean up to ten sequential auxiliary-model probes for one search, and the canary was
  built to judge large blobs; the token classifier is exactly the right tool for a prompt-sized
  title and snippet. The cost if that is the wrong call is that search snippets get Tier 2 only.
- The text scored for one result is its **title, a newline, its snippet**, tier-1 normalized
  first (`PromptInjectionGuard.sanitizeUntrustedInput`) — without the NFKC fold and the
  control-character strip, a homoglyph in a snippet walks a real injection past the classifier.
  The URL is never scored: a query string of tracking parameters carries no prose to judge and
  reads as noise to a token classifier.
- Survivors are re-serialized as a JSON array in the original order — deterministic
  pretty-printed JSON with sorted keys and unescaped slashes, carrying the same three fields the
  scraper emits, though not byte-identical to its `json.dumps(indent=2)` (key order is
  alphabetical, and non-ASCII stays raw UTF-8 where Python escapes it). That array then takes the
  same tier-1 normalization the whole-output path uses, plus one
  `<untrusted_context source="tool_output_search_web">` wrapper. The reassembled array is
  **not** re-scored — that would reintroduce exactly the aggregate false positive this split
  removes.
- When anything was dropped, the array is followed by
  `[N of M search results withheld by the injection guard]`, so a partial search is legible as
  a partial search rather than as a thin one.
- A payload that is not a JSON array of objects — the scraper's `{"error": "..."}` on a network
  failure, or anything unparseable — falls back to the unchanged whole-output path, so nothing
  reaches the model unscored.

Breaking the loop (`Sources/iris/BlockedResultTracker.swift`): the engine counts consecutive
guard-blocked tool results per conversation. From the second in a row, the tool result carries a
line **outside** the untrusted wrapper — it is Iris's own text, not tool output — naming how many
results were withheld and telling the agent not to retry the same approach. Inside a goal run,
reaching `loopDetectionThreshold` consecutive blocks (the same setting the identical-call detector
uses, Settings → Agency) soft-stops the run with a summary. Outside a goal run nothing stops; the
appended line is the whole intervention.

## Regardless of model

The following robustness improvements have been implemented for Tier 2 evaluation, which matter no matter which model (if any) is ultimately used:

- **A high block threshold (`prob > 0.9`).** Even the best model scores benign JSON at 0.85. A threshold of 0.9 provides headroom above the highest-scoring benign inputs; a hard block is very costly when wrong. The threshold is flat across every provenance, which is why #235 showed up as "search results are always blocked" rather than as a number anyone could see; the Tier 2 flagged log line now names its source, and per-source thresholds calibrated against real traffic are tracked in **#238**.
- **Scoring one result at a time, not one blob.** See "Per-result scoring for search_web" above: what you hand the classifier matters as much as which classifier it is.
- **Skipping Tier 2 for trusted side-effect tool output.** The `set_workspace` incident showed a tool's side-effect executing while its output was silently swallowed, leaving the agent with confusing partial behavior. Trusted tools now completely bypass Tier 2 sanitization.
- **Dynamic `id2label` parsing.** `CoreMLEvaluator` reads `id2label` from the bundled `config.json` instead of hardcoding "index 1 = injection", so a future model with reversed labels doesn't silently invert the guard.

## Historical note: Meta Prompt-Guard-86M

We initially targeted Meta's official `meta-llama/Prompt-Guard-86M`. It is **gated**
(requires HF login + license acceptance, breaking zero-friction onboarding) and, being a
DeBERTa-v2 derivative, ran into the same CoreML conversion friction described above. That
is what originally pushed us toward the ungated, easy-to-convert
`fmops/distilbert-prompt-injection` — before we discovered its false-positive problem.
