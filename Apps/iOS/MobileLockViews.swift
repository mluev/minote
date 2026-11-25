import MinoteEditor
import MinoteKit
import SwiftUI
import UniformTypeIdentifiers

/// What the password sheet is for.
struct MobilePasswordRequest: Identifiable {
    enum Kind {
        case set
        case change
        case unlock
        /// A forgotten password: a new one, with Face ID or the recovery key.
        case reset
    }

    let id = UUID()
    let kind: Kind
    /// A note to lock once there's a password and the notes are unlocked.
    var thenLock: Note.ID?
}

/// A password field with Unlock, and Face ID / Touch ID below it. After a
/// wrong password, "Forgot Password?"; after a few, the hint.
struct MobileUnlockForm: View {
    let lock: LockController
    var prompt = "Password"
    var offersBiometrics = true

    @ViewState private var password = ""
    @ViewState private var failures = 0
    @ViewState private var resetsPassword = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                SecureField(prompt, text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .submitLabel(.go)
                    .onSubmit(unlock)
                    .accessibilityIdentifier("unlockPassword")
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || lock.isBusy)
            }
            .frame(maxWidth: 340)
            if offersBiometrics && lock.isBiometricReady {
                Button {
                    Task { await lock.unlockWithBiometrics() }
                } label: {
                    Label("Unlock with \(lock.biometricName)", systemImage: lock.biometricName == "Face ID" ? "faceid" : "touchid")
                }
                .disabled(lock.isBusy)
            }
            if failures > 0 {
                Text(wrongPassword)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("Forgot Password?") { resetsPassword = true }
                    .font(.callout)
            }
        }
        .sheet(isPresented: $resetsPassword) {
            MobilePasswordSheet(request: MobilePasswordRequest(kind: .reset), lock: lock) { resetsPassword = false }
        }
    }

    private var wrongPassword: String {
        guard failures >= PasswordPolicy.hintAfterFailures, let hint = lock.library.vault?.key.hint else { return "Wrong password." }
        return "Wrong password. Hint: \(hint)"
    }

    private func unlock() {
        guard !password.isEmpty, !lock.isBusy else { return }
        let typed = password
        Task {
            do {
                try await lock.unlock(password: typed)
                failures = 0
            } catch {
                failures += 1
            }
            password = ""
        }
    }
}

/// Over a sealed note's page: its title, and ways to unlock.
struct LockedNoteView: View {
    let note: Note
    let lock: LockController

    private var needsEarlierPassword: Bool { lock.library.isUnlocked }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(note.displayTitle)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(needsEarlierPassword ? "This note was locked with an earlier password." : "This note is locked.")
                .font(.callout)
                .foregroundStyle(.secondary)
            MobileUnlockForm(lock: lock, prompt: needsEarlierPassword ? "Earlier password" : "Password",
                             offersBiometrics: !needsEarlierPassword)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: EditorPalette.standard.background))
        .task(id: note.id) {
            if !needsEarlierPassword { await lock.unlockWithBiometrics() }
        }
    }
}

/// Whole library mode while locked.
struct MobileLockScreen: View {
    let lock: LockController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Minote Is Locked")
                .font(.title2.weight(.semibold))
            Text("Enter your password to see your notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            MobileUnlockForm(lock: lock)
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: EditorPalette.standard.background))
        .task { await lock.unlockWithBiometrics() }
    }
}

/// Covers the screen while the app isn't active, so the app switcher's
/// snapshot never shows an unlocked note.
struct PrivacyCover: View {
    var body: some View {
        Color(uiColor: EditorPalette.standard.background)
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            .ignoresSafeArea()
    }
}

/// Setting the password, changing it, resetting a forgotten one, or
/// unlocking for a command. Setting or changing it ends on the new recovery
/// key, which stays on screen until the user says it's kept.
struct MobilePasswordSheet: View {
    let request: MobilePasswordRequest
    let lock: LockController
    let dismiss: () -> Void

