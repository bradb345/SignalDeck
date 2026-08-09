#!/bin/bash
# Builds a universal (arm64 + x86_64) SignalDeck.app and packages it as a distributable zip.
#
# Use `./build.sh` for day-to-day development (arm64 only, faster).
# Use this when you want an artifact to move to another Mac or attach to a GitHub release.
#
# IMPORTANT: this produces an *ad-hoc signed* app unless you set SIGN_IDENTITY.
# An ad-hoc app is not notarized, so Gatekeeper will block it on first launch on any
# machine that didn't build it. See README "Installing on another Mac" for the two-click
# workaround. If you have a paid Apple Developer account, set:
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./package.sh
#
# ...and the app can additionally be notarized with `xcrun notarytool`, after which it
# opens with no warnings at all.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/SignalDeck.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

DEPLOYMENT_TARGET="15.0"
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework AVFoundation
            -framework AudioToolbox -framework CoreAudio -framework CoreAudioKit)

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/slices"

for ARCH in arm64 x86_64; do
  echo "==> Compiling $ARCH"
  swiftc -O \
    -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
    -swift-version 6 \
    "${FRAMEWORKS[@]}" \
    -o "$BUILD/slices/SignalDeck-$ARCH" \
    "$ROOT"/Sources/SignalDeck/*.swift
done

echo "==> Merging universal binary"
lipo -create \
  "$BUILD/slices/SignalDeck-arm64" \
  "$BUILD/slices/SignalDeck-x86_64" \
  -output "$APP/Contents/MacOS/SignalDeck"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> Signing ($SIGN_IDENTITY)"
codesign --force --deep \
  --options runtime \
  --timestamp=none \
  --entitlements "$ROOT/Resources/SignalDeck.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# `ditto` is mandatory here. Plain `zip -r` mangles the bundle's symlinks and extended
# attributes, which invalidates the code signature on the receiving machine.
ZIP="$DIST/SignalDeck-$VERSION.zip"
echo "==> Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo
echo "==> Done"
lipo -archs "$APP/Contents/MacOS/SignalDeck" | sed 's/^/    architectures: /'
echo "    app: $APP"
echo "    zip: $ZIP"
