#!/bin/zsh
# Build, sign, and launch the debug app: the day-to-day replacement for `swift run`.
# `swift run` ad-hoc signs each rebuild, so macOS asks for Keychain access again every time the
# code changes; signing with a stable Developer ID makes one "Always Allow" stick.
#
#   scripts/run-dev.sh [extra iris arguments]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | tail -1
scripts/sign.sh .build/debug/iris
exec .build/debug/iris "$@"
