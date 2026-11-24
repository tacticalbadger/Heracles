# Building Heracles

Heracles is a native Mac app: a Swift interface over a Rust core. Version
0.4.0 is its current preview release. For what works and what has not been
checked, see [`docs/status.md`](./docs/status.md).

## Prerequisites

You need Rust (via [rustup](https://rustup.rs), with the `aarch64-apple-darwin`
and `x86_64-apple-darwin` targets), Xcode, and Git.

```bash
git clone https://github.com/tacticalbadger/Heracles.git
cd Heracles
```

## Building

```bash
macos/build-app.sh              # universal build → build/Heracles.app
macos/build-app.sh --host-only  # this Mac's processor only, faster
```

The script runs two steps, which you can also run one at a time:

| Step | Command | Produces |
| --- | --- | --- |
| Rust core | `macos/build-core.sh` | `macos/Frameworks/HeraclesCoreFFI.xcframework` and the Swift bindings in `macos/Sources/HeraclesCore/Generated/` |
| App | `swift build --package-path macos` | the `Heracles` executable |

Both outputs are git-ignored. After changing Rust code, run
`macos/build-core.sh` again before building or testing the Swift package.

The app has one dependency that is not built here: Sparkle, which installs
updates. SwiftPM downloads it the first time, at the version pinned in
`macos/Package.swift`, and `build-app.sh` copies it into the bundle.

`build-app.sh` signs the app ad hoc, which runs on the Mac that built it. For
a build to give to someone else, see [Releasing](#releasing).

### Tests

```bash
cargo test                           # the core: storage, documents, search, import
swift test --package-path macos      # the bindings, the app's model, the editor
build/Heracles.app/Contents/MacOS/Heracles --self-test
```

The editor's tests drive the real text views in a window that is never
shown: they type, press Return and Backspace, move with the arrow keys, and
paste, and check what the document holds afterwards.

`--self-test` does the same in the built app against a throwaway library: it
opens a note, types into it, and checks that the edit reaches the core, is
searchable, and survives a save from elsewhere. It prints one line per check
and exits 0 if all pass.

`Heracles --snapshot <folder>` draws the app's window and the editor, filled
with a sample note that has one of every kind of block, into PNG files. It is
a way to look at the interface from a script.

Two more checks belong to releases and are described under
[Releasing](#releasing): `macos/test-release-scripts.sh`
and `macos/update-rehearsal.sh`.

### The app icon

The icon is a notebook page with a heading, a checklist and lines of text.
Its source is `macos/Icon/Heracles.icon`, an Icon Composer document: a
background, the page, and what is written on the page, as SVG layers, each
with its colours for the light and the dark style. Open it in Icon Composer,
which comes with Xcode, or edit `icon.json` and the SVG files in `Assets/` by
hand. Then compile it:

```bash
macos/make-icon.sh
```

This needs Xcode 26 or later. It writes three files into `macos/Icon/`. All
three are kept in the repository, so building the app does not need the
script.

| File | What it is |
| --- | --- |
| `Assets.car` | The layered icon, which macOS 26 and later draw in their light, dark, clear and tinted styles. It also holds pictures of the icon for macOS 14 and 15. |
| `Heracles.icns` | The plain icon file, for whatever still asks for one |
| `Heracles.png` | A picture of the icon, shown in the README |

`build-app.sh` copies the first two into the app, and `--self-test` checks
that they arrived.

## Releasing

```bash
macos/release.sh                  # build, sign, notarize, staple, make the disk image and the feed
macos/release.sh --skip-notarize  # stop after signing
macos/update-rehearsal.sh         # rehearse an update with the build just made
macos/publish.sh --check          # every check before publishing, and nothing else
macos/publish.sh                  # publish it on GitHub
```

`release.sh` builds the universal app, signs it with the Developer ID
certificate under the hardened runtime, runs the signed app's self-test, has
Apple notarize it, and staples the ticket. It then puts the app in a disk
image beside a link to the Applications folder, signs the image, and has
Apple notarize that too. Last, it signs the zip with the update key and
writes the update feed. The result, in `build/`:

| File | What it is |
| --- | --- |
| `Heracles.app` | The app |
| `Heracles-<version>-mac.dmg` | The disk image people download |
| `Heracles-<version>-mac.zip` | The same app, zipped. Installed copies download this one when they update |
| `appcast.xml` | The update feed: which version is the newest, where its zip is, and the signatures |

The image is a plain one: it opens as a window with the app and the
Applications folder in it, with no background picture or arranged icons.

The app needs no hardened-runtime exceptions and has no entitlements file.
It is one executable with the Rust core linked into it, plus Sparkle's
framework and its two helper programs, and it runs no JavaScript. The
script checks every executable in the bundle for a secure timestamp, the
hardened runtime, no entitlements, and no file path from the Mac it was
built on.

The signing certificate is found in the keychain: the first Developer ID
Application certificate there. Set `CODESIGN_IDENTITY` to a name or a SHA-1
to use a different one.

Notarizing needs credentials. An App Store Connect API key:

```bash
export APPLE_API_KEY=/path/to/AuthKey_XXXXXXXXXX.p8
export APPLE_API_KEY_ID=XXXXXXXXXX
export APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
macos/release.sh
```

An Apple ID with an app-specific password, made at account.apple.com, works
too:

```bash
export APPLE_ID=you@example.com
export APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
macos/release.sh
```

Or save either kind once with `xcrun notarytool store-credentials heracles`
and run `NOTARY_PROFILE=heracles macos/release.sh`.

The script checks the credentials with Apple before it builds, so a missing
or mistyped one fails at once.

To publish a version:

1. In `macos/Info.plist`, set `CFBundleShortVersionString` and raise
   `CFBundleVersion`, the build number. Add a section for the version to
   `CHANGELOG.md`, and write `docs/release-notes/<version>.md`: a few
   Markdown bullets, which the update window shows and the release page
   repeats.
2. Commit, and push the branch.
3. Run `macos/release.sh`.
4. Run `macos/update-rehearsal.sh`.
5. Run `macos/publish.sh`. It needs the GitHub CLI, signed in.

The build number matters as much as the version. Sparkle compares build
numbers to decide whether an update is newer, so a release that keeps the
old number is never offered to anyone. `release.sh` reads the published
feed first and stops if the number has not gone up.

`publish.sh` tags the commit, creates the release **as a draft**, attaches
the disk image, the zip and the feed, reads their sizes and SHA-256 back
from GitHub, and only then publishes the release as the latest one. The
order matters. This repository has immutable releases turned on: once a
release is published, files cannot be added to it, replaced or removed, and
its tag name can never be used again, even if the release is deleted. 0.2.0
was published before its file was attached, which is why the first preview
was 0.2.1.

Before it tags anything, `publish.sh` refuses a build that is not notarized,
a feed that was written for a different zip or build number, a zip whose
signature does not verify against the update key, uncommitted changes, and
a commit that is not on GitHub. Afterwards it checks that the address
installed copies read serves the new feed.

Releases before 0.4.0 are no longer published. Their pages were deleted on
2026-11-24, because those builds held file paths from the Mac they were made
on, and a published release here cannot have its files replaced. `release.sh`
checks every build for such paths now. 0.4.0 is the first release with a
feed, and the first that updates itself. The version numbers 0.2.0 to 0.3.3
cannot be used again.

### Updates

The app updates itself with [Sparkle](https://sparkle-project.org). Once a
day, and from **Heracles ▸ Check for Updates…**, it reads

```
https://github.com/tacticalbadger/Heracles/releases/latest/download/appcast.xml
```

which GitHub serves from the newest release, so there is no server to run.
If the feed names a build newer than the one running, the app shows the
release notes and, when the user agrees, downloads the zip, checks it, and
replaces itself when it quits. Quitting to install goes through the app's
ordinary quit, which waits for every editor to save.

Three things follow from that address being built into every copy:

- **Every release must carry the feed, and must be the latest release.** A
  release without `appcast.xml`, or one marked as a pre-release, stops
  updates for everyone until the next good one, and nothing reports it.
  `publish.sh` exists to make that mistake impossible.
- **The repository cannot be renamed or moved** without first shipping a
  build that knows the new address. Until then GitHub's redirect is all that
  keeps installed copies updating.
- **Versions before 0.4.0 have no updater.** They have to be replaced by
  hand once.

The release notes in the feed are Markdown, which Sparkle draws in a text
view. It shows HTML notes in a web view, and the app has none, so
`release.sh` refuses a feed whose notes are anything else.

A run started for a trial or a test does not look for updates: a library
named with `HERACLES_DATA_DIR`, `--self-test` and `--snapshot`. Otherwise a
trial copy would be offered the published app.

### The update key

An update is installed only if the feed and the zip both carry a signature
made with the update key. Its public half is in `macos/update-config.sh` and
so in every copy of the app. Its private half is in the login keychain of
the Mac that makes releases, under the account `heracles-update-key`, and
nowhere else: not in the repository and not in any file a script writes.
Whoever controls the GitHub account can therefore withhold an update, and
cannot supply one.

Sparkle's tools manage the key. SwiftPM unpacks them into
`macos/.build/artifacts/sparkle/Sparkle/bin`:

```bash
generate_keys --account heracles-update-key -p          # show the public half
generate_keys --account heracles-update-key -x <file>   # write the private half to a file
generate_keys --account heracles-update-key -f <file>   # take it from a file, on another Mac
```

- **Keep a copy of the private half somewhere safe**, such as a password
  manager: export it with `-x`, store the file's contents, and delete the
  file. If the key is lost, installed copies stop taking updates.
- A second Mac cannot make a release until the key has been brought over
  with `-x` and `-f`. `release.sh` compares the keychain's key with the one
  in `update-config.sh` and stops on a difference. `HERACLES_UPDATE_KEY_FILE`
  names a file that holds the key, for a Mac whose keychain should not.
- The first time `release.sh` signs with the key on a Mac, macOS asks
  whether `generate_appcast` may use it. Choose Always Allow, or an
  unattended release waits on that question.
- This is Heracles' own key. Toolbox, the owner's other app that updates
  the same way, has a different one.

Sparkle keeps two provisions for a developer who has lost the key, and they
are part of what the key protects. A copy that has seen no properly signed
feed for 20 days reads a badly signed one after all, with restrictions: no
notes, no links, and nothing downloaded before the user agrees. And an
archive that fails the key is still taken if the file itself is signed with
the app's Developer ID, which a disk image can be and a zip cannot. So the
Developer ID certificate's private key is a second key to updates, and
deserves the same care. Both rules were read from Sparkle 2.10.1's source
for Toolbox and are written up in that project's security review, in the
addendum on updates over the air. Do not restate them from memory.

### Checking updates without a release

```bash
macos/test-release-scripts.sh   # a few seconds; no build needed
macos/update-rehearsal.sh       # a few minutes; needs build/Heracles.app
```

`test-release-scripts.sh` checks the two safeguards that the release
scripts lean on: that `verify-update.sh` accepts a file only with a
signature made by the key it is given, and that `check-build-number.sh`
stops a build number that has not gone up.

`update-rehearsal.sh` rehearses a whole update with nothing real in it. It
makes a key for the run, two copies of the current build that claim to be
versions 9.9.1 and 9.9.2 under a bundle identifier of their own, a library
in its work folder, and a feed served from this Mac. It passes only if:

0. a copy with a library of its own and no feed named does not look at all,
   and its two menu items for updates are greyed out;
1. the old copy finds the new one, verifies it, and is the new version on
   disk once it has quit;
2. the updated copy is then offered nothing, its Check for Updates… item
   can be chosen, and Check for Updates Automatically is ticked;
3. a zip altered after signing is refused, for that reason;
4. a feed altered after signing is refused, for that reason, with nothing
   downloaded;
5. the same feed, 21 days on, is read under Sparkle's 20-day rule and still
   gets nothing downloaded.

The menu items are read the way the menu draws them. SwiftUI brings a
menu's items up to date when the menu is about to open, not when what they
show changes, so the copy tells its menu that first; looked at without it,
the items are as they were at launch, before the updater had started.

The copies start behind whatever is in front, though a window of theirs may
show. The run touches neither the real update key nor GitHub nor the real
library, and removes what its copies kept in `~/Library`.

## Trying it without touching your library

By default the app uses `~/Library/Application Support/Heracles/`. If the
original Heracles app (version 0.1) left a library there, `heracles.sqlite`,
the first launch imports it into a new `heracles.db`. The old database is
backed up and never modified. To use a different folder:

```bash
HERACLES_DATA_DIR=/tmp/heracles-trial build/Heracles.app/Contents/MacOS/Heracles
```

## If `xcodebuild` or `swift test` cannot find Xcode

When the command line tools are selected instead of Xcode, the build scripts
find `/Applications/Xcode.app` by themselves. For commands you run directly,
either select Xcode once with `sudo xcode-select -s /Applications/Xcode.app`,
or prefix the command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos
```
