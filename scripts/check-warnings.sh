#!/usr/bin/env bash
# Builds the package and the test target, and fails on any compiler warning from Sources/ or
# Tests/ (#286). Warnings from dependencies are ignored: they are not ours to fix.
#
# An incremental build only prints warnings for the files it recompiles, so a warning in a file
# that did not change would pass unseen. The script touches every Swift file under Sources/ and
# Tests/ first, which recompiles our own modules (not the dependencies) and makes every warning
# print again.
#
# SwiftPM colours diagnostics whenever the environment says the terminal can (CLICOLOR, COLORTERM,
# TERM), even with the output redirected to a file, and an escape code between `: ` and `warning:`
# defeats the match below: the gate said "no warnings" on a build that printed three (#902). So the
# build is asked not to colour, and the filter strips escapes anyway, since it must not depend on
# that being honoured.
#
#   scripts/check-warnings.sh
#   scripts/check-warnings.sh --filter-log FILE   # only filter an existing build log (the test uses it)
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2

# Diagnostics print as `<abs path>:<line>:<col>: warning: ...`; the same one can print more than
# once in a build, so count unique lines.
filter() {
    sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$1" \
        | grep -E "^${root}/(Sources|Tests)/[^:]+:[0-9]+:[0-9]+: warning:" | sort -u
}

report() {
    local warnings
    warnings=$(filter "$1")
    if [ -n "$warnings" ]; then
        echo "$warnings" | sed "s#^${root}/##"
        echo "check-warnings: $(echo "$warnings" | wc -l | tr -d ' ') warning(s) in Sources/ or Tests/" >&2
        return 1
    fi
    echo "check-warnings: no warnings in Sources/ or Tests/"
}

if [ "${1:-}" = "--filter-log" ]; then
    report "${2:?--filter-log needs a file}"
    exit $?
fi

find Sources Tests -name '*.swift' -exec touch {} +

log=$(mktemp -t iris-check-warnings)
trap 'rm -f "$log"' EXIT
NO_COLOR=1 swift build --build-tests -Xswiftc -no-color-diagnostics >"$log" 2>&1
status=$?
if [ $status -ne 0 ]; then
    cat "$log"
    echo "check-warnings: build failed (exit $status)" >&2
    exit $status
fi

report "$log"
