# Status

Updated 2026-11-24. What is built, the choices behind it, what is missing
and what has not been checked.

Version 0.4.0 is the current preview on the GitHub releases page, as a
signed and notarized disk image. From this version on the app updates
itself. 0.4.0 is build 7, published from commit `b5559c6` with its update
feed attached.

Heracles began as a different app, built on web technology (version 0.1).
The native app replaced it from 0.2.1 on. The original is no longer in this
repository, though its git history is, and the native app still brings
across a library that it left behind.

## Built

**The core** (`core/`, Rust, 195 tests via `cargo test`):

- SQLite schema with foreign keys, `ON DELETE CASCADE`, WAL, and one write
  transaction per user action. `CHECK` constraints hold the invariants:
  notebooks at the top level and nothing else there, and every task either in
  a column or under a parent.
- Documents as block JSON in ProseMirror's shape, kept apart from the note
  row. Unknown node types and attributes survive a round trip.
- HTML to document conversion, used for migrating stored notes, importing
  HTML, and pasting. Output is built from an allow-list, so nothing from the
  input is copied through.
- Markdown to document and document to Markdown.
- File import (Markdown or HTML, with the pictures beside the file) and
  Markdown export (with pictures copied into a folder beside the file).
- Content-addressed image store. Saving a document moves any embedded
  `data:` image into it.
- FTS5 search over titles and text, with prefix matching and snippets.
- A change feed: each committed write announces what it touched, in commit
  order.
- The importer for the original app's library, with a backup first and a
  report of every repair.
- UniFFI bindings for Swift.

**The app** (`macos/`, Swift, 255 tests via `swift test`, plus `--self-test`):

- Sidebar with notebooks, nested notes, favorites, archive, trash, and search.
- Panes and tabs: splits within splits, draggable dividers, tabs that move
  between panes, ⌘-click to open beside. The layout is kept per window.
