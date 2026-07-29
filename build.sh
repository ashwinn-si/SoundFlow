#!/bin/bash
set -euo pipefail

SIGN_ID="SoundFlow Dev"
BUILD_DIR=".build/release"
APP_DIR="build/SoundFlow.app"
DMG_NAME="SoundFlow.dmg"
STAGING_DIR="build/dmg_staging"

# ── Signing identity check ──────────────────────────────────────────
# An ad-hoc signature makes TCC revoke the audio-capture grant on every
# rebuild (the cdhash changes). Refuse to build without a real identity.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "ERROR: code-signing identity \"$SIGN_ID\" not found."
    echo
    echo "Run ./scripts/setup-signing.sh first. Without a stable signature,"
    echo "macOS revokes the System Audio Recording permission on every rebuild."
    exit 1
fi

echo "=== Building SoundFlowApp (Release) ==="
swift build -c release --product SoundFlowApp

echo "=== Assembling SoundFlow.app Bundle ==="
rm -rf build
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/SoundFlowApp" "$APP_DIR/Contents/MacOS/SoundFlowApp"
cp "Sources/SoundFlowApp/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "Sources/SoundFlowApp/Resources/AppIcon.icns" ]; then
    cp "Sources/SoundFlowApp/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# SwiftPM emits a resource bundle next to the binary when the target declares
# resources. It has no Info.plist, so codesign rejects it as a bundle — copy the
# icon straight into Resources instead and skip the wrapper entirely.
if [ -f "$BUILD_DIR/SoundFlow_SoundFlowApp.bundle/AppIcon.icns" ]; then
    cp "$BUILD_DIR/SoundFlow_SoundFlowApp.bundle/AppIcon.icns" \
       "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "=== Signing with \"$SIGN_ID\" ==="
# --deep is deprecated and would sign nested items with the outer bundle's
# options; there is no nested code here, so a plain signature is correct.
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP_DIR"

echo "=== Verifying signature ==="
codesign --verify --strict "$APP_DIR"
if codesign -dv --verbose=4 "$APP_DIR" 2>&1 | grep -q "flags=.*adhoc"; then
    echo "ERROR: bundle is still ad-hoc signed. TCC will not persist across rebuilds."
    exit 1
fi
echo "Designated Requirement:"
codesign -d -r- "$APP_DIR" 2>&1 | sed 's/^/  /'

echo "=== Creating DMG ==="
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_NAME"
hdiutil create -volname "SoundFlow" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_NAME" >/dev/null

rm -rf "$STAGING_DIR"

cat <<EOF

=== Done! Created $DMG_NAME ===

To run:  open build/SoundFlow.app

The signature is stable across rebuilds, so the System Audio Recording
grant in System Settings -> Privacy & Security only needs to be given once.
EOF
