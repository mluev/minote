# Folders and a sidebar you shape yourself

Status: built (Mac and iOS; iCloud between two devices still to verify with a signed build). Date: 26/11/2026.

Differences from the design, found while building:

- A folder dropped onto a sorted folder from elsewhere lands where the sort
  puts it (the whole folder lights up); the line shows only for Manual
  folders, and for reorders inside a folder.
- Dropping below every row puts the item at the end of the folder looked
  into, whatever the depth of the last row.
- The tab's tooltip shows the note's folder whenever it's in one, not only
  when another open note shares its title.
- iOS lists Manual in Sort By only while a folder already uses it: there's
  no dragging there to arrange one.

## Intent

The library is one flat list, newest first, with search as its only filter.
That stops working once there are more notes than fit on a screen: there is
no way to keep a project's notes together, to put the important one first,
or to look at the list another way.

The sidebar becomes a place the writer arranges: folders that nest, notes
and folders that drag anywhere, an order of one's own, and one menu at the
top of the sidebar that regroups, re-sorts and filters what is listed. The
reference for how it should feel is the Claude desktop app's sidebar
(groups you create, drag and reorder; a "Group by / Sort by / Show" menu).

Lines marked **(call)** are decisions made while writing this, not ones the
owner made; they are listed again at the end.

## Goals

- Folders, nested as deep as wanted, created, renamed, moved and trashed
  from the sidebar.
- Drag a note into another folder, to a place among its siblings, or out
  to the top level. Drag a folder the same way, with everything in it.
- An order of one's own inside each folder (Manual), next to the sorted
  ones.
- One menu at the top of the sidebar: Group by, Sort by, Show.
- Look inside one folder only: the list, the search and New Note narrow to
  it.
- The structure belongs to the writer, not to Minote: it is real folders on
  disk, the same in Finder, iCloud Drive, the Files app and any other
  editor.
- Nothing a flat library does today gets worse: tabs come back, links
  resolve, locked notes stay sealed, backups and auto-naming work, in
  every folder.

## Non-goals (this version)

- Hashtags. Left out on purpose: a locked note's text can't be read while
  locked, so its tags would vanish from every filter, and folders plus the
  view menu cover the need. They can come back later as one more "Group by".
- Selecting or dragging several items at once.
- Dragging files in from Finder, or notes out to Finder or onto the tab bar.
- Locking a folder as a unit, folder colours or icons, smart folders.
- A filter on note contents other than search (e.g. "has open tasks").
- Folders for a file opened from Finder (single-file mode is untouched).

## Anti-goals

- A structure that exists only inside Minote. No database, no index of
  notes: anything Minote stores about the hierarchy must be losable
  without losing where a note is.
- A note's text at risk during a move. A move never goes through "delete,
  then write"; unsaved edits travel with the note.
- A tab closing, or a note's caret, scroll or undo history being lost,
  because the note or a folder above it was moved or renamed.
- Idle cost: a keystroke must not rebuild the tree (see Constraints).
- A sidebar that looks like a file browser. It stays the quiet list it is:
  the page's paper a shade darker, our own rows, no system `List`.

## Approaches considered

1. **Real folders on disk (chosen by the owner).** A sidebar folder is a
   directory under the library folder; nesting is subdirectories; dragging a
   note moves its file. Only the manual order and a folder's own sort need a
   small hidden file, because a file system has no order. Costs: a note's
   persistent identity becomes its path instead of its name (tabs, links,
   locking, backups, name uniqueness), and the scan reads subfolders.
2. **Virtual groups.** Files stay in one flat folder and a hidden file
   holds the whole tree. Much cheaper (identity, locking and tabs
   untouched), but the structure exists only in Minote, Finder shows a flat
   pile, losing or conflicting the hidden file loses all grouping, and a
   note renamed by another app falls out of its group.
3. **Nested hashtags as the hierarchy** (`#work/clients`). Dropped:
   dragging would have to rewrite the note's text, there is no manual
   order, and locked notes would vanish from it.

Real folders were picked because Minote's premise is plain files the writer
owns, and structure that disappears outside the app breaks that.

## How it works

### On disk

- The library folder is the root. Every directory under it is a folder in
  the sidebar, including empty ones. Hidden directories (leading dot) and
  packages are skipped, with everything in them; symlinks aren't followed.
  A directory named like a note ("Notes.md") is a folder.
- A note is a note file (`NoteNaming.isNoteFile`) in the root or any
  folder. Other files are ignored and never shown, moved singly or deleted
  singly; they travel with their folder.
