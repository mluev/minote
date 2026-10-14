#if DEBUG
import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Drives the editor from outside, for interaction tests of debug builds.
/// Real NSEvents go through the window, so clicks, keys and hovering take the
/// same path as the user's. Enabled by the MINOTE_DRIVER environment variable;
/// commands are read from `$TMPDIR/minote-driver/in`, results written to `out`.
///
/// Commands (one per file, character indices are UTF-16 offsets):
///   text <escaped>            replace the note's text (\n for newlines)
///   click <index> [cmd]       click at the middle of a character
///   clickat <x> <y> [cmd]     click at a point in text view coordinates
///   hover <index>             move the mouse over a character
///   key <name> [shift|opt|cmd…] left right up down home end delete return tab, or one character
///   type <escaped>            type text through the input path
///   select <location> <length>
///   state                     selection, caret, text and the cursor
///   snapshot <path>           PNG of the window contents
///   snapshotpanel <path>      PNG of the text settings popover
///   snapshotwindow <title> <path>   PNG of another window, by title
///   config <key> <value>      showsSyntax|preview true|false
///   appearance dark|light     (not saved)
///   theme system|light|sepia|dark   (saved: put it back after)
///   panel true|false          the text settings popover
///   toolbar                   every window's toolbar items and where they sit
///   pref <key> true|false|remove
///   scroll <y>
///   outline                   the outline beside the page (Preview)
///   outlinehover <i|rail|off> move the pointer over a heading's dash or row, or away
///   outlineclick <i>          click a heading in the card (opening it first)
///   outlinefilm <path> [dark|sepia|light]   PNG strip of the morph, rail to card
///   tabs                      every window's tabs: title, kind, edited, which is selected
///   open <file name> [new]    open a library note under the tab rules ("new": a tab of its own)
///   openfile <path>           open a file as if from Finder
///   newtab | newnote          File ▸ New Tab / New Note
///   tab <i>                   select the front window's tab i (0-based)
///   closetab                  close the tab in front
///   savetabs                  save the open tabs now and read them back
///   menus                     the File, View and Window menus with their shortcuts
///   trash <file name>         Move to Trash (driver notes only)
@MainActor
enum DebugDriver {
    private static var timer: Timer?
    private static var directory: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minote-driver") }

