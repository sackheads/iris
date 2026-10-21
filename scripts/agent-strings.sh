#!/usr/bin/env bash
# Lists the agent-facing strings a change may have made untrue (#629, docs/specs/2026-10-18-agent-strings-listing.md).
#
#   scripts/agent-strings.sh <base> <head>
#
# Prints, for the reviewer, the tool descriptions, prompt constants and prompt resources in the files
# the change touched that share a word with its diff, then the few elsewhere that share the most.
# It decides nothing and never fails: whatever it can't read, it says so and exits 0, so it is never
# switched off for crying wolf (#198). In CI the listing also goes to $GITHUB_STEP_SUMMARY.
set -u
python3 -I - "$@" <<'PY' || echo "agent-strings: the listing itself failed; nothing to show."
import math, os, re, subprocess, sys

SECTION1_CAP = 40
SECTION2_CAP = 10
COMMON_SHARE = 12
SHORT_WORDS = {"vm", "ask", "job", "url", "cli", "key", "run", "git", "ssh", "pid"}
STOP = set("""
return guard self string strings true false else func static private public internal final class
struct enum case cases default break continue await async throws throw where some none init let var
with from that this have will your into when then what which their there them they been were also
only each more most must should would could just than such very much many like over under after
before about above below being does done doing make made using used uses value values type types
optional bool int double count index items item first last line lines text data name names path
paths file files test tests expect require issue print description
""".split())

def out(lines):
    text = "\n".join(lines) + "\n"
    sys.stdout.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        try:
            with open(summary, "a") as f: f.write(text)
        except OSError:
            pass

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout

