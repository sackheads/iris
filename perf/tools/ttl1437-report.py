#!/usr/bin/env python3
"""#1437: per-tick tokens and dollars for one or more `iris --perf run` records of loop-ttl-1437.
Usage: perf/tools/ttl1437-report.py <run.json> [<run.json> ...]
Prices: claude-sonnet-5-5 list ($/M), from platform.claude.com pricing (2026-11-27): input 2.00, output 10.00,
cache read 0.10 (0.05x on Sonnet 5.5 and Opus 5.5), 5m write 2.50, 1h write 4.00."""
import json, sys
IN, OUT, READ, W5, W1H = 2.00, 10.00, 0.10, 2.50, 4.00
grand = 0.0
for path in sys.argv[1:]:
    rec = json.load(open(path))
    print(f"== {path}  experiments={rec.get('environment', {}).get('experiments')}  models={rec.get('environment', {}).get('models')}")
    print(f"{'tick':>4} {'prompt':>8} {'read':>8} {'write5m':>8} {'write1h':>8} {'uncached':>8} {'out':>6} {'$':>8}")
    total = 0.0
    for sc in rec["scenarios"]:
        for rung in sc["rungs"]:
            for rep in rung["repetitions"]:
                if rep.get("error"): print("  ERROR:", rep["error"])
                for i, turn in enumerate(rep["turns"], 1):
                    p = r = w = w1 = o = 0; unsplit = False
                    for c in turn["modelCalls"]:
                        if (c.get("cacheWriteTokens") or 0) > 0 and c.get("cacheWrite1hTokens") is None: unsplit = True
                        p += c.get("promptTokens") or 0; r += c.get("cacheReadTokens") or 0
                        w += c.get("cacheWriteTokens") or 0; w1 += c.get("cacheWrite1hTokens") or 0
                        o += c.get("outputTokens") or 0
                    w5 = w - w1; unc = max(p - r - w, 0)
                    usd = (unc * IN + r * READ + w5 * W5 + w1 * W1H + o * OUT) / 1e6
                    total += usd
                    flag = "  (no 1h split reported: writes priced at 5m)" if unsplit else ""
                    print(f"{i:>4} {p:>8} {r:>8} {w5:>8} {w1:>8} {unc:>8} {o:>6} {usd:>8.4f}{flag}")
    print(f"     arm total ${total:.4f}"); grand += total
print(f"all arms ${grand:.4f}")
