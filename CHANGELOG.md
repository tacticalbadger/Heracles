# Changelog

All notable changes to Heracles are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Removed

- **The original app.** Heracles began as an app built on web technology
  (version 0.1), which lived in this repository beside the native Mac app.
  It is gone from the repository, with everything that built, signed and
  released it and the documents that described it. Heracles is the native
  Mac app. The app still brings across a library that the original left
  behind, the first time it starts.
- **The downloads of versions 0.2.1 to 0.3.3.** Their release pages were
  deleted on 2026-11-24, because those builds held file paths from the Mac
  they were made on. The entries below are kept as the record of what each
  one changed. 0.4.0 is the oldest version that can be downloaded.

### Changed

- `docs/status.md` replaces `docs/review-and-native-rewrite.md`: what is
  built, the choices behind it, what is missing and what has not been
  checked. `BUILDING.md` covers the native app only.
- The copy an import makes of the original library is now named
  `heracles-original-<time>.sqlite`. Copies made earlier keep their names.

## [0.4.0] - 2026-11-24

The native Mac app updates itself from this version on. It is the last one
to download by hand: get `Heracles-0.4.0-mac.dmg` from the
[release page](https://github.com/tacticalbadger/Heracles/releases/tag/v0.4.0),
open it, and drag Heracles onto the Applications folder beside it. Versions
0.3.3 and earlier have no updater and cannot be told that this one exists.

### Added

- **Updates over the air.** The app looks for a new version once a day and
  from **Heracles ▸ Check for Updates…**, shows what changed, and installs
  it when you agree. Installing restarts the app, after every editor has
  saved. **Heracles ▸ Check for Updates Automatically** turns the daily look
  off. Keep the app in the Applications folder for this to work.
- An update is installed only if it carries the developer's signature: the
  feed that announces it and the archive itself are both checked against a
  key built into the app, before anything is unpacked. A check sends the
  app's version and the Mac's language setting, and nothing about your
  notes.
- The updater is [Sparkle](https://sparkle-project.org) 2.10.1, the app's
  first dependency that is not built from this repository. Its window is a
  native one. Release notes are written in Markdown, which it draws as
  text, so the app still has no web view.
- `macos/publish.sh` publishes a release on GitHub: as a draft first, with
  the update feed attached, and only after checking that the feed, the zip
  and the notarization all belong together. `macos/update-rehearsal.sh`
  rehearses a whole update on one Mac, including the updates that must be
  refused. [`BUILDING.md`](./BUILDING.md#releasing) has both.

### Changed

- `macos/release.sh` signs the zip with the update key, writes the feed,
  and stops before building when the build number has not gone up. It finds
  the signing certificate in the keychain; no name is written in the script.

### Fixed

- The app no longer contains file paths from the Mac it was built on.
  Version 0.3.3 held 150 of them, left by the Rust compiler for its error
  messages, each naming the build Mac's home folder.

## 0.3.3 - 2026-11-23

A new icon. Nothing else in the app has changed since 0.3.0.

### Changed

- **A new app icon that shows what the app is for**: a notebook page with a
  heading, a ticked item, an empty one, and lines of text. It replaces the
  letter H of 0.3.2. By default it is a cream page on terracotta, and in the
  dark icon style of macOS 26 and later a terracotta page on black.

## 0.3.2 - 2026-11-23

The app gets an icon. Nothing else in the app has changed since 0.3.0.

### Added

- **An app icon**: an H made of two columns, cream on terracotta. It is a
  layered icon, so macOS 26 and later draw it in each of their icon styles,
  where the dark one is terracotta on black. Earlier versions of macOS show
  the light one. Its source is `macos/Icon/Heracles.icon`, compiled by
  `macos/make-icon.sh`.

## 0.3.1 - 2026-11-23

The app as a disk image. The app itself is the same as 0.3.0.

### Added

- **A disk image download.** `macos/release.sh` now also makes
  `Heracles-<version>-mac.dmg`: the app beside a link to the Applications
  folder. The image is signed, notarized and stapled, as the app in it is.
  The zip of the same app is still published beside it.

## 0.3.0 - 2026-11-22

The second preview. The editor is now native, and the download is
notarized, so it opens without a detour through System Settings. A
universal app for macOS 14 or later. It does not update itself.

### Added

- **The editor is native.** The web editor in a web view is gone, and with it
  the last web technology in the native app. Each block's text is a system
  text view, so typing, selection, spelling, text replacement, dictation and
  input methods behave as they do in every other Mac app. The app no longer
  loads WebKit or bundles any JavaScript.
- **Blocks.** Paragraphs, headings, bullet, numbered and task lists nested to
  any depth, quotes, callouts, toggles, code blocks with a language menu,
  dividers, images and column layouts with dividers to drag. Notes written
  with the web editor open unchanged: the stored format is the same.
- **Keys.** Return splits a block and ends a list on an empty item. Backspace
  at the start of a block joins it to the one above. Tab and Shift-Tab indent
  and outdent list items. The arrow keys cross from block to block and keep
  their column. Shift with an arrow at the edge of a block, a drag from one
  block into another, or a second Select All selects whole blocks, which can
  be copied, cut, deleted, moved or indented together.
- **Markdown as you type.** `# `, `- `, `1. `, `[] `, `> `, ` ``` ` and `---`
  at the start of a line make the block. `**bold**`, `*italic*`, `` `code` ``
  and `~~struck~~` make the mark. A web address becomes a link when the space
  after it is typed.
- **Slash menu.** `/` where a word could start lists the kinds of block, and
  narrows as you type.
- **Block handle.** The handle beside the block under the pointer adds a block
  below, drags the block to a new place or to the right-hand end of another to
  make columns, and opens a menu to turn the block into another kind,
  duplicate it, copy a link to it or delete it.
- **Format menu**, with shortcuts for bold, italic, strikethrough, code,
  headings and lists. ⌘K links the selected text, and is still Quick Open when
  nothing is selected.
- **Undo and redo for the whole note**, not one block at a time.
- **Copy and paste.** Blocks copy to other apps as Markdown, and back into
  Heracles as blocks. Rich text from other apps still goes through the core's
  allow-list. A web address pasted over selected text links it. Pictures can
  be pasted, or dropped in as files.

### Changed

- The download is notarized by Apple and has its ticket stapled.
- A click on a link opens it. The web editor wanted ⌘-click.
- The build no longer needs Node.js. `macos/release.sh` also accepts an
  Apple ID with an app-specific password, and checks the credentials with
  Apple before it builds.

### Removed

- The web editor in a web view, and WebKit with it.
- The floating toolbar over selected text. The Format menu, its shortcuts and
  the context menu do its job.

## 0.2.1 - 2026-11-22

The first preview of the native Mac app: a universal app for macOS 14 or
later. It was signed with the Developer ID certificate and **not
notarized**, so macOS refused to open it the first time. It did not update
itself.

### Added

- **Native Mac app, first stage** — the start of the app in Swift over a
  Rust core.
  - `core/` is **heracles-core**, a Rust library that owns the data: a SQLite
    schema with foreign keys and WAL, one write transaction per user action,
    documents stored as block JSON in ProseMirror's shape, images in a
    content-addressed store outside note content, FTS5 search, and a change
    feed that tells every window what each write touched.
  - A one-time importer brings the original app's library
    (`heracles.sqlite`) across: it backs the old database up first, only reads it, converts each
    note's HTML to block JSON, moves base64 images into the image store, and
    repairs what the old schema allowed and the new one does not (orphaned
    notes, cards in no column), reporting every repair.
  - `macos/` is the app: a SwiftUI shell (sidebar, search, kanban board,
    multiple windows) over the core through UniFFI bindings, with a web
    editor hosted in a web view until a native block editor replaced it.
  - Build with `macos/build-app.sh`. See
    [`BUILDING.md`](./BUILDING.md#building).
- **Native Mac app, second stage** — the pieces the first stage left out:
  - **Panes and tabs.** Split a window right or down, as deep as you like,
    drag the dividers, drag tabs between panes, and ⌘-click a note in the
    sidebar to open it beside the current one. Each window remembers its
    layout.
  - **Block handle in the editor.** Hover a block for its handle: drag to
    reorder or to make columns, + to add a block, ⋮⋮ for a menu with copy
    link, duplicate, delete and "turn into". Selecting text shows the
    formatting toolbar.
  - **Task details.** Click a card for its notes, priority, due date,
    deadline, location, labels, reminders, nested subtasks and comments.
  - **Reminders** are scheduled as system notifications, so they arrive
    whether or not the app is open. Clicking one opens its todo list.
  - **Import and export.** Import Markdown and HTML files as pages, with the
    pictures beside them brought into the image store. Markdown images are
    now image blocks, not links. Export a note as Markdown, with its pictures
    copied into a folder beside the file.
  - **Quick Open (⌘K)**, an icon picker, and a menu bar with shortcuts.
  - **Links to blocks.** "Copy link to block" gives a `heracles://` link that
    opens the note and scrolls to the block.
  - **Paste goes through the core.** Rich text pasted into the editor is
    converted by the same allow-list as an import.
  - **`macos/release.sh`** builds a universal app, signs it with the
    Developer ID certificate under the hardened runtime with no exceptions,
    notarizes it and staples the ticket.

## 0.2.0 - 2026-11-22

Published on GitHub without its download, by mistake. The repository's
releases are immutable, so the file could not be added afterwards. 0.2.1 was
the same app with the download attached.

## 0.1.0

The original app, built on web technology: a local-first, hierarchical
notebook with a block editor, split panes and kanban boards. It is no
longer in this repository. The native app replaced it from 0.2.1 on.

[0.4.0]: https://github.com/tacticalbadger/Heracles/releases/tag/v0.4.0
