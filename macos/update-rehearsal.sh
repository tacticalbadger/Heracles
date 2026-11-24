#!/usr/bin/env bash
# Rehearses an over-the-air update from start to finish with nothing real in
# it: a signing key made for the run, two copies of the current build given
# made-up versions (9.9.1 and 9.9.2) and a bundle identifier of their own,
# a library in the work folder, and a feed served from that folder (Sparkle
# does not read file:// feeds, so a web server on 127.0.0.1 hands it out
# for the length of the run). No release, no GitHub, not the real update
# key, not the real library, not the app's own preferences.
#
#   macos/update-rehearsal.sh [work-dir]      default: build/update-rehearsal
#
# It checks six things and exits non-zero unless all hold:
#   0. A run with a library of its own and no feed named does not look for
#      updates at all, so a trial copy is never offered the published app.
#      Its two menu items for updates are greyed out.
#   1. The old copy finds the new one in the feed, verifies it, and once it
#      has quit, the copy on disk is the new version.
#   2. That copy, now the new version, finds nothing newer in the same feed.
#      Its Check for Updates… item can be chosen, and Check for Updates
#      Automatically is ticked.
#   3. With the archive altered after it was signed, nothing is installed
#      and the app says why.
#   4. The same with the feed altered after it was signed.
#   5. Sparkle stops refusing such a feed once a copy has seen no good one
#      for 20 days, and reads it with restrictions from then on (its
#      provision for a developer who lost the key; BUILDING.md says where
#      that is written up). With that date moved back by hand: still
#      nothing is downloaded or installed on the feed's word.
#
# Needs build/Heracles.app (macos/build-app.sh, or a release build) and
# python3 for the web server (PORT=8498 by default). The copies start in
# the background, though a window of theirs may show. A run that passes
# removes its work folder (KEEP=1 keeps it; a run that fails always does),
# and every run removes what the copies kept under their own bundle
# identifier in ~/Library: preferences and caches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source macos/update-config.sh
APP="$ROOT/build/Heracles.app"
WORK="${1:-$ROOT/build/update-rehearsal}"
BUNDLE_ID="com.heracles.notes.native.update-rehearsal"
PORT="${PORT:-8498}"
BASE="http://127.0.0.1:$PORT"
OLD_VERSION="9.9.1"; OLD_BUILD="99901"
NEW_VERSION="9.9.2"; NEW_BUILD="99902"
ARCHIVE="Heracles-$NEW_VERSION-mac"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[[ -d "$APP" ]] || fail "no app bundle at build/Heracles.app; run macos/build-app.sh first"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] \
  || fail "Sparkle's tools are not in the package cache ($SPARKLE_BIN); run macos/build-app.sh first"
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] \
  || fail "build/Heracles.app has no Sparkle.framework in it: the bundle was made without the updater"

version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist"; }
has_version() { [[ "$(version_of "$1" 2>/dev/null)" == "$2" ]]; }

# Waits until a command succeeds: wait_for <seconds> <command…>
wait_for() {
  local limit="$1" waited=0
  shift
  until "$@" >/dev/null 2>&1; do
    sleep 0.5
    waited=$((waited + 1))
    [[ "$waited" -lt $((limit * 2)) ]] || return 1
  done
}

running() { pgrep -f "$1/Contents/MacOS/Heracles" >/dev/null; }
not_running() { ! running "$1"; }
stop() { pkill -f "$1/Contents/MacOS/Heracles" 2>/dev/null || true; wait_for 20 not_running "$1" || true; }

# What the copies keep outside the work folder, under their own bundle
# identifier: preferences (Sparkle's among them) and caches. Removed before
# a run, so that nothing an earlier one left decides this one (the date of
# check 5 is kept there), and after it. Only ever for an identifier below
# the app's own, never for the app's.
forget_copies() {
  [[ "$BUNDLE_ID" == com.heracles.notes.native.?* ]] || return 0
  # `defaults delete` empties the domain where the system keeps it in
  # memory, and leaves an empty file behind.
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
}

rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"
forget_copies

# The feeds are read over HTTP from this folder, on this Mac only.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK" > "$WORK/server.log" 2>&1 &
SERVER=$!
finish() {
  local code=$?
  kill "$SERVER" 2>/dev/null || true
  wait "$SERVER" 2>/dev/null || true
  pkill -f "$WORK/.*/Heracles.app/Contents/MacOS/Heracles" 2>/dev/null || true
  forget_copies
  if [[ "$code" == 0 && "${KEEP:-0}" != 1 ]]; then
    rm -rf "$WORK"
  else
    echo "left for a look: $WORK"
  fi
}
trap finish EXIT
wait_for 10 nc -z 127.0.0.1 "$PORT" || fail "the local web server did not start on port $PORT (in use? set PORT)"

