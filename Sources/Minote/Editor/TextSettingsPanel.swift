import AppKit
import MinoteEditor
import SwiftUI

/// The "Aa" button in the titlebar: the View menu's reading settings (size,
/// theme, font) within reach of the page, for writing and Preview alike.
struct TextSettingsButton: View {
    @Bindable var windowState: WindowState

    var body: some View {
        Button {
            windowState.isShowingTextSettings.toggle()
        } label: {
            Label("Text Settings", systemImage: "textformat")
        }
        .help("Font, Size and Theme")
        .popover(isPresented: $windowState.isShowingTextSettings, arrowEdge: .bottom) {
            TextSettingsPanel()
        }
    }
}

/// Size, theme and font, each applied at once to every page. The same
/// preferences as the View menu, so the two always agree.
struct TextSettingsPanel: View {
    @AppStorage(PreferenceKey.fontFamily) private var fontFamily = EditorFontFamily.plexMono
    @AppStorage(PreferenceKey.fontSize) private var fontSize = EditorTheme.defaultFontSize
    @AppStorage(PreferenceKey.appearance) private var theme = PageTheme.system

    var body: some View {
        VStack(spacing: 14) {
            sizeStepper
            themePicker
            Divider()
            fontList
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: Size

    private var sizeStepper: some View {
        let range = EditorTheme.fontSizeRange
        return HStack(spacing: 0) {
            Button {
                fontSize = max(fontSize - 1, range.lowerBound)
            } label: {
                Text("A").font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(PlateButtonStyle())
            .disabled(fontSize <= range.lowerBound)
            .accessibilityLabel("Smaller")

            Text("\(fontSize.formatted()) pt")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64)
                .accessibilityLabel("Text size \(fontSize.formatted()) points")

            Button {
                fontSize = min(fontSize + 1, range.upperBound)
            } label: {
                Text("A").font(.system(size: 20)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(PlateButtonStyle())
            .disabled(fontSize >= range.upperBound)
            .accessibilityLabel("Bigger")
        }
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary))
    }

    // MARK: Theme

    private var themePicker: some View {
        HStack(spacing: 0) {
            ForEach(PageTheme.allCases) { option in
                ThemeSwatch(theme: option, family: fontFamily, isSelected: option == theme) {
                    PageTheme.select(option)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Font

    private var fontList: some View {
        VStack(spacing: 2) {
            ForEach(EditorFontFamily.allCases) { family in
                Button {
                    fontFamily = family
                } label: {
                    HStack {
                        Text(family.displayName)
                            .font(Self.sampleFonts[family])
                            .foregroundStyle(.primary)
                        Spacer()
                        if family == fontFamily {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(nsColor: EditorTheme.caret))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
                .buttonStyle(PlateButtonStyle())
                .accessibilityAddTraits(family == fontFamily ? .isSelected : [])
            }
        }
    }

    /// Each family's name is set in that family.
    private static let sampleFonts: [EditorFontFamily: Font] = Dictionary(
        uniqueKeysWithValues: EditorFontFamily.allCases.map { ($0, Font(EditorFonts(family: $0, size: 14).regular as CTFont)) }
    )
}

/// A theme as a little page: its paper, and "Aa" in its ink and the current
/// font. System shows its light and dark halves.
private struct ThemeSwatch: View {
    let theme: PageTheme
    let family: EditorFontFamily
    let isSelected: Bool
    let action: () -> Void

    private static let diameter: CGFloat = 38

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                page
                    .frame(width: Self.diameter, height: Self.diameter)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .padding(3)
                    .overlay(Circle().strokeBorder(isSelected ? Color(nsColor: EditorTheme.caret) : .clear, lineWidth: 2))
                Text(theme.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var page: some View {
        switch theme {
        case .system:
            ZStack {
                sample(.standard, in: .aqua)
                sample(.standard, in: .darkAqua)
                    .mask(alignment: .trailing) { Rectangle().frame(width: Self.diameter / 2) }
            }
        case .light: sample(.standard, in: .aqua)
        case .sepia: sample(.sepia, in: .aqua)
        case .dark: sample(.standard, in: .darkAqua)
        }
    }

    private func sample(_ palette: EditorPalette, in appearance: NSAppearance.Name) -> some View {
        Rectangle()
            .fill(Self.resolve(palette.background, in: appearance))
            .overlay {
                Text("Aa")
                    .font(Font(EditorFonts(family: family, size: 14).regular as CTFont))
                    .foregroundStyle(Self.resolve(palette.text, in: appearance))
            }
    }

    /// A page color as it looks in a given appearance, whatever the app's is.
    private static func resolve(_ color: NSColor, in appearance: NSAppearance.Name) -> Color {
        var resolved = color.cgColor
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return Color(cgColor: resolved)
    }
}

/// A borderless button that shows a soft plate under the pointer and when pressed.
private struct PlateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Plate(configuration: configuration)
    }

    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.12 : isHovered && isEnabled ? 0.06 : 0))
                }
                .onHover { isHovered = $0 }
        }
    }
}
