#!/usr/bin/env python3
"""THIRD_PARTY_NOTICES.md: generate it from Package.resolved + the resolved checkouts, or check it (#787).

  third-party-notices.py generate   rewrite the file from .build/checkouts (run `swift package resolve` first)
  third-party-notices.py check      fail when a Package.resolved pin has no section, or one for another version

Options: --resolved FILE, --notices FILE, --checkouts DIR (defaults: the repo's own).
A section's heading is `## <identity> (<version, or revision for a branch pin>)`, so a bumped
dependency fails the check until the file is regenerated and its licence re-read.
"""
import argparse, json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EMOJI_PIN = re.search(r'^PIN="([0-9a-f]{40})"', (ROOT / "scripts" / "fetch-emoji-data.sh").read_text(), re.M).group(1)
# The licence text below is the LICENSE at that pin; moving the pin means re-reading it.
EMOJI_LICENCE = """The MIT License (MIT)

Copyright (c) 2013 Cal Henderson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""
LLAMA_TAG = "b9957"  # llama.swift's binaryTarget; generate fails when it moves
LLAMA_LICENCE = """MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""
LLAMA_HEADING = "llama.cpp (%s)" % LLAMA_TAG
EMOJI_HEADING = "emoji-data (%s)" % EMOJI_PIN[:7]
HEAD = re.compile(r"^## (.+)$", re.M)


def pins(resolved):
    out = []
    for p in json.loads(pathlib.Path(resolved).read_text())["pins"]:
        st = p["state"]
        out.append((p["identity"], p["location"], st.get("version") or st["revision"][:7]))
    return sorted(out, key=lambda t: t[0].lower())


def headings(notices):
    return set(HEAD.findall(pathlib.Path(notices).read_text()))


def check(resolved, notices):
    have = headings(notices)
    missing = ["%s (%s)" % (i, v) for i, _, v in pins(resolved) if "%s (%s)" % (i, v) not in have]
    for h in (EMOJI_HEADING, LLAMA_HEADING):
        if h not in have:
            missing.append(h)
    if missing:
        print("THIRD_PARTY_NOTICES.md has no section for: " + ", ".join(missing), file=sys.stderr)
        print("run scripts/third-party-notices.py generate after `swift package resolve`", file=sys.stderr)
        return 1
    return 0


SKIP_DIRS = {"tests", "test", "examples", "example", "docs", ".git", ".build"}
LICENCE = re.compile(r"(?i)^(licen[cs]e|copying|notice|thirdparty)")


def files_in(roots):
    """Licence, COPYING, NOTICE and ThirdParty files under each root, vendored ones included
    (mlx-swift carries mlx, fmt, json and metal-cpp), minus tests and examples. Identical text
    is listed once. Returns [(label, text)]."""
    seen, out = set(), []
    for root in roots:
        if not root.is_dir():
            continue
        for p in sorted(root.rglob("*")):
            rel = p.relative_to(root)
            if not p.is_file() or not LICENCE.match(p.name) or any(x.lower() in SKIP_DIRS for x in rel.parts[:-1]):
                continue
            text = p.read_text(errors="replace").strip()
            if text and text not in seen:
                seen.add(text)
                out.append((str(rel), text))
    return out


def generate(resolved, notices, checkouts):
    parts = ["""# Third-party notices

Iris itself is MIT-licensed (see [LICENSE](LICENSE)). The release app also contains the software
below, each under its own licence. This file is generated by `scripts/third-party-notices.py` from
`Package.resolved` and the resolved checkouts, and `scripts/third-party-notices.py check` (run by
CI and `scripts/release.sh`) fails when a pinned dependency has no section here. It is copied into
the app's Resources.
"""]
    parts.append("## %s\n\nSource: https://github.com/iamcal/emoji-data, vendored as "
                 "`Sources/IrisKit/assets/emoji.json` (pinned in `scripts/fetch-emoji-data.sh`).\n\n"
                 "### Licence\n\n%s\n" % (EMOJI_HEADING, indent(EMOJI_LICENCE)))
    llama = next((c for c in pathlib.Path(checkouts).iterdir() if c.name.lower() == "llama.swift"), None)
    if llama is not None and "llama-%s-xcframework" % LLAMA_TAG not in (llama / "Package.swift").read_text():
        sys.exit("llama.swift no longer ships llama.cpp %s: update LLAMA_TAG and LLAMA_LICENCE" % LLAMA_TAG)
    parts.append("## %s\n\nSource: https://github.com/ggml-org/llama.cpp, the xcframework llama.swift "
                 "downloads (it carries no licence file of its own).\n\n### LICENSE\n\n%s\n"
                 % (LLAMA_HEADING, indent(LLAMA_LICENCE)))
    for ident, loc, ver in pins(resolved):
        d = next((c for c in pathlib.Path(checkouts).iterdir() if c.name.lower() == ident.lower()), None)
        if d is None:
            sys.exit("no checkout for %s under %s (run `swift package resolve`)" % (ident, checkouts))
        docs = files_in([d, pathlib.Path(checkouts).parent / "artifacts" / ident])
        if not any(not n.lower().startswith("notice") for n, _ in docs):
            sys.exit("no LICENSE file in the checkout of %s" % ident)
        s = "## %s (%s)\n\nSource: %s\n" % (ident, ver, loc.removesuffix(".git"))
        for n, text in docs:
            s += "\n### %s\n\n%s\n" % (n, indent(text))
        parts.append(s)
    pathlib.Path(notices).write_text("\n".join(parts))


def indent(text):
    return "\n".join(("    " + l).rstrip() for l in text.splitlines())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["generate", "check"])
    ap.add_argument("--resolved", default=str(ROOT / "Package.resolved"))
    ap.add_argument("--notices", default=str(ROOT / "THIRD_PARTY_NOTICES.md"))
    ap.add_argument("--checkouts", default=str(ROOT / ".build" / "checkouts"))
    a = ap.parse_args()
    if a.mode == "check":
        sys.exit(check(a.resolved, a.notices))
    generate(a.resolved, a.notices, a.checkouts)