# --- a key for this run only ---------------------------------------------------
step "Making a signing key for the rehearsal"
read -r SEED PUBLIC < <(swift - <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)
[[ -n "$SEED" && -n "$PUBLIC" ]] || fail "could not make a key"
printf '%s' "$SEED" > "$WORK/key"
chmod 600 "$WORK/key"
echo "public key: $PUBLIC"
[[ "$PUBLIC" != "$UPDATE_PUBLIC_KEY" ]] || fail "the rehearsal's key is the real update key, which cannot be"

# --- two copies of the build, as two versions -----------------------------------
# Signed the way the build is: ad hoc for one made by build-app.sh, with
# the same certificate and the hardened runtime for a release build.
SIGNING="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$SIGNING" == *"Signature=adhoc"* ]]; then
  IDENTITY="-"
else
  IDENTITY="$(sed -n 's/^Authority=//p' <<<"$SIGNING" | head -1)"
fi
[[ -n "$IDENTITY" ]] || fail "build/Heracles.app is not signed"
SIGN_MODE=()
[[ "$SIGNING" == *"flags="*"runtime"* ]] && SIGN_MODE=(--runtime)

# make_copy <dir> <version> <build>: a copy of the build that claims to be
# that version, trusts the rehearsal key, keeps its own preferences, and
# may read plain HTTP from this Mac (the real app may not).
make_copy() {
  local dir="$1" plist="$1/Heracles.app/Contents/Info.plist"
  mkdir -p "$dir"
  ditto "$APP" "$dir/Heracles.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :SUPublicEDKey $PUBLIC" \
    -c "Add :NSAppTransportSecurity dict" \
    -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" \
    -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$plist"
  macos/sign-app.sh "$dir/Heracles.app" "$IDENTITY" ${SIGN_MODE[@]+"${SIGN_MODE[@]}"} >/dev/null 2>&1
  codesign --verify --deep --strict "$dir/Heracles.app" || fail "the copy in $dir does not verify after signing"
}

# make_feed <folder>: the new version's archive in that folder, and a feed
# for it made by the tool the release uses. The copies ask for a signed
# feed (SURequireSignedFeed), so generate_appcast signs it as well as the
# archive.
make_feed() {
  mkdir -p "$1"
  cp "$WORK/$ARCHIVE.zip" "$1/"
  printf -- '- A rehearsal update. **Nothing** in it is real.\n' > "$1/$ARCHIVE.md"
  "$SPARKLE_BIN/generate_appcast" --ed-key-file "$WORK/key" --download-url-prefix "$BASE/$(basename "$1")/" \
    --embed-release-notes -o "$1/appcast.xml" "$1" > "$1/generate_appcast.log" 2>&1 \
    || { cat "$1/generate_appcast.log"; fail "generate_appcast could not make the feed in $1"; }
  grep -q "sparkle:edSignature=" "$1/appcast.xml" || fail "the feed in $1 has no signed archive in it"
}

step "Making $NEW_VERSION ($NEW_BUILD), its archive and three feeds"
make_copy "$WORK/new" "$NEW_VERSION" "$NEW_BUILD"
ditto -c -k --sequesterRsrc --keepParent "$WORK/new/Heracles.app" "$WORK/$ARCHIVE.zip"
make_feed "$WORK/feed"

# The archive altered after the feed was made: four bytes in its middle,
# same length, same name.
make_feed "$WORK/bad-archive"
BAD="$WORK/bad-archive/$ARCHIVE.zip"
printf '\x00\x11\x22\x33' | dd of="$BAD" bs=1 seek=$(( $(stat -f %z "$BAD") / 2 )) conv=notrunc 2>/dev/null
cmp -s "$BAD" "$WORK/$ARCHIVE.zip" && fail "the archive did not change"

# The feed altered after it was signed: the release notes say something else.
make_feed "$WORK/bad-feed"
sed -i '' 's/A rehearsal update\./An update from somewhere else./' "$WORK/bad-feed/appcast.xml"
grep -q "from somewhere else" "$WORK/bad-feed/appcast.xml" || fail "the feed did not change"

# launch <copy-dir> <feed-folder or ""> <log>: a copy with a library of its
# own, looking at that feed (or at none), set to take updates without
# asking so nothing has to be clicked.
launch() {
  local feed=()
  [[ -n "$2" ]] && feed=(--updater-feed "$BASE/$(basename "$2")/appcast.xml")
  : > "$3"
  open -g -n "$1/Heracles.app" --stderr "$3" \
    --env HERACLES_DATA_DIR="$WORK/library" \
    --args ${feed[@]+"${feed[@]}"} --demo-update \
    -SUEnableAutomaticChecks YES -SUAutomaticallyUpdate YES
}
said() { grep -Eq "$1" "$2"; }
# The app writes down how its two menu items for updates stand once the
# app menu has been told it is about to open, which is when they are drawn.
menu_says() { grep -Fq "updates: menu: $1" "$2"; }
MENU_OFF="Check for Updates…=off; Check for Updates Automatically=off"
MENU_ON="Check for Updates…=on; Check for Updates Automatically=on, ticked"
shown() { grep 'updates: ' "$1" | sed -E 's/^.*updates: /  app: /' || true; }

