# Code review and native rewrite plan

Written 2026-11-20 from a full read of the codebase at commit `c472352`. It
records the bugs found, what was fixed, what is still open, and a proposed plan
for rebuilding Heracles as a native macOS app with a Swift interface and a Rust
core.

It complements [`ROADMAP.md`](../ROADMAP.md). Gaps already listed there are not
repeated here: archive not cascading, dead `heracles://` links, reminders that
never fire, JavaScript-only syntax highlighting, no export, inline image
storage, and substring-only search.

## How the findings were established

Each finding is marked one of two ways:

- **tested**: reproduced, or covered by an automated or live check.
- **read**: concluded from reading the code, and not reproduced in a running
  app.

Most open findings are **read**. Treat them as well-founded leads and reproduce
one before building a fix on it.

## Fixed

Commits `736dd42` and `41a3bd8`.

| Bug | Fix | Verification |
|---|---|---|
| A metadata update (favorite, archive, icon) or a sidebar refresh that arrived while an autosave was still debounced replaced the note in memory with the older database row, which reset the editor and dropped the latest typing. | `renderer/src/App.tsx` overlays pending edits on every server response (`mergePendingEdits`, `withPendingEdits`) and clears the pending marker only after the save resolves. A rename during the debounce window updates the pending payload. | Typecheck and production build only. Not exercised in a running app. |
| Dragging a kanban card also started a column drag, because the card's `dragstart` bubbled into the draggable column. Dropping the card could reorder columns. | `KanbanBoard.tsx` stops propagation in `handleTaskDragStart`, and the column's `onDragOver`/`onDrop` treat a card drag and a column drag as mutually exclusive. | Typecheck and production build only. Not exercised in a running app. |
| "Move to…" could make a note its own ancestor, which detaches the subtree from the sidebar. Only the picker UI prevented it. | `setNoteParent` in `electron/db.cjs` refuses a parent that is the note itself or a descendant. | **tested**: three cases in `scripts/db-cascade-test.cjs`. |
| Nothing restricted where a window could navigate. A remote page, or another local file, could load in a window that has the preload database bridge. | `electron/navigation.cjs` allows only the app's own document. `main.cjs` denies every other navigation and `window.open`, and hands `http(s)` targets to the system browser. | **tested**: ten cases in the test script, plus a live Electron run confirming a local-file navigation is blocked with the policy and succeeds without it. |

## Open findings

The first three are the ones worth fixing next, because they can lose or
corrupt data.

### Data integrity

1. **The last edit can be lost on quit.** (read) `App.tsx` flushes pending saves
   from a `beforeunload` handler by calling `notes.update` over asynchronous
   IPC without waiting for a reply. Nothing guarantees the main process handles
   the message before the window is destroyed. A fix is for the main process to
   ask each window to flush on `close` and wait for the acknowledgement.
2. **Windows do not see each other's changes.** (read) Each window loads every
   note once and keeps its own copy. `main.cjs` never tells other windows about
   a mutation. Editing one note in two windows is last-writer-wins, and a
   structural change in one window leaves the other stale until it reloads. A
   fix is to broadcast a change event from the main process after each
   mutation.
3. **Deleting a notebook is not atomic and can leave duplicate positions.**
   (read) The notebook branch of `deleteNote` in `db.cjs` reassigns the
   children and deletes the notebook as two statements outside a transaction.
   The adopted children also keep their old `position` values, which can
   collide with the receiving notebook's children.
4. **SQLite runs with default settings.** (read) `db.cjs` sets no
   `journal_mode`, `foreign_keys`, or `busy_timeout`. The tables declare no
   foreign keys, so every cascade is a JavaScript loop that rescans the whole
   `notes` table (`collectDescendantIds`, `isSelfOrDescendant`).
5. **Duplicating a board is many separate IPC calls.** (read) `duplicateBoard`
   in `App.tsx` creates columns and tasks one call at a time. A failure partway
   leaves a partial copy. It belongs in one main-process transaction.
