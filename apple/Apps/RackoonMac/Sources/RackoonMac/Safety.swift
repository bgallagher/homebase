import RackoonCore
import SwiftUI

/// App-wide safety switches. Read-only mode is stored here and mirrored into the one `ActionPolicy` that every
/// session shares, so the service layer (not just the UI) refuses changes while it is on.
@MainActor @Observable
final class SafetyStore {
    static let shared = SafetyStore()
    private static let key = "readOnlyMode"

    private(set) var readOnly: Bool
    @ObservationIgnored let policy: ActionPolicy

    private init() {
        let on = UserDefaults.standard.bool(forKey: Self.key)
        readOnly = on
        policy = ActionPolicy(readOnly: on)
    }

    func setReadOnly(_ on: Bool) {
        guard on != readOnly else { return }
        readOnly = on
        policy.isReadOnly = on
        UserDefaults.standard.set(on, forKey: Self.key)
    }
}

/// A change waiting for the user's yes. Shown by `confirmAction`; `run` is only called on Confirm.
struct PendingAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let serverName: String
    /// The exact command that will run on the server.
    let command: String
    let destructive: Bool
    let run: () -> Void
}

extension View {
    func confirmAction(_ pending: Binding<PendingAction?>) -> some View {
        sheet(item: pending) { action in
            ConfirmSheet(action: action) { pending.wrappedValue = nil }
        }
    }
}

private struct ConfirmSheet: View {
    let action: PendingAction
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: action.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(action.destructive ? Theme.warn : Theme.accent)
                Text(action.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text(action.message).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("RUNS ON \(action.serverName.uppercased())")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
                Text(action.command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }

            HStack(spacing: 10) {
                Spacer()
                // Native macOS buttons: bordered Cancel, prominent default action that runs the command shown above.
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("Run Command") {
                    close()
                    action.run()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(action.destructive ? Theme.danger : Theme.accent)
            }
            .controlSize(.large)
            .handCursor()
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(AppearanceStore.shared.fixedColorScheme)
    }
}
