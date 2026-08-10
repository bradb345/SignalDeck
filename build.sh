#!/bin/bash
# Builds SignalDeck.app without Xcode (Command Line Tools are enough).
#
# TCC (the audio-capture permission) is keyed to the app's code signature and Info.plist,
# so a bare executable will never get permission — it must be a signed .app bundle.
# Ad-hoc signing (-) works for local development. Re-signing with a different identity
# resets the granted permission.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/SignalDeck.app"

# Build for the machine doing the build. Hardcoding arm64 here produced a bundle that an
# Intel Mac refuses to launch at all ("bad CPU type in executable"), which looks exactly like
# the app being broken. Use ./package.sh for a universal binary.
ARCH="${ARCH:-$(uname -m)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling ($ARCH)"
swiftc \
  -O \
  -target "$ARCH-apple-macosx15.0" \
  -swift-version 6 \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework CoreAudioKit \
  -o "$APP/Contents/MacOS/SignalDeck" \
  "$ROOT"/Sources/SignalDeck/*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/SignalDeck.icns" "$APP/Contents/Resources/SignalDeck.icns"
echo "==> Stamping build"
"$ROOT/stamp-build.sh" "$APP"

echo "==> Signing (ad-hoc)"
codesign --force --deep \
  --options runtime \
  --entitlements "$ROOT/Resources/SignalDeck.entitlements" \
  --sign - "$APP"

echo "==> Built $APP"
echo "    Run with: open \"$APP\""
