import SwiftUI

struct AboutView: View {
    static let windowID = "about"
    /// From Info.plist in a built app (tools/make-app); `swift run` has no bundle, so it says so.
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "development build" }
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let icon = AppIcon.artwork {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "server.rack").resizable().scaledToFit().padding(30).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)

            VStack(spacing: 4) {
                Text("Rackoon").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("Version \(Self.version)" + (AppBuild.isDev ? " · dev build" : "")).font(.callout).foregroundStyle(Theme.textSecondary)
            }
            if case .supporter(let email, _) = LicenceStore.shared.state {
                Label("Supporter · \(email)", systemImage: "heart.fill").font(.callout).foregroundStyle(Theme.accent)
            }
            Text("Manage your servers over plain SSH. Nothing to install on them.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 250)
            Text("Terminal themes from the iTerm2-Color-Schemes collection (MIT).")
                .font(.caption).foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 250)
        }
        .padding(28)
        .frame(width: 340)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(AppearanceStore.shared.fixedColorScheme)
    }
}
