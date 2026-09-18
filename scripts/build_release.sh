#!/bin/bash
set -e

# Production Release Build & Packaging Script for Iris
# Usage: ./scripts/build_release.sh [version_tag] [--publish]

VERSION="${1:-v0.1.0}"
PUBLISH_FLAG="$2"
BUILD_DIR=".build/release"
APP_NAME="Iris"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-${VERSION}-macOS.zip"

echo "=== Building Production Release ${VERSION} ==="

# 1. Compile release binary
echo "Compiling release binary with SPM..."
swift build -c release

# 2. Assemble .app bundle structure
echo "Assembling ${APP_NAME}.app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/iris" "${APP_BUNDLE}/Contents/MacOS/iris"

# Copy bundled assets if present
if [ -d "Sources/iris/assets" ]; then
    cp -R Sources/iris/assets/* "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
fi

# Write Info.plist
cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>iris</string>
    <key>CFBundleIdentifier</key>
    <string>com.bnaylor.iris</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Iris</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION#v}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 3. Code Signing
# CODESIGN_IDENTITY wins; otherwise the first Developer ID Application identity in the keychain;
# otherwise ad-hoc ("-"), which works but re-prompts for Keychain access after every rebuild.
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "${SIGNING_IDENTITY}" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
echo "Signing app bundle with identity '${SIGNING_IDENTITY}'..."
codesign --force --deep --options runtime -s "${SIGNING_IDENTITY}" "${APP_BUNDLE}"

# 4. Packaging ZIP & SHA256 Checksum
echo "Packaging release zip..."
(cd "${BUILD_DIR}" && zip -r -q "${ZIP_NAME}" "${APP_NAME}.app")
shasum -a 256 "${BUILD_DIR}/${ZIP_NAME}" > "${BUILD_DIR}/${ZIP_NAME}.sha256"

echo "=== Release Build Complete ==="
echo "Artifact: ${BUILD_DIR}/${ZIP_NAME}"
echo "Checksum: ${BUILD_DIR}/${ZIP_NAME}.sha256"

# 5. Optional GitHub Release Publication
if [ "${PUBLISH_FLAG}" = "--publish" ] || [ "${PUBLISH}" = "1" ]; then
    if command -v gh >/dev/null 2>&1; then
        echo "Publishing release ${VERSION} to GitHub..."
        NOTES_ARG=()
        if [ -n "${RELEASE_NOTES}" ]; then
            NOTES_ARG=(--notes "${RELEASE_NOTES}")
        elif [ -f "RELEASE_NOTES.md" ]; then
            NOTES_ARG=(--notes-file "RELEASE_NOTES.md")
        elif [ -f "docs/RELEASE_NOTES.md" ]; then
            NOTES_ARG=(--notes-file "docs/RELEASE_NOTES.md")
        else
            NOTES_ARG=(--generate-notes)
        fi

        gh release create "${VERSION}" "${BUILD_DIR}/${ZIP_NAME}" "${BUILD_DIR}/${ZIP_NAME}.sha256" \
            --title "Iris ${VERSION}" "${NOTES_ARG[@]}"
    else
        echo "Warning: gh CLI not installed. Skipping automatic GitHub release creation."
    fi
fi