- A note's persistent identity is its path relative to the root
  ("Work/Clients/Acme.md"). `Note.id` stays a per-launch UUID. Everything
  that today remembers a file name remembers the relative path instead:
  saved tabs, the last selection, the editors re-shown after switching
  between local and iCloud. A bare name saved by an earlier build is a
  root-relative path, so nothing migrates.
- Names are unique per folder, across extensions as today ("Ideas.md" and
  "Ideas.mdlock" never share a folder). The same name in two folders is
  allowed.
- Folder names go through the same cleaning as note names (no "/" or ":",
  no leading dot, trimmed, length-capped). Paths compare the way stems do
  (`NoteNaming.stemsMatch`), for case-insensitive volumes.
- `.minote-vault` stays in the root only, and Whole Library still means
  every note in every folder. Folder names stay readable while locked, as
  titles do. A vault file found inside a subfolder is ignored.

### The hidden file: `.minote-folder`

One per folder that has something to remember (the root included), inside
that folder, so it moves with the folder whoever moves it. **(call)** JSON:

```json
{ "version": 1, "sort": "manual", "reversed": false,
  "order": ["Clients/", "Roadmap Q1", "Meeting notes"] }
```

- `order`: the folder's children in the writer's order. A subfolder is its
  name with a trailing slash; a note is its stem without extension, so
  locking or unlocking a note keeps its place.
- `sort` and `reversed`: this folder's own sort, or both absent to follow
  the folder above it (the root, with none, is Last Updated). They are one
  setting: set, inherited and cleared together.
- `order` is kept while the folder is sorted another way, so going back to
  Manual brings the writer's order back.
- Children missing from `order` (made elsewhere) come first, newest first.
  Names in `order` that no longer exist are ignored and dropped at the next
  write. Minote updates the entry when it renames or moves something
  itself; something renamed elsewhere loses its place and nothing else.
- An unknown `version`, or a file that doesn't parse, is left alone and
  treated as absent: never rewritten until the writer reorders that folder.
- In iCloud the current version wins and conflict versions are discarded.
- It is written like the vault: coordinated, atomic, counted as our own
  disk work so the scan it triggers isn't read as an outside change. The
  file is only created once there is something to store.

What is stored where:

