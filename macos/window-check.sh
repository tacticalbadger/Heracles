#!/usr/bin/env bash
# Checks what only the running app has, its menu bar and its windows, with
# nothing real in it: a copy of the current build given a bundle identifier
# of its own, and a library in the work folder. Not the real library, not
# the app's own preferences, not the windows it remembers.
#
#   macos/window-check.sh [work-dir]      default: build/window-check
#
# The copy is started with --window-check. It then checks itself
# (macos/Sources/HeraclesApp/WindowCheck.swift), prints one line per check
# and ends: that File has New Window and it opens another window on the
# library, that Format has Divider, and that a task opens in a window of
# its own, one for each task, which follows the task's name and closes when
# the task is deleted or its list goes to the trash.
#
# Needs build/Heracles.app (macos/build-app.sh, or a release build). The
# copy's windows show on the screen for a few seconds. It does not take the
# keyboard. Every run removes its work folder and what the copy kept under
# its own bundle identifier in ~/Library (KEEP=1 keeps the work folder).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/Heracles.app"
WORK="${1:-$ROOT/build/window-check}"
BUNDLE_ID="com.heracles.notes.native.window-check"
COPY="$WORK/Heracles.app"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[[ -d "$APP" ]] || fail "no app bundle at build/Heracles.app; run macos/build-app.sh first"

# What the copy keeps outside the work folder, under its own bundle
# identifier: preferences, and the windows it had open. Removed before a
# run, so that nothing an earlier one left decides this one, and after it.
# Only ever for an identifier below the app's own, never for the app's.
forget_copy() {
  [[ "$BUNDLE_ID" == com.heracles.notes.native.?* ]] || return 0
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
}

cleanup() {
  pkill -f "$COPY/Contents/MacOS/Heracles" 2>/dev/null || true
  forget_copy
  [[ -n "${KEEP:-}" ]] || rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"
forget_copy

step "Making a copy of the build with an identifier of its own"
ditto "$APP" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$COPY/Contents/Info.plist"
# The copy is signed again, since its Info.plist changed: ad hoc is enough
# to run on this Mac.
macos/sign-app.sh "$COPY" - >/dev/null 2>&1
codesign --verify --deep --strict "$COPY" || fail "the copy does not verify after signing"

step "The copy checks its menus and windows"
STATUS=0
# -ApplePersistenceIgnoreState: no windows from an earlier run are put back.
HERACLES_DATA_DIR="$WORK/library" "$COPY/Contents/MacOS/Heracles" --window-check \
  -ApplePersistenceIgnoreState YES 2>"$WORK/stderr.log" | tee "$WORK/check.log" || STATUS=$?

if [[ "$STATUS" -ne 0 ]] || ! grep -q '^WINDOW CHECK PASSED$' "$WORK/check.log"; then
  sed 's/^/    /' "$WORK/stderr.log" | tail -20 >&2
  KEEP=1
  fail "the window check did not pass (exit $STATUS); the work folder is kept at $WORK"
fi
printf '\nThe window check passed.\n'
