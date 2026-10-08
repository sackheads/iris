#!/bin/zsh
# Cut an Iris release: archive → Developer ID sign → notarize → staple → DMG → notarize DMG
# → Sparkle EdDSA sign → GitHub Release → prepend an <item> to appcast.xml on gh-pages.
#
#   scripts/release.sh 1.2.3            full release
#   scripts/release.sh 1.2.3 --dry-run  everything up to the DMG + appcast item; no tag, no
#                                       release, no appcast push (notarization DOES run)
#
# Versioning: CFBundleShortVersionString = the version given; CFBundleVersion (what Sparkle
# compares) = `git rev-list --count HEAD`, monotonic on main. Both are xcodebuild overrides.
#
# Identity: $CODESIGN_IDENTITY if set (must name team RMKGLPG4K4, or be the generic "Developer ID
# Application"), else the first "Developer ID Application: ... (RMKGLPG4K4)" identity in the
# keychain. Notary profile: $NOTARY_PROFILE, default
# iris-notary. Needs the Metal Toolchain (see scripts/build-app.sh).
# One-time setup: docs/releasing.md.
set -euo pipefail
# Before any cd: ${0:A} resolves a relative $0 against the current directory.
source "${0:A:h}/lib.sh"

# --- arguments -----------------------------------------------------------------------------
VERSION="${1:-}"
DRY_RUN=0
usage() { echo "usage: scripts/release.sh MAJOR.MINOR.PATCH [--dry-run]" >&2; exit 64; }
(( $# > 2 )) && usage
case "${2:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) usage ;;
esac
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  usage
fi

# --- constants -----------------------------------------------------------------------------
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PROJECT="$REPO_ROOT/Iris.xcodeproj"
SCHEME="Iris"
INFO_PLIST="$REPO_ROOT/App/Info.plist"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
TEAM_ID="RMKGLPG4K4"
NOTARY_PROFILE="${NOTARY_PROFILE:-iris-notary}"
GH_REPO="sackheads/iris"
FEED_URL="https://sackheads.github.io/iris/appcast.xml"
# The exact Contents/Frameworks listing, as `ls | LC_ALL=C sort | tr '\n' ' '` prints it.
# libswiftCompatibilitySpan.dylib is a weak-linked Swift back-deploy dylib Xcode embeds unprompted.
EXPECTED_FRAMEWORKS="Sparkle.framework libswiftCompatibilitySpan.dylib llama.framework onnxruntime.framework "
TAG="v$VERSION"
DMG_NAME="Iris-$VERSION.dmg"
RELEASE_URL="https://github.com/$GH_REPO/releases/tag/$TAG"
ENCLOSURE_URL="https://github.com/$GH_REPO/releases/download/$TAG/$DMG_NAME"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-release-$VERSION.XXXX")
echo "work dir: $WORK"
DERIVED="$WORK/DerivedData"
ARCHIVE="$WORK/Iris.xcarchive"
EXPORT_DIR="$WORK/export"
APP="$EXPORT_DIR/Iris.app"
DMG="$WORK/$DMG_NAME"
ITEM_FILE="$WORK/item.xml"
PAGES_WT="$WORK/gh-pages"

# A registered worktree must never leak, even on an early failure/exit.
trap 'git -C "$REPO_ROOT" worktree remove --force "$PAGES_WT" 2>/dev/null || true' EXIT

step() { print -P "%F{cyan}==> ${*//\%/%%}%f"; }
die()  { print -P "%F{red}error: ${*//\%/%%}%f" >&2; exit 1; }

cd "$REPO_ROOT"

# --- preconditions -------------------------------------------------------------------------
step "Checking preconditions"
# Runs the compiler rather than just locating it: MLX's shaders are compiled into a .metallib by
# the Xcode build (SwiftPM never does), so the archive fails late without it.
xcrun metal --version >/dev/null 2>&1 \
  || die "Metal Toolchain missing; install it with: xcodebuild -downloadComponent MetalToolchain"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean"
build_or_die "$REPO_ROOT/scripts/gen-xcodeproj.sh"
# Pin the archive to the same dependency revisions `swift test` used: swift-sdk and llama.swift
# track branch main. Every xcodebuild below passes -disableAutomaticPackageResolution.
mkdir -p "$PROJECT/project.xcworkspace/xcshareddata/swiftpm"
cp "$REPO_ROOT/Package.resolved" "$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
git fetch -q origin gh-pages || die "cannot fetch origin/gh-pages (see docs/releasing.md)"
if [[ "${RELEASE_ALLOW_BRANCH:-0}" == "1" ]]; then
  # Dry-run testing from a feature branch only; a real release must never set this.
  (( DRY_RUN )) || die "RELEASE_ALLOW_BRANCH is only honoured with --dry-run"
  echo "RELEASE_ALLOW_BRANCH=1: skipping the main/pushed checks"
else
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "must be on main"
  git fetch -q origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "HEAD is not pushed to origin/main"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
# --exit-code: 2 means no matching ref; anything else non-zero is a failure to ask.
LS_REMOTE_RC=0
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 || LS_REMOTE_RC=$?
case $LS_REMOTE_RC in
  0) die "tag $TAG already exists on origin" ;;
  2) ;;
  *) die "cannot reach origin (git ls-remote exit $LS_REMOTE_RC)" ;;
