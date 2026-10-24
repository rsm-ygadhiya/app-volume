#!/bin/bash
# Build AppVolume.app from the SwiftPM executable, bundle Info.plist +
# entitlements, and ad-hoc codesign it (required for the audio-recording
# permission prompt to work).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AppVolume"
BUNDLE="$APP_NAME.app"
BIN_NAME="AppVolumeMixer"

echo "==> Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"

echo "==> Assembling $BUNDLE…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$BIN_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "==> Codesigning (ad-hoc)…"
codesign --force --deep --sign - \
    --entitlements AppVolume.entitlements \
    --options runtime \
    "$BUNDLE"

echo "==> Done: $(pwd)/$BUNDLE"
echo "    Launch with:  open \"$(pwd)/$BUNDLE\""
