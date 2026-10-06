import MinoteKit
import SwiftUI

/// File ▸ Rename… sheet.
struct RenameSheet: View {
    let note: Note
    let library: Library
    let dismiss: () -> Void
    @ViewState private var name: String

    init(note: Note, library: Library, dismiss: @escaping () -> Void) {
        self.note = note
        self.library = library
        self.dismiss = dismiss
        _name = ViewState(initialValue: note.fileStem ?? note.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Note")
                .font(.headline)
            Text("The file keeps this name instead of following its first line.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isBlank)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func commit() {
        guard !name.isBlank else { return }
        let id = note.id, newName = name
        dismiss()
        Task { await library.rename(id, to: newName) }
    }
}
