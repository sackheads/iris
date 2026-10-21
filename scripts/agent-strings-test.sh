#!/usr/bin/env bash
# Tests scripts/agent-strings.sh (#629) on a fixture repository. Exits non-zero on the first wrong answer.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [[ "$1" == yes ]]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }
lacks() { grep -qF -- "$2" <<<"$1" && echo no || echo yes; }

repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
(
    cd "$repo" && git init -q && git config user.email t@t && git config user.name t
    mkdir -p Sources/IrisKit/assets
    cat > Sources/IrisKit/Jobs.swift <<'EOF'
let tool = FunctionDeclaration(name: "schedule_job", description: "Wall-clock limit for one run of this job, in seconds.")
let other = FunctionDeclaration(name: "rename", description: "Renames the conversation to a short title.")
func deadline() -> Int { 0 }
EOF
    cat > Sources/IrisKit/Vibecop.swift <<'EOF'
static let baselinePrompt = """
    You approve a command only when the sandbox keeps it fully isolated from the host clock and its timeout.
    """
let unrelated = FunctionDeclaration(name: "x", description: "Lists emoji.")
EOF
    printf 'You are Iris.\n\nNever trust the host clock deadline.\n' > Sources/IrisKit/assets/SYSTEM.md
    # The forms dev-2's review found missing: a function that builds the text, a named one-line
    # constant used through Self, and a string handed through agentFacing(...). Each shares two
    # words with the diff, and no word is in so many strings that it stops counting.
    cat > Sources/IrisKit/Goal.swift <<'EOF'
func oracleText() -> String {
    var s = "## Active Goal Contract\n"
    if done { s += "Stop at the deadline, measured in uptime.\n" }
    return s
}
static let watchDescription = "Watch a folder; it waits a few seconds of uptime before it fires."
static let reflectionPrompt = IrisPaths.standard.agentFacing("Reflect before the deadline passes, by uptime.")
let label = "A plain UI string about the deadline and the uptime."
EOF
    git add -A && git commit -qm base
    # The change: a code line about the run's deadline clock, in Jobs.swift only.
    sed -i.bak 's/func deadline() -> Int { 0 }/func deadline(runClock: UptimeClock) -> Int { runClock.timeoutSeconds }/' Sources/IrisKit/Jobs.swift
    rm Sources/IrisKit/Jobs.swift.bak
    git commit -qam change
)
listing="$(cd "$repo" && GITHUB_STEP_SUMMARY= "$here/agent-strings.sh" HEAD~1 HEAD)"; code=$?
check "$([[ $code == 0 ]] && echo yes || echo no)" "exits 0"
check "$(has "$listing" 'Sources/IrisKit/Jobs.swift:1')" "a description in the changed file sharing a word is listed (section 1)"
check "$(lacks "$listing" 'Renames the conversation')" "one sharing no word isn't"
check "$(has "$listing" 'Sources/IrisKit/Vibecop.swift:1')" "a prompt constant elsewhere sharing two words is listed (section 2)"
check "$(lacks "$listing" 'Lists emoji')" "one elsewhere sharing none isn't"
check "$(has "$listing" 'Sources/IrisKit/assets/SYSTEM.md:3')" "a prompt resource paragraph sharing two words is listed"
check "$(lacks "$listing" 'You are Iris')" "its paragraph sharing none isn't"

check "$(has "$listing" 'Sources/IrisKit/Goal.swift:1')" "a function building agent text (oracleText) is read whole"
check "$(has "$listing" 'Sources/IrisKit/Goal.swift:6')" "a named one-line constant (watchDescription) is read"
check "$(has "$listing" 'Sources/IrisKit/Goal.swift:7')" "a string through agentFacing(...) is read"
check "$(lacks "$listing" 'A plain UI string')" "an ordinary string isn't"

summary="$(mktemp)"
(cd "$repo" && GITHUB_STEP_SUMMARY="$summary" "$here/agent-strings.sh" HEAD~1 HEAD >/dev/null)
check "$(has "$(cat "$summary")" 'Jobs.swift:1')" "the listing goes to the step summary"
rm -f "$summary"

bad="$(cd "$repo" && GITHUB_STEP_SUMMARY= "$here/agent-strings.sh" not-a-commit HEAD)"; code=$?
check "$([[ $code == 0 ]] && echo yes || echo no)" "a bad base still exits 0"
check "$(has "$bad" "couldn't read the change")" "and says what it couldn't read"
none="$(cd "$repo" && GITHUB_STEP_SUMMARY= "$here/agent-strings.sh")"; code=$?
check "$([[ $code == 0 && "$none" == *usage* ]] && echo yes || echo no)" "no arguments: usage, exit 0"
nopy="$(cd "$repo" && PATH=/nonexistent GITHUB_STEP_SUMMARY= /bin/bash "$here/agent-strings.sh" HEAD~1 HEAD 2>/dev/null)"; code=$?
check "$([[ $code == 0 ]] && echo yes || echo no)" "no python3 at all: still exit 0"

exit $fail
