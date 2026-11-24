#!/bin/sh
# Build Heracles for distribution: a universal app, signed with the Developer
# ID certificate under the hardened runtime, notarized by Apple and stapled,
# in a disk image that is signed, notarized and stapled as well, and the
# update feed that tells installed copies about it.
#
# Usage: macos/release.sh [--skip-notarize]
#   --skip-notarize   stop after signing. For checking a signed build locally;
#                     publish.sh will not publish one.
#
# Signing needs a Developer ID Application certificate in the keychain. The
# first one found is used. Set CODESIGN_IDENTITY (a name or a SHA-1) to use
# a different one.
#
# Notarizing needs credentials, given in one of three ways:
#   - the same three variables the Electron release uses:
#       APPLE_API_KEY      path to the App Store Connect API key (.p8)
#       APPLE_API_KEY_ID   the key's id
#       APPLE_API_ISSUER   the issuer id
#   - an Apple ID and an app-specific password made for it at
#     account.apple.com:
#       APPLE_ID                      the Apple ID, an email address
#       APPLE_APP_SPECIFIC_PASSWORD   the app-specific password
#       APPLE_TEAM_ID                 the team id, if not the signing identity's
#   - or NOTARY_PROFILE, the name of a profile saved once with
#       xcrun notarytool store-credentials <name> ...
#
# The feed needs the update key in the login keychain (update-config.sh
# says which and how to bring it over), or HERACLES_UPDATE_KEY_FILE, a file
# that holds it. Installed copies take an update only if it is signed with
# that key. The first time, macOS asks whether generate_appcast may use
# the key: choose Always Allow.
#
# The version and the build number come from macos/Info.plist. The build
# number has to be higher than the published one, or no installed copy is
# offered the update; the script stops if it is not. What the update window
# shows is docs/release-notes/<version>.md.
#
# Produces, in build/:
#   Heracles.app                 the app
#   Heracles-<version>-mac.dmg   the disk image people download: the app
#                                beside a link to the Applications folder
#   Heracles-<version>-mac.zip   the same app, zipped. Also what installed
#                                copies download as an update.
#   appcast.xml                  the update feed, signed. publish.sh
#                                attaches it to the release.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. macos/update-config.sh

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

NOTARIZE=yes
[ "${1:-}" = "--skip-notarize" ] && NOTARIZE=no

# The update key signs the feed at the very end. Without it there is
# nothing to publish, so that is found out first, not after the long build
# and the wait for Apple.
KEY_SOURCE=none
if [ -n "${HERACLES_UPDATE_KEY_FILE:-}" ]; then
    [ -r "$HERACLES_UPDATE_KEY_FILE" ] ||
        fail "cannot read the update key file named in HERACLES_UPDATE_KEY_FILE ($HERACLES_UPDATE_KEY_FILE)"
    KEY_SOURCE=file
elif [ ! -x "$SPARKLE_BIN/generate_keys" ]; then
    # A fresh checkout: SwiftPM unpacks Sparkle's tools with the first build.
    KEY_SOURCE=unknown
elif [ "$("$SPARKLE_BIN/generate_keys" --account "$UPDATE_KEY_ACCOUNT" -p 2>/dev/null || true)" = "$UPDATE_PUBLIC_KEY" ]; then
    KEY_SOURCE=keychain
fi
missing_key() {
    fail "the update key is not in this Mac's keychain (account $UPDATE_KEY_ACCOUNT), or is a different key.
       Without it nobody's copy can be updated. Bring it over from the Mac that has it:
         $SPARKLE_BIN/generate_keys --account $UPDATE_KEY_ACCOUNT -x <file>     there
         $SPARKLE_BIN/generate_keys --account $UPDATE_KEY_ACCOUNT -f <file>     here
       or set HERACLES_UPDATE_KEY_FILE to a file that holds it."
}
[ "$KEY_SOURCE" != none ] || [ "$NOTARIZE" = no ] || missing_key

# A release nobody would be offered is stopped before the long build.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/Info.plist)
NOTES=docs/release-notes/$VERSION.md
STATUS=0
macos/check-build-number.sh || STATUS=$?
if [ "$STATUS" = 3 ] && [ "$NOTARIZE" = no ]; then
    echo "Going on without knowing the published build number: this build is not for publishing."
elif [ "$STATUS" != 0 ]; then
    exit 1
fi
# The update window shows these notes. They are Markdown, which Sparkle
# draws as text; without them it would have nothing to show.
[ -f "$NOTES" ] || fail "no release notes for $VERSION: write $NOTES first"

