# Updates over the air: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The native Mac app finds, verifies and installs its own updates, and 0.4.0 is published as the first version that can.

**Architecture:** Sparkle 2 does the checking, the window and the swap of the bundle. The feed is a signed `appcast.xml` attached to every GitHub release. One shell file holds where the feed is and which key it is checked against; the build, release, publish and rehearsal scripts all read it.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing), Sparkle 2.10.1, POSIX shell and bash scripts, the GitHub CLI.

**Spec:** `docs/superpowers/specs/2026-11-24-ota-updates-design.md`. The working model is Toolbox: `~/code/Toolbox` at `6aa9e34` (`App/Sources/App/Updates.swift`, `bridge/update-config.sh`, `bridge/bundle-app.sh`, `bridge/release.sh`, `bridge/publish.sh`, `tools/e2e/update-rehearsal.sh`).

## Global Constraints

- Sparkle is pinned: `exact: "2.10.1"`.
- Minimum macOS stays 14.0. The build stays universal (arm64 and x86_64).
- No web view: the feed carries Markdown release notes only, never HTML.
- No entitlements and no hardened-runtime exceptions on any executable in a release.
- Sparkle's XPC services are not in the bundle.
- Nothing in git or in the download names the owner or the build Mac: no real name, no `/Users/<account>` path.
- Bundle identifier: `com.heracles.notes.native`. Repository: `tacticalbadger/Heracles`.
- Feed address: `https://github.com/tacticalbadger/Heracles/releases/latest/download/appcast.xml`.
- Update key: login keychain, account `heracles-update-key`. The private half is never written to a file by a script, and never to the repository.
- `xcodebuild` and `swift test` need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on this Mac.
- Commit messages follow the repository's style (`feat(macos): …`, `build(macos): …`, `docs: …`, `chore(release): …`).

## Review Focus

Conditions the spec implies and unit tests do not reach, most likely first. Each is pinned by a check in the task named.

1. **A release goes out without its feed, as a pre-release, or with a feed for another archive.** Updates stop for everyone and nothing says so. Expected: publishing refuses. Task 5, steps 1 and 3.
2. **A build number that did not go up.** Sparkle compares `CFBundleVersion`; an update with the same number is never offered. Expected: the release stops before notarizing. Task 4, step 2.
3. **A test run meets the real feed.** A run with `HERACLES_DATA_DIR` set would offer to replace a trial copy. Expected: the updater does not start. Task 2 (unit tests) and Task 6, check 0.
4. **An Intel Mac.** A feed that says `arm64` only would hide the update from Intel copies. Expected: the feed has no `sparkle:hardwareRequirements`, and `Sparkle.framework` in the bundle holds both architectures. Task 3, step 4 and Task 4, step 5.
5. **Text typed just before an update installs.** Installing quits the app. Expected: the quit goes through `applicationShouldTerminate`, which waits for every editor to save. Sparkle quits through `NSApp.terminate`; Task 2, step 6 checks that the delegate method is untouched, and the final report says this path was not exercised by hand.

---

### Task 1: Sparkle in the package, the update key, the shared settings

**Files:**
- Modify: `macos/Package.swift`
- Create: `macos/Package.resolved` (written by SwiftPM, committed)
- Create: `macos/update-config.sh`

**Interfaces:**
- Produces: `macos/update-config.sh`, sourced with `ROOT` set to the repository root. It defines `UPDATE_REPO="tacticalbadger/Heracles"`, `UPDATE_FEED_URL`, `UPDATE_KEY_ACCOUNT="heracles-update-key"`, `UPDATE_PUBLIC_KEY` (base64, 44 characters), `SPARKLE_BIN="$ROOT/macos/.build/artifacts/sparkle/Sparkle/bin"`. It is plain `sh`, with no bash-only syntax, because `build-app.sh` and `release.sh` are `sh` scripts.
- Produces: the `Sparkle` product, a dependency of the `HeraclesApp` target.