6. **Every structural change refetches every note's full content.** (read)
   `notes.list()` runs after each reorder, trash, restore, and section or
   notebook creation, and returns all rows including content with inline
   base64 images. Listing without content and fetching content on open would
   remove most of that cost.

### Correctness

7. **A "drop after" in the sidebar can land in the wrong place.** (read) This
   happens when the section is not sorted manually. `handleItemDrop` in
   `Sidebar.tsx` picks the next sibling from the list as currently sorted, for
   example by last edited. The database inserts relative to manual order, and
   `handleMovePage` then switches the section to manual sort. "Drop before" and
   "drop inside" are unaffected.
8. **The ⌘K switcher strips HTML from every note on every keystroke.** (read;
   cost not measured) See `switcherNotes` in `App.tsx`. The sidebar already
   memoizes the same text in `searchTextById`, which the switcher could reuse.
9. **`htmlToEditorHtml` does not filter by tag or attribute.** (read)
   `BLOCK_TAGS` and `INLINE_TAGS_TO_PRESERVE` in `lib/htmlImport.ts` are
   declared and never used. The function removes `script`, `style`, `noscript`,
   `iframe`, `object`, and `embed`, and nothing else, so event-handler
   attributes and `javascript:` URLs survive in its output. What protects the
   editor in practice is TipTap's schema, which drops nodes and attributes it
   does not know. That has not been tested with hostile input. Separately, the
   editor has no table node, so tables lose their structure on paste and
   import.
10. **Markdown import demotes images to links.** (read) The comment in
    `lib/markdownImport.ts` says the editor has no image node, but `ImageBlock`
    exists. `docs/architecture.md` is stale the other way: it says HTML import
    turns `<img>` into a link, and it now keeps images.
11. **Links cannot be opened from the editor.** (read) The TipTap `Link`
    extension is configured with `openOnClick: false` and there is no other
    click handler. Now that any `http(s)` navigation goes to the system
    browser, adding a modifier-click handler is safe.
12. **A root task with no column can be stored but is never shown.** (read)
    `createTask` accepts a null `columnId` with no parent, and `KanbanBoard`
    renders only tasks whose column exists. No UI path that creates one was
    found, so this is a latent hazard and not an observed bug.

### Platform

13. **There is no Content-Security-Policy.** (read) `renderer/index.html` has
    no CSP meta tag and the main process sets no header. The renderer sandbox
    is on, because Electron has enabled it by default since version 20.
14. **The DMG notarization hook patches `latest-mac.yml` line by line.** (read)
    `build/notarize-dmg.cjs` works, but depends on the layout electron-builder
    happens to emit.
15. **The entitlements are the usual Electron set.** (read) This is not a bug.
    `allow-unsigned-executable-memory` may be unnecessary on current Electron.
    That is untested, so check a signed build before removing it.

## Native rewrite plan

