import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// The sidebar's view options, all in sight at once: grouping as one
/// segmented control, the sort as a list with its direction beside it, what
/// rows show as toggles, and folding every folder. One click per change, and
/// every change shows in the list behind it straight away; a small reset
/// button puts the defaults back. ↑↓ move between the controls, ←→ change
/// the grouping, Return or Space choose. Under the pointer a row gets the
/// faintest plate; the keyboard's place a firmer one.
struct ViewOptionsPanel: View {
    @Bindable var library: Library
    @Bindable var state: WindowState
    let workspace: Workspace
    @Bindable var preferences: SidebarPreferences
    let palette: EditorPalette

    @ViewState private var focus: Control?
    @ViewState private var hovered: Control?
    @FocusState private var isFocused: Bool
    @Namespace private var grouping

    private enum Control: Hashable {
        case group
        case sort(NoteSort)
        case reverse
        case show(Show)
        case foldAll, reset
    }

    private enum Show: CaseIterable {
        case dates, counts, lockedOnly

        var title: String {
            switch self {
            case .dates: "Dates"
            case .counts: "Note Counts"
            case .lockedOnly: "Locked"
            }
        }

        var systemImage: String {
            switch self {
            case .dates: "calendar"
            case .counts: "number"
            case .lockedOnly: "lock"
            }
        }
    }

    private var order: MinoteKit.SortOrder { library.sortOrder(of: state.scope) }
    private var foldersHere: [FolderPath] { library.folders.filter { state.scope.isAncestor(of: $0) } }
    private var allFolded: Bool { !foldersHere.isEmpty && foldersHere.allSatisfy(preferences.collapsed.contains) }
    private var isStandard: Bool { preferences.view == .standard && library.folderSettings[state.scope]?.ownOrder == nil }

    private var controls: [Control] {
        var controls: [Control] = isStandard ? [] : [.reset]
        controls.append(.group)
        controls += NoteSort.allCases.map(Control.sort)
        controls.append(.reverse)
        controls += Show.allCases.map(Control.show)
        if preferences.view.groupBy == .folder && !foldersHere.isEmpty { controls.append(.foldAll) }
        return controls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                header("Group by")
                Spacer()
                resetButton
            }
            groupControl
                .padding(.bottom, 10)

            HStack {
                header("Sort by", detail: state.scope.name.map { "in “\($0)”" })
                Spacer()
                reverseButton
            }
            VStack(spacing: 1) {
                ForEach(NoteSort.allCases, id: \.self) { sort in
                    sortRow(sort)
                }
            }
            .padding(.bottom, 10)

            header("Show")
            HStack(spacing: 6) {
                ForEach(Show.allCases, id: \.self) { chip($0) }
            }
            .padding(.bottom, 8)