- [ ] **Step 1:** Add `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")` to `macos/Package.swift` and `.product(name: "Sparkle", package: "Sparkle")` to the `HeraclesApp` target's dependencies.
- [ ] **Step 2:** Run `macos/build-core.sh --host-only`, then `swift package --package-path macos resolve`. Expected: `macos/.build/artifacts/sparkle/Sparkle/bin/generate_keys` exists and `macos/Package.resolved` names Sparkle 2.10.1.
- [ ] **Step 3:** Make the key: `macos/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account heracles-update-key`. Expected: it prints a public key. `generate_keys --account heracles-update-key -p` prints the same one again.
- [ ] **Step 4:** Write `macos/update-config.sh` with the values above and that public key, with a comment block carrying what Toolbox's file says about the key (how to show, export and import it; what losing it means).
- [ ] **Step 5:** Check: `sh -c 'ROOT=$PWD; . macos/update-config.sh; test "$("$SPARKLE_BIN/generate_keys" --account "$UPDATE_KEY_ACCOUNT" -p)" = "$UPDATE_PUBLIC_KEY" && echo same'` prints `same`.
- [ ] **Step 6:** Commit: `build(macos): Sparkle in the package, and where updates come from`.

### Task 2: The updater in the app

**Files:**
- Create: `macos/Sources/HeraclesApp/Updates.swift`
- Create: `macos/Tests/HeraclesAppTests/UpdatePolicyTests.swift`
- Modify: `macos/Sources/HeraclesApp/HeraclesApp.swift` (`AppDelegate.applicationDidFinishLaunching`)
- Modify: `macos/Sources/HeraclesApp/Commands.swift`
- Modify: `macos/Info.plist`

**Interfaces:**
- Produces, for the rehearsal (Task 6): the launch arguments `--updater-feed <url>` and `--demo-update`, and one log line per event on stderr, each starting `updates: `, with exactly these texts:
  - `updates: looking for an update (active: true|false)` (only with `--demo-update`)
  - `updates: found <version> (<build>)`
  - `updates: downloaded <version>`
  - `updates: <version> is verified and will be installed when the app quits`
  - `updates: installing <version>`
  - `updates: stopped: could not download <version>: <reason>`
  - `updates: nothing newer in the feed`
  - `updates: stopped: <reason> (<domain> <code>)`
  - `updates: done`

- [ ] **Step 1: Write the failing tests** in `UpdatePolicyTests.swift`, for

```swift
enum UpdatePolicy: Equatable {
    case off
    /// `feed` is nil for the address in the Info.plist.
    case on(feed: String?)
    static func decide(arguments: [String], environment: [String: String], info: [String: Any]) -> UpdatePolicy
}
```

With `let ready: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"]`:

| Test | arguments | environment | info | expected |
| --- | --- | --- | --- | --- |
| `anEverydayRunLooksAtTheBuiltInFeed` | `["Heracles"]` | `[:]` | `ready` | `.on(feed: nil)` |
| `aBundleWithoutFeedOrKeyDoesNotLook` | `["Heracles"]` | `[:]` | `[:]`, then `ready` without each key in turn | `.off` |
| `aTrialLibraryDoesNotLook` | `["Heracles"]` | `["HERACLES_DATA_DIR": "/tmp/x"]` | `ready` | `.off` |
| `anEmptyDataDirIsAnEverydayRun` | `["Heracles"]` | `["HERACLES_DATA_DIR": ""]` | `ready` | `.on(feed: nil)` |
| `aRehearsalNamesItsOwnFeed` | `["Heracles", "--updater-feed", "http://127.0.0.1:1/a.xml"]` | `["HERACLES_DATA_DIR": "/tmp/x"]` | `ready` | `.on(feed: "http://127.0.0.1:1/a.xml")` |
| `anEverydayRunTakesNoFeedFromTheCommandLine` | `["Heracles", "--updater-feed", "http://evil.example/a.xml"]` | `[:]` | `ready` | `.on(feed: nil)` |
| `aFeedFlagWithoutAValueIsIgnored` | `["Heracles", "--updater-feed"]` | `["HERACLES_DATA_DIR": "/tmp/x"]` | `ready` | `.off` |
| `selfTestAndSnapshotRunsDoNotLook` | `["Heracles", "--self-test"]`, and `["Heracles", "--snapshot", "/tmp/s"]` | `[:]` | `ready` | `.off` |
| `aRehearsalStillNeedsAKey` | as `aRehearsalNamesItsOwnFeed` | same | `["SUFeedURL": "x"]` | `.off` |

- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos --filter UpdatePolicyTests`. Expected: it does not compile, `UpdatePolicy` is not defined.
- [ ] **Step 3:** Implement `UpdatePolicy` in `Updates.swift`. Run the same command. Expected: 9 tests pass.
- [ ] **Step 4:** Add the rest of `Updates.swift`, after Toolbox's `Updates.swift`:

```swift
@MainActor @Observable
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    /// Starts Sparkle's standard updater if `UpdatePolicy.decide` says so.
    func start()
    var isActive: Bool { get }
    /// Follows `SPUUpdater.canCheckForUpdates` by key-value observation, so menu items redraw.
    private(set) var canCheckForUpdates: Bool
    var checksAutomatically: Bool { get set }
    func checkForUpdates()        // what the menu item does
    func checkInBackground()      // what the daily check does
}
```

The delegate methods log the lines listed under Interfaces with `NSLog`, and `feedURLString(for:)` returns the rehearsal's feed. Nothing is logged from Sparkle's "did extract" callback: it arrives before the signature is checked.
- [ ] **Step 5:** In `Commands.swift` add `CommandGroup(after: .appInfo)` with `Button("Check for Updates…")`, disabled while `!Updates.shared.canCheckForUpdates`, and `Toggle("Check for Updates Automatically", …)` bound to `checksAutomatically`, disabled while `!Updates.shared.isActive`.
- [ ] **Step 6:** In `AppDelegate.applicationDidFinishLaunching` call `Updates.shared.start()`; with `--demo-update` among the arguments, two seconds later log `updates: looking for an update (active: …)` and call `checkInBackground()`. Do not touch `applicationShouldTerminate`: `git diff macos/Sources/HeraclesApp/HeraclesApp.swift` shows no change inside it.
- [ ] **Step 7:** In `macos/Info.plist` add `SUEnableAutomaticChecks`, `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`, all `true`, with a comment saying that `build-app.sh` adds the address and the key.
- [ ] **Step 8:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos`. Expected: every test passes, the earlier ones included.
- [ ] **Step 9:** Commit: `feat(macos): look for updates and install them with Sparkle`.

### Task 3: The framework in the bundle