# The certificate is looked up, not named here: the repository is public.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    LINE=$(printf '%s\n' "$IDENTITIES" | grep -F "$CODESIGN_IDENTITY" | head -1)
    [ -n "$LINE" ] || fail "no certificate in the keychain matches CODESIGN_IDENTITY"
else
    LINE=$(printf '%s\n' "$IDENTITIES" | grep -F "Developer ID Application:" | head -1)
    [ -n "$LINE" ] || fail "no \"Developer ID Application\" certificate in the keychain.
       Create one in Xcode > Settings > Accounts > Manage Certificates, or import
       the .p12 from the Mac that has it. Then run this again."
fi
# Lines look like:   1) <sha1> "<name> (<team>)"
IDENTITY=$(printf '%s\n' "$LINE" | awk '{print $2}')
IDENTITY_NAME=$(printf '%s\n' "$LINE" | sed -E 's/^[^"]*"(.*)"[^"]*$/\1/')

if [ "$NOTARIZE" = yes ]; then
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        set -- --keychain-profile "$NOTARY_PROFILE"
    elif [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
        set -- --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
        # The team is the one named in brackets at the end of the identity.
        TEAM=${APPLE_TEAM_ID:-$(printf '%s' "$IDENTITY_NAME" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')}
        set -- --apple-id "$APPLE_ID" --team-id "$TEAM" --password "$APPLE_APP_SPECIFIC_PASSWORD"
    else
        echo "No notary credentials. Set NOTARY_PROFILE, or APPLE_API_KEY, APPLE_API_KEY_ID" >&2
        echo "and APPLE_API_ISSUER, or APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD." >&2
        echo "To stop after signing, pass --skip-notarize." >&2
        exit 2
    fi
    # Checked with Apple before the long build, so a missing or mistyped
    # credential fails at once and not after ten minutes.
    if ! xcrun notarytool history "$@" >/dev/null 2>&1; then
        echo "Apple did not accept the notary credentials." >&2
        exit 2
    fi
fi

# The universal build: Apple silicon and Intel.
macos/build-app.sh

APP=build/Heracles.app
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] ||
    fail "the built app is not version $VERSION"
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
NAME=Heracles-$VERSION-mac
ZIP=build/$NAME.zip
DMG=build/$NAME.dmg
FEED=build/appcast.xml
rm -f "$FEED"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# The zip is also what installed copies download as an update. Sparkle asks
# for these options, so that nothing about the bundle changes in the archive.
make_zip() {
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
}

# The disk image holds the app beside a link to the Applications folder, so
# installing is one drag. It is signed, which lets macOS tell who made it.
make_dmg() {
    rm -rf "$STAGE/Heracles.app" "$STAGE/Applications" "$DMG"
    ditto "$APP" "$STAGE/Heracles.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname Heracles -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
    hdiutil verify -quiet "$DMG"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
    rm -rf "$STAGE/Heracles.app" "$STAGE/Applications"
}

# Installed copies read appcast.xml from the newest GitHub release
# (publish.sh puts it there) and download the zip it names. Both are signed
# here with the update key, and the app refuses either without it.
write_feed() {
    # On a fresh checkout the tools were not there to ask before the build.
    if [ "$KEY_SOURCE" = unknown ]; then
        KEY_SOURCE=none
        HAVE=$("$SPARKLE_BIN/generate_keys" --account "$UPDATE_KEY_ACCOUNT" -p 2>/dev/null || true)
        [ "$HAVE" = "$UPDATE_PUBLIC_KEY" ] && KEY_SOURCE=keychain
    fi
    case "$KEY_SOURCE" in
        file) set -- --ed-key-file "$HERACLES_UPDATE_KEY_FILE" ;;
        keychain) set -- --account "$UPDATE_KEY_ACCOUNT" ;;
        *)
            [ "$NOTARIZE" = no ] || missing_key
            echo "No update key on this Mac: no feed written. This build cannot be published."
            return 0
            ;;
    esac

    echo "==> Signing the update and writing the feed"
    mkdir "$STAGE/feed"
    cp "$ZIP" "$STAGE/feed/"
    # Notes with the archive's name are put into the feed.
    cp "$NOTES" "$STAGE/feed/$NAME.md"
    "$SPARKLE_BIN/generate_appcast" "$@" \
        --download-url-prefix "https://github.com/$UPDATE_REPO/releases/download/v$VERSION/" \
        --link "https://github.com/$UPDATE_REPO/releases" \
        --embed-release-notes --maximum-versions 1 -o "$FEED" "$STAGE/feed" ||
        fail "generate_appcast could not write the feed"

    # What every installed copy will do with it: check the archive's
    # signature against the public key in the app. A release signed with
    # any other key would be refused by all of them.
    SIGNATURE=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$FEED" | head -1)
    [ -n "$SIGNATURE" ] || fail "the feed names no signed archive"
    APP_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
    macos/verify-update.sh "$APP_KEY" "$SIGNATURE" "$ZIP" >/dev/null ||
        fail "the archive's signature does not verify against the key in the app: installed copies would refuse this update"
    grep -q "sparkle-signatures:" "$FEED" || fail "the feed itself is not signed"
    grep -q "releases/download/v$VERSION/$NAME.zip\"" "$FEED" ||
        fail "the feed does not point at this release's archive"
    grep -q "length=\"$(stat -f %z "$ZIP")\"" "$FEED" || fail "the feed gives another length than the archive's"
    grep -q "<sparkle:version>$BUILD</sparkle:version>" "$FEED" || fail "the feed does not name build $BUILD"
    # Markdown is drawn as text. HTML would bring up a web view in the app.
    grep -q 'sparkle:format="markdown"' "$FEED" || fail "the feed's release notes are not Markdown"
    # The app is universal. A feed that asks for one processor would hide
    # the update from Macs with the other.
    if grep -q "sparkle:hardwareRequirements" "$FEED"; then
        fail "the feed limits the update to one kind of processor"
    fi
    echo "The archive's signature verifies against the key in the app. Feed written: $FEED"
}

