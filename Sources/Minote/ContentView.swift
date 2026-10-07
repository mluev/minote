import AppKit
import MinoteKit
import SwiftUI
import MinoteEditor

/// The single library window: sidebar on the left, the page on the right.
struct ContentView: View {
    @Bindable var library: Library
    @Bindable var windowState: WindowState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var fader = ChromeFader()

    var body: some View {
        NavigationSplitView(columnVisibility: $windowState.columnVisibility) {
            SidebarView(library: library, windowState: windowState)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            EditorPage(library: library, windowState: windowState, onUserEdit: { fader.userDidType() })
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .navigationTitle(windowTitle)
        .background(WindowAccessor { window in configure(window) })
        .onChange(of: windowState.columnVisibility, initial: true) { _, visibility in
            fader.isEnabled = visibility == .detailOnly
        }
        .onChange(of: reduceMotion, initial: true) { _, reduce in
            fader.animates = !reduce
        }
        .sheet(item: $windowState.renaming) { note in
            RenameSheet(note: note, library: library) { windowState.renaming = nil }
        }
        .libraryErrorAlert(library)
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
