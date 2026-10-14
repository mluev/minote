# Tabs (macOS)

Status: approved behavior, technical design for implementation. Mac only; the
iOS app keeps its single page.

## Behavior

Every note or file opened, from the sidebar, a link, Finder, File ▸ Open…,
Open Recent or the Dock, shows in the front window. Where it lands depends on
the tab in front:

| Front tab                 | Untouched (not typed in)     | Edited              |
|---------------------------|------------------------------|---------------------|
| A library note            | the new one replaces it      | new tab beside it   |
| A file opened from Finder | new tab beside it            | new tab beside it   |

- An untouched tab's title is in italics. Typing, ticking a task box or a
  Format command marks it edited; moving the caret or scrolling doesn't.
- A note already open in a tab is never opened twice: its tab comes forward.
- With no window, a Finder file opens a light window (sidebar hidden, library
  not loaded). Later files join it as tabs. A library note with no window
  opens a window with the sidebar.
- ⌘T: new tab with an empty note. ⌘-click in the sidebar or "Open in New Tab"
  (its context menu): new tab, nothing replaced. ⌘N: as today, under the rule
  above.
- ⌘W closes the tab (the window with its last tab). ⌃Tab / ⌃⇧Tab and
  ⌘⇧] / ⌘⇧[: next / previous tab. ⌘1…⌘8: that tab, ⌘9: the last.
  Typewriter Mode moves to ⌃⌘T.
- Sidebar ↑/↓ open the next note under the same rule, so browsing stays in
  one tab. Return focuses the page.
- Tabs reorder by dragging, drag out into a window, drag into another
  window's tab bar; Window ▸ Merge All Windows, Move Tab to New Window, Show
  All Tabs. The tab bar shows from two tabs on.
- Showing the sidebar in a light window loads the library there.
- Relaunch: library-note tabs come back per window, in order, with the same
  tab in front. Tabs of files opened from Finder don't (as today).
- A blank new note that's replaced or closed disappears; a note the user
  emptied goes to the Trash quietly when its last tab closes (as today, when
  it was left).

## Approach: native window tabs

Each tab is an AppKit window in a native tab group (`NSWindowTabGroup`), like
Finder and Safari. Chosen over a tab bar of our own because dragging tabs
between windows, out into windows and merging them is exactly what the
system does well, with the standard shortcuts, menus, VoiceOver and full
screen behavior. A custom bar with cross-window dragging would be large,
fragile and never quite native.

Costs, accepted:

- The tab bar is the system's: it follows light/dark but can't take the
  Sepia paper.
- One editor per tab (a TextKit 2 stack, a few MB). A tab in the background
  isn't key: its caret doesn't blink and nothing draws, so idle stays free.
- Every tab window has its own sidebar view over the one shared `Library`
  (as Finder does). A title-line keystroke updates that row in each.
- `Library` must serve several editors at once (below). The single-editor
  path the iOS app uses behaves exactly as before.

Rejected: one editor per window swapping text (cheapest, but drag-out and
merge would be ours to build); one hidden editor per tab inside a custom bar
(the costs of both).

## MinoteKit

### Library serves several editors

Today `Library` has one `editor` and wraps a note up ("leaves" it: drops a
blank draft, renames, trashes an emptied note) when `selectedID` changes.
With tabs, a note in a background tab is still open, so a note is wrapped up
when *no editor shows it any more*.

- `attach(_:)` adds an editor (weakly held); it shows `selectedNote`, as
  today. `attach(_:showing:)` shows a given note. `detach(_:)` keeps its
  text, saves, and wraps its note up if nothing else shows it.
- `show(_ id:in:)` is the primitive: keeps the editor's old note's text,
  displays the new one, wraps up the old note if no editor shows it, makes
  this the front editor and persists `LastOpenedNote`. It refuses a note
  another editor shows (one note, one editor: two editors on one file
  overwrite each other).
- `activate(_:)`: the editor's window came forward. `selectedID` mirrors the
  front editor's note without displaying or wrapping anything up.
- Setting `selectedID` directly (iOS's list, tests) is `show(_:in:)` on the
  front editor: identical to today with one editor.
- Every "per editor" helper (capturing live text, the title-line check
  before renaming, reloading a file changed on disk, `saveNow`) finds the
  editor showing that note instead of assuming one.
- Opening on the user's behalf goes through `open(_:)`, which calls
  `openHandler` when set (the Mac's tab routing) or sets `selectedID`.
  Following a link, Duplicate, undoing Move to Trash and New Note use it.
- When a shown note is removed (trashed, deleted elsewhere), `removalHandler`
  is asked per editor; it returns true if the tab closes. Otherwise the
  editor shows a neighbor no other editor shows, or a new draft (today's
  behavior).
- `relocate` (local ⇄ iCloud) remembers each editor's file name and shows
  the same file again after reloading, so open tabs survive a move.

### Pure, tested pieces

- `TabPlacement`: given the front tab (library note or outside file, edited
  or not), and whether the note is already open, returns focus / replace /
  new tab. The behavior table above is its test.
- `SavedTabs` (Codable): per window, the library notes' file names and the
  front index. `restored(existing:)` drops names no longer in the library and
  clamps the index. Stored under `OpenTabs`; `LastOpenedNote` stays as the
  fallback.

## Mac app

- `PageWindow` replaces `LibraryWindow`'s window and `FileSession`: one
  NSWindow (tabbing identifier `com.mlutfullaev.minote.page`), its
  `WindowState`, its editor, and its page: a library note, or an outside
  file (`OpenedFile`: URL, single-file `Library`, `PathWatcher`, from
  `FileSession`). `isEdited` is set by the editor's first user edit and reset
  when the page shows another note. Content: `PageView`, a
  NavigationSplitView of `SidebarView` (shared library) and `EditorPage`.
- Replacing a tab with the same kind of page shows the note in the same
  editor (`show(_:in:)`). Across kinds (library note ⇄ outside file) a new
  PageWindow is inserted at the same index (`tabGroup.insertWindow(_:atIndex:)`)
  and the old one closed.
- `Workspace` (owned by `AppDelegate`) replaces `LibraryWindow` as owner and
  router: the shared library and storage switcher (loaded on first need, as
  today), every PageWindow, outside files by URL, recents (from
  `OpenedFiles`), `open(note:newTab:)`, `open(url:)`, `newTab()`, the front
  page the menus act on, saving and termination across all pages, tab
  persistence and restoration. "Opening stays light" is kept: a Finder
  launch makes one light window per group and never loads the library.
- Tab titles: the window title is the note's title (a file's name for
  outside files); `window.tab.attributedTitle` is italic while untouched.
- Sidebar: highlight = this window's note; click opens (⌘-click: new tab),
  context menu "Open in New Tab", ↑/↓ open under the rule, Return focuses.
- Menus (`AppCommands`): `front` is the key page's library and window state;
  library-only commands (Duplicate, Rename, Move to Trash) are enabled when
  the front page is a library note. New Tab ⌘T, Typewriter ⌃⌘T, ⌘1…⌘9,
  ⌘⇧] / ⌘⇧[. `NSWindow.allowsAutomaticWindowTabbing` turns on, for the
  system's Window menu items.
- `ChromeFader` keeps fading the titlebar (the tab bar sits in it) while
  typing with the sidebar hidden.
- `DebugDriver` acts on the key page and gains `tabs`, `open <name> [new]`,
  `newtab`, `tab <i>`, `closetab`, for interaction tests.

## Testing

- Unit (MinoteKit, Swift Testing): Library with two `FakeEditor`s (a blank
  draft dropped only when no editor shows it; an emptied note trashed only
  when its last editor leaves; text captured and saved from a background
  editor; disk changes reload the right editor; removal handler; one note,
  one editor; relocation keeps pages). `TabPlacement` table. `SavedTabs`
  restore. Every existing Library test passes unchanged (iOS path).
- Interaction (DebugDriver scripts): replace when untouched, new tab after
  typing, a Finder file into the front window, light window stays light,
  restore after relaunch.
- By hand: drag a tab out, in and between windows; merge; full screen;
  Sepia and Dark; the fading chrome; VoiceOver reads tab titles.
- CI keeps building the iOS app and running its UI tests.

## To verify early

- Whether dragging a whole one-tab window onto another tab bar groups it
  (dragging a tab and Merge All Windows do).
- Cost of N hidden sidebars while typing a title line, with ~20 tabs.

## Order of work

1. Library serving several editors, `open`/removal hooks, relocation;
   `TabPlacement`, `SavedTabs`. Tests. No visible change.
2. `PageWindow` + `Workspace` replace `LibraryWindow`/`FileSession`/
   `OpenedFiles`; native tabs, ⌘T, shortcuts, menus.
3. The untouched rule, italic titles, sidebar opening.
4. Restoring tabs at launch.
5. DebugDriver commands, interaction scripts, CLAUDE.md.