**Files:**
- Create: `macos/sign-app.sh`
- Modify: `macos/build-app.sh`
- Modify: `macos/build-core.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `macos/sign-app.sh <app> <identity> [--release]`. Signs, in this order and each by itself, never with `--deep`: `Sparkle.framework/Versions/B/Autoupdate`, `…/Versions/B/Updater.app`, `Sparkle.framework`, then the app. `--release` adds `--options runtime --timestamp`. `-` as the identity signs ad hoc. Works on a bundle without the framework.
- Produces: `build/Heracles.app` with `Contents/Frameworks/Sparkle.framework`, `Contents/Resources/Licenses/Sparkle.txt`, and `SUFeedURL` and `SUPublicEDKey` in its Info.plist, taken from `update-config.sh`.

- [ ] **Step 1:** In `build-core.sh`, build the library with `RUSTFLAGS` carrying `--remap-path-prefix` for `$HOME`, for Cargo's home and for `$ROOT` (to `/home`, `/cargo`, `/heracles`), as Toolbox's `bridge/build-core.sh` does. The published 0.3.3 holds 150 strings under `/Users/<account>/.cargo`.
- [ ] **Step 2:** In `build-app.sh`: pass `-Xswiftc -file-prefix-map -Xswiftc "$ROOT=/heracles"` to both `swift build` calls; after copying the executable, copy `Sparkle.framework` from the products folder into `Contents/Frameworks` with `ditto`; remove `XPCServices`, `Headers`, `PrivateHeaders` and `Modules` from it (the top-level links and under `Versions/B`); make sure the executable has `@executable_path/../Frameworks` among its search paths and none that start with `$ROOT`; copy Sparkle's `LICENSE` to `Contents/Resources/Licenses/Sparkle.txt`; set `SUFeedURL` and `SUPublicEDKey` in the bundle's Info.plist with PlistBuddy; sign with `macos/sign-app.sh "$APP" -`.
- [ ] **Step 3:** Add `/build/appcast.xml` and `/build/update-rehearsal/` to `.gitignore`.
- [ ] **Step 4:** Run `macos/build-app.sh`. Then check, each on `build/Heracles.app`:
  - `codesign --verify --deep --strict build/Heracles.app` exits 0.
  - `build/Heracles.app/Contents/MacOS/Heracles --self-test` exits 0 (the framework loads).
  - `lipo -archs` on `Contents/MacOS/Heracles` and on `Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle` both print `x86_64 arm64`.
  - `find build/Heracles.app -name '*.xpc'` prints nothing.
  - `strings -a` over every file in `Contents/MacOS` and `Contents/Frameworks` has no line containing `$HOME`.
  - `PlistBuddy -c 'Print :SUFeedURL'` prints the feed address in Global Constraints.
- [ ] **Step 5:** Commit: `build(macos): Sparkle in the bundle, and no paths from the build Mac`.

### Task 4: A release signs the update and writes the feed

**Files:**
- Modify: `macos/release.sh`
- Create: `docs/release-notes/0.4.0.md`
- Modify: `macos/Info.plist` (`CFBundleShortVersionString` 0.4.0, `CFBundleVersion` 7)

**Interfaces:**
- Consumes: `macos/sign-app.sh`, `macos/update-config.sh`.
- Produces: `build/Heracles-<version>-mac.dmg`, `build/Heracles-<version>-mac.zip`, `build/appcast.xml`. The feed's one item names `https://github.com/tacticalbadger/Heracles/releases/download/v<version>/Heracles-<version>-mac.zip`.
- Produces: `HERACLES_UPDATE_KEY_FILE=<file>` as a way to sign with a key from a file, for rehearsing the script.

- [ ] **Step 1:** The signing identity: `CODESIGN_IDENTITY` if set, else the first `Developer ID Application:` line of `security find-identity -v -p codesigning`; fail with a sentence saying how to get one if there is none. No name in the script. The team id for `notarytool` comes from the identity found.
- [ ] **Step 2:** Before the build: read `CFBundleVersion` from `macos/Info.plist`, fetch the published feed with `curl -fsSL "$UPDATE_FEED_URL"`, and stop if the feed's `sparkle:version` is not lower. A feed that is not there yet (HTTP 404) passes with a line saying so; any other failure to fetch stops the release unless `--skip-notarize` was given.
- [ ] **Step 3:** After the build: sign with `macos/sign-app.sh "$APP" "$IDENTITY" --release`; `codesign --verify --deep --strict`; for every Mach-O file under `Contents/MacOS` and `Contents/Frameworks`, require a secure timestamp and the `runtime` flag, and no entitlements (`codesign -d --entitlements -` prints none); require that no string in them contains `$HOME`. Then the self-test, as today.
- [ ] **Step 4:** Make the zip with `ditto -c -k --sequesterRsrc --keepParent`.
- [ ] **Step 5:** After the disk image: write the feed as Toolbox's `release.sh` does (`generate_appcast`, `--download-url-prefix`, `--link`, `--embed-release-notes`, `--maximum-versions 1`, notes from `docs/release-notes/<version>.md` copied beside the zip under the zip's name with `.md`). Fail if the key in the keychain is not `UPDATE_PUBLIC_KEY`, unless `--skip-notarize` was given, in which case say that no feed was written. Then check, and fail on any:
  - the archive's `sparkle:edSignature` verifies against `SUPublicEDKey` read from the built app, with the CryptoKit lines from Toolbox's `release.sh`;
  - the feed contains `v<version>/Heracles-<version>-mac.zip` and `sparkle:format="markdown"`;
  - the feed does not contain `sparkle:hardwareRequirements`;
  - the feed's `length` is the zip's size.