esac
git rev-parse -q --verify origin/gh-pages >/dev/null || die "origin/gh-pages missing (see docs/releasing.md)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notary profile '$NOTARY_PROFILE' missing (see docs/releasing.md)"
command -v xmllint >/dev/null || die "xmllint not found"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
  [[ "$IDENTITY" == *"($TEAM_ID)"* || "$IDENTITY" == "Developer ID Application" ]] \
    || die "CODESIGN_IDENTITY '$IDENTITY' is not a team $TEAM_ID identity"
else
  # Parsed in zsh rather than piped through head: under pipefail, head closing early can
  # SIGPIPE the producer and fail the assignment.
  IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
  IDENTITY_RE="\"(Developer ID Application: [^\"]*\\($TEAM_ID\\))\""
  for line in "${(@f)IDENTITIES}"; do
    if [[ "$line" =~ $IDENTITY_RE ]]; then IDENTITY="${match[1]}"; break; fi
  done
fi
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity for team $TEAM_ID found; set CODESIGN_IDENTITY"
echo "identity: $IDENTITY"

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null || true)
[[ -n "$PUBLIC_KEY" ]] || die "SUPublicEDKey missing from $INFO_PLIST"

BUILD=$(git rev-list --count HEAD)
echo "version: $VERSION  build: $BUILD  tag: $TAG"

# --- Sparkle tools (from the SPM artifact; resolving packages downloads them) ---------------
step "Resolving packages"
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED" -disableAutomaticPackageResolution -quiet \
  || die "package resolution failed: Package.resolved is out of date with Package.swift; run swift package resolve and commit it (or origin/the network is unreachable)"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "sign_update not found under $SPARKLE_BIN"
KEYCHAIN_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account iris -p 2>/dev/null || true)
[[ "$KEYCHAIN_PUBLIC_KEY" == "$PUBLIC_KEY" ]] \
  || die "EdDSA key in keychain does not match SUPublicEDKey in Info.plist — do NOT ship (see docs/releasing.md)"

# --- archive + export ----------------------------------------------------------------------
step "Archiving $VERSION ($BUILD)"
# arm64 only: MLX and the local engines need Apple Silicon, and an Intel Mac cannot launch the
# app to be offered an update.
# -skipPackagePluginValidation / -skipMacroValidation: mlx-swift's CudaBuild plugin and
# mlx-swift-lm's MLXHuggingFaceMacros need a trust prompt a headless build cannot answer.
build_or_die xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
  -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
  ARCHS=arm64 MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="$IDENTITY"

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" -quiet
[[ -d "$APP" ]] || die "export did not produce $APP"

BUILT_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
[[ "$BUILT_SHORT" == "$VERSION" && "$BUILT_BUILD" == "$BUILD" ]] \
  || die "built app reports $BUILT_SHORT ($BUILT_BUILD), expected $VERSION ($BUILD)"

