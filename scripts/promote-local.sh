#!/bin/zsh
# Promote a locally-built Release Iris to your daily driver — without cutting a formal release.
#
#   scripts/promote-local.sh [--dry-run] [--no-launch] [--dest DIR] [--version X] [--force]
#
# Builds the Release config from the CURRENT source tree and installs it as the real app at
# DEST/Iris.app (default /Applications), then relaunches it. The app uses ~/.iris (your real
# data), because Release is the installed app's identity (com.bnaylor.iris).
#
# It only ever REPLACES an existing install: it refuses unless DEST/Iris.app is already there
# (--force overrides), because the first install must be a real install — launching a local
# Release on a machine that never installed Iris spends the one-time settings import wrongly.
#
# Order is build -> stage -> quit -> atomic swap -> relaunch, so a failed build or copy never
# leaves you with no app and the running app is down only for the swap. A running Iris is quit
# gracefully (never force-killed, so a Keychain/SecurityAgent prompt is never interrupted); if it
# will not quit, this aborts rather than kill it.
#
# The build is stamped with a Sparkle-safe local version (0.0.0-local.<sha>[-dirty], override with
# --version) and a date-based build number, high enough that the appcast never replaces it.
set -euo pipefail
source "${0:A:h}/lib.sh"
cd "${0:A:h}/.."

dry=0; launch=1; dest="/Applications"; version=""; force=0
while (( $# )); do
  case "$1" in
    --dry-run)   dry=1 ;;
    --no-launch) launch=0 ;;
    --force)     force=1 ;;
    --dest)      dest="${2:?--dest needs a directory}"; shift ;;
    --version)   version="${2:?--version needs a value}"; shift ;;
    -h|--help)   sed -n '2,20p' "${0:A}"; exit 0 ;;
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
staging="${dest%/}/Iris.app.promote-tmp"
note=""; (( dry )) && note="  (dry-run)"

echo "promote-local: version=$marketing build=$buildno -> $app_dest$note"

# First-install guard: only ever replace an existing install. AGENTS.md: never launch a local
# Release before the first real install — it spends the one-time settings import (AppDefaultsImport)
# a fresh install is meant to get once. --force skips this.
if [[ ! -d "$app_dest" && $force -eq 0 ]]; then
  echo "promote-local: no existing install at $app_dest — this script only REPLACES an already-installed Iris, because the first install must be a real install (so the one-time settings import is spent once). Re-run with --force only if you intend a local Release to be the first app that opens ~/.iris." >&2
  exit 1
fi

# 1. Build the Release config with the stamped version. The running/installed app is untouched, so
#    a build failure here never leaves you without an app.
if (( dry )); then
  echo "+ IRIS_MARKETING_VERSION=$marketing IRIS_BUILD_VERSION=$buildno scripts/build-app.sh Release"
  built="<release-app-path>"
else
  echo "building Release (a few minutes; the running app is left alone)..."
  # Capture build output and status without letting errexit abort before we can report it. build
  # happens before any quit/install, so a failure here leaves the running/installed app untouched.
  set +e
  out=$(IRIS_MARKETING_VERSION="$marketing" IRIS_BUILD_VERSION="$buildno" scripts/build-app.sh Release)
  rc=$?
  set -e
  if (( rc != 0 )); then
    echo "$out" >&2
    echo "promote-local: build failed (exit $rc) — your running app was NOT touched and nothing was installed. The full build log is above. Known Xcode-build failures: a corrupt xcframework artifact extraction (build-app.sh now self-heals this, #950) and the SwiftSyntax/MLXHuggingFaceMacros macro-plugin error on a fresh worktree (#945)." >&2
    exit 1
  fi
  built="${out##*$'\n'}"
  [[ -d "$built" ]] || { echo "promote-local: build produced no .app (got: ${built:-<empty>}) — app not touched." >&2; exit 1; }
fi

# 2. Stage the new app next to the destination (ditto preserves the signature). Still not touching
#    the installed/running app, so a copy failure here also leaves your current app intact.
if (( dry )); then
  echo "+ rm -rf '$staging' && ditto '$built' '$staging'"
else
  rm -rf "$staging"
  ditto "$built" "$staging"
fi

# 3. Quit a running release Iris gracefully, now that the new build is staged. Never SIGKILL — a
#    Keychain/SecurityAgent prompt must not be interrupted (#578). `pgrep -x Iris` matches only the
#    release binary, not the dev build "Iris Dev" or the bare `iris`.
if pgrep -x Iris >/dev/null 2>&1; then
  if (( dry )); then
    echo "+ osascript -e 'tell application \"Iris\" to quit'   # then wait for exit"
  else
    echo "quitting running Iris..."
    osascript -e 'tell application "Iris" to quit' >/dev/null 2>&1 || true
    for _ in {1..40}; do pgrep -x Iris >/dev/null 2>&1 || break; sleep 0.5; done
    if pgrep -x Iris >/dev/null 2>&1; then
      echo "Iris did not quit (a dialog may be open — e.g. a Keychain prompt). Quit it by hand and re-run; not force-killing. Staged build is at $staging." >&2
      exit 1
    fi
  fi
fi

# 4. Atomic swap: the destination is absent only between two renames (microseconds), and the old
#    app is kept as .old until the new one is in place.
if (( dry )); then
  echo "+ mv '$app_dest' '$app_dest.old' (if present); mv '$staging' '$app_dest'; rm -rf '$app_dest.old'"
else
  rm -rf "$app_dest.old"
  if [[ -d "$app_dest" ]]; then mv "$app_dest" "$app_dest.old"; fi
  mv "$staging" "$app_dest"
  rm -rf "$app_dest.old"
  codesign --verify "$app_dest" 2>/dev/null || echo "warning: codesign verify reported issues on $app_dest" >&2
fi

# 5. Relaunch.
if (( launch )); then
  if (( dry )); then echo "+ open '$app_dest'"; else open "$app_dest"; fi
fi

done_note=""; (( dry )) && done_note=" (dry-run; nothing changed)"
echo "promote-local: done$done_note."
