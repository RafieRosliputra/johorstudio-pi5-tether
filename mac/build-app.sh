#!/usr/bin/env bash
# Build "JohorStudio Tether.app" and install it to /Applications.
# Needs Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="JohorStudio Tether.app"
echo "==> Building (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/JSTether"
rm -rf "build/$APP"
mkdir -p "build/$APP/Contents/MacOS"
cp "$BIN" "build/$APP/Contents/MacOS/JSTether"
cp Info.plist "build/$APP/Contents/Info.plist"
codesign --force --deep --sign - "build/$APP"

echo "==> Installing to /Applications"
pkill -x JSTether 2>/dev/null || true
rm -rf "/Applications/$APP"
cp -R "build/$APP" /Applications/
open "/Applications/$APP"
echo "Done. Look for the camera icon in the menu bar."
