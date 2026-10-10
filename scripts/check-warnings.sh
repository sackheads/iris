#!/usr/bin/env bash
# Builds the package and the test target, and fails on any compiler warning from Sources/ or
# Tests/ (#286). Warnings from dependencies are ignored: they are not ours to fix.
#
# An incremental build only prints warnings for the files it recompiles, so a warning in a file
# that did not change would pass unseen. The script touches every Swift file under Sources/ and
# Tests/ first, which recompiles our own modules (not the dependencies) and makes every warning
# print again.
#
#   scripts/check-warnings.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2

find Sources Tests -name '*.swift' -exec touch {} +

log=$(mktemp -t iris-check-warnings)
trap 'rm -f "$log"' EXIT
swift build --build-tests >"$log" 2>&1
status=$?
if [ $status -ne 0 ]; then
    cat "$log"
    echo "check-warnings: build failed (exit $status)" >&2
    exit $status
fi

# Diagnostics print as `<abs path>:<line>:<col>: warning: ...`; the same one can print more than
# once in a build, so count unique lines.
warnings=$(grep -E "^${root}/(Sources|Tests)/[^:]+:[0-9]+:[0-9]+: warning:" "$log" | sort -u)
if [ -n "$warnings" ]; then
    echo "$warnings" | sed "s#^${root}/##"
    echo "check-warnings: $(echo "$warnings" | wc -l | tr -d ' ') warning(s) in Sources/ or Tests/" >&2
    exit 1
fi
echo "check-warnings: no warnings in Sources/ or Tests/"
