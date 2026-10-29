"""Explains every v3 text whose tier-2 input length differs from its dataset length.

    python3 -I eval/runs-789-v3/tier1_lengths.py

Replays tier 1 in Python, step by step: NFKC and the control-character strip
(PromptInjectionGuard.normalize), the role-delimiter strip (stripRecording, then
executeTier1's own pass) and the breakout-tag escape. It then counts the result as Swift
counts a String, in Characters (extended grapheme clusters), and compares that with the
`tier2_chars` the verdict run logged. A text matches when the replay reproduces the logged
length exactly. The cause is the first step that changed its length.
"""
import json, os, re, sys, unicodedata
from collections import Counter

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here))
DS = f"{root}/eval/datasets/injection/v3"
texts = {}
for f in ("benign.jsonl", "attacks.jsonl"):
    for line in open(f"{DS}/{f}"):
        if line.strip():
            r = json.loads(line); texts[r["id"]] = r["text"]
logged = {}
for line in open(f"{here}/verdict-tiers.jsonl"):
    e = json.loads(line); logged[e["id"]] = e["tier2_chars"]

def normalize(s):
    s = unicodedata.normalize("NFKC", s)
    # CharacterSet.controlCharacters (Cc, Cf) minus whitespace and newlines, plus U+200B
    return "".join(c for c in s if not ((unicodedata.category(c) in ("Cc", "Cf") and not c.isspace()) or c == "​"))

guard_patterns = ["system:", "assistant:", "user:", "model:", "---", "###", "<|im_start|>", "<|im_end|>",
                  "Instruction:", "System Prompt:"]
tier1_patterns = ["system:", "assistant:", "user:", "---", "###"]

def remove(p, line):
    if not p[0].isalpha():
        return re.sub(re.escape(p), "", line, flags=re.IGNORECASE)
    return re.sub(r"(?<![A-Za-z0-9_])" + re.escape(p), "", line, flags=re.IGNORECASE)

def strip(s, patterns):
    out = []
    for line in s.split("\n"):
        for p in patterns:
            line = remove(p, line)
        out.append(line)
    return "\n".join(out)

def swift_count(s):
    # Extended grapheme clusters, for the characters these texts hold: CRLF is one Character,
    # and a combining mark, variation selector, emoji skin-tone modifier or ZWJ joins the
    # Character before it.
    n, prev = 0, ""
    for c in s:
        joins = (prev == "\r" and c == "\n") or unicodedata.category(c) in ("Mn", "Me", "Mc") \
            or 0xFE00 <= ord(c) <= 0xFE0F or 0x1F3FB <= ord(c) <= 0x1F3FF \
            or c == "‍" or prev == "‍"
        if not joins or n == 0: n += 1
        prev = c
    return n

causes, unexplained = Counter(), []
examples = {}
for i, raw in sorted(texts.items()):
    steps = [("dataset", raw)]
    s = normalize(raw); steps.append(("NFKC and control strip", s))
    s = strip(s, guard_patterns); steps.append(("role-delimiter strip", s))
    s = strip(s, tier1_patterns); steps.append(("tier 1's own strip", s))
    s = re.sub(re.escape("</untrusted_context>"), "[escaped_tag]", s, flags=re.IGNORECASE); steps.append(("tag escape", s))
    got = swift_count(s)
    if got != logged[i]:
        unexplained.append((i, len(raw), got, logged[i])); continue
    if got == len(raw): continue
    changed = [name for (_, a), (name, b) in zip(steps, steps[1:]) if swift_count(a) != swift_count(b)]
    if swift_count(raw) != len(raw): changed.insert(0, "grapheme count")
    key = " + ".join(changed) or "grapheme count"
    causes[key] += 1
    examples.setdefault(key, (i, len(raw), got))

print(f"replayed tier 1 reproduces the logged length for {len(texts) - len(unexplained)}/{len(texts)} texts")
for key, n in causes.most_common():
    i, a, b = examples[key]
    print(f"- {key}: {n} texts, e.g. `{i}` {a} code points in the dataset, {b} Characters after tier 1")
for i, a, got, want in unexplained:
    print(f"- UNEXPLAINED `{i}`: dataset {a}, replay {got}, logged {want}")
sys.exit(1 if unexplained else 0)