- A native block editor. The first two previews showed a web editor in a
  web view, and 0.3.0 replaced it. It reads and writes the same block
  JSON, so notes carried over unchanged. See
  [The native editor](#the-native-editor) below.
- Kanban board with drag between columns, and a task detail sheet: notes,
  priority, dates, location, labels, reminders, nested subtasks, comments.
- Reminders scheduled through `UNUserNotificationCenter`.
- Import of Markdown and HTML files, and Markdown export.
- Quick Open (⌘K), icon picker, and a menu bar with a Format menu.
- An app icon: a notebook page with a heading, a checklist and lines of
  text. It is a layered Icon Composer icon, which macOS 26 and later draw in
  their light, dark, clear and tinted styles.
- Multiple windows on one shared model.
- `heracles://note/<id>` links, with `#block=<id>` to scroll to a block.
- Updates over the air, through Sparkle 2.10.1. The app looks once a day
  and from Heracles ▸ Check for Updates…, shows the release notes, and
  installs when the user agrees. It takes an update only if the feed and
  the archive are both signed with the update key. A run with a library
  named in `HERACLES_DATA_DIR`, the self-test and the snapshot do not look.
- `macos/release.sh`: universal build, Developer ID signing under the
  hardened runtime, notarization, stapling, a disk image that is signed
  and notarized in its own right, and the signed update feed. It checks
  every executable in the bundle, and stops when the build number has not
  gone up.
- `macos/publish.sh`: the GitHub release, as a draft until its files have
  been read back, and refused when the feed, the zip and the notarization
  do not belong together.
- `macos/update-rehearsal.sh`: a whole update between two relabelled copies
  of the build, with a key made for the run, and the updates that must be
  refused.

## What the design rules out

Each of these is a way a notes app loses or mangles work, and how the
design keeps it from happening.

| Risk | How it is ruled out |
|---|---|
| The last edit is lost on quit | Quitting waits for every editor to hand over its pending change. Closing a window does the same. |
| Two windows show different things | Every window reads one model, which the change feed keeps current. |
| Deleting a notebook half happens | One transaction, and adopted notes get positions of their own. Tested. |
| The database is left in a state the app does not expect | WAL, foreign keys, a busy timeout, and cascades in the schema. |
| Duplicating a board half happens | One transaction in the core. Tested. |
| Listing notes drags every note's content along | Listing notes never reads content. |
| Imported or pasted HTML carries something hostile | Import and paste both go through the core's converter, whose output is allow-listed, with link and image URLs checked by scheme. Tested with hostile input. |
| Markdown import turns pictures into links | Markdown images become image blocks, and local ones are brought into the image store. Tested. |
| A link leads somewhere it should not | A click opens a link, as in other Mac text. Only web, mail and note links are followed. |
| A task belongs to no column | Refused by the core and by a `CHECK` constraint. The importer gives such tasks a column. |
| Script runs inside the app | There is no web page in it. The app runs no JavaScript and shows no web view. |
| The app holds more rights than it needs | It has no entitlements. It runs under the hardened runtime with no exceptions, checked on a signed build. |

## The native editor

The editor is the hard part of the app. It is in
`macos/Sources/HeraclesApp/Editor/`, in three layers:

- **A document model in plain Swift.** A note is a tree of blocks. A list
  item is a block with its text on it and what is nested in it as its
  children, which is the shape an editor wants, and it is converted to and
  from the stored JSON's lists-of-items shape on the way in and out. Every
  edit that changes the shape of a note (split, join, indent, move, make
  columns, paste) is a function on this model, with no view involved, and
  each is tested on its own.
- **One system text view per block** (`NSTextView` on TextKit 2). Typing
  inside a block is the text view's own business, which is where the native
  behaviour comes from. What crosses blocks (Return, Backspace at the start,
  arrows at an edge) is passed to the editor, which changes the model and
  then makes the views match.
- **The page**, which stacks the block views, and draws what floats over
  them: the block handle, the selection of whole blocks, the drop line and
  the slash menu.

Choices made in it:

- **A selection is either text inside one block, or whole blocks.** A drag
  from one block into another selects whole blocks, as in other block
  editors. Text cannot be selected from the middle of one block to the
  middle of another.
- **Undo is the editor's own**, one history for the note, kept as snapshots
  of the document. A run of typing in one block is one step.
- **A click on a link opens it.**
- **Only `http`, `https`, `mailto` and `heracles` links can be made or
  followed.**
- **Remote pictures are fetched** when a note that refers to one is
  opened.
- **No floating toolbar over a selection.** The Format menu, its shortcuts
  and the context menu replace it.

## Choices

Each is easy to change now and harder later.

- **Minimum macOS is 14.** Set in `macos/Package.swift` and
  `macos/build-core.sh`.
- **No App Sandbox.**
- **The bundle id is `com.heracles.notes.native`.** The original app used
  `com.heracles.notes`, so the two never shared preferences. Every installed
  copy's settings and its updates hang on this id, so it stays.
- **The library lives in `~/Library/Application Support/Heracles/`** as
  `heracles.db`, with images in `images/` and import backups in `backups/`.
  The original app kept its library in the same folder as
  `heracles.sqlite`, which is where the importer looks.
- **SwiftPM builds the app**, and scripts assemble and sign the bundle.
  There is no Xcode project.
- **The release is a plain disk image**, with a zip of the same app beside
  it. The image has no background picture or arranged icons.
- **Export writes the note's content, not its title.** The file name carries
  the title, as it does on import, so an export imports back as it was.
- **A new note goes inside the open note.**
- **Archive does not cascade.** Archiving a page hides the pages under it
  without archiving them, and they come back with it. Whether it should
  cascade, as trash does, is undecided.
- **Windows is undecided.** Nothing here blocks sharing the core with a
  Windows interface.
- **The update feed is a file on each GitHub release.**
  `releases/latest/download/appcast.xml` always
  serves the newest release's copy, so there is no server and no second
  set of credentials. The address is built into every copy from 0.4.0 on.
- **Heracles has an update key of its own**, in the login keychain of the
  Mac that makes releases. It is not the key the owner's other app uses.
- **Release notes in the feed are Markdown.** Sparkle draws those in a text
  view and HTML in a web view, and the app is to have no web view.
- **The app is no longer a single executable.** Sparkle's framework and its
  two helper programs are in the bundle. Its two XPC services, which are
  for sandboxed apps, are left out. Nothing has an entitlement.

## Not built yet

- Syntax coloring in code blocks. They are plain monospaced text with a
  language menu.
- Find within a note. Search finds notes, not places in them.
- Selecting text across blocks, and dragging out a rectangle to select
  blocks.
- Resizing an image. It is shown at its own size, or as wide as the text.
- Per-section sort modes in the sidebar, and dragging notes in the sidebar
  to reorder them. Notes move through the "Move to Notebook" menu.
- Moving a subtask under a different task. A subtask can be promoted to a
  card.
- HTML export.

Further off, from the app's first goals: sync between Macs, a calendar
integration, notifications to chat, and a command palette for actions as
well as for opening notes.

## Not verified

- **Versions before 0.4.0 are no longer published.** Their release pages
  and downloads were deleted on 2026-11-24, because those builds held file
  paths from the Mac they were made on, and a published release here
  cannot have its files replaced. Their tags are still in git, and
  `CHANGELOG.md` still says what each one changed.
- 0.4.0 is notarized: Apple accepted the app and the disk image, both
  tickets are stapled, and Gatekeeper passes the image and the app copied
  out of it. That was checked from a script, on a copy of the image marked
  the way macOS marks a download. Nobody has yet opened an image by hand
  and dragged the app across.
- The importer has only been run on databases built by its tests. No real
  library from the original app was on the machine it was written on. Try
  it first with `HERACLES_DATA_DIR` pointing at a copy.
- **Nobody has used the app by hand yet.** The windows were checked by
  drawing them offscreen (`--snapshot`), in light and dark, and the editor by
  tests that drive the real text views with keys and the clipboard, in
  `swift test` and in `--self-test` on the built app. What those cannot do is
  move a mouse. Built and never exercised: clicking and dragging in the
  editor (placing the caret, dragging a selection across blocks, the block
  handle, dragging a block to move it or make columns, column dividers,
  dropping picture files), the link and icon popovers, input methods for
  languages that compose characters, and the Edit menu's own Undo item, as
  opposed to ⌘Z. Outside the editor: dragging tabs, dividers and cards,
  reminders arriving, and the open and save panels.
- The icon was looked at as macOS 27 draws it in the dark style, at every
  size, and as Icon Composer renders the other styles. It has not been seen
  on macOS 14 or 15, where the system shows pictures that Xcode made from
  the same source.
- The editor's tests for the views were written after the views. The
  document model was written test first.
- **Updates were rehearsed, and one was taken from the published feed, but
  none yet from one published version to the next.** `update-rehearsal.sh`
  passed on a build signed ad hoc and on the notarized 0.4.0 build: an old
  copy replaced itself with a new one, an updated copy was offered nothing,
  a zip and a feed altered after signing were each refused for that reason,
  the same feed 21 days on got nothing downloaded, and a copy with a
  library of its own did not look. After 0.4.0 was published, the three
  files were downloaded back and matched the local ones byte for byte, and
  the address installed copies read served the feed that was built. Then a
  copy of the release build, relabelled 0.3.9 with a bundle identifier and
  a library of its own and the real update key in it, read the published
  feed, found 0.4.0, downloaded the published zip and verified it. Once it
  had quit, the copy on disk was file for file the app in the published
  zip, its signature valid, its ticket stapled. Only the old copy's version
  was made up. Not checked, because it cannot be until a second release
  exists: an update from one published version to the next. The rehearsal
  reads the two menu items as the menu draws them (greyed out in a trial
  run, available and ticked otherwise), but nobody has clicked Check for
  Updates… or seen the update window. Also not checked: an update of a copy
  in a folder its user cannot write to; an update on an Intel Mac, or on
  macOS 14 or 15; and
  what happens to text typed in the moment before an update installs. The
  install quits the app through its ordinary quit, which waits for every
  editor to save, but the rehearsal stops its copies with a signal and so
  never takes that path. The way back from a lost update key has not been
  tried either.
