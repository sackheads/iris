#!/bin/zsh
# Sign a dev binary with a stable identity so macOS stops re-prompting for Keychain access after
# every rebuild. Keychain ACLs are keyed on the code signature; SwiftPM ad-hoc signs every build
# differently, which is why `swift run` and freshly built perf binaries prompt. Dev/perf binaries
# only — the release bundle is signed through Xcode's own manual signing (project.yml) instead.
#
#   scripts/sign.sh <path>
#
# Identity: $CODESIGN_IDENTITY if set, else the first "Developer ID Application" identity in the
# keychain. Without either: leave SwiftPM's ad-hoc signature in place and say why (exit 0). Signed
# without the hardened runtime or a secure timestamp so the llama/ggml dynamic libraries keep
# loading and the sign step never waits on Apple's timestamp service.
set -euo pipefail

target="${1:-}"
[[ -n "$target" ]] || { echo "usage: scripts/sign.sh <binary-or-app>" >&2; exit 64; }
[[ -e "$target" ]] || { echo "sign: no such path: $target" >&2; exit 66; }

identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [[ -z "$identity" ]]; then
  echo "sign: no Developer ID Application identity in the keychain and CODESIGN_IDENTITY unset; leaving the ad-hoc signature (macOS will prompt for Keychain access once per rebuild)"
  exit 0
fi

opts=(--force --sign "$identity" --timestamp=none)
[[ -d "$target" ]] && opts+=(--deep)
codesign "${opts[@]}" "$target"
echo "sign: signed $(basename "$target") with '$identity'"
