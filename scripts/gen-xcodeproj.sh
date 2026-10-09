#!/bin/zsh
# Iris.xcodeproj is generated from project.yml and never committed; edit project.yml instead.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec project.yml --quiet
