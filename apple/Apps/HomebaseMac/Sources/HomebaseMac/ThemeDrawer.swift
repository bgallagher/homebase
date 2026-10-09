import HomebaseCore
import SwiftUI

/// Right-hand theme picker for the Terminal screen: search, All/Dark/Light filter, and a list of
/// themes with a small preview each. Clicking a theme applies it to every terminal immediately.
struct ThemeDrawer: View {
    let store: TerminalStore
    @State private var query = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", dark = "Dark", light = "Light" }

    private var visible: [TerminalTheme] {
        store.themes.filter { t in
            switch filter {
            case .all: true
            case .dark: t.isDark
            case .light: !t.isDark
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.family.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Highlight output", isOn: Binding(get: { store.highlightOutput }, set: { store.highlightOutput = $0 }))
                    .disabled(!store.highlightAvailable)
                Text(store.highlightAvailable
                     ? "Colours IP addresses, errors, warnings and high percentages. Applies to new tabs."
                     : "Unavailable: the homebase-pty helper was not found next to the app.")
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

            if let error = store.themeError { ErrorBanner(message: error) }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visible) { t in
                        ThemeRow(theme: t, selected: t.id == store.theme.id) { store.select(theme: t) }
                    }
                    if visible.isEmpty {
                        Text("No themes match.").foregroundStyle(Theme.textMuted).padding(.top, 20)
                    }
                }
            }
            Text("Colour schemes from iTerm2-Color-Schemes (MIT). Credits in SOURCES.md.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
        .padding(14)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .foregroundStyle(Theme.textPrimary)
    }
}

private struct ThemeRow: View {
    let theme: TerminalTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ThemeThumbnail(theme: theme)
                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.name).fontWeight(.medium).lineLimit(1)
                    Text(theme.family).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
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
        .accessibilityLabel("\(theme.name), \(theme.appearance)\(selected ? ", selected" : "")")
    }
}

/// A tiny fake terminal drawn in the theme's own colours.
struct ThemeThumbnail: View {
    let theme: TerminalTheme

    var body: some View {
        let ansi = theme.ansiRGB
        let fg = Color(rgb: theme.foregroundRGB)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(rgb: theme.backgroundRGB))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) { bar(fg, 26); bar(Color(rgb: ansi[2]), 16) }
                HStack(spacing: 3) { bar(Color(rgb: ansi[4]), 14); bar(Color(rgb: ansi[1]), 20); bar(Color(rgb: ansi[3]), 10) }
                HStack(spacing: 3) { bar(Color(rgb: ansi[5]), 18); Rectangle().fill(Color(rgb: theme.cursorRGB)).frame(width: 4, height: 6) }
            }
            .padding(8)
        }
        .frame(width: 76, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
        .accessibilityHidden(true)
    }

    private func bar(_ color: Color, _ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: width, height: 4)
    }
}

private extension Color {
    init(rgb: RGB) { self.init(nsColor: rgb.nsColor) }
}
