import AppKit
import RackoonCore
import SwiftUI

/// A root command was refused because the ssh user's sudo wants a password. Shown by `.sudoPassword(_:)` (or directly,
/// for the reboot); `submit` gets the typed password, which the caller hands to sudo and keeps nowhere.
struct SudoRequest: Identifiable {
    let id = UUID()
    let title: String
    let server: Server
    /// The exact command that will run (it contains no password).
    let command: String
    /// Why the previous attempt failed ("The server did not accept that password."), if there was one.
    var problem: String?
    /// The default button: "Reboot", "Install", "Run".
    var actionLabel = "Run"
    var destructive = false
    /// Show "Remember on this Mac" (only when `SudoVault` can store passwords).
    var canRemember = false
    /// The typed password, and whether to remember it once the server has accepted it.
    let submit: (String, Bool) -> Void
}

extension View {
    func sudoPassword(_ request: Binding<SudoRequest?>) -> some View {
        sheet(item: request) { r in
            SudoPasswordSheet(request: r) { request.wrappedValue = nil }
        }
    }
}

struct SudoPasswordSheet: View {
    let request: SudoRequest
    /// Cancel (and, unless `closesItself` is false, also after the password was handed over).
    let close: () -> Void
    /// False when the presenter takes the sheet down itself once the password arrives (the reboot: its phase changes,
    /// while calling `close` there would give up on the reboot).
    var closesItself = true
    @State private var password = ""
    @State private var remember = false

    private var user: String { request.server.user ?? "This user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                Text(request.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text("\(user) needs a password for sudo on \(request.server.name). It is typed into sudo's one prompt before the command starts, over its own SSH connection and never written into the command.\(request.canRemember ? "" : " It is not saved.")")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Sudo password", text: $password)
                .textContentType(.password)   // lets a password manager fill it; never .newPassword (no "save" offer)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            if request.canRemember {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Remember on this Mac", isOn: $remember).toggleStyle(.checkbox)
                    Text("Saved only after the server accepts it, sealed by this Mac's Secure Enclave and never synced. Each use asks for Touch ID, your Apple Watch or your login password. Forget it from the Server menu.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem = request.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("COMMAND").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
                ScrollView {
                    Text(request.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).buttonStyle(.bordered).handCursor()
                Button(request.actionLabel, action: send).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .tint(request.destructive ? Theme.danger : Theme.accent)
                    .handCursor().disabled(password.isEmpty)
            }
            .controlSize(.large).padding(.top, 4)
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(AppearanceStore.shared.fixedColorScheme)
    }

    private func send() {
        guard !password.isEmpty else { return }
        let typed = password
        password = ""
        if closesItself { close() }
        request.submit(typed, remember)
    }
}
