#!/bin/zsh
# Promote a locally-built Release Iris to your daily driver — without cutting a formal release.
#
#   scripts/promote-local.sh [--dry-run] [--no-launch] [--dest DIR] [--version X]
#
# Builds the Release config from the CURRENT source tree and installs it as the real app at
# DEST/Iris.app (default /Applications), then relaunches it. The app uses ~/.iris (your real
# data), because Release is the installed app's identity (com.bnaylor.iris) — safe after the
# first real install, since the one-time settings import is already spent.
#
# The build is stamped with an identifiable, Sparkle-safe local version: a marketing string of
# "0.0.0-local.<sha>[-dirty]" (override with --version) and a date-based build number, high
# enough that the official appcast never offers to replace your dogfood build. To return to an
# official release, install it by hand.
#
# A running Iris is quit gracefully first (never force-killed, so a Keychain/SecurityAgent prompt
# is never interrupted). If it will not quit on its own, this aborts rather than kill it.
set -euo pipefail
source "${0:A:h}/lib.sh"
cd "${0:A:h}/.."

dry=0; launch=1; dest="/Applications"; version=""
while (( $# )); do
  case "$1" in
    --dry-run)   dry=1 ;;
    --no-launch) launch=0 ;;
    --dest)      dest="${2:?--dest needs a directory}"; shift ;;
    --version)   version="${2:?--version needs a value}"; shift ;;
    -h|--help)   sed -n '2,18p' "${0:A}"; exit 0 ;;
    *) echo "promote-local: unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
dirty=""
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then dirty="-dirty"; fi
marketing="${version:-0.0.0-local.${sha}${dirty}}"
buildno=$(date +%Y%m%d%H%M)
app_dest="${dest%/}/Iris.app"
note=""; (( dry )) && note="  (dry-run)"

echo "promote-local: version=$marketing build=$buildno -> $app_dest$note"

# 1. Quit a running release Iris gracefully. Never SIGKILL — a Keychain/SecurityAgent prompt must
#    not be interrupted (#578). `pgrep -x Iris` matches the release binary exactly, never the dev
#    build "Iris Dev" or the lowercase bare-binary `iris`.
if pgrep -x Iris >/dev/null 2>&1; then
  if (( dry )); then
    echo "+ osascript -e 'tell application \"Iris\" to quit'   # then wait for it to exit"
  else
    echo "quitting running Iris..."
    osascript -e 'tell application "Iris" to quit' >/dev/null 2>&1 || true
    for _ in {1..40}; do pgrep -x Iris >/dev/null 2>&1 || break; sleep 0.5; done
    if pgrep -x Iris >/dev/null 2>&1; then
      echo "Iris did not quit (a dialog may be open — e.g. a Keychain prompt). Quit it by hand and re-run; not force-killing." >&2
      exit 1
    fi
  fi
fi

# 2. Build the Release config with the stamped version. build-app.sh prints the .app path as its
#    last stdout line (IRIS_MARKETING_VERSION / IRIS_BUILD_VERSION are honored there).
if (( dry )); then
  echo "+ IRIS_MARKETING_VERSION=$marketing IRIS_BUILD_VERSION=$buildno scripts/build-app.sh Release"
  built="<release-app-path>"
else
  echo "building Release (this takes a few minutes)..."
  out=$(IRIS_MARKETING_VERSION="$marketing" IRIS_BUILD_VERSION="$buildno" scripts/build-app.sh Release)
  built="${out##*$'\n'}"
  [[ -d "$built" ]] || { echo "build did not yield an .app (got: ${built:-<empty>})" >&2; exit 1; }
fi

# 3. Install to DEST, preserving the signature (ditto, not cp).
if (( dry )); then
  echo "+ rm -rf '$app_dest'"
  echo "+ ditto '$built' '$app_dest'"
else
  echo "installing to $app_dest ..."
  rm -rf "$app_dest"
  ditto "$built" "$app_dest"
  codesign --verify "$app_dest" 2>/dev/null || echo "warning: codesign verify reported issues on $app_dest" >&2
fi

# 4. Relaunch.
if (( launch )); then
  if (( dry )); then echo "+ open '$app_dest'"; else open "$app_dest"; fi
fi

done_note=""; (( dry )) && done_note=" (dry-run; nothing changed)"
echo "promote-local: done$done_note."
