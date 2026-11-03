#!/usr/bin/env bash
# Tests the filter of scripts/check-warnings.sh (#902): a coloured diagnostic must count. Exits
# non-zero on the first wrong answer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fail=0
esc=$'\x1b'
tmp=$(mktemp -t iris-check-warnings-test)
trap 'rm -f "$tmp"' EXIT

# expect <exit status wanted> <name> <log line>...
expect() {
    local want="$1" name="$2"; shift 2
    printf '%s\n' "$@" >"$tmp"
    "$here/check-warnings.sh" --filter-log "$tmp" >/dev/null 2>&1
    local got=$?
    if [[ $got -eq $want ]]; then echo "ok   $name"; else echo "FAIL $name: exit $got, want $want"; fail=1; fi
}

plain="$root/Tests/irisTests/A.swift:3:5: warning: initialization of immutable value 'x' was never used"
colour="$root/Tests/irisTests/A.swift:3:5: ${esc}[1;33mwarning: ${esc}[1;39minitialization of immutable value 'x' was never used${esc}[0;0m"
colour_path="${esc}[1m$root/Sources/IrisKit/B.swift:9:1: ${esc}[0m${esc}[1;33mwarning: ${esc}[0mc"
dep="$root/.build/checkouts/Dep/Sources/D.swift:1:1: warning: deprecated"

expect 0 "clean log"                      "Build complete!"
expect 1 "a plain warning"                "$plain"
expect 1 "a coloured warning (the #902 miss)" "$colour"
expect 1 "a coloured path and warning"    "$colour_path"
expect 0 "a dependency's warning"         "$dep"
expect 1 "the same warning twice counts once, still fails" "$plain" "$plain"
exit $fail
