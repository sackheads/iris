#!/usr/bin/env bash
# Focused test run that fails when the filter matched nothing (#271).
#
# `swift test --filter` matches TYPE names, not the `@Suite`/`@Test` display strings — and the
# display string is exactly what the test output prints, so the natural copy-paste selects nothing
# and still exits 0 with "Test run with 0 tests in 0 suites passed". A filtered run cited as
# evidence has to have run something; this refuses to report success when it did not.
#
#   scripts/test-filter.sh VibecopUnderAutoApproveTests
#   scripts/test-filter.sh 'ProfilerRecordTests|InjectionGuardCacheTests'
set -uo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <filter-regex> [extra swift test args...]" >&2
    exit 2
fi
filter="$1"; shift

# Streamed through `tee` rather than captured, so a long run still prints as it goes; the copy on
# disk is only there for the zero-test check below. `PIPESTATUS[0]` is swift's own status, not tee's.
log=$(mktemp -t iris-test-filter)
trap 'rm -f "$log"' EXIT
swift test --filter "$filter" "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

if grep -qE 'Test run with 0 tests' "$log"; then
    cat >&2 <<EOF

error: --filter '$filter' matched no tests, so this run proves nothing.
       --filter takes the TYPE name (VibecopUnderAutoApproveTests), not the @Suite or @Test
       display string ("Vibecop under headless auto-approve"). See AGENTS.md, Build and test.
EOF
    exit 1
fi
exit $status
