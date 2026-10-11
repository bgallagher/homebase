import RackoonCore
import SwiftUI

/// Help > Enter Licence…: paste the key from the purchase email. A supporter sees who it is licensed to and can remove the
/// key; the paste box is only there while there is no valid key (remove it to enter another).
struct LicenceSheet: View {
    let close: () -> Void
    private let store = LicenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var problem: String?
    @State private var confirmingRemove = false
    /// Counts accepted keys: drives the heart bounce, and the hearts overlay while `celebrating`.
    @State private var celebrations = 0
    @State private var celebrating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rackoon licence").font(.system(size: 16, weight: .semibold))
            if store.purchaseReturned && !store.isSupporter {
                Label {
                    Text("Payment successful. Check your email for your licence code, then paste it below.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ok)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            switch store.state {
            case .supporter(let email, let env):
                supporterCard(email: email, env: env)
            case .none:
                enterKey
            }
            HStack {
                if store.hasKey {
                    Button("Remove Licence…") { confirmingRemove = true }.handCursor()
                }
                Spacer()
                Button("Close") { store.dismissPurchaseNote(); close() }.keyboardShortcut(store.isSupporter ? .defaultAction : .cancelAction).handCursor()
                if !store.isSupporter {
                    Button("Activate", action: activate)
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .handCursor()
                }
            }
        }
        .padding(22).frame(width: 480)
        .overlay { if celebrating { Hearts().allowsHitTesting(false) } }
        .confirmationDialog("Remove the saved licence from this Mac?", isPresented: $confirmingRemove) {
            Button("Remove Licence", role: .destructive) { store.remove(); problem = nil }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can paste the key again at any time. Nothing else changes.")
        }
    }

    private func supporterCard(email: String, env: LicenceEnv) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Supporter")
                } icon: {
                    Image(systemName: "heart.fill").symbolEffect(.bounce, value: celebrations)
                }
                .foregroundStyle(Theme.accent).font(.system(size: 14, weight: .semibold))
                Text("Licensed to \(email)").font(.system(size: 13))
                if env == .sandbox {
                    Text("This is a sandbox (test) key.").font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
                Text("Thank you for feeding the Rackoon. Everything in the app works the same with or without a key.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
            checkNote
        }
    }

    @ViewBuilder private var enterKey: some View {
        Text("Paste the licence key from your purchase email: the whole long line of text.")
            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        if let stored = store.storedProblem {
            Text("The saved key isn't being used: \(stored)").font(.system(size: 12)).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        checkNote
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .frame(height: 96)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(problem == nil ? Theme.border : Theme.danger))
        if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
    }

    private var checkNote: some View {
        Text("About once a week the app asks the licence service whether this key was refunded. It sends only the key's random ID, never your email or anything about this Mac, and if the service can't be reached the key keeps working.")
            .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
    }

    private func activate() {
        do {
            try store.activate(text)
            problem = nil
            text = ""
            celebrations += 1
            if !reduceMotion {
                celebrating = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    celebrating = false
                }
            }
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// A burst of hearts rising from the bottom of the window. Plain SwiftUI: each heart animates itself once.
private struct Hearts: View {
    private struct Spec: Identifiable {
        let id: Int
        let x: CGFloat        // 0...1 across the window
        let drift: CGFloat
        let size: CGFloat
        let rise: CGFloat
        let delay: Double
        let duration: Double
        let colour: Int
    }

    private let specs: [Spec] = (0..<28).map { i in
        Spec(id: i, x: .random(in: 0.04...0.96), drift: .random(in: -40...40), size: .random(in: 12...28),
             rise: .random(in: 220...420), delay: .random(in: 0...0.6), duration: .random(in: 1.6...2.4), colour: .random(in: 0..<3))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(specs) { spec in
                    Heart(spec: (spec.size, spec.drift, spec.rise, spec.delay, spec.duration, colour(spec.colour)))
                        .position(x: geo.size.width * spec.x, y: geo.size.height + 20)
                }
            }
        }
        .clipped()
    }

    private func colour(_ index: Int) -> Color {
        [Theme.accent, Color(red: 0.95, green: 0.45, blue: 0.62), Theme.danger][index]
    }

    private struct Heart: View {
        let spec: (size: CGFloat, drift: CGFloat, rise: CGFloat, delay: Double, duration: Double, colour: Color)
        @State private var risen = false

        var body: some View {
            Image(systemName: "heart.fill")
                .font(.system(size: spec.size))
                .foregroundStyle(spec.colour)
                .scaleEffect(risen ? 1.15 : 0.6)
                .offset(x: risen ? spec.drift : 0, y: risen ? -spec.rise : 0)
                .opacity(risen ? 0 : 0.95)
                .onAppear { withAnimation(.easeOut(duration: spec.duration).delay(spec.delay)) { risen = true } }
        }
    }
}
