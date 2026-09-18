#!/bin/zsh
# Build, sign, and launch the debug app: the day-to-day replacement for `swift run`.
# `swift run` ad-hoc signs each rebuild, so macOS asks for Keychain access again every time the
# code changes; signing with a stable Developer ID makes one "Always Allow" stick.
#
#   scripts/run-dev.sh [extra iris arguments]
set -euo pipefail
cd "$(dirname "$0")/.."
# Print the whole build log only when the build fails; a bare `| tail -1` hides the error.
build_or_die() {
  local out
  if ! out=$("$@" 2>&1); then echo "$out"; echo "build failed" >&2; exit 1; fi
  echo "$out" | tail -1
}
build_or_die swift build
scripts/sign.sh .build/debug/iris
exec .build/debug/iris "$@"