| What | Where | Why |
|---|---|---|
| Manual order, every sort (the root's too) | `.minote-folder` | part of the organising; follows the folder and syncs |
| Group by, Show | UserDefaults, per device | a phone and a Mac want different views |
| Collapsed folders | UserDefaults, per device, by relative path | a view state |
| The folder looked into | the window, in memory | passing |

### Notes and drafts

- `Note` gains `folder` (its folder's relative path, "" for the root) and
  `created` (the file's creation date, for Sort by ▸ Date Created). A draft
  has a folder before it has a file.
- New Note makes its draft in the *current folder*: the folder looked into
  if there is one, else the folder of the front tab's note, else the root.
  "New Note" on a folder row or its menu makes it there. The draft's file is
  created in that folder at first save; if the folder is gone by then it is
  made again, never the text dropped.
- A note deleted elsewhere while it had unsaved edits is written again in
  the folder it was in (today: in the library folder).
- Auto-naming, wrap-up, and trashing an emptied note are unchanged, within
  the note's folder. Folders are never removed by Minote on its own, however
  empty.
- Locking converts the file in place, in its folder. `convert` writes a new
  file: it must carry the creation date over, or locking would reorder a
  library sorted by Date Created.
- Backups are unchanged (one flat, device-local folder). Deleting a locked
  note's plain backups by name can now also take the backups of a
  same-named plain note in another folder; that errs on the side of the
  lock and is accepted. **(call)** Matching by backup ID is exact, as today.

### Links between notes

`[see](Other note.md)` resolves from the linking note's folder first, as a
real relative path (`Sub/Note.md`, `../Note.md`). If nothing is there, it
falls back to today's match by name anywhere in the library, preferring the
same folder, then the shortest path, so links written before folders keep
working after their targets are filed away. **(call)**

### Changes made elsewhere

- The Mac's FSEvents watcher already covers the whole tree. iOS watches one
  folder with a vnode `PathWatcher`; it needs one per folder, kept in step
  with the folders the last scan found.
- A file that vanishes while a file with the same name and the same stamp
  (size and modification date) appears in another folder is one note moved,
  not a note deleted and another created: it keeps its `Note.id`, its tab
  and its unsaved edits. This also covers a folder renamed or moved in
  Finder or on another device. Two candidates, or none, fall back to
  today's remove-and-add. **(call)** The existing same-folder rule for a
  note locked elsewhere (`.md` ↔ `.mdlock`) stays and is checked within one
  folder.
- iCloud placeholders are asked for in every folder, as today in the root.
- Switching the library between local and iCloud moves the tree: each
  top-level item moves whole (a folder with everything in it, its
  `.minote-folder` included), under a free name if the destination has one
  with that name. Never merged, never overwritten, and what can't move
  stays and is reported, as today.

### Folder commands (Library)

All of these are serialised with the saves of the notes they touch (pending
edits are written first), count as our own disk work, and update, in
memory, every affected note's URL, the saved tabs, the collapsed set and
the order entries. None of them closes a tab except Move to Trash.

- **New Folder** in a folder: "New Folder", "New Folder 2"…, then renamed
  in place in the row.
- **Rename**: refused, with the usual error alert, if a sibling has the name.
- **Move a folder** into another folder or the root: refused into itself or
  one of its own descendants; refused if the destination has a folder of
  that name. **(call)** No merging.
- **Move a note** to a folder: a taken name gets a number, as restoring from
  the Trash does today; an auto-named note stays auto-named.
- **Move to Trash**: the folder goes to the Trash as one item, with
  everything in it, non-note files too. A folder that isn't empty asks
  first ("Move "Work" and its 12 notes to the Trash?"; it says so when
  there are other files). Its notes leave the list under the existing rules
  for a removed note.
- **Undo** (⌘Z, through the window's undo manager, as Move to Trash does
  today) for: trashing a folder, moving a note or folder, reordering, and
  the sort change a reorder can cause. **(call)**

### The view: Group by, Sort by, Show

- **Group by**
  - *Folder* (default): the tree.
  - *Date*: one flat list under Today, Yesterday, Previous 7 Days, Previous
    30 Days, then months of this year, then years, by last update. Folders
    aren't shown; each row carries its folder's path as a small label.
  - *None*: one flat list, as today, with the same label.
- **Sort by**: Manual, Last Updated (newest first, as today), Date Created
  (newest first), Title (A–Z), and Reverse Order for the three sorted
  ones. Drafts always come first in their folder.
  - There is one kind of sort, a folder's, and no per-device one. **(call)**
    A folder without a sort of its own follows the folder above it; the
    root without one is Last Updated.
  - The view menu's Sort by reads and sets the sort of the folder at the
    top of the list: the root, or the folder being looked into. So the
    menu always says what the list in front of the writer is doing, a
    reorder at the top level shows there as Manual, and the menu is the
    way back.
  - A folder row's menu has Sort By ▸ Same as "‹parent›" (clears its own),
    the four sorts, and Reverse Order.
  - Sorted (not Manual): subfolders first, in the same order as notes
    (a folder's date is its newest note's), then notes. Manual: subfolders
    and notes interleave freely.
  - In Date and None there are no folders to sort: the list uses the root's
    sort, and Manual there falls back to Last Updated.
- **Show**: Previews (the two excerpt lines), Dates, Note Counts on
  folders, each on by default (today's look), and Locked Notes Only.
  **(call)** With Previews off a note is a single line, for long trees.
- **Reset to Defaults** puts back Group by Folder and everything shown, and
  clears the sort of the folder at the top of the list (the root goes back
  to Last Updated). It doesn't touch the folders below, nor any stored
  manual order.

Search keeps working as now, over what is listed. In the tree it shows the
matching notes under their folders, opened for the search without changing
which folders are collapsed, and hides folders with nothing to show. A
folder whose own name matches is shown with everything in it. **(call)**

**Looking into a folder.** A folder's menu has "Show Only This Folder", and
the sidebar's title then reads as a path back ("Notes ▸ Work ▸ Clients",
each part a button). The list, the search and New Note narrow to that
folder. This is "filter inside a group". It belongs to the window and isn't
kept across launches. **(call)** If the folder goes away, the window steps
back to the nearest folder that still exists.

### The sidebar (Mac)

```
 ● ● ●  ▯                      ✎     header: window buttons, toggle, New Note
 ⌕ Search
 Notes                    ≡   ▢+     title or path back · view menu · New Folder
 ▾ Work                        12
     ▸ Clients                  4
     Roadmap Q1
     Two lines of preview…
     Yesterday
     Meeting notes
 ▾ Personal                     5
     Reading list
 ▸ Archive                     40
 A loose note at the top level
```

```
 Group by      Folder ▸
 Sort by       Last Updated ▸
 Show          ▸
 ─────────────
 New Folder
 Collapse All / Expand All
 ─────────────
 Reset to Defaults
```

- A new row under the search field holds the title (or the path back), the
  view menu and New Folder, in the chrome's own button style.
- **Folder row**: a chevron that turns, the name, the count of notes
  inside (all levels) at the right; under the pointer the count gives way
  to a "+" that makes a note there. A click anywhere else on the row opens
  or closes it. Shaped and shaded like a note row (`SidebarMetrics`,
  `palette.sidebarHover`); never selected. Children indent one step per
  level; folders start open.
- **Note row**: as today, indented under its folder.
- **Menus.** Note: today's items plus "Move to ▸" (the folder tree, and
  "New Folder…"). Folder: New Note, New Folder, Rename, Show Only This
  Folder, Sort By ▸, Show in Finder, Move to ▸, Move to Trash. Empty space:
  New Note, New Folder. "Move to ▸" is also the way to move anything
  without dragging (keyboard, VoiceOver).
- **File menu**: New Folder ⇧⌘N, and Move to ▸ for the front tab's note
  (library notes only).
- **Keyboard**: ↑/↓ walk the notes that are listed, skipping folder rows
  and anything inside a closed folder; the rest as today. Opening and
  closing folders from the keyboard is left for later. **(call)**
- **A tab** whose note shares its title with another open note shows its
  folder in the tab's tooltip.

### Dragging

Our own, like the tab bar's (no system drag session):

- Press and move a note or folder row: a small chip with its name follows
  the pointer; the row dims where it was.
- Over a folder row's middle: the folder highlights, the drop goes into it
  (at the top, in Manual). Over the gap between two rows: a line shows the
  place, indented to the level it would land at. Held over a closed folder
  for a moment, the folder opens. Near the list's top or bottom edge, the
  list scrolls.
- Reordering inside a folder that isn't sorted manually (the item already
  lives there) makes that folder Manual, starting from the order it was
  showing, then puts the item at the place; ⌘Z puts the sort back.
  **(call)** So a reorder never hits a dead end and never needs a trip to
  the menu first.
- An item coming from another folder never changes a folder's sort: over a
  sorted folder's rows the whole folder highlights and the item lands
  where the sort puts it. Only a Manual folder shows the line to a
  newcomer.
- Not allowed (no line, no highlight): a folder into itself or below
  itself; anything while Group by is Date or None, or while searching.
- Escape, or dropping outside the list, cancels.
- One item at a time.

### iOS

The library is shared, so the phone sees the same folders the moment the
Mac's sync. In this version iOS shows the tree (folders open and close),
has the same view menu in the list's toolbar, and edits through menus: New
Folder, Rename, Move to ▸, Move to Trash, Show Only This Folder. No
dragging. **(call)** It can ship after the Mac work; until it does, the
iOS list must at least show every note in every folder, with its folder as
a label, so nothing seems lost.

## Constraints

- Typing never goes through SwiftUI state, and a keystroke styles its line
  once. The tree's order is recomputed when a save lands, a scan
  reconciles, or an organising command or view setting changes it, the way
  `sortNotes` runs today; never from a per-keystroke observation of every
  note's title.
- Opening a file from Finder stays light: the library, and so the tree, is
  loaded only when a window shows it.
- All disk work for a note goes through `Library.enqueue`; folder commands
  wait for the notes they touch and bump `mutationCounter` like any write.
- Everything in "Rules that bit us" on locked notes holds in every folder:
  a sealed note is never taken for empty, plain text never goes into a
  `.mdlock`, lock and unlock throw away scans that started before them.
- The sidebar keeps its own rows on the chrome's paper, colours from
  `styleSheet.palette` / `PageTheme.palette`; no `List(.sidebar)`, no
  `NavigationSplitView`, no window toolbar.
- No repeating animation; the drag chip and the insertion line move with
  the pointer and stop with it. Motion respects Reduce Motion.
- Swift Testing unit tests for everything in MinoteKit; the SwiftPM scripts
  must keep working with Command Line Tools alone (`ViewState`, not
  `@State`).
- The debug driver's library keeps its own folder and defaults suite;
  driver folders and notes get names no real note has.

## Shape of the code

Settled here:

- Pure, tested pieces in MinoteKit: the relative folder path type; the
  `.minote-folder` codec; the view settings; building the listed rows (a
  flat array of folder, note and section rows with their depth) from notes,
  folders, folder settings, view settings, collapsed set, the folder looked
  into and the search; date sections; and resolving a drag (rows, their
  frames, the pointer → into a folder, at a place, or nothing). Like
  `TabStripLayout` for the tab bar.
- `NoteFileStore`: a recursive scan that returns notes and folders (with
  each folder's settings), per-folder name checks, folder create / rename /
  move / trash / restore, moving a note between folders, writing a
  folder's settings.
- `Library`: `folders`, folder settings, the commands above, the current
  folder for new notes, identity by relative path, link resolution, the
  outside-move rule.
- Mac: the sidebar's new row and view menu, folder rows, renaming in place,
  dragging, menus, the File menu items, driver commands for all of it.

Left to the builder:

- Type and method names, file layout, how row frames are collected for the
  drag, the chip's look, timings (opening a folder under a held drag,
  edge scrolling), exact indents and type sizes within the existing
  sidebar's scale.
- Whether the listed rows are computed in `Library` or in a small
  observable model beside it, as long as the keystroke constraint holds.
- How folder commands are serialised with per-note operations.
- The order of work. Suggested: (1) paths, the recursive scan and identity
  by relative path, with the sidebar still flat and showing a folder label,
  so nothing is lost and every existing test passes; (2) folder commands,
  `.minote-folder`, the row builder and view settings; (3) the Mac
  sidebar: tree, view menu, menus, renaming, looking into a folder;
  (4) dragging; (5) iOS.

## Testing

- Store: recursive scan (hidden folders, packages, placeholders in
  subfolders, empty folders), per-folder names, each folder command and its
  refusals, settings round trip and unknown versions, `convert` keeping
  the creation date.
- Library: a moved note keeps its id, editor and unsaved edits; renaming
  and moving a folder with open, edited and locked notes inside; trashing
  a folder and undoing it; a draft saved into its folder, and into a folder
  that vanished; a move made elsewhere recognised (and the two-candidate
  case not); links by relative path and by the old name-only form; tabs
  saved by path and restored, bare names included; lock, unlock and Whole
  Library with notes in folders; local ↔ iCloud moving a tree.
- Pure pieces: rows for every Group by × Sort by, folder sort overrides,
  search in the tree, looking into a folder, date sections across midnight
  and year ends, every drag resolution and refusal.
- Mac, through the debug driver: making, renaming, dragging and trashing
  folders; the view menu; tabs surviving a folder rename and a relaunch.
- By hand before shipping: iCloud on two devices (untested for the whole
  app until a signed build exists).

## Known edges

- An older Minote on another device won't list notes inside folders (it
  scans one level). They are not deleted; update both devices.
