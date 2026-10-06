#if DEBUG
import AppKit
import MinoteEditor
import MinoteKit

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
///   config <key> <value>      showsSyntax|preview true|false
///   appearance dark|light     (not saved)
///   pref <key> true|false|remove
///   scroll <y>
@MainActor
enum DebugDriver {
    private static var timer: Timer?
    private static var directory: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minote-driver") }

    static func startIfRequested(windowState: WindowState) {
        guard ProcessInfo.processInfo.environment["MINOTE_DRIVER"] != nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        WriterTextView.assumesKeyWindow = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { poll(windowState) }
        }
    }

    private static var busy = false
    private static var lastHit = "" 

    private static func poll(_ windowState: WindowState) {
        let input = directory.appendingPathComponent("in")
        guard !busy, let command = try? String(contentsOf: input, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: input)
        busy = true
        Task { @MainActor in
            let result = await run(command.trimmingCharacters(in: .whitespacesAndNewlines), windowState)
            try? result.write(to: directory.appendingPathComponent("out.tmp"), atomically: false, encoding: .utf8)
            try? FileManager.default.moveItem(at: directory.appendingPathComponent("out.tmp"), to: directory.appendingPathComponent("out"))
            busy = false
        }
    }

    private static func run(_ command: String, _ windowState: WindowState) async -> String {
        guard let editor = windowState.editor, let window = editor.textView.window else { return "error: no editor" }
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
