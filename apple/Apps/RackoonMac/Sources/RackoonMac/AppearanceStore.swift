import AppKit
import Foundation
import RackoonCore
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

    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    private static let selectionKey = "appearanceSelection"
    private static let legacyThemeKey = "terminalThemeID"   // from when the theme only styled terminals
    private static let highlightKey = "terminalHighlightOutput"

    var isAutomatic: Bool { selectionID == ThemeCatalog.automaticID }

    /// False when the relay executable was not built or shipped; the highlight switch is then disabled.
    var highlightAvailable: Bool { TerminalTab.relayURL != nil }

    /// True when the app should follow macOS. Not when themes failed to load: the built-in fallback is a single
    /// dark theme, so system-drawn controls must be forced dark to match it.
    private var followsSystem: Bool { isAutomatic && themeError == nil }

    /// nil when following macOS, otherwise forced to match the resolved theme.
    var fixedColorScheme: ColorScheme? { followsSystem ? nil : (resolvedTheme.isDark ? .dark : .light) }

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
            id: ThemeCatalog.defaultID, name: "Default", family: "Rackoon", appearance: "dark",
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
        // A saved id that no longer exists (a theme removed from the bundle) becomes Automatic, and is rewritten.
        let valid = saved == ThemeCatalog.automaticID || all.contains { $0.id == saved }
        selectionID = valid ? saved : ThemeCatalog.automaticID
        if !valid { defaults.set(ThemeCatalog.automaticID, forKey: Self.selectionKey) }
        systemIsDark = dark
        resolvedTheme = resolved
        palette = AppPalette.derive(from: resolved)
        highlightOutput = defaults.object(forKey: Self.highlightKey) as? Bool ?? true

        // While following macOS, NSApp.appearance is nil, so effectiveAppearance IS the system appearance and
        // changes to it are delivered reliably. (When a theme is fixed we do not need the system state at all:
        // choosing Automatic again clears the override and reads it fresh.)
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.recompute() }
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
    }

    /// Makes system-drawn parts (sheets, popovers, alerts, text fields) match the theme. Call after any change.
    func applyWindowAppearance() {
        let wanted: NSAppearance? = followsSystem ? nil : NSAppearance(named: resolvedTheme.isDark ? .darkAqua : .aqua)
        // Only touch it when it differs: setting it fires the effectiveAppearance observer.
        if NSApplication.shared.appearance?.name != wanted?.name { NSApplication.shared.appearance = wanted }
    }

    /// Re-resolves the theme. Order matters: clear or set the override first, and only then read the system
    /// appearance, because it is only readable from effectiveAppearance while nothing overrides it.
    private func recompute() {
        applyWindowAppearance()
        if followsSystem { systemIsDark = Self.readSystemIsDark() }
        if let t = ThemeCatalog.resolve(selection: selectionID, systemIsDark: systemIsDark, in: themes), t != resolvedTheme {
            resolvedTheme = t
            palette = AppPalette.derive(from: t)
        }
    }

    private static func readSystemIsDark() -> Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
