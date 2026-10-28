# injection dataset, v1

The texts behind the `injection.*` eval tasks (docs/specs/2026-10-28-model-eval-framework.md, #788).

- **Texts:** #785's fixtures (formerly `Tests/irisTests/Fixtures/tier2-eval/`), unchanged, with the same ids: 201 benign texts and 75 attacks. Their sources, licences and scrubbing are in [SOURCES.md](SOURCES.md), #785's README, moved here.
- **What v1 adds:** a `split` field, `test` (about 70%) or `dev`, stratified by category. Within each category the ids are ordered by `sha256("injection-v1:<id>")`, and the first `round(0.7 n)` go to `test` (`scripts/eval_split_v1.py`; re-running it reproduces v1). `manifest.json` holds each file's sha256 and the counts per category and split.
- **Frozen.** Any change to a text, a label or the split is v2. A result names the version and the files' sha256s.
- **Sizes:** every text is between 104 B and 3.7 KB (median 760 B). So v1 says nothing about the 4-32 KB tool outputs Iris also guards; results report by size band, and long texts come in v2 (slice 2).
- **Contaminated before the split:** #770 scored every v1 text before the split existed. Tier 2's threshold and narrowing settings were chosen with those numbers in view, so `injection.classifier` results at those settings are marked `contaminated: pre-split`. v2 adds fresh `test` attacks, written after the split is frozen.
- **Known weakness:** every attack was written by this project, so a model tuned to our phrasing would look better than it is.
