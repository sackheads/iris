#!/usr/bin/env bash
# Tests scripts/eval-append-only.sh (#788). Exits non-zero on the first wrong answer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0

expect() {
    local want="$1" name="$2"; shift 2
    printf '%s\n' "$@" | "$here/eval-append-only.sh" --status >/dev/null
    local got=$?
    if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: exit $got, want $want"; fail=1; fi
}

T=$'\t'
expect 0 "a new result"                  "A${T}eval/results/injection.classifier/2026-10-28-onnx-x-v1-test-full.json"
expect 0 "nothing under eval/results"    "M${T}Sources/IrisKit/iris.swift" "D${T}eval/datasets/injection/v1/README.md"
expect 0 "empty diff"                    ""
expect 1 "a result edited"               "M${T}eval/results/injection.classifier/a.json"
expect 1 "a result deleted"              "D${T}eval/results/injection.classifier/a.json"
expect 1 "a result renamed"              "R100${T}eval/results/injection.classifier/a.json${T}eval/results/injection.classifier/b.json"
expect 1 "a type change"                 "T${T}eval/results/x.json"
expect 1 "one bad among good"            "A${T}eval/results/b.json" "M${T}eval/results/a.json"
exit $fail
