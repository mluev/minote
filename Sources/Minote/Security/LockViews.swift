import AppKit
import MinoteEditor
import MinoteKit
import SwiftUI

/// What the password sheet is for.
struct PasswordRequest: Identifiable {
    enum Kind {
        /// The first password.
        case set
        case change
        /// Unlock before a command that needs the key (Lock Note while locked).
        case unlock
        /// A forgotten password: a new one, with Touch ID or the recovery key.
        case reset
    }

    let id = UUID()
    let kind: Kind
    /// A note to lock once there's a password and the notes are unlocked.
    var thenLock: Note.ID?
    /// Lock the whole library once the password is set.
    var thenScope: LockScope?
}

/// The lock screens' password field: Minote's own, quiet and round like the
/// search field, without the system's bezel or focus ring. Empty, it offers
/// Touch ID at its end; once something is typed, an arrow unlocks.
/// A wrong password shakes it; after a few, the hint shows underneath. From
/// the first, "Forgot Password?" offers a new one (Touch ID, recovery key).
struct UnlockForm: View {
    let lock: LockController
    let palette: EditorPalette
    var prompt = "Password"
    /// Off for a note sealed with an earlier password: Touch ID holds only the current one.
    var offersBiometrics = true

    @ViewState private var password = ""
    @ViewState private var failures: CGFloat = 0
    @ViewState private var showsHint = false
    @ViewState private var resetsPassword = false
    @FocusState private var isFocused: Bool

    private var color: (NSColor) -> Color { { Color(nsColor: $0) } }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                SecureField(prompt, text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(color(palette.text))
                    .focused($isFocused)
                    .focusEffectDisabled()
                    .onSubmit(unlock)
                    .disabled(lock.isBusy)
                    .onChange(of: password) { if !password.isEmpty { showsHint = false } }
                trailingButton
                    .frame(width: 24, height: 24)
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(width: 236, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color(palette.text).opacity(isFocused ? 0.07 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(color(palette.rule).opacity(isFocused ? 1 : 0.5))
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .modifier(Shake(animatableData: failures))

            // Always the same height, so nothing moves when the hint appears.
            Text(hintLine)
                .font(.system(size: 11.5))
                .foregroundStyle(color(palette.quote))
                .opacity(showsHint ? 1 : 0)
                .frame(height: 14)
            Button("Forgot Password?") { resetsPassword = true }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .underline()
                .foregroundStyle(color(palette.quote))
                .opacity(failures > 0 ? 1 : 0)
                .disabled(failures == 0)
                .frame(height: 14)
        }
        .onAppear { isFocused = true }
        .sheet(isPresented: $resetsPassword) {
            PasswordSheet(request: PasswordRequest(kind: .reset), lock: lock) { resetsPassword = false }
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if lock.isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else if password.isEmpty && offersBiometrics && lock.isBiometricReady {
            Button {
                Task { await lock.unlockWithBiometrics() }
            } label: {
                Image(systemName: lock.biometricName == "Face ID" ? "faceid" : "touchid")
                    .font(.system(size: 15, weight: .regular))
            }
            .buttonStyle(ChromeButtonStyle(palette: palette, cornerRadius: 7, size: 24))
            .help("Unlock with \(lock.biometricName)")
            .accessibilityLabel("Unlock with \(lock.biometricName)")
        } else {
            Button(action: unlock) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color(password.isEmpty ? palette.syntax : palette.background))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color(palette.text).opacity(password.isEmpty ? 0 : 0.85)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(password.isEmpty)
            .help("Unlock")
            .accessibilityLabel("Unlock")
        }
    }

    private var hintLine: String {
        guard Int(failures) >= PasswordPolicy.hintAfterFailures, let hint = lock.library.vault?.key.hint else { return "Wrong password" }
        return "Wrong password · Hint: \(hint)"
    }

    private func unlock() {
        guard !password.isEmpty, !lock.isBusy else { return }
        let typed = password
        Task {
            do {
                try await lock.unlock(password: typed)
                password = ""
                showsHint = false
            } catch {
                password = ""
                showsHint = true
                withAnimation(.linear(duration: 0.32)) { failures += 1 }
                isFocused = true
            }
        }
    }
}

/// A short side-to-side shake, once per wrong password.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// What the lock screens show: a lock, a title, a line, the password field.
/// Centered on the space it's given, a little above the middle, as the eye
/// expects.
private struct LockContent: View {
    let title: String
    let message: String
    let lock: LockController
    let palette: EditorPalette
    var prompt = "Password"
    var offersBiometrics = true

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(nsColor: palette.quote))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(nsColor: palette.text).opacity(0.06)))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(nsColor: palette.text))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 16)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Color(nsColor: palette.quote))
                .multilineTextAlignment(.center)
                .padding(.top, 5)
            UnlockForm(lock: lock, palette: palette, prompt: prompt, offersBiometrics: offersBiometrics)
                .padding(.top, 22)
        }
        .frame(maxWidth: 320)
        .offset(y: -18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A locked note's page while it's sealed: its title, and ways to unlock.
struct LockedNotePanel: View {
    let tab: PageTab
    let workspace: Workspace
    let palette: EditorPalette

    private var lock: LockController { workspace.lock }
    /// Unlocked, yet this note is still shut: sealed with an earlier password.
    private var needsEarlierPassword: Bool { workspace.library.isUnlocked }

    var body: some View {
        LockContent(
            title: tab.note?.displayTitle ?? "Locked Note",
            message: needsEarlierPassword ? "Locked with an earlier password." : "This note is locked.",
            lock: lock,
            palette: palette,
            prompt: needsEarlierPassword ? "Earlier password" : "Password",
            offersBiometrics: !needsEarlierPassword
        )
        .background(Color(nsColor: palette.background))
        .task(id: tab.noteID) {
            // Opened on purpose (not put back at launch): Touch ID asks right away.
            guard let id = tab.noteID, workspace.takeUnlockPrompt(for: id) else { return }
            await lock.unlockWithBiometrics()
        }
    }
}

/// Whole library mode while locked: the window's notes are covered, all the
/// way up; its top stays a handle to move the window by.
struct AppLockView: View {
    let lock: LockController
    let palette: EditorPalette

    var body: some View {
        LockContent(
            title: "Minote is locked",
            message: lock.isBiometricReady ? "Enter your password or use \(lock.biometricName)." : "Enter your password to see your notes.",
            lock: lock,
            palette: palette
        )
        .background(Color(nsColor: palette.background))
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: TitlebarLayout.height)
        }
        .contentShape(Rectangle())
        .ignoresSafeArea()
    }
}

