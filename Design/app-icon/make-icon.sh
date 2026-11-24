#!/bin/zsh
# Redraws YummyOrange's app icon from IconArt.swift (direction B, "Bloom") at every size an .icns holds (16 to 1024 px,
# @1x and @2x) and builds AppIcon.icns with iconutil. build.sh copies AppIcon.icns into the app, so run this only
# after changing the drawing. Needs Swift (Xcode or the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/make-icon" IconArt.swift main.swift
"$WORK/make-icon" "$WORK/AppIcon.iconset" AppIcon-1024.png
iconutil -c icns "$WORK/AppIcon.iconset" -o AppIcon.icns
echo "Wrote $PWD/AppIcon.icns"
