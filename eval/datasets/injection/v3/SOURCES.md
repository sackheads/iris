# Sources of v3

**v2's rows:** see [v2's SOURCES.md](../v2/SOURCES.md) (and v1's, which it links). They're unchanged here. v2's InjecAgent licence is in [v2/LICENSES](../v2/LICENSES/InjecAgent-MIT.txt); none of v3's new rows come from InjecAgent.

## Long texts (66)

All by `scripts/eval_build_v3.py`, seed 789.

- **`source: repo`** (`long_diff`, `long_code`, `long_docs`): this repository at `b61bf05c`, v1's pin, read with `git show`, so a later commit doesn't change them. `long_code` and `long_docs` are whole files of 8 to 31.4 KB (Swift, Python, shell; `docs/` Markdown). `long_diff` is `git show --unified=3` of a commit with 150 to 1,500 inserted lines, cut at a line end to 31.4 KB.
  - Scrubbed as in v1: home paths become `/Users/me` and email addresses `dev@example.com`.
  - Left out by name: v1's list of guard documents and sources, plus anything under `eval/` and any path naming the guard, injection, the canary or fixtures. Their texts quote attacks, so they aren't benign by label.
  - Left out by content: any file or diff that quotes an attack phrase ("ignore previous instructions", "system prompt", `<<SYS>>`, `[INST]` and similar).
  - Left out because they're written to instruct agents (`AGENTS.md`, `CLAUDE.md`, `.agents/`, skills, superpowers plans, or any text saying "for agentic workers" or "AI agents must"). A guard that flags one isn't plainly wrong, so it isn't benign by label (#809 review).
  - Each repository row names its origin: `file` and `commit` (the pin) for a whole file, `commit` for a diff. A long attack or `buried` variant built on repository content carries its carrier's origin too.
- **`source: synthetic`** (`long_build_log`, `long_test_log`, `long_json`, `long_listing`): built from templates in the script, filled from the same pin:
  - a `swift build` log over the repository's real source and test file names;
  - a `swift test` log over its real test function names;
  - a GitHub-issues-style JSON array whose titles are commit subjects;
  - an `ls -l`-style listing of the tree, with real sizes and made-up dates.
- **Attacks:** each long attack is one of these carriers, built the same way with its own draw, with one instruction line written for v3 inserted. The 24 lines are in the script.

## Fresh attacks (30)

`source: v3-fresh`. They were written for this project on 2026-10-28, after v1's split was frozen, in the explicit categories only. `embedded_*` and half the `delimiter` texts are planted in v1 benign texts of the matching kind: `json_api`, `build_log`, synthetic `docs` and synthetic `code`. The carrier is v1's, but the instruction is new, so the row is `clean`. The texts are in the script.

## Adversarial variants (48)

`source: derived`. These are mechanical transforms of 12 attacks in this dataset, named in each row's `parent`, with a fixed seed. `buried` puts the parent's line in a new long carrier built as above. No text is written by hand.