/// In the tab bar, beside "Aa": whether locked notes are open, and a click
/// to lock them all at once (or, while locked, to unlock with Touch ID; the
/// first time, to set a password).
struct LockButton: View {
    let workspace: Workspace
    let state: WindowState
    let palette: EditorPalette

    private var library: Library { workspace.library }
    private var lock: LockController { workspace.lock }
    private var isOpen: Bool { library.hasPassword && library.isUnlocked }

    var body: some View {
        Button(action: act) {
            Image(systemName: isOpen ? "lock.open" : "lock")
                .font(.system(size: 12.5, weight: .medium))
        }
        .buttonStyle(ChromeButtonStyle(palette: palette))
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        if !library.hasPassword { return "Lock Notes with a Password…" }
        if library.isUnlocked { return "Lock Now (⌃⌘L)" }
        return lock.isBiometricReady ? "Unlock with \(lock.biometricName)" : "Unlock"
    }

    private func act() {
        guard library.hasPassword else {
            if library.canSetPassword { state.passwordRequest = PasswordRequest(kind: .set) }
            return
        }
        if library.isUnlocked {
            lock.lockNow()
            return
        }
        Task {
            if !(await lock.unlockWithBiometrics()) { state.passwordRequest = PasswordRequest(kind: .unlock) }
        }
    }
}

/// Setting the password, changing it, resetting a forgotten one, or
/// unlocking for a command. Setting or changing it ends on the new recovery
/// key, which stays on screen until the user says it's kept.
struct PasswordSheet: View {
    let request: PasswordRequest
    let lock: LockController
    let dismiss: () -> Void

    /// What stands in for the current password when changing it.
    private enum Proof: Hashable {
        case password, biometrics, recoveryKey
    }

    @ViewState private var kind: PasswordRequest.Kind
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

    init(request: PasswordRequest, lock: LockController, dismiss: @escaping () -> Void) {
        self.request = request
        self.lock = lock
        self.dismiss = dismiss
        _kind = ViewState(initialValue: request.kind)
        _proof = ViewState(initialValue: request.kind == .reset ? (lock.isBiometricReady ? .biometrics : .recoveryKey) : .password)
    }

