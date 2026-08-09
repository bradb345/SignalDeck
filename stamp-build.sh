#!/bin/bash
# Writes the commit a bundle was built from into its Info.plist, as SDGitCommit.
#
#   ./stamp-build.sh path/to/SignalDeck.app
#
# Neither CFBundleShortVersionString nor CFBundleVersion moves between commits, so without
# this two bundles that behave completely differently both report "0.1.1 (2)". The app shows
# whatever lands here under the title in the menu bar panel.
#
# Must run after the Info.plist is copied into the bundle and *before* codesign — editing a
# sealed bundle invalidates its signature.

set -euo pipefail

APP="${1:?usage: stamp-build.sh <path to .app>}"
PLIST="$APP/Contents/Info.plist"
ROOT="$(cd "$(dirname "$0")" && pwd)"

if COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
  # A dirty tree means the binary doesn't correspond to any commit; say so rather than
  # naming a commit that doesn't describe what's running.
  if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
    COMMIT="$COMMIT+"
  fi
else
  COMMIT="unknown"   # built outside a checkout; the UI omits it
fi

/usr/libexec/PlistBuddy -c "Set :SDGitCommit $COMMIT" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SDGitCommit string $COMMIT" "$PLIST"

echo "    commit: $COMMIT"
