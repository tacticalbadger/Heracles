#!/bin/sh
# Build Heracles.app, the native Mac app, into build/.
#
# Usage: macos/build-app.sh [--host-only]
#   --host-only   build for this Mac's processor only. Faster, for development.
#
# The app is signed ad hoc, which is enough to run it on this Mac. For a
# build to give to someone else, see release.sh.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if ! xcodebuild -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ "${1:-}" = "--host-only" ]; then
    ARCH_FLAGS=""
else
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

macos/build-core.sh "$@"

echo "==> Building the app"
# shellcheck disable=SC2086  # the flags are meant to split into arguments
swift build --package-path macos --configuration release $ARCH_FLAGS
# shellcheck disable=SC2086
PRODUCTS=$(swift build --package-path macos --configuration release $ARCH_FLAGS --show-bin-path)

APP=build/Heracles.app
BINARY="$APP/Contents/MacOS/Heracles"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp macos/Info.plist "$APP/Contents/Info.plist"
cp "$PRODUCTS/Heracles" "$BINARY"
# The icon, compiled by macos/make-icon.sh and kept in the repository.
cp macos/Icon/Assets.car macos/Icon/Heracles.icns "$APP/Contents/Resources/"

# Where updates come from and the key they are checked against. Written
# here, so that update-config.sh is the one place that says.
. macos/update-config.sh
/usr/libexec/PlistBuddy \
    -c "Add :SUFeedURL string $UPDATE_FEED_URL" \
    -c "Add :SUPublicEDKey string $UPDATE_PUBLIC_KEY" "$APP/Contents/Info.plist"

# Sparkle (over-the-air updates) is a framework with two helper programs
# inside. It is taken from the package's own copy, which holds both
# processors' code whichever of them the app was built for.
SPARKLE_SOURCE="$SPARKLE_BIN/../Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$SPARKLE"
# The app is not sandboxed, so Sparkle's two XPC services are never used.
# Headers and module maps are for building against the framework.
for PART in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "$SPARKLE/Versions/B/$PART" "$SPARKLE/$PART"
done
# Sparkle's license asks that its notice travels with every copy.
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$SPARKLE_BIN/../LICENSE" "$APP/Contents/Resources/Licenses/Sparkle.txt"

# The executable finds the framework beside it in the bundle. SwiftPM
# leaves search paths into its own build folder instead, which the bundle
# has no use for and which would name the Mac the build was made on.
RPATHS=$(otool -l "$BINARY" | awk '/LC_RPATH/ {getline; getline; print $2}' | sort -u)
for RPATH in $RPATHS; do
    case "$RPATH" in
        "$ROOT"/*) install_name_tool -delete_rpath "$RPATH" "$BINARY" ;;
    esac
done
case "$RPATHS" in
    *@executable_path/../Frameworks*) ;;
    *) install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" ;;
esac

# Ad hoc, the framework's parts first. Enough to run on this Mac.
macos/sign-app.sh "$APP" - 2>/dev/null

echo "Built $APP"