This began as a proposal. The first stage has since been built: see
[Rewrite status](#rewrite-status) at the end for what exists, which choices
were made along the way, and what is still to do.

### Decide first: Windows

A Swift app runs on macOS only, and this codebase also ships as
[Heracles-Windows](https://github.com/mattdobbs/Heracles-Windows). A Rust core
could be shared with a Windows interface later. Until one exists, the Windows
build either stays on Electron or stops receiving features.

### Architecture

```
┌──────────────────────────────────────────────────┐
│ Heracles.app (Swift: SwiftUI + AppKit)           │
│ windows, pane splits, tabs, sidebar, kanban,     │
│ drag and drop, menus, notifications, updater     │
├──────────────── UniFFI bindings ─────────────────┤
│ heracles-core (Rust static library)              │
│ SQLite storage, document model, search,          │
│ import and export, image store, change feed      │
└──────────────────────────────────────────────────┘
```

Everything in `electron/db.cjs`, `electron/main.cjs`, and the import converters
is logic with no interface, which suits Rust. Everything in
`renderer/src/workspace/` is interface, which suits SwiftUI and AppKit. The
core builds as an XCFramework consumed through Swift Package Manager, with
Swift bindings generated by UniFFI. `swift-bridge` is an alternative.

Candidate crates: `rusqlite` with bundled SQLite and FTS5, `pulldown-cmark` for
Markdown, `ammonia` for HTML sanitizing, `html5ever` or `scraper` for parsing
stored HTML during migration, and `automerge` or `yrs` if sync is added later.

### Decisions that remove the open findings

- **One core owns the data, and windows subscribe to a change feed.** This
  removes finding 2 by construction. It also lets the core, and not each
  window, decide when a write is durable (finding 1) and how much to send
  (finding 6).
- **Store documents as structured blocks in JSON, not as HTML strings.** This
  is the most important schema change. It makes native editing, search,
  export, and sync tractable. Design the JSON so it maps onto ProseMirror's
  document JSON, which lets a web editor and a native editor read the same
  documents.
- **Move images out of note content** into a content-addressed store.
- **Declare foreign keys with `ON DELETE CASCADE`, enable WAL, and run one
  write transaction per user action.** This removes findings 3, 4, and 5.
- **Register the `heracles://` scheme and deliver reminders through
  `UNUserNotificationCenter`.** Both are roadmap items that are awkward in
  Electron and small natively.

### The editor is the hard part

The block editor (drag handles, columns, slash menu, code blocks) is most of
the product and most of the rewrite.

| Option | Effort | Result |
|---|---|---|
| A. Native block editor: a list of blocks, each a TextKit 2 text view, with block drag and columns in Swift | High | Fully native |
| B. Hybrid: native shell, sidebar, and kanban, with one `WKWebView` hosting the existing TipTap editor and talking to the Rust core through script messages | Low to medium | Ships sooner and reuses `renderer/src/editor/` |
| C. A single rich-text document in TextKit | Medium | Loses blocks and columns, so it does not match the product |

The recommendation is B first and A second, with the Rust core and the block
JSON designed for A from the start. For native code blocks, candidates are
`STTextView`, `CodeEditSourceEditor`, and `Neon` for tree-sitter highlighting.
(`Runestone`, which an earlier draft of this plan named, is iOS only.)

### Migration

A one-time importer in the core opens `heracles.sqlite`, parses each note's
TipTap HTML into block JSON, extracts base64 data URLs into the image store,
and carries `tasks`, `task_columns`, and `task_comments` across with real
foreign keys. It writes a backup first, as the notebook migration does today.

### Signing, notarization, and updates

- The Developer ID identity and the App Store Connect API key used today work
  unchanged. The flow is `xcodebuild archive`, then
  `xcrun notarytool submit --wait`, then `xcrun stapler staple`.
- A native build should need no hardened-runtime exceptions, because the Rust
  library links statically into the main binary and `WKWebView` runs its JIT
  in a separate process. Confirm this once the web editor is wired in.
- Sparkle 2 with an EdDSA-signed appcast replaces `electron-updater`. The R2
  bucket can serve `appcast.xml` as it serves `latest-mac.yml` now.
  `scripts/upload-release.cjs` keeps its signing and upload logic, and its
  feed file name, content type, and artifact pattern change.

### Open questions

- Minimum macOS version. TextKit 2 and current SwiftUI features set the floor.
- Whether to adopt App Sandbox. If so, Sparkle needs its XPC services
  configured.
- Sync model, attachment storage, and local encryption, which
  `docs/architecture.md` already lists as undecided.

## Rewrite status

Updated 2026-11-21. Work is on the `native-rewrite` branch. The Electron app
is unchanged and is still the release.

### Built

**The core** (`core/`, Rust, 165 tests via `cargo test`):

- SQLite schema with foreign keys, `ON DELETE CASCADE`, WAL, and one write
  transaction per user action. `CHECK` constraints hold the invariants:
  notebooks at the top level and nothing else there, and every task either in
  a column or under a parent.
- Documents as block JSON in ProseMirror's shape, kept apart from the note
  row. Unknown node types and attributes survive a round trip.
- HTML to document conversion, used for migrating stored notes and for
  importing HTML. Output is built from an allow-list, so nothing from the
  input is copied through.
- Content-addressed image store. Saving a document moves any embedded
  `data:` image into it.
- FTS5 search over titles and text, with prefix matching and snippets.
- A change feed: each committed write announces what it touched, in commit
  order.
- The Electron library importer, with a backup first and a report of every
  repair.
- UniFFI bindings for Swift.

**The app** (`macos/`, Swift, 32 tests via `swift test`, plus `--self-test`):

- Sidebar with notebooks, nested notes, favorites, archive, trash, and search.
- Kanban board with drag between columns.
- The existing TipTap editor in a web view (option B), loading and saving
  block JSON through the core.
- Multiple windows on one shared model.
- `heracles://note/<id>` links, registered in `Info.plist`.

### Open findings this removes

Each is removed in the native code only. The Electron app still has them.

| Finding | How |
|---|---|
| 1. Last edit lost on quit | Quitting waits for every editor to hand over its pending change. Closing a window does the same. |
| 2. Windows do not see each other's changes | Every window reads one model, which the change feed keeps current. |
| 3. Notebook delete not atomic | One transaction, and adopted notes get positions of their own. Tested. |
| 4. SQLite defaults | WAL, foreign keys, busy timeout, cascades in the schema. |
| 5. Duplicate board is many calls | One transaction in the core. Tested. |
| 6. Refetching all content | Listing notes never reads content. |
| 9. `htmlToEditorHtml` filters nothing | The converter's output is allow-listed, and link and image URLs are checked by scheme. Tested with hostile input. The web editor still uses the old function for paste: see below. |
| 11. Links cannot be opened | ⌘-click opens a link. |
| 12. Root task with no column | Refused by the core and by a `CHECK` constraint. The importer gives such tasks a column. |
| 13. No Content-Security-Policy | The editor page has one, and is served from its own URL scheme, not `file:`. |

### Choices made that the plan left open

These were made to keep moving. Each is easy to change now and harder later.

- **Minimum macOS is 14.** Set in `macos/Package.swift` and
  `macos/build-core.sh`.
- **No App Sandbox**, matching the Electron app.
- **The bundle id is `com.heracles.notes.native`**, so both apps can be
  installed during the rewrite. Taking over `com.heracles.notes` is a release
  decision.
- **The library lives in the Electron app's folder** as `heracles.db`, beside
  `heracles.sqlite`, with images in `images/` and import backups in
  `backups/`.
- **SwiftPM builds the app**, and a script assembles the bundle. The plan's
  `xcodebuild archive` flow is not set up.
- **Archive still does not cascade**, as in the Electron app. The roadmap
  question is undecided.
- **Windows is undecided.** Nothing here blocks sharing the core with a
  Windows interface.

### Not built yet

- Pane splits and tabs. A window shows one note.
- The editor's block gutter: drag handle, block menu, and dragging blocks into
  columns. The slash menu and all block types work.
- The task detail view: subtasks, comments, due dates, labels, and reminders
  can be stored and are shown on cards, but only title and completion can be
  edited.
- Reminders through `UNUserNotificationCenter`. The core lists outstanding
  reminders (`list_reminders`). Nothing schedules them.
- Markdown import, HTML import from the menu, and export. The core converts
  HTML. Nothing calls it for import yet, and Markdown is not started.
- Icon picker, the ⌘K switcher, and menu bar commands.
- Release signing, notarization, and Sparkle.
- Paste in the web editor still goes through `htmlToEditorHtml` and TipTap's
  schema, as in the Electron app. Routing paste through the core's converter
  would close finding 9 there too.

### Not verified

- The importer has only been run on databases built by its tests. No real
  Electron library was on the machine it was written on. Try it first with
  `HERACLES_DATA_DIR` pointing at a copy.
- The app's windows were checked by drawing them offscreen
  (`--snapshot`) and by `--self-test`. Nobody has used it by hand yet.
- Findings marked **read** above were not reproduced in the Electron app
  before being designed out.
