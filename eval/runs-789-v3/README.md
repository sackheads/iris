# #789: v3 verdict and stack runs, per-judgement data

Supporting data for two results:

- `eval/results/injection.verdict/2026-10-28-ollama-gemma4-12b-thinkoff-v3-all-full.json`
- `eval/results/injection.stack/2026-10-29-stack123-ollama-gemma4-12b-thinkoff-v3-all-full.json`

Both were run from one binary built at `73e9be39`, signed with the Developer ID and launched directly.

## Files

- **`verdict-tiers.jsonl`, `stack123-tiers.jsonl`:** one line per judgement (1,362 each), taken from the run's `[perf]` log. A line records:
  - the text's `id` and `repeat_index`;
  - tier 2's verdict, its input length (`tier2_chars`) and its time;
  - tier 3's verdict, input length and time, when tier 3 ran;
  - `at`, the UTC second the judgement started.

  The result rows record only the outcome, not the tier that blocked, so this is where the per-tier tables come from. The field is #830.
- **`verdict-load.txt`, `stack123-load.txt`:** written every 30 s during each run. Each line is the load average, plus the CPU of `BackgroundShortcutRunner` and of CacheDelete's `deleted`, as `ps` reports it.
- **`tables.py`:** rebuilds every table in the PR from the committed files only:

  ```sh
  python3 -I eval/runs-789-v3/tables.py
  ```

  It first checks that the tier lines line up with the results:
  - the outcome derived from each line equals the result row, for all 1,362;
  - tier 2's input length is equal across the two runs at every position;
  - each text's length is the dataset's, or differs by the same amount in every repeat, from tier 1's strip and NFKC.

  The order holds because the eval judges serially in id order, repeat by repeat (`EvalGuardTask.swift:205-207`, `EvalDataset.select`).

  The perf log carries no id. The extractor gave line n the id at position `n mod 454` of the sorted ids, with repeat `n div 454`. So the `id` check only confirms that rule. The outcome and length checks are the independent ones.
- **`tier1_lengths.py`:** explains every text whose tier-2 input length differs from its dataset length.
  - It replays tier 1 in Python: NFKC, the control-character strip, the role-delimiter strips and the breakout-tag escape.
  - It counts the result in Swift Characters and requires the logged length exactly.
  - All 454 texts match, and it prints the cause of each difference with one example id.

## Stripped

The stack result's `model.spec` and `settings.tier2_bundle` held the absolute path of the tier-2 bundle under the home folder. The home prefix is replaced with `~/`, so they read `~/.iris/models/deberta-v3-base-prompt-injection-v2.onnx-no`. Nothing else was changed. The bundle's files and sha256s are unchanged in `model`, and its digest is in `settings.tier2_fingerprint`. The verdict result and these files held no local path.
