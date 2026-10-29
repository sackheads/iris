"""Rebuilds every table in the #789 v3 data PR from committed files only.

    python3 -I eval/runs-789-v3/tables.py

Reads the two results, the dataset, and the per-judgement tier lines taken from each run's
[perf] log (`*-tiers.jsonl`; the result rows record no tier, #830). The eval judges serially
in id order, repeat by repeat (EvalGuardTask.swift:205-207, EvalDataset.select), so the nth
tier line is the nth judgement. This script checks that before using it.
"""
import json, os, statistics as S
from collections import Counter, defaultdict

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here))
VER = f"{root}/eval/results/injection.verdict/2026-10-28-ollama-gemma4-12b-thinkoff-v3-all-full.json"
STK = f"{root}/eval/results/injection.stack/2026-10-29-stack123-ollama-gemma4-12b-thinkoff-v3-all-full.json"
DS = f"{root}/eval/datasets/injection/v3"

texts = {}
for f, attack in (("benign.jsonl", False), ("attacks.jsonl", True)):
    for line in open(f"{DS}/{f}"):
        if line.strip():
            r = json.loads(line); r["attack"] = attack; texts[r["id"]] = r
ids = sorted(texts)
N = len(ids)

def load(path):
    d = json.load(open(path))
    return d, {(r["id"], r["repeat_index"]): r for r in d["verdicts"]}

V, vr = load(VER)
St, sr = load(STK)
R = V["key"]["repeats"]
tiers = {name: [json.loads(l) for l in open(f"{here}/{name}-tiers.jsonl")] for name in ("verdict", "stack123")}

# --- checks: the tier lines line up with the results ---
def derived(e):
    if e.get("tier2") == "error" or e.get("tier3") == "error": return "fail-closed"
    if e.get("tier2") == "malicious" or e.get("tier3") == "malicious": return "blocked"
    return "withheld" if e.get("tier2") == "partial" else "passed"
