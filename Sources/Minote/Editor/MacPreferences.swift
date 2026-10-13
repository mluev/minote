import AppKit
import MinoteEditor

/// View ▸ Appearance and the text settings panel: how the page looks. Sepia
/// is a light page on warm paper. Saved under the Appearance key, where
/// System, Light and Dark keep the values they had before Sepia existed.
enum PageTheme: String, CaseIterable, Identifiable {
    case system, light, sepia, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light, .sepia: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var paper: EditorPaper { self == .sepia ? .sepia : .standard }

    var palette: EditorPalette { .of(paper) }

    /// The saved theme, for AppKit code outside SwiftUI's `@AppStorage`.
    static var saved: PageTheme {
        UserDefaults.standard.string(forKey: PreferenceKey.appearance).flatMap(PageTheme.init(rawValue:)) ?? .system
    }

    /// Saves a theme and switches the app's appearance. Pages follow the
    /// saved value through `@AppStorage`.
    static func select(_ theme: PageTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: PreferenceKey.appearance)
        applySaved()
    }

    /// Gives the app the saved theme's appearance (at launch, after a change).
    static func applySaved() {
        NSApp.appearance = saved.nsAppearance
    }
}