EXPORTED_FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true)
EXPORTED_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
[[ "$EXPORTED_FEED_URL" == "$FEED_URL" && "$EXPORTED_PUBLIC_KEY" == "$PUBLIC_KEY" ]] \
  || die "exported app is missing or has wrong SUFeedURL/SUPublicEDKey — Sparkle would abort at launch; do NOT ship"

MIN_SYSTEM_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
[[ -n "$MIN_SYSTEM_VERSION" ]] || die "LSMinimumSystemVersion missing from exported app"

ARCHS_BUILT=$(lipo -archs "$APP/Contents/MacOS/Iris") || die "cannot read the architectures of the app binary"
[[ "$ARCHS_BUILT" == "arm64" ]] || die "app binary is '$ARCHS_BUILT', expected exactly arm64"

# Signature checks capture output and match in the shell: `codesign | grep -q` under pipefail
# fails at random when grep exits before codesign finishes writing, and passes when codesign fails.
APP_ENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null) || die "cannot read the app's entitlements"
[[ "$APP_ENTS" == *com.apple.security.app-sandbox* ]] \
  && die "app-sandbox entitlement present — Iris runs user-approved shell commands and must not be sandboxed"
# An allowlist, not a denylist: the toolchain renames test and interop dylibs (lib_TestingInterop,
# libswift_Testing*), and a name we did not think of must not ship. LC_ALL=C pins the sort so the
# comparison does not depend on the release machine's locale.
frameworks=$({ ls "$APP/Contents/Frameworks" 2>/dev/null || true; } | LC_ALL=C sort | tr '\n' ' ')
[[ "$frameworks" == "$EXPECTED_FRAMEWORKS" ]] \
  || die "unexpected Contents/Frameworks: ${frameworks:-<none>}(expected exactly $EXPECTED_FRAMEWORKS)"
stray=$(find "$APP/Contents" \( -name '*.xctest' -o \( -name '*.dylib' \
  -not -path '*/Contents/Frameworks/*.framework/*' \
  -not -path '*/Contents/Frameworks/libswiftCompatibilitySpan.dylib' \) \) -print)
