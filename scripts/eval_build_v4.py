#!/usr/bin/env python3
"""Builds eval/datasets/injection/v4 (#802): v3's 454 rows unchanged (ids, texts, splits, exposure),
plus the 24 disguised `subtle` attacks and 24 benign look-alikes Gemini wrote for #802
(scripts/eval_gen_802.py). Every new row is `source: synthetic-gemini-802`, `exposure: clean`.

Split: per category, ids ordered by sha256('injection-v4:<id>'), the first round(0.7 n) are test
(half to even), at least one in each split. Nobody assigns a row by hand: 17 test and 7 dev in each
of the two new categories. The generator's rows are written once, here; a re-run reproduces every
file byte for byte.

    python3 -I scripts/eval_build_v4.py   # from the repository root

v4 is frozen once committed, like v1, v2 and v3; any change is v5. `iris --eval run` still uses v3
unless `--dataset eval/datasets/injection/v4` names this one.
"""
import hashlib
import importlib.util
import json
import os
from collections import Counter, defaultdict

V3 = "eval/datasets/injection/v3"
DST = "eval/datasets/injection/v4"
SALT = "injection-v4"
TEST_SHARE = 0.7
KEYS = ["id", "category", "source", "split", "exposure", "text", "payload", "carrier", "parent",
        "file", "index", "commit", "attack_type", "user_tool", "license"]


def generator():
    spec = importlib.util.spec_from_file_location("eval_gen_802", os.path.join(os.path.dirname(__file__), "eval_gen_802.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def order_key(sample_id):
    return hashlib.sha256(f"{SALT}:{sample_id}".encode()).hexdigest()


def split_new(rows):
    by_category = defaultdict(list)
    for row in rows:
        by_category[row["category"]].append(row)
    for members in by_category.values():
        members.sort(key=lambda r: order_key(r["id"]))
        n_test = round(len(members) * TEST_SHARE)   # half to even, as in v1, v2 and v3
        if len(members) >= 2:
            n_test = min(max(n_test, 1), len(members) - 1)
        for i, row in enumerate(members):
            row["split"] = "test" if i < n_test else "dev"
    return rows


def sha256_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def write(name, rows):
    path = os.path.join(DST, name)
    with open(path, "w", encoding="utf-8") as f:
        for row in sorted(rows, key=lambda r: r["id"]):
            f.write(json.dumps({k: row[k] for k in KEYS if k in row}, ensure_ascii=False) + "\n")
    return sha256_file(path)


def counts(rows):
    table = defaultdict(Counter)
    for row in rows:
        table[row["category"]][row["split"]] += 1
    return {c: dict(sorted(v.items())) for c, v in sorted(table.items())}


def main():
    new_attacks, new_benign = generator().build()
    # The generator's ids ("subtle-disg-001") must not collide with v3's, and its "subtle" category
    # splits among its own rows only: v1's `subtle` attacks keep the splits they have.
    v3_benign, v3_attacks = read(f"{V3}/benign.jsonl"), read(f"{V3}/attacks.jsonl")
    split_new(new_attacks)
    split_new(new_benign)
    benign, attacks = v3_benign + new_benign, v3_attacks + new_attacks
    ids = [r["id"] for r in benign + attacks]
    assert len(ids) == len(set(ids)), "duplicate ids"
    os.makedirs(DST, exist_ok=True)
    manifest = {
        "family": "injection",
        "version": 4,
        "created": "2026-11-07",
        "source": "v3's 454 rows unchanged; 24 disguised attacks and 24 benign look-alikes written by Gemini for #802 (scripts/eval_gen_802.py)",
        "generator": "scripts/eval_build_v4.py",
        "split_rule": f"v1, v2 and v3 rows keep their split; the 24 new rows of each of attacks and benign, ids ordered by "
                      f"sha256('{SALT}:<id>'), the first round({TEST_SHARE} n) are test, rounding half to even, "
                      f"at least one in each split",
        "exposure": "per row: pre-split (v1's rows, and variants of them) or clean",
        "max_bytes": 32000,
        "files": {
            "benign.jsonl": {"sha256": write("benign.jsonl", benign), "count": len(benign), "by_category": counts(benign)},
            "attacks.jsonl": {"sha256": write("attacks.jsonl", attacks), "count": len(attacks), "by_category": counts(attacks)},
        },
    }
    with open(os.path.join(DST, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    new = Counter((r["category"], r["split"]) for r in new_benign + new_attacks)
    print(f"v4: {len(benign)} benign, {len(attacks)} attacks; new {len(new_benign)} benign, {len(new_attacks)} attacks {dict(new)}")


if __name__ == "__main__":
    main()
