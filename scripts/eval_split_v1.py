#!/usr/bin/env python3
"""Builds eval/datasets/injection/v1 from #785's fixtures (#788): the same texts and ids, plus a
`split` field, stratified by category, and a manifest with each file's sha256 and the counts per
split and category.

The split is a pure function of each id, so re-running this reproduces v1 exactly; v1 is frozen
once committed, and any change is v2 (docs/specs/2026-10-28-model-eval-framework.md, section 3).

    python3 -I scripts/eval_split_v1.py   # from the repository root
"""
import hashlib
import json
import os
import subprocess
from collections import Counter, defaultdict

# #785's fixtures, read from the commit they were last at before #788 moved them here.
SRC_COMMIT = "7406e8cc"
SRC = "Tests/irisTests/Fixtures/tier2-eval"
DST = "eval/datasets/injection/v1"
TEST_SHARE = 0.7
SALT = "injection-v1"


def order_key(sample_id):
    return hashlib.sha256(f"{SALT}:{sample_id}".encode()).hexdigest()


def split(rows):
    by_category = defaultdict(list)
    for row in rows:
        by_category[row["category"]].append(row)
    for members in by_category.values():
        members.sort(key=lambda r: order_key(r["id"]))
        # Python's round, half to even: part of v1's definition (n=15 gives 10, not 11).
        # At least one of each in a category of two or more, so dev is never empty for a category.
        n_test = round(len(members) * TEST_SHARE)
        if len(members) >= 2:
            n_test = min(max(n_test, 1), len(members) - 1)
        for i, row in enumerate(members):
            row["split"] = "test" if i < n_test else "dev"
    return rows


def load(name):
    text = subprocess.run(["git", "show", f"{SRC_COMMIT}:{SRC}/{name}"], check=True,
                          capture_output=True, text=True).stdout
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def write(name, rows):
    path = os.path.join(DST, name)
    keys = ["id", "category", "source", "split", "text", "payload"]
    with open(path, "w", encoding="utf-8") as f:
        for row in sorted(rows, key=lambda r: r["id"]):
            out = {k: row[k] for k in keys if k in row}
            f.write(json.dumps(out, ensure_ascii=False) + "\n")
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def counts(rows):
    table = defaultdict(Counter)
    for row in rows:
        table[row["category"]][row["split"]] += 1
    return {c: dict(sorted(v.items())) for c, v in sorted(table.items())}


def main():
    os.makedirs(DST, exist_ok=True)
    benign, attacks = split(load("benign.jsonl")), split(load("attacks.jsonl"))
    manifest = {
        "family": "injection",
        "version": 1,
        "created": "2026-10-28",
        "source": f"{SRC} at {SRC_COMMIT} (#785), unchanged texts and ids",
        "generator": "scripts/eval_split_v1.py",
        "split_rule": f"per category, ids ordered by sha256('{SALT}:<id>'), the first round({TEST_SHARE} n) are test, "
                      "rounding half to even (Python's round: n=15 gives 10), at least one in each split",
        "pre_split_exposure": "#770 scored every text of v1 before the split, so tier 2's threshold and "
                              "narrowing settings have seen test: results that depend on them are "
                              "contaminated: pre-split",
        "files": {
            "benign.jsonl": {"sha256": write("benign.jsonl", benign), "count": len(benign),
                             "by_category": counts(benign)},
            "attacks.jsonl": {"sha256": write("attacks.jsonl", attacks), "count": len(attacks),
                              "by_category": counts(attacks)},
        },
    }
    with open(os.path.join(DST, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    total = Counter(r["split"] for r in benign + attacks)
    print(f"v1: {len(benign)} benign, {len(attacks)} attacks; test {total['test']}, dev {total['dev']}")


if __name__ == "__main__":
    main()
