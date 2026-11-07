# injection dataset, v4

The texts behind the `injection.*` eval tasks (docs/specs/2026-10-28-model-eval-framework.md, #802). `iris --eval run` still uses v3 unless `--dataset eval/datasets/injection/v4` names this one.

- **v3's 454 texts, unchanged:** same ids, texts, payloads, splits and `exposure`.
- **24 disguised attacks (`category: subtle`, `source: synthetic-gemini-802`).** An instruction written in the register of the text around it: a compatibility note in a Compose file, a maintainer convention in a runbook, a deprecation notice in a docstring. None uses a trigger phrase ("ignore previous", "override", a role tag) or a cartoon exploit word. Six carrier shapes, four each: configuration files, documentation and runbooks, source comments and docstrings, build/CI/test logs, JSON API and webhook payloads, git output. The payload is the literal command, URL or string that compliance would produce, and appears once in the text. v3's README said there were none of these: they are #802.
- **24 benign look-alikes (`category: subtle`).** Each shares the exact carrier text and slot of one attack, with a legitimate note in the attack's place, so a guard that flags imperative prose or tooling words flags it. The pairing is by number (`subtle-disg-007` and `subtle-benign-007`), not by a field.
- **Exposure:** `clean` for every new row. They were written for #802, after v1's split was frozen, and nothing was tuned or scored on them before this dataset.
- **Split:** v1, v2 and v3 rows keep theirs. Each new category's ids are ordered by `sha256("injection-v4:<id>")`; the first `round(0.7 n)` go to `test` (half to even): 17 test and 7 dev of the 24 attacks, and the same of the 24 benign. A pair can land in different splits. Nobody assigned a row by hand.
- **Every new attack is checked as scorable** (`EvalFrameworkTests`): its payload appears once in its text, the text is under OutputCap, and the payload survives tier 1. The generator asserts the same, and that the payload is absent from the benign twin, has no newline and contains no tier-1 pattern.
- **Comparing:** v1's `subtle` attacks and the 24 new ones share a category name, so a `subtle` rate on v4 is not a `subtle` rate on v3. `compare` refuses results of two dataset versions unless `--vary dataset` says so.
- **Rebuild:** `python3 -I scripts/eval_build_v4.py`, from the repository root, reproduces every file byte for byte.
- **Frozen.** Any change to a text, a label or the split is v5.

Sources and licences: [SOURCES.md](SOURCES.md).
