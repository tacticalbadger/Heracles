#!/bin/sh
# Compile the app icon again, after a change to macos/Icon/Heracles.icon.
#
# Usage: macos/make-icon.sh
#
# Heracles.icon is the icon's source: a background, and the letter as an SVG
# layer over it, each with its colours for the light and the dark style. It
# opens in Icon Composer, which comes with Xcode.
#
# This writes, into macos/Icon/:
#   Assets.car     the layered icon, which macOS 26 and later draw in their
#                  light, dark, clear and tinted styles, with pictures of it
#                  for earlier versions
#   Heracles.icns  the plain icon file, for whatever still asks for one
#   Heracles.png   a picture of the icon, for the README
#
# All three are kept in the repository, so building the app does not need
# this script. Running it needs Xcode 26 or later.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if ! xcodebuild -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xcrun actool macos/Icon/Heracles.icon --compile "$WORK" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon Heracles \
    --output-partial-info-plist "$WORK/partial.plist" >/dev/null
cp "$WORK/Assets.car" "$WORK/Heracles.icns" macos/Icon/

"$ICTOOL" macos/Icon/Heracles.icon --export-image --output-file macos/Icon/Heracles.png \
    --platform macOS --rendition Default --width 512 --height 512 --scale 1 >/dev/null

echo "Wrote Assets.car, Heracles.icns and Heracles.png into macos/Icon/"
