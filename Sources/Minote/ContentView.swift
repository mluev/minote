import AppKit
import MinoteKit
import SwiftUI
import MinoteEditor

/// The single library window: sidebar on the left, the page on the right.
struct ContentView: View {
    @Bindable var library: Library
    @Bindable var windowState: WindowState

    @AppStorage(PreferenceKey.fontFamily) private var fontFamily = EditorFontFamily.plexMono
    @AppStorage(PreferenceKey.fontSize) private var fontSize = EditorTheme.defaultFontSize
    @AppStorage(PreferenceKey.focusEnabled) private var focusEnabled = false
    @AppStorage(PreferenceKey.focusUnit) private var focusUnit = FocusMode.sentence
    @AppStorage(PreferenceKey.typewriter) private var typewriter = false
    @AppStorage(PreferenceKey.syntaxHighlight) private var syntaxHighlight = false
    @AppStorage(PreferenceKey.showCounter) private var showCounter = false
    @AppStorage(PreferenceKey.showsSyntax) private var showsSyntax = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var fader = ChromeFader()

    var body: some View {
        NavigationSplitView(columnVisibility: $windowState.columnVisibility) {
            SidebarView(library: library, windowState: windowState)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            GeometryReader { proxy in
                EditorView(
                    library: library,
                    windowState: windowState,
                    configuration: configuration,
                    topInset: proxy.safeAreaInsets.top,
                    viewportHeight: proxy.size.height + proxy.safeAreaInsets.top,
                    onUserEdit: { fader.userDidType() }
                )
                .ignoresSafeArea()
            }
            .background(Color(nsColor: EditorTheme.background))
            .overlay(alignment: .bottomTrailing) {
                if showCounter {
                    WordCounter(windowState: windowState)
                        .padding(8)
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .navigationTitle(windowTitle)
        .background(WindowAccessor { window in configure(window) })
        .onChange(of: windowState.columnVisibility, initial: true) { _, visibility in
            fader.isEnabled = visibility == .detailOnly
        }
        .onChange(of: showCounter, initial: true) { _, shows in
            windowState.showsCounter = shows
            if shows { windowState.editor?.refreshStatistics() }
        }
        .onChange(of: reduceMotion, initial: true) { _, reduce in
            fader.animates = !reduce
        }
        .sheet(item: $windowState.renaming) { note in
            RenameSheet(note: note, library: library) { windowState.renaming = nil }
        }
        .alert(
            library.presentedError?.title ?? "",
            isPresented: Binding(
                get: { library.presentedError != nil },
                set: { if !$0 { library.presentedError = nil } }
            ),
            presenting: library.presentedError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }

    private var configuration: EditorConfiguration {
        EditorConfiguration(
            family: fontFamily,
            size: fontSize,
            focus: focusEnabled ? focusUnit : .off,
            typewriter: typewriter,
            partsOfSpeech: syntaxHighlight,
            showsSyntax: showsSyntax,
            preview: windowState.isPreviewing
        )
    }

    /// Shown in the Window menu and Mission Control; hidden from the toolbar.
    private var windowTitle: String {
        guard let note = library.selectedNote else { return "Minote" }
        return note.title.isEmpty ? "New Note" : note.title
    }

    private func configure(_ window: NSWindow) {
        window.backgroundColor = EditorTheme.background
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        fader.attach(to: window)
    }
}