for name, rows in (("verdict", vr), ("stack123", sr)):
    seq = tiers[name]
    assert len(seq) == N * R
    assert all(e["id"] == ids[e["n"] % N] and e["repeat_index"] == e["n"] // N for e in seq)
    match = sum(derived(e) == rows[(e["id"], e["repeat_index"])]["outcome"] for e in seq)
    print(f"check {name}: derived outcome equals the result row for {match}/{len(seq)}")
same = sum(a["tier2_chars"] == b["tier2_chars"] for a, b in zip(tiers["verdict"], tiers["stack123"]))
print(f"check: tier-2 chars equal across the two runs at {same}/{N * R} positions")
moved = {e["id"] for e in tiers["verdict"] if e["tier2_chars"] != len(texts[e["id"]]["text"])}
steady = all(len({e["tier2_chars"] for e in tiers["verdict"] if e["id"] == i}) == 1 for i in moved)
print(f"check: tier-2 chars equal the dataset text's length for {N - len(moved)}/{N} texts; the other "
      f"{len(moved)} differ by the same amount in every repeat: {steady} (tier 1's strip and NFKC)")
grew = [(e["id"], e["tier2_chars"], e["tier3_chars"]) for e in tiers["stack123"]
        if "tier3_chars" in e and e["tier3_chars"] > e["tier2_chars"]]
print(f"check: tier-3 chars over tier-2 chars in {len(grew)} judgements, all after a tier-2 partial: "
      f"{all(e.get('tier2') == 'partial' for e in tiers['stack123'] if 'tier3_chars' in e and e['tier3_chars'] > e['tier2_chars'])}")

def hit(row):  # as the metrics count: an attack caught, a benign text not passed
    return row["caught"] if texts[row["id"]]["attack"] else row["outcome"] != "passed"

# --- per repeat ---
print("\n## Per repeat\n")
print("| run | repeat | FP (of 253) | recall (of 201) | fresh (of 30) | timeouts | minutes | long p50 / p95 / max s |")
print("|---|---|---|---|---|---|---|---|")
for name, rows in (("verdict", vr), ("1+2+3", sr)):
    for r in range(R):
        rr = [rows[(i, r)] for i in ids]
        fp = sum(hit(x) for x in rr if not texts[x["id"]]["attack"])
        rc = sum(hit(x) for x in rr if texts[x["id"]]["attack"])
        fr = sum(hit(x) for x in rr if texts[x["id"]].get("source") == "v3-fresh")
        to = sum(x["outcome"] == "fail-closed" and x["seconds"] >= 55 for x in rr)
        lg = sorted(x["seconds"] for x in rr if len(texts[x["id"]]["text"].encode()) > 8000)
        p95 = lg[-(-95 * len(lg) // 100) - 1]
        print(f"| {name} | {r + 1} | {fp} | {rc} | {fr} | {to} | {sum(x['seconds'] for x in rr) / 60:.1f} | "
              f"{S.median(lg):.1f} / {p95:.1f} / {lg[-1]:.1f} |")

# --- layers ---
att = {f"{e['id']}#{e['repeat_index']}": e for e in tiers["stack123"]}
def layer(k):
    e, row = att[f"{k[0]}#{k[1]}"], sr[k]
    if e.get("tier2") == "malicious": return "t2 block"
    if e.get("tier3") == "malicious": return "t3 block after t2 partial" if e.get("tier2") == "partial" else "t3 block"
    if e.get("tier2") == "partial":
        if not texts[k[0]]["attack"]: return "t2 partial, t3 passed"
        return "t2 partial removed payload" if row["caught"] else "t2 partial kept payload, t3 passed"
    return "passed both"

cols = ["t2 block", "t3 block", "t3 block after t2 partial", "t2 partial removed payload",
        "t2 partial kept payload, t3 passed", "passed both"]
print("\n## Attacks by category: judgements caught, and how 1+2+3 handled each\n")
print("| category | judgements | verdict | 1+2+3 | " + " | ".join(cols) + " |")
print("|---|---|---|---|" + "---|" * len(cols))
cats = sorted({t["category"] for t in texts.values() if t["attack"]})
total = Counter()
for c in cats:
    keys = [(i, r) for i in ids for r in range(R) if texts[i]["attack"] and texts[i]["category"] == c]
    v = sum(hit(vr[k]) for k in keys); s = sum(hit(sr[k]) for k in keys)
    lc = Counter(layer(k) for k in keys); total.update(lc)
    print(f"| {c} | {len(keys)} | {v} ({v / len(keys):.0%}) | {s} ({s / len(keys):.0%}) | " + " | ".join(str(lc[x]) for x in cols) + " |")
print("| all | 603 | | | " + " | ".join(str(total[x]) for x in cols) + " |")

bcols = ["t2 block", "t3 block", "t3 block after t2 partial", "t2 partial, t3 passed"]
print("\n## Benign by category: judgements not passed, and by which tier\n")
print("| category | judgements | verdict FP | 1+2+3 FP | " + " | ".join(bcols) + " |")
print("|---|---|---|---|" + "---|" * len(bcols))
btotal = Counter()
for c in sorted({t["category"] for t in texts.values() if not t["attack"]}):
    keys = [(i, r) for i in ids for r in range(R) if not texts[i]["attack"] and texts[i]["category"] == c]
    v = sum(hit(vr[k]) for k in keys); s = sum(hit(sr[k]) for k in keys)
    lc = Counter(layer(k) for k in keys); btotal.update(lc)
    print(f"| {c} | {len(keys)} | {v} | {s} | " + " | ".join(str(lc[x]) for x in bcols) + " |")
print("| all | 759 | | | " + " | ".join(str(btotal[x]) for x in bcols) + " |")

# --- cross ---
keys = [(i, r) for i in ids for r in range(R) if texts[i]["attack"]]
vm = [k for k in keys if not hit(vr[k])]
lost = [k for k in keys if hit(vr[k]) and not hit(sr[k])]
print("\n## Cross, per attack judgement (same text, same repeat index)\n")
print(f"- verdict missed {len(vm)}; 1+2+3 caught {sum(hit(sr[k]) for k in vm)} of them: "
      + ", ".join(f"{n} {l}" for l, n in Counter(layer(k) for k in vm if hit(sr[k])).most_common()))
print(f"- verdict caught {len(keys) - len(vm)}; 1+2+3 missed {len(lost)} of them: "
      + ", ".join(f"{n} {l}" for l, n in Counter(layer(k) for k in lost).most_common())
      + ": " + ", ".join(f"`{i}` r{r + 1}" for i, r in lost))
def unstable_ids(rows): return {i for i in ids if len({rows[(i, r)]["outcome"] for r in range(R)}) > 1}
either = unstable_ids(vr) | unstable_ids(sr)
gained = [k for k in vm if hit(sr[k])]
t3_alone = [k for k in gained if layer(k) == "t3 block"]
print(f"- of the {len(gained)}: tier 3 alone (no tier-2 partial) {len(t3_alone)}, leaving {len(gained) - len(t3_alone)} that "
      f"tier 2 took part in; {sum(k[0] in either for k in gained)} of the {len(gained)} are texts unstable in either run "
      f"({sum(k[0] in either for k in t3_alone)} of the tier-3-alone ones)")
per = defaultdict(lambda: [0, 0])
for k in keys:
    per[k[0]][0] += hit(vr[k]); per[k[0]][1] += hit(sr[k])
print(f"- texts caught 3/3 by verdict and 0/3 by 1+2+3: {sum(a == 3 and b == 0 for a, b in per.values())}; "
      f"0/3 by verdict and 3/3 by 1+2+3: {sum(a == 0 and b == 3 for a, b in per.values())}")

# --- unstable ---
def unstable(rows): return sorted(i for i in ids if len({rows[(i, r)]["outcome"] for r in range(R)}) > 1)
vu, su = unstable(vr), unstable(sr)
print(f"\n## Unstable texts (outcome differs across repeats): verdict {len(vu)}, 1+2+3 {len(su)}, in both {len(set(vu) & set(su))}\n")
print("| run | id | label | category | r1 | r2 | r3 |\n|---|---|---|---|---|---|---|")
for name, rows, us, lay in (("verdict", vr, vu, None), ("1+2+3", sr, su, layer)):
    for i in us:
        cells = [rows[(i, r)]["outcome"] + (f" ({lay((i, r))})" if lay else "") for r in range(R)]
        print(f"| {name} | `{i}` | {'attack' if texts[i]['attack'] else 'benign'} | {texts[i]['category']} | " + " | ".join(cells) + " |")
