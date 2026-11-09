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
# One derived-data dir per checkout, not one per config: its module and plugin caches hold absolute
# paths, so a dir shared by every worktree was reused with another tree's paths in it (the same
# trap as moving a worktree, see docs/building.md). The hash is of this tree's root; an explicit
# argument still wins.
tree_id="$(print -rn -- "$PWD" | shasum | cut -c1-8)"
derived="${2:-${tmp%/}/iris-app-$config-$tree_id}"
echo "derived data: $derived" >&2

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
# Optional version stamp — scripts/promote-local.sh sets these for Sparkle-safe dogfood builds;
# both are unset in a normal build, so `verargs` is empty and nothing changes.
verargs=()
if [[ -n "${IRIS_MARKETING_VERSION:-}" ]]; then verargs+=("MARKETING_VERSION=$IRIS_MARKETING_VERSION"); fi
if [[ -n "${IRIS_BUILD_VERSION:-}" ]]; then verargs+=("CURRENT_PROJECT_VERSION=$IRIS_BUILD_VERSION"); fi

# Self-heal a corrupt binary-artifact extraction. Xcode sometimes extracts a downloaded
# xcframework (Sparkle, llama, onnxruntime) without its root Info.plist — usually after a
# Package.resolved bump re-extracts the artifacts — and then every build fails with
# "There is no Info.plist found at .../X.xcframework/Info.plist" (#950). We build with
# -disableAutomaticPackageResolution, so xcodebuild reuses the broken extraction instead of
# redoing it. The source zips in the global SwiftPM cache are intact, so removing SourcePackages
# makes the build re-resolve and re-extract them cleanly (an absent SourcePackages is still
# populated from the pinned Package.resolved under that flag). Check for the missing Info.plist
# and clear it before building.
while IFS= read -r xcf; do
  if [[ ! -f "$xcf/Info.plist" ]]; then
    echo "build-app: $xcf has no Info.plist — a corrupt artifact extraction; clearing $derived/SourcePackages so it re-extracts from the global cache." >&2
    rm -rf "$derived/SourcePackages"
    break
  fi
done < <(find "$derived/SourcePackages/artifacts" -type d -name '*.xcframework' 2>/dev/null)

# Resolve the pinned packages into THIS derived-data dir before building. With
# -disableAutomaticPackageResolution the build step fetches nothing, so a tree whose xcodebuild
# state has never held the packages (a fresh worktree's first app build) fails in the macro plugin
# with "Unable to resolve module dependency: 'SwiftSyntax' ... in target 'MLXHuggingFaceMacros'"
# (#945). release.sh does the same step. It must use the same -derivedDataPath as the build:
# resolving into xcodebuild's default location leaves this directory empty. Cheap when warm.
build_or_die xcodebuild -resolvePackageDependencies -project Iris.xcodeproj -scheme Iris \
  -derivedDataPath "$derived" -disableAutomaticPackageResolution -quiet

build_or_die xcodebuild build -project Iris.xcodeproj -scheme Iris -configuration "$config" \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
  "${verargs[@]}"

apps=("$derived/Build/Products/$config/"*.app(N))
(( ${#apps} == 1 )) || { echo "expected one .app in $derived/Build/Products/$config, found ${#apps}" >&2; exit 1; }
echo "${apps[1]}"

if [[ "$config" == "Release" ]]; then
  echo "warning: this is the installed app's identity (com.bnaylor.iris); do not open it before the first real install — it opens ~/.iris and spends the one-time settings import." >&2
fi
