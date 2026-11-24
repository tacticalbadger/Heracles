#!/usr/bin/env bash
# Publishes the release that macos/release.sh built as a GitHub release:
# tag v<version>, with the disk image, the zip and the update feed
# (appcast.xml) attached. The feed is what installed copies read to learn
# that there is a new version, so publishing is what sends an update out.
#
#   macos/publish.sh           publish
#   macos/publish.sh --check   make every check, publish nothing
#
# Releases on this repository are immutable: once one is published, files
# cannot be added to it or replaced, and its tag can never be used again.
# So the release is created as a draft, the files are attached and read
# back, and only then is it published. Nothing is tagged or created before
# every check below has passed:
#   - the three files are there, for the version in macos/Info.plist
#   - the feed announces exactly this zip, at the address it will have, and
#     the zip's signature verifies against the update key
#   - the disk image and the app in the zip are notarized and stapled
#   - the commit is on GitHub and nothing tracked is changed since
#   - there is no published release with this tag
#
# The release's notes are the text below with docs/release-notes/<version>.md
# in it. Keep names, hostnames and account details out of those.
# Needs the GitHub CLI, signed in (`gh auth login`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source macos/update-config.sh

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  *) fail "unknown option $1 (usage: macos/publish.sh [--check])" ;;
esac

PLIST=/usr/libexec/PlistBuddy
VERSION="$($PLIST -c 'Print :CFBundleShortVersionString' macos/Info.plist)"
BUILD="$($PLIST -c 'Print :CFBundleVersion' macos/Info.plist)"
TAG="v$VERSION"
NAME="Heracles-$VERSION-mac"
DMG="build/$NAME.dmg"
ZIP="build/$NAME.zip"
FEED="build/appcast.xml"
NOTES_SOURCE="docs/release-notes/$VERSION.md"
# The clone's remote may still name an older address of the repository;
# releases go where installed copies look for them.
export GH_REPO="${GH_REPO:-$UPDATE_REPO}"
ZIP_URL="https://github.com/$GH_REPO/releases/download/$TAG/$NAME.zip"

command -v gh >/dev/null || fail "the GitHub CLI is not installed (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "not signed in to GitHub; run: gh auth login"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the files ----------------------------------------------------------------
step "Checking the files for $VERSION (build $BUILD)"
[[ -f "$DMG" && -f "$ZIP" ]] || fail "no release files for $VERSION in build/; run macos/release.sh first"
[[ -f "$FEED" ]] || fail "no update feed (build/appcast.xml): macos/release.sh writes it when the update key is on this Mac.
       A release without it would leave installed copies unable to see this or any later version."
[[ -f "$NOTES_SOURCE" ]] || fail "no release notes for $VERSION ($NOTES_SOURCE)"

