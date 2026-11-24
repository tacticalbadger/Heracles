# Over-the-air updates: where the app looks for them and the key they are
# checked against. Read by build-app.sh (the app's Info.plist), release.sh
# (the feed), publish.sh and update-rehearsal.sh. Expects ROOT to be set to
# the repository's folder. Plain sh: two of those scripts are not bash.
#
# The feed is a small file attached to every GitHub release;
# "releases/latest/download" always serves the newest release's copy, so
# there is no server to run. Every build that has shipped carries this
# address: if the repository is renamed or moved, GitHub's redirect is all
# that keeps those copies updating, so ship a build with the new address
# before relying on anything else.
UPDATE_REPO="tacticalbadger/Heracles"
UPDATE_FEED_URL="https://github.com/$UPDATE_REPO/releases/latest/download/appcast.xml"

# The public half of the update key (EdDSA). The app takes an update, and
# the feed that announces it, only if they are signed with the private
# half. That half lives in the login keychain of the Mac that makes
# releases, under the account name below, and never in the repository. It
# is Heracles' own key, not the one Toolbox uses. Sparkle's tools manage it:
#   $SPARKLE_BIN/generate_keys --account heracles-update-key -p        show the public key
#   $SPARKLE_BIN/generate_keys --account heracles-update-key -x FILE   write the private key to FILE (to move or back up)
#   $SPARKLE_BIN/generate_keys --account heracles-update-key -f FILE   take the private key from FILE (on another Mac)
# Lose the private key and updates stop, for 20 days at least. After that
# Sparkle has a provision for a lost key, which has not been tried here;
# until then everyone downloads a build by hand. Keep a copy of the key
# somewhere safe. BUILDING.md has more.
UPDATE_KEY_ACCOUNT="heracles-update-key"
UPDATE_PUBLIC_KEY="+odiQ43CFVwZFB3t7TE70grpr3zccLLDT8fbMreJOxE="

# Sparkle's command-line tools, unpacked by SwiftPM with the framework
# (after `swift package --package-path macos resolve`, or any build).
SPARKLE_BIN="$ROOT/macos/.build/artifacts/sparkle/Sparkle/bin"
