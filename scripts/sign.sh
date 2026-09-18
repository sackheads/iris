#!/bin/zsh
# Sign a binary or .app bundle with a stable identity so macOS stops re-prompting for Keychain
# access after every rebuild. Keychain ACLs are keyed on the code signature; SwiftPM ad-hoc
# signs every build differently, which is why `swift run` and freshly built perf binaries prompt.
#
#   scripts/sign.sh <path> [--hardened]
#
# Identity: $CODESIGN_IDENTITY if set, else the first "Developer ID Application" identity in the
# keychain. Without either:
#   - default (dev/perf binaries): leave SwiftPM's ad-hoc signature in place and say why (exit 0);
#   - --hardened (the release bundle): sign ad-hoc ("-") instead, because a bundle must carry a
#     signature; the release will work but re-prompt for Keychain access after each rebuild.
# --hardened also enables the hardened runtime and a secure timestamp (needed for notarization).
# Dev/perf binaries are signed without either so the llama/ggml dynamic libraries keep loading and
# the sign step never waits on Apple's timestamp service.
set -euo pipefail

target="${1:-}"
[[ -n "$target" ]] || { echo "usage: scripts/sign.sh <binary-or-app> [--hardened]" >&2; exit 64; }
[[ -e "$target" ]] || { echo "sign: no such path: $target" >&2; exit 66; }
hardened=0; [[ "${2:-}" == "--hardened" ]] && hardened=1

identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [[ -z "$identity" ]]; then
  if (( hardened )); then
    identity="-"
    echo "sign: no Developer ID Application identity in the keychain and CODESIGN_IDENTITY unset; signing ad-hoc (macOS will prompt for Keychain access once per rebuild)"
  else
    echo "sign: no Developer ID Application identity in the keychain and CODESIGN_IDENTITY unset; leaving the ad-hoc signature (macOS will prompt for Keychain access once per rebuild)"
    exit 0
  fi
fi

opts=(--force --sign "$identity")
if (( hardened )); then
  opts+=(--options runtime)          # secure timestamp is codesign's default here
else
  opts+=(--timestamp=none)
fi
[[ -d "$target" ]] && opts+=(--deep)
codesign "${opts[@]}" "$target"
echo "sign: signed $(basename "$target") with '$identity'"
