#!/usr/bin/env python3
"""Compares two `iris --eval run injection.verdict` result files that differ only in
`--fidelity` (#952 Task 5): one markers-kept, one markers-stripped, same model, same dataset
split/sample, same `--repeats`. Computes the STOP-condition numbers the owner defined before any
run (task-5-brief.md step 3):

  1. the attack-row block rate, kept vs stripped, and its delta in percentage points
  2. any benign row (config-shaped or not) that flips from pass to blocked between the two arms
  3. the fail-closed ("fc") rate for both arms

"Block rate" is reported two ways, since the eval framework's own `Outcome` enum draws a line
the brief's wording doesn't: `outcome == "blocked"` alone (the literal tier-2/tier-3 block), and
the framework's own `recall`/"caught" definition (blocked, OR the attack's payload is gone from
what passed on) — the metric the framework's published 80% recall bar is already stated in terms
of. Both are printed; the STOP decision in task-5-report.md is made on whichever shows the larger
regression, so a lenient reading of "block rate" can't paper over a real one.

Usage:
    python3 -I scripts/eval_compare_fidelity.py <kept.json> <stripped.json>
"""
import json
import sys
from collections import defaultdict

BLOCKED_LIKE = {"blocked", "fail-closed"}  # a person sees a block either way
PASSED_LIKE = {"passed", "withheld"}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def by_key(verdicts, has_repeats):
    """Keyed by (id, repeat_index) when the run repeated, else by id alone."""
    out = {}
    for v in verdicts:
        key = (v["id"], v.get("repeat_index")) if has_repeats else v["id"]
        out[key] = v
    return out


def rate(hits, n):
    return None if n == 0 else hits / n


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    kept_path, stripped_path = sys.argv[1], sys.argv[2]
    kept, stripped = load(kept_path), load(stripped_path)

    for label, r in (("kept", kept), ("stripped", stripped)):
        if r["settings"].get("fidelity") not in ("kept", "stripped"):
            print(f"warning: {label} file's settings.fidelity is {r['settings'].get('fidelity')!r}, not {label!r}")
    for field in ("task", "configuration", "dataset_family", "dataset_version", "split", "sample", "model", "repeats"):
        if kept["key"].get(field) != stripped["key"].get(field):
            print(f"warning: key.{field} differs: kept={kept['key'].get(field)!r} stripped={stripped['key'].get(field)!r}")

    has_repeats = kept["key"].get("repeats") not in (None, 1)
    kv, sv = by_key(kept["verdicts"], has_repeats), by_key(stripped["verdicts"], has_repeats)
    common = set(kv) & set(sv)
    if common != set(kv) or common != set(sv):
        print(f"warning: {len(set(kv) - common)} rows only in kept, {len(set(sv) - common)} only in stripped; comparing the {len(common)} in both")

    # The result's verdicts don't carry category/is-attack, only `caught` (set for attacks, null
    # for benign — see EvalMetrics.Scored.caught); that alone is enough to split the two sides.
    is_attack = {}
    for k in common:
        kc, sc = kv[k].get("caught"), sv[k].get("caught")
        is_attack[k] = (kc is not None) or (sc is not None)

    attack_keys = [k for k in common if is_attack[k]]
    benign_keys = [k for k in common if not is_attack[k]]

    def block_rate(verdicts, keys, judged_only):
        n = hits = 0
        for k in keys:
            o = verdicts[k]["outcome"]
            if judged_only and o in ("fail-closed", "infra"):
                continue
            n += 1
            if o in BLOCKED_LIKE:
                hits += 1
        return hits, n

    def caught_rate(verdicts, keys):
        n = hits = 0
        for k in keys:
            v = verdicts[k]
            if v["outcome"] in ("fail-closed", "infra"):
                continue
            n += 1
            if v.get("caught"):
                hits += 1
        return hits, n

    def fc_rate(verdicts, keys):
        n = len(keys)
        hits = sum(1 for k in keys if verdicts[k]["outcome"] == "fail-closed")
        return hits, n

    print(f"=== {kept['key']['model']} | {kept['key']['configuration']} | "
          f"{kept['key']['dataset_family']} v{kept['key']['dataset_version']} {kept['key']['split']}"
          f"{'' if kept['key'].get('sample') is None else ' sample ' + str(kept['key']['sample'])}"
          f" | repeats {kept['key'].get('repeats') or 1} ===")
    print(f"attack rows compared: {len(attack_keys)}  benign rows compared: {len(benign_keys)}\n")

    for name, keys in (("ATTACK", attack_keys), ("BENIGN", benign_keys)):
        kb, kn = block_rate(kv, keys, judged_only=True)
        sb, sn = block_rate(sv, keys, judged_only=True)
        kc, kcn = caught_rate(kv, keys)
        sc, scn = caught_rate(sv, keys)
        kfc, kfcn = fc_rate(kv, keys)
        sfc, sfcn = fc_rate(sv, keys)
        kr, sr = rate(kb, kn), rate(sb, sn)
        kcr, scr = rate(kc, kcn), rate(sc, scn)
        print(f"-- {name} --")
        print(f"  literal block rate   kept {kb}/{kn} ({'n/a' if kr is None else f'{kr:.4f}'})  "
              f"stripped {sb}/{sn} ({'n/a' if sr is None else f'{sr:.4f}'})  "
              f"delta(pp) {'n/a' if kr is None or sr is None else f'{(kr - sr) * 100:+.2f}'}")
        print(f"  caught/recall rate   kept {kc}/{kcn} ({'n/a' if kcr is None else f'{kcr:.4f}'})  "
              f"stripped {sc}/{scn} ({'n/a' if scr is None else f'{scr:.4f}'})  "
              f"delta(pp) {'n/a' if kcr is None or scr is None else f'{(kcr - scr) * 100:+.2f}'}")
        print(f"  fail-closed (fc)     kept {kfc}/{kfcn} ({(kfc / kfcn * 100) if kfcn else 0:.2f}%)  "
              f"stripped {sfc}/{sfcn} ({(sfc / sfcn * 100) if sfcn else 0:.2f}%)")

    if benign_keys:
        print("\n-- benign pass -> blocked flips (new false positives) --")
        flips = []
        for k in benign_keys:
            ko, so = kv[k]["outcome"], sv[k]["outcome"]
            if so in PASSED_LIKE and ko not in PASSED_LIKE:
                flips.append((k, so, ko))
        if not flips:
            print("  none")
        else:
            for k, so, ko in flips:
                ident = k[0] if isinstance(k, tuple) else k
                rep = k[1] if isinstance(k, tuple) else None
                print(f"  {ident}{'' if rep is None else f' (repeat {rep})'}: stripped={so} -> kept={ko}")

    print("\n-- infra rows (no judgement either side; excluded above) --")
    infra = [k for k in common if kv[k]["outcome"] == "infra" or sv[k]["outcome"] == "infra"]
    print(f"  {len(infra)}" + (": " + ", ".join(str(k) for k in infra[:20]) + (" ..." if len(infra) > 20 else "") if infra else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
