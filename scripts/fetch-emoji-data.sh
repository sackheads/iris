#!/usr/bin/env bash
set -euo pipefail
# Vendors iamcal/emoji-data emoji.json at a pinned commit. No Node/npm required.
PIN="097705020bcf82331c9ef10df3425aad15f5043c"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Sources/IrisKit/assets/emoji.json"
URL="https://raw.githubusercontent.com/iamcal/emoji-data/${PIN}/emoji.json"
echo "Fetching emoji.json @ ${PIN:0:7} …"
curl -fsSL "$URL" -o "$DEST"
COUNT=$(python3 -c "import json; print(len(json.load(open('$DEST'))))")
echo "Wrote $DEST ($COUNT entries)"