echo "==> Signing as $IDENTITY_NAME"
# The hardened runtime with no exceptions: the app loads no unsigned code and
# makes no executable memory of its own. Sparkle's helpers are signed first,
# then the framework, then the app.
macos/sign-app.sh "$APP" "$IDENTITY" --release
codesign --verify --deep --strict --verbose=2 "$APP"

# Every executable in the bundle, one by one. Apple refuses to notarize a
# signature without a secure timestamp or the hardened runtime, and it is
# quicker to hear it here. The download is public, so nothing in it may
# name the Mac it was built on, and nothing gets an entitlement.
echo "==> Checking every executable in the bundle"
find "$APP/Contents/MacOS" "$APP/Contents/Frameworks" -type f | while IFS= read -r ITEM; do
    case "$(file -b "$ITEM")" in
        *Mach-O*) ;;
        *) continue ;;
    esac
    DETAILS=$(codesign -dvv "$ITEM" 2>&1 || true)
    case "$DETAILS" in
        *Timestamp=*) ;;
        *) fail "no secure timestamp in the signature of $ITEM" ;;
    esac
    case "$DETAILS" in
        *flags=*runtime*) ;;
        *) fail "$ITEM is not signed with the hardened runtime" ;;
    esac
    ENTITLEMENTS=$(codesign -d --entitlements - "$ITEM" 2>/dev/null || true)
    [ -z "$ENTITLEMENTS" ] || fail "$ITEM carries entitlements, and nothing in the app should"
    FOUND=$(strings -a "$ITEM" | grep -c -F -e "$HOME" -e "/Users/$(id -un)" || true)
    [ "$FOUND" = 0 ] || fail "$ITEM holds $FOUND strings with a path from this Mac in them.
       macos/build-core.sh rewrites the paths Rust records; see what else has brought some in."
    echo "  ${ITEM#"$APP"/Contents/}"
done || exit 1

# What a signed build must be able to do, checked on the build itself.
echo "==> Checking the signed app"
"$APP/Contents/MacOS/Heracles" --self-test >/dev/null || {
    echo "The signed app failed its self-test. Run it by hand to see why:" >&2
    echo "  $APP/Contents/MacOS/Heracles --self-test" >&2
    exit 1
}

make_zip

if [ "$NOTARIZE" = no ]; then
    make_dmg
    write_feed
    echo "Signed, not notarized: $DMG and $ZIP"
    exit 0
fi

echo "==> Notarizing the app (this waits for Apple, usually a few minutes)"
xcrun notarytool submit "$ZIP" "$@" --wait

echo "==> Stapling the app"
xcrun stapler staple "$APP"
# The zip is made again so that it holds the stapled app, which opens on a
# Mac that is offline.
make_zip

# The image is made from the stapled app and then notarized in its own
# right, so both the image and the app in it carry a ticket.
echo "==> Notarizing the disk image"
make_dmg
xcrun notarytool submit "$DMG" "$@" --wait

echo "==> Stapling the disk image"
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Last, from the zip that holds the stapled app: the one that is published.
write_feed
echo "Ready to distribute: $DMG, $ZIP and $FEED"
echo "Rehearse an update with macos/update-rehearsal.sh, then publish with macos/publish.sh."
