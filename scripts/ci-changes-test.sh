#!/usr/bin/env bash
# Tests scripts/ci-changes.sh (#535). Exits non-zero on the first wrong answer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0

expect() {
    local want="$1" name="$2"; shift 2
    local got
    got="$(printf '%s\n' "$@" | GITHUB_OUTPUT= "$here/ci-changes.sh" --paths)"
    if [[ "$got" == "code=$want" ]]; then echo "ok   $name"; else echo "FAIL $name: got $got, want code=$want"; fail=1; fi
}

expect false "docs only"                    README.md docs/jobs.md docs/ipf/spec.md AGENTS.md
expect false "README images"                README.md assets/screenshot_1.jpg
expect true  "docs plus Sources"            README.md Sources/IrisKit/iris.swift
expect true  "Sources only"                 Sources/IrisKit/iris.swift
expect true  "a bundled .md resource"       Sources/IrisKit/assets/library-SKILL.md
expect true  "a test fixture .md"           Tests/irisTests/Fixtures/notes.md
expect true  ".github only"                 .github/workflows/test.yml
expect true  "scripts only"                 scripts/check-warnings.sh
# The never-skip list only decides a .md under it: anything else there is not docs anyway.
expect true  "a .md under .github/"         .github/pull_request_template.md
expect true  "a .md under scripts/"         scripts/README.md
expect true  "a .md under App/"             App/NOTES.md
expect true  "Package.resolved"             Package.resolved
expect true  "project.yml"                  project.yml
expect true  "App/"                         App/Info.plist
expect true  "unknown path"                 perf/suites/basic.json
expect true  "empty diff"                   ""

zero="$(GITHUB_OUTPUT= "$here/ci-changes.sh" 0000000000000000000000000000000000000000 HEAD)"
if [[ "$zero" == "code=true" ]]; then echo "ok   zero base"; else echo "FAIL zero base: got $zero"; fail=1; fi
bad="$(GITHUB_OUTPUT= "$here/ci-changes.sh" not-a-commit HEAD)"
if [[ "$bad" == "code=true" ]]; then echo "ok   git error"; else echo "FAIL git error: got $bad"; fail=1; fi

# A rename out of Sources/ into docs/ is a change to Sources/: both paths must count.
repo="$(mktemp -d)"
(
    cd "$repo" && git init -q && git config user.email t@t && git config user.name t
    mkdir -p Sources/IrisKit/assets docs
    printf 'shipped\n' > Sources/IrisKit/assets/x.md && git add -A && git commit -qm one
    git mv Sources/IrisKit/assets/x.md docs/x.md && git commit -qm two
) >/dev/null 2>&1
renamed="$(cd "$repo" && GITHUB_OUTPUT= "$here/ci-changes.sh" HEAD~1 HEAD)"
rm -rf "$repo"
if [[ "$renamed" == "code=true" ]]; then echo "ok   a resource renamed into docs/"; else echo "FAIL a resource renamed into docs/: got $renamed"; fail=1; fi

exit $fail
