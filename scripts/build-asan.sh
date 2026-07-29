#!/bin/bash
#
# Builds SoundFlow.app with AddressSanitizer into build/SoundFlowASan.app.
#
# Why a bundle: TCC attributes the System Audio Recording grant to a code
# identity, and a bare `swift build` binary has none — the HAL then hands back
# zero-filled buffers instead of an error. Same reasoning as scripts/run-spike.sh.
#
# The ASan runtime ships as a dylib inside the toolchain, so it is copied into
# the bundle and the load command repointed at @rpath.

set -euo pipefail

SIGN_ID="SoundFlow Dev"
APP="build/SoundFlowASan.app"
BIN=".build/debug/SoundFlowApp"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "ERROR: signing identity \"$SIGN_ID\" not found. Run ./scripts/setup-signing.sh"
    exit 1
fi

swift build -c debug --product SoundFlowApp --sanitize=address

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/SoundFlowApp"
cp Sources/SoundFlowApp/Resources/Info.plist "$APP/Contents/Info.plist"

# swiftc bakes an absolute rpath to the toolchain's clang runtime directory, so
# the ASan dylib resolves without bundling. Fail loudly if that stops being true
# rather than at launch with a missing-dylib dialog.
if ! otool -l "$APP/Contents/MacOS/SoundFlowApp" | grep -q "lib/clang.*darwin"; then
    echo "ERROR: no toolchain rpath for the ASan runtime; the app will not launch."
    exit 1
fi

codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"

cat <<EOF
Built $APP

Run it with the log captured:
  ASAN_OPTIONS=detect_leaks=0:abort_on_error=0:log_path=/tmp/soundflow-asan \\
    "$APP/Contents/MacOS/SoundFlowApp"

Then exercise: open/close the main window, open/dismiss the menu bar popover,
drag the master slider and a per-app slider.
EOF
