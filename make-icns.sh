#!/bin/bash
# Regenerates Resources/SignalDeck.icns from Resources/AppIcon.png.
#
# AppIcon.png is the 1024x1024 master: the artwork sits in an 824x824 rounded rect centred
# on a transparent canvas, which is the layout macOS expects (the surrounding padding is
# what the Finder and the App Switcher use for their own shadow and highlight).
#
# Only run this after editing the master. The .icns is committed, so a plain build does not
# need it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MASTER="$ROOT/Resources/AppIcon.png"
ICNS="$ROOT/Resources/SignalDeck.icns"
TMP="$(mktemp -d)"
# set -e aborts the moment sips or iconutil fails, which is before any cleanup line at the
# bottom would run. The trap is what stops a failed run leaving a directory behind.
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/SignalDeck.iconset"

mkdir -p "$SET"

# iconutil requires exactly these names; anything else is silently dropped from the .icns.
for SPEC in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  POINTS="${SPEC%%:*}"
  SCALE="${SPEC##*:}"
  PIXELS=$((POINTS * SCALE))
  NAME="icon_${POINTS}x${POINTS}"
  [ "$SCALE" -eq 2 ] && NAME="$NAME@2x"
  sips -s format png -z "$PIXELS" "$PIXELS" "$MASTER" --out "$SET/$NAME.png" >/dev/null
done

iconutil -c icns "$SET" -o "$ICNS"

echo "==> Wrote $ICNS"