    var body: some View {
        Group {
            if let recoveryCode {
                RecoveryKeyView(code: recoveryCode, done: dismiss)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .unlock {
                SecureField("Password", text: $current)
                    .onSubmit(commit)
            }
            if kind == .change || kind == .reset {
                if proofs.count > 1 {
                    Picker("Confirm with", selection: $proof) {
                        ForEach(proofs, id: \.self) { Text(label(of: $0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                switch proof {
                case .password:
                    SecureField("Current password", text: $current)
                case .biometrics:
                    Text("\(lock.biometricName) confirms it's you when you continue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .recoveryKey:
                    TextField("Recovery key", text: $recoveryKey, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"))
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                }
            }
            if kind != .unlock {
                SecureField("New password", text: $password)
                SecureField("Verify", text: $confirmation)
                    .onSubmit(commit)
                TextField("Hint (optional)", text: $hint)
                if kind == .set && lock.canUseBiometrics {
                    Toggle("Unlock with \(lock.biometricName)", isOn: $useBiometrics)
                }
                Text("At least \(PasswordPolicy.minimumLength) characters: a few unrelated words are strong and easy to remember. The hint isn't encrypted, so it mustn't give the password away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let issue {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if kind == .unlock {
                    Button("Forgot Password?") {
                        error = nil
                        proof = lock.isBiometricReady ? .biometrics : .recoveryKey
                        kind = .reset
                    }
                    .buttonStyle(.link)
                }
                if lock.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit || lock.isBusy)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var title: String {
        switch kind {
        case .set: "Set a Password for Locked Notes"
        case .change: "Change Password"
        case .unlock: "Unlock Locked Notes"
        case .reset: "Forgot Your Password?"
        }
    }

    private var explanation: String {
        switch kind {
        case .set: "Locked notes are encrypted on disk, so other apps and tools can't read them; their titles stay visible. One password opens them all."
        case .change: "Every locked note is encrypted again with the new password, and you get a new recovery key."
        case .unlock: "Enter your password to continue."
        case .reset:
            lock.isBiometricReady
                ? "Set a new password with \(lock.biometricName) or the recovery key you saved. Every locked note is encrypted again with it."
                : "Set a new password with the recovery key you saved when you made the old one. Every locked note is encrypted again with it."
        }
    }

    private var actionTitle: String {
        switch kind {
        case .set: request.thenLock != nil ? "Lock Note" : "Set Password"
        case .change: "Change Password"
        case .unlock: request.thenLock != nil ? "Lock Note" : "Unlock"
        case .reset: "Set Password"
        }
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

    /// What's still wrong with the new password, said as it's typed.
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
                    let code = try await lock.setPassword(password, hint: hint, scope: request.thenScope ?? .notes, useBiometrics: useBiometrics)
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
struct RecoveryKeyView: View {
    let code: RecoveryCode
    let done: () -> Void

    @ViewState private var saved = false
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Your Recovery Key")
                .font(.headline)
            Text("If you forget your password, this key is the only way to open your locked notes. Minote doesn't keep it and can't show it again. Print it, or keep it in a password manager: somewhere other than this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(code.description)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                .accessibilityLabel("Recovery key \(code.description)")
            HStack {
                Button(copied ? "Copied" : "Copy", action: copy)
                Button("Print…") { RecoveryKeyPrinter.print(code) }
            }
            Toggle("I've saved my recovery key somewhere safe", isOn: $saved)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saved)
            }
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        // This Mac only: not to other devices through Universal Clipboard.
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(code.description, forType: .string)
        // Clipboard managers that honour it keep it out of their history.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copied = true
    }
}

/// Prints the recovery key on a page of its own, to keep with other papers.
enum RecoveryKeyPrinter {
    static func print(_ code: RecoveryCode) {
        let page = NSMutableAttributedString()
        page.append(NSAttributedString(string: "Minote Recovery Key\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)]))
        page.append(NSAttributedString(string: "\(code.description)\n\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium)]))
        let made = Date().formatted(date: .long, time: .omitted)
        page.append(NSAttributedString(
            string: "Made \(made). It opens your locked notes in Minote if you forget your password. Anyone who has it can open them too: keep it somewhere safe. A newer recovery key, or a new password, replaces it.",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        view.textStorage?.setAttributedString(page)
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = "Minote Recovery Key"
        operation.run()
    }
}
