#!/usr/bin/env bash
# Tests scripts/third-party-notices.py (#787). Exits non-zero on the first wrong answer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/third-party-notices.py"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expect() {
    local want="$1" name="$2"; shift 2
    python3 -I "$tool" "$@" >"$work/out" 2>&1; local got=$?
    if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: exit $got, want $want"; cat "$work/out"; fail=1; fi
}

mkdir -p "$work/checkouts/alpha" "$work/checkouts/Beta"
printf 'MIT alpha licence\n' > "$work/checkouts/alpha/LICENSE"
printf 'Apache beta licence\n' > "$work/checkouts/Beta/LICENSE.txt"
printf 'beta notice\n' > "$work/checkouts/Beta/NOTICE.txt"
mkdir -p "$work/checkouts/alpha/Source/vendored/fmt" "$work/checkouts/alpha/Tests/x"
printf 'vendored fmt licence\n' > "$work/checkouts/alpha/Source/vendored/fmt/LICENSE"
printf 'test fixture licence\n' > "$work/checkouts/alpha/Tests/x/LICENSE"
resolved() { # identity version [identity version ...]
    local first=1 body=""
    while (( $# )); do
        (( first )) || body+=","; first=0
        body+="{\"identity\":\"$1\",\"location\":\"https://example.com/$1.git\",\"state\":{\"revision\":\"0123456789abcdef\",\"version\":\"$2\"}}"
        shift 2
    done
    printf '{"pins":[%s],"version":3}\n' "$body"
}
resolved alpha 1.0.0 beta 2.0.0 > "$work/resolved.json"
args=(--resolved "$work/resolved.json" --notices "$work/notices.md" --checkouts "$work/checkouts")

expect 0 "generate" generate "${args[@]}"
expect 0 "a generated file passes" check "${args[@]}"
grep -q 'Apache beta licence' "$work/notices.md" && grep -q 'beta notice' "$work/notices.md" \
    && echo "ok   licence and NOTICE text are copied" || { echo "FAIL licence and NOTICE text are copied"; fail=1; }

grep -q 'vendored fmt licence' "$work/notices.md" && ! grep -q 'test fixture licence' "$work/notices.md" \
    && echo "ok   vendored licences are copied, test fixtures are not" || { echo "FAIL vendored licences"; fail=1; }
grep -q '^## llama.cpp (' "$work/notices.md" && echo "ok   the llama.cpp section is written" || { echo "FAIL llama.cpp section"; fail=1; }
cp "$work/notices.md" "$work/full.md"
sed -i.bak '/^## llama.cpp/d' "$work/notices.md"
expect 1 "a missing llama.cpp section fails" check "${args[@]}"
cp "$work/full.md" "$work/notices.md"

resolved alpha 1.0.0 beta 2.0.0 gamma 3.0.0 > "$work/resolved.json"
expect 1 "a new dependency with no entry fails" check "${args[@]}"
grep -q 'gamma (3.0.0)' "$work/out" && echo "ok   the failure names it" || { echo "FAIL the failure names it"; fail=1; }

resolved alpha 1.1.0 beta 2.0.0 > "$work/resolved.json"
expect 1 "a bumped version fails" check "${args[@]}"

resolved alpha 1.0.0 beta 2.0.0 > "$work/resolved.json"
sed -i.bak '/^## emoji-data/d' "$work/notices.md"
expect 1 "a missing emoji-data section fails" check "${args[@]}"

resolved alpha 1.0.0 beta 2.0.0 gamma 3.0.0 > "$work/resolved.json"
expect 1 "generate refuses a pin with no checkout" generate "${args[@]}"

# The committed file covers the committed pins.
expect 0 "the repo's own notices cover Package.resolved" check
exit $fail
