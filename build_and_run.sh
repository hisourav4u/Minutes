#!/usr/bin/env bash
# build_and_run.sh - builds Minutes with SPM and packages it into a .app bundle.
# Usage:
#   ./build_and_run.sh          # debug build + launch
#   ./build_and_run.sh release  # release build + launch
#   ./build_and_run.sh build    # build only, don't launch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-debug}"
LAUNCH=true
[[ "$MODE" == "build" ]] && { MODE=debug; LAUNCH=false; }

# -- 1. Compile ----------------------------------------------------------------
echo "Building ($MODE)..."
if [[ "$MODE" == "release" ]]; then
    swift build -c release 2>&1
    BINARY=".build/release/Minutes"
else
    swift build 2>&1
    BINARY=".build/debug/Minutes"
fi
echo "Build succeeded"

# -- 2. Assemble the .app bundle -----------------------------------------------
# A real bundle matters here more than usual: microphone and screen-recording
# permissions are granted to a bundle id. Running the bare SPM binary would
# attribute them to your terminal instead.
APP="Minutes.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

cp "$BINARY" "$MACOS/Minutes"
sed "s/\$(EXECUTABLE_NAME)/Minutes/g" \
    "Minutes/Resources/Info.plist" > "$CONTENTS/Info.plist"

echo "App bundle assembled at $APP"

# -- 3. Ad-hoc code signing ----------------------------------------------------
# Sign with a STABLE identity so macOS TCC (Microphone, Screen Recording) keeps
# the grant across rebuilds. Ad-hoc signatures change every build and lose it.
SIGN_ID="${MINUTES_SIGN_ID:-ClipboardManager Dev}"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "Signing with stable identity: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "WARNING: stable identity '$SIGN_ID' not found — ad-hoc signing."
    echo "         Screen Recording / Mic permission will reset on every rebuild."
    codesign --force --deep --sign - "$APP"
fi
echo "Signed"

# -- 4. Launch -----------------------------------------------------------------
if [[ "$LAUNCH" == "true" ]]; then
    pkill -x Minutes 2>/dev/null || true
    sleep 0.3
    echo "Launching $APP..."
    open "$SCRIPT_DIR/$APP"
    echo
    echo "Look for the waveform icon in your menu bar."
    echo "First recording will prompt for Microphone and Screen Recording"
    echo "permissions - grant both, then start the recording again."
fi