- [ ] **Step 6:** Write `docs/release-notes/0.4.0.md`: three bullets in the owner's plain style (it updates itself and how to turn the daily look off; this is the last version to download by hand, keep it in Applications; an update is installed only with the developer's signature, and what a check sends).
- [ ] **Step 7:** Set the version to 0.4.0 and the build to 7 in `macos/Info.plist`.
- [ ] **Step 8:** Rehearse the script without Apple: `macos/release.sh --skip-notarize`. Expected: it ends with the disk image, the zip and `build/appcast.xml`, and every check in step 5 passed. If macOS asks whether `generate_appcast` may use the key, that needs the owner (Always Allow).
- [ ] **Step 9:** Commit: `build(macos): a release signs its update and writes the feed`.

### Task 5: Publishing

**Files:**
- Create: `macos/publish.sh`

**Interfaces:**
- Consumes: the files Task 4 produces, `macos/update-config.sh`, `gh` signed in with the `repo` scope.
- Produces: `macos/publish.sh` (bash). Publishes the version in `build/Heracles.app` as release `v<version>` on `UPDATE_REPO`.

- [ ] **Step 1:** Refuse, each with a sentence that says what to do, when: a file is missing; the disk image is not stapled (`xcrun stapler validate`) or Gatekeeper does not call it `Notarized Developer ID`; the feed's enclosure is not `…/download/v<version>/Heracles-<version>-mac.zip` or its `length` is not the zip's size; the archive's signature does not verify against `UPDATE_PUBLIC_KEY`; `HEAD` is not on GitHub (`git branch -r --contains HEAD` is empty after a fetch); the working tree has changes; a release `v<version>` already exists.
- [ ] **Step 2:** Tag `HEAD` as `v<version>` and push the tag. Create the release as a draft (`gh release create --draft --verify-tag`), titled `Heracles <version>`, with notes made of the install text (download the disk image, drag to Applications; universal, macOS 14 or later; it updates itself from 0.4.0 on) followed by `docs/release-notes/<version>.md`. Upload the disk image, the zip and the feed.
- [ ] **Step 3:** Before publishing, read the draft's files back with `gh api` and require three files whose `size` and `digest` (`sha256:…`) match the local ones. Then `gh release edit --draft=false --prerelease=false --latest`.
- [ ] **Step 4:** After publishing, require: `gh api repos/$UPDATE_REPO/releases/latest` names this tag; and the bytes served at `UPDATE_FEED_URL` are the bytes of `build/appcast.xml` (`curl -fsSL … | cmp - build/appcast.xml`, retried for up to a minute).
- [ ] **Step 5:** Check the refusals without publishing anything: run `macos/publish.sh` on the un-notarized build from Task 4, step 8. Expected: it stops at "not notarized" and nothing was tagged or created (`git tag -l v0.4.0` is empty; `gh release view v0.4.0` fails).
- [ ] **Step 6:** Commit: `build(macos): a publish script that will not release without the feed`.

### Task 6: The rehearsal

**Files:**
- Create: `macos/update-rehearsal.sh`

**Interfaces:**
- Consumes: `build/Heracles.app`, the launch arguments and log lines of Task 2, `macos/sign-app.sh`, `SPARKLE_BIN`.
- Produces: `macos/update-rehearsal.sh [work-dir]` (bash), default work folder `build/update-rehearsal`, exit 0 only if every check passes.

