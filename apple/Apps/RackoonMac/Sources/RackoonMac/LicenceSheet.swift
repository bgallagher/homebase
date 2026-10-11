import RackoonCore
import SwiftUI

/// Help > Enter Licence…: paste the key from the purchase email. Shows who it is licensed to once accepted, and lets the
/// user remove it (and later paste it again, or another one).
struct LicenceSheet: View {
    let close: () -> Void
    private let store = LicenceStore.shared
    @State private var text = ""
    @State private var problem: String?
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rackoon licence").font(.system(size: 16, weight: .semibold))
            switch store.state {
            case .supporter(let email, let env):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Supporter", systemImage: "heart.fill").foregroundStyle(Theme.accent).font(.system(size: 14, weight: .semibold))
                    Text("Licensed to \(email)").font(.system(size: 13))
                    if env == .sandbox {
                        Text("This is a sandbox (test) key.").font(.system(size: 12)).foregroundStyle(Theme.warn)
                    }
                    Text("Thank you for feeding the Rackoon. Everything in the app works the same with or without a key.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
                Text("To use a different key, paste it below. Remove deletes the saved key from this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            case .none:
                Text("Paste the key from your purchase email. It starts with RKN1-.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                if let stored = store.storedProblem {
                    Text("The saved key isn't being used: \(stored)").font(.system(size: 12)).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(problem == nil ? Theme.border : Theme.danger))
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if store.isSupporter {
                    Button("Remove Licence…") { confirmingRemove = true }.handCursor()
                }
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction).handCursor()
                Button(store.isSupporter ? "Use This Key" : "Activate", action: activate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .handCursor()
            }
        }
        .padding(22).frame(width: 480)
        .confirmationDialog("Remove the saved licence from this Mac?", isPresented: $confirmingRemove) {
            Button("Remove Licence", role: .destructive) { store.remove(); problem = nil }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can paste the key again at any time. Nothing else changes.")
        }
    }

    private func activate() {
        do {
            try store.activate(text)
            problem = nil
            text = ""
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