def split_words(text):
    words = set()
    for ident in re.findall(r"[A-Za-z][A-Za-z0-9_]*", text):
        for part in re.split(r"_+", ident):
            for w in re.findall(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+", part):
                w = w.lower()
                if w.isdigit() or w in STOP: continue
                if len(w) >= 4 or w in SHORT_WORDS: words.add(w)
    return words

def line_of(text, offset):
    return text.count("\n", 0, offset) + 1

LITERAL = r'"""\n(.*?)\n\s*"""|"((?:[^"\\\n]|\\.)*)"'
DESCRIPTION = re.compile(r'description:\s*(?:' + LITERAL + ')', re.S)
# A constant named for what it holds (`baselinePrompt`, `watchDescription`, `downgradePrompt`), one
# line or many, direct or through a helper (`agentFacing(...)`): its first literal.
NAMED_CONST = re.compile(r'(?:let|var)\s+\w*(?:Prompt|Text|Description)\b[^=\n]*=[^"\n]*(?:' + LITERAL + ')', re.S)
# A string handed to the model through `agentFacing(...)` anywhere (#735 review of #745).
AGENT_FACING = re.compile(r'agentFacing\(\s*(?:' + LITERAL + ')', re.S)
# A function that builds one (`oracleText()`, `searchMemoryDescription(isPinned:)`): every literal in its body.
NAMED_FUNC = re.compile(r'func\s+\w*(?:Prompt|Text|Description)\s*\([^{]*\{')
ANY_LITERAL = re.compile(LITERAL, re.S)

def body_of(text, open_brace):
    """The text from `open_brace` to its matching `}`, skipping braces inside string literals."""
    depth, i, n = 0, open_brace, len(text)
    while i < n:
        if text.startswith('"""', i):
            end = text.find('"""', i + 3); i = n if end < 0 else end + 3; continue
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            i = j + 1; continue
        if c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0: return text[open_brace:i + 1]
        i += 1
    return text[open_brace:]

def strings_in(path, text):
    found = []
    if path.endswith(".swift"):
        seen = set()
        def add(start, literal):
            line = line_of(text, start)
            if literal and (line, literal) not in seen:
                seen.add((line, literal)); found.append((path, line, literal))
        for pattern in (DESCRIPTION, NAMED_CONST, AGENT_FACING):
            for m in pattern.finditer(text):
                add(m.start(), m.group(1) or m.group(2))
        for m in NAMED_FUNC.finditer(text):
            body = body_of(text, m.end() - 1)
            joined = " ".join((l.group(1) or l.group(2) or "") for l in ANY_LITERAL.finditer(body))
            add(m.start(), joined.strip())
    elif path.endswith(".md"):
        offset = 0
        for para in re.split(r"\n\s*\n", text):
            start = text.find(para, offset)
            offset = max(offset, start + len(para))
            if para.strip(): found.append((path, line_of(text, start), para))
    return found

def agent_facing(path):
    if not path.startswith("Sources/IrisKit/"): return False
    if path.endswith(".swift"): return True
    name = os.path.basename(path)
    return path.startswith("Sources/IrisKit/assets/") and (name in ("SYSTEM.md", "EVALUATOR.md") or name.endswith("-SKILL.md"))

def preview(text):
    flat = " ".join(text.split())
    return flat if len(flat) <= 160 else flat[:157] + "..."

def main():
    if len(sys.argv) != 3:
        out(["agent-strings: usage: scripts/agent-strings.sh <base> <head>; nothing listed."]); return
    base, head = sys.argv[1], sys.argv[2]
    try:
        changed = [p for p in git("diff", "--name-only", f"{base}...{head}").split("\n") if p]
        diff = git("diff", "-U0", f"{base}...{head}", "--", "Sources/")
        tracked = [p for p in git("ls-tree", "-r", "--name-only", head, "--", "Sources/IrisKit").split("\n") if p]
    except subprocess.CalledProcessError as e:
        out([f"agent-strings: couldn't read the change {base}...{head} ({(e.stderr or '').strip() or e}); nothing listed."]); return
    # Code and string literals, not comments: a long comment's prose matched almost every
    # description (81 on #735), and what a change does is in its identifiers and its strings.
    changed_lines = [re.sub(r"(^|\s)//.*$", "", l[1:]) for l in diff.split("\n")
                     if (l.startswith("+") or l.startswith("-")) and not l.startswith(("+++", "---"))]
    diff_words = split_words("\n".join(changed_lines))
    candidates = [p for p in tracked if agent_facing(p)]
    if not diff_words:
        out(["### Agent-facing strings this change may touch", "", "No changed lines under `Sources/`, so nothing to list."]); return

    unreadable, all_strings = [], []
    changed_set = set(changed)
    for path in candidates:
        try:
            text = git("show", f"{head}:{path}")
        except subprocess.CalledProcessError:
            unreadable.append(path); continue
        all_strings += [(p, line, s, split_words(s)) for (p, line, s) in strings_in(path, text)]
    # A word in more than a twelfth of all the strings ("model", "run", "read") tells none of them
    # apart, so it doesn't count as shared: on #735 it was most of the listing. The rest are
    # weighted by rarity, so a long description sharing many middling words doesn't top every list.
    df = {}
    for (_, _, _, words) in all_strings:
        for w in words: df[w] = df.get(w, 0) + 1
    common = {w for w, n in df.items() if n > max(5, len(all_strings) // COMMON_SHARE)}
    near, far = [], []
    for (p, line, s, words) in all_strings:
        shared = (words & diff_words) - common
        if not shared: continue
        score = sum(math.log(len(all_strings) / df[w]) for w in shared)
        (near if p in changed_set else far).append((score, p, line, s, sorted(shared)))

    near.sort(key=lambda r: (-r[0], r[1], r[2]))
    far = sorted([r for r in far if len(r[4]) >= 2], key=lambda r: (-r[0], r[1], r[2]))
    lines = ["### Agent-facing strings this change may touch (#198)", "",
             "Each shares a word with this diff. Read it: is it still true? Nothing here fails the build.", ""]
    lines.append(f"**In files this change touched** ({len(near)}):")
    if not near: lines.append("- none")
    for (n, p, line, s, shared) in near[:SECTION1_CAP]:
        lines.append(f"- `{p}:{line}` ({', '.join(shared)}): {preview(s)}")
    if len(near) > SECTION1_CAP: lines.append(f"- … and {len(near) - SECTION1_CAP} more, not shown")
    lines += ["", f"**Elsewhere, sharing two or more words** ({min(SECTION2_CAP, len(far))} of {len(far)}):"]
    if not far: lines.append("- none")
    for (n, p, line, s, shared) in far[:SECTION2_CAP]:
        lines.append(f"- `{p}:{line}` ({', '.join(shared)}): {preview(s)}")
    if unreadable:
        lines += ["", "Couldn't read: " + ", ".join(f"`{p}`" for p in unreadable)]
    out(lines)

try:
    main()
except Exception as e:  # never fail the build (#198)
    out([f"agent-strings: stopped on an error it didn't expect ({type(e).__name__}: {e}); nothing more listed."])
PY
exit 0
