import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// Minote ▸ Settings…: the password, what's locked, Touch ID and when to lock
/// again. Everything else stays in the menus.
struct SecuritySettingsView: View {
    let workspace: Workspace

    @ViewState private var request: PasswordRequest?
    @ViewState private var confirmsWholeLibrary = false
    @ViewState private var confirmsSelectedNotes = false
    @ViewState private var confirmsNewRecoveryKey = false
    @ViewState private var shownCode: ShownRecoveryCode?

    private struct ShownRecoveryCode: Identifiable {
        let id = UUID()
        let code: RecoveryCode
    }

    private var lock: LockController { workspace.lock }
    private var library: Library { workspace.library }

    var body: some View {
        Form {
            if !library.hasPassword && !library.canSetPassword {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading your library…").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Locked Notes")
                }
            } else if !library.hasPassword {
                Section {
                    Text("Locked notes are encrypted on disk, so other apps and tools on this Mac can't read them; their titles stay visible. You open them with a password or \(lock.biometricName).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Set Password…") { request = PasswordRequest(kind: .set) }
                        Button("Lock Whole Library…") { request = PasswordRequest(kind: .set, thenScope: .library) }
                    }
                } header: {
                    Text("Locked Notes")
                }
            } else {
                if !library.isUnlocked {
                    Section {
                        UnlockForm(lock: lock, palette: PageTheme.saved.palette)
                            .frame(maxWidth: .infinity)
                    } header: {
                        Text("Unlock to change what's locked")
                    }
                }
                Section {
                    Picker("Lock", selection: scopeSelection) {
                        Text("Selected Notes").tag(LockScope.notes)
                        Text("Whole Library").tag(LockScope.library)
                    }
                    .disabled(!library.isUnlocked)
                    // Locked, nobody changes how the notes lock without the password.
                    if lock.canUseBiometrics {
                        Toggle("Unlock with \(lock.biometricName)", isOn: Binding(
                            get: { lock.useBiometrics },
                            set: { lock.setUseBiometrics($0) }
                        ))
                        .disabled(!library.isUnlocked)
                    }
                    Picker("Lock Again", selection: Binding(get: { lock.lockAfter }, set: { lock.setLockAfter($0) })) {
                        ForEach(LockTimeout.allCases) { timeout in
                            Text(timeout.title).tag(timeout)
                        }
                    }
                    .disabled(!library.isUnlocked)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recovery Key")
                            Text(library.vault?.key.recovery == nil
                                ? "None yet: without one, a forgotten password means losing your locked notes."
                                : "Opens your locked notes if you forget the password.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("New Recovery Key…") {
                            if library.vault?.key.recovery == nil { makeRecoveryKey() } else { confirmsNewRecoveryKey = true }
                        }
                        .disabled(!library.isUnlocked || lock.isBusy)
                    }
                    HStack {
                        Button("Change Password…") { request = PasswordRequest(kind: .change) }
                        Button("Lock Now") { lock.lockNow() }
                            .disabled(!library.isUnlocked)
                        Spacer()
                        Button("Turn Off Password") {
                            Task { try? await lock.removePassword() }
                        }
                        .disabled(library.hasLockedNotes || library.lockScope == .library)
                        .help("Possible once no note is locked")
                    }
                } header: {
                    Text("Locked Notes")
                } footer: {
                    Text("Locked notes also lock when your Mac sleeps, its screen locks, or Minote quits.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .task { await workspace.loadLibrary().value }
        .sheet(item: $request) { request in
            PasswordSheet(request: request, lock: lock) { self.request = nil }
        }
        .sheet(item: $shownCode) { shown in
            RecoveryKeyView(code: shown.code) { shownCode = nil }
                .padding(20)
                .frame(width: 400)
        }
        .alert("Make a new recovery key?", isPresented: $confirmsNewRecoveryKey) {
            Button("New Recovery Key") { makeRecoveryKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recovery key you have now stops working.")
        }
        .alert("Lock every note?", isPresented: $confirmsWholeLibrary) {
            Button("Lock Every Note") { setScope(.library) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every note in your library is encrypted, and new notes start locked. Minote opens behind a lock screen.")
        }
        .confirmationDialog("Lock only the notes you choose?", isPresented: $confirmsSelectedNotes) {
            Button("Keep Notes Locked") { setScope(.notes) }
            Button("Remove Lock from All Notes") { setScope(.notes, removingLocks: true) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var scopeSelection: Binding<LockScope> {
        Binding(
            get: { library.lockScope },
            set: { scope in
                guard scope != library.lockScope else { return }
                if scope == .library { confirmsWholeLibrary = true } else { confirmsSelectedNotes = true }
            }
        )
    }

    private func makeRecoveryKey() {
        Task {
            do {
                shownCode = ShownRecoveryCode(code: try await lock.makeRecoveryCode())
            } catch {
                library.presentedError = LibraryError(title: "Couldn't make a recovery key", message: error.localizedDescription)
            }
        }
    }

    private func setScope(_ scope: LockScope, removingLocks: Bool = false) {
        Task {
            do {
                try await library.setScope(scope)
                if removingLocks { try await library.removeAllLocks() }
            } catch {
                library.presentedError = LibraryError(title: "Couldn't change what's locked", message: error.localizedDescription)
            }
        }
    }
}
