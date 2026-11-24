#!/bin/sh
# Sign Heracles.app: first what is inside Sparkle.framework, each piece by
# itself and from the inside out, then the app. That order is the one
# Sparkle's documentation gives, and it warns against `codesign --deep`.
#
# Usage: macos/sign-app.sh <app> <identity> [--runtime | --release]
#   identity    a certificate's name or SHA-1, or - for an ad hoc signature
#   --runtime   the hardened runtime, without a timestamp. For the update
#               rehearsal's copies of a release build.
#   --release   the hardened runtime and Apple's secure timestamp, which is
#               what notarizing needs.
#
# No entitlements are given to anything: the app has none, and Sparkle's
# helpers need none outside the App Sandbox.
set -eu

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "usage: macos/sign-app.sh <app> <identity> [--runtime | --release]" >&2
    exit 2
fi
APP=$1
IDENTITY=$2
case "${3:-}" in
    "") set -- --timestamp=none ;;
    --runtime) set -- --options runtime --timestamp=none ;;
    --release) set -- --options runtime --timestamp ;;
    *)
        echo "macos/sign-app.sh: unknown option $3" >&2
        exit 2
        ;;
esac

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    codesign --force "$@" --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
    codesign --force "$@" --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
    codesign --force "$@" --sign "$IDENTITY" "$SPARKLE"
fi
codesign --force "$@" --sign "$IDENTITY" "$APP"
