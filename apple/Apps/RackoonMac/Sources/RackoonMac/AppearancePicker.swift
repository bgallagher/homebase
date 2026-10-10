import RackoonCore
import SwiftUI

/// The Appearance popover: terminal options, then the theme list (Automatic first). Choosing a theme restyles
/// the whole app and every terminal at once.
struct AppearancePicker: View {
    let appearance: AppearanceStore
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", dark = "Dark", light = "Light" }

    private var visible: [TerminalTheme] {
        appearance.themes.filter { t in
            switch filter {
            case .all: true
            case .dark: t.isDark
            case .light: !t.isDark
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.family.localizedCaseInsensitiveContains(query) }
    }

    private var showAutomatic: Bool {
        query.isEmpty || "automatic follows macos".contains(query.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Highlight output", isOn: Binding(get: { appearance.highlightOutput },
                                                         set: { appearance.setHighlight($0) }))
                    .disabled(!appearance.highlightAvailable)
                Text(appearance.highlightAvailable
                     ? "Colours IP addresses, errors, warnings and high percentages, in open tabs too."
                     : "Unavailable: the rackoon-pty helper was not found next to the app.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Text("Themes").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search themes", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))

            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if let error = appearance.themeError { ErrorBanner(message: error) }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if showAutomatic, filter == .all {
                        ThemeRow(theme: automaticTheme, title: "Automatic", subtitle: "Follows macOS light and dark",
                                 selected: appearance.isAutomatic) { appearance.select(ThemeCatalog.automaticID) }
                    }
                    ForEach(visible) { t in
                        ThemeRow(theme: t, title: t.name, subtitle: t.family,
                                 selected: !appearance.isAutomatic && t.id == appearance.selectionID) { appearance.select(t.id) }
                    }
                    if visible.isEmpty, !showAutomatic || filter != .all {
                        Text("No themes match.").foregroundStyle(Theme.textMuted).padding(.top, 20)
                    }
                }
            }
            Text("Colour schemes from iTerm2-Color-Schemes (MIT). Credits in SOURCES.md.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
        .padding(14)
        .frame(width: 320, height: 560)
        .background(Theme.sidebar)
        .foregroundStyle(Theme.textPrimary)
    }

    /// Automatic previews as whichever Rackoon theme it currently resolves to.
    private var automaticTheme: TerminalTheme { appearance.isAutomatic ? appearance.resolvedTheme
        : (ThemeCatalog.resolve(selection: ThemeCatalog.automaticID, systemIsDark: appearance.systemIsDark, in: appearance.themes) ?? appearance.resolvedTheme) }
}

private struct ThemeRow: View {
    let theme: TerminalTheme
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ThemeThumbnail(theme: theme)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .padding(8)
            .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .accessibilityLabel("\(title), \(theme.appearance)\(selected ? ", selected" : "")")
    }
}

/// A tiny fake terminal drawn in the theme's own colours.
struct ThemeThumbnail: View {
    let theme: TerminalTheme
    var compact = false

    var body: some View {
        let ansi = theme.ansiRGB
        let fg = Color(rgb: theme.foregroundRGB)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(rgb: theme.backgroundRGB))
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                HStack(spacing: 3) { bar(fg, 26); bar(Color(rgb: ansi[2]), 16) }
                HStack(spacing: 3) { bar(Color(rgb: ansi[4]), 14); bar(Color(rgb: ansi[1]), 20); bar(Color(rgb: ansi[3]), 10) }
                if !compact {
                    HStack(spacing: 3) { bar(Color(rgb: ansi[5]), 18); Rectangle().fill(Color(rgb: theme.cursorRGB)).frame(width: 4, height: 6) }
                }
            }
            .padding(compact ? 6 : 8)
        }
        .frame(width: compact ? 52 : 76, height: compact ? 34 : 52)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
        .accessibilityHidden(true)
    }

    private func bar(_ color: Color, _ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: width, height: 4)
    }
}
