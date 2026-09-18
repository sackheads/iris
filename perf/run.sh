#!/bin/zsh
# The one sanctioned way to execute the perf suites, so every run is comparable:
# release build, the suite files' own repetitions, records under perf/runs/, and a comparison
# against the newest promoted baseline for each suite when one exists.
set -euo pipefail
cd "$(dirname "$0")/.."

FAKE_ONLY=0
PROMOTE=0
for arg in "$@"; do
  case "$arg" in
    --fake-only) FAKE_ONLY=1 ;;
    --promote)   PROMOTE=1 ;;
    *) echo "usage: perf/run.sh [--fake-only] [--promote]" >&2; exit 64 ;;
  esac
done

sha=$(git rev-parse --short HEAD)
dirty=""
git diff --quiet && git diff --cached --quiet || dirty=" (dirty tree: results will be flagged)"
echo "perf: building release at ${sha}${dirty}"
swift build -c release 2>&1 | tail -1
BIN=.build/release/iris

suites=(perf/suites/smoke.json)
if (( ! FAKE_ONLY )); then
  suites+=(perf/suites/ladder.json perf/suites/tool-eagerness.json perf/suites/tool-eagerness-2.json)
fi

mkdir -p perf/runs perf/baselines
run_status=0
for suite in "${suites[@]}"; do
  name=$(basename "$suite" .json)
  echo ""
  echo "perf: running suite ${name}"
  "$BIN" --perf run "$suite" --out perf/runs
  # (om) sorts newest-first by mtime; [1] takes the head without an ls|head pipe under pipefail.
  latest_candidates=(perf/runs/*-"${name}"-*.json(Nom))
  latest=${latest_candidates[1]}
  # (N) makes an unmatched glob expand to nothing instead of zsh erroring with "no matches
  # found"; without the emptiness check, `ls -t` given zero file operands would fall back to
  # listing the current directory instead of reporting no baseline.
  baseline_candidates=(perf/baselines/*-"${name}"-*.json(Nom))
  baseline=${baseline_candidates[1]:-}
  if [[ -n "$baseline" ]]; then
    echo "perf: comparing ${name} against $(basename "$baseline")"
    "$BIN" --perf compare "$baseline" "$latest" || run_status=$?
  else
    echo "perf: no baseline for ${name}; run with --promote to create one"
  fi
  if (( PROMOTE )); then
    cp "$latest" perf/baselines/
    echo "perf: promoted $(basename "$latest")"
  fi
done
exit $run_status
