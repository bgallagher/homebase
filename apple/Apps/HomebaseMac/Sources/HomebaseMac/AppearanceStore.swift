import AppKit
import Foundation
import HomebaseCore
import Observation
import SwiftUI

/// The app's look: which theme is selected (or Automatic), the theme that resolves to, the chrome palette
/// derived from it, and the terminal highlight switch. One theme drives both the terminals and the app's own UI.
@MainActor @Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    let themes: [TerminalTheme]
    /// Set when themes.json could not be loaded; the picker shows it and a plain built-in theme is used.
    let themeError: String?
    private(set) var selectionID: String
    private(set) var systemIsDark: Bool
    private(set) var resolvedTheme: TerminalTheme
    private(set) var palette: AppPalette
    private(set) var highlightOutput: Bool

    /// Called when the highlight switch changes, so open terminals can be told straight away.
    @ObservationIgnored var onHighlightChange: ((Bool) -> Void)?
    @ObservationIgnored private var systemObserver: NSObjectProtocol?

    private static let selectionKey = "appearanceSelection"
    private static let legacyThemeKey = "terminalThemeID"   // from when the theme only styled terminals
    private static let highlightKey = "terminalHighlightOutput"

    var isAutomatic: Bool { selectionID == ThemeCatalog.automaticID }

    /// False when the relay executable was not built or shipped; the highlight switch is then disabled.
    var highlightAvailable: Bool { TerminalTab.relayURL != nil }

    /// nil in Automatic (follow macOS), otherwise forced to match the chosen theme.
    var fixedColorScheme: ColorScheme? { isAutomatic ? nil : (resolvedTheme.isDark ? .dark : .light) }

    /// "Automatic" shows which theme it currently resolves to.
    var selectionTitle: String { isAutomatic ? "Automatic · \(resolvedTheme.name)" : resolvedTheme.name }

    private init() {
        var loaded: [TerminalTheme] = []
        var loadError: String?
        do {
            guard let url = Bundle.module.url(forResource: "themes", withExtension: "json") else {
                throw ThemeCatalogError.invalid("themes.json is missing from the app bundle")
            }
            loaded = try ThemeCatalog.load(from: Data(contentsOf: url))
        } catch {
            loadError = error.localizedDescription
        }
        let fallback = TerminalTheme(
            id: ThemeCatalog.defaultID, name: "Default", family: "Homebase", appearance: "dark",
            background: "#000000", foreground: "#E5E5E5",
            ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
                   "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#FFFFFF"])
        let all = loaded.isEmpty ? [fallback] : loaded
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.selectionKey) ?? defaults.string(forKey: Self.legacyThemeKey)
            ?? ThemeCatalog.automaticID
        let dark = Self.readSystemIsDark()
        let resolved = ThemeCatalog.resolve(selection: saved, systemIsDark: dark, in: all) ?? fallback

        themes = all
        themeError = loadError
        selectionID = all.contains { $0.id == saved } ? saved : ThemeCatalog.automaticID
        systemIsDark = dark
        resolvedTheme = resolved
        palette = AppPalette.derive(from: resolved)
        highlightOutput = defaults.object(forKey: Self.highlightKey) as? Bool ?? true

        // Fires when the user flips macOS between light and dark (also on the automatic schedule).
        systemObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            // The preference is written just after the notification; give it a moment.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.systemAppearanceChanged()
            }
        }
    }

    /// Picks a theme by id, or `ThemeCatalog.automaticID`.
    func select(_ id: String) {
        guard id == ThemeCatalog.automaticID || themes.contains(where: { $0.id == id }), id != selectionID else { return }
        selectionID = id
        UserDefaults.standard.set(id, forKey: Self.selectionKey)
        recompute()
    }

    func setHighlight(_ on: Bool) {
        guard on != highlightOutput else { return }
        highlightOutput = on
        UserDefaults.standard.set(on, forKey: Self.highlightKey)
        onHighlightChange?(on)
    }

    /// Makes system-drawn parts (sheets, popovers, alerts, text fields) match the theme. Call after any change.
    func applyWindowAppearance() {
        NSApplication.shared.appearance = isAutomatic ? nil : NSAppearance(named: resolvedTheme.isDark ? .darkAqua : .aqua)
    }

    private func systemAppearanceChanged() {
        let dark = Self.readSystemIsDark()
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        recompute()
    }

    private func recompute() {
        if let t = ThemeCatalog.resolve(selection: selectionID, systemIsDark: systemIsDark, in: themes) {
            resolvedTheme = t
            palette = AppPalette.derive(from: t)
        }
        applyWindowAppearance()
    }

    /// macOS stores "Dark" under AppleInterfaceStyle only while dark mode is on.
    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
