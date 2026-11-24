#!/bin/sh
# Checks of the release scripts' own safeguards. Needs no build, no
# certificate and no network, and changes nothing outside a temporary
# folder.
#
# Usage: macos/test-release-scripts.sh
#
#   verify-update.sh        accepts an archive only with a signature made
#                           by the key it is given
#   check-build-number.sh   stops a release whose build number is not
#                           higher than the one in the published feed
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

# expect <what> <wanted exit status> <command…>
# The command's output is left in $WORK/out for a look at what it said.
expect() {
    WHAT=$1
    WANTED=$2
    shift 2
    "$@" >"$WORK/out" 2>&1
    GOT=$?
    if [ "$GOT" = "$WANTED" ]; then
        echo "PASS: $WHAT"
    else
        echo "FAIL: $WHAT (exit $GOT, wanted $WANTED)"
        sed 's/^/      /' "$WORK/out"
        FAILED=1
    fi
}
# said <what> <text>: the last command's output contains the text.
said() {
    if grep -q -F -- "$2" "$WORK/out"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (nothing said \"$2\")"
        FAILED=1
    fi
}

echo "== verify-update.sh"
printf 'what an update would be' >"$WORK/archive"
# A key made for this run, a signature of the archive made with it, and
# the public half of a second key that signed nothing.
KEYS=$(
    swift - "$WORK/archive" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let stranger = Curve25519.Signing.PrivateKey()
let archive = FileManager.default.contents(atPath: CommandLine.arguments[1])!
print(
    key.publicKey.rawRepresentation.base64EncodedString(),
    try! key.signature(for: archive).base64EncodedString(),
    stranger.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)
# shellcheck disable=SC2086  # three words: the key, the signature, the other key
set -- $KEYS
if [ $# -ne 3 ]; then
    echo "FAIL: could not make a key to test with"
    exit 1
fi
PUBLIC=$1
SIGNATURE=$2
STRANGER=$3

expect "an archive signed with the key is accepted" 0 macos/verify-update.sh "$PUBLIC" "$SIGNATURE" "$WORK/archive"
said "and called valid" "valid"
cp "$WORK/archive" "$WORK/altered"
printf '!' >>"$WORK/altered"
expect "the same signature on an altered archive is refused" 1 macos/verify-update.sh "$PUBLIC" "$SIGNATURE" "$WORK/altered"
expect "a signature made with another key is refused" 1 macos/verify-update.sh "$STRANGER" "$SIGNATURE" "$WORK/archive"
expect "a key that is not a key is refused" 1 macos/verify-update.sh "not-a-key" "$SIGNATURE" "$WORK/archive"
expect "an empty signature is refused" 1 macos/verify-update.sh "$PUBLIC" "" "$WORK/archive"
expect "an archive that is not there is refused" 1 macos/verify-update.sh "$PUBLIC" "$SIGNATURE" "$WORK/missing"

echo "== check-build-number.sh"
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' macos/Info.plist)
# A feed as generate_appcast writes it, as far as the build number goes.
published() {
    cat >"$WORK/feed.xml" <<FEED
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item>
            <title>9.9.9</title>
            <sparkle:version>$1</sparkle:version>
            <sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>
        </item>
    </channel>
</rss>
FEED
}
published $((BUILD - 1))
expect "a build number above the published one goes on" 0 macos/check-build-number.sh "$WORK/feed.xml"
published "$BUILD"
expect "the published build number again is refused" 1 macos/check-build-number.sh "$WORK/feed.xml"
said "and the refusal says what to change" "CFBundleVersion"
published $((BUILD + 1))
expect "a build number below the published one is refused" 1 macos/check-build-number.sh "$WORK/feed.xml"
published "7b"
expect "a feed whose build number is not a number cannot be judged" 3 macos/check-build-number.sh "$WORK/feed.xml"
: >"$WORK/feed.xml"
expect "an empty feed cannot be judged" 3 macos/check-build-number.sh "$WORK/feed.xml"
expect "a feed file that is not there cannot be judged" 3 macos/check-build-number.sh "$WORK/missing.xml"

echo
if [ "$FAILED" = 0 ]; then
    echo "release scripts: every check passed"
else
    echo "release scripts: FAILED"
fi
exit "$FAILED"
