import AppKit
import MinoteEditor
import SwiftUI

/// A menu drawn by Minote: rows with a glyph or a checkmark, a title, a
/// detail (the current value, a shortcut) and submenus that open to the side.
struct ChromeMenu: Identifiable, Equatable {
    let id = UUID()
    var items: [ChromeMenuItem]

    static func == (lhs: ChromeMenu, rhs: ChromeMenu) -> Bool { lhs.id == rhs.id }
}

struct ChromeMenuItem: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([ChromeMenuItem])
        case divider
    }

    let id = UUID()
    var title = ""
    var systemImage: String?
    /// On the right: a current value or a shortcut.
    var detail: String?
    var isChecked = false
    var isEnabled = true
    /// Levels it steps in, for a tree of folders.
    var indent = 0
    var kind: Kind

    var isDivider: Bool { if case .divider = kind { true } else { false } }
    var isSelectable: Bool { isEnabled && !isDivider }
    var submenu: [ChromeMenuItem]? { if case .submenu(let items) = kind { items } else { nil } }

    static func action(_ title: String, systemImage: String? = nil, detail: String? = nil, checked: Bool = false,
                       enabled: Bool = true, indent: Int = 0, _ run: @escaping () -> Void) -> ChromeMenuItem {
        ChromeMenuItem(title: title, systemImage: systemImage, detail: detail, isChecked: checked,
                       isEnabled: enabled, indent: indent, kind: .action(run))
    }

    static func submenu(_ title: String, systemImage: String? = nil, detail: String? = nil, enabled: Bool = true,
                        _ items: [ChromeMenuItem]) -> ChromeMenuItem {
        ChromeMenuItem(title: title, systemImage: systemImage, detail: detail, isEnabled: enabled && !items.isEmpty, kind: .submenu(items))
    }

    static var divider: ChromeMenuItem { ChromeMenuItem(kind: .divider) }
}

enum ChromeMenuMetrics {
    static let rowHeight: CGFloat = 28
    static let dividerHeight: CGFloat = 9
    static let inset: CGFloat = 5
    static let minWidth: CGFloat = 196
    static let maxWidth: CGFloat = 320

    /// Where row `index` starts, from the panel's top.
    static func top(of index: Int, in items: [ChromeMenuItem]) -> CGFloat {
        inset + items.prefix(index).reduce(0) { $0 + ($1.isDivider ? dividerHeight : rowHeight) }
    }
}

/// The menu and its open submenus, side by side. The pointer and the keys
/// both move the highlight: ↑↓ along a menu, → into a submenu, ← back out,
/// Return to choose, Escape to close.
struct ChromeMenuView: View {
    let menu: ChromeMenu
    let palette: EditorPalette
    /// The window's room: a longer menu scrolls, and a submenu stays inside it.
    var maxHeight: CGFloat = .infinity
    let dismiss: () -> Void

    /// For each open level, the highlighted row.
    @ViewState private var highlights: [Int?] = [nil]
    /// For each open submenu, the row it opened from.
    @ViewState private var opened: [Int] = []
    @ViewState private var pendingOpen: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var levels: [[ChromeMenuItem]] {
        var levels = [menu.items]
        for index in opened {
            guard let items = levels.last?[index].submenu else { break }
            levels.append(items)
        }
        return levels
    }

    var body: some View {
        let levels = levels
        HStack(alignment: .top, spacing: -2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { level, items in
                panel(items, level: level)
                    .padding(.top, level == 0 ? 0 : min(offset(ofLevel: level, in: levels), max(0, maxHeight - height(of: items))))
                    .transition(ChromeMotion.reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -6)))
                    .zIndex(Double(level))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.rightArrow) { openHighlighted(); return .handled }
        .onKeyPress(.leftArrow) { closeLevel(); return .handled }
        .onKeyPress(.return) { activateHighlighted(); return .handled }
        .onKeyPress(.space) { activateHighlighted(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    /// A submenu lines its first row up with the row it opened from.
    private func offset(ofLevel level: Int, in levels: [[ChromeMenuItem]]) -> CGFloat {
        (0..<level).reduce(0) { total, parent in
            total + ChromeMenuMetrics.top(of: opened[parent], in: levels[parent]) - ChromeMenuMetrics.inset
        }
    }

    /// A menu's height on screen: all its rows, or the window's room.
    private func height(of items: [ChromeMenuItem]) -> CGFloat {
        min(ChromeMenuMetrics.top(of: items.count, in: items) + ChromeMenuMetrics.inset, maxHeight)
    }

    @ViewBuilder
    private func panel(_ items: [ChromeMenuItem], level: Int) -> some View {
        let fullHeight = ChromeMenuMetrics.top(of: items.count, in: items) + ChromeMenuMetrics.inset
        if fullHeight > maxHeight {
            ScrollView(.vertical) { rows(items, level: level) }
                .scrollIndicators(.hidden)
                .frame(height: maxHeight)
                .fixedSize(horizontal: true, vertical: false)
                .chromeSurface(palette, cornerRadius: 10)
        } else {
            rows(items, level: level)
                .chromeSurface(palette, cornerRadius: 10)
        }
    }

    private func rows(_ items: [ChromeMenuItem], level: Int) -> some View {
        let showsLeading = items.contains { $0.isChecked || $0.systemImage != nil }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.isDivider {
                    Rectangle()
                        .fill(Color(nsColor: palette.rule))
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                } else {
                    row(item, index: index, level: level, showsLeading: showsLeading)
                }
            }
        }
        .padding(ChromeMenuMetrics.inset)
        .frame(minWidth: ChromeMenuMetrics.minWidth, maxWidth: ChromeMenuMetrics.maxWidth, alignment: .leading)
        .fixedSize()
    }