RESULT=0

# --- 0. a trial run does not look ----------------------------------------------------
step "0. A copy with a library of its own and no feed named"
make_copy "$WORK/trial" "$OLD_VERSION" "$OLD_BUILD"
REQUESTS_BEFORE="$(grep -c 'GET ' "$WORK/server.log" || true)"
launch "$WORK/trial" "" "$WORK/trial.log"
wait_for 30 said "updates: menu: " "$WORK/trial.log" || true
shown "$WORK/trial.log"
stop "$WORK/trial/Heracles.app"
if said "updates: looking for an update \(active: false\)" "$WORK/trial.log" \
   && ! said "updates: (found|downloaded|nothing newer|stopped|done)" "$WORK/trial.log" \
   && [[ "$(grep -c 'GET ' "$WORK/server.log" || true)" == "$REQUESTS_BEFORE" ]]; then
  echo "PASS: the updater did not start, and nothing was asked of any feed"
else
  echo "FAIL: a run with a library of its own looked for updates, or never said whether it does"
  RESULT=1
fi
if menu_says "$MENU_OFF" "$WORK/trial.log"; then
  echo "PASS: its two menu items for updates are greyed out"
else
  echo "FAIL: its menu items for updates are not both greyed out, or the app never said how they stand"
  RESULT=1
fi

# --- 1. the update arrives and is installed ---------------------------------------
step "1. $OLD_VERSION looks at the feed"
make_copy "$WORK/old" "$OLD_VERSION" "$OLD_BUILD"
launch "$WORK/old" "$WORK/feed" "$WORK/old.log"
if wait_for 90 said "updates: $NEW_VERSION is verified and will be installed when the app quits" "$WORK/old.log"; then
  shown "$WORK/old.log"
  stop "$WORK/old/Heracles.app"
  # The installer replaces the bundle once the app is gone.
  wait_for 90 has_version "$WORK/old/Heracles.app" "$NEW_VERSION" || true
  NOW="$(version_of "$WORK/old/Heracles.app" 2>/dev/null || echo missing) ($(build_of "$WORK/old/Heracles.app" 2>/dev/null || echo -))"
  if [[ "$NOW" == "$NEW_VERSION ($NEW_BUILD)" ]] && codesign --verify --deep --strict "$WORK/old/Heracles.app" 2>/dev/null; then
    echo "PASS: the copy on disk is now $NOW and its signature verifies"
  else
    echo "FAIL: after quitting, the copy on disk is $NOW, not $NEW_VERSION ($NEW_BUILD)"
    RESULT=1
  fi
else
  stop "$WORK/old/Heracles.app"
  echo "FAIL: the old copy never said it had an update ready. What it logged:"
  grep -E 'updates: ' "$WORK/old.log" | sed -E 's/^.*Heracles\[[0-9:]+\] /  app: /' | tail -8
  [[ -s "$WORK/old.log" ]] || echo "  (nothing)"
  RESULT=1
fi

# --- 2. the updated copy is content --------------------------------------------------
step "2. The updated copy looks at the same feed"
if has_version "$WORK/old/Heracles.app" "$NEW_VERSION"; then
  launch "$WORK/old" "$WORK/feed" "$WORK/updated.log"
  wait_for 60 said "updates: (nothing newer|stopped|found)" "$WORK/updated.log" || true
  wait_for 30 said "updates: menu: " "$WORK/updated.log" || true
  shown "$WORK/updated.log"
  stop "$WORK/old/Heracles.app"
  if said "updates: nothing newer in the feed" "$WORK/updated.log" && ! said "updates: found" "$WORK/updated.log"; then
    echo "PASS: nothing is offered to a copy that is already $NEW_VERSION"
  else
    echo "FAIL: the updated copy did not report that nothing newer is in the feed"
    RESULT=1
  fi
  if menu_says "$MENU_ON" "$WORK/updated.log"; then
    echo "PASS: Check for Updates… can be chosen, and Check for Updates Automatically is ticked"
  else
    echo "FAIL: the menu items for updates do not follow the updater, or the app never said how they stand"
    RESULT=1
  fi
else
  echo "FAIL: there is no updated copy to try (check 1 did not pass)"
  RESULT=1