            if controls.contains(.foldAll) {
                Rectangle()
                    .fill(Color(nsColor: palette.rule))
                    .frame(height: 1)
                    .padding(.vertical, 4)
                    .padding(.horizontal, -10)
                actionRow(.foldAll, allFolded ? "Expand All" : "Collapse All",
                          systemImage: allFolded ? "chevron.down.2" : "chevron.up.2")
            }
        }
        .padding(10)
        .frame(width: 284)
        .chromeSurface(palette)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { shiftGrouping(-1) }
        .onKeyPress(.rightArrow) { shiftGrouping(1) }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space) { activate(); return .handled }
        .onKeyPress(.escape) { state.dismissOverlay(); return .handled }
    }

    // MARK: Parts

    private func header(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: palette.syntax))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: palette.syntax).opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var groupControl: some View {
        HStack(spacing: 2) {
            ForEach(LibraryView.Grouping.allCases, id: \.self) { grouping in
                let isOn = preferences.view.groupBy == grouping
                Text(grouping.displayName)
                    .font(.system(size: 12.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(Color(nsColor: isOn ? palette.text : palette.quote))
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: palette.background))
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "plate", in: self.grouping)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { set(grouping) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Group by \(grouping.displayName)")
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: palette.sidebarSelection))
        }
        .overlay {
            if focus == .group {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: palette.text).opacity(0.35), lineWidth: 1.5)
            }
        }
        .animation(ChromeMotion.move, value: preferences.view.groupBy)
    }

    /// Back to the standard view (and the folder's own sort cleared): only
    /// there when something differs.
    private var resetButton: some View {
        Button { perform(.reset) } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(ChromeButtonStyle(palette: palette, cornerRadius: 5, isActive: focus == .reset, size: 22))
        .opacity(isStandard ? 0 : 1)
        .disabled(isStandard)
        .help("Reset to Defaults")
        .accessibilityLabel("Reset to Defaults")
        .padding(.top, -6)
    }

    private func sortRow(_ sort: NoteSort) -> some View {
        let isOn = order.sort == sort
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(isOn ? 1 : 0)
                .frame(width: 14)
            Text(sort.displayName)
                .font(.system(size: 13))
            Spacer()
            if sort == .manual && isOn {
                Text("Drag to arrange")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: palette.syntax))
            }
        }
        .foregroundStyle(Color(nsColor: palette.text))
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(plate(focus == .sort(sort), hovered: hovered == .sort(sort)))
        .contentShape(Rectangle())
        .onHover { hover(.sort(sort), $0) }
        .onTapGesture { set(sort) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sort by \(sort.displayName)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var reverseButton: some View {
        let isOn = order.reversed
        let enabled = order.sort != .manual
        return HStack(spacing: 4) {
            Image(systemName: isOn ? "arrow.up" : "arrow.down")
                .font(.system(size: 10.5, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(directionTitle)
                .font(.system(size: 11.5))
                .contentTransition(.opacity)
        }
        .foregroundStyle(Color(nsColor: isOn ? palette.text : palette.quote))
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(plate(focus == .reverse || isOn, strength: isOn ? 1 : 0.7, hovered: hovered == .reverse && enabled))
        .opacity(enabled ? 1 : 0.35)
        .contentShape(Rectangle())
        .onHover { hover(.reverse, $0) }
        .onTapGesture { if enabled { toggleReverse() } }
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reverse Order")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    /// What the order's direction means for the sort chosen.
    private var directionTitle: String {
        switch (order.sort, order.reversed) {
        case (.title, false): "A–Z"
        case (.title, true): "Z–A"
        case (.manual, _): "Yours"
        case (_, false): "Newest"
        case (_, true): "Oldest"
        }
    }

    private func chip(_ show: Show) -> some View {
        let isOn = value(of: show)
        return HStack(spacing: 4) {
            Image(systemName: show.systemImage)
                .font(.system(size: 10.5, weight: .medium))
            Text(show.title)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .foregroundStyle(Color(nsColor: isOn ? palette.background : palette.quote))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            Capsule()
                .fill(Color(nsColor: isOn ? palette.text : palette.sidebarSelection))
                .opacity(hovered == .show(show) ? 0.85 : 1)
        }
        .overlay {
            if focus == .show(show) {
                Capsule().strokeBorder(Color(nsColor: palette.text).opacity(isOn ? 0 : 0.35), lineWidth: 1.5)
            }
        }
        .contentShape(Capsule())
        .onHover { hover(.show(show), $0) }
        .onTapGesture { toggle(show) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show \(show.title)")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    private func actionRow(_ control: Control, _ title: String, systemImage: String, detail: String? = nil,
                           enabled: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: palette.quote))
                .frame(width: 14)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: palette.text))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: palette.syntax))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(plate(focus == control && enabled, hovered: hovered == control && enabled))
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { hover(control, $0) }
        .onTapGesture { if enabled { perform(control) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private func plate(_ isOn: Bool, strength: Double = 1, hovered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOn ? Color(nsColor: palette.sidebarSelection).opacity(strength) : hovered ? palette.hoverFill : .clear)
    }

    private func hover(_ control: Control, _ inside: Bool) {
        if inside { hovered = control } else if hovered == control { hovered = nil }
    }

    // MARK: Changing things

    private func value(of show: Show) -> Bool {
        switch show {
        case .dates: preferences.view.showsDates
        case .counts: preferences.view.showsCounts
        case .lockedOnly: preferences.view.lockedOnly
        }
    }

    // The list behind changes at once; only the grouping's plate slides.

    private func toggle(_ show: Show) {
        switch show {
        case .dates: preferences.view.showsDates.toggle()
        case .counts: preferences.view.showsCounts.toggle()
        case .lockedOnly: preferences.view.lockedOnly.toggle()
        }
    }

    private func set(_ grouping: LibraryView.Grouping) {
        preferences.view.groupBy = grouping
    }

    private func set(_ sort: NoteSort) {
        let reversed = sort == .manual ? false : order.reversed
        library.setSort(SortOrder(sort, reversed: reversed), for: state.scope)
    }

    private func toggleReverse() {
        library.setSort(SortOrder(order.sort, reversed: !order.reversed), for: state.scope)
    }

    private func perform(_ control: Control) {
        switch control {
        case .group: break
        case .sort(let sort): set(sort)
        case .reverse: if order.sort != .manual { toggleReverse() }
        case .show(let show): toggle(show)
        case .foldAll:
            if allFolded { preferences.collapsed.subtract(foldersHere) } else { preferences.collapsed.formUnion(foldersHere) }
        case .reset:
            preferences.view = .standard
            library.setSort(nil, for: state.scope)
            if focus == .reset { focus = .group }
        }
    }

    private func step(_ offset: Int) {
        let controls = controls
        guard let current = focus.flatMap(controls.firstIndex(of:)) else {
            focus = offset > 0 ? controls.first : controls.last
            return
        }
        focus = controls[(current + offset + controls.count) % controls.count]
    }

    private func shiftGrouping(_ offset: Int) -> KeyPress.Result {
        guard focus == .group else { return .ignored }
        let all = LibraryView.Grouping.allCases
        guard let index = all.firstIndex(of: preferences.view.groupBy) else { return .ignored }
        set(all[(index + offset + all.count) % all.count])
        return .handled
    }

    private func activate() {
        guard let focus else { return }
        if focus == .group {
            _ = shiftGrouping(1)
        } else {
            perform(focus)
        }
    }
}