    private func row(_ item: ChromeMenuItem, index: Int, level: Int, showsLeading: Bool) -> some View {
        let isHighlighted = highlights.indices.contains(level) && highlights[level] == index
        let isOpen = opened.indices.contains(level) && opened[level] == index
        let foreground = Color(nsColor: palette.text)
        return HStack(spacing: 8) {
            if showsLeading {
                Group {
                    if item.isChecked {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    } else if let image = item.systemImage {
                        Image(systemName: image).font(.system(size: 12))
                    }
                }
                .frame(width: 16)
                .foregroundStyle(item.isChecked ? foreground : Color(nsColor: palette.quote))
            }
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(foreground)
                .lineLimit(1)
            Spacer(minLength: 16)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: palette.syntax))
                    .lineLimit(1)
            }
            if item.submenu != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: palette.syntax))
            }
        }
        .padding(.leading, 8 + CGFloat(item.indent) * 14)
        .padding(.trailing, 8)
        .frame(height: ChromeMenuMetrics.rowHeight)
        .background {
            if (isHighlighted || isOpen) && item.isEnabled {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: palette.sidebarSelection))
            }
        }
        .opacity(item.isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside, item.isEnabled else { return }
            highlight(index, level: level)
        }
        .onTapGesture {
            guard item.isEnabled else { return }
            highlight(index, level: level)
            activate(item, index: index, level: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.detail ?? "")
        .accessibilityAddTraits(item.isChecked ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Highlight and keys

    private func highlight(_ index: Int, level: Int) {
        pendingOpen?.cancel()
        while highlights.count <= level { highlights.append(nil) }
        highlights[level] = index
        let item = levels[level][index]
        // Moving onto another row of this menu closes what opened deeper.
        if opened.count > level, opened[level] != index {
            withAnimation(ChromeMotion.move) {
                opened.removeSubrange(level...)
                if highlights.count > level + 1 { highlights.removeSubrange((level + 1)...) }
            }
        }
        // Resting on a submenu row opens it, after a beat (a pointer passing by doesn't).
        if item.submenu != nil, opened.count == level {
            pendingOpen = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, opened.count == level, highlights[level] == index else { return }
                open(index, level: level, highlightFirst: false)
            }
        }
    }

    private func open(_ index: Int, level: Int, highlightFirst: Bool) {
        withAnimation(ChromeMotion.move) {
            opened = Array(opened.prefix(level)) + [index]
            highlights = Array(highlights.prefix(level + 1))
            let first = levels[level + 1].firstIndex(where: \.isSelectable)
            highlights.append(highlightFirst ? first : nil)
        }
    }

    private func move(_ step: Int) {
        let level = max(0, min(highlights.count, levels.count) - 1)
        let items = levels[level]
        let selectable = items.indices.filter { items[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        let current = highlights[level].flatMap { selectable.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = selectable[(current + step + selectable.count) % selectable.count]
        } else {
            next = step > 0 ? selectable[0] : selectable[selectable.count - 1]
        }
        pendingOpen?.cancel()
        highlights[level] = next
        if opened.count > level {
            withAnimation(ChromeMotion.move) { opened.removeSubrange(level...) }
        }
    }

    private func openHighlighted() {
        let level = highlights.count - 1
        guard let index = highlights[level], levels[level][index].submenu != nil else { return }
        open(index, level: level, highlightFirst: true)
    }

    private func closeLevel() {
        guard !opened.isEmpty else { return }
        withAnimation(ChromeMotion.move) {
            opened.removeLast()
            highlights.removeLast()
        }
    }

    private func activateHighlighted() {
        let level = highlights.count - 1
        guard level >= 0, let index = highlights[level] else { return }
        activate(levels[level][index], index: index, level: level)
    }

    private func activate(_ item: ChromeMenuItem, index: Int, level: Int) {
        switch item.kind {
        case .action(let run):
            dismiss()
            // After the menu is gone: the action may present something of its own.
            DispatchQueue.main.async { run() }
        case .submenu:
            open(index, level: level, highlightFirst: true)
        case .divider:
            break
        }
    }
}