fi

# refused <name> <feed-folder> <what was done> <reason> [<must not appear>]:
# the old version must stay what it is and give that reason, which is what
# tells a refusal for the right cause from one that merely failed.
refused() {
  make_copy "$WORK/$1" "$OLD_VERSION" "$OLD_BUILD"
  launch "$WORK/$1" "$2" "$WORK/$1.log"
  wait_for 90 said "updates: (stopped|done|.*when the app quits)" "$WORK/$1.log" || echo "  (the app reported nothing within 90 s)"
  sleep 2
  shown "$WORK/$1.log"
  stop "$WORK/$1/Heracles.app"
  sleep 15   # as long as an installer would have needed
  local now
  now="$(version_of "$WORK/$1/Heracles.app" 2>/dev/null || echo missing)"
  if [[ "$now" == "$OLD_VERSION" ]] && said "updates: stopped: $4" "$WORK/$1.log" \
     && ! said "when the app quits" "$WORK/$1.log" && ! { [[ -n "${5:-}" ]] && said "$5" "$WORK/$1.log"; }; then
    echo "PASS: nothing was installed (still $now), refused as improperly signed"
  else
    echo "FAIL: with $3 the copy is $now; expected $OLD_VERSION, no install, and the reason \"$4\" in the log"
    RESULT=1
  fi
}

# --- 3. an archive that was altered after signing is refused -----------------------
# The feed is intact, so the update is found and downloaded; the archive's
# signature is what stops it.
step "3. $OLD_VERSION looks at a feed whose archive was altered after signing"
refused old-bad-archive "$WORK/bad-archive" "the altered archive" "The update is improperly signed"
said "updates: found $NEW_VERSION" "$WORK/old-bad-archive.log" || { echo "FAIL: the update was not even found, so the archive was never judged"; RESULT=1; }

# --- 4. a feed that was altered after signing is refused ---------------------------
# Nothing in such a feed is believed: no update is "found" and nothing is
# downloaded.
step "4. $OLD_VERSION looks at a feed that was altered after signing"
refused old-bad-feed "$WORK/bad-feed" "the altered feed" "The update feed is improperly signed" "updates: (found|downloaded)"
if grep -q "GET /bad-feed/Heracles-" "$WORK/server.log"; then
  echo "FAIL: the archive was downloaded on the word of an altered feed"
  RESULT=1
fi

# --- 5. the same feed once Sparkle's 20 days are over -------------------------------
# Sparkle refuses a badly signed feed for 20 days, counted from a copy's
# first refusal (the date is in the copy's preferences and one good feed
# clears it). After that it reads the feed with restrictions: no notes, no
# links, and no download before the user has agreed. That is its way back
# for a developer who lost the key. Check 4 has just set the date; here it
# is moved back by hand. These copies are set to install without asking,
# so a download would start by itself if anything allowed one.
step "5. $OLD_VERSION looks at the altered feed again, 21 days after first refusing it"
LATER="$WORK/old-bad-feed-later.log"
defaults write "$BUNDLE_ID" SUInitialFailedFeedSigningValidationDate -date "$(date -u -v-21d '+%Y-%m-%d %H:%M:%S +0000')"
launch "$WORK/old-bad-feed" "$WORK/bad-feed" "$LATER"
wait_for 60 said "updates: (found|stopped)" "$LATER" || true
sleep 10   # several times what the download took in check 1
shown "$LATER"
stop "$WORK/old-bad-feed/Heracles.app"
sleep 15   # as long as an installer would have needed
NOW="$(version_of "$WORK/old-bad-feed/Heracles.app" 2>/dev/null || echo missing)"
if ! said "updates: (found|stopped)" "$LATER"; then
  echo "FAIL: the copy said nothing about the feed, so nothing was learned"
  RESULT=1
elif [[ "$NOW" != "$OLD_VERSION" ]] || said "updates: (downloaded|.*when the app quits)" "$LATER" \
     || grep -q "GET /bad-feed/Heracles-" "$WORK/server.log"; then
  echo "FAIL: 21 days on, the altered feed got further than an offer: the copy is $NOW, expected $OLD_VERSION and no download"
  RESULT=1
elif said "updates: found $NEW_VERSION" "$LATER"; then
  echo "PASS: the feed is read now, as Sparkle's 20-day rule has it, and nothing was downloaded or installed (still $NOW)"
else
  echo "PASS: nothing was downloaded or installed (still $NOW). The feed was refused again, though: this Sparkle"
  echo "      does not have the 20-day rule described for 2.10; bring BUILDING.md up to date"
fi

echo
[[ "$RESULT" == 0 ]] && echo "update rehearsal: all six checks passed" || echo "update rehearsal: FAILED"
exit "$RESULT"