[[ -z "$stray" ]] || die "test or stray dylib artefacts in the app: $stray"
# Team and get-task-allow for every signed piece: the app, everything in Frameworks, and Sparkle's
# nested helpers. A plain `xcodebuild build` injects get-task-allow; export is expected to strip
# it, and notarization rejects it anywhere.
check_signature() {  # check_signature <path>
  local p="$1" sig ents
  sig=$(codesign -dv "$p" 2>&1) || die "${p#$EXPORT_DIR/} is not signed"
  [[ "$sig" =~ $'(^|\n)TeamIdentifier='"$TEAM_ID"$'(\n|$)' ]] \
    || die "${p#$EXPORT_DIR/} is not signed by team $TEAM_ID"
  ents=$(codesign -d --entitlements - "$p" 2>/dev/null) || die "cannot read entitlements of ${p#$EXPORT_DIR/}"
  [[ "$ents" == *get-task-allow* ]] \
    && die "${p#$EXPORT_DIR/} carries com.apple.security.get-task-allow (notarization will reject it)"
  return 0
}
SPARKLE_VERSION_DIR="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
SIGNED_PATHS=(
  "$APP"
  "$APP"/Contents/Frameworks/*(N)
  "$SPARKLE_VERSION_DIR"/Autoupdate(N)
  "$SPARKLE_VERSION_DIR"/Updater.app(N)
  "$SPARKLE_VERSION_DIR"/XPCServices/*.xpc(N)
)
for p in "${SIGNED_PATHS[@]}"; do
  check_signature "$p"
done
codesign --verify --deep --strict "$APP" || die "code signature invalid"

# --- notarize + staple the app -------------------------------------------------------------
notarize() {  # notarize <artifact>
  local artifact="$1" out id result
  out=$(xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$out"
  # No early `exit` in awk: under pipefail it can SIGPIPE the echo and fail the assignment.
  id=$(echo "$out" | awk '/^ *id:/ && id == "" {id = $2} END {print id}')
  result=$(echo "$out" | awk '/^ *status:/{print $2}' | tail -1)
  if [[ "$result" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization of $(basename "$artifact") was not accepted (status: ${result:-unknown})"
  fi
}

step "Notarizing the app"
APP_ZIP="$WORK/Iris-$VERSION-app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP" || die "spctl rejected the stapled app"

# --- DMG -----------------------------------------------------------------------------------
step "Building $DMG_NAME"
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Iris.app"
ln -s /Applications "$STAGE/Applications"
# hdiutil create is flaky immediately after a fresh bundle copy (Spotlight/quarantine hold
# files busy); never pass -quiet, it closes stderr and hides the reason.
DMG_OK=0
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "Iris $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"; then
    DMG_OK=1; break
  fi
  echo "hdiutil create failed (attempt $attempt/5); retrying in 3s" >&2
  sleep 3
done
(( DMG_OK )) || die "hdiutil create failed after 5 attempts"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# --- Sparkle signature + appcast item ------------------------------------------------------
step "Signing the DMG for Sparkle"
SIG_ATTRS=$("$SPARKLE_BIN/sign_update" --account iris "$DMG")      # → sparkle:edSignature="…" length="…"
[[ "$SIG_ATTRS" == *sparkle:edSignature=* ]] || die "sign_update produced no signature: $SIG_ATTRS"
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")

cat > "$ITEM_FILE" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$RELEASE_URL</sparkle:releaseNotesLink>
      <enclosure url="$ENCLOSURE_URL" type="application/octet-stream" $SIG_ATTRS/>
    </item>
EOF

step "Appcast item"
echo "item file: $ITEM_FILE"
cat "$ITEM_FILE"

if (( DRY_RUN )); then
  DRY_RUN_MSG="dry run: not tagging, publishing, or updating the appcast."
  print -P "%F{yellow}${DRY_RUN_MSG//\%/%%}%f"
  echo "artifacts left in: $WORK"
  echo "  app:  $APP"
  echo "  dmg:  $DMG"
  echo "  item: $ITEM_FILE"
  exit 0
fi

# --- publish: tag → release → appcast (the release must exist before the feed points at it) -
step "Tagging $TAG"
git tag -a "$TAG" -m "Iris $VERSION (build $BUILD)"
git push origin "$TAG"

step "Creating GitHub release"
gh release create "$TAG" "$DMG" --repo "$GH_REPO" --title "Iris $VERSION" --generate-notes --verify-tag
# Fail fast if the asset URL Sparkle will fetch is not actually there. GitHub's CDN can take a
# few seconds to make a freshly-uploaded release asset reachable, so retry briefly.
ASSET_OK=0
for _ in 1 2 3; do
  if curl -fsSLI -o /dev/null "$ENCLOSURE_URL"; then ASSET_OK=1; break; fi
  sleep 5
done
(( ASSET_OK )) || die "release asset not reachable at $ENCLOSURE_URL"

step "Updating appcast on gh-pages"
git worktree add -q --detach "$PAGES_WT" origin/gh-pages
(
  cd "$PAGES_WT"
  [[ -f appcast.xml ]] || die "appcast.xml missing on gh-pages"
  [[ -r "$ITEM_FILE" ]] || die "appcast item missing: $ITEM_FILE"
  # Insert the new item before the first existing <item>, or before </channel> if none.
  awk -v itemfile="$ITEM_FILE" '
    !done && ($0 ~ /<item>/ || $0 ~ /<\/channel>/) {
      while ((getline line < itemfile) > 0) print line
      close(itemfile); done = 1
    }
    { print }
  ' appcast.xml > appcast.xml.new
  mv appcast.xml.new appcast.xml
  XMLLINT_OUT=$(xmllint --noout --nonet appcast.xml 2>&1) && [[ -z "$XMLLINT_OUT" ]] \
    || die "appcast.xml failed validation: ${XMLLINT_OUT:-non-zero exit}"
  git add appcast.xml
  git commit -q -m "appcast: $VERSION (build $BUILD)"
  git push -q origin HEAD:gh-pages
)
git worktree remove --force "$PAGES_WT"

step "Done"
echo "release:  $RELEASE_URL"
echo "feed:     $FEED_URL  (Pages may take a minute to refresh)"
echo "dmg:      $DMG"
