#!/bin/zsh
# Build, sign, and launch the debug app: the day-to-day replacement for `swift run`.
# `swift run` ad-hoc signs each rebuild, so macOS asks for Keychain access again every time the
# code changes; signing with a stable Developer ID makes one "Always Allow" stick.
#
#   scripts/run-dev.sh [extra iris arguments]
set -euo pipefail
# Before the cd: ${0:A} resolves a relative $0 against the current directory.
source "${0:A:h}/lib.sh"
cd "$(dirname "$0")/.."
build_or_die swift build
scripts/sign.sh .build/debug/iris
# Dev builds live in ~/.iris-dev. Whenever it is missing or empty, this copies the installed
# app's home and secrets into it.
# Exit 3 means nothing to seed (no ~/.iris yet, e.g. a fresh machine) — fine, dev launches empty.
# Any other non-zero exit aborts here: launching anyway would populate ~/.iris-dev itself and the
# seeder refuses a non-empty destination, so a later retry could never seed at all.
# An empty ~/.iris-dev is seeded too. One with content but no seed marker was made by something
# else (a `swift run` first): say so once, and launch it as it is.
dev_home="$HOME/.iris-dev"
if [[ ! -e "$dev_home" ]] || [[ -d "$dev_home" && -z "$(ls -A "$dev_home")" ]]; then
  seed_output=$(.build/debug/iris --seed-dev-home 2>&1) && seed_rc=0 || seed_rc=$?
  echo "$seed_output"
  if [[ $seed_rc -ne 0 && $seed_rc -ne 3 ]]; then
    echo "not launching dev: seeding failed (see above)" >&2
    exit 1
  fi
elif [[ -e "$HOME/.iris" && ! -e "$dev_home/.seeded-from-release" ]]; then
  echo "~/.iris-dev was not seeded from ~/.iris; to start over: rm -rf ~/.iris-dev && scripts/run-dev.sh"
fi
exec .build/debug/iris "$@"