# --- the feed announces exactly this archive ------------------------------------
FEED_URL="$(sed -nE 's/.*<enclosure url="([^"]+)".*/\1/p' "$FEED" | head -1)"
[[ "$FEED_URL" == "$ZIP_URL" ]] \
  || fail "the feed does not point at this release's archive (it names ${FEED_URL:-nothing}); run macos/release.sh again"
FEED_LENGTH="$(sed -nE 's/.* length="([0-9]+)".*/\1/p' "$FEED" | head -1)"
[[ "$FEED_LENGTH" == "$(stat -f %z "$ZIP")" ]] \
  || fail "the feed was written for another archive (it gives the length ${FEED_LENGTH:-none}); run macos/release.sh again"
FEED_BUILD="$(sed -nE 's/.*<sparkle:version>([^<]*)<.*/\1/p' "$FEED" | head -1)"
[[ "$FEED_BUILD" == "$BUILD" ]] || fail "the feed names build ${FEED_BUILD:-none}, and macos/Info.plist says $BUILD; run macos/release.sh again"
grep -q "sparkle-signatures:" "$FEED" || fail "the feed is not signed; run macos/release.sh again"
grep -q 'sparkle:format="markdown"' "$FEED" || fail "the feed's release notes are not Markdown; run macos/release.sh again"
FEED_SIGNATURE="$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' "$FEED" | head -1)"
macos/verify-update.sh "$UPDATE_PUBLIC_KEY" "${FEED_SIGNATURE:-}" "$ZIP" >/dev/null \
  || fail "the archive's signature does not verify against the update key: installed copies would refuse this update"
echo "the update feed announces this archive, and its signature verifies"

# --- notarized, both of them ------------------------------------------------------
xcrun stapler validate "$DMG" >/dev/null 2>&1 \
  || fail "$(basename "$DMG") is not notarized and stapled; run macos/release.sh without --skip-notarize"
ASSESS="$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 || true)"
[[ "$ASSESS" == *"Notarized Developer ID"* ]] || fail "Gatekeeper does not accept the disk image: $ASSESS"
# The zip is what installed copies unpack: look at the app inside it.
ditto -x -k "$ZIP" "$WORK/unzipped"
UNZIPPED="$WORK/unzipped/Heracles.app"
xcrun stapler validate "$UNZIPPED" >/dev/null 2>&1 || fail "the app in $(basename "$ZIP") is not notarized and stapled"
ASSESS="$(spctl --assess --type execute -vv "$UNZIPPED" 2>&1 || true)"
[[ "$ASSESS" == *"Notarized Developer ID"* ]] || fail "Gatekeeper does not accept the app in the zip: $ASSESS"
[[ "$($PLIST -c 'Print :CFBundleShortVersionString' "$UNZIPPED/Contents/Info.plist")" == "$VERSION" \
   && "$($PLIST -c 'Print :CFBundleVersion' "$UNZIPPED/Contents/Info.plist")" == "$BUILD" ]] \
  || fail "the app in the zip is not $VERSION (build $BUILD)"
[[ "$($PLIST -c 'Print :SUPublicEDKey' "$UNZIPPED/Contents/Info.plist")" == "$UPDATE_PUBLIC_KEY" ]] \
  || fail "the app in the zip trusts another update key than the one in macos/update-config.sh"
echo "notarized and accepted by Gatekeeper: the disk image, and the app in the zip"

# --- the commit --------------------------------------------------------------------
# The tag points at the commit the release was built from: it has to be on
# GitHub, and what was built has to be what was committed.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
  || fail "tracked files have changes that are not committed; commit them and run macos/release.sh again"
git fetch -q origin
HEAD_SHA="$(git rev-parse HEAD)"
[[ -n "$(git branch -r --contains "$HEAD_SHA" 2>/dev/null)" ]] || fail "the current commit is not on GitHub; push first"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-parse "refs/tags/$TAG^{commit}")" == "$HEAD_SHA" ]] \
    || fail "the tag $TAG exists and points at another commit"
fi

# --- no such release yet -------------------------------------------------------------
# A draft left by a run that stopped half way is taken up again.
EXISTING="$(gh api "repos/$GH_REPO/releases" --paginate --jq ".[] | select(.tag_name == \"$TAG\") | .draft")"
[[ "$EXISTING" != *false* ]] || fail "release $TAG is already published, and a published release cannot be changed.
       Raise the version and the build number in macos/Info.plist and make a new release."

if [[ "$CHECK_ONLY" == 1 ]]; then
  echo "Every check passed. Nothing was tagged or published (--check)."
  exit 0
fi

# --- the notes -------------------------------------------------------------------------
NOTES="$WORK/notes.md"
cat > "$NOTES" <<NOTES_EOF
The native Mac app's preview. In this version:

$(cat "$NOTES_SOURCE")

This preview passes its automated tests, but nobody has used it day to day yet. Treat it as something to try, not something to rely on.

## Install

1. Download \`$NAME.dmg\` below and open it.
2. In the window that appears, drag Heracles onto the Applications folder.
3. Eject the Heracles disk, then open Heracles from Applications.

If an earlier version is already in Applications, quit it first, and choose Replace when the Finder asks.

It needs macOS 14 or later and runs on Apple silicon and Intel. The app and the disk image are signed and notarized by Apple, so Heracles opens like any other downloaded app.

## Updates

From 0.4.0 on, Heracles updates itself: it looks for a new version once a day and offers it with its release notes. **Heracles ▸ Check for Updates…** looks right away, and **Check for Updates Automatically** turns the daily look off. Keep the app in Applications for this to work. Version 0.3.3 and earlier cannot do this: install this version by hand once.

\`$NAME.zip\` holds the same app. It is what the app downloads when it updates itself, and \`appcast.xml\` is the small file that tells it a new version exists.

## What it is

A local-first notebook: pages in notebooks, a block editor, split panes and kanban boards, all stored on your Mac. It is a native Mac app, written in Swift over a Rust core.

## Your notes

If you have never used Heracles, it starts with an empty library and this section does not apply to you.

The preview uses the same folder as the Electron app, \`~/Library/Application Support/Heracles/\`. The first time it starts, it copies your library from \`heracles.sqlite\` into a new file, \`heracles.db\`. The Electron database is backed up first and is never changed, so the Electron app keeps working. After that the two apps hold separate copies: an edit made in one does not appear in the other.

To try the preview without it reading your library, start it from Terminal with a different folder:

\`\`\`bash
HERACLES_DATA_DIR=~/heracles-trial /Applications/Heracles.app/Contents/MacOS/Heracles
\`\`\`

The full list of changes is in [CHANGELOG.md](https://github.com/$GH_REPO/blob/$TAG/CHANGELOG.md), and the state of the rewrite is in [docs/review-and-native-rewrite.md](https://github.com/$GH_REPO/blob/$TAG/docs/review-and-native-rewrite.md#rewrite-status).

SHA-256 checksums:

- \`$NAME.dmg\`: \`$(shasum -a 256 "$DMG" | awk '{print $1}')\`
- \`$NAME.zip\`: \`$(shasum -a 256 "$ZIP" | awk '{print $1}')\`
NOTES_EOF

# --- tag, draft, files ---------------------------------------------------------------------
step "Tagging $TAG"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag "$TAG" "$HEAD_SHA"
git push -q origin "refs/tags/$TAG"

TITLE="Heracles $VERSION (native Mac app, preview)"
if [[ -n "$EXISTING" ]]; then
  step "Taking up the draft of $TAG again"
  gh release edit "$TAG" --draft --title "$TITLE" --notes-file "$NOTES" >/dev/null
else
  step "Creating $TAG as a draft"
  gh release create "$TAG" --draft --verify-tag --title "$TITLE" --notes-file "$NOTES" >/dev/null
fi
step "Attaching the files"
gh release upload "$TAG" "$DMG" "$ZIP" "$FEED" --clobber

# Read back what GitHub holds before the release can no longer be changed.
step "Comparing the draft's files with the local ones"
ASSETS="$(gh api "repos/$GH_REPO/releases" --paginate \
  --jq ".[] | select(.tag_name == \"$TAG\" and .draft) | .assets[] | \"\(.name) \(.size) \(.digest)\"")"
[[ "$(wc -l <<<"$ASSETS" | tr -d ' ')" == 3 ]] || fail "the draft holds other files than the three expected:
$ASSETS
       The draft is still on GitHub; look at it there."
for FILE in "$DMG" "$ZIP" "$FEED"; do
  WANT="$(basename "$FILE") $(stat -f %z "$FILE") sha256:$(shasum -a 256 "$FILE" | awk '{print $1}')"
  grep -q -x -F "$WANT" <<<"$ASSETS" || fail "$(basename "$FILE") on GitHub is not the local file.
       The draft is still on GitHub; run this again to replace its files."
  echo "  $(basename "$FILE"): same size and SHA-256"
done

# --- publish ------------------------------------------------------------------------------------
# A full release marked latest: "releases/latest/download" serves nothing
# from a pre-release, and that is the address every copy reads.
step "Publishing"
gh release edit "$TAG" --draft=false --prerelease=false --latest >/dev/null
LATEST="$(gh api "repos/$GH_REPO/releases/latest" --jq .tag_name)"
[[ "$LATEST" == "$TAG" ]] || fail "$TAG is published, but GitHub's latest release is $LATEST: installed copies read that one's feed"
# What installed copies will be served, byte for byte. It can take a moment.
SERVED=0
for _ in $(seq 1 12); do
  if curl -fsSL "$UPDATE_FEED_URL" 2>/dev/null | cmp -s - "$FEED"; then SERVED=1; break; fi
  sleep 5
done
[[ "$SERVED" == 1 ]] || fail "$TAG is published, but $UPDATE_FEED_URL does not serve this release's feed"
echo "published: https://github.com/$GH_REPO/releases/tag/$TAG"
echo "installed copies look for updates at: $UPDATE_FEED_URL"