    static func startIfRequested(workspace: Workspace) {
        guard ProcessInfo.processInfo.environment["MINOTE_DRIVER"] != nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        WriterTextView.assumesKeyWindow = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { poll(workspace) }
        }
    }

    private static var busy = false
    private static var lastHit = "" 

    private static func poll(_ workspace: Workspace) {
        let input = directory.appendingPathComponent("in")
        guard !busy, let command = try? String(contentsOf: input, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: input)
        busy = true
        Task { @MainActor in
            let result = await run(command.trimmingCharacters(in: .whitespacesAndNewlines), workspace)
            try? result.write(to: directory.appendingPathComponent("out.tmp"), atomically: false, encoding: .utf8)
            try? FileManager.default.moveItem(at: directory.appendingPathComponent("out.tmp"), to: directory.appendingPathComponent("out"))
            busy = false
        }
    }

    private static func run(_ command: String, _ workspace: Workspace) async -> String {
        if let result = await runTabCommand(command, workspace) { return result }
        guard let windowState = workspace.targetPage?.windowState, let editor = windowState.editor,
              let window = editor.textView.window else { return "error: no editor" }
        let textView = editor.textView
        if !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        let words = rest.split(separator: " ").map(String.init)

        switch name {
        case "text":
            textView.setSelectedRange(NSRange(location: 0, length: textView.textStorage?.length ?? 0))
            textView.insertText(unescape(rest), replacementRange: textView.selectedRange())
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        case "click":
            guard let index = Int(words.first ?? ""), let point = center(of: index, in: textView) else { return "error: bad index" }
            click(at: point, modifiers: modifiers(words.dropFirst()), in: textView)
        case "clickat":
            guard words.count >= 2, let x = Double(words[0]), let y = Double(words[1]) else { return "error: bad point" }
            click(at: NSPoint(x: x, y: y), modifiers: modifiers(words.dropFirst(2)), in: textView)
        case "hover":
            guard let index = Int(words.first ?? ""), let point = center(of: index, in: textView) else { return "error: bad index" }
            let location = textView.convert(point, to: nil)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                textView.mouseMoved(with: event)
            }
        case "key":
            key(words.first ?? "", modifiers: modifiers(words.dropFirst()), in: window)
        case "type":
            for character in unescape(rest) {
                textView.insertText(String(character), replacementRange: textView.selectedRange())
            }
        case "select":
            guard words.count == 2, let location = Int(words[0]), let length = Int(words[1]) else { return "error" }
            textView.setSelectedRange(NSRange(location: location, length: length))
            textView.scrollRangeToVisible(textView.selectedRange())
        case "snapshot":
            try? await Task.sleep(for: .milliseconds(150))
            return snapshot(window, to: rest)
        case "config":
            guard words.count == 2 else { return "error" }
            UserDefaults.standard.set(words[1] == "true", forKey: words[0] == "preview" ? "DebugPreview" : PreferenceKey.showsSyntax)
            if words[0] == "preview" { windowState.isPreviewing = words[1] == "true" }
        case "state":
            break
        case "pref":
            // pref <key> true|false|remove — a view preference (saved: put it back after).
            guard words.count == 2 else { return "error" }
            if words[1] == "remove" {
                UserDefaults.standard.removeObject(forKey: words[0])
            } else {
                UserDefaults.standard.set(words[1] == "true", forKey: words[0])
            }
        case "scroll":
            // scroll <y>: the visible part of the page starts at y.
            guard let y = Double(rest) else { return "error" }
            textView.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: y))
            textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
        case "appearance":
            NSApp.appearance = NSAppearance(named: rest == "dark" ? .darkAqua : .aqua)
        case "theme":
            guard let theme = PageTheme(rawValue: rest) else { return "error: bad theme" }
            PageTheme.select(theme)
        case "panel":
            windowState.isShowingTextSettings = rest == "true"
        case "toolbar":
            return NSApp.windows.filter { $0.isVisible && $0.toolbar != nil }.map { window in
                "window \"\(window.title)\" width \(window.frame.width) background \(window.backgroundColor.description)\n" + (window.toolbar?.items ?? []).map { item in
                    let frame = item.view.map { $0.convert($0.bounds, to: nil) } ?? .zero
                    return "  \(item.itemIdentifier.rawValue) \(item.label) \(frame)"
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        case "snapshotwindow":
            guard words.count == 2, let other = NSApp.windows.first(where: { $0.isVisible && $0.title == words[0] }) else { return "error: no such window" }
            try? await Task.sleep(for: .milliseconds(150))
            return snapshot(other, to: words[1])
        case "snapshotpanel":
            try? await Task.sleep(for: .milliseconds(300))
            guard let popover = NSApp.windows.first(where: { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }) else { return "error: no popover" }
            return snapshot(popover, to: rest)
        case "outline":
            try? await Task.sleep(for: .milliseconds(150))
            return outlineState(editor)
        case "outlinehover":
            let outline = editor.outline
            guard let overlay = outline.overlayView, let layout = outline.model.layout else { return "error: no outline" }
            let point: CGPoint
            switch rest {
            case "off":
                point = CGPoint(x: 0, y: 0)
            case "rail":
                point = CGPoint(x: layout.railRect.midX, y: layout.railRect.midY)
            default:
                guard let index = Int(rest), let rect = outline.itemRect(index) else { return "error: bad index" }
                point = CGPoint(x: rect.midX, y: rect.midY)
            }
            moveMouse(to: point, in: overlay, textView: textView)
            try? await Task.sleep(for: .milliseconds(700))
            return outlineState(editor)
        case "outlineclick":
            let outline = editor.outline
            guard let overlay = outline.overlayView, let index = Int(rest) else { return "error: no outline" }
            if !outline.isCardOpen, let rect = outline.itemRect(index) {
                moveMouse(to: CGPoint(x: rect.midX, y: rect.midY), in: overlay, textView: textView)
                try? await Task.sleep(for: .milliseconds(700))
            }
            guard let row = outline.itemRect(index) else { return "error: bad index" }
            let point = CGPoint(x: row.midX, y: row.midY)
            let windowPoint = overlay.convert(point, to: nil)
            let hit = window.contentView?.hitTest(windowPoint)
            lastHit = hit.map { String(describing: type(of: $0)) } ?? "nil"
            guard hit === overlay else { return "error: the click would land on \(lastHit)" }
            let time = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: time,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                if type == .leftMouseDown { overlay.mouseDown(with: event) } else { overlay.mouseUp(with: event) }
            }
            try? await Task.sleep(for: .milliseconds(900))
            return outlineState(editor) + "\n" + state(textView, editor: editor)
        case "outlinefilm":
            guard let path = words.first else { return "error: no path" }
            return outlineFilm(editor, to: path, look: words.count > 1 ? words[1] : "light")
        case "probe":
            guard let index = Int(words.first ?? ""), let point = center(of: index, in: textView) else { return "error: bad index" }
            let origin = textView.textContainerOrigin
            let container = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            return "point \(point) container \(container) taskBox \(String(describing: editor.taskBox(at: container))) link \(String(describing: editor.linkIndex(at: container))) char \(String(describing: editor.characterIndexForProbe(container)))"
        default:
            return "error: unknown command \(name)"
        }
        // Let the deferred caret update and restyling run.
        try? await Task.sleep(for: .milliseconds(120))
        return state(textView, editor: editor)
    }

    // MARK: Events

    /// Commands about tabs and windows; nil for the others.
    private static func runTabCommand(_ command: String, _ workspace: Workspace) async -> String? {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "tabs":
            break
        case "open":
            var name = rest
            let newTab = name.hasSuffix(" new")
            if newTab { name = String(name.dropLast(4)) }
            guard let note = workspace.library.notes.first(where: { $0.fileURL?.lastPathComponent == name || $0.title == name }) else {
                return "error: no note \(name)"
            }
            workspace.open(note: note.id, newTab: newTab)
        case "openfile":
            workspace.open(URL(fileURLWithPath: rest))
        case "newtab":
            workspace.newTab()
        case "newnote":
            workspace.newNote()
        case "tab":
            guard let index = Int(rest) else { return "error: bad index" }
            workspace.selectTab(at: index)
        case "closetab":
            workspace.targetPage?.window.performClose(nil)
        case "trash":
            guard let note = workspace.library.notes.first(where: { $0.fileURL?.lastPathComponent == rest || $0.title == rest }) else {
                return "error: no note \(rest)"
            }
            await workspace.library.moveToTrash(note.id)
        case "menus":
            // The File, View and Window menus with their shortcuts.
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                // As if opened: some items are added only then.
                menu.delegate?.menuNeedsUpdate?(menu)
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
                menu.update()
            }
            return (NSApp.mainMenu?.items ?? []).filter { ["File", "View", "Window"].contains($0.title) }.map { menu in
                menu.title + ":\n" + (menu.submenu?.items ?? []).filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
                    "  \(item.title) \(item.keyEquivalentModifierMask.rawValue >> 17) \(item.keyEquivalent)\(item.isEnabled ? "" : " (disabled)")"
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        case "savetabs":
            workspace.saveTabs()
            let saved = SavedTabs.load().map { "\($0.windows)" } ?? "nothing saved"
            return "ordered windows \(NSApp.orderedWindows.count), saved \(saved)"
        default:
            return nil
        }
        try? await Task.sleep(for: .milliseconds(400))
        return workspace.describeTabs()
    }

    private static func click(at point: NSPoint, modifiers: NSEvent.ModifierFlags, in textView: WriterTextView) {
        guard let window = textView.window else { return }
        let location = textView.convert(point, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: time,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        // The text view tracks the mouse until it sees the mouse-up: queue it first.
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        // Straight to the view: an inactive window would swallow the click to activate.
        if let down = event(.leftMouseDown), let target = window.contentView?.hitTest(down.locationInWindow) ?? textView as NSView? {
            lastHit = String(describing: type(of: target)) + " frame \(target.frame) in \(target.superview.map { String(describing: type(of: $0)) } ?? "-")"
            target.mouseDown(with: down)
        }
    }

    private static func key(_ name: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
        let special: [String: (String, UInt16)] = [
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            "home": (String(UnicodeScalar(NSHomeFunctionKey)!), 115), "end": (String(UnicodeScalar(NSEndFunctionKey)!), 119),
            "delete": ("\u{7F}", 51), "return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1B}", 53),
        ]
        let (characters, code) = special[name] ?? (name, 0)
        var flags = modifiers
        if ["left", "right", "up", "down"].contains(name) { flags.insert([.numericPad, .function]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                if type == .keyDown, !modifiers.contains(.command) || !(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false) {
                    window.sendEvent(event)
                }
            }
        }
    }

    private static func modifiers(_ words: some Sequence<String>) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for word in words {
            switch word {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    /// Sends a mouse move to the outline and to the text under it, as AppKit does.
    private static func moveMouse(to point: CGPoint, in overlay: OutlineOverlayView, textView: WriterTextView) {
        guard let window = overlay.window else { return }
        let location = overlay.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        if point == .zero {
            overlay.mouseExited(with: event)
        } else {
            overlay.mouseMoved(with: event)
        }
        textView.mouseMoved(with: event)
    }

    private static func outlineState(_ editor: EditorCoordinator) -> String {
        let outline = editor.outline
        let model = outline.model
        let clip = editor.scrollView.contentView
        var lines = [
            "shown: \(model.isShown) open: \(outline.isCardOpen) progress: \(model.progress) gliding: \(outline.isGliding)",
            "active: \(model.active.map(String.init) ?? "-") pinned: \(outline.pinnedIndex.map(String.init) ?? "-") plate: \(model.plate.map(String.init) ?? "-") \(model.plateStrength)",
            "origin: \(model.origin) listOffset: \(model.listOffset)",
            "overlay: \(outline.overlayView.map { "\($0.frame) interactive \($0.interactiveRect)" } ?? "none")",
            "clipOrigin: \(clip.bounds.minY) topPadding: \(editor.textView.topPadding) inset: \(editor.scrollView.contentInsets.top)",
        ]
        if let layout = model.layout {
            lines.append("layout: hidden \(layout.isHidden) dashes \(layout.dashRange) spacing \(layout.dashSpacing) scale \(layout.dashScale) rail \(layout.railRect) card \(layout.cardRect)")
        }
        for (index, heading) in model.headings.enumerated() {
            lines.append("  [\(index)] h\(heading.level) \(heading.title.debugDescription) @\(heading.location)/\(heading.contentLocation)")
        }
        return lines.joined(separator: "\n")
    }

    /// The morph from rail to card, frame by frame, on the page's paper.
    private static func outlineFilm(_ editor: EditorCoordinator, to path: String, look: String) -> String {
        let model = editor.outline.model
        guard let layout = model.layout else { return "error: no outline layout" }
        let paper: EditorPaper = look == "sepia" ? .sepia : .standard
        let palette = EditorPalette.of(paper)
        let appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)!
        let crop = layout.cardRect.union(layout.railRect).insetBy(dx: -24, dy: -24)
        let steps = Array(stride(from: 0.0, through: 1.0, by: 0.1))
        let columns = 4
        let scale: CGFloat = 2
        let cell = CGSize(width: crop.width, height: crop.height)
        let rows = (steps.count + columns - 1) / columns
        let size = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "error: context" }
        var paperColor = palette.background.cgColor
        appearance.performAsCurrentDrawingAppearance { paperColor = palette.background.cgColor }
        context.setFillColor(paperColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        for (number, progress) in steps.enumerated() {
            let view = OutlineRailView(layout: layout, titles: model.titles, ids: model.ids, active: model.active, plate: nil, plateStrength: 0,
                                       progress: progress, origin: model.origin, listOffset: layout.listOffset(placing: model.origin),
                                       reduceMotion: model.reduceMotion, palette: palette)
                .frame(width: layout.cardRect.maxX + 40, height: crop.maxY + 40, alignment: .topLeading)
                .offset(x: -crop.minX, y: -crop.minY)
                .frame(width: cell.width, height: cell.height, alignment: .topLeading)
                .clipped()
                .environment(\.colorScheme, look == "dark" ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            var image: CGImage?
            appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            guard let image else { return "error: render" }
            let column = number % columns, row = number / columns
            let x = CGFloat(column) * cell.width * scale
            let y = (size.height - CGFloat(row + 1) * cell.height) * scale
            context.draw(image, in: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        guard let strip = context.makeImage() else { return "error: image" }
        let rep = NSBitmapImageRep(cgImage: strip)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "error: png" }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return "error: \(error)" }
        return "film: \(path) frames \(steps.count) cell \(cell)"
    }

    // MARK: Inspection

    /// The middle of a character's glyph, in text view coordinates.
    private static func center(of index: Int, in textView: WriterTextView) -> NSPoint? {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: index),
              let end = content.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return nil }
        layoutManager.ensureLayout(for: range)
        var frame: NSRect?
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
            frame = rect
            return false
        }
        guard let rect = frame else { return nil }
        let origin = textView.textContainerOrigin
        return NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
    }

    private static func state(_ textView: WriterTextView, editor: EditorCoordinator) -> String {
        let selection = textView.selectedRange()
        let string = textView.string as NSString
        let line = string.length > 0 ? string.lineRange(for: NSRange(location: min(selection.location, string.length), length: 0)) : NSRange()
        let caret = textView.caretView
        let window = textView.window
        var lines = [
            "selection: \(selection.location) \(selection.length)",
            "caretVisible: \(!caret.isHidden)",
            "caretFrame: \(Int(caret.frame.minX)) \(Int(caret.frame.minY)) \(Int(caret.frame.width))x\(Int(caret.frame.height))",
            "key: \(window?.isKeyWindow ?? false) firstResponder: \(window?.firstResponder === textView)",
            "editable: \(textView.isEditable)",
            "line: \(string.length > 0 ? string.substring(with: line).debugDescription : "\"\"")",
            "cursor: \(NSCursor.current == NSCursor.pointingHand ? "pointingHand" : NSCursor.current == NSCursor.iBeam ? "iBeam" : "other")",
            "hover: \(editor.hoverDescription)",
            "hintFrame: \(editor.linkHintFrame)",
            "length: \(string.length)",
            "hit: \(lastHit)",
            "scroll: frame \(editor.scrollView.frame) clip \(editor.scrollView.contentView.frame) insets \(editor.scrollView.contentInsets.top) \(editor.scrollView.contentInsets.bottom) clipBounds \(editor.scrollView.contentView.bounds)",
        ]
        if let point = selection.length == 0 ? center(of: max(0, selection.location - 1), in: textView) : nil {
            lines.append("prevCharCenter: \(Int(point.x)) \(Int(point.y))")
        }
        lines.append("text: \(textView.string.debugDescription)")
        return lines.joined(separator: "\n")
    }

    private static func snapshot(_ window: NSWindow, to path: String) -> String {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "error: no view" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "error: png" }
        let url = path.isEmpty ? directory.appendingPathComponent("snapshot.png") : URL(fileURLWithPath: path)
        do { try data.write(to: url) } catch { return "error: \(error)" }
        return "snapshot: \(url.path)"
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }
}
#endif
