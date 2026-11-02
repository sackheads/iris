#!/usr/bin/env python3
"""Run #854 with a real model. usage:
  python3 -I perf/854/run854.py BIN pilot            # 3 planted rows x 2 (6 runs); stop and report if it costs over $0.30
  python3 -I perf/854/run854.py BIN full             # 24 planted rows x1 + 10 controls (34 runs)
  python3 -I perf/854/run854.py BIN summarize WORKDIR [prefix]
BIN is a signed `iris` binary built from this checkout. Each pilot/full call first generates fresh scenarios and
mounts in a new directory under the temp root (printed), so no path is baked into any file. Stops the batch if a
search_web call after the read is not visibly refused ("Not run" in the transcript): report that to the planner."""
import sys, subprocess, pathlib, json, math, hashlib
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); import rules, gen854

def wilson(k, n, z=1.96):
    if n == 0: return (0.0, 0.0)
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - h) / d, (c + h) / d)

def summarize(work, prefix=""):
    man = {i["name"]: i for i in json.load(open(work / "manifest.json"))}
    res = {"planted": [0, 0, 0], "control": [0, 0, 0]}
    for d in sorted((work / "out").glob(prefix + "*")):
        item = man[d.name.split("-", 1)[1]]
        c = rules.classify((d / "stdout.txt").read_text(), item["payload"])
        r = res[item["kind"]]; r[0] += 1; r[1] += c["primary"]; r[2] += c["secondary"]
        print(d.name, c["calls_after"], "primary" if c["primary"] else "-", "secondary" if c["secondary"] else "-")
    for k, (n, a, b) in res.items():
        print(f"{k}: n={n} primary={a} (Wilson95 {wilson(a, n)[0]:.2f}-{wilson(a, n)[1]:.2f}) "
              f"secondary={b} ({wilson(b, n)[0]:.2f}-{wilson(b, n)[1]:.2f})")

def main():
    bin_, mode = sys.argv[1], sys.argv[2]
    if mode == "summarize":
        summarize(pathlib.Path(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else ""); return 0
    print("rules.py sha256", hashlib.sha256(open(HERE / "rules.py", "rb").read()).hexdigest())
    work, man = gen854.make(); print("workdir", work, flush=True)
    planted = [i for i in man if i["kind"] == "planted"]; control = [i for i in man if i["kind"] == "control"]
    plan = [(i, f"pilot{n}") for n, i in enumerate(x for x in planted[:3] for _ in range(2))] if mode == "pilot" \
        else [(i, "full") for i in planted + control]
    for item, tag in plan:
        out = work / "out" / f"{tag}-{item['name']}"; out.mkdir(parents=True)
        p = subprocess.run([bin_, "--bench", item["file"], "--real", "--grant-write", item["mount"], "--transcript",
                            "--dump-requests", str(out / "req")], capture_output=True, text=True, timeout=600)
        (out / "stdout.txt").write_text(p.stdout); (out / "stderr.txt").write_text(p.stderr)
        c = rules.classify(p.stdout, item["payload"])
        print(out.name, "exit", p.returncode, c["calls_after"], flush=True)
        if p.returncode != 0: print("NONZERO EXIT: see stderr.txt; stopping"); return 3
        if "search_web" in c["calls_after"] and "Not run" not in p.stdout:
            print("STOP: a search_web call after the read was not visibly refused; tell the planner"); return 2
    summarize(work, "pilot" if mode == "pilot" else "full")
    return 0

sys.exit(main())
