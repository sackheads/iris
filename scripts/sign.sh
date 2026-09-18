#!/bin/zsh
# Sign a binary or .app bundle with a stable identity so macOS stops re-prompting for Keychain
# access after every rebuild. Keychain ACLs are keyed on the code signature; SwiftPM ad-hoc
# signs every build differently, which is why `swift run` and freshly built perf binaries prompt.
#
#   scripts/sign.sh <path> [--hardened]
#
# Identity: $CODESIGN_IDENTITY if set, else the first "Developer ID Application" identity in the
# keychain. With neither, the ad-hoc signature is left in place and this prints why (exit 0).
# --hardened adds the hardened runtime (used for the release bundle); dev/perf binaries are signed
# without it so the llama/ggml dynamic libraries keep loading.
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
  echo "sign: no Developer ID Application identity in the keychain and CODESIGN_IDENTITY unset; leaving the ad-hoc signature (macOS will prompt for Keychain access once per rebuild)"
  exit 0
fi

opts=(--force --sign "$identity" --timestamp=none)
(( hardened )) && opts+=(--options runtime)
[[ -d "$target" ]] && opts+=(--deep)
codesign "${opts[@]}" "$target"
echo "sign: signed $(basename "$target") with '$identity'"