- A `.minote-folder` lost or overwritten by sync costs that folder's
  manual order and sort, nothing else.
- Whole Library seals every note Minote lists, and after this change that
  includes note files (`.md`, `.markdown`, `.txt`, `.text`) already sitting
  in subfolders of the library folder, which no build has listed before.
  With Whole Library on, they become `.mdlock` at the first unlock after
  the update, as any note added to the folder does today: sealed with the
  library's password, their plain files deleted, not trashed. No prompt,
  no guard. **(call)** That is what the mode promises (nothing readable in
  the folder), and the suggested first step of the work must be described
  with it in mind.

## Decisions made while writing this (to check)

1. iOS in this version: shows the tree and edits through menus, no
   dragging; may ship after the Mac.
2. Reordering inside a sorted folder switches that folder to Manual
   (undoable), rather than being refused; an item arriving from another
   folder never changes the sort.
3. One `.minote-folder` per folder (not one file for the library), holding
   order and sort. Sort is always a folder's (inherited downwards, set for
   the top of the list by the view menu) and syncs; Group by, Show and
   collapsed folders stay per device.
4. "Show Only This Folder" is how one filters inside a group; per window,
   not kept across launches.
5. Show has one filter, Locked Notes Only; richer filters wait.
6. Moving a folder onto a same-named folder is refused, not merged; a
   moved note takes a numbered name instead.
7. Links resolve by relative path first, then by name anywhere.
8. A file moved elsewhere is recognised by same name and same stamp.
9. Undo covers trash, moves, reorders and the sort change from a reorder;
   not renames or New Folder.
10. Deleting a locked note's backups by name may take a same-named plain
    note's backups from another folder.
11. Folders can't be opened or closed from the keyboard yet.
12. Search shows a folder whose name matches with everything in it.
13. With Whole Library on, note files already in subfolders are sealed at
    the first unlock after the update, without asking.
