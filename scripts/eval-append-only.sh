#!/usr/bin/env bash
# Fails a change that modifies, deletes or renames a committed eval result (#788). Results are
# append-only (docs/specs/2026-10-28-model-eval-framework.md, section 9): a run adds a file, and a
# wrong result is superseded by a later file that names it, never edited. Adding files is fine.
#
#   scripts/eval-append-only.sh <base-sha> <head-sha>   # diff base...head
#   scripts/eval-append-only.sh --status                # judge `git diff --name-status` lines on stdin
set -uo pipefail

judge() {
    local bad=0 status path rest
    while IFS=$'\t' read -r status path rest; do
        [[ -z "$status" ]] && continue
        # A rename or copy names the old path first; a rename out of eval/results/ is a deletion.
        case "$path" in eval/results/*) ;; *) continue ;; esac
        case "$status" in
            A) ;;
            C*) ;;
            *) echo "eval/results is append-only: $status $path${rest:+ -> $rest}"; bad=1 ;;
        esac
    done
    if (( bad )); then
        echo "Add a new result that supersedes the old one (its \"supersedes\" field) instead."
        return 1
    fi
    return 0
}

if [[ "${1:-}" == "--status" ]]; then
    judge
    exit $?
fi

base="${1:-}" head="${2:-HEAD}"
if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    echo "eval-append-only: no usable base; nothing to check"
    exit 0
fi
git diff --no-renames --name-status "$base...$head" -- eval/results | judge
