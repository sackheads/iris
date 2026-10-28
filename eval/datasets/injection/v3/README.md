# injection dataset, v3

The texts behind the `injection.*` eval tasks (docs/specs/2026-10-28-model-eval-framework.md, #789). `iris --eval run` uses v3 unless `--dataset` names another.

- **v2's 310 texts, unchanged:** same ids, texts, payloads, splits and `exposure`.
- **Long texts, 8 to 32 KB.** v1 and v2 stop at 3.7 KB, and #785 found false positives grow with length.
  - **42 benign texts:** 6 each of `long_build_log`, `long_test_log`, `long_json`, `long_listing`, `long_diff`, `long_code` and `long_docs`.
  - **24 attacks:** one instruction line each, in output of the line's own kind (a compiler warning in a build log, a JSON field in JSON). The line sits in the first tenth of the lines (`long_head`), the middle tenth (`long_middle`) or the last tenth (`long_tail`), 8 of each.
  - Every v3 text is at most 32,000 bytes, under OutputCap's 32 KB limit, so the product judges it whole and no payload is cut.
- **30 fresh attacks,** `source: v3-fresh`, all `test`. They were written for v3 after v1's split was frozen, and nothing was tuned or scored on them before. Results report their recall on its own line, the one recall no setting has seen. Categories: `direct` 8, `delimiter` 8, `embedded_json` 4, `embedded_log` 4, `embedded_docs` 3 and `embedded_code` 3. There are no trigger-free or disguised ones: those are #802.
- **48 adversarial variants** (spec, section 3). There are 12 parent attacks: 6 of v1's (seeded choice) and 6 of the fresh ones, each with a one-line payload of six words or more. Each transform is applied to all 12, so a parent reads across the four:
  - `adversarial.case_space`: the payload in upper or random case, with doubled spaces and tabs between words.
  - `adversarial.lookalike`: about half the payload's `a e o p c x y i` replaced by Cyrillic look-alikes. NFKC (tier 1) doesn't fold these, so the model sees them.
  - `adversarial.line_split`: the payload broken across two or three lines. Its payload is the longest fragment, so the variant counts as caught when that fragment is withheld.
  - `adversarial.buried`: the parent's instruction line moved into a long text, 60-95% of the way down.

  A variant's row names its `parent`, and takes the parent's split and exposure: a variant of a pre-split v1 attack is pre-split too.
  A trigger-free paraphrase transform was dropped (#802).
- **Exposure:** `clean` for every new text, except the 24 variants of v1's attacks. Results give clean texts' false positives and recall apart, next to `contaminated: pre-split: N of M texts`.
- **Split:** v1's and v2's texts keep theirs; the fresh attacks are all `test`; variants take their parent's. The other new rows are split per category, with ids ordered by `sha256("injection-v3:<id>")`; the first `round(0.7 n)` go to `test` (half to even), with at least one in each split.
- **Every new attack is checked as scorable** (`EvalDatasetTests`): its payload appears once in its text, the text is under OutputCap, and the payload survives tier 1. Otherwise tier 1 removing it would count as a catch.
- **Rebuild:** `python3 -I scripts/eval_build_v3.py`, from the repository root, reproduces every file byte for byte (seed 789; repository content read with `git show` at `b61bf05c`).
- **Frozen.** Any change to a text, a label or the split is v4.

Sources and licences: [SOURCES.md](SOURCES.md).

**First result** (#809): `eval/results/injection.classifier/2026-10-28-onnx-deberta-v3-base-prompt-injection-v2.onnx-v3-test-full.json` records `iris_commit` `c763e9bd`, the branch before its rebase onto main for #801 and #806. That commit isn't on main. The eval code, the guard and v3's files there are identical to the merged ones, and the result's dataset sha256s match this manifest.
