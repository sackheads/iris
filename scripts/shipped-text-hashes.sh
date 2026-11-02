#!/bin/bash
# Prints the SHA-256 (hex) of a bundled asset as a release install leaves it on disk and as a dev
# build does (`~/.iris` spelled `~/.iris-dev`), for ShippedSkills.previousVersions (#864). Run it on
# the text an edit REPLACES, before the edit; the two lines are the same when the text names no home.
# usage: scripts/shipped-text-hashes.sh Sources/IrisKit/assets/<asset>.md
set -euo pipefail
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 <asset file>" >&2; exit 2; }
echo "release  $(shasum -a 256 < "$1" | cut -d' ' -f1)"
# The same rewrite as IrisPaths.agentFacing: `~/.iris` not followed by a name character, or by a
# `.` and then a letter or digit.
echo "dev      $(perl -pe 's{~/\.iris(?![A-Za-z0-9_\-]|\.[A-Za-z0-9])}{~/.iris-dev}g' "$1" | shasum -a 256 | cut -d' ' -f1)"
