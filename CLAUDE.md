# Minote

A quiet place to write: plain Markdown files, a library sidebar, everything else in the menus. The editor renders Markdown: no markup symbols show. Block markup is hidden or drawn as what it means (bullets •◦▪, clickable task boxes, quote bars, rules, code boxes, table lines); only the *inline* formatting under the caret (`**`, `[]()`) reveals its symbols, so it can be edited. View ▸ Preview (⌘R) is read-only: nothing reveals, a click follows links. While editing, ⌘-click follows a link (iOS: tap it when not typing) and hovering shows its address. View ▸ Show Markdown Syntax switches to iA-style dimmed markup. Philosophy and interaction model follow iA Writer; name, icon and typeface are our own (iA's fonts may not be bundled — we use IBM Plex Mono, OFL).

## Commands

```bash
scripts/test.sh                      # unit tests (Swift Testing)
scripts/build-app.sh --run           # Mac app → build/Minote.app (sandboxed, ad-hoc signed), relaunch
scripts/build-app.sh --universal     # arm64 + x86_64
scripts/build-ios-preview.sh --run   # iOS app compiled for Mac Catalyst → build/Minote iOS Preview.app
xcodegen generate && xcodebuild test -project Minote.xcodeproj -scheme Minote-iOS -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO   # iOS UI tests (real taps)
swift scripts/make-icon.swift        # regenerate AppIcon.icns + Assets.xcassets
xcodegen generate                    # Minote.xcodeproj for App Store archives (needs Xcode to build)
```

## Layout

- `Sources/MinoteKit` — Foundation only, shared by every platform, fully unit-tested.
  - `Library` (`@MainActor @Observable`): notes, selection, drafts, debounced autosave, auto-naming, trash/undo, reconciling outside changes. All disk work for a note is serialized through `enqueue`.
  - `NoteFileStore` (actor): scan, safe write (`replaceItemAt` + xattr copy), create, rename, trash. In iCloud (`isUbiquitous`): coordinated I/O, downloads `.icloud` placeholders, saves conflict versions as "(conflict)" notes. Emptying a non-empty note first copies it to `../Backups`.
  - `LibraryStorageSwitcher`: opens the library locally or in iCloud Drive and moves notes between them (`setUbiquitous`).
  - `Markdown/`: `MarkdownLexer` (per-line CommonMark/GFM styling spans, list markers, quote depth, links), `FenceIndex` (incremental code-fence tracking), `MarkdownEditing` (Format actions as pure `TextEdit`s; `hiddenMarkup`/`adjustedCaret`/`deleteMarkup` for the rendered view), `MarkdownLinks` (resolves references, footnotes, `#heading` anchors, other notes), `TextStatistics`.
- `Sources/MinoteEditor` — AppKit/UIKit shared look: `EditorTheme`, `EditorStyleSheet`, `MarkdownStyler` (rendered/source views; hidden markup = 0.01 pt clear font; drawn markup = clear glyphs + `.minoteMark`/`.minoteBlock` attributes), `MarkdownLayoutFragment` (TextKit 2 fragment that draws those marks; installed by `EditorTextEngine.attach(to:)`), `EditorTextEngine` (text-storage delegate: incremental restyle, caret reveal, Preview, Focus mode, caret snapping out of hidden markup, link/task-box hit testing), `FormatAction`. Branch on `#if os(macOS)`, never `canImport(AppKit)` (true on Catalyst).
- `Sources/Minote` — macOS app (SwiftUI shell + TextKit 2 `NSTextView`). `Debug/DebugDriver.swift` (DEBUG only): with `MINOTE_DRIVER=1` the app takes commands (click/key/type/hover/snapshot…) from `$TMPDIR/minote-driver/in`, against its own `DriverNotes` library — interaction tests without the screen.
- `Apps/iOS` — iPhone/iPad app (SwiftUI + TextKit 2 `UITextView`). Not a SwiftPM target; built by Xcode or `build-ios-preview.sh`. Module name `MinoteMobile` (`Minote` is the Mac target). `Tests/MinoteiOSUITests`: XCUITests (DEBUG seed via `MINOTE_UITEST_NOTE`).
- `Support/` — `Minote.xcconfig` (identity + version, single source of truth), Info.plists, entitlements, privacy manifest, container migration.

## Rules that bit us

- Typing never goes through SwiftUI state. The library drives the editor via the `NoteEditor` protocol.
- Files Minote didn't create are never renamed (auto-naming is gated on the `com.mlutfullaev.minote.autoname` xattr).
- TextKit 2: `baselineOffset` has its standard meaning inside a fixed line height (negative = lower); a positive one shrinks the line. `NSTextLineFragment.glyphOrigin` is the baseline *before* the offset: drawn baseline = `glyphOrigin.y - baselineOffset`. `drawInsertionPoint` is ignored, hence `CaretView`.
- Never give the Mac editor's NSScrollView a bottom `contentInsets`: AppKit treats that band as outside the page, so clicks there were swallowed or started a selection to the end of the note. Scroll-past-end is `WriterTextView.bottomPadding` (taller view + `textContainerOrigin` override).
- The caret never rests inside hidden block markup (`EditorTextEngine.adjustedSelection`). Only keyboard moves may step back out of a line (pass `previous` for those, nil for clicks: a click sets the selection twice). NSTextLayoutManager rendering attributes don't reliably recolor NSTextView text, so Focus mode restyles storage. After replacing the whole text, call `layoutViewport()` or only the old viewport renders.
- The SwiftPM scripts work with Command Line Tools alone: SwiftUI's `@State` is a macro whose plugin ships only with Xcode → use the `ViewState` typealias. Swift Testing's macro plugin needs `-plugin-path` (see `scripts/test.sh`). Xcode 27 is now installed too (iOS simulators, UI tests, archives).
- macOS bash is 3.2: guard empty arrays under `set -u`.

## iCloud

Container `iCloud.com.mlutfullaev.minote`, shown as "Minote" in iCloud Drive. Only signed builds carry the iCloud entitlements (`Support/Minote-AppStore.entitlements`, `Minote-iOS.entitlements`); local ad-hoc builds use `Minote.entitlements`, where iCloud is simply unavailable. Untested until a signed build exists: verify sync, placeholders and conflicts on two devices.

## Shipping (needs Xcode + an Apple Developer account)

1. `xcodegen generate`, open `Minote.xcodeproj`, set the Team on both targets, enable the iCloud container in the developer portal.
2. Archive `Minote-macOS` and `Minote-iOS`, upload from the Organizer. Same bundle id on both → universal purchase.
3. App Store Connect: privacy policy URL, "Data Not Collected", screenshots. Export compliance is pre-answered (`ITSAppUsesNonExemptEncryption = NO`).