    /// What stands in for the current password when changing it.
    private enum Proof: Hashable {
        case password, biometrics, recoveryKey
    }

    @ViewState private var kind: MobilePasswordRequest.Kind
    @ViewState private var proof: Proof
    @ViewState private var current = ""
    @ViewState private var recoveryKey = ""
    @ViewState private var password = ""
    @ViewState private var confirmation = ""
    @ViewState private var hint = ""
    @ViewState private var useBiometrics = true
    @ViewState private var error: String?
    @ViewState private var failures = 0
    @ViewState private var recoveryCode: RecoveryCode?

    init(request: MobilePasswordRequest, lock: LockController, dismiss: @escaping () -> Void) {
        self.request = request
        self.lock = lock
        self.dismiss = dismiss
        _kind = ViewState(initialValue: request.kind)
        _proof = ViewState(initialValue: request.kind == .reset ? (lock.isBiometricReady ? .biometrics : .recoveryKey) : .password)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let recoveryCode {
                    MobileRecoveryKeyView(code: recoveryCode, done: dismiss)
                } else {
                    form
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(recoveryCode != nil)
    }

    private var form: some View {
        Form {
            if kind == .change || kind == .reset {
                Section {
                    if proofs.count > 1 {
                        Picker("Confirm With", selection: $proof) {
                            ForEach(proofs, id: \.self) { Text(label(of: $0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    switch proof {
                    case .password:
                        SecureField("Current Password", text: $current)
                    case .biometrics:
                        Text("\(lock.biometricName) confirms it's you when you tap Done.")
                            .foregroundStyle(.secondary)
                    case .recoveryKey:
                        TextField("Recovery Key", text: $recoveryKey, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"))
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    if kind == .reset { Text(resetExplanation) }
                }
            }
            Section {
                if kind == .unlock {
                    SecureField("Password", text: $current)
                }
                if kind != .unlock {
                    SecureField("New Password", text: $password)
                    SecureField("Verify", text: $confirmation)
                    TextField("Hint (Optional)", text: $hint)
                }
            } footer: {
                if kind != .unlock {
                    Text("At least \(PasswordPolicy.minimumLength) characters: a few unrelated words are strong and easy to remember. Locked notes are encrypted so other apps can't read them; their titles stay visible. The hint isn't encrypted, so it mustn't give the password away.")
                }
            }
            if kind == .set && lock.canUseBiometrics {
                Toggle("Unlock with \(lock.biometricName)", isOn: $useBiometrics)
            }
            if let error {
                Text(error).foregroundStyle(.red)
            } else if let issue {
                Text(issue).foregroundStyle(.secondary)
            }
            if kind == .unlock {
                Button("Forgot Password?") {
                    error = nil
                    proof = lock.isBiometricReady ? .biometrics : .recoveryKey
                    kind = .reset
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: dismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
                if lock.isBusy {
                    ProgressView()
                } else {
                    Button("Done", action: commit).disabled(!canCommit)
                }
            }
        }
    }

    private var title: String {
        switch kind {
        case .set: "Set Password"
        case .change: "Change Password"
        case .unlock: "Unlock"
        case .reset: "Forgot Password"
        }
    }

    private var resetExplanation: String {
        lock.isBiometricReady
            ? "Set a new password with \(lock.biometricName) or the recovery key you saved."
            : "Set a new password with the recovery key you saved when you made the old one."
    }

    private var proofs: [Proof] {
        var proofs: [Proof] = kind == .change ? [.password] : []
        if lock.isBiometricReady { proofs.append(.biometrics) }
        proofs.append(.recoveryKey)
        return proofs
    }

    private func label(of proof: Proof) -> String {
        switch proof {
        case .password: "Password"
        case .biometrics: lock.biometricName
        case .recoveryKey: "Recovery Key"
        }
    }

    private var issue: String? {
        guard kind != .unlock else { return nil }
        if !password.isEmpty && password.count < PasswordPolicy.minimumLength {
            return "At least \(PasswordPolicy.minimumLength) characters (\(password.count) so far)."
        }
        if !confirmation.isEmpty && confirmation != password { return "The passwords don't match." }
        if PasswordPolicy.problem(password: password, hint: hint) == .hintRevealsPassword {
            return LockError.hintRevealsPassword.errorDescription
        }
        return nil
    }

    private var canCommit: Bool {
        let newPasswordWillDo = password == confirmation && PasswordPolicy.problem(password: password, hint: hint) == nil
        switch kind {
        case .unlock: return !current.isEmpty
        case .set: return newPasswordWillDo
        case .change, .reset:
            switch proof {
            case .password: return newPasswordWillDo && !current.isEmpty
            case .biometrics: return newPasswordWillDo
            case .recoveryKey: return newPasswordWillDo && RecoveryCode(recoveryKey) != nil
            }
        }
    }

    private var wrongPassword: String {
        guard failures >= PasswordPolicy.hintAfterFailures, let hint = lock.library.vault?.key.hint else { return "Wrong password." }
        return "Wrong password. Hint: \(hint)"
    }

    private func commit() {
        guard canCommit, !lock.isBusy else { return }
        error = nil
        Task {
            do {
                switch kind {
                case .set:
                    let code = try await lock.setPassword(password, hint: hint, useBiometrics: useBiometrics)
                    // The key shows whatever happens next: the password is set.
                    recoveryCode = code
                    if let id = request.thenLock { await lockNote(id) }
                case .change, .reset:
                    recoveryCode = try await replacePassword()
                case .unlock:
                    try await lock.unlock(password: current)
                    if let id = request.thenLock { await lockNote(id) }
                    dismiss()
                }
            } catch LockError.wrongPassword {
                current = ""
                failures += 1
                error = wrongPassword
            } catch let biometric as BiometricError {
                switch biometric {
                case .cancelled: break
                case .fallback: proof = kind == .change ? .password : .recoveryKey
                default: error = "\(lock.biometricName) didn't confirm it. Use your password or recovery key instead."
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func replacePassword() async throws -> RecoveryCode {
        switch proof {
        case .password:
            return try await lock.changePassword(from: current, to: password, hint: hint)
        case .biometrics:
            return try await lock.changePasswordWithBiometrics(to: password, hint: hint)
        case .recoveryKey:
            guard let code = RecoveryCode(recoveryKey) else { throw LockError.wrongRecoveryKey }
            return try await lock.resetPassword(recoveryCode: code, to: password, hint: hint)
        }
    }

    private func lockNote(_ id: Note.ID) async {
        do {
            try await lock.library.lock(id)
        } catch {
            lock.library.presentedError = LibraryError(title: "Couldn't lock the note", message: error.localizedDescription)
        }
    }
}

/// The recovery key, shown once: copied or printed, then confirmed as kept.
struct MobileRecoveryKeyView: View {
    let code: RecoveryCode
    let done: () -> Void

    @ViewState private var saved = false
    @ViewState private var copied = false

    var body: some View {
        Form {
            Section {
                Text(code.description)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Recovery key \(code.description)")
                    .accessibilityIdentifier("recoveryKey")
                Button(copied ? "Copied" : "Copy", action: copy)
                Button("Print…", action: print)
            } footer: {
                Text("If you forget your password, this key is the only way to open your locked notes. Minote doesn't keep it and can't show it again. Print it, or keep it in a password manager: somewhere other than this device.")
            }
            Toggle("I've saved my recovery key somewhere safe", isOn: $saved)
        }
        .navigationTitle("Recovery Key")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).disabled(!saved)
            }
        }
    }

    private func copy() {
        // This device only, and gone from the clipboard after ten minutes.
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: code.description]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        copied = true
    }

    private func print() {
        let made = Date().formatted(date: .long, time: .omitted)
        let page = "Minote Recovery Key\n\n\(code.description)\n\nMade \(made). It opens your locked notes in Minote if you forget your password. Anyone who has it can open them too: keep it somewhere safe. A newer recovery key, or a new password, replaces it."
        let formatter = UISimpleTextPrintFormatter(text: page)
        formatter.perPageContentInsets = UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = "Minote Recovery Key"
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
}

/// Locked notes: the password, what's locked, Face ID and when to lock again.
struct MobileSecuritySettings: View {
    let lock: LockController
    let dismiss: () -> Void

    @ViewState private var request: MobilePasswordRequest?
    @ViewState private var confirmsWholeLibrary = false
    @ViewState private var confirmsSelectedNotes = false
    @ViewState private var confirmsNewRecoveryKey = false
    @ViewState private var shownCode: ShownRecoveryCode?

    private struct ShownRecoveryCode: Identifiable {
        let id = UUID()
        let code: RecoveryCode
    }

    private var library: Library { lock.library }

    private func makeRecoveryKey() {
        Task {
            do {
                shownCode = ShownRecoveryCode(code: try await lock.makeRecoveryCode())
            } catch {
                library.presentedError = LibraryError(title: "Couldn't make a recovery key", message: error.localizedDescription)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !library.hasPassword {
                    Section {
                        Button("Set Password…") { request = MobilePasswordRequest(kind: .set) }
                            .disabled(!library.canSetPassword)
                    } footer: {
                        Text("Locked notes are encrypted on this device and in iCloud, so other apps can't read them; their titles stay visible.")
                    }
                } else {
                    if !library.isUnlocked {
                        Section("Unlock to change what's locked") {
                            MobileUnlockForm(lock: lock)
                        }
                    }
                    Section {
                        Picker("Lock", selection: Binding(
                            get: { library.lockScope },
                            set: { scope in
                                guard scope != library.lockScope else { return }
                                if scope == .library { confirmsWholeLibrary = true } else { confirmsSelectedNotes = true }
                            }
                        )) {
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
                            ForEach(LockTimeout.allCases) { Text($0.title).tag($0) }
                        }
                        .disabled(!library.isUnlocked)
                    } footer: {
                        Text("Locked notes also lock when you leave Minote.")
                    }
                    Section {
                        Button("New Recovery Key…") {
                            if library.vault?.key.recovery == nil { makeRecoveryKey() } else { confirmsNewRecoveryKey = true }
                        }
                        .disabled(!library.isUnlocked || lock.isBusy)
                    } footer: {
                        Text(library.vault?.key.recovery == nil
                            ? "No recovery key yet: without one, a forgotten password means losing your locked notes."
                            : "The recovery key opens your locked notes if you forget the password. A new one replaces it.")
                    }
                    Section {
                        Button("Change Password…") { request = MobilePasswordRequest(kind: .change) }
                        Button("Lock Now") { lock.lockNow() }
                            .disabled(!library.isUnlocked)
                        Button("Turn Off Password", role: .destructive) {
                            Task { try? await lock.removePassword() }
                        }
                        .disabled(library.hasLockedNotes || library.lockScope == .library)
                    }
                }
            }
            .navigationTitle("Locked Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
            .sheet(item: $request) { request in
                MobilePasswordSheet(request: request, lock: lock) { self.request = nil }
            }
            .sheet(item: $shownCode) { shown in
                NavigationStack {
                    MobileRecoveryKeyView(code: shown.code) { shownCode = nil }
                        .navigationBarTitleDisplayMode(.inline)
                }
                .interactiveDismissDisabled()
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
                Text("Every note is encrypted, and new notes start locked. Minote opens behind a lock screen.")
            }
            .confirmationDialog("Lock only the notes you choose?", isPresented: $confirmsSelectedNotes, titleVisibility: .visible) {
                Button("Keep Notes Locked") { setScope(.notes) }
                Button("Remove Lock from All Notes") { setScope(.notes, removingLocks: true) }
                Button("Cancel", role: .cancel) {}
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
