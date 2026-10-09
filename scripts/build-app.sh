#!/bin/zsh
# Build Iris.app from project.yml with xcodebuild and print the .app's location.
#
#   scripts/build-app.sh [Debug|Release] [derived-data-dir]
#
# Debug builds "Iris Dev.app" (com.bnaylor.iris.dev); Release builds "Iris.app" (com.bnaylor.iris).
# Needs the Metal Toolchain, which Xcode no longer ships by default: MLX's shaders are compiled
# into a .metallib by the Xcode build (SwiftPM never does). Install it once with
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
# Before the cd: ${0:A} resolves a relative $0 against the current directory.
source "${0:A:h}/lib.sh"
cd "$(dirname "$0")/.."

config="${1:-Debug}"
case "$config" in
  Debug|Release) ;;
  *) echo "usage: scripts/build-app.sh [Debug|Release] [derived-data-dir]" >&2; exit 64 ;;
esac
tmp="${TMPDIR:-/tmp}"
derived="${2:-${tmp%/}/iris-app-$config}"

# Runs the compiler rather than just locating it, so this fails when the build would.
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Metal Toolchain missing; install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

build_or_die scripts/gen-xcodeproj.sh

# Pin the app build to the same dependency revisions `swift test` used: swift-sdk and llama.swift
# track branch main, so an unpinned xcodebuild could resolve newer commits than the ones the suite
# just ran against. XcodeGen's workspace has no shared SwiftPM resolution yet, so seed it from the
# root Package.resolved and tell xcodebuild not to touch it.
resolved_dir="Iris.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
cp Package.resolved "$resolved_dir/Package.resolved"

# -skipPackagePluginValidation: mlx-swift attaches its CudaBuild build-tool plugin to its targets,
#   and a headless build cannot answer Xcode's "trust this plugin" prompt.
# -skipMacroValidation: mlx-swift-lm's MLXHuggingFaceMacros needs the same trust for macros.
# -disableAutomaticPackageResolution: build from the pinned Package.resolved above, not whatever
#   SwiftPM would re-resolve.
build_or_die xcodebuild build -project Iris.xcodeproj -scheme Iris -configuration "$config" \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution

apps=("$derived/Build/Products/$config/"*.app(N))
(( ${#apps} == 1 )) || { echo "expected one .app in $derived/Build/Products/$config, found ${#apps}" >&2; exit 1; }
echo "${apps[1]}"

if [[ "$config" == "Release" ]]; then
  echo "warning: this is the installed app's identity (com.bnaylor.iris); do not open it before the first real install — it opens ~/.iris and spends the one-time settings import." >&2
fi