- [ ] **Step 1:** Port Toolbox's `tools/e2e/update-rehearsal.sh`: the bundle identifier `com.heracles.notes.native.update-rehearsal`, `PORT` 8498 by default, versions 9.9.1 (99901) and 9.9.2 (99902), archive name `Heracles-9.9.2-mac.zip`, each copy launched with `HERACLES_DATA_DIR` in the work folder and `--updater-feed <url> --demo-update -SUEnableAutomaticChecks YES -SUAutomaticallyUpdate YES`. Copies are signed again with `macos/sign-app.sh` after their Info.plist is changed. The copies' preferences and caches under that identifier are removed before and after.
- [ ] **Step 2:** Add check 0 in front of Toolbox's five: a copy launched with `HERACLES_DATA_DIR` and `--demo-update` and no `--updater-feed` logs `updates: looking for an update (active: false)` and makes no request (the server log is empty).
- [ ] **Step 3:** Run `macos/build-app.sh && macos/update-rehearsal.sh`. Expected: `update rehearsal: all six checks passed`, and the work folder is gone.
- [ ] **Step 4:** Commit: `test(macos): rehearse a whole update, and the ones that must be refused`.

### Task 7: What the documents say

**Files:**
- Modify: `README.md` (the status section, the tree of `macos/`)
- Modify: `BUILDING.md` ("Releasing the native app"; the two clone addresses that still name the repository's old owner)
- Modify: `CHANGELOG.md` (a `## [0.4.0] - 2026-11-24` section and its link)
- Modify: the status document, now `docs/status.md` (status: built, verified, not verified; the old repository address)
- Modify: `docs/superpowers/specs/2026-11-24-ota-updates-design.md` (only if building changed a decision)

- [ ] **Step 1:** README: it updates itself from 0.4.0 on; the two menu items; keep it in Applications; 0.3.3 and earlier need one download by hand.
- [ ] **Step 2:** BUILDING: the release steps as they are now (`release.sh`, `update-rehearsal.sh`, `publish.sh`); the update key (where it is, how to show, export and import it, what losing it means, with a pointer to the Toolbox security review's 0.5.0 addendum for Sparkle's two provisions); the build number must go up; the one keychain question from `generate_appcast`. Remove "Updates are not set up".
- [ ] **Step 3:** CHANGELOG and the rewrite status. The status section says what was checked and what was not, in the document's own manner.
- [ ] **Step 4:** Check: `git grep -n -i -E "does not update itself|Updates are not set up|no Sparkle feed"` prints nothing, and a search of `macos`, `docs`, `README.md`, `BUILDING.md` and `CHANGELOG.md` for the owner's name and for a home-folder path finds nothing but the checks that look for them.
- [ ] **Step 5:** Commit: `docs: the native app updates itself from 0.4.0 on`.

### Task 8: Release 0.4.0

No files change except the status notes at the end. Every step is a command with an expected result. The owner approved publishing once these pass.

- [ ] **Step 1:** `DEVELOPER_DIR=… swift test --package-path macos` passes. Push the branch.
- [ ] **Step 2:** `macos/release.sh` with notary credentials (the saved profile if Apple accepts it, otherwise an app-specific password asked of the owner once). Expected: `Ready to distribute`, and the feed checks pass.
- [ ] **Step 3:** `macos/update-rehearsal.sh` against the notarized build: six checks pass.
- [ ] **Step 4:** On a copy of the disk image marked as a download (`xattr -w com.apple.quarantine`): Gatekeeper accepts the image and the app in it; the app in it is 0.4.0 (7).
- [ ] **Step 5:** `macos/publish.sh`. Expected: published, latest, and the served feed is the local one.
- [ ] **Step 6:** The nearest thing to a real update before a second release exists, as Toolbox did: a copy of the release build relabelled 0.3.9 (1), with a bundle identifier of its own and the real key in it, started against the real feed. Expected: it finds 0.4.0 (7), downloads the published zip, verifies it, and after it quits the copy on disk is the published app (`codesign --verify --deep --strict`, `spctl` says `Notarized Developer ID`).
- [ ] **Step 7:** Delete `build/Heracles.app` (the owner's standing rule: after the push succeeded, and the app is not running). Record the release in the status document, commit `docs: record the 0.4.0 release` and push.
