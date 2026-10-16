#!/usr/bin/env bash
# Decides whether a CI run needs the build and tests (#535). Prints `code=true` or `code=false`,
# to $GITHUB_OUTPUT when it is set and to stdout either way.
#
#   scripts/ci-changes.sh <base-sha> <head-sha>   # diff base...head
#   scripts/ci-changes.sh --paths                  # classify the paths on stdin, one per line
#
# code=false only when every changed path is documentation. Anything else, including a path this
# script does not know, an empty diff, a zero or missing base, or a git error, is code=true: when
# in doubt, run the tests.
set -uo pipefail

emit() {
    echo "code=$1"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "code=$1" >> "$GITHUB_OUTPUT"; fi
    exit 0
}

# Returns 0 when the path is documentation only. Checked after the never-skip list, so a `.md`
# under Sources/ (a bundled resource the tests read) is never docs.
is_docs() {
    case "$1" in
        Package.swift|Package.resolved|project.yml) return 1 ;;
        Sources/*|Tests/*|App/*|scripts/*|.github/*) return 1 ;;
        docs/*) return 0 ;;
        *.md) return 0 ;;
        assets/*.jpg|assets/*.jpeg|assets/*.png|assets/*.gif|assets/*.svg|assets/*.webp) return 0 ;;
        *) return 1 ;;
    esac
}

classify() {
    local any=0 path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        any=1
        is_docs "$path" || emit true
    done
    [[ $any -eq 1 ]] || emit true   # an empty diff proves nothing
    emit false
}

if [[ "${1:-}" == "--paths" ]]; then
    classify
fi

base="${1:-}"
head="${2:-HEAD}"
# A new branch or a force push has no usable `before`: run everything.
if [[ -z "$base" || "$base" =~ ^0+$ ]]; then emit true; fi

if ! paths="$(git diff --name-only "$base...$head" 2>/dev/null)"; then emit true; fi
classify <<< "$paths"
