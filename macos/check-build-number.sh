#!/bin/sh
# Stops a release whose build number is not higher than the published one.
#
# Sparkle decides whether a version is newer by its build number
# (CFBundleVersion in macos/Info.plist), not by the version people see. A
# release that keeps the number of the one before it is never offered to
# anybody, and nothing says so.
#
# Usage: macos/check-build-number.sh [<feed-file>]
#   feed-file   read this file as the published feed, not the one on
#               GitHub. For the tests (macos/test-release-scripts.sh).
#
# Exit status:
#   0   go on: the number is higher, or no feed is published yet
#   1   stop: the number is not higher
#   3   the published feed could not be read or names no number, so
#       nothing is known either way
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. macos/update-config.sh

BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' macos/Info.plist)
case "$BUILD" in
    '' | *[!0-9]*)
        echo "CFBundleVersion in macos/Info.plist must be a whole number, not \"$BUILD\"." >&2
        exit 1
        ;;
esac

if [ $# -ge 1 ]; then
    FEED=$1
    if [ ! -r "$FEED" ]; then
        echo "Cannot read the feed $FEED." >&2
        exit 3
    fi
else
    FEED=$(mktemp)
    trap 'rm -f "$FEED"' EXIT
    STATUS=$(curl -sS -L -o "$FEED" -w '%{http_code}' "$UPDATE_FEED_URL" 2>/dev/null) || STATUS=000
    case "$STATUS" in
        200) ;;
        404)
            echo "No feed is published yet: build $BUILD will be the first with one."
            exit 0
            ;;
        *)
            echo "Could not read the published feed (HTTP $STATUS): $UPDATE_FEED_URL" >&2
            exit 3
            ;;
    esac
fi

PUBLISHED=$(sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p' "$FEED" | head -1)
case "$PUBLISHED" in
    '' | *[!0-9]*)
        echo "The published feed names no build number that can be compared (\"$PUBLISHED\")." >&2
        exit 3
        ;;
esac

if [ "$BUILD" -gt "$PUBLISHED" ]; then
    echo "Build $BUILD is higher than the published build $PUBLISHED."
    exit 0
fi
echo "Build $BUILD is not higher than the published build $PUBLISHED." >&2
echo "Installed copies would never be offered this version. Raise CFBundleVersion in macos/Info.plist." >&2
exit 1
