# injection dataset, v2

The texts behind the `injection.*` eval tasks (docs/specs/2026-10-28-model-eval-framework.md, #788).  `iris --eval run` uses v2 unless `--dataset` names another.

- **v1's 276 texts, unchanged:** same ids, texts, payloads and splits, now marked `exposure: pre-split` (#770 and #783 scored all of them before the split existed).
- **24 attacks from [InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent)** at `f19c9f2`, MIT ([licence](LICENSES/InjecAgent-MIT.txt)): 12 from its direct-harm base set and 12 from its data-stealing base set, category `subtle_plain`, apart from v1's `subtle` so each reports on its own line, `exposure: clean`.  Each text is the case's `Tool Response`, verbatim, which is what the canary sees.  The payload is the first 60 characters of its `Attacker Instruction`.  Which cases, and why, is in [SOURCES.md](SOURCES.md).
- **10 benign look-alikes**, category `json_api`, `exposure: clean`: InjecAgent's tool-response templates with the injection slot filled by a legitimate instruction we wrote ("Run make test before opening a pull request").  Without them, a detector that blocks every imperative in tool output would score perfectly on the new attacks.
- **Split:** v1's texts keep theirs.  The new ones are split per category, ids ordered by `sha256("injection-v2:<id>")`, the first `round(0.7 n)` to `test` (half to even), at least one in each split: 17 test and 7 dev attacks, 7 test and 3 dev benign.
- **Contamination is per text:** a result names how many of the texts it scored are `pre-split` (`contaminated: pre-split: N of M texts`).  The clean rows are the only ones nothing here has been tuned on.
- **Rebuild:** `python3 -I scripts/eval_build_v2.py <InjecAgent checkout at f19c9f2>` reproduces every file, and refuses a checkout whose files differ.
- **Frozen.**  Any change to a text, a label or the split is v3.  Long (4-32 KB) texts, which v1's README put in v2, are v3 now.
- **The gap:** see SOURCES.md.  In short, these are plain requests planted in tool output, not disguised ones.
