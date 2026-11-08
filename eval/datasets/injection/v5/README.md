# injection dataset, v5

The texts behind the `injection.*` eval tasks (docs/specs/2026-10-28-model-eval-framework.md, #952 Task 5). `iris --eval run` still uses v3 unless `--dataset eval/datasets/injection/v5` names this one.

- **v4's 502 texts, unchanged:** same ids, texts, payloads, splits and `exposure`. `attacks.jsonl` is byte-for-byte v4's file (`scripts/eval_build_v5.py` asserts this).
- **24 new benign config-shaped rows (`source: synthetic-952`).** v4 has only a handful of benign rows that spell `model:`, `system:`, `user:` as ordinary YAML/config keys, or `---` as an ordinary YAML document separator — most of its `config` category is CI YAML and Dockerfiles with no role-shaped keys at all. That under-measures exactly the false-positive risk docs/specs/2026-11-08-role-marker-sanitizer-fidelity.md's fidelity channel takes on: a config file whose ordinary syntax happens to spell a role marker, judged and shown unstripped instead of deleted. Four carrier shapes, written by hand, none containing any instruction, payload or trigger phrase:
  1. **`compose`** (8 rows): Docker Compose files using `user:` (the container's uid:gid) as an ordinary key.
  2. **`k8s_yaml`** (6 rows): multi-document Kubernetes manifests using `---` between resources — the ordinary Kubernetes convention, not markdown.
  3. **`llm_config`** (6 rows): LLM client/provider configs — a litellm proxy route table, a prompt template with `system:`/`user:` keys, a chat message array with `role: system`/`role: user`, an Ollama Modelfile's `SYSTEM` block, a RAG chain config, and a prompt-eval harness's `judge.system`. These are the shapes closest to the real risk: ordinary config syntax that happens to read as a role marker, with no instruction in any value.
  4. **`ansible`** (4 rows): playbooks using the YAML `---` document start and `become_user:`/`user:` as ordinary keys.
- **Exposure:** `clean` for every new row — written for this task, after v1's split froze, and nothing was tuned or scored on them before.
- **Split:** v1-v4 rows keep theirs. The 24 new rows are split per category, ids ordered by `sha256("injection-v5:<id>")`; the first `round(0.7 n)` go to `test` (half to even), at least one in each split. Nobody assigned a row by hand.
- **No new attack rows.** `attacks.jsonl` is unchanged from v4; this version adds only to `benign.jsonl` (#802's standing rule: no new attack payloads, ever).
- **Rebuild:** `python3 -I scripts/eval_build_v5.py`, from the repository root, reproduces every file byte for byte.
- **Frozen.** Any change to a text, a label or the split is v6.

Sources and licence notes for the new rows: [SOURCES.md](SOURCES.md). v4's own sources are unchanged: see [v4's SOURCES.md](../v4/SOURCES.md).
