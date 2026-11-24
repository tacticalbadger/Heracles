# Updates over the air for the native Mac app

Approved by the owner on 2026-11-24. A short design: the work follows what
Toolbox already ships (its 0.5.0), adapted to how Heracles is built and
released.

## Why

Through 0.3.3 a new version of Heracles is installed by downloading a disk
image and replacing the app. The owner wants Heracles to update itself the
way Toolbox does, so that nobody has to do that again.

## Goals

- The app looks for a new version once a day, and when asked from the
  menu, shows what changed, and installs when the user agrees.
- An update is installed only if the owner signed it. Whoever controls the
  place the files are served from can withhold an update and cannot supply
  one.
- A release cannot be published in a state that silently stops updates.
- The whole path can be rehearsed on one Mac with nothing real in it.

## Not goals

- Installing updates without asking.
- Delta updates, beta channels, or a server of our own.
- Updates for the Electron app, which keeps its own updater.
- Telling 0.3.3 and earlier that a new version exists. They have no
  updater: 0.4.0 is the last version installed by hand.

## What would make this a failure even if it works

- A web view in the app. Release notes are written as Markdown, which
  Sparkle 2.10.1 draws in a text view (`SUTextViewReleaseNotesView`). HTML
  notes would bring up its web view, so the feed never carries any.
- An entitlement or a hardened-runtime exception that the app does not
  have today.
- A test run (`--self-test`, `--snapshot`, or a library named with
  `HERACLES_DATA_DIR`) that finds the real release and offers to replace
  itself with it.
- The owner's real name, or a path from the build Mac, in the repository
  or in the download.

## Constraints

- Releases on GitHub are immutable. The feed has to be attached while the
  release is a draft, and the release has to be the latest one, not a
  pre-release, or `releases/latest/download/appcast.xml` does not serve it.
- The app is a universal build made by SwiftPM (`--arch arm64 --arch
  x86_64`) and assembled by `macos/build-app.sh`. There is no Xcode
  project.
- The app is not sandboxed and has no entitlements.
- Quitting waits for every editor to save. An update installs through the
  same quit.

## Approaches

1. **Sparkle 2, as in Toolbox (chosen).** A framework that does the
   checking, the signature checks, the window and the swap of the bundle.
   It is what `docs/review-and-native-rewrite.md` planned, it is in use in
   the owner's other app, and its behavior when a signature fails has
   already been read from its source and rehearsed there.
2. **An updater of our own** over the GitHub releases API. Rejected: it
   means writing the download, the signature check and the replacement of
   a running app, which is where updaters go wrong, for no gain.
3. **The plan's original feed on the R2 bucket.** Rejected: a file on each
   GitHub release needs no server and no second set of credentials, and
   Toolbox has shown that it works.

## Decisions

The owner's:

- Build it as Toolbox has it.
- **Heracles gets an update key of its own**, not Toolbox's: login
  keychain, account `heracles-update-key`. A copy goes into the owner's
  password manager.
- Publish 0.4.0 in the same session once the build is notarized and the
  rehearsal passes.

Made while building, each easy to change before 0.4.0 and hard after:

- The feed is `appcast.xml` on every release, read from
  `https://github.com/tacticalbadger/Heracles/releases/latest/download/appcast.xml`.
  The address and the public key are built into every copy.
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are on.
  Sparkle's two provisions for a lost key stay at their defaults, as in
  Toolbox; the Toolbox security review (0.5.0 addendum) has what they
  mean.
- The daily check is on by default and asks before installing.
- Sparkle's XPC services are left out of the bundle. They are for
  sandboxed apps.
- The signing certificate is found in the keychain, not named in a
  script.
- `CFBundleVersion` stays a number in `macos/Info.plist`, raised by hand
  with each release. The release script refuses a build number that is
  not higher than the one in the published feed.
- Publishing goes through a script that uses the GitHub CLI: draft,
  attach, compare with the local files, publish as latest.

## The parts

- `macos/update-config.sh`: the repository, the feed address, the key's
  account and public half, and where Sparkle's tools are. Read by the
  scripts below.
- `macos/Package.swift`: Sparkle, pinned to 2.10.1.
- `macos/Sources/HeraclesApp/Updates.swift`: starts the standard updater
  unless this is a test run or the bundle has no feed address and key;
  logs one `updates:` line per event.
- `Commands.swift` and `HeraclesApp.swift`: Heracles ▸ Check for Updates…
  and Check for Updates Automatically; start the updater at launch.
- `macos/Info.plist`: the three `SU…` switches (automatic checks, signed
  feed, verify before extraction); version 0.4.0.
- `macos/build-app.sh`: the framework into `Contents/Frameworks`, the
  search path for it, SwiftPM's own search path removed, Sparkle's
  license text into the bundle, the feed address and key written into the
  bundle's Info.plist from `update-config.sh`, so both have one source.
- `macos/sign-app.sh`: signs the framework's parts from the inside out and
  then the app. The build, the release and the rehearsal all use it.
- `macos/release.sh`: checks that nothing names the build Mac, makes the
  zip the way Sparkle asks, writes and signs the feed, and checks the
  archive's signature against the key in the built app.
- `macos/build-core.sh`: source paths rewritten in the Rust library. The
  published 0.3.3 holds 150 strings under the build Mac's home folder.
- `macos/check-build-number.sh` and `macos/verify-update.sh`: the two
  safeguards the release scripts lean on, as scripts of their own so that
  `macos/test-release-scripts.sh` can check them without a build.
- `macos/publish.sh`: the draft-first release, refusing one without a
  feed written for exactly that archive.
- `macos/update-rehearsal.sh`: a whole update between two relabelled
  copies with a key made for the run, plus an altered archive, an altered
  feed, and the 20-day case.
- `docs/release-notes/<version>.md`: what the update window shows.
- README, BUILDING, CHANGELOG and the rewrite status.

## Left to the builder

- Where SwiftPM puts `Sparkle.framework` in a universal build, and what it
  leaves in the executable's search paths.
- How the menu items learn whether a check can start (Sparkle's
  `canCheckForUpdates` is observable).
- The exact checks in the rehearsal, taking Toolbox's as the model.
