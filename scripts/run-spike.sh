#!/bin/bash
#
# Runs the engine self-test from inside a signed .app bundle.
#
# Why the wrapper: TCC attributes permissions to a code identity. A bare CLI
# built by `swift build` has none, so macOS cannot grant it System Audio
# Recording — and rather than returning an error, the HAL hands back
# zero-filled buffers. The tap looks perfectly healthy and captures silence.
#
# Bundling and signing the CLI gives it a stable identity that can be granted
# once and stays granted across rebuilds.

set -euo pipefail

SIGN_ID="SoundFlow Dev"
APP="build/SoundFlowSpike.app"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "ERROR: signing identity \"$SIGN_ID\" not found. Run ./scripts/setup-signing.sh"
    exit 1
fi

swift build --product SoundFlowSpike

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/SoundFlowSpike "$APP/Contents/MacOS/SoundFlowSpike"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SoundFlowSpike</string>
    <key>CFBundleIdentifier</key>
    <string>com.soundflow.spike</string>
    <key>CFBundleName</key>
    <string>SoundFlowSpike</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>SoundFlowSpike verifies per-application audio capture.</string>
</dict>
</plist>
EOF

codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" 2>/dev/null

echo "Signed: $(codesign -dv --verbose=2 "$APP" 2>&1 | grep Authority | head -1)"
echo

exec "$APP/Contents/MacOS/SoundFlowSpike" "$@"
